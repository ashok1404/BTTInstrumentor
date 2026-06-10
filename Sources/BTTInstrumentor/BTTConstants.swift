//
//  BTTConstants.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 09/06/26.
//

import Foundation

enum BTTConstants {
    // MARK: - SDK
    static let minBTTVersion        = "3.15.13"
    static let isForkedVersion      =  true

    // MARK: - Package product names
    static let bttProductName            = "BlueTriangle"
    static let bttSwiftUITrackerProduct  = "BTTSwiftUITracker"

    // MARK: - .btt folder & files
    static let bttFolderName    = ".btt"
    static let configFileName   = "btt_config.json"
    static let scriptFileName   = "btt_instrument.sh"
    static let binaryName       = "BTTInstrumentor"

    // MARK: - Source annotation
    static let trackAttribute   = "BTTTrack"
    static let importModule     = "BTTSwiftUITracker"
    static let ignoreComment    = "btt:ignore"

    // MARK: - Scheme pre-action
    static let preActionTitle   = "BTTInstrumentation"
    
    // MARK: - Project scanning
    /// Max depth when searching for .xcodeproj files.
    static let xcodeprojSearchDepth     = 4
    /// Directory names excluded during Swift file scanning.
    static let excludedScanPaths        = ["/Pods/", "/.build/", "/DerivedData/"]

    // MARK: - Package.resolved candidates
    /// Relative paths tried inside .xcodeproj (most common first).
    static let packageResolvedCandidates = [
        "project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
        "project.xcworkspace/xcshareddata/Package.resolved"
    ]
    /// Relative paths tried inside the sibling .xcworkspace (CocoaPods + SPM).
    static let workspaceResolvedCandidates = [
        "xcshareddata/swiftpm/Package.resolved",
        "xcshareddata/Package.resolved"
    ]
    /// Relative path tried at the package root (Package.swift-only projects).
    static let rootPackageResolved = "Package.resolved"

    // MARK: - Help text
    static let helpText = """
    BTTInstrumentor — BlueTriangle SwiftUI Screen Tracking
    USAGE
      BTTInstrumentor install    [project.xcodeproj]
      BTTInstrumentor instrument [project.xcodeproj]
      BTTInstrumentor uninstall  [project.xcodeproj]
      BTTInstrumentor check      [project.xcodeproj]

    COMMANDS
      install     Adds scheme pre-action and saves target (no injection)
      instrument  Injects @BTTTrack into SwiftUI views immediately
      uninstall   Removes instrumentation for a target or full clean up
      check       Verifies all setup steps with ✓ / ✗ status

    EXAMPLE
      cd MyApp && BTTInstrumentor install
      cd MyApp && BTTInstrumentor instrument
      cd MyApp && BTTInstrumentor uninstall
    """
}
