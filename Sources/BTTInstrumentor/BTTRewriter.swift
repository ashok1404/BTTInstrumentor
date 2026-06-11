//
//  BTTRewriter.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

import SwiftSyntax
import SwiftParser
import SwiftSyntaxBuilder

/// Injects `@BTTTrack` above every SwiftUI `View`.
/// Also inserts `import BTTSwiftUITracker` after `import SwiftUI` when at least one
/// struct was instrumented.
final class BTTRewriter: SyntaxRewriter {
    var injectedCount = 0

    override func visit(_ node: SourceFileSyntax) -> SourceFileSyntax {
        // Visit children first so injectedCount is accurate before we add the import
        let visited = super.visit(node)

        BTTLog.verbose("  BTTRewriter.visit(SourceFileSyntax) — injectedCount after child visit: \(injectedCount)")

        guard injectedCount > 0 else {
            BTTLog.verbose("  No Views injected — skipping import insertion.")
            return visited
        }

        // Skip if import already present
        let alreadyImported = visited.statements.contains(where: { stmt in
            guard let d = stmt.item.as(ImportDeclSyntax.self) else { return false }
            return d.path.trimmedDescription == BTTConstants.importModule
        })
        if alreadyImported {
            BTTLog.verbose("  import \(BTTConstants.importModule) already present — skipping insertion.")
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
            BTTLog.verbose("  import SwiftUI not found — cannot insert import \(BTTConstants.importModule).")
            return visited
        }

        BTTLog.verbose("  Inserting import \(BTTConstants.importModule) after import SwiftUI at index \(swiftUIIdx).")
        statements.insert(
            CodeBlockItemSyntax(item: .decl(DeclSyntax(bttImport))),
            at: swiftUIIdx + 1
        )
        return visited.with(\.statements, CodeBlockItemListSyntax(statements))
    }

    override func visit(_ node: StructDeclSyntax) -> DeclSyntax {
        let name = node.name.text

        guard conformsToView(node) else {
            BTTLog.verbose("    '\(name)': does not conform to View — skip")
            return DeclSyntax(node)
        }
        guard hasBodyProperty(node) else {
            BTTLog.verbose("    '\(name)': conforms to View but no 'body' property — skip (likely protocol extension)")
            return DeclSyntax(node)
        }
        if hasAttribute(BTTConstants.trackAttribute, in: node) {
            BTTLog.verbose("    '\(name)': already has @\(BTTConstants.trackAttribute) — skip")
            return DeclSyntax(node)
        }
        if hasBTTIgnore(node) {
            BTTLog.verbose("    '\(name)': has // \(BTTConstants.ignoreComment) — skip")
            return DeclSyntax(node)
        }

        BTTLog.verbose("    '\(name)': injecting @\(BTTConstants.trackAttribute) ✓")

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
