//
//  BTTConstants.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 09/06/26.
//

import Foundation

enum BTTConstants {
    static let version        = "1.0.0"

    // MARK: - SDK
    static let minBTTVersion        = "3.15.13"
    static let isForkedVersion      = true

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
    static let xcodeprojSearchDepth  = 4
    static let excludedScanPaths     = ["/Pods/", "/.build/", "/DerivedData/"]

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

    // MARK: - Help
    static let docsURL = "https://help.bluetriangle.com/instrumentation"
    static let helpText = """

        BTTInstrumentor — BlueTriangle SwiftUI Screen Tracking

        USAGE
          BTTInstrumentor install    [project.xcodeproj] [--verbose]
          BTTInstrumentor uninstall  [project.xcodeproj] [--verbose]
          BTTInstrumentor check      [project.xcodeproj]

        COMMANDS
          install     Adds scheme pre-action, saves target, and optionally
                      injects @BTTTrack into SwiftUI views right away
          uninstall   Removes instrumentation for a target or full clean up
          check       Verifies all setup steps with ✓ / ✗ status

        OPTIONS
          --verbose   Show detailed logs for any command

        EXAMPLE
          cd MyApp && BTTInstrumentor install
          cd MyApp && BTTInstrumentor install --verbose
          cd MyApp && BTTInstrumentor uninstall
          cd MyApp && BTTInstrumentor uninstall --verbose
          cd MyApp && BTTInstrumentor check 

        For more information see \(docsURL)
        """
}
