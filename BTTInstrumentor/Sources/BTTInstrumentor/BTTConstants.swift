//
//  BTTConstants.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 09/06/26.
//

import Foundation

enum BTTConstants {

    // MARK: - BTTInstrumentor version
    static let version = "1.0.1"

    // MARK: - SDK
    static let minBTTVersion        = "3.15.13"
    /// Set to `true` when using a forked or development branch of the SDK.
    /// Skips version check in interactive mode. Must be `false` for production release.
    static let isForkedVersion      = true

    // MARK: - Package product names
    static let bttProductName            = "BlueTriangle"

    // MARK: - .btt folder & files
    static let bttFolderName    = ".btt"
    static let configFileName   = "btt_config.json"
    static let scriptFileName   = "btt_instrument.sh"
    static let binaryName       = "BTTInstrumentor"

    // MARK: - Source annotation
    static let trackModifier    = "bttTrack"
    static let importModule     = "BlueTriangle"
    
    static let ignoreComment    = "btt:ignore"
    static let ignorePattern    = #"//\s*btt\s*:\s*ignore"#

    // MARK: - Scheme pre-action
    static let preActionTitle   = "BTTInstrumentation"

    // MARK: - Injection
    static let injectionDepth = 3  // 1 = top only, 2 = one level into control flow, etc.
    static let xcodeprojSearchDepth  = 4
    static let excludedScanPaths     = ["/Pods/", "/.build/", "/DerivedData/", "/Packages/", "/LocalPackages/"]

    // MARK: - Package.resolved candidates
    static let packageResolvedCandidates = [
        "project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
        "project.xcworkspace/xcshareddata/Package.resolved"
    ]
    static let workspaceResolvedCandidates = [
        "xcshareddata/swiftpm/Package.resolved",
        "xcshareddata/Package.resolved"
    ]
    static let rootPackageResolved = "Package.resolved"

    // MARK: - Help text
    static let docsURL = "https://help.bluetriangle.com/instrumentation"
    static let helpText = """

    BTTInstrumentor — BlueTriangle SwiftUI Screen Tracking

    USAGE
      BTTInstrumentor install  [--verbose]
      BTTInstrumentor uninstall  [--verbose]
      BTTInstrumentor check 

    COMMANDS
      install     Adds scheme pre-action, saves target, and optionally
                  injects .bttTrackScreen() into SwiftUI views right away
      uninstall   Removes instrumentation for a target or full clean up
      check       Verifies all setup steps with ✓ / ✗ status

    OPTIONS
      --verbose   Show detailed logs for any command

    EXAMPLE
      cd MyApp && BTTInstrumentor install
      cd MyApp && BTTInstrumentor install --verbose
      cd MyApp && BTTInstrumentor uninstall
      cd MyApp && BTTInstrumentor check

    For more information see \(docsURL)
    """
}
