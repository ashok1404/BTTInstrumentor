//
//  BTTRewriter.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

import SwiftSyntax
import SwiftParser
import SwiftSyntaxBuilder

/// injects `@BTTTrack` above every SwiftUI `View
/// Also inserts `import BTTSwiftUITracker` after `import SwiftUI` when at least one
final class BTTRewriter: SyntaxRewriter {

    // MARK: - State
    var injectedCount = 0
    // MARK: - Source file

    override func visit(_ node: SourceFileSyntax) -> SourceFileSyntax {
        // Visit children first so injectedCount is accurate before we add the import
        let visited = super.visit(node)
        guard injectedCount > 0 else { return visited }

        // Skip if import already present
        guard !visited.statements.contains(where: { stmt in
            guard let d = stmt.item.as(ImportDeclSyntax.self) else { return false }
            return d.path.trimmedDescription == BTTConstants.importModule
        }) else { return visited }

        let bttImport = ImportDeclSyntax(
            leadingTrivia: .newline,
            importKeyword: .keyword(.import, trailingTrivia: .space),
            path: ImportPathComponentListSyntax([
                ImportPathComponentSyntax(name: .identifier(BTTConstants.importModule))
            ])
        )

        var statements = Array(visited.statements)
        guard let swiftUIIdx = statements.firstIndex(where: { stmt in
            guard let d = stmt.item.as(ImportDeclSyntax.self) else { return false }
            return d.path.trimmedDescription == "SwiftUI"
        }) else { return visited }

        statements.insert(
            CodeBlockItemSyntax(item: .decl(DeclSyntax(bttImport))),
            at: swiftUIIdx + 1
        )
        return visited.with(\.statements, CodeBlockItemListSyntax(statements))
    }

    // MARK: - Struct

    override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
        guard conformsToView(node)                    else { return DeclSyntax(node) }
        guard hasBodyProperty(node)                   else { return DeclSyntax(node) }
        guard !hasAttribute(BTTConstants.trackAttribute, in: node) else { return DeclSyntax(node) }
        guard !hasBTTIgnore(node)                     else { return DeclSyntax(node) }

        let attrSyntax = AttributeSyntax(
            atSign: .atSignToken(),
            attributeName: IdentifierTypeSyntax(name: .identifier(BTTConstants.trackAttribute)),
            trailingTrivia: .newline
        )

        let leadingTrivia  = node.leadingTrivia
        let strippedNode   = node.with(\.leadingTrivia, .spaces(0))
        let attrWithTrivia = attrSyntax.with(\.leadingTrivia, leadingTrivia)
        let newAttr        = AttributeListSyntax([.attribute(attrWithTrivia)])
        var modified       = strippedNode

        if node.attributes.isEmpty {
            modified = strippedNode.with(\.attributes, newAttr)
        } else {
            var combined = newAttr
            combined.append(contentsOf: strippedNode.attributes)
            modified = strippedNode.with(\.attributes, combined)
        }

        injectedCount += 1
        return DeclSyntax(modified)
    }

    // MARK: - Private

    private func conformsToView(_ node: StructDeclSyntax) -> Bool {
        node.inheritanceClause?.inheritedTypes.contains {
            $0.type.trimmedDescription == "View"
        } ?? false
    }

    private func hasBodyProperty(_ node: StructDeclSyntax) -> Bool {
        node.memberBlock.members.contains { member in
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { return false }
            return varDecl.bindings.contains { $0.pattern.trimmedDescription == "body" }
        }
    }

    private func hasAttribute(_ name: String, in node: StructDeclSyntax) -> Bool {
        node.attributes.contains { attr in
            guard case .attribute(let a) = attr else { return false }
            return a.attributeName.trimmedDescription == name
        }
    }

    private func hasBTTIgnore(_ node: StructDeclSyntax) -> Bool {
        node.leadingTrivia.description.contains(BTTConstants.ignoreComment)
    }
}
