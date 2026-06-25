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

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: args.rootPath),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var found: [String] = []
        let rootDepth = URL(fileURLWithPath: args.rootPath).pathComponents.count

        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - rootDepth
            if depth > BTTConstants.xcodeprojSearchDepth { enumerator.skipDescendants(); continue }
            if url.pathExtension == "xcodeproj" { found.append(url.path) }
        }

        BTTLog.verbose("Found \(found.count) .xcodeproj file(s) in \(args.rootPath)")
        switch found.count {
        case 0: return nil
        case 1: BTTLog.verbose("Using: \(found[0])"); return found[0]
        default:
            guard !args.nonInteractive else {
                let rootStore = BTTTargetStore(projectDir: args.rootPath)
                let selected: String

                if let savedName = rootStore.savedXcodeprojName(),
                   let match = found.first(where: {
                       URL(fileURLWithPath: $0).lastPathComponent == savedName && fm.fileExists(atPath: $0)
                   }) {
                    selected = match
                } else {
                    selected = found[0]
                }
                BTTLog.verbose("Non-interactive: selected '\(URL(fileURLWithPath: selected).lastPathComponent)'")
                return selected
            }

            BTTLog.prompt("\nMultiple .xcodeproj files found. Which one do you want to use?\n\n")
            found.enumerated().forEach { i, p in
                let name = URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent
                BTTLog.prompt("  \(i + 1). \(name).xcodeproj\n")
            }
            BTTLog.prompt("\nEnter the number: ")

            if let input = readLine()?.trimmingCharacters(in: .whitespaces),
               let idx   = Int(input),
               (1...found.count).contains(idx) {
                return found[idx - 1]
            }
            return found[0]
        }
    }

    // MARK: - Targets.
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
        BTTLog.verbose("Targets found (\(targets.count)): \(targets.joined(separator: ", "))")
        return targets
    }

    // MARK: - Swift files
    /// Returns all Swift files for a target by merging two sources:
    /// 1. File references declared in xcodeproj
    /// 2. Folder scan fallback when the target uses a folder reference
    func getSwiftFiles(for target: String, in xcodeprojPath: String) -> [String] {
        var files = [String]()
        var seen  = Set<String>()

        func add(_ incoming: [String]) {
            incoming.filter { seen.insert($0).inserted }.forEach { files.append($0) }
        }

        add(sourceFileRefs(for: target, in: xcodeprojPath))

        if files.isEmpty {
            let projDir      = Path(xcodeprojPath).parent().string
            let targetFolder = (projDir as NSString).appendingPathComponent(target)
            if fm.fileExists(atPath: targetFolder) { add(scanSwiftFiles(in: targetFolder)) }
        }
        BTTLog.verbose("Swift files resolved (\(files.count)) for target: \(target)")
        return files
    }

    // MARK: - Private

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
