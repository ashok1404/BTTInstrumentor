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

// MARK: - Xcodeproj
/// Finds .xcodeproj from args path or by searching rootPath up to 4 levels deep.
/// If multiple are found and running interactively, prompts the user to pick one.
func resolveXcodeproj(args: BTTArgs) -> String? {
    if let p = args.projectPath, fm.fileExists(atPath: p) { return p }

    guard let enumerator = fm.enumerator(
        at: URL(fileURLWithPath: args.rootPath),
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return nil }

    var found: [String] = []
    let rootDepth = URL(fileURLWithPath: args.rootPath).pathComponents.count
    for case let url as URL in enumerator {
        let depth = url.pathComponents.count - rootDepth
        if depth > 4 { enumerator.skipDescendants(); continue }
        if url.pathExtension == "xcodeproj" { found.append(url.path) }
    }

    switch found.count {
    case 0: return nil
    case 1: return found[0]
    default:
        // Non-interactive (scheme pre-action) — pick first, no prompt
        if isatty(STDIN_FILENO) == 0 { return found[0] }

        BTTLog.info("\nMultiple .xcodeproj files found. Which one do you want to use?\n")
        found.enumerated().forEach { i, p in
            BTTLog.info("\(i + 1). \(URL(fileURLWithPath: p).lastPathComponent) (\(p))")
        }
        BTTLog.info("\nEnter the number: ")

        if let input = readLine()?.trimmingCharacters(in: .whitespaces),
           let idx   = Int(input), (1...found.count).contains(idx) {
            return found[idx - 1]
        }
        return found[0]
    }
}

// MARK: - Targets
/// Returns all targets listed under the "Targets:" section in xcodebuild -list
func getTargets(in xcodeprojPath: String) -> [String] {
    var targets   = [String]()
    var seen      = Set<String>()
    var inSection = false
    for line in runXcodebuildList(for: xcodeprojPath).components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "Targets:"  { inSection = true; continue }
        guard inSection            else { continue }
        if trimmed.isEmpty         { continue }
        if trimmed.hasSuffix(":")  { break }
        if seen.insert(trimmed).inserted { targets.append(trimmed) }
    }
    return targets
}

// MARK: - Swift files for a target

/// Returns all Swift files for a target by merging three sources:
/// 1. File references declared in xcodeproj (most projects)
/// 2. Files from local SPM package dependencies of the target
/// 3. Folder scan fallback — used when target uses a folder reference instead of file refs
func getSwiftFiles(for target: String, in xcodeprojPath: String) -> [String] {
    var files = [String]()
    var seen  = Set<String>()

    // Helper — adds only unique paths
    func add(_ incoming: [String]) { incoming.filter { seen.insert($0).inserted }.forEach { files.append($0) } }

    // 1. File references from xcodeproj
    add(sourceFileRefs(for: target, in: xcodeprojPath))
    // 2. Swift files from local package dependencies
    add(localPackageFiles(for: target, in: xcodeprojPath))
    // 3. Folder reference fallback — scan folder named after target
    if files.isEmpty {
        let projDir    = Path(xcodeprojPath).parent().string
        let targetFolder = (projDir as NSString).appendingPathComponent(target)
        if fm.fileExists(atPath: targetFolder) {
            add(scanSwiftFiles(in: targetFolder))
        }
    }

    return files
}

// MARK: - Private
/// Reads Swift file paths declared as file references for a target in xcodeproj
private func sourceFileRefs(for target: String, in xcodeprojPath: String) -> [String] {
    let projDir = Path(xcodeprojPath).parent()
    guard let proj    = try? XcodeProj(path: Path(xcodeprojPath)),
          let native  = proj.pbxproj.nativeTargets.first(where: { $0.name == target }),
          let sources = try? native.sourceFiles()
    else { return [] }

    return sources.compactMap { ref -> String? in
        guard let relativePath = ref.path, relativePath.hasSuffix(".swift") else { return nil }
        let fullPath = (try? ref.fullPath(sourceRoot: projDir)) ?? (projDir + Path(relativePath))
        return fm.fileExists(atPath: fullPath.string) ? fullPath.string : nil
    }
}

/// Resolves local SPM package dependencies for a target and returns all their Swift files
private func localPackageFiles(for target: String, in xcodeprojPath: String) -> [String] {
    guard let proj   = try? XcodeProj(path: Path(xcodeprojPath)),
          let native = proj.pbxproj.nativeTargets.first(where: { $0.name == target })
    else { return [] }

    let packagePathMap  = resolvedLocalPackages(for: xcodeprojPath)
    let dependencyNames = (native.packageProductDependencies ?? []).compactMap { $0.productName }

    var visitedPaths = Set<String>()
    return dependencyNames
        .compactMap { name in
            // Match by exact name or prefix (handles sub-product names)
            packagePathMap[name] ?? packagePathMap.first(where: { name.hasPrefix($0.key) })?.value
        }
        .filter { visitedPaths.insert($0).inserted }
        .flatMap { scanSwiftFiles(in: $0) }
}

/// Parses "Resolved source packages:" from xcodebuild -list — returns [packageName: localPath]
/// Only includes local packages (path starts with "/") that exist on disk
private func resolvedLocalPackages(for projPath: String) -> [String: String] {
    var packageMap = [String: String]()
    var inSection  = false
    for line in runXcodebuildList(for: projPath).components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "Resolved source packages:" { inSection = true; continue }
        if trimmed.hasPrefix("Information about project") { break }
        guard inSection, !trimmed.isEmpty, let separator = trimmed.range(of: ": ") else { continue }
        let name = String(trimmed[trimmed.startIndex..<separator.lowerBound])
        let path = String(trimmed[separator.upperBound...])
        guard path.hasPrefix("/") else { continue }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
        packageMap[name] = path
    }
    return packageMap
}

/// Recursively scans a directory and returns .swift files, skipping Pods / .build / DerivedData
private func scanSwiftFiles(in root: String) -> [String] {
    var files = [String]()
    guard let enumerator = fm.enumerator(
        at: URL(fileURLWithPath: root).standardized,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return files }
    for case let url as URL in enumerator {
        let path = url.standardized.path
        guard path.hasSuffix(".swift"),
              !path.contains("/Pods/"),
              !path.contains("/.build/"),
              !path.contains("/DerivedData/")
        else { continue }
        files.append(path)
    }
    return files
}

/// Runs `xcodebuild -list -project <path>` and returns stdout as a string
private func runXcodebuildList(for projPath: String) -> String {
    let task = Process()
    task.launchPath     = "/usr/bin/xcrun"
    task.arguments      = ["xcodebuild", "-list", "-project", projPath]
    let pipe            = Pipe()
    task.standardOutput = pipe
    task.standardError  = Pipe()
    try? task.run()
    task.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

#endif
