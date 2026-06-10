//
//  BTTVersionChecker.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

#if os(macOS)
import Foundation
import PathKit
import XcodeProj

final class BTTVersionChecker {
    private let xcodeprojPath: String

    init(xcodeprojPath: String) {
        self.xcodeprojPath = xcodeprojPath
    }

    // MARK: - Public API
    /// Returns the pinned BlueTriangle version from Package.resolved, or `nil` if not found.
    /// Covers plain xcodeproj, xcworkspace (CocoaPods + SPM), and Package.swift root setups.
    func resolvedVersion() -> String? {
        let projDir  = (xcodeprojPath as NSString).deletingLastPathComponent
        let projName = ((xcodeprojPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let wsDir    = (projDir as NSString).appendingPathComponent("\(projName).xcworkspace")

        let candidates: [String] =
            BTTConstants.packageResolvedCandidates.map {
                (xcodeprojPath as NSString).appendingPathComponent($0)
            } +
            BTTConstants.workspaceResolvedCandidates.map {
                (wsDir as NSString).appendingPathComponent($0)
            } +
            [(projDir as NSString).appendingPathComponent(BTTConstants.rootPackageResolved)]

        return candidates.lazy.compactMap { self.parseVersion(from: $0) }.first
    }

    /// Checks the resolved version and interactively prompts the user when it is too old.
    /// Returns `true` if instrumentation should proceed, `false` if the SDK is not found.
    /// Calls `exit` when the user chooses to update or quit.
    @discardableResult
    func checkAndProceed() -> Bool {
        guard let version = resolvedVersion() else {
            BTTLog.error("Could not find \(BTTConstants.bttProductName) SDK — please add it before proceeding.")
            return false
        }

        guard !Self.isVersion(version, atLeast: BTTConstants.minBTTVersion) else {
            BTTLog.info("\(BTTConstants.bttProductName) \(version) ✓")
            return true
        }

        // Version too old — offer options
        BTTLog.error(
            "\(BTTConstants.bttProductName) \(version) does not support screen auto-tracking " +
            "(requires >= \(BTTConstants.minBTTVersion))."
        )
        BTTLog.info(
            "\nHow would you like to proceed?\n" +
            "  1. Update to the latest release\n" +
            "  2. Update to minimum required version (\(BTTConstants.minBTTVersion))\n" +
            "  3. No — quit\n\n" +
            "Enter 1, 2, or 3: "
        )

        switch readLine()?.trimmingCharacters(in: .whitespaces) ?? "3" {
        case "1":
            guard let latest = fetchLatestVersion() else {
                BTTLog.error("Could not fetch latest version from GitHub — check your internet connection.")
                exit(1)
            }
            guard writeVersion(latest, to: xcodeprojPath) else {
                BTTLog.error("Could not write version to project.pbxproj — update \(BTTConstants.bttProductName) manually to >= \(BTTConstants.minBTTVersion).")
                exit(1)
            }
            BTTLog.success("✓ \(BTTConstants.bttProductName) updated to \(latest).")
            resolvePackages(projPath: xcodeprojPath)
            return true

        case "2":
            guard writeVersion(BTTConstants.minBTTVersion, to: xcodeprojPath) else {
                BTTLog.error("Could not write version to project.pbxproj — update \(BTTConstants.bttProductName) manually to >= \(BTTConstants.minBTTVersion).")
                exit(1)
            }
            BTTLog.success("✓ \(BTTConstants.bttProductName) updated to >= \(BTTConstants.minBTTVersion).")
            resolvePackages(projPath: xcodeprojPath)
            return true

        default:
            BTTLog.warn("Instrumentation cancelled.")
            exit(0)
        }
    }

    // MARK: - Version comparison (static utility)
    static func isVersion(_ a: String, atLeast b: String) -> Bool {
        let av = a.components(separatedBy: ".").compactMap { Int($0) }
        let bv = b.components(separatedBy: ".").compactMap { Int($0) }
        for i in 0..<max(av.count, bv.count) {
            let ai = i < av.count ? av[i] : 0
            let bi = i < bv.count ? bv[i] : 0
            if ai != bi { return ai > bi }
        }
        return true
    }

    // MARK: - Private
    private func parseVersion(from path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let pins: [[String: Any]]
        if let p = json["pins"] as? [[String: Any]] {
            pins = p
        } else if let p = (json["object"] as? [String: Any])?["pins"] as? [[String: Any]] {
            pins = p
        } else {
            return nil
        }

        for pin in pins {
            let identity = (pin["identity"] as? String ?? pin["package"] as? String ?? "").lowercased()
            guard identity.contains("btt-swift-sdk") else { continue }
            return (pin["state"] as? [String: Any])?["version"] as? String
        }
        return nil
    }

    private func fetchLatestVersion() -> String? {
        let slug = BTTConstants.bttPackageURL
            .replacingOccurrences(of: "https://github.com/", with: "")
            .replacingOccurrences(of: ".git", with: "")
        guard let url = URL(string: "https://api.github.com/repos/\(slug)/releases/latest")
        else { return nil }

        var request = URLRequest(url: url, timeoutInterval: BTTConstants.gitHubRequestTimeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        var result: String?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { sem.signal() }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag  = json["tag_name"] as? String
            else { return }
            result = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        }.resume()
        sem.wait()
        return result
    }

    private func writeVersion(_ version: String, to projPath: String) -> Bool {
        guard let xcodeproj = try? XcodeProj(path: Path(projPath)) else { return false }
        let normalized = BTTConstants.bttPackageURL.lowercased().replacingOccurrences(of: ".git", with: "")
        var updated = false
        for ref in xcodeproj.pbxproj.rootObject?.remotePackages ?? [] {
            let url = (ref.repositoryURL ?? "").lowercased().replacingOccurrences(of: ".git", with: "")
            guard url == normalized else { continue }
            ref.versionRequirement = .upToNextMajorVersion(version)
            updated = true
        }
        guard updated else { return false }
        try? xcodeproj.write(path: Path(projPath))
        return true
    }

    private func resolvePackages(projPath: String) {
        let task = Process()
        task.launchPath     = "/usr/bin/xcrun"
        task.arguments      = ["xcodebuild", "-resolvePackageDependencies", "-project", projPath]
        task.standardOutput = Pipe()
        task.standardError  = Pipe()
        guard (try? task.run()) != nil else {
            BTTLog.info("Open Xcode to resolve package dependencies.")
            return
        }
        task.waitUntilExit()
        if task.terminationStatus == 0 {
            BTTLog.success("✓ Package dependencies resolved.")
        } else {
            BTTLog.info("Open Xcode to resolve package dependencies.")
        }
    }
}
#endif
