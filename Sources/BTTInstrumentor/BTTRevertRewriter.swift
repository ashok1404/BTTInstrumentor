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
    var removedCount = 0

    // MARK: - Source file — remove import BTTSwiftUITracker

    override func visit(_ node: SourceFileSyntax) -> SourceFileSyntax {
        let visited  = super.visit(node)
        let before   = visited.statements.count
        let filtered = visited.statements.filter { stmt in
            guard let d = stmt.item.as(ImportDeclSyntax.self) else { return true }
            let isImportBTT = d.path.trimmedDescription == BTTConstants.importModule
            if isImportBTT {
                BTTLog.verbose("  Removing import \(BTTConstants.importModule)")
            }
            return !isImportBTT
        }

        guard filtered.count != before else {
            BTTLog.verbose("  visit(SourceFileSyntax) — no import \(BTTConstants.importModule) found")
            return visited
        }

        BTTLog.verbose("  visit(SourceFileSyntax) — removed import statement (statements: \(before) → \(filtered.count))")
        removedCount += 1
        return visited.with(\.statements, filtered)
    }

    // MARK: - Struct — remove @BTTTrack

    override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
        let name = node.name.text

        guard node.attributes.contains(where: { attr in
            guard case .attribute(let a) = attr else { return false }
            return a.attributeName.trimmedDescription == BTTConstants.trackAttribute
        }) else {
            BTTLog.verbose("  Struct '\(name)': no @\(BTTConstants.trackAttribute) — skip")
            return DeclSyntax(node)
        }

        BTTLog.verbose("  Struct '\(name)': removing @\(BTTConstants.trackAttribute) ✓")

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
