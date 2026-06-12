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

enum BTTTrackerLinkResult {
    case added
    case alreadyLinked
    case failed

    var isLinked: Bool {
        switch self {
        case .added, .alreadyLinked: return true
        case .failed:                 return false
        }
    }
}

final class BTTPackageDependency {
    private let xcodeprojPath: String

    init(xcodeprojPath: String) {
        self.xcodeprojPath = xcodeprojPath
    }

    @discardableResult
    func addSwiftUITracker(to targetName: String) -> BTTTrackerLinkResult {
        guard let xcodeproj = try? XcodeProj(path: Path(xcodeprojPath)),
              let target    = xcodeproj.pbxproj.nativeTargets.first(where: { $0.name == targetName })
        else { return .failed }

        let existing = target.packageProductDependencies ?? []

        if existing.contains(where: { $0.productName == BTTConstants.bttSwiftUITrackerProduct }) {
            return .alreadyLinked
        }

        guard let bttPackage = existing.first(where: { $0.productName == BTTConstants.bttProductName })?.package else {
            BTTLog.warn("\(BTTConstants.bttProductName) package not found in '\(targetName)' — skipping \(BTTConstants.bttSwiftUITrackerProduct)")
            return .failed
        }

        let dep = XCSwiftPackageProductDependency(productName: BTTConstants.bttSwiftUITrackerProduct)
        dep.package = bttPackage
        xcodeproj.pbxproj.add(object: dep)
        target.packageProductDependencies = existing + [dep]

        if let frameworksPhase = target.buildPhases.first(where: { $0.buildPhase == .frameworks }) as? PBXFrameworksBuildPhase {
            let buildFile = PBXBuildFile(product: dep)
            xcodeproj.pbxproj.add(object: buildFile)
            frameworksPhase.files = (frameworksPhase.files ?? []) + [buildFile]
        }

        try? xcodeproj.write(path: Path(xcodeprojPath))
        BTTLog.verbose("Injected \(BTTConstants.bttSwiftUITrackerProduct) dependency into '\(targetName)'")
        return .added
    }

    // MARK: - Remove
    @discardableResult
    func removeSwiftUITracker(from targetName: String, store: BTTTargetStore) -> Bool {
        guard store.didAddBTTSwiftUITracker(for: targetName) else { return false }

        guard let xcodeproj = try? XcodeProj(path: Path(xcodeprojPath)),
              let target    = xcodeproj.pbxproj.nativeTargets.first(where: { $0.name == targetName })
        else { return false }

        let before = target.packageProductDependencies ?? []
        let after  = before.filter { $0.productName != BTTConstants.bttSwiftUITrackerProduct }
        guard after.count != before.count else { return false }

        let trackerDeps = before.filter { $0.productName == BTTConstants.bttSwiftUITrackerProduct }

        // Remove the corresponding PBXBuildFile(s) from the Frameworks build phase.
        if let frameworksPhase = target.buildPhases.first(where: { $0.buildPhase == .frameworks }) as? PBXFrameworksBuildPhase {
            let existingFiles = frameworksPhase.files ?? []
            let (keepFiles, removeFiles) = existingFiles.reduce(into: ([PBXBuildFile](), [PBXBuildFile]())) { acc, file in
                if let product = file.product, trackerDeps.contains(where: { $0 === product }) {
                    acc.1.append(file)
                } else {
                    acc.0.append(file)
                }
            }
            frameworksPhase.files = keepFiles
            removeFiles.forEach { xcodeproj.pbxproj.delete(object: $0) }
        }

        trackerDeps.forEach { xcodeproj.pbxproj.delete(object: $0) }
        target.packageProductDependencies = after
        try? xcodeproj.write(path: Path(xcodeprojPath))
        BTTLog.verbose("Removed \(BTTConstants.bttSwiftUITrackerProduct) dependency from '\(targetName)'")
        return true
    }
}

#endif
