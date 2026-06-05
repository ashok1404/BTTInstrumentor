//
//  main.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

import Foundation

// MARK: - Help
func printHelp() {
    BTTLog.plain("""

BTTInstrumentor — BlueTriangle SwiftUI Screen Tracking

USAGE
  BTTInstrumentor install [project.xcodeproj] [--target <TARGET>] [--scheme <SCHEME>]

WHAT IT DOES
  1. Copies BTTInstrumentor to .btt/ in your project
  2. Adds BTT Instrumentation Run Script before Compile Sources
  Every Xcode build automatically injects @BTTTrack into SwiftUI views
  including all local package dependencies of the selected target.

EXAMPLES
  BTTInstrumentor install
  BTTInstrumentor install MyApp.xcodeproj
  BTTInstrumentor install MyApp.xcodeproj --target MyApp
  BTTInstrumentor install MyApp.xcodeproj --target MyApp --scheme "XYZ (Prod)"
""")
}

// MARK: - Resolve executable path
func resolveExecutablePath() -> String {
    let arg0 = CommandLine.arguments[0]
    if arg0.hasPrefix("/") && fm.fileExists(atPath: arg0) { return arg0 }
    let task = Process()
    task.launchPath = "/usr/bin/which"
    task.arguments = ["BTTInstrumentor"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    try? task.run()
    task.waitUntilExit()
    let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return path.isEmpty ? arg0 : path
}

// MARK: - Install (interactive — called by developer once)
func cmdInstall(args: BTTArgs) {

    // Called non-interactively from Run Script — just inject
    if args.target != nil && isatty(STDIN_FILENO) == 0 {
        cmdInject(args: args)
        return
    }

    BTTLog.info("BlueTriangle BTTInstrumentor")
    BTTLog.info("Project root: \(args.rootPath)")

    // Step 1 — Resolve xcodeproj
    guard let xcodeprojPath = resolveXcodeproj(args: args) else {
        BTTLog.error("No .xcodeproj found in \(args.rootPath)")
        exit(1)
    }
    let projectDir = (xcodeprojPath as NSString).deletingLastPathComponent

    // Step 2 — Ask target first, then scheme
    // Scheme list shows only app schemes (packages hidden — they are dependencies)
    let (selectedTarget, selectedScheme) = resolveTargetAndScheme(args: args, xcodeprojPath: xcodeprojPath)

    // Step 3 — Copy binary to .btt (project root, shared by all targets)
    let bttDir    = (projectDir as NSString).appendingPathComponent(".btt")
    let bttBinary = (bttDir as NSString).appendingPathComponent("BTTInstrumentor")

    do {
        if !fm.fileExists(atPath: bttDir) {
            try fm.createDirectory(atPath: bttDir, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: bttBinary) {
            try fm.removeItem(atPath: bttBinary)
        }
        let selfPath = resolveExecutablePath()
        BTTLog.info("Binary source: \(selfPath)")
        try fm.copyItem(atPath: selfPath, toPath: bttBinary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bttBinary)
        BTTLog.success("Binary installed: \(bttBinary)")
    } catch {
        BTTLog.error("Failed to copy binary: \(error.localizedDescription)")
    }

    // Step 4 — Add build phase to selected target
    // scheme is baked into the Run Script:
    // - nil  → Run Script injects target files + ALL its local package deps
    // - "XYZ (Prod)" → Run Script injects only that scheme's files
    addBuildPhase(xcodeprojPath: xcodeprojPath, targetName: selectedTarget, scheme: selectedScheme)

    BTTLog.success("Done. Build your app in Xcode — @BTTTrack injected automatically every build.")
}

// MARK: - Inject (called by Run Script every build — non-interactive)
func cmdInject(args: BTTArgs) {
    let found = findXcodeprojFiles(in: args.rootPath)
    guard let xcodeproj = found.first else {
        BTTLog.warn("No .xcodeproj found")
        return
    }

    var files: [String] = []
    var seen = Set<String>()

    func add(_ newFiles: [String]) {
        for f in newFiles where !seen.contains(f) { seen.insert(f); files.append(f) }
    }

    let target = args.target ?? ""

    // Always inject target source files
    add(getSourceFiles(for: target, in: xcodeproj))

    // Always inject local package dependencies of this target
    add(getLocalPackagesForTarget(target, in: xcodeproj)
        .flatMap { findAllSwiftFiles(in: $0) })

    // Fallback — if xcodeproj returns no files, scan target folder
    if files.isEmpty {
        let projDir = (xcodeproj as NSString).deletingLastPathComponent
        let targetDir = (projDir as NSString).appendingPathComponent(target)
        if fm.fileExists(atPath: targetDir) {
            add(findAllSwiftFiles(in: targetDir))
        }
    }

    guard !files.isEmpty else {
        BTTLog.warn("No Swift files found")
        return
    }

    var injected = 0
    for file in files {
        if injectFile(file) {
            injected += 1
            BTTLog.success("Injected: \(URL(fileURLWithPath: file).lastPathComponent)")
        }
    }
    BTTLog.success("BTT: Injected \(injected) view(s)")
}

// MARK: - Entry
func run() {
    let args = parseArgs()
    guard !args.command.isEmpty else { printHelp(); exit(0) }
    switch args.command {
    case "install":              cmdInstall(args: args)
    case "help", "--help", "-h": printHelp()
    default: BTTLog.error("Unknown command: \(args.command)"); printHelp(); exit(1)
    }
}

run()
