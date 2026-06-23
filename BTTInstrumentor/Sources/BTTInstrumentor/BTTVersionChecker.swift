//
//  BTTVersionChecker.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

#if os(macOS)
import Foundation

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

    @discardableResult
    func checkAndProceed() -> Bool {
        if BTTConstants.isForkedVersion {
            if !BTTLog.nonInteractive {
                BTTLog.warn("BTTConstants.isForkedVersion = true — version check skipped. Set to false before release.")
                return true
            } else {
                BTTLog.error("BTTConstants.isForkedVersion = true. Production builds require a tagged release >= \(BTTConstants.minBTTVersion). Set isForkedVersion = false before release.")
                return false
            }
        }

        guard let version = resolvedVersion() else {
            BTTLog.error("Could not find \(BTTConstants.bttProductName) SDK — please add it before proceeding.")
            return false
        }

        guard !Self.isVersion(version, atLeast: BTTConstants.minBTTVersion) else {
            BTTLog.info("\(BTTConstants.bttProductName) \(version) ✓")
            return true
        }

        BTTLog.error(
            "\(BTTConstants.bttProductName) \(version) does not support SwiftUI screen auto-tracking. " +
            "Please update \(BTTConstants.bttProductName) to >= \(BTTConstants.minBTTVersion) in Xcode " +
            "(File → Packages → Update to Latest Package Versions), then quit xcode and re-run BTTInstrumentor."
        )
        return false
    }

    // MARK: - Version comparison
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

    /// Runs `path --version` and returns the last whitespace-separated token.
    static func binaryVersion(at path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let task = Process()
        task.launchPath     = path
        task.arguments      = ["--version"]
        let pipe            = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        try? task.run()
        task.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: " ").last
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
}
#endif
