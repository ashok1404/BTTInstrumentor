//
//  BTTRevertRewriter.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 09/06/26.
//

import SwiftSyntax
import SwiftParser

/// Removes all BTT injection artifacts from a Swift source file:
/// - `import BTTSwiftUITracker`
/// - `@BTTTrack` attributes on structs
final class BTTRevertRewriter: SyntaxRewriter {

    // MARK: - State

    var removedCount = 0

    // MARK: - Source file — remove import BTTSwiftUITracker

    override func visit(_ node: SourceFileSyntax) -> SourceFileSyntax {
        let visited  = super.visit(node)
        let filtered = visited.statements.filter { stmt in
            guard let d = stmt.item.as(ImportDeclSyntax.self) else { return true }
            return d.path.trimmedDescription != BTTConstants.importModule
        }
        guard filtered.count != visited.statements.count else { return visited }
        removedCount += 1
        return visited.with(\.statements, filtered)
    }

    // MARK: - Struct — remove @BTTTrack

    override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
        guard node.attributes.contains(where: { attr in
            guard case .attribute(let a) = attr else { return false }
            return a.attributeName.trimmedDescription == BTTConstants.trackAttribute
        }) else { return DeclSyntax(node) }

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

        removedCount += 1
        return DeclSyntax(modified)
    }
}
