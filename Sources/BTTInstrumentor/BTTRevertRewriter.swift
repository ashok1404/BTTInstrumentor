//
//  BTTRevertRewriter.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 09/06/26.
//

import SwiftSyntax
import SwiftParser

final class BTTRevertRewriter: SyntaxRewriter {
    var revertedViews =  Set<String>()

    override func visit(_ node: SourceFileSyntax) -> SourceFileSyntax {
        let visited  = super.visit(node)
        let before   = visited.statements.count
        let filtered = visited.statements.filter { stmt in
            guard let d = stmt.item.as(ImportDeclSyntax.self) else { return true }
            let isImportBTT = d.path.trimmedDescription == BTTConstants.importModule
            return !isImportBTT
        }

        guard filtered.count != before else {
            return visited
        }

        return visited.with(\.statements, filtered)
    }

    // MARK: - Struct — remove @BTTTrack
    override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
        let name = node.name.text

        guard node.attributes.contains(where: { attr in
            guard case .attribute(let a) = attr else { return false }
            return a.attributeName.trimmedDescription == BTTConstants.trackAttribute
        }) else {
            return DeclSyntax(node)
        }

        let filtered = node.attributes.filter { attr in
            guard case .attribute(let a) = attr else { return true }
            return a.attributeName.trimmedDescription != BTTConstants.trackAttribute
        }

        // Restore the leading trivia that was originally on @BTTTrack onto the struct keyword
        let originalTrivia = node.attributes.first.flatMap { attr -> Trivia? in
            guard case .attribute(let a) = attr,
                  a.attributeName.trimmedDescription == BTTConstants.trackAttribute
            else { return nil }
            return a.leadingTrivia
        } ?? node.leadingTrivia

        let modified = node
            .with(\.attributes, filtered)
            .with(\.leadingTrivia, originalTrivia)

        revertedViews.insert(name)
        return DeclSyntax(modified)
    }
}
