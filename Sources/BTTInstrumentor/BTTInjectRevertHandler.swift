//
//  BTTInjectRevertHandler.swift
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

final class BTTInjectRevertHandler {
    // MARK: - Inject
    @discardableResult
    func inject(file path: String) -> Int {
        let fileName = URL(fileURLWithPath: path).lastPathComponent

        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            BTTLog.error("  ✗ Could not read file: \(path)")
            return 0
        }

        let tree      = Parser.parse(source: source)
        let inputDiags = ParseDiagnosticsGenerator.diagnostics(for: tree)
        if !inputDiags.isEmpty {
            BTTLog.error("  ✗ Skipping — \(inputDiags.count) parse error(s) in source:")
            inputDiags.forEach { BTTLog.error("    \($0.message)") }
            return 0
        }

        let rewriter = BTTInjectRewriter()
        guard let newTree = rewriter.visit(tree).as(SourceFileSyntax.self) else {
            BTTLog.verbose("  ✗ Rewriter returned unexpected node type")
            return 0
        }
        let result = newTree.description
        guard rewriter.injectedViews.count > 0 || result != source else { return 0 }
        guard result != source else { return 0 } // no-op if injectedViews>0 but text unchanged (shouldn't happen, but stay safe)

        let hasTrackAttr   = result.contains("@\(BTTConstants.trackAttribute)")
        let hasTrackImport = result.contains("import \(BTTConstants.importModule)")
        if hasTrackAttr && !hasTrackImport {
            BTTLog.error("  ✗ \(fileName) Injection skipped — @\(BTTConstants.trackAttribute) was added but import \(BTTConstants.importModule) is missing.")
            BTTLog.error("    This indicates an unexpected file layout. Please report this file to BlueTriangle.")
            return 0
        }

        let outputTree  = Parser.parse(source: result)
        let outputDiags = ParseDiagnosticsGenerator.diagnostics(for: outputTree)
        if !outputDiags.isEmpty {
            BTTLog.verbose("  ✗ \(fileName) Injection skipped — \(outputDiags.count) parse error(s) in generated output:")
            outputDiags.forEach { BTTLog.verbose("    \($0.message)") }
            return 0
        }

        do {
            try result.write(toFile: path, atomically: true, encoding: .utf8)
            if rewriter.injectedViews.isEmpty {
                BTTLog.verbose("  ✓ \(fileName) repaired — added missing import \(BTTConstants.importModule)")
            } else {
                BTTLog.verbose("  ✓ \(fileName) \(rewriter.injectedViews.joined(separator: ", ")) instrumented")
            }
        } catch {
            BTTLog.verbose("  ✗ \(fileName) failed to instrument: \(error.localizedDescription)")
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
        if !hasBTTTrack && !hasBTTImport { return 0 }

        let tree     = Parser.parse(source: source)
        let rewriter = BTTRevertRewriter()
        guard let newTree = rewriter.visit(tree).as(SourceFileSyntax.self) else {
            BTTLog.verbose("  ✗ Rewriter returned unexpected node type")
            return 0
        }
        guard rewriter.revertedViews.count > 0 else { return 0 }

        let result = newTree.description
        guard result != source else { return 0 }

        let outputTree  = Parser.parse(source: result)
        let outputDiags = ParseDiagnosticsGenerator.diagnostics(for: outputTree)
        if !outputDiags.isEmpty {
            BTTLog.verbose("  ✗ \(fileName) Revert skipped — \(outputDiags.count) parse error(s) in generated output:")
            outputDiags.forEach { BTTLog.verbose("    \($0.message)") }
            return 0
        }

        do {
            try result.write(toFile: path, atomically: true, encoding: .utf8)
            BTTLog.verbose("  ↩ \(fileName) \(rewriter.revertedViews.joined(separator: ", ")) reverted instrumentation")
        } catch {
            BTTLog.verbose("  ✗ \(fileName) failed to revert: \(error.localizedDescription)")
            return 0
        }

        return rewriter.revertedViews.count
    }
    
    // MARK: - Dry-run count (no file writes)
    func countInjectableViews(file path: String) -> Int {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
        let tree = Parser.parse(source: source)
        guard ParseDiagnosticsGenerator.diagnostics(for: tree).isEmpty else { return 0 }
        let rewriter = BTTInjectRewriter()
        _ = rewriter.visit(tree)
        return rewriter.injectedViews.count
    }

}

#endif
