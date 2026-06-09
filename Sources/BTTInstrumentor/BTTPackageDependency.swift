//
//  BTTPackageDependency.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 09/06/26.
//

#if os(macOS)
import Foundation
import PathKit
import XcodeProj

// MARK: - Add

/// Adds BTTSwiftUITracker as a package product dependency to the target.
/// Returns true if added by us, false if already present.
@discardableResult
func addBTTSwiftUITrackerDependency(xcodeprojPath: String, targetName: String) -> Bool {
    guard let xcodeproj = try? XcodeProj(path: Path(xcodeprojPath)),
          let target = xcodeproj.pbxproj.nativeTargets.first(where: { $0.name == targetName })
    else { return false }

    let deps = target.packageProductDependencies ?? []
    guard !deps.contains(where: { $0.productName == "BTTSwiftUITracker" }) else { return true }

    guard let bttPackage = deps.first(where: { $0.productName == "BlueTriangle" })?.package else {
        BTTLog.warn("BlueTriangle package not found in '\(targetName)' — skipping BTTSwiftUITracker")
        return false
    }

    let dep = XCSwiftPackageProductDependency(productName: "BTTSwiftUITracker")
    dep.package = bttPackage
    xcodeproj.pbxproj.add(object: dep)
    target.packageProductDependencies = deps + [dep]
    try? xcodeproj.write(path: Path(xcodeprojPath))
    return true
}

// MARK: - Remove
/// Removes BTTSwiftUITracker only if BTTInstrumentor originally added it.
func removeBTTSwiftUITrackerDependency(xcodeprojPath: String, targetName: String, store: BTTTargetStore) {
    guard store.didAddBTTSwiftUITracker(for: targetName) else { return }
    guard let xcodeproj = try? XcodeProj(path: Path(xcodeprojPath)),
          let target = xcodeproj.pbxproj.nativeTargets.first(where: { $0.name == targetName })
    else { return }

    let before = target.packageProductDependencies ?? []
    let after  = before.filter { $0.productName != "BTTSwiftUITracker" }
    guard after.count != before.count else { return }

    before.filter { $0.productName == "BTTSwiftUITracker" }
          .forEach { xcodeproj.pbxproj.delete(object: $0) }
    target.packageProductDependencies = after
    try? xcodeproj.write(path: Path(xcodeprojPath))
}

#endif
