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
    private(set) var lastHadComplexViews = false

    // MARK: - Inject
    @discardableResult
    func inject(file path: String) -> Int {
        lastHadComplexViews = false
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
        rewriter.filePath = path
        guard let newTree = rewriter.visit(tree).as(SourceFileSyntax.self) else {
            BTTLog.verbose("  ✗ Rewriter returned unexpected node type")
            return 0
        }
        lastHadComplexViews = !rewriter.complexViews.isEmpty
        let result = newTree.description
        guard rewriter.injectedViews.count > 0 || result != source else { return 0 }
        guard result != source else { return 0 } // no-op if injectedViews>0 but text unchanged (shouldn't happen, but stay safe)

        let hasTrackModifier = result.contains(".\(BTTConstants.trackModifier)(")
        let hasTrackImport   = result.contains("import \(BTTConstants.importModule)")
        if hasTrackModifier && !hasTrackImport {
            BTTLog.error("  ✗ \(fileName) Injection skipped — .\(BTTConstants.trackModifier)() was added but import \(BTTConstants.importModule) is missing.")
            BTTLog.error("    This indicates an unexpected file layout. Please report this file to BlueTriangle SDK team.")
            return 0
        }

        let outputTree  = Parser.parse(source: result)
        let outputDiags = ParseDiagnosticsGenerator.diagnostics(for: outputTree)
        if !outputDiags.isEmpty {
            BTTLog.warn("  ✗ \(fileName) skipped — body too complex, instrument manually")
            BTTLog.verbose("  ✗ \(fileName) Injection skipped — generated output has \(outputDiags.count) parse error(s), instrument manually")
            outputDiags.forEach { BTTLog.verbose("    \($0.message)") }
            return 0
        }

        do {
            try result.write(toFile: path, atomically: true, encoding: .utf8)
            if rewriter.injectedViews.isEmpty {
                BTTLog.verbose("  ✓ \(fileName) repaired — added missing import \(BTTConstants.importModule)")
            } else {
                BTTLog.success("  ✓ \(fileName) \(rewriter.injectedViews.joined(separator: ", ")) instrumented")
            }
        } catch {
            BTTLog.error("  ✗ \(fileName) failed to instrument: \(error.localizedDescription)")
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

        let hasBTTModifier = source.contains(".\(BTTConstants.trackModifier)(")
        if !hasBTTModifier { return 0 }

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
            if !BTTLog.nonInteractive {
                BTTLog.verbose("  ↩ \(fileName) \(rewriter.revertedViews.joined(separator: ", ")) reverted instrumentation")
            }
        } catch {
            BTTLog.verbose("  ✗ \(fileName) failed to revert: \(error.localizedDescription)")
            return 0
        }

        return rewriter.revertedViews.count
    }
    
    // MARK: - State check
    func isInjected(file path: String) -> Bool {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return source.contains(".\(BTTConstants.trackModifier)(")
    }

    func isIgnored(file path: String) -> Bool {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        let lines = source.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() {
            guard line.trimmingCharacters(in: .whitespaces)
                    .range(of: BTTConstants.ignorePattern, options: .regularExpression) != nil else { continue }
            let nextNonEmpty = lines[(i + 1)...].first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            if nextNonEmpty?.trimmingCharacters(in: .whitespaces).hasPrefix("struct ") == true { continue }
            return true
        }
        return false
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
