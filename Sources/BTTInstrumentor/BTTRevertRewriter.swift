//
//  BTTRemove.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 09/06/26.
//


import SwiftSyntax
import SwiftParser

// MARK: - Entry point

func revertInjectedFile(_ path: String) -> Bool {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
    let tree     = Parser.parse(source: source)
    let rewriter = BTTRevertRewriter()
    guard let newTree = rewriter.visit(tree).as(SourceFileSyntax.self) else { return false }
    guard rewriter.removedCount > 0 else { return false }
    let result = newTree.description
    guard result != source else { return false }
    try? result.write(toFile: path, atomically: true, encoding: .utf8)
    return true
}

// MARK: - Rewriter
private final class BTTRevertRewriter: SyntaxRewriter {

    var removedCount = 0

    // Remove import BTTSwiftUITracker
    override func visit(_ node: SourceFileSyntax) -> SourceFileSyntax {
        let visited  = super.visit(node)
        let filtered = visited.statements.filter { stmt in
            guard let d = stmt.item.as(ImportDeclSyntax.self) else { return true }
            return d.path.trimmedDescription != "BTTSwiftUITracker"
        }
        guard filtered.count != visited.statements.count else { return visited }
        removedCount += 1
        return visited.with(\.statements, filtered)
    }

    // Remove @BTTTrack from structs
    override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
        guard node.attributes.contains(where: { attr in
            guard case .attribute(let a) = attr else { return false }
            return a.attributeName.trimmedDescription == "BTTTrack"
        }) else { return DeclSyntax(node) }

        let filtered = node.attributes.filter { attr in
            guard case .attribute(let a) = attr else { return true }
            return a.attributeName.trimmedDescription != "BTTTrack"
        }

        // Restore original leading trivia that was on @BTTTrack onto the struct keyword
        let originalTrivia = node.attributes.first.flatMap { attr -> Trivia? in
            guard case .attribute(let a) = attr,
                  a.attributeName.trimmedDescription == "BTTTrack"
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
