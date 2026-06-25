//
//  BTTInjectRewriter.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

import SwiftSyntax
import SwiftParser
import Foundation

final class BTTInjectRewriter: SyntaxRewriter {
    var injectedViews = [String]()
    var complexViews  = [String]()  // views whose body was too complex to inject
    var filePath      = ""  // set by BTTInjectRevertHandler before visiting

    // MARK: - Import
    override func visit(_ node: SourceFileSyntax) -> SourceFileSyntax {
        let visited = super.visit(node)
        guard injectedViews.count > 0 else { return visited }

        let importModule = BTTConstants.importModule
        let alreadyImported = visited.statements.contains(where: {
            guard let d = $0.item.as(ImportDeclSyntax.self) else { return false }
            return d.path.trimmedDescription == importModule
        })
        guard !alreadyImported else { return visited }

        let hasSwiftUI = visited.statements.contains(where: {
            guard let d = $0.item.as(ImportDeclSyntax.self) else { return false }
            return d.path.trimmedDescription == "SwiftUI"
        })
        guard hasSwiftUI else { return visited }

        let bttImport = ImportDeclSyntax(
            leadingTrivia: .newline,
            importKeyword: .keyword(.import, trailingTrivia: .space),
            path: ImportPathComponentListSyntax([
                ImportPathComponentSyntax(name: .identifier(importModule))
            ])
        )

        var statements = Array(visited.statements)
        if let idx = statements.firstIndex(where: {
            guard let d = $0.item.as(ImportDeclSyntax.self) else { return false }
            return d.path.trimmedDescription == "SwiftUI"
        }) {
            statements.insert(CodeBlockItemSyntax(item: .decl(DeclSyntax(bttImport))), at: idx + 1)
        } else {
            statements.insert(CodeBlockItemSyntax(item: .decl(DeclSyntax(bttImport.with(\.leadingTrivia, [])))), at: 0)
        }
        return visited.with(\.statements, CodeBlockItemListSyntax(statements))
    }

    // MARK: - Struct

    override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
        let name = node.name.text

        guard conformsToView(node) else { return DeclSyntax(node) }
        guard !node.leadingTrivia.hasIgnore else { return DeclSyntax(node) }
        guard let bodyVar = bodyMember(in: node) else { return DeclSyntax(node) }
        guard bodyReturnsOpaqueView(bodyVar) else { return DeclSyntax(node) }

        // Already has .bttTrackScreen anywhere in body — skip silently
        if bodyVar.description.contains(".\(BTTConstants.trackModifier)(") {
            BTTLog.verbose("  Skipping \(name) — already injected")
            return DeclSyntax(node)
        }

        guard let newNode = injectTrackScreen(into: node, viewName: name) else {
            complexViews.append(name)
            if !filePath.isEmpty {
                let fileName = URL(fileURLWithPath: filePath).lastPathComponent
                BTTLog.warn("\(fileName): \(name) has a view body too complex for auto-instrumentation")
            }
            return DeclSyntax(node)
        }

