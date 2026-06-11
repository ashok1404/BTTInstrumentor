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

        BTTLog.verbose("resolvedVersion — searching \(candidates.count) Package.resolved candidate(s):")
        candidates.enumerated().forEach { i, path in
            let exists = FileManager.default.fileExists(atPath: path)
            BTTLog.verbose("  [\(i + 1)] \(exists ? "✓" : "✗") \(path)")
        }

        for candidate in candidates {
            if let version = parseVersion(from: candidate) {
                BTTLog.verbose("  Found BlueTriangle version '\(version)' in: \(candidate)")
                return version
            }
        }

        BTTLog.verbose("  No BlueTriangle version found in any candidate.")
        return nil
    }

    /// Checks the resolved version and returns `true` if instrumentation should proceed.
    ///
    /// - If `BTTConstants.isForkedVersion` is `true`:
    ///     Interactive  → skips version check with a warning (dev/fork branch allowed).
    ///     Non-interactive → blocks with an error (production builds require a release).
    /// - Otherwise performs a normal version gate against `BTTConstants.minBTTVersion`.
    @discardableResult
    func checkAndProceed() -> Bool {
        BTTLog.verbose("checkAndProceed — isForkedVersion=\(BTTConstants.isForkedVersion) minBTTVersion=\(BTTConstants.minBTTVersion) isatty=\(isatty(STDIN_FILENO))")

        // Fork/dev branch gate
        if BTTConstants.isForkedVersion {
            if isatty(STDIN_FILENO) != 0 {
                BTTLog.verbose("isForkedVersion=true + interactive → version check skipped (dev/fork branch allowed).")
                BTTLog.warn("BTTConstants.isForkedVersion = true — version check skipped. Set to false before release.")
                return true
            } else {
                BTTLog.verbose("isForkedVersion=true + non-interactive → blocking (production builds require a tagged release).")
                BTTLog.error("BTTConstants.isForkedVersion = true. Production builds require a tagged release >= \(BTTConstants.minBTTVersion). Set isForkedVersion = false before release.")
                return false
            }
        }

        guard let version = resolvedVersion() else {
            BTTLog.verbose("resolvedVersion() returned nil — SDK not found in Package.resolved.")
            BTTLog.error("Could not find \(BTTConstants.bttProductName) SDK — please add it before proceeding.")
            return false
        }

        let meetsMin = Self.isVersion(version, atLeast: BTTConstants.minBTTVersion)
        BTTLog.verbose("Version comparison: '\(version)' >= '\(BTTConstants.minBTTVersion)' → \(meetsMin)")

        guard !meetsMin else {
            BTTLog.info("\(BTTConstants.bttProductName) \(version) ✓")
            return true
        }

        BTTLog.error(
            "\(BTTConstants.bttProductName) \(version) does not support SwiftUI screen auto-tracking. " +
            "Please update to >= \(BTTConstants.minBTTVersion) in Xcode " +
            "(File → Packages → Update to Latest Package Versions), then re-run BTTInstrumentor."
        )
        return false
    }

    // MARK: - Version comparison
    static func isVersion(_ a: String, atLeast b: String) -> Bool {
        let av = a.components(separatedBy: ".").compactMap { Int($0) }
        let bv = b.components(separatedBy: ".").compactMap { Int($0) }
        BTTLog.verbose("isVersion('\(a)', atLeast: '\(b)') — av=\(av) bv=\(bv)")
        for i in 0..<max(av.count, bv.count) {
            let ai = i < av.count ? av[i] : 0
            let bi = i < bv.count ? bv[i] : 0
            if ai != bi {
                BTTLog.verbose("  Component[\(i)]: \(ai) vs \(bi) → \(ai > bi ? "passes" : "fails")")
                return ai > bi
            }
        }
        BTTLog.verbose("  All components equal → passes (exactly meets minimum)")
        return true
    }

    // MARK: - Private

    private func parseVersion(from path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else {
            BTTLog.verbose("  parseVersion — file not found: \(path)")
            return nil
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            BTTLog.verbose("  parseVersion — could not read file: \(path)")
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            BTTLog.verbose("  parseVersion — JSON parse failed for: \(path)")
            return nil
        }

        let pins: [[String: Any]]
        if let p = json["pins"] as? [[String: Any]] {
            pins = p
            BTTLog.verbose("  parseVersion — using v2 'pins' format (\(p.count) pin(s)) in: \(URL(fileURLWithPath: path).lastPathComponent)")
        } else if let p = (json["object"] as? [String: Any])?["pins"] as? [[String: Any]] {
            pins = p
            BTTLog.verbose("  parseVersion — using v1 'object.pins' format (\(p.count) pin(s)) in: \(URL(fileURLWithPath: path).lastPathComponent)")
        } else {
            BTTLog.verbose("  parseVersion — no 'pins' key found in: \(path)")
            return nil
        }

        for pin in pins {
            let identity = (pin["identity"] as? String ?? pin["package"] as? String ?? "").lowercased()
            BTTLog.verbose("    Pin identity: '\(identity)'")
            guard identity.contains("btt-swift-sdk") else { continue }
            let version = (pin["state"] as? [String: Any])?["version"] as? String
            BTTLog.verbose("    Matched btt-swift-sdk — version: '\(version ?? "nil")'")
            return version
        }

        BTTLog.verbose("  parseVersion — no btt-swift-sdk pin found in: \(URL(fileURLWithPath: path).lastPathComponent)")
        return nil
    }
}
#endif
