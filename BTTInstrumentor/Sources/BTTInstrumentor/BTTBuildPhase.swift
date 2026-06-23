//
//  BTTBuildPhase.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//
//  Manages Xcode scheme pre-actions for BTT instrumentation.
//

#if os(macOS)
import Foundation
import PathKit
import XcodeProj

/// Reads, writes, and removes BTT ExecutionAction blocks inside `.xcscheme` files.
final class BTTBuildPhase {
    private let xcodeprojPath: String
    init(xcodeprojPath: String) {
        self.xcodeprojPath = xcodeprojPath
    }

    struct PreActionResult {
        var matchedSchemes: [String]   // scheme names that received the pre-action
        var userOnlySchemes: [String]  // matched schemes that are user-local (xcuserdata), not shared
        var hasSharedScheme: Bool { matchedSchemes.count > userOnlySchemes.count }
    }

    @discardableResult
    func addPreAction(for targetName: String) -> PreActionResult {
        let projName = ((xcodeprojPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let schemePaths = collectSchemePaths()
        BTTLog.verbose("Found \(schemePaths.count) scheme file(s): \(schemePaths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", "))")

        var matchedSchemes: [String] = []
        var userOnlySchemes: [String] = []

        for schemePath in schemePaths {
            let schemeName = URL(fileURLWithPath: schemePath).deletingPathExtension().lastPathComponent
            let isUserScheme = schemePath.contains("xcuserdata")

            guard var content = try? String(contentsOfFile: schemePath, encoding: .utf8) else {
                BTTLog.verbose("  \(schemeName): could not read file")
                continue
            }

            guard let primaryBlueprint = primaryBuildActionBlueprint(in: content) else {
                BTTLog.verbose("  \(schemeName): no <BuildActionEntries> found — skipping")
                continue
            }
            guard primaryBlueprint == targetName else {
                BTTLog.verbose("  \(schemeName): primary build target is '\(primaryBlueprint)', not '\(targetName)' — skipping")
                continue
            }

            let hasPreAction = content.contains(BTTConstants.preActionTitle) || content.contains("BTT Instrumentation")
            guard !hasPreAction else {
                BTTLog.verbose("  \(schemeName): already has BTT pre-action — skipping")
                matchedSchemes.append(schemeName)
                if isUserScheme { userOnlySchemes.append(schemeName) }
                continue
            }

            let blueprintID = extractBlueprintID(from: content, targetName: targetName) ?? ""
            let action      = buildActionXML(blueprintID: blueprintID, targetName: targetName, projName: projName)
            content = insertAction(action, into: content)
            try? content.write(toFile: schemePath, atomically: true, encoding: .utf8)
            BTTLog.verbose("  \(schemeName): pre-action injected for target '\(targetName)' (\(isUserScheme ? "user scheme" : "shared scheme"))")
            matchedSchemes.append(schemeName)
            if isUserScheme { userOnlySchemes.append(schemeName) }
        }
        return PreActionResult(matchedSchemes: matchedSchemes, userOnlySchemes: userOnlySchemes)
    }

    // MARK: - Remove pre-action

    @discardableResult
    func removePreActions(for target: String? = nil, keepTargets: [String] = [], store: BTTTargetStore) -> Bool {
        var removed = false

        for schemePath in collectSchemePaths() {
            guard var content = try? String(contentsOfFile: schemePath, encoding: .utf8),
                  content.contains(BTTConstants.preActionTitle)
            else { continue }

            if let target = target {
                guard content.contains("BlueprintName = \"\(target)\""),
                      !keepTargets.contains(where: { content.contains("BlueprintName = \"\($0)\"") })
                else { continue }
            }

            let cleaned = stripActionBlock(from: content)
            guard cleaned != content else { continue }

            content = removeEmptyPreActionsTag(from: cleaned)
            try? content.write(toFile: schemePath, atomically: true, encoding: .utf8)
            removed = true
        }
        return removed
    }

    // MARK: - Scheme path discovery

    func collectSchemePaths() -> [String] {
        var paths: [String] = []

        let sharedDir = (xcodeprojPath as NSString).appendingPathComponent("xcshareddata/xcschemes")
        paths += schemeFiles(in: sharedDir)
        paths += userSchemeFiles(under: (xcodeprojPath as NSString).appendingPathComponent("xcuserdata"))

        let projDir  = (xcodeprojPath as NSString).deletingLastPathComponent
        let projName = ((xcodeprojPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let wsPath   = (projDir as NSString).appendingPathComponent("\(projName).xcworkspace")

        paths += schemeFiles(in: (wsPath as NSString).appendingPathComponent("xcshareddata/xcschemes"))
        paths += userSchemeFiles(under: (wsPath as NSString).appendingPathComponent("xcuserdata"))

        return paths
    }

    private func schemeFiles(in dir: String) -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return files.filter { $0.hasSuffix(".xcscheme") }.map { (dir as NSString).appendingPathComponent($0) }
    }

    private func userSchemeFiles(under userDir: String) -> [String] {
        guard let users = try? FileManager.default.contentsOfDirectory(atPath: userDir) else { return [] }
        var paths: [String] = []
        for user in users where user.hasSuffix(".xcuserdatad") {
            let dir = ((userDir as NSString).appendingPathComponent(user) as NSString).appendingPathComponent("xcschemes")
            paths += schemeFiles(in: dir)
        }
        return paths
    }

    // MARK: - XML helpers

    private func buildActionXML(blueprintID: String, targetName: String, projName: String) -> String {
        let script = "bash &quot;$SRCROOT/\(BTTConstants.bttFolderName)/\(BTTConstants.scriptFileName)&quot; || true&#10;"
        return
            "         <ExecutionAction\n" +
            "            ActionType = \"Xcode.IDEStandardExecutionActionsCore.ExecutionActionType.ShellScriptAction\">\n" +
            "            <ActionContent\n" +
            "               title = \"\(BTTConstants.preActionTitle)\"\n" +
            "               scriptText = \"\(script)\">\n" +
            "               <EnvironmentBuildable>\n" +
            "                  <BuildableReference\n" +
            "                     BuildableIdentifier = \"primary\"\n" +
            "                     BlueprintIdentifier = \"\(blueprintID)\"\n" +
            "                     BuildableName = \"\(targetName).app\"\n" +
            "                     BlueprintName = \"\(targetName)\"\n" +
            "                     ReferencedContainer = \"container:\(projName).xcodeproj\">\n" +
            "                  </BuildableReference>\n" +
            "               </EnvironmentBuildable>\n" +
            "            </ActionContent>\n" +
            "         </ExecutionAction>\n"
    }

    private func insertAction(_ action: String, into content: String) -> String {
        var c = content
        if c.contains("      <PreActions>") {
            c = c.replacingOccurrences(of: "      <PreActions>", with: "      <PreActions>\n" + action)
        } else if let range = c.range(of: "<PreActions>") {
            c.insert(contentsOf: "\n" + action, at: range.upperBound)
        } else {
            let block = "      <PreActions>\n" + action + "      </PreActions>\n"
            c = c.replacingOccurrences(of: "      <BuildActionEntries>", with: block + "      <BuildActionEntries>")
        }
        return c
    }

    private func isBTTActionTitle(_ block: String) -> Bool {
        block.contains("title = \"\(BTTConstants.preActionTitle)\"") ||
        block.contains("title = \"BTT Instrumentation\"")
    }

    private func stripActionBlock(from content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            guard lines[i].contains("<ExecutionAction") else { i += 1; continue }
            let lookahead = min(i + 25, lines.count - 1)
            let block = lines[i...lookahead].joined(separator: "\n")
            guard isBTTActionTitle(block) else { i += 1; continue }
            var j = i + 1
            while j < lines.count {
                if lines[j].contains("</ExecutionAction>") { lines.removeSubrange(i...j); break }
                j += 1
            }
        }
        return lines.joined(separator: "\n")
    }

    private func removeEmptyPreActionsTag(from content: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\s*<PreActions>\\s*</PreActions>") else { return content }
        return regex.stringByReplacingMatches(in: content, range: NSRange(content.startIndex..., in: content), withTemplate: "")
    }

    private func extractBlueprintID(from content: String, targetName: String) -> String? {
        let lines = content.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            guard line.contains("BlueprintName = \"\(targetName)\"") else { continue }
            for j in stride(from: i, through: max(0, i - 5), by: -1) {
                let parts = lines[j].components(separatedBy: "\"")
                if lines[j].contains("BlueprintIdentifier"), parts.count >= 2 { return parts[1] }
            }
        }
        return nil
    }

    private func primaryBuildActionBlueprint(in content: String) -> String? {
        let lines = content.components(separatedBy: "\n")
        guard let startIdx = lines.firstIndex(where: { $0.contains("<BuildActionEntries>") }) else { return nil }
        for line in lines[startIdx...] {
            if line.contains("</BuildActionEntries>") { break }
            if line.contains("BlueprintName"),
               let value = line.components(separatedBy: "\"").dropFirst().first { return value }
        }
        return nil
    }
}

#endif
