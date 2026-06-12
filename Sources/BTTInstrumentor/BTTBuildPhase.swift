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

    /// Injects the BTT pre-action into every scheme that references `targetName`.
    /// Also adds the BTTSwiftUITracker dependency to the target.
    /// - Returns: `true` if BTTSwiftUITracker was successfully added (or already present).
    @discardableResult
    func addPreAction(for targetName: String) -> Bool {
        let dependency = BTTPackageDependency(xcodeprojPath: xcodeprojPath)
        guard dependency.addSwiftUITracker(to: targetName) else {
            BTTLog.warn("BTTSwiftUITracker not added for '\(targetName)' — skipping pre-action.")
            return false
        }

        let projName = ((xcodeprojPath as NSString).lastPathComponent as NSString).deletingPathExtension

        for schemePath in collectSchemePaths() {
            guard var content = try? String(contentsOfFile: schemePath, encoding: .utf8),
                  content.contains("BlueprintName = \"\(targetName)\""),
                  !content.contains(BTTConstants.preActionTitle),
                  !content.contains("BTT Instrumentation")   // legacy title guard
            else { continue }

            let blueprintID = extractBlueprintID(from: content, targetName: targetName) ?? ""
            let action      = buildActionXML(blueprintID: blueprintID, targetName: targetName, projName: projName)
            content = insertAction(action, into: content)
            try? content.write(toFile: schemePath, atomically: true, encoding: .utf8)
        }
        return true
    }

    /// Strips the BTT pre-action from schemes.
    /// - Parameters:
    ///   - target: The specific target to remove, or `nil` to strip from all schemes.
    ///   - keepTargets: Targets whose schemes should NOT be modified (used for single-target removal).
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

                BTTPackageDependency(xcodeprojPath: xcodeprojPath)
                    .removeSwiftUITracker(from: target, store: store)
            } else {
                // "Remove all" — strip BTTSwiftUITracker from every instrumented
                // target whose pre-action appears in this scheme.
                for instrumentedTarget in store.targets where content.contains("BlueprintName = \"\(instrumentedTarget)\"") {
                    BTTPackageDependency(xcodeprojPath: xcodeprojPath)
                        .removeSwiftUITracker(from: instrumentedTarget, store: store)
                }
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
        let sharedDir = (xcodeprojPath as NSString).appendingPathComponent("xcshareddata/xcschemes")
        let userDir   = (xcodeprojPath as NSString).appendingPathComponent("xcuserdata")
        var paths: [String] = []

        if let files = try? FileManager.default.contentsOfDirectory(atPath: sharedDir) {
            paths += files
                .filter { $0.hasSuffix(".xcscheme") }
                .map { (sharedDir as NSString).appendingPathComponent($0) }
        }
        if let users = try? FileManager.default.contentsOfDirectory(atPath: userDir) {
            for user in users where user.hasSuffix(".xcuserdatad") {
                let dir = ((userDir as NSString).appendingPathComponent(user) as NSString)
                    .appendingPathComponent("xcschemes")
                if let files = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                    paths += files
                        .filter { $0.hasSuffix(".xcscheme") }
                        .map { (dir as NSString).appendingPathComponent($0) }
                }
            }
        }
        return paths
    }

    // MARK: - Private XML helpers
    private func buildActionXML(blueprintID: String, targetName: String, projName: String) -> String {
        let script =
            "export PATH=&quot;$PATH:/usr/local/bin&quot;&#10;" +
            "export PATH=&quot;$PATH:/opt/homebrew/bin&quot;&#10;" +
            "if [[ ! -f &quot;$SRCROOT/\(BTTConstants.bttFolderName)/\(BTTConstants.scriptFileName)&quot; ]]; then exit 0; fi&#10;" +
            "bash &quot;$SRCROOT/\(BTTConstants.bttFolderName)/\(BTTConstants.scriptFileName)&quot;&#10;" +
            "exit $?&#10;"

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

    // Matches both current title (BTTConstants.preActionTitle) and legacy "BTT Instrumentation"
    private func isBTTActionTitle(_ line: String) -> Bool {
        line.contains("title = \"\(BTTConstants.preActionTitle)\"") ||
        line.contains("title = \"BTT Instrumentation\"")
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
                if lines[j].contains("</ExecutionAction>") {
                    lines.removeSubrange(i...j)
                    break
                }
                j += 1
            }
        }
        return lines.joined(separator: "\n")
    }

    private func removeEmptyPreActionsTag(from content: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\s*<PreActions>\\s*</PreActions>") else { return content }
        return regex.stringByReplacingMatches(
            in: content,
            range: NSRange(content.startIndex..., in: content),
            withTemplate: ""
        )
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
}

#endif
