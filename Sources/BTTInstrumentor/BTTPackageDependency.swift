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
    @discardableResult
    func addSwiftUITracker(to targetName: String) -> Bool {
        guard let xcodeproj = try? XcodeProj(path: Path(xcodeprojPath)),
              let target    = xcodeproj.pbxproj.nativeTargets.first(where: { $0.name == targetName })
        else { return false }

        let existing = target.packageProductDependencies ?? []

        // Already present — nothing to do
        if existing.contains(where: { $0.productName == BTTConstants.bttSwiftUITrackerProduct }) {
            return true
        }

        guard let bttPackage = existing.first(where: { $0.productName == BTTConstants.bttProductName })?.package else {
            BTTLog.warn(
                "\(BTTConstants.bttProductName) package not found in '\(targetName)' " +
                "— skipping \(BTTConstants.bttSwiftUITrackerProduct)"
            )
            return false
        }

        let dep = XCSwiftPackageProductDependency(productName: BTTConstants.bttSwiftUITrackerProduct)
        dep.package = bttPackage
        xcodeproj.pbxproj.add(object: dep)
        target.packageProductDependencies = existing + [dep]
        try? xcodeproj.write(path: Path(xcodeprojPath))
        return true
    }

    // MARK: - Remove
    func removeSwiftUITracker(from targetName: String, store: BTTTargetStore) {
        guard store.didAddBTTSwiftUITracker(for: targetName) else { return }

        guard let xcodeproj = try? XcodeProj(path: Path(xcodeprojPath)),
              let target    = xcodeproj.pbxproj.nativeTargets.first(where: { $0.name == targetName })
        else { return }

        let before = target.packageProductDependencies ?? []
        let after  = before.filter { $0.productName != BTTConstants.bttSwiftUITrackerProduct }
        guard after.count != before.count else { return }

        before.filter { $0.productName == BTTConstants.bttSwiftUITrackerProduct }
              .forEach { xcodeproj.pbxproj.delete(object: $0) }

        target.packageProductDependencies = after
        try? xcodeproj.write(path: Path(xcodeprojPath))
    }
}

#endif
