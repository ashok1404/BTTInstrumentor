//
//  BTTInjectRewriter.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

import SwiftSyntax
import SwiftParser
import SwiftSyntaxBuilder

final class BTTInjectRewriter: SyntaxRewriter {
    var injectedViews = Set<String>()

    override func visit(_ node: SourceFileSyntax) -> SourceFileSyntax {
        let visited = super.visit(node)
        guard injectedViews.count > 0 else {
            return visited
        }

        // Skip if import already present
        let alreadyImported = visited.statements.contains(where: { stmt in
            guard let d = stmt.item.as(ImportDeclSyntax.self) else { return false }
            return d.path.trimmedDescription == BTTConstants.importModule
        })
        if alreadyImported {
            return visited
        }

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
        }) else {
            return visited
        }

        statements.insert(
            CodeBlockItemSyntax(item: .decl(DeclSyntax(bttImport))),
            at: swiftUIIdx + 1
        )
        return visited.with(\.statements, CodeBlockItemListSyntax(statements))
    }

    override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
        let name = node.name.text

        guard conformsToView(node) else {
            return DeclSyntax(node)
        }
        guard hasBodyProperty(node) else {
            return DeclSyntax(node)
        }
        if hasAttribute(BTTConstants.trackAttribute, in: node) {
            return DeclSyntax(node)
        }

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

        injectedViews.insert(name)
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
}
