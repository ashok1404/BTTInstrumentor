//
//  BTTBuildPhase.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//
//  Manages Xcode scheme pre-actions for BTT instrumentation.
//  - addPreAction:    injects BTT pre-action into matching xcschemes
//  - removePreActions: strips BTT pre-action from xcschemes
//

#if os(macOS)
import Foundation
import PathKit
import XcodeProj

// MARK: - Add pre-action

@discardableResult
func addPreAction(xcodeprojPath: String, targetName: String) -> Bool {
    let bttSwiftUITrackerAdded = addBTTSwiftUITrackerDependency(xcodeprojPath: xcodeprojPath, targetName: targetName)
    guard bttSwiftUITrackerAdded else {
        BTTLog.warn("BTTSwiftUITracker not added for '\(targetName)' — skipping pre-action.")
        return false
    }
    let projName = ((xcodeprojPath as NSString).lastPathComponent as NSString).deletingPathExtension

    for schemePath in collectSchemePaths(in: xcodeprojPath) {
        guard var content = try? String(contentsOfFile: schemePath, encoding: .utf8),
              content.contains("BlueprintName = \"\(targetName)\""),
              !content.contains("BTT Instrumentation")
        else { continue }

        let action = buildAction(
            blueprintID: extractBlueprintID(from: content, targetName: targetName) ?? "",
            targetName: targetName,
            projName: projName
        )
        content = insertAction(action, into: content)
        try? content.write(toFile: schemePath, atomically: true, encoding: .utf8)
    }
    return true
}

@discardableResult
func removePreActions(for target: String?, in xcodeprojPath: String, keepTargets: [String] = [], store: BTTTargetStore) -> Bool {
    var removed = false
    for schemePath in collectSchemePaths(in: xcodeprojPath) {
        guard var content = try? String(contentsOfFile: schemePath, encoding: .utf8),
              content.contains("BTT Instrumentation")
        else { continue }

        if let target = target {
            guard content.contains("BlueprintName = \"\(target)\""),
                  !keepTargets.contains(where: { content.contains("BlueprintName = \"\($0)\"") })
            else { continue }
            removeBTTSwiftUITrackerDependency(xcodeprojPath: xcodeprojPath, targetName: target, store: store)
        }

        let cleaned = removeAction(from: content)
        // If removeAction made no change, skip writing — avoids silent no-op touching files
        guard cleaned != content else { continue }

        content = removeEmptyPreActions(from: cleaned)
        try? content.write(toFile: schemePath, atomically: true, encoding: .utf8)
        removed = true
    }
    return removed
}

// MARK: - Private

private func buildAction(blueprintID: String, targetName: String, projName: String) -> String {
    let script = "export PATH=&quot;$PATH:/usr/local/bin&quot;&#10;" +
                 "export PATH=&quot;$PATH:/opt/homebrew/bin&quot;&#10;" +
                 "if [[ ! -f &quot;$SRCROOT/.btt/btt_instrument.sh&quot; ]]; then exit 0; fi&#10;" +
                 "bash &quot;$SRCROOT/.btt/btt_instrument.sh&quot;&#10;" +
                 "exit $?&#10;"
    return
        "         <ExecutionAction\n" +
        "            ActionType = \"Xcode.IDEStandardExecutionActionsCore.ExecutionActionType.ShellScriptAction\">\n" +
        "            <ActionContent\n" +
        "               title = \"BTT Instrumentation\"\n" +
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

private func removeAction(from content: String) -> String {
    var lines = content.components(separatedBy: "\n")
    var i = 0
    while i < lines.count {
        // Match opening tag loosely — any indentation
        guard lines[i].contains("<ExecutionAction") else { i += 1; continue }

        // Search far enough ahead for the title — BTT block can be 20+ lines
        let lookahead = min(i + 25, lines.count - 1)
        guard lines[i...lookahead].joined(separator: "\n").contains("title = \"BTT Instrumentation\"") else { i += 1; continue }

        // Find the closing tag — match loosely regardless of indentation
        var j = i + 1
        while j < lines.count {
            if lines[j].contains("</ExecutionAction>") {
                lines.removeSubrange(i...j)
                break
            }
            j += 1
        }
        // Don't increment i — recheck same index after removal
    }
    return lines.joined(separator: "\n")
}

private func removeEmptyPreActions(from content: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "\\s*<PreActions>\\s*</PreActions>") else { return content }
    return regex.stringByReplacingMatches(in: content, range: NSRange(content.startIndex..., in: content), withTemplate: "")
}

private func collectSchemePaths(in xcodeprojPath: String) -> [String] {
    let sharedDir = (xcodeprojPath as NSString).appendingPathComponent("xcshareddata/xcschemes")
    let userDir   = (xcodeprojPath as NSString).appendingPathComponent("xcuserdata")
    var paths: [String] = []
    if let files = try? FileManager.default.contentsOfDirectory(atPath: sharedDir) {
        paths += files.filter { $0.hasSuffix(".xcscheme") }.map { (sharedDir as NSString).appendingPathComponent($0) }
    }
    if let users = try? FileManager.default.contentsOfDirectory(atPath: userDir) {
        for user in users where user.hasSuffix(".xcuserdatad") {
            let dir = ((userDir as NSString).appendingPathComponent(user) as NSString).appendingPathComponent("xcschemes")
            if let files = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                paths += files.filter { $0.hasSuffix(".xcscheme") }.map { (dir as NSString).appendingPathComponent($0) }
            }
        }
    }
    return paths
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

#endif
