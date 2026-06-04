//
//  ProjectResolve.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//


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

func resolveAllLocalPackages(projPath: String) -> [String: String] {
    let output = xcodebuildList(projPath: projPath)
    var packages: [String: String] = [:]
    for line in output.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.components(separatedBy: ": ")
        guard parts.count == 2 else { continue }
        let name = parts[0].trimmingCharacters(in: .whitespaces)
        let path = parts[1].trimmingCharacters(in: .whitespaces)
        guard path.hasPrefix("/") else { continue }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
        packages[name] = path
    }
    return packages
}

// MARK: - Make selection
func select(from options: [String], prompt: String, allLabel: String) -> [String] {
    print("\n\(prompt)\n")
    for (i, opt) in options.enumerated() {
        print("\(i + 1). \(opt)")
    }
    BTTLog.info("\(options.count + 1). \(allLabel)")
    BTTLog.info("\nEnter the number of the \(prompt.lowercased().contains("target") ? "target" : "scheme") to instrument: ")
    
    if let input = readLine()?.trimmingCharacters(in: .whitespaces),
       let idx = Int(input) {
        if idx == options.count + 1 { return options }
        if idx >= 1 && idx <= options.count { return [options[idx - 1]] }
    }
    return [options[0]]
}

// MARK: - Resolve files

func resolveFiles(args: BTTArgs) -> [String] {
    let root = args.rootPath
    var xcodeproj: String

    let found = findXcodeprojFiles(in: root)

    if let p = args.projectPath, fm.fileExists(atPath: p) {
        xcodeproj = p
    } else if found.isEmpty {
        return findAllSwiftFiles(in: root)
    } else if found.count == 1 {
        xcodeproj = found[0]
    } else {
        let names = found.map { ($0 as NSString).lastPathComponent }
        let sel = select(from: names, prompt: "Multiple projects found:", allLabel: "all projects")
        xcodeproj = found.first { ($0 as NSString).lastPathComponent == sel[0] } ?? found[0]
    }

    BTTLog.info("Project: \((xcodeproj as NSString).lastPathComponent)")

    let targets = getTargets(from: xcodeproj)
    var selectedTargets: [String] = []

    if let t = args.target {
        selectedTargets = [t]
        BTTLog.info("Target: \(t)")
    } else if targets.isEmpty {
        return findAllSwiftFiles(in: (xcodeproj as NSString).deletingLastPathComponent)
    } else {
        BTTLog.info("\nFetching targets for \((xcodeproj as NSString).lastPathComponent)...")
        selectedTargets = select(
            from: targets,
            prompt: "Which target do you want to instrument?",
            allLabel: "all targets"
        )
    }

    var selectedScheme: String? = args.scheme
    let allSchemes = getAllSchemes(from: xcodeproj)

    if selectedScheme == nil && !allSchemes.isEmpty {
        BTTLog.info("\nFetching all available schemes for \((xcodeproj as NSString).lastPathComponent)...")
        let sel = select(
            from: allSchemes,
            prompt: "Which scheme do you want to instrument?",
            allLabel: "all schemes"
        )
        selectedScheme = sel.count == 1 ? sel[0] : nil
        if let s = selectedScheme { print("Scheme: \(s)") }
    }

    var allFiles: [String] = []
    var seen = Set<String>()

    func addFiles(_ files: [String]) {
        for f in files where !seen.contains(f) { seen.insert(f); allFiles.append(f) }
    }

    if let scheme = selectedScheme {
        if targets.contains(scheme) {
            addFiles(getSourceFiles(for: scheme, in: xcodeproj))
        } else {
            let packages = resolveAllLocalPackages(projPath: xcodeproj)
            if let pkgPath = packages[scheme] {
                BTTLog.info("Package path: \(pkgPath)")
                addFiles(findAllSwiftFiles(in: pkgPath))
            } else {
                BTTLog.error("Error: '\(scheme)' is a remote package — cannot inject source files.")
                exit(1)
            }
        }
    } else {
        for target in selectedTargets {
            addFiles(getSourceFiles(for: target, in: xcodeproj))
        }
        for (_, path) in resolveAllLocalPackages(projPath: xcodeproj) {
            addFiles(findAllSwiftFiles(in: path))
        }
    }

    if allFiles.isEmpty {
        BTTLog.error("Error: No Swift files found for the selected target/scheme.")
        exit(1)
    }

    BTTLog.info("Files to process: \(allFiles.count)")
    return allFiles
}
