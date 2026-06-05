//
//  BTTProjectResolver.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

#if os(macOS)
import Foundation
import PathKit
import XcodeProj

let fm = FileManager.default

// MARK: - xcodebuild
func xcodebuildList(projPath: String) -> String {
    let task = Process()
    task.launchPath = "/usr/bin/xcrun"
    task.arguments = ["xcodebuild", "-list", "-project", projPath]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    try? task.run()
    task.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

func parseSection(_ section: String, from output: String) -> [String] {
    var results: [String] = []
    var seen = Set<String>()
    var inSection = false
    for line in output.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "\(section):" { inSection = true; continue }
        if inSection {
            if trimmed.isEmpty { continue }
            if trimmed.hasSuffix(":") { break }
            if !seen.contains(trimmed) { seen.insert(trimmed); results.append(trimmed) }
        }
    }
    return results
}

func getTargets(from projPath: String) -> [String] {
    parseSection("Targets", from: xcodebuildList(projPath: projPath))
}

func getAllSchemes(from projPath: String) -> [String] {
    parseSection("Schemes", from: xcodebuildList(projPath: projPath)).sorted()
}

/// Returns all resolved package names (local + remote)
/// Parses "Resolved source packages:" section from xcodebuild -list
/// Returns only app-level schemes by reading xcshareddata/xcschemes
/// then filtering out any that match local package names
func getAppSchemes(from projPath: String) -> [String] {
    // Get schemes from xcshareddata — developer created
    let schemesDir = (projPath as NSString).appendingPathComponent("xcshareddata/xcschemes")
    let sharedSchemes: [String]
    if let files = try? fm.contentsOfDirectory(atPath: schemesDir) {
        sharedSchemes = files
            .filter { $0.hasSuffix(".xcscheme") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    } else {
        sharedSchemes = getAllSchemes(from: projPath)
    }

    // Get all local package names to exclude
    let localPackages = resolveAllPackages(projPath: projPath)

    // Filter out schemes that match a local package name
    return sharedSchemes.filter { !localPackages.keys.contains($0) }
}

// MARK: - Source files

func getSourceFiles(for targetName: String, in projPath: String) -> [String] {
    guard let xcodeproj = try? XcodeProj(path: Path(projPath)),
          let target = xcodeproj.pbxproj.nativeTargets.first(where: { $0.name == targetName }),
          let sourceFiles = try? target.sourceFiles() else { return [] }

    let projDir = Path(projPath).parent()
    return sourceFiles.compactMap { file -> String? in
        guard let path = file.path, path.hasSuffix(".swift") else { return nil }
        let fullPath = (try? file.fullPath(sourceRoot: projDir)) ?? (projDir + Path(path))
        return fm.fileExists(atPath: fullPath.string) ? fullPath.string : nil
    }
}

/// Get local package paths that a specific target depends on via XcodeProj
func getLocalPackagesForTarget(_ targetName: String, in projPath: String) -> [String] {
    guard let xcodeproj = try? XcodeProj(path: Path(projPath)),
          let target = xcodeproj.pbxproj.nativeTargets.first(where: { $0.name == targetName })
    else { return [] }

    let allPackages = resolveAllPackages(projPath: projPath)
    let depNames = (target.packageProductDependencies ?? []).compactMap { $0.productName }

    var paths: [String] = []
    var seen = Set<String>()
    for dep in depNames {
        if let path = allPackages[dep] ?? allPackages.first(where: { dep.hasPrefix($0.key) })?.value {
            if !seen.contains(path) { seen.insert(path); paths.append(path) }
        }
    }
    return paths
}

func findAllSwiftFiles(in root: String) -> [String] {
    var files: [String] = []
    guard let e = fm.enumerator(at: URL(fileURLWithPath: root),
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]) else { return files }
    for case let url as URL in e {
        let path = url.path
        guard path.hasSuffix(".swift") else { continue }
        guard !path.contains("/Pods/") else { continue }
        guard !path.contains("/.build/") else { continue }
        guard !path.contains("/DerivedData/") else { continue }
        files.append(path)
    }
    return files
}

