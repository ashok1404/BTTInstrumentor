//
//  main.swift
//  blue-triangle
//
//  Created by Ashok Singh on 10/04/26.
//

#if swift(>=5.9)

import Foundation

guard CommandLine.arguments.count > 1 else {
    exit(0) // Silent — no error shown to developer
}

let filePath = CommandLine.arguments[1]
// MARK: - INJECT

do {
    let source = try String(contentsOfFile: filePath)

    // Skip files without SwiftUI
    guard source.contains("import SwiftUI") else { exit(0) }

    // Skip if already injected
    guard !source.contains("@BTTTrack") else { exit(0) }

    // Find all injectable SwiftUI structs
    let matches = findSwiftUIStructs(in: source)

    // Nothing to inject — skip silently
    guard !matches.isEmpty else { exit(0) }

    // Ensure import BlueTriangle is present
    var rewritten = ensureImports(in: source)

    // Inject @BTTTrackScreen above each valid struct
    rewritten = injectMacros(into: rewritten, matches: matches)

    guard rewritten != source else { exit(0) }

    try rewritten.write(toFile: filePath, atomically: true, encoding: .utf8)
    print("✅ Injected \(matches.count) view(s) in:", filePath)

} catch {
    // Silent — never surface errors to developer
    exit(0)
}

// MARK: - Struct Detection

struct ViewStructMatch {
    let structName: String
    let insertionIndex: String.Index // where to insert @BTTTrackScreen
}

/// Finds all structs that:
/// 1. Conform to View
/// 2. Have a `var body` inside their body
/// 3. Don't already have @BTTTrack
/// 4. Don't have // btt:ignore
func findSwiftUIStructs(in source: String) -> [ViewStructMatch] {
    var results: [ViewStructMatch] = []
    var cursor = source.startIndex

    while cursor < source.endIndex {

        // Find next struct keyword
        guard let structRange = source.range(
            of: #"\bstruct\s+([A-Za-z_][A-Za-z0-9_]*)"#,
            options: .regularExpression,
            range: cursor..<source.endIndex
        ) else { break }

        cursor = structRange.upperBound

        // Extract struct name
        let structName = extractStructName(from: String(source[structRange]))

        // Find opening brace
        guard let openBraceIdx = source[structRange.upperBound...].firstIndex(of: "{") else {
            continue
        }

        // Check conformance text between struct name and opening brace
        let conformanceText = String(source[structRange.upperBound..<openBraceIdx])
        guard conformsToView(conformanceText) else { continue }

        // Find matching closing brace for this struct
        guard let closeBraceIdx = findMatchingCloseBrace(in: source, openBrace: openBraceIdx) else {
            continue
        }

        let structBody = String(source[openBraceIdx..<closeBraceIdx])

        // Must have `var body` inside — confirms it's a real SwiftUI view
        guard hasBodyProperty(structBody) else { continue }

        // Skip if btt:ignore comment is above this struct
        let lineStart = findLineStart(in: source, at: structRange.lowerBound)
        guard !hasBTTIgnore(in: source, before: lineStart) else { continue }

        // Skip if @BTTTrackScreen already above this struct
        let preceding = source[..<lineStart].split(separator: "\n").suffix(3)
        guard !preceding.contains(where: { $0.contains("@BTTTrack") }) else { continue }

        results.append(ViewStructMatch(
            structName: structName,
            insertionIndex: lineStart
        ))

        // Move cursor past this struct to find next one
        cursor = closeBraceIdx
    }

    return results
}

// MARK: - Inject Macros

/// Injects @BTTTrackScreen above each matched struct.
/// Works in reverse order so earlier insertions don't shift later indices.
func injectMacros(into source: String, matches: [ViewStructMatch]) -> String {
    var result = source

    // Reverse order — inject from bottom up to preserve string indices
    for match in matches.reversed() {
        // Recalculate insertion point after previous insertions
        guard let insertPoint = recalculateIndex(
            originalIndex: match.insertionIndex,
            in: result,
            structName: match.structName
        ) else { continue }

        let indent = detectIndent(in: result, at: insertPoint)
        result.insert(contentsOf: "\(indent)@BTTTrack\n", at: insertPoint)
    }

    return result
}

/// After each insertion the string changes — recalculate the insertion
/// point by finding the struct by name again near the expected location.
func recalculateIndex(originalIndex: String.Index, in source: String, structName: String) -> String.Index? {
    // Search for struct near original position
    guard let structRange = source.range(
        of: "struct \(structName)",
        options: [],
        range: originalIndex < source.endIndex ? originalIndex..<source.endIndex : source.startIndex..<source.endIndex
    ) else {
        // Fallback: search from start
        guard let fallback = source.range(of: "struct \(structName)") else { return nil }
        return findLineStart(in: source, at: fallback.lowerBound)
    }
    return findLineStart(in: source, at: structRange.lowerBound)
}

// MARK: - Ensure Imports

func ensureImports(in source: String) -> String {
    guard source.contains("import SwiftUI"),
          !source.contains("import BlueTriangle"),
          let range = source.range(of: "import SwiftUI") else {
        return source
    }
    var result = source
    result.insert(contentsOf: "\nimport BlueTriangle", at: range.upperBound)
    return result
}

// MARK: - Helpers

func extractStructName(from structDecl: String) -> String {
    structDecl
        .replacingOccurrences(of: "struct", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: "_")).inverted)
        .first(where: { !$0.isEmpty }) ?? "Unknown"
}

/// Checks if the conformance text contains `View` as a standalone word
func conformsToView(_ text: String) -> Bool {
    let pattern = #"(?<![A-Za-z0-9_])View(?![A-Za-z0-9_])"#
    return text.range(of: pattern, options: .regularExpression) != nil
}

/// Checks if struct body contains `var body` — confirms real SwiftUI view
func hasBodyProperty(_ body: String) -> Bool {
    let pattern = #"\bvar\s+body\b"#
    return body.range(of: pattern, options: .regularExpression) != nil
}

/// Finds the matching closing brace for an opening brace
func findMatchingCloseBrace(in source: String, openBrace: String.Index) -> String.Index? {
    var depth = 0
    var idx = openBrace

    while idx < source.endIndex {
        let ch = source[idx]
        if ch == "{" { depth += 1 }
        else if ch == "}" {
            depth -= 1
            if depth == 0 { return idx }
        }
        idx = source.index(after: idx)
    }
    return nil
}

func hasBTTIgnore(in source: String, before idx: String.Index) -> Bool {
    source[..<idx]
        .components(separatedBy: "\n")
        .suffix(3)
        .contains(where: { $0.contains("btt:ignore") })
}

func findLineStart(in source: String, at index: String.Index) -> String.Index {
    var idx = index
    while idx > source.startIndex {
        let prev = source.index(before: idx)
        if source[prev] == "\n" { break }
        idx = prev
    }
    return idx
}

func detectIndent(in source: String, at idx: String.Index) -> String {
    var i = idx
    var indent = ""
    while i < source.endIndex {
        let ch = source[i]
        if ch == " " || ch == "\t" {
            indent.append(ch)
            i = source.index(after: i)
        } else { break }
    }
    return indent
}

func isValidSwiftFile(_ path: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["swiftc", "-parse", path]
    let pipe = Pipe()
    process.standardError = pipe
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus == 0
}

#endif
