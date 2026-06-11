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

/// Resolves Xcode project artifacts: the .xcodeproj path, target names,
/// and the Swift source files belonging to each target.
final class BTTProjectResolver {
    private let args: BTTArgs
    private let fm = FileManager.default

    init(args: BTTArgs) {
        self.args = args
    }

    /// Finds the .xcodeproj from args or by searching `rootPath` up to
    /// BTTConstants.xcodeprojSearchDepth` levels deep.
    /// Prompts the user to pick one when multiple projects are found (interactive only).
    func resolveXcodeproj() -> String? {
        BTTLog.verbose("resolveXcodeproj — args.projectPath='\(args.projectPath ?? "nil")' rootPath='\(args.rootPath)'")

        if let p = args.projectPath {
            if fm.fileExists(atPath: p) {
                BTTLog.verbose("Using explicit --projectPath: \(p)")
                return p
            } else {
                BTTLog.verbose("Explicit --projectPath not found on disk: \(p)")
            }
        }

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: args.rootPath),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            BTTLog.verbose("Could not create directory enumerator for rootPath: \(args.rootPath)")
            return nil
        }

        var found: [String] = []
        let rootDepth = URL(fileURLWithPath: args.rootPath).pathComponents.count
        BTTLog.verbose("Scanning for .xcodeproj (maxDepth=\(BTTConstants.xcodeprojSearchDepth)) under: \(args.rootPath)")

        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - rootDepth
            if depth > BTTConstants.xcodeprojSearchDepth {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension == "xcodeproj" {
                BTTLog.verbose("  Found: \(url.path)")
                found.append(url.path)
            }
        }

        BTTLog.verbose("Found \(found.count) .xcodeproj file(s) in \(args.rootPath)")

        switch found.count {
        case 0:
            BTTLog.verbose("No .xcodeproj found — returning nil")
            return nil
        case 1:
            BTTLog.verbose("Single .xcodeproj found — using: \(found[0])")
            return found[0]
        default:
            // Non-interactive (scheme pre-action) — pick first without prompting
            if isatty(STDIN_FILENO) == 0 {
                BTTLog.verbose("Non-interactive mode — auto-selecting first: \(found[0])")
                return found[0]
            }

            BTTLog.info("\nMultiple .xcodeproj files found. Which one do you want to use?\n")
            found.enumerated().forEach { i, p in
                BTTLog.info("\(i + 1). \(URL(fileURLWithPath: p).lastPathComponent) (\(p))")
            }
            BTTLog.info("\nEnter the number: ")

            if let input = readLine()?.trimmingCharacters(in: .whitespaces),
               let idx   = Int(input),
               (1...found.count).contains(idx) {
                BTTLog.verbose("User chose index \(idx) → \(found[idx - 1])")
                return found[idx - 1]
            }

            BTTLog.verbose("Invalid input — defaulting to first: \(found[0])")
            return found[0]
        }
    }

    /// Returns all target names from `xcodebuild -list`.
    func getTargets(in xcodeprojPath: String) -> [String] {
        BTTLog.verbose("getTargets — running xcodebuild -list for: \(xcodeprojPath)")
        var targets   = [String]()
        var seen      = Set<String>()
        var inSection = false
        let output    = runXcodebuildList(for: xcodeprojPath)

        BTTLog.verbose("xcodebuild -list output (\(output.components(separatedBy: "\n").count) lines)")

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "Targets:"  { inSection = true; continue }
            guard inSection           else { continue }
            if trimmed.isEmpty        { continue }
            if trimmed.hasSuffix(":") {
                BTTLog.verbose("  End of Targets section (next section: '\(trimmed)')")
                break
            }
            if seen.insert(trimmed).inserted {
                targets.append(trimmed)
                BTTLog.verbose("  Target: '\(trimmed)'")
            } else {
                BTTLog.verbose("  Duplicate target skipped: '\(trimmed)'")
            }
        }

        BTTLog.verbose("getTargets result (\(targets.count)): \(targets.joined(separator: ", "))")
        return targets
    }

    // MARK: - Swift files

    /// Returns all Swift files for a target by merging three sources:
    /// 1. File references declared in xcodeproj
    /// 2. Swift files from local SPM package dependencies
    /// 3. Folder scan fallback when the target uses a folder reference
    func getSwiftFiles(for target: String, in xcodeprojPath: String) -> [String] {
        BTTLog.verbose("getSwiftFiles — target='\(target)' xcodeproj='\(URL(fileURLWithPath: xcodeprojPath).lastPathComponent)'")
        var files = [String]()
        var seen  = Set<String>()

        func add(_ incoming: [String], source: String) {
            let unique = incoming.filter { seen.insert($0).inserted }
            BTTLog.verbose("  [\(source)] \(unique.count) unique file(s) added (of \(incoming.count) total)")
            unique.forEach { files.append($0) }
        }

        let xcprojFiles = sourceFileRefs(for: target, in: xcodeprojPath)
        add(xcprojFiles, source: "xcodeproj file refs")

        let spmFiles = localPackageFiles(for: target, in: xcodeprojPath)
        add(spmFiles, source: "local SPM packages")

        if files.isEmpty {
            let projDir      = Path(xcodeprojPath).parent().string
            let targetFolder = (projDir as NSString).appendingPathComponent(target)
            BTTLog.verbose("  No files from xcodeproj/SPM — trying folder scan fallback: \(targetFolder)")
            if fm.fileExists(atPath: targetFolder) {
                let scanned = scanSwiftFiles(in: targetFolder)
                add(scanned, source: "folder scan fallback '\(target)/'")
            } else {
                BTTLog.verbose("  Fallback folder does not exist: \(targetFolder)")
            }
        }

        BTTLog.verbose("getSwiftFiles total for '\(target)': \(files.count) file(s)")
        return files
    }

    // MARK: - Private

    private func sourceFileRefs(for target: String, in xcodeprojPath: String) -> [String] {
        BTTLog.verbose("  sourceFileRefs — loading XcodeProj...")
        let projDir = Path(xcodeprojPath).parent()
        guard let proj    = try? XcodeProj(path: Path(xcodeprojPath)) else {
            BTTLog.verbose("  Failed to load XcodeProj at '\(xcodeprojPath)'")
            return []
        }
        guard let native  = proj.pbxproj.nativeTargets.first(where: { $0.name == target }) else {
            BTTLog.verbose("  nativeTarget '\(target)' not found in pbxproj")
            return []
        }
        guard let sources = try? native.sourceFiles() else {
            BTTLog.verbose("  sourceFiles() threw for target '\(target)'")
            return []
        }

        BTTLog.verbose("  \(sources.count) source file ref(s) in target '\(target)'")
        var resolved = [String]()
        for ref in sources {
            guard let relativePath = ref.path, relativePath.hasSuffix(".swift") else {
                BTTLog.verbose("    Skipping non-Swift ref: \(ref.path ?? "(nil)")")
                continue
            }
            let fullPath = (try? ref.fullPath(sourceRoot: projDir)) ?? (projDir + Path(relativePath))
            if fm.fileExists(atPath: fullPath.string) {
                resolved.append(fullPath.string)
                BTTLog.verbose("    ✓ \(relativePath)")
            } else {
                BTTLog.verbose("    ✗ File not found on disk: \(fullPath.string)")
            }
        }
        return resolved
    }

    private func localPackageFiles(for target: String, in xcodeprojPath: String) -> [String] {
        BTTLog.verbose("  localPackageFiles — loading XcodeProj for SPM dependencies...")
        guard let proj   = try? XcodeProj(path: Path(xcodeprojPath)) else {
            BTTLog.verbose("  Failed to load XcodeProj")
            return []
        }
        guard let native = proj.pbxproj.nativeTargets.first(where: { $0.name == target }) else {
            BTTLog.verbose("  nativeTarget '\(target)' not found")
            return []
        }

        let packagePathMap  = resolvedLocalPackages(for: xcodeprojPath)
        let dependencyNames = (native.packageProductDependencies ?? []).compactMap { $0.productName }
        BTTLog.verbose("  Package dependencies for '\(target)': \(dependencyNames.isEmpty ? "(none)" : dependencyNames.joined(separator: ", "))")
        BTTLog.verbose("  Resolved local packages map (\(packagePathMap.count)): \(packagePathMap.map { "\($0.key)→\($0.value)" }.joined(separator: ", "))")

        var visitedPaths = Set<String>()
        var result       = [String]()

        for name in dependencyNames {
            if let path = packagePathMap[name] {
                BTTLog.verbose("  Exact match '\(name)' → \(path)")
                if visitedPaths.insert(path).inserted {
                    let scanned = scanSwiftFiles(in: path)
                    BTTLog.verbose("    Scanned \(scanned.count) Swift file(s) in \(path)")
                    result.append(contentsOf: scanned)
                }
            } else if let entry = packagePathMap.first(where: { name.hasPrefix($0.key) }) {
                BTTLog.verbose("  Prefix match '\(name)' → '\(entry.key)' at \(entry.value)")
                if visitedPaths.insert(entry.value).inserted {
                    let scanned = scanSwiftFiles(in: entry.value)
                    BTTLog.verbose("    Scanned \(scanned.count) Swift file(s) in \(entry.value)")
                    result.append(contentsOf: scanned)
                }
            } else {
                BTTLog.verbose("  No local path found for package dependency '\(name)' — may be remote")
            }
        }
        return result
    }

    private func resolvedLocalPackages(for projPath: String) -> [String: String] {
        BTTLog.verbose("  resolvedLocalPackages — parsing 'Resolved source packages' from xcodebuild -list...")
        var packageMap = [String: String]()
        var inSection  = false

        for line in runXcodebuildList(for: projPath).components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "Resolved source packages:"              { inSection = true; continue }
            if trimmed.hasPrefix("Information about project")      { break }
            guard inSection, !trimmed.isEmpty,
                  let separator = trimmed.range(of: ": ")          else { continue }

            let name = String(trimmed[trimmed.startIndex..<separator.lowerBound])
            let path = String(trimmed[separator.upperBound...])
            guard path.hasPrefix("/") else {
                BTTLog.verbose("    Skipping non-absolute path for '\(name)': \(path)")
                continue
            }

            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                packageMap[name] = path
                BTTLog.verbose("    Local package: '\(name)' → \(path)")
            } else {
                BTTLog.verbose("    Path not found or not a directory for '\(name)': \(path)")
            }
        }

        BTTLog.verbose("  resolvedLocalPackages found \(packageMap.count) local package(s)")
        return packageMap
    }

    private func scanSwiftFiles(in root: String) -> [String] {
        BTTLog.verbose("  scanSwiftFiles — root: \(root)")
        var files = [String]()
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root).standardized,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            BTTLog.verbose("  Could not create enumerator for: \(root)")
            return files
        }

        var excluded = 0
        for case let url as URL in enumerator {
            let path = url.standardized.path
            guard path.hasSuffix(".swift") else { continue }
            if BTTConstants.excludedScanPaths.contains(where: { path.contains($0) }) {
                BTTLog.verbose("    Excluded: \(path)")
                excluded += 1
                continue
            }
            files.append(path)
            BTTLog.verbose("    + \(URL(fileURLWithPath: path).lastPathComponent)")
        }

        BTTLog.verbose("  scanSwiftFiles result: \(files.count) file(s), \(excluded) excluded")
        return files
    }

    private func runXcodebuildList(for projPath: String) -> String {
        BTTLog.verbose("  runXcodebuildList — xcrun xcodebuild -list -project \(projPath)")
        let task = Process()
        task.launchPath     = "/usr/bin/xcrun"
        task.arguments      = ["xcodebuild", "-list", "-project", projPath]
        let pipe            = Pipe()
        let errPipe         = Pipe()
        task.standardOutput = pipe
        task.standardError  = errPipe
        try? task.run()
        task.waitUntilExit()

        let output   = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errOutput = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        BTTLog.verbose("  xcodebuild -list exit code: \(task.terminationStatus)")
        if !errOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            BTTLog.verbose("  xcodebuild -list stderr: \(errOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }
}

#endif
