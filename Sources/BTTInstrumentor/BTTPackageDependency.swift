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
        BTTLog.verbose("addSwiftUITracker — target='\(targetName)' xcodeproj='\(URL(fileURLWithPath: xcodeprojPath).lastPathComponent)'")

        guard let xcodeproj = try? XcodeProj(path: Path(xcodeprojPath)) else {
            BTTLog.verbose("  ✗ Failed to load XcodeProj at '\(xcodeprojPath)'")
            return false
        }
        guard let target = xcodeproj.pbxproj.nativeTargets.first(where: { $0.name == targetName }) else {
            BTTLog.verbose("  ✗ nativeTarget '\(targetName)' not found in pbxproj")
            return false
        }

        let existing    = target.packageProductDependencies ?? []
        let existingNames = existing.map { $0.productName }
        BTTLog.verbose("  Existing packageProductDependencies for '\(targetName)': \(existingNames.isEmpty ? "(none)" : existingNames.joined(separator: ", "))")

        if existing.contains(where: { $0.productName == BTTConstants.bttSwiftUITrackerProduct }) {
            BTTLog.verbose("  \(BTTConstants.bttSwiftUITrackerProduct) already linked — skipping.")
            BTTLog.verbose("  Returning true (already present counts as success).")
            return true
        }

        guard let bttPackage = existing.first(where: { $0.productName == BTTConstants.bttProductName })?.package else {
            BTTLog.verbose("  ✗ '\(BTTConstants.bttProductName)' not found among dependencies — cannot resolve package reference for \(BTTConstants.bttSwiftUITrackerProduct)")
            BTTLog.verbose("  Hint: ensure BlueTriangle SDK is added via SPM before running BTTInstrumentor.")
            BTTLog.warn("\(BTTConstants.bttProductName) package not found in '\(targetName)' — skipping \(BTTConstants.bttSwiftUITrackerProduct)")
            return false
        }

        BTTLog.verbose("  Found parent package: repositoryURL=\(bttPackage.repositoryURL ?? "nil") name=\(bttPackage.name ?? "nil")")

        let dep = XCSwiftPackageProductDependency(productName: BTTConstants.bttSwiftUITrackerProduct)
        dep.package = bttPackage
        xcodeproj.pbxproj.add(object: dep)
        target.packageProductDependencies = existing + [dep]

        do {
            try xcodeproj.write(path: Path(xcodeprojPath))
            BTTLog.verbose("  ✓ \(BTTConstants.bttSwiftUITrackerProduct) added and .xcodeproj written.")
        } catch {
            BTTLog.verbose("  ✗ Failed to write .xcodeproj: \(error.localizedDescription)")
            return false
        }

        return true
    }

    // MARK: - Remove

    func removeSwiftUITracker(from targetName: String, store: BTTTargetStore) {
        BTTLog.verbose("removeSwiftUITracker — target='\(targetName)'")

        let wasAddedByUs = store.didAddBTTSwiftUITracker(for: targetName)
        BTTLog.verbose("  store.didAddBTTSwiftUITracker('\(targetName)') = \(wasAddedByUs)")

        guard wasAddedByUs else {
            BTTLog.verbose("  Skipping removal — \(BTTConstants.bttSwiftUITrackerProduct) was not added by BTTInstrumentor for '\(targetName)'.")
            return
        }

        guard let xcodeproj = try? XcodeProj(path: Path(xcodeprojPath)) else {
            BTTLog.verbose("  ✗ Failed to load XcodeProj at '\(xcodeprojPath)'")
            return
        }
        guard let target = xcodeproj.pbxproj.nativeTargets.first(where: { $0.name == targetName }) else {
            BTTLog.verbose("  ✗ nativeTarget '\(targetName)' not found in pbxproj")
            return
        }

        let before     = target.packageProductDependencies ?? []
        let after      = before.filter { $0.productName != BTTConstants.bttSwiftUITrackerProduct }
        let toDelete   = before.filter { $0.productName == BTTConstants.bttSwiftUITrackerProduct }

        BTTLog.verbose("  Dependencies before: \(before.map { $0.productName }.joined(separator: ", "))")
        BTTLog.verbose("  Will delete \(toDelete.count) entry(ies): \(toDelete.map { $0.productName }.joined(separator: ", "))")

        guard after.count != before.count else {
            BTTLog.verbose("  Nothing to remove — \(BTTConstants.bttSwiftUITrackerProduct) not present.")
            return
        }

        toDelete.forEach { xcodeproj.pbxproj.delete(object: $0) }
        target.packageProductDependencies = after

        do {
            try xcodeproj.write(path: Path(xcodeprojPath))
            BTTLog.verbose("  ✓ \(BTTConstants.bttSwiftUITrackerProduct) removed and .xcodeproj written.")
        } catch {
            BTTLog.verbose("  ✗ Failed to write .xcodeproj: \(error.localizedDescription)")
        }
    }
}

#endif
