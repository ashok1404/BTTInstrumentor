//
//  BTTInjector.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

#if os(macOS)
import Foundation
import SwiftSyntax
import SwiftParser
import SwiftDiagnostics
import SwiftParserDiagnostics

/// Injects and reverts `@BTTTrack` instrumentation in Swift source files.
final class BTTInjector {
    // MARK: - Inject
    @discardableResult
    func inject(file path: String) -> Bool {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        let tree = Parser.parse(source: source)

        // Skip files that already have parse errors
        guard ParseDiagnosticsGenerator.diagnostics(for: tree).isEmpty else { return false }

        let rewriter = BTTRewriter()
        guard let newTree = rewriter.visit(tree).as(SourceFileSyntax.self) else { return false }
        guard rewriter.injectedCount > 0 else { return false }

        let result = newTree.description
        guard result != source else { return false }

        // Validate output before writing
        let outputDiags = ParseDiagnosticsGenerator.diagnostics(for: Parser.parse(source: result))
        guard outputDiags.isEmpty else {
            BTTLog.warn("Injection skipped — parse error in \(URL(fileURLWithPath: path).lastPathComponent)")
            return false
        }

        try? result.write(toFile: path, atomically: true, encoding: .utf8)
        return true
    }

    // MARK: - Revert
    @discardableResult
    func revert(file path: String) -> Bool {
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
}

#endif
