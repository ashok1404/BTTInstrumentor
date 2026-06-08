//
//  Injector.swift
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


func injectFile(_ path: String) -> Bool {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
    let tree = Parser.parse(source: source)

    // Skip files with existing parse errors
    let originalDiags = ParseDiagnosticsGenerator.diagnostics(for: tree)
    guard originalDiags.isEmpty else { return false }

    let rewriter = BTTRewriter()
    guard let newTree = rewriter.visit(tree).as(SourceFileSyntax.self) else { return false }
    guard rewriter.injectedCount > 0 else { return false }

    let result = newTree.description
    guard result != source else { return false }

    // Validate output
    let validatedTree = Parser.parse(source: result)
    let outputDiags = ParseDiagnosticsGenerator.diagnostics(for: validatedTree)
    guard outputDiags.isEmpty else {
        BTTLog.warn("Injection skipped — parse error: \(URL(fileURLWithPath: path).lastPathComponent)")
        return false
    }

    try? result.write(toFile: path, atomically: true, encoding: .utf8)
    return true
}

#endif
