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
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        BTTLog.verbose("Injecting... — \(fileName)")

        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            BTTLog.verbose("  ✗ Could not read file: \(path)")
            return false
        }
        BTTLog.verbose("  File read: \(source.utf8.count) bytes")

        let tree = Parser.parse(source: source)

        // Skip files that already have parse errors
        let inputDiags = ParseDiagnosticsGenerator.diagnostics(for: tree)
        if !inputDiags.isEmpty {
            BTTLog.verbose("  ✗ Skipping — \(inputDiags.count) parse error(s) in source:")
            inputDiags.forEach { BTTLog.verbose("    \($0.message)") }
            return false
        }
        BTTLog.verbose("  Input parse: clean")

        let rewriter = BTTRewriter()
        guard let newTree = rewriter.visit(tree).as(SourceFileSyntax.self) else {
            BTTLog.verbose("  ✗ Rewriter returned unexpected node type")
            return false
        }

        BTTLog.verbose("  BTTRewriter.injectedCount = \(rewriter.injectedCount)")
        guard rewriter.injectedCount > 0 else {
            BTTLog.verbose("  – No Views eligible for injection (already instrumented, btt:ignore, or no 'body' property)")
            return false
        }

        let result = newTree.description
        guard result != source else {
            BTTLog.verbose("  – Output identical to source — nothing written")
            return false
        }

        // Validate output before writing
        let outputTree  = Parser.parse(source: result)
        let outputDiags = ParseDiagnosticsGenerator.diagnostics(for: outputTree)
        if !outputDiags.isEmpty {
            BTTLog.verbose("  ✗ Injection skipped — \(outputDiags.count) parse error(s) in generated output:")
            outputDiags.forEach { BTTLog.verbose("    \($0.message)") }
            BTTLog.warn("Injection skipped — parse error in \(fileName)")
            return false
        }
        BTTLog.verbose("  Output parse: clean")

        do {
            try result.write(toFile: path, atomically: true, encoding: .utf8)
            BTTLog.verbose("  ✓ Written: \(result.utf8.count) bytes (delta \(result.utf8.count - source.utf8.count) bytes)")
        } catch {
            BTTLog.verbose("  ✗ Write failed: \(error.localizedDescription)")
            return false
        }

        return true
    }

    // MARK: - Revert

    @discardableResult
    func revert(file path: String) -> Bool {
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        BTTLog.verbose("reverting... — \(fileName)")

        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            BTTLog.verbose("  ✗ Could not read file: \(path)")
            return false
        }
        BTTLog.verbose("  File read: \(source.utf8.count) bytes")

        // Quick pre-check: skip files that clearly contain no BTT annotations
        let hasBTTTrack  = source.contains("@\(BTTConstants.trackAttribute)")
        let hasBTTImport = source.contains("import \(BTTConstants.importModule)")
        BTTLog.verbose("  Quick scan — @\(BTTConstants.trackAttribute): \(hasBTTTrack), import \(BTTConstants.importModule): \(hasBTTImport)")
        if !hasBTTTrack && !hasBTTImport {
            BTTLog.verbose("  – No BTT annotations found — skipping parse")
            return false
        }

        let tree     = Parser.parse(source: source)
        let rewriter = BTTRevertRewriter()
        guard let newTree = rewriter.visit(tree).as(SourceFileSyntax.self) else {
            BTTLog.verbose("  ✗ Rewriter returned unexpected node type")
            return false
        }

        BTTLog.verbose("  BTTRevertRewriter.removedCount = \(rewriter.removedCount)")
        guard rewriter.removedCount > 0 else {
            BTTLog.verbose("  – Nothing removed (removedCount=0)")
            return false
        }

        let result = newTree.description
        guard result != source else {
            BTTLog.verbose("  – Output identical to source — nothing written")
            return false
        }

        do {
            try result.write(toFile: path, atomically: true, encoding: .utf8)
            BTTLog.verbose("  ✓ Written: \(result.utf8.count) bytes (delta \(result.utf8.count - source.utf8.count) bytes)")
        } catch {
            BTTLog.verbose("  ✗ Write failed: \(error.localizedDescription)")
            return false
        }

        return true
    }
}

#endif
