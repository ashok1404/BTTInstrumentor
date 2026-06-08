//
//  BTTBuildPhase.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

#if os(macOS)
import Foundation

// MARK: - Script

private func buildScript() -> String {
"""
export PATH="$PATH:/usr/local/bin"
export PATH="$PATH:/opt/homebrew/bin"

if [[ -x "$SRCROOT/.btt/BTTInstrumentor" ]]
then
    instrumentorExecutable="$SRCROOT/.btt/BTTInstrumentor"
elif [[ -x "$(command -v BTTInstrumentor)" ]]
then
    instrumentorExecutable="$(command -v BTTInstrumentor)"
else
    echo "error: BTTInstrumentor not found. Run: brew install bttinstrumentor"
    exit 1
fi

"$instrumentorExecutable" install "$SRCROOT"
exit $?
"""
}

// MARK: - Add pre-action
// Only adds to schemes that build the selected target
// Skips if pre-action already exists

func addBuildPhase(xcodeprojPath: String, targetName: String) {
    let schemesDir = (xcodeprojPath as NSString).appendingPathComponent("xcshareddata/xcschemes")
    guard let schemeFiles = try? FileManager.default.contentsOfDirectory(atPath: schemesDir) else {
        BTTLog.error("No schemes found at \(schemesDir)")
        return
    }

    let projName = ((xcodeprojPath as NSString).lastPathComponent as NSString).deletingPathExtension
    let script   = buildScript()

    for schemeFile in schemeFiles where schemeFile.hasSuffix(".xcscheme") {
        let schemePath = (schemesDir as NSString).appendingPathComponent(schemeFile)
        guard var content = try? String(contentsOfFile: schemePath, encoding: .utf8) else { continue }

        // Only schemes that build this target
        guard content.contains("BlueprintName = \"\(targetName)\"") else { continue }

        // Skip — already has BTT pre-action
        if content.contains("BTT Instrumentation") { continue }

        let blueprintID = extractBlueprintID(from: content, targetName: targetName) ?? ""
        let escapedScript = script
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "&#10;") + "&#10;"

        let action =
            "         <ExecutionAction\n" +
            "            ActionType = \"Xcode.IDEStandardExecutionActionsCore.ExecutionActionType.ShellScriptAction\">\n" +
            "            <ActionContent\n" +
            "               title = \"BTT Instrumentation\"\n" +
            "               scriptText = \"\(escapedScript)\">\n" +
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

        // Insert inside existing PreActions or create new block
        if content.contains("      </PreActions>") {
            content = content.replacingOccurrences(of: "      </PreActions>", with: action + "      </PreActions>")
        } else if let range = content.range(of: "</PreActions>") {
            content.insert(contentsOf: action, at: range.lowerBound)
        } else {
            let block = "      <PreActions>\n" + action + "      </PreActions>\n"
            content = content.replacingOccurrences(of: "      <BuildActionEntries>", with: block + "      <BuildActionEntries>")
        }

        try? content.write(toFile: schemePath, atomically: true, encoding: .utf8)
    }
}

// MARK: - Remove pre-action
// target = nil removes ALL BTT pre-actions (full clean up)
// target = "Xpo" removes only the pre-action for that target

func removePreActions(for target: String?, in xcodeprojPath: String, keepTargets: [String] = []) {
    let schemesDir = (xcodeprojPath as NSString).appendingPathComponent("xcshareddata/xcschemes")
    guard let schemeFiles = try? FileManager.default.contentsOfDirectory(atPath: schemesDir) else { return }

    for schemeFile in schemeFiles where schemeFile.hasSuffix(".xcscheme") {
        let schemePath = (schemesDir as NSString).appendingPathComponent(schemeFile)
        guard var content = try? String(contentsOfFile: schemePath, encoding: .utf8) else { continue }
        guard content.contains("BTT Instrumentation") else { continue }

        if let target = target {
            // Only remove from schemes that build this target
            guard content.contains("BlueprintName = \"\(target)\"") else { continue }

            // If another instrumented target also uses this scheme — keep the pre-action
            let schemeAlsoBuilds = keepTargets.filter { content.contains("BlueprintName = \"\($0)\"") }
            if !schemeAlsoBuilds.isEmpty {
                BTTLog.info("Keeping pre-action in '\((schemeFile as NSString).deletingPathExtension)' — still used by: \(schemeAlsoBuilds.joined(separator: ", "))")
                continue
            }
        }

        content = removeBTTAction(from: content)
        content = removeEmptyPreActions(from: content)
        try? content.write(toFile: schemePath, atomically: true, encoding: .utf8)
    }
}

/// Removes the BTT Instrumentation ExecutionAction XML block
private func removeBTTAction(from content: String) -> String {
    let startMarker = "         <ExecutionAction"
    let titleMarker = "title = \"BTT Instrumentation\""
    let endMarker   = "         </ExecutionAction>"

    var lines = content.components(separatedBy: "\n")
    var i     = 0
    while i < lines.count {
        if lines[i].contains(startMarker) {
            let lookahead = min(i + 5, lines.count - 1)
            let block     = lines[i...lookahead].joined(separator: "\n")
            if block.contains(titleMarker) {
                var j = i
                while j < lines.count {
                    if lines[j].contains(endMarker) {
                        lines.removeSubrange(i...j)
                        break
                    }
                    j += 1
                }
                continue
            }
        }
        i += 1
    }
    return lines.joined(separator: "\n")
}

/// Removes <PreActions></PreActions> if it contains no ExecutionAction children
private func removeEmptyPreActions(from content: String) -> String {
    // Match empty PreActions block — only whitespace between open and close tags
    let pattern = "\\s*<PreActions>\\s*</PreActions>"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
    let range  = NSRange(content.startIndex..., in: content)
    return regex.stringByReplacingMatches(in: content, range: range, withTemplate: "")
}

private func extractBlueprintID(from content: String, targetName: String) -> String? {
    let lines = content.components(separatedBy: "\n")
    for (i, line) in lines.enumerated() {
        guard line.contains("BlueprintName = \"\(targetName)\"") else { continue }
        for j in stride(from: i, through: max(0, i - 5), by: -1) {
            guard lines[j].contains("BlueprintIdentifier") else { continue }
            let parts = lines[j].components(separatedBy: "\"")
            if parts.count >= 2 { return parts[1] }
        }
    }
    return nil
}

#endif
