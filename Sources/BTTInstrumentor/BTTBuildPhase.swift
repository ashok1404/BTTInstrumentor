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
        BTTLog.verbose("addPreAction — target='\(targetName)'")

        let dependency = BTTPackageDependency(xcodeprojPath: xcodeprojPath)
        guard dependency.addSwiftUITracker(to: targetName) else {
            BTTLog.verbose("  addSwiftUITracker failed for '\(targetName)' — aborting pre-action injection.")
            BTTLog.warn("BTTSwiftUITracker not added for '\(targetName)' — skipping pre-action.")
            return false
        }
        BTTLog.verbose("  BTTSwiftUITracker dependency ensured ✓")

        let projName    = ((xcodeprojPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let schemePaths = collectSchemePaths()
        BTTLog.verbose("  Scheme files to check (\(schemePaths.count)):")
        schemePaths.forEach { BTTLog.verbose("    \(URL(fileURLWithPath: $0).lastPathComponent)") }

        var injectedCount = 0
        for schemePath in schemePaths {
            let schemeName = URL(fileURLWithPath: schemePath).lastPathComponent
            guard var content = try? String(contentsOfFile: schemePath, encoding: .utf8) else {
                BTTLog.verbose("  Could not read scheme: \(schemeName)")
                continue
            }

            guard content.contains("BlueprintName = \"\(targetName)\"") else {
                BTTLog.verbose("  Scheme '\(schemeName)' does not reference target '\(targetName)' — skipping.")
                continue
            }
            if content.contains(BTTConstants.preActionTitle) {
                BTTLog.verbose("  Scheme '\(schemeName)' already has pre-action '\(BTTConstants.preActionTitle)' — skipping.")
                continue
            }

            let blueprintID = extractBlueprintID(from: content, targetName: targetName) ?? ""
            BTTLog.verbose("  Inserting pre-action into '\(schemeName)' blueprintID='\(blueprintID)'")

            let action  = buildActionXML(blueprintID: blueprintID, targetName: targetName, projName: projName)
            content     = insertAction(action, into: content)

            do {
                try content.write(toFile: schemePath, atomically: true, encoding: .utf8)
                BTTLog.verbose("  ✓ Pre-action written to '\(schemeName)'")
                injectedCount += 1
            } catch {
                BTTLog.verbose("  ✗ Failed to write scheme '\(schemeName)': \(error.localizedDescription)")
            }
        }

        BTTLog.verbose("addPreAction complete — injected into \(injectedCount) scheme(s)")
        return true
    }

    /// Strips the BTT pre-action from schemes.
    /// - Parameters:
    ///   - target: The specific target to remove, or `nil` to strip from all schemes.
    ///   - keepTargets: Targets whose schemes should NOT be modified (used for single-target removal).
    @discardableResult
    func removePreActions(for target: String? = nil, keepTargets: [String] = [], store: BTTTargetStore) -> Bool {
        BTTLog.verbose("removePreActions — target='\(target ?? "all")' keepTargets=[\(keepTargets.joined(separator: ", "))]")

        var removed    = false
        let schemePaths = collectSchemePaths()
        BTTLog.verbose("  Scheme files to check (\(schemePaths.count)):")
        schemePaths.forEach { BTTLog.verbose("    \(URL(fileURLWithPath: $0).lastPathComponent)") }

        for schemePath in schemePaths {
            let schemeName = URL(fileURLWithPath: schemePath).lastPathComponent
            guard var content = try? String(contentsOfFile: schemePath, encoding: .utf8) else {
                BTTLog.verbose("  Could not read scheme: \(schemeName)")
                continue
            }
            guard content.contains(BTTConstants.preActionTitle) else {
                BTTLog.verbose("  Scheme '\(schemeName)' has no BTT pre-action — skipping.")
                continue
            }

            if let target = target {
                guard content.contains("BlueprintName = \"\(target)\"") else {
                    BTTLog.verbose("  Scheme '\(schemeName)' does not reference '\(target)' — skipping.")
                    continue
                }
                if keepTargets.contains(where: { content.contains("BlueprintName = \"\($0)\"") }) {
                    BTTLog.verbose("  Scheme '\(schemeName)' also contains a keepTarget — leaving pre-action intact.")
                    continue
                }
                BTTLog.verbose("  Removing BTTSwiftUITracker dependency for '\(target)'...")
                BTTPackageDependency(xcodeprojPath: xcodeprojPath)
                    .removeSwiftUITracker(from: target, store: store)
            }

            BTTLog.verbose("  Stripping pre-action block from '\(schemeName)'...")
            let cleaned = stripActionBlock(from: content)
            guard cleaned != content else {
                BTTLog.verbose("  stripActionBlock returned identical content — nothing removed from '\(schemeName)'.")
                continue
            }

            content = removeEmptyPreActionsTag(from: cleaned)
            do {
                try content.write(toFile: schemePath, atomically: true, encoding: .utf8)
                BTTLog.verbose("  ✓ Pre-action removed from '\(schemeName)'")
                removed = true
            } catch {
                BTTLog.verbose("  ✗ Failed to write scheme '\(schemeName)': \(error.localizedDescription)")
            }
        }

        BTTLog.verbose("removePreActions complete — removed=\(removed)")
        return removed
    }

    // MARK: - Scheme path discovery

    func collectSchemePaths() -> [String] {
        let sharedDir = (xcodeprojPath as NSString).appendingPathComponent("xcshareddata/xcschemes")
        let userDir   = (xcodeprojPath as NSString).appendingPathComponent("xcuserdata")
        var paths: [String] = []

        BTTLog.verbose("collectSchemePaths — sharedDir: \(sharedDir)")
        if let files = try? FileManager.default.contentsOfDirectory(atPath: sharedDir) {
            let schemes = files.filter { $0.hasSuffix(".xcscheme") }
            BTTLog.verbose("  Shared schemes (\(schemes.count)): \(schemes.joined(separator: ", "))")
            paths += schemes.map { (sharedDir as NSString).appendingPathComponent($0) }
        } else {
            BTTLog.verbose("  No shared schemes directory or unreadable: \(sharedDir)")
        }

        if let users = try? FileManager.default.contentsOfDirectory(atPath: userDir) {
            BTTLog.verbose("  xcuserdata entries (\(users.count)): \(users.joined(separator: ", "))")
            for user in users where user.hasSuffix(".xcuserdatad") {
                let dir = ((userDir as NSString).appendingPathComponent(user) as NSString)
                    .appendingPathComponent("xcschemes")
                if let files = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                    let schemes = files.filter { $0.hasSuffix(".xcscheme") }
                    BTTLog.verbose("    User '\(user)' schemes (\(schemes.count)): \(schemes.joined(separator: ", "))")
                    paths += schemes.map { (dir as NSString).appendingPathComponent($0) }
                } else {
                    BTTLog.verbose("    No xcschemes dir for user '\(user)'")
                }
            }
        } else {
            BTTLog.verbose("  No xcuserdata directory or unreadable: \(userDir)")
        }

        BTTLog.verbose("collectSchemePaths total: \(paths.count)")
        return paths
    }

    // MARK: - Private XML helpers

    private func buildActionXML(blueprintID: String, targetName: String, projName: String) -> String {
        BTTLog.verbose("  buildActionXML — blueprintID='\(blueprintID)' target='\(targetName)' proj='\(projName)'")
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
        if content.contains("      <PreActions>") {
            BTTLog.verbose("    insertAction — appending inside existing <PreActions> block")
            return content.replacingOccurrences(of: "      <PreActions>", with: "      <PreActions>\n" + action)
        } else if let range = content.range(of: "<PreActions>") {
            BTTLog.verbose("    insertAction — appending after <PreActions> (no indentation variant)")
            var c = content
            c.insert(contentsOf: "\n" + action, at: range.upperBound)
            return c
        } else {
            BTTLog.verbose("    insertAction — no <PreActions> found; injecting new block before <BuildActionEntries>")
            let block = "      <PreActions>\n" + action + "      </PreActions>\n"
            return content.replacingOccurrences(of: "      <BuildActionEntries>", with: block + "      <BuildActionEntries>")
        }
    }

    // Matches both current title (BTTConstants.preActionTitle)
    private func isBTTActionTitle(_ line: String) -> Bool {
        line.contains("title = \"\(BTTConstants.preActionTitle)\"")
    }

    private func stripActionBlock(from content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        var i = 0
        var strippedCount = 0
        while i < lines.count {
            guard lines[i].contains("<ExecutionAction") else { i += 1; continue }

            let lookahead = min(i + 25, lines.count - 1)
            let block = lines[i...lookahead].joined(separator: "\n")
            guard isBTTActionTitle(block) else {
                BTTLog.verbose("    stripActionBlock — <ExecutionAction> at line \(i) is not BTT — skipping.")
                i += 1
                continue
            }

            BTTLog.verbose("    stripActionBlock — found BTT <ExecutionAction> at line \(i)")
            var j = i + 1
            while j < lines.count {
                if lines[j].contains("</ExecutionAction>") {
                    BTTLog.verbose("    stripActionBlock — removing lines \(i)...\(j) (inclusive)")
                    lines.removeSubrange(i...j)
                    strippedCount += 1
                    break
                }
                j += 1
            }
            // Recheck same index after removal
        }
        BTTLog.verbose("    stripActionBlock — removed \(strippedCount) block(s)")
        return lines.joined(separator: "\n")
    }

    private func removeEmptyPreActionsTag(from content: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\\s*<PreActions>\\s*</PreActions>") else {
            BTTLog.verbose("    removeEmptyPreActionsTag — regex compile failed")
            return content
        }
        let result = regex.stringByReplacingMatches(
            in: content,
            range: NSRange(content.startIndex..., in: content),
            withTemplate: ""
        )
        if result != content {
            BTTLog.verbose("    removeEmptyPreActionsTag — removed empty <PreActions/> tag")
        }
        return result
    }

    private func extractBlueprintID(from content: String, targetName: String) -> String? {
        let lines = content.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            guard line.contains("BlueprintName = \"\(targetName)\"") else { continue }
            BTTLog.verbose("    extractBlueprintID — found BlueprintName at line \(i), scanning back for BlueprintIdentifier...")
            for j in stride(from: i, through: max(0, i - 5), by: -1) {
                let parts = lines[j].components(separatedBy: "\"")
                if lines[j].contains("BlueprintIdentifier"), parts.count >= 2 {
                    BTTLog.verbose("    extractBlueprintID — found at line \(j): '\(parts[1])'")
                    return parts[1]
                }
            }
            BTTLog.verbose("    extractBlueprintID — BlueprintIdentifier not found within 5 lines of BlueprintName")
        }
        BTTLog.verbose("    extractBlueprintID — target '\(targetName)' not found in scheme content")
        return nil
    }
}

#endif
