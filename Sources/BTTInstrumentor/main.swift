//
//  main.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//


import Foundation

// MARK: - Help
func printHelp() {
    BTTLog.info("""

BTTInstrumentor — BlueTriangle SwiftUI Screen Tracking

USAGE
  BTTInstrumentor install [project.xcodeproj] [--target <TARGET>] [--scheme <SCHEME>]

EXAMPLES
  BTTInstrumentor install
  BTTInstrumentor install MyApp.xcodeproj
  BTTInstrumentor install MyApp.xcodeproj --target MyApp
  BTTInstrumentor install MyApp.xcodeproj --scheme "Xpo (Prod)"
  BTTInstrumentor install MyApp.xcodeproj --target MyApp --scheme "Xpo (Prod)"
""")
}

// MARK: - Install
func cmdInstall(args: BTTArgs) {
    BTTLog.info("\nBlueTriangle BTTInstrumentor\n")
    BTTLog.info("Project root: \(args.rootPath)")

    let files = resolveFiles(args: args)

    print("\nInjecting @BTTTrack into SwiftUI views...\n")

    var injected = 0
    var skipped  = 0

    for file in files {
        if injectFile(file) {
            injected += 1
            BTTLog.success("Injected: \(URL(fileURLWithPath: file).lastPathComponent)")
        } else {
            skipped += 1
        }
    }

    BTTLog.success("\nDone.")
    BTTLog.info("Total    : \(files.count)")
    BTTLog.info("Injected : \(injected)")
    BTTLog.info("Skipped  : \(skipped)")
}

// MARK: - Entry
func run() {
    let args = parseArgs()
    guard !args.command.isEmpty else { printHelp(); exit(0) }
    switch args.command {
    case "install":              cmdInstall(args: args)
    case "help", "--help", "-h": printHelp()
    default: BTTLog.info("Unknown command: \(args.command)"); printHelp(); exit(1)
    }
}
 
run()