func findXcodeprojFiles(in root: String) -> [String] {
    var results: [String] = []
    guard let e = fm.enumerator(at: URL(fileURLWithPath: root),
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]) else { return results }
    for case let url as URL in e {
        let depth = url.pathComponents.count - URL(fileURLWithPath: root).pathComponents.count
        if depth > 4 { e.skipDescendants(); continue }
        if url.pathExtension == "xcodeproj" { results.append(url.path) }
    }
    return results
}

/// Returns local package names and their paths [name: path]
func resolveAllPackages(projPath: String) -> [String: String] {
    let output = xcodebuildList(projPath: projPath)
    var packages: [String: String] = [:]
    var inSection = false

    for line in output.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed == "Resolved source packages:" { inSection = true; continue }
        if trimmed.hasPrefix("Information about project") { break }
        guard inSection, !trimmed.isEmpty else { continue }

        guard let range = trimmed.range(of: ": ") else { continue }
        let name = String(trimmed[trimmed.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let path = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)

        // Only local paths
        guard path.hasPrefix("/") else { continue }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
        packages[name] = path
    }
    return packages
}

// MARK: - Interactive selection
func select(from options: [String], prompt: String, allLabel: String) -> [String] {
    BTTLog.plain("\n\(prompt)\n")
    for (i, opt) in options.enumerated() {
        BTTLog.plain("\(i + 1). \(opt)")
    }
    BTTLog.info("\(options.count + 1). \(allLabel)")
    BTTLog.prompt("\nEnter the number of the \(prompt.lowercased().contains("target") ? "target" : "scheme") to instrument: ")

    if let input = readLine()?.trimmingCharacters(in: .whitespaces),
       let idx = Int(input) {
        if idx == options.count + 1 { return options }
        if idx >= 1 && idx <= options.count { return [options[idx - 1]] }
    }
    return [options[0]]
}

// MARK: - Resolve xcodeproj only

func resolveXcodeproj(args: BTTArgs) -> String? {
    if let p = args.projectPath, fm.fileExists(atPath: p) { return p }
    let found = findXcodeprojFiles(in: args.rootPath)
    if found.count == 1 { return found[0] }
    if found.isEmpty { return nil }
    let names = found.map { ($0 as NSString).lastPathComponent }
    let sel = select(from: names, prompt: "Multiple projects found:", allLabel: "all projects")
    return found.first { ($0 as NSString).lastPathComponent == sel[0] }
}

// MARK: - Resolve target then scheme (scheme list filtered after target selected)

func resolveTargetAndScheme(args: BTTArgs, xcodeprojPath: String) -> (target: String, scheme: String?) {

    // Step 1 — Select target first
    let targets = getTargets(from: xcodeprojPath)
    var selectedTarget: String

    if let t = args.target {
        selectedTarget = t
        BTTLog.info("Target: \(t)")
    } else if targets.isEmpty {
        selectedTarget = ""
    } else {
        BTTLog.info("Fetching targets for \((xcodeprojPath as NSString).lastPathComponent)...")
        let sel = select(
            from: targets,
            prompt: "Which target do you want to instrument?",
            allLabel: "all targets"
        )
        selectedTarget = sel.first ?? targets[0]
    }

    // Step 2 — Select scheme
    // Only show app-level schemes (packages are hidden — they are dependencies)
    let appSchemes = getAppSchemes(from: xcodeprojPath)
    var selectedScheme: String? = args.scheme

    if selectedScheme == nil && !appSchemes.isEmpty {
        BTTLog.info("Fetching all available schemes for \((xcodeprojPath as NSString).lastPathComponent)...")
        let sel = select(
            from: appSchemes,
            prompt: "Which scheme do you want to instrument?",
            allLabel: "all schemes"
        )
        // nil means all schemes selected
        selectedScheme = sel.count == 1 ? sel[0] : nil
        if let s = selectedScheme { BTTLog.info("Scheme: \(s)") }
        else { BTTLog.info("Instrumenting all schemes") }
    }

    return (selectedTarget, selectedScheme)
}

#endif
