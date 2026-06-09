//
//  BTTBuildPhase.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

#if os(macOS)
import Foundation
import PathKit
import XcodeProj

// MARK: - Shell script content — written to .btt/btt_instrument.sh at install time

func writeBTTInstrumentScript(to projectDir: String) {
    let bttDir    = (projectDir as NSString).appendingPathComponent(".btt")
    let scriptPath = (bttDir as NSString).appendingPathComponent("btt_instrument.sh")

    let content = """
#!/bin/bash
export PATH="$PATH:/usr/local/bin"
export PATH="$PATH:/opt/homebrew/bin"

if [[ -x "$SRCROOT/.btt/BTTInstrumentor" ]]; then
    "$SRCROOT/.btt/BTTInstrumentor" install "$SRCROOT"
elif [[ -x "$(command -v BTTInstrumentor)" ]]; then
    "$(command -v BTTInstrumentor)" install "$SRCROOT"
else
    echo "error: BTTInstrumentor not found. Run: brew install bttinstrumentor"
    exit 1
fi
"""
    try? content.write(toFile: scriptPath, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
}

// Pre-action script — delegates to .btt/btt_instrument.sh
private func buildScript() -> String {
"""
export PATH="$PATH:/usr/local/bin"
export PATH="$PATH:/opt/homebrew/bin"
bash "$SRCROOT/.btt/btt_instrument.sh"
exit $?
"""
}

// MARK: - Add BTTSwiftUITracker package dependency
/// Adds BTTSwiftUITracker as a package product dependency to the target
/// Returns true if it was added by us, false if already existed
@discardableResult
private func addBTTSwiftUITrackerDependency(xcodeprojPath: String, targetName: String) -> Bool {
    guard let xcodeproj = try? XcodeProj(path: Path(xcodeprojPath)),
          let target = xcodeproj.pbxproj.nativeTargets.first(where: { $0.name == targetName })
    else { return false }

    // Already added — either by us or manually by developer
    let alreadyAdded = (target.packageProductDependencies ?? [])
        .contains { $0.productName == "BTTSwiftUITracker" }
    guard !alreadyAdded else { return false } // false = we didn't add it

    guard let bttPackage = (target.packageProductDependencies ?? [])
        .first(where: { $0.productName == "BlueTriangle" })?.package
    else {
        BTTLog.warn("BlueTriangle package not found in target '\(targetName)' — skipping BTTSwiftUITracker")
        return false
    }

    let dep = XCSwiftPackageProductDependency(productName: "BTTSwiftUITracker")
    dep.package = bttPackage
    xcodeproj.pbxproj.add(object: dep)
    target.packageProductDependencies = (target.packageProductDependencies ?? []) + [dep]
    try? xcodeproj.write(path: Path(xcodeprojPath))
    return true
}

// MARK: - Remove BTTSwiftUITracker package dependency
/// Removes BTTSwiftUITracker ONLY if BTTInstrumentor originally added it
/// Never removes if developer added it manually
private func removeBTTSwiftUITrackerDependency(xcodeprojPath: String, targetName: String, store: BTTTargetStore) {
    guard store.didAddBTTSwiftUITracker(for: targetName) else { return }

    guard let xcodeproj = try? XcodeProj(path: Path(xcodeprojPath)),
          let target = xcodeproj.pbxproj.nativeTargets.first(where: { $0.name == targetName })
    else { return }

    let before = target.packageProductDependencies ?? []
    let after  = before.filter { $0.productName != "BTTSwiftUITracker" }
    guard after.count != before.count else { return }

    before.filter { $0.productName == "BTTSwiftUITracker" }
          .forEach { xcodeproj.pbxproj.delete(object: $0) }
    target.packageProductDependencies = after
    try? xcodeproj.write(path: Path(xcodeprojPath))
}

// MARK: - Add pre-action
// One pre-action per scheme with target baked in
// Only adds to schemes that build the selected target (matched via BlueprintName)
// Skips if pre-action already exists

@discardableResult
func addBuildPhase(xcodeprojPath: String, targetName: String) -> Bool {
    // Add BTTSwiftUITracker package dependency to target — returns true if we added it
    let bttSwiftUITrackerAdded = addBTTSwiftUITrackerDependency(xcodeprojPath: xcodeprojPath, targetName: targetName)

    let projName = ((xcodeprojPath as NSString).lastPathComponent as NSString).deletingPathExtension

    // Check both shared schemes and user-specific schemes
    let sharedSchemesDir = (xcodeprojPath as NSString).appendingPathComponent("xcshareddata/xcschemes")
    let userDataDir      = (xcodeprojPath as NSString).appendingPathComponent("xcuserdata")
    var schemePaths: [String] = []

    // Shared schemes
    if let files = try? FileManager.default.contentsOfDirectory(atPath: sharedSchemesDir) {
        schemePaths += files
            .filter { $0.hasSuffix(".xcscheme") }
            .map { (sharedSchemesDir as NSString).appendingPathComponent($0) }
    }

    // User-specific schemes — xcuserdata/<user>.xcuserdatad/xcschemes/
    if let users = try? FileManager.default.contentsOfDirectory(atPath: userDataDir) {
        for user in users where user.hasSuffix(".xcuserdatad") {
            let userSchemesDir = ((userDataDir as NSString).appendingPathComponent(user) as NSString)
                .appendingPathComponent("xcschemes")
            if let files = try? FileManager.default.contentsOfDirectory(atPath: userSchemesDir) {
                schemePaths += files
                    .filter { $0.hasSuffix(".xcscheme") }
                    .map { (userSchemesDir as NSString).appendingPathComponent($0) }
            }
        }
    }

    guard !schemePaths.isEmpty else {
        BTTLog.error("No schemes found in \(xcodeprojPath)");
        return false
    }

    for schemePath in schemePaths {
        guard var content = try? String(contentsOfFile: schemePath, encoding: .utf8) else { continue }

        // Only schemes that build this target
        guard content.contains("BlueprintName = \"\(targetName)\"") else { continue }

        // Skip — pre-action already exists
        if content.contains("BTT Instrumentation") { continue }

        let blueprintID   = extractBlueprintID(from: content, targetName: targetName) ?? ""
        let escapedScript = buildScript()
            .replacingOccurrences(of: "&",  with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<",  with: "&lt;")
            .replacingOccurrences(of: ">",  with: "&gt;")
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

        // Insert at TOP of PreActions — before any existing actions
        if content.contains("      <PreActions>") {
            // Insert right after <PreActions> opening tag — BTT runs first
            content = content.replacingOccurrences(
                of: "      <PreActions>",
                with: "      <PreActions>\n" + action
            )
        } else if content.contains("<PreActions>") {
            if let range = content.range(of: "<PreActions>") {
                let insertPos = range.upperBound
                content.insert(contentsOf: "\n" + action, at: insertPos)
            }
        } else {
            // No PreActions block — create one before BuildActionEntries
            let block = "      <PreActions>\n" + action + "      </PreActions>\n"
            content = content.replacingOccurrences(
                of: "      <BuildActionEntries>",
                with: block + "      <BuildActionEntries>"
            )
        }

        try? content.write(toFile: schemePath, atomically: true, encoding: .utf8)
    }
    return bttSwiftUITrackerAdded
}
// target = nil → remove from all schemes (full clean up)
// target = "Xpo" → remove only from schemes that build Xpo
//                  but keep if another instrumented target shares that scheme

func removePreActions(for target: String?, in xcodeprojPath: String, keepTargets: [String] = [], store: BTTTargetStore) {
    let sharedSchemesDir = (xcodeprojPath as NSString).appendingPathComponent("xcshareddata/xcschemes")
    let userDataDir      = (xcodeprojPath as NSString).appendingPathComponent("xcuserdata")
    var schemePaths: [String] = []

    if let files = try? FileManager.default.contentsOfDirectory(atPath: sharedSchemesDir) {
        schemePaths += files.filter { $0.hasSuffix(".xcscheme") }
            .map { (sharedSchemesDir as NSString).appendingPathComponent($0) }
    }
    if let users = try? FileManager.default.contentsOfDirectory(atPath: userDataDir) {
        for user in users where user.hasSuffix(".xcuserdatad") {
            let dir = ((userDataDir as NSString).appendingPathComponent(user) as NSString)
                .appendingPathComponent("xcschemes")
            if let files = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                schemePaths += files.filter { $0.hasSuffix(".xcscheme") }
                    .map { (dir as NSString).appendingPathComponent($0) }
            }
        }
    }

    for schemePath in schemePaths {
        guard var content = try? String(contentsOfFile: schemePath, encoding: .utf8) else { continue }
        guard content.contains("BTT Instrumentation") else { continue }

        if let target = target {
            guard content.contains("BlueprintName = \"\(target)\"") else { continue }
            // Keep pre-action if another instrumented target uses this same scheme
            let stillNeeded = keepTargets.filter { content.contains("BlueprintName = \"\($0)\"") }
            if !stillNeeded.isEmpty { continue }
            // Remove BTTSwiftUITracker only if we added it — never touch manually added deps
            removeBTTSwiftUITrackerDependency(xcodeprojPath: xcodeprojPath, targetName: target, store: store)
        }

        content = removeBTTAction(from: content)
        content = removeEmptyPreActions(from: content)
        try? content.write(toFile: schemePath, atomically: true, encoding: .utf8)
    }
}

// MARK: - Private
private func removeBTTAction(from content: String) -> String {
    let startMarker = "         <ExecutionAction"
    let titleMarker = "title = \"BTT Instrumentation\""
    let endMarker   = "         </ExecutionAction>"

    var lines = content.components(separatedBy: "\n")
    var i     = 0
    while i < lines.count {
        if lines[i].contains(startMarker) {
            let lookahead = min(i + 5, lines.count - 1)
            if lines[i...lookahead].joined(separator: "\n").contains(titleMarker) {
                var j = i
                while j < lines.count {
                    if lines[j].contains(endMarker) { lines.removeSubrange(i...j); break }
                    j += 1
                }
                continue
            }
        }
        i += 1
    }
    return lines.joined(separator: "\n")
}

private func removeEmptyPreActions(from content: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "\\s*<PreActions>\\s*</PreActions>") else { return content }
    return regex.stringByReplacingMatches(in: content, range: NSRange(content.startIndex..., in: content), withTemplate: "")
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
