//
//  BTTRevertRewriter.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 09/06/26.
//

import SwiftSyntax
import SwiftParser

final class BTTRevertRewriter: SyntaxRewriter {
    var revertedViews = Set<String>()

    // MARK: - Struct — remove .bttTrackScreen from body
    override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
        let name = node.name.text
        guard bodyHasTrackScreen(node) else { return DeclSyntax(node) }
        guard !node.leadingTrivia.hasIgnore else { return DeclSyntax(node) }

        let newMembers = MemberBlockItemListSyntax(node.memberBlock.members.map { member in
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  let binding = varDecl.bindings.first(where: { $0.pattern.trimmedDescription == "body" }),
                  let accessorBlock = binding.accessorBlock
            else { return member }

            let stmts: [CodeBlockItemSyntax]
            switch accessorBlock.accessors {
            case .getter(let items): stmts = Array(items)
            case .accessors(let list):
                guard let getAccessor = list.first(where: {
                    $0.accessorSpecifier.tokenKind == .keyword(.get)
                }), let body = getAccessor.body else { return member }
                stmts = Array(body.statements)
            }

            let newStmts = revertStmts(stmts)

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

        let modified = node.with(\.memberBlock, node.memberBlock.with(\.members, newMembers))

        // If auto-inject can't handle this struct after revert, the .bttTrackScreen() is manual — preserve it
        let testInjector = BTTInjectRewriter()
        _ = testInjector.visit(modified)
        guard !testInjector.injectedViews.isEmpty else { return DeclSyntax(node) }

        revertedViews.insert(name)
        return DeclSyntax(modified)
    }

    // MARK: - Statement list revert

    private func revertStmts(_ stmts: [CodeBlockItemSyntax]) -> [CodeBlockItemSyntax] {
        stmts.map { revertItem($0) }
    }

    private func revertItem(_ item: CodeBlockItemSyntax) -> CodeBlockItemSyntax {
        switch item.item {
        case .expr(let expr):
            if let ifExpr = expr.as(IfExprSyntax.self) {
                return item.with(\.item, .expr(ExprSyntax(revertIf(ifExpr))))
            }
            return item.with(\.item, .expr(stripTrackScreen(from: expr)))
        case .stmt(let stmt):
            if let newStmt = revertStatement(stmt) {
                return item.with(\.item, .stmt(newStmt))
            }
            return item
        case .decl(let decl):
            if let ifConfig = decl.as(IfConfigDeclSyntax.self) {
                return item.with(\.item, .decl(DeclSyntax(revertIfConfig(ifConfig))))
            }
            return item
        @unknown default:
            return item
        }
    }

    // MARK: - Statement revert

    private func revertStatement(_ stmt: StmtSyntax) -> StmtSyntax? {
        // return
        if let ret = stmt.as(ReturnStmtSyntax.self), let expr = ret.expression {
            return StmtSyntax(ret.with(\.expression, stripTrackScreen(from: expr)))
        }
        // guard
        if let guardStmt = stmt.as(GuardStmtSyntax.self) {
            return StmtSyntax(guardStmt.with(\.body, revertCodeBlock(guardStmt.body)))
        }
        // if/else
        if let exprStmt = stmt.as(ExpressionStmtSyntax.self),
           let ifExpr = exprStmt.expression.as(IfExprSyntax.self) {
            let newIf = revertIf(ifExpr)
            return StmtSyntax(exprStmt.with(\.expression, ExprSyntax(newIf)))
        }
        if let ifStmt = stmt.as(IfExprSyntax.self) {
            let newIf = revertIf(ifStmt)
            return StmtSyntax(ExpressionStmtSyntax(expression: ExprSyntax(newIf)))
        }
        // switch
        if let exprStmt = stmt.as(ExpressionStmtSyntax.self),
           let switchStmt = exprStmt.expression.as(SwitchExprSyntax.self) {
            return StmtSyntax(exprStmt.with(\.expression, ExprSyntax(revertSwitch(switchStmt))))
        }
        if let switchStmt = stmt.as(SwitchExprSyntax.self) {
            return StmtSyntax(ExpressionStmtSyntax(expression: ExprSyntax(revertSwitch(switchStmt))))
        }
        return nil
    }

    // MARK: - if/else revert
    private func revertIf(_ node: IfExprSyntax) -> IfExprSyntax {
        let newBody = revertCodeBlock(node.body)
        let newElse: IfExprSyntax.ElseBody?
        switch node.elseBody {
        case .codeBlock(let block): newElse = .codeBlock(revertCodeBlock(block))
        case .ifExpr(let nested):   newElse = .ifExpr(revertIf(nested))
        case .none:                 newElse = nil
        }
        return node.with(\.body, newBody).with(\.elseBody, newElse)
    }

    private func revertCodeBlock(_ block: CodeBlockSyntax) -> CodeBlockSyntax {
        block.with(\.statements, CodeBlockItemListSyntax(revertStmts(Array(block.statements))))
    }

    // MARK: - switch revert
    private func revertSwitch(_ node: SwitchExprSyntax) -> SwitchExprSyntax {
        let newCases = SwitchCaseListSyntax(node.cases.map { element -> SwitchCaseListSyntax.Element in
            guard case .switchCase(let switchCase) = element else { return element }
            return .switchCase(switchCase.with(\.statements, CodeBlockItemListSyntax(revertStmts(Array(switchCase.statements)))))
        })
        return node.with(\.cases, newCases)
    }

    // MARK: - #if revert
    private func revertIfConfig(_ node: IfConfigDeclSyntax) -> IfConfigDeclSyntax {
        let newClauses = node.clauses.map { clause -> IfConfigClauseSyntax in
            guard let elements = clause.elements,
                  case .statements(let stmts) = elements
            else { return clause }
            return clause.with(\.elements, .statements(CodeBlockItemListSyntax(revertStmts(Array(stmts)))))
        }
        return node.with(\.clauses, IfConfigClauseListSyntax(newClauses))
    }

    // MARK: - Strip .bttTrackScreen from expression
    private func stripTrackScreen(from expr: ExprSyntax) -> ExprSyntax {
        // Ternary — strip from both branches
        if let ternary = expr.as(TernaryExprSyntax.self) {
            return ExprSyntax(ternary
                .with(\.thenExpression, stripTrackScreen(from: ternary.thenExpression))
                .with(\.elseExpression, stripTrackScreen(from: ternary.elseExpression))
            )
        }

        // SequenceExprSyntax — ternary with complex condition (e.g. state == 0 ? ... : ...)
        // Strip from each UnresolvedTernaryExprSyntax.thenExpression and the final else element.
        if let seqExpr = expr.as(SequenceExprSyntax.self) {
            var elements = Array(seqExpr.elements)
            var changed = false
            for (i, element) in elements.enumerated() {
                if let ut = element.as(UnresolvedTernaryExprSyntax.self) {
                    let newThen = stripTrackScreen(from: ut.thenExpression)
                    if newThen.description != ut.thenExpression.description {
                        elements[i] = ExprSyntax(ut.with(\.thenExpression, newThen))
                        changed = true
                    }
                }
            }
            let lastIdx = elements.count - 1
            let newLast = stripTrackScreen(from: elements[lastIdx])
            if newLast.description != elements[lastIdx].description {
                elements[lastIdx] = newLast
                changed = true
            }
            if changed {
                return ExprSyntax(seqExpr.with(\.elements, ExprListSyntax(elements)))
            }
        }

        // Any FunctionCallExpr — strip .bttTrackScreen from trailing closures and labeled args
        if let call = expr.as(FunctionCallExprSyntax.self) {
            var newCall = call

            // Strip from labeled arguments (e.g. AnyView(Text(...).bttTrackScreen(...)))
            if !call.arguments.isEmpty {
                let newArgs = LabeledExprListSyntax(call.arguments.map { arg in
                    arg.with(\.expression, stripTrackScreen(from: arg.expression))
                })
                newCall = newCall.with(\.arguments, newArgs)
            }

            // Strip from trailing closure
            if let closure = call.trailingClosure {
                let newStmts = revertStmts(Array(closure.statements))
                let newClosure = closure.with(\.statements, CodeBlockItemListSyntax(newStmts))
                newCall = newCall.with(\.trailingClosure, newClosure)
            }

            // Strip from additional trailing closures
            if !call.additionalTrailingClosures.isEmpty {
                let newClosures = call.additionalTrailingClosures.map { element -> MultipleTrailingClosureElementSyntax in
                    let newStmts = revertStmts(Array(element.closure.statements))
                    let newClosure = element.closure.with(\.statements, CodeBlockItemListSyntax(newStmts))
                    return element.with(\.closure, newClosure)
                }
                newCall = newCall.with(\.additionalTrailingClosures, MultipleTrailingClosureElementListSyntax(newClosures))
            }

            // Check if this call itself is .bttTrackScreen — strip it
            if let member = newCall.calledExpression.as(MemberAccessExprSyntax.self),
               member.declName.baseName.text == BTTConstants.trackModifier,
               let base = member.base {
                return base.with(\.trailingTrivia, expr.trailingTrivia)
            }

            // Return with cleaned args/closures if anything changed
            if newCall.description != call.description {
                return ExprSyntax(newCall)
            }
        }

        return expr
    }

    // MARK: - Helpers
    private func bodyHasTrackScreen(_ node: StructDeclSyntax) -> Bool {
        node.memberBlock.members.contains { member in
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                  varDecl.bindings.contains(where: { $0.pattern.trimmedDescription == "body" })
            else { return false }
            return varDecl.description.contains(".\(BTTConstants.trackModifier)(")
        }
    }
}
