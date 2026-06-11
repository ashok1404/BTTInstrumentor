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
final class BTTInjectRevertHandler {

    @discardableResult
    func inject(file path: String) -> Int {
        let fileName = URL(fileURLWithPath: path).lastPathComponent

        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            BTTLog.error("  ✗ Could not read file: \(path)")
            return 0
        }
        
        let tree = Parser.parse(source: source)

        // Skip files that already have parse errors
        let inputDiags = ParseDiagnosticsGenerator.diagnostics(for: tree)
        if !inputDiags.isEmpty {
            BTTLog.error("  ✗ Skipping — \(inputDiags.count) parse error(s) in source:")
            inputDiags.forEach { BTTLog.error("    \($0.message)") }
            return 0
        }

        let rewriter = BTTRewriter()
        guard let newTree = rewriter.visit(tree).as(SourceFileSyntax.self) else {
            BTTLog.verbose("  ✗ Rewriter returned unexpected node type")
            return 0
        }

        guard rewriter.injectedViews.count > 0 else {
            return 0
        }

        let result = newTree.description
        guard result != source else {
            return 0
        }

        // Validate output before writing
        let outputTree  = Parser.parse(source: result)
        let outputDiags = ParseDiagnosticsGenerator.diagnostics(for: outputTree)
        if !outputDiags.isEmpty {
            BTTLog.verbose("  ✗ \(fileName) Injection skipped — found \(outputDiags.count) parse error(s) in generated output:")
            outputDiags.forEach { BTTLog.verbose("    \($0.message)") }
            return 0
        }

        do {
            try result.write(toFile: path, atomically: true, encoding: .utf8)
            BTTLog.verbose("  ✓ \(rewriter.injectedViews) instrumented ")
        } catch {
            BTTLog.verbose("  ✗ \(fileName) failed to instrumented with error: \(error.localizedDescription)")
            return 0
        }

        return rewriter.injectedViews.count
    }

    // MARK: - Revert
    @discardableResult
    func revert(file path: String) -> Int {
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            BTTLog.verbose("  ✗ Could not read file: \(path)")
            return 0
        }

        let hasBTTTrack  = source.contains("@\(BTTConstants.trackAttribute)")
        let hasBTTImport = source.contains("import \(BTTConstants.importModule)")
        if !hasBTTTrack && !hasBTTImport {
            return 0
        }

        let tree     = Parser.parse(source: source)
        let rewriter = BTTRevertRewriter()
        guard let newTree = rewriter.visit(tree).as(SourceFileSyntax.self) else {
            BTTLog.verbose("  ✗ Rewriter returned unexpected node type")
            return 0
        }

        guard rewriter.revertedViews.count > 0 else {
            return 0
        }

        let result = newTree.description
        guard result != source else {
            return 0
        }
        
        let outputTree  = Parser.parse(source: result)
        let outputDiags = ParseDiagnosticsGenerator.diagnostics(for: outputTree)
        if !outputDiags.isEmpty {
            BTTLog.verbose("  ✗ \(fileName) Revert skipped — found \(outputDiags.count) parse error(s) in generated output:")
            outputDiags.forEach { BTTLog.verbose("    \($0.message)") }
            return 0
        }

        do {
            try result.write(toFile: path, atomically: true, encoding: .utf8)
            BTTLog.verbose("  ✓ \(rewriter.revertedViews) revert instrumention.")
        } catch {
            BTTLog.verbose("  ✗ \(fileName) failed to revert instrumention with error: \(error.localizedDescription)")
            return 0
        }

        return rewriter.revertedViews.count
    }
}

#endif
