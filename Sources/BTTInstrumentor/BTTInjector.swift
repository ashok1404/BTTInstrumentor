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

func injectFile(_ path: String) -> Bool {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { return false }

    let tree = Parser.parse(source: source)
    let rewriter = BTTRewriter()
    guard let newTree = rewriter.visit(tree).as(SourceFileSyntax.self) else { return false }
    guard rewriter.injectedCount > 0 else { return false }

    let result = newTree.description
    guard result != source else { return false }
    try? result.write(toFile: path, atomically: true, encoding: .utf8)
    return true
}
#endif
