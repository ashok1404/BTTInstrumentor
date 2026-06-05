//
//  BTTRewriter.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

import SwiftSyntax
import SwiftParser
import SwiftSyntaxBuilder

final class BTTRewriter: SyntaxRewriter {

    var injectedCount = 0

    // Source file level — add import BlueTriangle after import SwiftUI
    override func visit(_ node: SourceFileSyntax) -> SourceFileSyntax {
        // First let super visit all children (including structs)
        let visited = super.visit(node)

        // Then add import BlueTriangle if needed
        guard injectedCount > 0 else { return visited }

        guard !visited.statements.contains(where: { stmt in
            guard let d = stmt.item.as(ImportDeclSyntax.self) else { return false }
            return d.path.trimmedDescription == "BlueTriangle"
        }) else { return visited }

        let bttImport = ImportDeclSyntax(
            leadingTrivia: .newline,
            importKeyword: .keyword(.import, trailingTrivia: .space),
            path: ImportPathComponentListSyntax([
                ImportPathComponentSyntax(name: .identifier("BlueTriangle"))
            ])
        )

        var statements = Array(visited.statements)
        guard let swiftUIInt = statements.firstIndex(where: { stmt in
            guard let d = stmt.item.as(ImportDeclSyntax.self) else { return false }
            return d.path.trimmedDescription == "SwiftUI"
        }) else { return visited }

        statements.insert(
            CodeBlockItemSyntax(item: .decl(DeclSyntax(bttImport))),
            at: swiftUIInt + 1
        )
        return visited.with(\.statements, CodeBlockItemListSyntax(statements))
    }

    // Struct level — add @BTTTrack above View structs
    override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
        guard conformsToView(node) else { return DeclSyntax(node) }
        guard hasBodyProperty(node) else { return DeclSyntax(node) }
        guard !hasAttribute("BTTTrack", in: node) else { return DeclSyntax(node) }
        guard !hasBTTIgnore(node) else { return DeclSyntax(node) }

        let attrSyntax = AttributeSyntax(
            atSign: .atSignToken(),
            attributeName: IdentifierTypeSyntax(name: .identifier("BTTTrack")),
            trailingTrivia: .newline
        )

        let leadingTrivia = node.leadingTrivia
        let strippedNode = node.with(\.leadingTrivia, .spaces(0))
        let attrWithTrivia = attrSyntax.with(\.leadingTrivia, leadingTrivia)
        let newAttr = AttributeListSyntax([.attribute(attrWithTrivia)])
        var modified = strippedNode

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
        node.leadingTrivia.description.contains("btt:ignore")
    }
}