        injectedViews.append(name)
        return DeclSyntax(newNode)
    }

    // MARK: - Inject into body
    private func injectTrackScreen(into node: StructDeclSyntax, viewName: String) -> StructDeclSyntax? {
        var didInject = false
        let newMembers = MemberBlockItemListSyntax(node.memberBlock.members.map { member in
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  let binding = varDecl.bindings.first(where: { $0.pattern.trimmedDescription == "body" }),
                  let accessorBlock = binding.accessorBlock
            else { return member }

            let stmts: [CodeBlockItemSyntax]
            switch accessorBlock.accessors {
            case .getter(let items):
                stmts = Array(items)
            case .accessors(let list):
                guard let getAccessor = list.first(where: {
                    $0.accessorSpecifier.tokenKind == .keyword(.get)
                }), let body = getAccessor.body else { return member }
                stmts = Array(body.statements)
            }

            let (newStmts, injected) = injectIntoStmts(stmts, viewName: viewName, currentDepth: 1)
            guard injected else { return member }
            didInject = true

            let newAccessorBlock: AccessorBlockSyntax
            switch accessorBlock.accessors {
            case .getter:
                newAccessorBlock = accessorBlock.with(\.accessors, .getter(CodeBlockItemListSyntax(newStmts)))
            case .accessors(let list):
                var newList = Array(list)
                guard let idx = newList.firstIndex(where: {
                    $0.accessorSpecifier.tokenKind == .keyword(.get)
                }), let body = newList[idx].body else { return member }
                let newBody = body.with(\.statements, CodeBlockItemListSyntax(newStmts))
                newList[idx] = newList[idx].with(\.body, newBody)
                newAccessorBlock = accessorBlock.with(\.accessors, .accessors(AccessorDeclListSyntax(newList)))
            }

            let newBinding = binding.with(\.accessorBlock, newAccessorBlock)
            let newBindings = PatternBindingListSyntax(varDecl.bindings.map {
                $0.pattern.trimmedDescription == "body" ? newBinding : $0
            })
            return member.with(\.decl, DeclSyntax(varDecl.with(\.bindings, newBindings)))
        })
        guard didInject else { return nil }
        return node.with(\.memberBlock, node.memberBlock.with(\.members, newMembers))
    }

    // MARK: - Core injection with depth
    // Returns (modifiedStmts, wasInjected)
    // Rules:
    //   - Direct view expression → inject, depth not consumed ✅
    //   - View container (VStack etc) → inject on container, depth not consumed ✅
    //   - Control flow (if/else, switch, guard, #if) → recurse into branches, depth consumed by 1
    //   - If currentDepth > injectionDepth → don't recurse into control flow → return false

    private func injectIntoStmts(
        _ stmts: [CodeBlockItemSyntax],
        viewName: String,
        currentDepth: Int
    ) -> ([CodeBlockItemSyntax], Bool) {
        var result = stmts
        var injected = false
        // Tracks whether a top-level expression stmt was already injected so earlier
        // side-effect calls (Void) are skipped. Return stmts and guard bodies are always
        // processed regardless — every return path needs tracking.
        var expressionDone = false

        // Statements after an explicit `return` are dead code — skip them.
        let firstReturnIdx = stmts.firstIndex(where: {
            if case .stmt(let s) = $0.item { return s.is(ReturnStmtSyntax.self) }
            return false
        })

        for (i, item) in stmts.enumerated().reversed() {
            if let ri = firstReturnIdx, i > ri { continue }

            switch item.item {

            // MARK: Expression
            case .expr(let expr):
                guard !expressionDone else { continue }

                // if/else as expression — control flow, costs 1 depth
                if let ifExpr = expr.as(IfExprSyntax.self) {
                    guard currentDepth < BTTConstants.injectionDepth else { break }
                    let (newIf, ok) = injectIntoIf(ifExpr, viewName: viewName, currentDepth: currentDepth + 1)
                    if ok {
                        result[i] = item.with(\.item, .expr(ExprSyntax(newIf)))
                        injected = true; expressionDone = true
                    }
                    continue
                }

                // switch as expression — control flow, costs 1 depth
                if let switchExpr = expr.as(SwitchExprSyntax.self) {
                    guard currentDepth < BTTConstants.injectionDepth else { break }
                    let (newSwitch, ok) = injectIntoSwitch(switchExpr, viewName: viewName, currentDepth: currentDepth + 1)
                    if ok {
                        result[i] = item.with(\.item, .expr(ExprSyntax(newSwitch)))
                        injected = true; expressionDone = true
                    }
                    continue
                }

                // Direct view expression — inject, no depth cost.
                // isFinalCandidate: true because reversed iteration guarantees this is the
                // last injectable expression in the scope — so a lowercase call must be a View.
                if let newExpr = appendTrackScreen(to: expr, viewName: viewName, isFinalCandidate: true) {
                    result[i] = item.with(\.item, .expr(newExpr))
                    injected = true; expressionDone = true
                }

            // MARK: Statement
            case .stmt(let stmt):

                // return — inject ALL returns unconditionally; every return path needs tracking.
                // Also set expressionDone so any preceding expression stmts (e.g. print calls)
                // are recognised as side effects and skipped.
                if let ret = stmt.as(ReturnStmtSyntax.self),
                   let expr = ret.expression,
                   let newExpr = appendTrackScreen(to: expr, viewName: viewName, isFinalCandidate: true) {
                    result[i] = item.with(\.item, .stmt(StmtSyntax(ret.with(\.expression, newExpr))))
                    injected = true; expressionDone = true

                // guard — inject guard body unconditionally alongside return injection
                } else if let guardStmt = stmt.as(GuardStmtSyntax.self) {
                    guard currentDepth < BTTConstants.injectionDepth else { break }
                    let (newBlock, ok) = injectIntoCodeBlock(guardStmt.body, viewName: viewName, currentDepth: currentDepth + 1)
                    if ok {
                        result[i] = item.with(\.item, .stmt(StmtSyntax(guardStmt.with(\.body, newBlock))))
                        injected = true
                    }

                // if/else wrapped in ExpressionStmtSyntax — skip if expression already injected
                } else if !expressionDone,
                          let exprStmt = stmt.as(ExpressionStmtSyntax.self),
                          let ifExpr = exprStmt.expression.as(IfExprSyntax.self) {
                    guard currentDepth < BTTConstants.injectionDepth else { break }
                    let (newIf, ok) = injectIntoIf(ifExpr, viewName: viewName, currentDepth: currentDepth + 1)
                    if ok {
                        result[i] = item.with(\.item, .stmt(StmtSyntax(exprStmt.with(\.expression, ExprSyntax(newIf)))))
                        injected = true; expressionDone = true
                    }

                // switch wrapped in ExpressionStmtSyntax — skip if expression already injected
                } else if !expressionDone,
                          let exprStmt = stmt.as(ExpressionStmtSyntax.self),
                          let switchExpr = exprStmt.expression.as(SwitchExprSyntax.self) {
                    guard currentDepth < BTTConstants.injectionDepth else { break }
                    let (newSwitch, ok) = injectIntoSwitch(switchExpr, viewName: viewName, currentDepth: currentDepth + 1)
                    if ok {
                        result[i] = item.with(\.item, .stmt(StmtSyntax(exprStmt.with(\.expression, ExprSyntax(newSwitch)))))
                        injected = true; expressionDone = true
                    }

                // bare if/else — skip if expression already injected
                } else if !expressionDone,
                          let ifExpr = stmt.as(IfExprSyntax.self) {
                    guard currentDepth < BTTConstants.injectionDepth else { break }
                    let (newIf, ok) = injectIntoIf(ifExpr, viewName: viewName, currentDepth: currentDepth + 1)
                    if ok {
                        result[i] = item.with(\.item, .stmt(StmtSyntax(ExpressionStmtSyntax(expression: ExprSyntax(newIf)))))
                        injected = true; expressionDone = true
                    }

                // bare switch — skip if expression already injected
                } else if !expressionDone,
                          let switchExpr = stmt.as(SwitchExprSyntax.self) {
                    guard currentDepth < BTTConstants.injectionDepth else { break }
                    let (newSwitch, ok) = injectIntoSwitch(switchExpr, viewName: viewName, currentDepth: currentDepth + 1)
                    if ok {
                        result[i] = item.with(\.item, .stmt(StmtSyntax(ExpressionStmtSyntax(expression: ExprSyntax(newSwitch)))))
                        injected = true; expressionDone = true
                    }
                }

            // MARK: Declaration — #if DEBUG
            case .decl(let decl):
                guard !expressionDone else { continue }
                if let ifConfig = decl.as(IfConfigDeclSyntax.self) {
                    guard currentDepth < BTTConstants.injectionDepth else { break }
                    let (newConfig, ok) = injectIntoIfConfig(ifConfig, viewName: viewName, currentDepth: currentDepth + 1)
                    if ok {
                        result[i] = item.with(\.item, .decl(DeclSyntax(newConfig)))
                        injected = true; expressionDone = true
                    }
                }

            @unknown default:
                break
            }
        }

        return (result, injected)
    }

    // MARK: - if/else

    private func injectIntoIf(
        _ node: IfExprSyntax,
        viewName: String,
        currentDepth: Int
    ) -> (IfExprSyntax, Bool) {
        var injected = false

        let (newBodyStmts, thenOk) = injectIntoStmts(Array(node.body.statements), viewName: viewName, currentDepth: currentDepth)
        let newBody = node.body.with(\.statements, CodeBlockItemListSyntax(newBodyStmts))
        if thenOk { injected = true }

        var newElse: IfExprSyntax.ElseBody? = node.elseBody
        switch node.elseBody {
        case .codeBlock(let block):
            let (newStmts, elseOk) = injectIntoStmts(Array(block.statements), viewName: viewName, currentDepth: currentDepth)
            newElse = .codeBlock(block.with(\.statements, CodeBlockItemListSyntax(newStmts)))
            if elseOk { injected = true }
        case .ifExpr(let nested):
            let (newNested, nestedOk) = injectIntoIf(nested, viewName: viewName, currentDepth: currentDepth)
            newElse = .ifExpr(newNested)
            if nestedOk { injected = true }
        case .none:
            break
        }

        let newNode = node.with(\.body, newBody).with(\.elseBody, newElse)
        return (newNode, injected)
    }

    private func injectIntoCodeBlock(
        _ block: CodeBlockSyntax,
        viewName: String,
        currentDepth: Int
    ) -> (CodeBlockSyntax, Bool) {
        let (newStmts, ok) = injectIntoStmts(Array(block.statements), viewName: viewName, currentDepth: currentDepth)
        return (block.with(\.statements, CodeBlockItemListSyntax(newStmts)), ok)
    }

    // MARK: - switch
    private func injectIntoSwitch(
        _ node: SwitchExprSyntax,
        viewName: String,
        currentDepth: Int
    ) -> (SwitchExprSyntax, Bool) {
        var injected = false
        let newCases = SwitchCaseListSyntax(node.cases.map { element -> SwitchCaseListSyntax.Element in
            guard case .switchCase(let switchCase) = element else { return element }
            let (newStmts, ok) = injectIntoStmts(Array(switchCase.statements), viewName: viewName, currentDepth: currentDepth)
            if ok { injected = true }
            return .switchCase(switchCase.with(\.statements, CodeBlockItemListSyntax(newStmts)))
        })
        return (node.with(\.cases, newCases), injected)
    }

    // MARK: - #if

    private func injectIntoIfConfig(
        _ node: IfConfigDeclSyntax,
        viewName: String,
        currentDepth: Int
    ) -> (IfConfigDeclSyntax, Bool) {
        var injected = false
        let newClauses = node.clauses.map { clause -> IfConfigClauseSyntax in
            guard let elements = clause.elements,
                  case .statements(let stmts) = elements
            else { return clause }
            let (newStmts, ok) = injectIntoStmts(Array(stmts), viewName: viewName, currentDepth: currentDepth)
            if ok { injected = true }
            return clause.with(\.elements, .statements(CodeBlockItemListSyntax(newStmts)))
        }
        return (node.with(\.clauses, IfConfigClauseListSyntax(newClauses)), injected)
    }

    // MARK: - Append .bttTrackScreen
    private func appendTrackScreen(to expr: ExprSyntax, viewName: String, isFinalCandidate: Bool = false) -> ExprSyntax? {
        guard !expr.description.contains(".\(BTTConstants.trackModifier)(") else { return nil }

        // Ternary — both branches, no depth cost (same level)
        if let ternary = expr.as(TernaryExprSyntax.self) {
            let newThen = appendTrackScreen(to: ternary.thenExpression, viewName: viewName, isFinalCandidate: true) ?? ternary.thenExpression
            let newElse = appendTrackScreen(to: ternary.elseExpression, viewName: viewName, isFinalCandidate: true) ?? ternary.elseExpression
            return ExprSyntax(ternary.with(\.thenExpression, newThen).with(\.elseExpression, newElse))
        }

        // withAnimation — inject inside closure, no depth cost
        if let call = expr.as(FunctionCallExprSyntax.self),
           let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           ref.baseName.text == "withAnimation",
           let closure = call.trailingClosure {
            let (newStmts, ok) = injectIntoStmts(Array(closure.statements), viewName: viewName, currentDepth: BTTConstants.injectionDepth)
            guard ok else { return nil }
            let newClosure = closure.with(\.statements, CodeBlockItemListSyntax(newStmts))
            return ExprSyntax(call.with(\.trailingClosure, newClosure))
        }

        // SequenceExprSyntax — ternary whose condition uses an operator (e.g. `state == 0 ? ... : ...`).
        // SwiftSyntax represents these as a flat sequence with UnresolvedTernaryExprSyntax elements
        // for each `? then :` branch. Inject into every then-expression and the final else element.
        if let seqExpr = expr.as(SequenceExprSyntax.self) {
            var elements = Array(seqExpr.elements)
            var changed = false
            for (i, element) in elements.enumerated() {
                if let ut = element.as(UnresolvedTernaryExprSyntax.self),
                   let newThen = appendTrackScreen(to: ut.thenExpression, viewName: viewName, isFinalCandidate: true) {
                    elements[i] = ExprSyntax(ut.with(\.thenExpression, newThen))
                    changed = true
                }
            }
            // Last element is the final else branch
            let lastIdx = elements.count - 1
            if let newLast = appendTrackScreen(to: elements[lastIdx], viewName: viewName, isFinalCandidate: true) {
                elements[lastIdx] = newLast
                changed = true
            }
            guard changed else { return nil }
            return ExprSyntax(seqExpr.with(\.elements, ExprListSyntax(elements)))
        }

        // AnyView(...) — inject inside the argument to preserve AnyView as the return type.
        // Injecting outside would change the return type to an opaque modifier type,
        // breaking bodies that mix AnyView returns across branches (e.g. guard/else).
        if let call = expr.as(FunctionCallExprSyntax.self),
           let ref = call.calledExpression.as(DeclReferenceExprSyntax.self),
           ref.baseName.text == "AnyView",
           let firstArg = call.arguments.first {
            guard let newArgExpr = appendTrackScreen(to: firstArg.expression, viewName: viewName, isFinalCandidate: true) else { return nil }
            let newArg = firstArg.with(\.expression, newArgExpr)
            let newArgs = LabeledExprListSyntax([newArg])
            return ExprSyntax(call.with(\.arguments, newArgs))
        }

        guard isViewExpression(expr, isFinalCandidate: isFinalCandidate) else { return nil }

        let indent = lastModifierIndent(of: expr) ?? extractIndent(from: expr.leadingTrivia)

        let modifier = MemberAccessExprSyntax(
            base: expr.with(\.trailingTrivia, []),
            period: .periodToken(leadingTrivia: .newline + indent),
            declName: DeclReferenceExprSyntax(baseName: .identifier(BTTConstants.trackModifier))
        )
        let selfDotSelf = MemberAccessExprSyntax(
            base: ExprSyntax(DeclReferenceExprSyntax(baseName: .keyword(.Self))),
            period: .periodToken(),
            declName: DeclReferenceExprSyntax(baseName: .keyword(.self))
        )
        let arg = LabeledExprSyntax(
            expression: StringLiteralExprSyntax(
                openingQuote: .stringQuoteToken(),
                segments: StringLiteralSegmentListSyntax([
                    .expressionSegment(ExpressionSegmentSyntax(
                        backslash: .backslashToken(),
                        leftParen: .leftParenToken(),
                        expressions: LabeledExprListSyntax([
                            LabeledExprSyntax(expression: ExprSyntax(selfDotSelf))
                        ]),
                        rightParen: .rightParenToken()
                    ))
                ]),
                closingQuote: .stringQuoteToken()
            )
        )
        let call = FunctionCallExprSyntax(
            calledExpression: ExprSyntax(modifier),
            leftParen: .leftParenToken(),
            arguments: LabeledExprListSyntax([arg]),
            rightParen: .rightParenToken(trailingTrivia: expr.trailingTrivia)
        )
        return ExprSyntax(call)
    }

    // MARK: - isViewExpression
    private func isViewExpression(_ expr: ExprSyntax, isFinalCandidate: Bool = false) -> Bool {
        if let ref = expr.as(DeclReferenceExprSyntax.self),
           ref.baseName.text.hasPrefix("$") { return false }

        if expr.is(TupleExprSyntax.self)          { return false }
        if expr.is(StringLiteralExprSyntax.self)  { return false }
        if expr.is(IntegerLiteralExprSyntax.self) { return false }
        if expr.is(FloatLiteralExprSyntax.self)   { return false }
        if expr.is(BooleanLiteralExprSyntax.self) { return false }
        if expr.is(AsExprSyntax.self)             { return false }

        if let tryExpr = expr.as(TryExprSyntax.self),
           tryExpr.questionOrExclamationMark?.tokenKind == .postfixQuestionMark { return false }

        // For function calls we cannot know the return type without the compiler's type checker.
        // We use two reliable AST signals plus one contextual one:
        //   • Uppercase first letter  →  View type constructor (Text, VStack, MyCard)
        //   • Callee is a member access  →  already a View with modifier chain (.padding() etc.)
        //   • isFinalCandidate  →  sole/last expression in its scope, so the compiler already
        //     guarantees it returns a View (a Void call here is already a compile error in the
        //     user's own code). Safe to inject on lowercase calls like myView().
        if let call = expr.as(FunctionCallExprSyntax.self) {
            if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self) {
                return ref.baseName.text.first?.isUppercase == true || isFinalCandidate
            }
            return call.calledExpression.is(MemberAccessExprSyntax.self)
        }

        if expr.is(MemberAccessExprSyntax.self)   { return true }
        if expr.is(DeclReferenceExprSyntax.self)  { return true }
        if expr.is(TryExprSyntax.self)            { return true }
        if expr.is(ForceUnwrapExprSyntax.self)    { return true }

        return false
    }

    // MARK: - Indent helpers
    private func extractIndent(from trivia: Trivia) -> Trivia {
        var indentPieces: [TriviaPiece] = []
        var afterNewline = false
        for piece in trivia.pieces {
            switch piece {
            case .newlines, .carriageReturnLineFeeds, .carriageReturns:
                afterNewline = true
                indentPieces = []
            case .spaces, .tabs:
                if afterNewline { indentPieces.append(piece) }
            default:
                break
            }
        }
        return indentPieces.isEmpty ? .spaces(8) : Trivia(pieces: indentPieces)
    }

    private func lastModifierIndent(of expr: ExprSyntax) -> Trivia? {
        if let call = expr.as(FunctionCallExprSyntax.self),
           let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            let indent = extractIndent(from: member.period.leadingTrivia)
            if !indent.isEmpty { return indent }
            if let base = member.base { return lastModifierIndent(of: base) }
        }
        return nil
    }

    // MARK: - Helpers
    private func conformsToView(_ node: StructDeclSyntax) -> Bool {
        node.inheritanceClause?.inheritedTypes.contains {
            $0.type.trimmedDescription == "View"
        } ?? false
    }

    private func bodyMember(in node: StructDeclSyntax) -> VariableDeclSyntax? {
        for member in node.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  varDecl.bindings.contains(where: { $0.pattern.trimmedDescription == "body" })
            else { continue }
            return varDecl
        }
        return nil
    }

    private func bodyReturnsOpaqueView(_ varDecl: VariableDeclSyntax) -> Bool {
        guard let binding = varDecl.bindings.first(where: { $0.pattern.trimmedDescription == "body" }),
              let typeAnnotation = binding.typeAnnotation
        else { return true }
        let typeText = typeAnnotation.type.trimmedDescription
        return typeText == "some View" || typeText == "any View"
    }
}

extension Trivia {
    var hasIgnore: Bool {
        contains {
            guard case .lineComment(let t) = $0 else { return false }
            return t.range(of: BTTConstants.ignorePattern, options: .regularExpression) != nil
        }
    }
}
