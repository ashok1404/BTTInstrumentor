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

/// Adds and removes the `BTTSwiftUITracker` package product dependency
final class BTTPackageDependency {
    private let xcodeprojPath: String

    init(xcodeprojPath: String) {
        self.xcodeprojPath = xcodeprojPath
    }

    // MARK: - Add

    /// Adds the `BTTSwiftUITracker` package product dependency to `targetName`.
    /// - Returns: `true` if the dependency is present afterward (whether newly
    ///   added or already linked), `false` only if it could not be added
    ///   (e.g. BlueTriangle package not found on the target).
    @discardableResult
    func addSwiftUITracker(to targetName: String) -> Bool {
        guard let xcodeproj = try? XcodeProj(path: Path(xcodeprojPath)),
              let target    = xcodeproj.pbxproj.nativeTargets.first(where: { $0.name == targetName })
        else { return false }

        let existing = target.packageProductDependencies ?? []

        if existing.contains(where: { $0.productName == BTTConstants.bttSwiftUITrackerProduct }) {
            return true
        }

        guard let bttPackage = existing.first(where: { $0.productName == BTTConstants.bttProductName })?.package else {
            BTTLog.warn("\(BTTConstants.bttProductName) package not found in '\(targetName)' — skipping \(BTTConstants.bttSwiftUITrackerProduct)")
            return false
        }

        let dep = XCSwiftPackageProductDependency(productName: BTTConstants.bttSwiftUITrackerProduct)
        dep.package = bttPackage
        xcodeproj.pbxproj.add(object: dep)
        target.packageProductDependencies = existing + [dep]
        try? xcodeproj.write(path: Path(xcodeprojPath))
        BTTLog.verbose("Injected \(BTTConstants.bttSwiftUITrackerProduct) dependency into '\(targetName)'")
        return true
    }

    // MARK: - Remove

    /// Removes the `BTTSwiftUITracker` dependency from `targetName`, if BTTInstrumentor
    /// originally added it (tracked in `store`).
    /// - Returns: `true` if the dependency was removed, `false` if there was nothing to remove.
    @discardableResult
    func removeSwiftUITracker(from targetName: String, store: BTTTargetStore) -> Bool {
        guard store.didAddBTTSwiftUITracker(for: targetName) else { return false }

        guard let xcodeproj = try? XcodeProj(path: Path(xcodeprojPath)),
              let target    = xcodeproj.pbxproj.nativeTargets.first(where: { $0.name == targetName })
        else { return false }

        let before = target.packageProductDependencies ?? []
        let after  = before.filter { $0.productName != BTTConstants.bttSwiftUITrackerProduct }
        guard after.count != before.count else { return false }

        before.filter { $0.productName == BTTConstants.bttSwiftUITrackerProduct }
              .forEach { xcodeproj.pbxproj.delete(object: $0) }
        target.packageProductDependencies = after
        try? xcodeproj.write(path: Path(xcodeprojPath))
        BTTLog.verbose("Removed \(BTTConstants.bttSwiftUITrackerProduct) dependency from '\(targetName)'")
        return true
    }
}

#endif
