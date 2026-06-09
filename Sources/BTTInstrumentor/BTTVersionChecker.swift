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

let kMinBTTVersion = "3.15.13"
let kBTTPackageURL = "https://github.com/blue-triangle-tech/btt-swift-sdk.git"

// MARK: - Version check

/// Returns the pinned BlueTriangle version from Package.resolved, or nil if not found.
/// Covers all SPM setups: plain xcodeproj, xcworkspace (CocoaPods+SPM), and Package.swift root.
func resolvedBTTVersion(xcodeprojPath: String) -> String? {
    let projDir = (xcodeprojPath as NSString).deletingLastPathComponent

    // Derive workspace name — MyApp.xcodeproj → MyApp.xcworkspace
    let projName   = ((xcodeprojPath as NSString).lastPathComponent as NSString).deletingPathExtension
    let workspaceDir = (projDir as NSString).appendingPathComponent("\(projName).xcworkspace")

    let candidates = [
        // 1. xcodeproj-embedded workspace (most common — plain SPM in Xcode)
        (xcodeprojPath as NSString)
            .appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved"),
        // 2. xcodeproj-embedded workspace — older Xcode format
        (xcodeprojPath as NSString)
            .appendingPathComponent("project.xcworkspace/xcshareddata/Package.resolved"),
        // 3. Sibling .xcworkspace (CocoaPods + SPM — workspace is next to xcodeproj)
        (workspaceDir as NSString)
            .appendingPathComponent("xcshareddata/swiftpm/Package.resolved"),
        // 4. Sibling .xcworkspace — older Xcode format
        (workspaceDir as NSString)
            .appendingPathComponent("xcshareddata/Package.resolved"),
        // 5. Package.swift root project (projDir is the package root)
        (projDir as NSString)
            .appendingPathComponent("Package.resolved")
    ]
    for path in candidates {
        if let version = parseBTTVersion(from: path) { return version }
    }
    return nil
}

private func parseBTTVersion(from path: String) -> String? {
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

private func isVersion(_ a: String, atLeast b: String) -> Bool {
    let av = a.components(separatedBy: ".").compactMap { Int($0) }
    let bv = b.components(separatedBy: ".").compactMap { Int($0) }
    for i in 0..<max(av.count, bv.count) {
        let ai = i < av.count ? av[i] : 0
        let bi = i < bv.count ? bv[i] : 0
        if ai != bi { return ai > bi }
    }
    return true
}

// MARK: - Update SPM package in xcodeproj

/// Writes a new version requirement for the BTT package into project.pbxproj.
private func writeBTTVersion(_ version: String, xcodeprojPath: String) -> Bool {
    guard let xcodeproj = try? XcodeProj(path: Path(xcodeprojPath)) else { return false }
    var updated = false
    let normalized = kBTTPackageURL.lowercased().replacingOccurrences(of: ".git", with: "")
    for ref in xcodeproj.pbxproj.rootObject?.remotePackages ?? [] {
        let url = (ref.repositoryURL ?? "").lowercased().replacingOccurrences(of: ".git", with: "")
        guard url == normalized else { continue }
        ref.versionRequirement = XCRemoteSwiftPackageReference.VersionRequirement.upToNextMajorVersion(version)
        updated = true
    }
    guard updated else { return false }
    try? xcodeproj.write(path: Path(xcodeprojPath))
    return true
}

/// Fetches the latest release tag from GitHub for kBTTPackageURL.
private func fetchLatestBTTVersion() -> String? {
    let slug = kBTTPackageURL
        .replacingOccurrences(of: "https://github.com/", with: "")
        .replacingOccurrences(of: ".git", with: "")
    guard let url = URL(string: "https://api.github.com/repos/\(slug)/releases/latest") else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 10)
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

// MARK: - Gate

/// Checks the resolved BTT version and prompts the user if it is too old.
/// Returns true if instrumentation should proceed, exits otherwise.
func checkBTTVersionAndProceed(xcodeprojPath: String) -> Bool {
    guard let version = resolvedBTTVersion(xcodeprojPath: xcodeprojPath) else {
        BTTLog.warn("Could not read BlueTriangle version — proceeding anyway.")
        return true
    }

    guard !isVersion(version, atLeast: kMinBTTVersion) else {
        BTTLog.info("BlueTriangle \(version) ✓")
        return true
    }

    // Too old — offer options
    BTTLog.error("BlueTriangle \(version) does not support screen auto-tracking (requires >= \(kMinBTTVersion)).")
    BTTLog.info(
        "\nHow would you like to proceed?\n" +
        "  1. Update to the latest release\n" +
        "  2. Update to minimum required version (\(kMinBTTVersion))\n" +
        "  3. No — quit\n\n" +
        "Enter 1, 2, or 3: "
    )

    switch readLine()?.trimmingCharacters(in: .whitespaces) ?? "3" {
    case "1":
        guard let latest = fetchLatestBTTVersion(), writeBTTVersion(latest, xcodeprojPath: xcodeprojPath) else {
            BTTLog.error("Update failed — please update BlueTriangle manually to >= \(kMinBTTVersion).")
            exit(1)
        }
        BTTLog.success("✓ BlueTriangle updated to \(latest).")
        BTTLog.info("Re-open Xcode to resolve the package, then re-run BTTInstrumentor.")
        exit(0)

    case "2":
        guard writeBTTVersion(kMinBTTVersion, xcodeprojPath: xcodeprojPath) else {
            BTTLog.error("Update failed — please update BlueTriangle manually to >= \(kMinBTTVersion).")
            exit(1)
        }
        BTTLog.success("✓ BlueTriangle updated to >= \(kMinBTTVersion).")
        BTTLog.info("Re-open Xcode to resolve the package, then re-run BTTInstrumentor.")
        exit(0)

    default:
        BTTLog.warn("Instrumentation cancelled.")
        exit(0)
    }
}

#endif
