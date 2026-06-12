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

final class BTTProjectResolver {
    private let args: BTTArgs
    private let fm = FileManager.default

    init(args: BTTArgs) {
        self.args = args
    }

    // MARK: - Xcodeproj resolution
    /// Finds the .xcodeproj to operate on.
    func resolveXcodeproj() -> String? {
        if let p = args.projectPath, fm.fileExists(atPath: p) { return p }
        let found = discoverXcodeprojPaths()
        
        switch found.count {
        case 0: return nil
        case 1: return found[0]
        default:
            guard isatty(STDIN_FILENO) != 0 else { return resolveNonInteractive(from: found) }
            return resolveInteractive(from: found)
        }
    }

    // MARK: - Non-interactive
    private func resolveNonInteractive(from found: [String]) -> String {
        let rootPath = args.rootPath
        let directChildren = found.filter { ($0 as NSString).deletingLastPathComponent == rootPath }
        if !directChildren.isEmpty {
            if directChildren.count == 1 { return directChildren[0] }
            
            let store = BTTTargetStore(projectDir: rootPath)
            if let saved = store.savedXcodeprojPath(),
               directChildren.contains(saved),
               fm.fileExists(atPath: saved) {
                return saved
            }
            return directChildren[0]
        }
        return found[0]
    }

    // MARK: - Interactive
    private func resolveInteractive(from found: [String]) -> String {
        BTTLog.prompt("\nMultiple .xcodeproj files found. Which one do you want to use?\n")
        found.enumerated().forEach { i, p in
            BTTLog.prompt("\n\(i + 1). \(URL(fileURLWithPath: p).lastPathComponent)")
        }
        BTTLog.prompt("\nEnter the number: ")

        if let input = readLine()?.trimmingCharacters(in: .whitespaces),
           let idx   = Int(input),
           (1...found.count).contains(idx) {
            return found[idx - 1]
        }
        return found[0]
    }

    // MARK: - Targets
    /// Returns all target names from `xcodebuild -list`.
    func getTargets(in xcodeprojPath: String) -> [String] {
        var targets   = [String]()
        var seen      = Set<String>()
        var inSection = false

        for line in runXcodebuildList(for: xcodeprojPath).components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "Targets:"  { inSection = true; continue }
            guard inSection           else { continue }
            if trimmed.isEmpty        { continue }
            if trimmed.hasSuffix(":") { break }
            if seen.insert(trimmed).inserted { targets.append(trimmed) }
        }
        return targets
    }

    // MARK: - Swift files
    /// Returns all Swift files for a target by merging three sources:
    /// 1. File references declared in xcodeproj
    /// 2. Swift files from local SPM package dependencies
    /// 3. Folder scan fallback when the target uses a folder reference
    func getSwiftFiles(for target: String, in xcodeprojPath: String) -> [String] {
        var files = [String]()
        var seen  = Set<String>()

        func add(_ incoming: [String]) {
            incoming.filter { seen.insert($0).inserted }.forEach { files.append($0) }
        }

        add(sourceFileRefs(for: target, in: xcodeprojPath))
        add(localPackageFiles(for: target, in: xcodeprojPath))

        if files.isEmpty {
            let projDir      = Path(xcodeprojPath).parent().string
            let targetFolder = (projDir as NSString).appendingPathComponent(target)
            if fm.fileExists(atPath: targetFolder) { add(scanSwiftFiles(in: targetFolder)) }
        }
        return files
    }

    // MARK: - Private helpers
    private func discoverXcodeprojPaths() -> [String] {
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: args.rootPath),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [String] = []
        let rootDepth = URL(fileURLWithPath: args.rootPath).pathComponents.count

        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - rootDepth
            if depth > BTTConstants.xcodeprojSearchDepth { enumerator.skipDescendants(); continue }
            if url.pathExtension == "xcodeproj" { found.append(url.path) }
        }
        return found
    }

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

    private func localPackageFiles(for target: String, in xcodeprojPath: String) -> [String] {
        guard let proj   = try? XcodeProj(path: Path(xcodeprojPath)),
              let native = proj.pbxproj.nativeTargets.first(where: { $0.name == target })
        else { return [] }

        let packagePathMap  = resolvedLocalPackages(for: xcodeprojPath)
        let dependencyNames = (native.packageProductDependencies ?? []).compactMap { $0.productName }
        var visitedPaths    = Set<String>()

        return dependencyNames
            .compactMap { name in
                packagePathMap[name] ?? packagePathMap.first(where: { name.hasPrefix($0.key) })?.value
            }
            .filter { visitedPaths.insert($0).inserted }
            .flatMap { scanSwiftFiles(in: $0) }
    }

    private func resolvedLocalPackages(for projPath: String) -> [String: String] {
        var packageMap = [String: String]()
        var inSection  = false

        for line in runXcodebuildList(for: projPath).components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "Resolved source packages:"         { inSection = true; continue }
            if trimmed.hasPrefix("Information about project") { break }
            guard inSection, !trimmed.isEmpty,
                  let separator = trimmed.range(of: ": ")     else { continue }

            let name = String(trimmed[trimmed.startIndex..<separator.lowerBound])
            let path = String(trimmed[separator.upperBound...])
            guard path.hasPrefix("/") else { continue }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
            packageMap[name] = path
        }
        return packageMap
    }

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
                  !BTTConstants.excludedScanPaths.contains(where: { path.contains($0) })
            else { continue }
            files.append(path)
        }
        return files
    }

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
}

#endif
