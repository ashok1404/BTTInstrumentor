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
  BTTInstrumentor install    [project.xcodeproj]
  BTTInstrumentor instrument [project.xcodeproj]
  BTTInstrumentor uninstall  [project.xcodeproj]

COMMANDS
  install     Adds scheme pre-action and saves target (no injection)
  instrument  Injects @BTTTrack into SwiftUI views immediately
  uninstall   Removes instrumentation for a target or full clean up

EXAMPLE
  cd MyApp && BTTInstrumentor install
  cd MyApp && BTTInstrumentor instrument
  cd MyApp && BTTInstrumentor uninstall
""")
}

// MARK: - Install

func cmdInstall(args: BTTArgs) {

    // Non-interactive — called from scheme pre-action every build
    if isatty(STDIN_FILENO) == 0 { cmdInject(args: args); return }

    BTTLog.info("BlueTriangle BTTInstrumentor")

    guard let xcodeprojPath = resolveXcodeproj(args: args) else {
        BTTLog.error("No .xcodeproj found in \(args.rootPath)"); exit(1)
    }

   // guard checkBTTVersionAndProceed(xcodeprojPath: xcodeprojPath) else { exit(0) }

    let projectDir = (xcodeprojPath as NSString).deletingLastPathComponent
    let store      = BTTTargetStore(projectDir: projectDir)
    let selected   = pickTarget(xcodeprojPath: xcodeprojPath, store: store)

    copyBinary(to: projectDir)
    writeBTTInstrumentScript(to: projectDir)
    let trackerAdded = addPreAction(xcodeprojPath: xcodeprojPath, targetName: selected)
    store.add(selected, bttSwiftUITrackerAdded: trackerAdded)
    BTTLog.success("✓ '\(selected)' is ready — build in Xcode to inject @BTTTrack.")
}

// MARK: - Instrument

func cmdInstrument(args: BTTArgs) {
    BTTLog.info("BlueTriangle BTTInstrumentor — Instrument")

    guard let xcodeprojPath = resolveXcodeproj(args: args) else {
        BTTLog.error("No .xcodeproj found in \(args.rootPath)"); exit(1)
    }

    guard checkBTTVersionAndProceed(xcodeprojPath: xcodeprojPath) else { exit(0) }

    let projectDir = (xcodeprojPath as NSString).deletingLastPathComponent
    let store      = BTTTargetStore(projectDir: projectDir)
    let selected   = pickTarget(xcodeprojPath: xcodeprojPath, store: store)

    copyBinary(to: projectDir)
    writeBTTInstrumentScript(to: projectDir)
    let trackerAdded = addPreAction(xcodeprojPath: xcodeprojPath, targetName: selected)
    store.add(selected, bttSwiftUITrackerAdded: trackerAdded)

    BTTLog.info("Injecting @BTTTrack into '\(selected)'...")
    let files = getSwiftFiles(for: selected, in: xcodeprojPath)
    guard !files.isEmpty else { BTTLog.warn("No Swift files found for '\(selected)'"); return }

    var injected = 0
    for file in files where injectFile(file) {
        injected += 1
        BTTLog.success("Injected: \(URL(fileURLWithPath: file).lastPathComponent)")
    }
    BTTLog.success("✓ '\(selected)' instrumented — \(injected) view(s) injected.")
}

// MARK: - Uninstall

func cmdUninstall(args: BTTArgs) {
    BTTLog.info("BlueTriangle BTTInstrumentor — Uninstall")

    guard let xcodeprojPath = resolveXcodeproj(args: args) else {
        BTTLog.error("No .xcodeproj found in \(args.rootPath)"); exit(1)
    }

    let projectDir   = (xcodeprojPath as NSString).deletingLastPathComponent
    let store        = BTTTargetStore(projectDir: projectDir)
    let instrumented = store.targets

    guard !instrumented.isEmpty else { BTTLog.warn("No instrumented targets found"); return }

    BTTLog.info("\nWhich target do you want to remove?\n")
    instrumented.enumerated().forEach { i, t in BTTLog.info("\(i + 1). \(t)") }
    BTTLog.info("\(instrumented.count + 1). Remove all (full clean up)")
    BTTLog.info("\nEnter the number: ")

    guard let input = readLine()?.trimmingCharacters(in: .whitespaces),
          let idx   = Int(input), (1...instrumented.count + 1).contains(idx)
    else { BTTLog.warn("Invalid selection"); return }

    if idx == instrumented.count + 1 {
        for target in instrumented { revertInjectedSwiftFiles(for: target, in: xcodeprojPath) }
        removePreActions(for: nil, in: xcodeprojPath, store: store)
        cleanupBttFolder(projectDir: projectDir)
        BTTLog.success("✓ All BTT instrumentation removed.")
    } else {
        let target      = instrumented[idx - 1]
        let keepTargets = instrumented.filter { $0 != target }
        revertInjectedSwiftFiles(for: target, in: xcodeprojPath)
        removePreActions(for: target, in: xcodeprojPath, keepTargets: keepTargets, store: store)
        store.remove(target)
        BTTLog.success("✓ '\(target)' removed.")
    }
}

// MARK: - Inject (called by scheme pre-action every build — non-interactive)

func cmdInject(args: BTTArgs) {
    guard let xcodeproj = resolveXcodeproj(args: args) else {
        BTTLog.warn("No .xcodeproj found"); return
    }

    let projectDir = (xcodeproj as NSString).deletingLastPathComponent
    let store      = BTTTargetStore(projectDir: projectDir)

    repairBttFolder(projectDir: projectDir, xcodeprojPath: xcodeproj, store: store)

    let targets = store.targets.isEmpty ? getTargets(in: xcodeproj) : store.targets

    var files: [String] = []
    var seen  = Set<String>()
    for target in targets {
        getSwiftFiles(for: target, in: xcodeproj)
            .filter { seen.insert($0).inserted }
            .forEach { files.append($0) }
    }

    guard !files.isEmpty else { BTTLog.warn("No Swift files found"); return }

    var injected = 0
    for file in files where injectFile(file) {
        injected += 1
        BTTLog.success("Injected: \(URL(fileURLWithPath: file).lastPathComponent)")
    }
    BTTLog.success("BTT: Injected \(injected) view(s)")
}

// MARK: - Pick target

private func pickTarget(xcodeprojPath: String, store: BTTTargetStore) -> String {
    let allTargets = getTargets(in: xcodeprojPath)
    guard !allTargets.isEmpty else { BTTLog.error("No targets found"); exit(1) }

    BTTLog.info("\nWhich target do you want to instrument?\n")
    allTargets.enumerated().forEach { i, t in
        BTTLog.info("\(i + 1). \(t)\(store.isInstrumented(t) ? " (instrumented)" : "")")
    }
    BTTLog.info("\nEnter the number of the target to instrument: ")

    if let input = readLine()?.trimmingCharacters(in: .whitespaces),
       let idx = Int(input), (1...allTargets.count).contains(idx) {
        return allTargets[idx - 1]
    }
    return allTargets[0]
}

// MARK: - Revert injected Swift files
private func revertInjectedSwiftFiles(for target: String, in xcodeprojPath: String) {
    let files = getSwiftFiles(for: target, in: xcodeprojPath)
    var removed = 0
    for file in files where revertInjectedFile(file) {
        removed += 1
        BTTLog.success("Revert injection: \(URL(fileURLWithPath: file).lastPathComponent)")
    }
    if removed > 0 { BTTLog.success("BTT: Removed instrumentation from \(removed) file(s).") }
}

// MARK: - Repair .btt folder
private func repairBttFolder(projectDir: String, xcodeprojPath: String, store: BTTTargetStore) {
    let bttDir     = (projectDir as NSString).appendingPathComponent(".btt")
    let binaryPath = (bttDir as NSString).appendingPathComponent("BTTInstrumentor")
    let scriptPath = (bttDir as NSString).appendingPathComponent("btt_instrument.sh")
    let configPath = (bttDir as NSString).appendingPathComponent("btt_config.json")

    if !fm.fileExists(atPath: bttDir) {
        try? fm.createDirectory(atPath: bttDir, withIntermediateDirectories: true)
    }
    if !fm.fileExists(atPath: binaryPath) {
        copyBinary(to: projectDir)
    }
    if !fm.fileExists(atPath: scriptPath) {
        writeBTTInstrumentScript(to: projectDir)
    }
    if !fm.fileExists(atPath: configPath) {
        BTTLog.warn("BTT: btt_config.json missing — re-run 'BTTInstrumentor install' to reconfigure.")
        for target in getTargets(in: xcodeprojPath) {
            let added = addPreAction(xcodeprojPath: xcodeprojPath, targetName: target)
            store.add(target, bttSwiftUITrackerAdded: added)
        }
    }
}

// MARK: - Copy binary

private func copyBinary(to projectDir: String) {
    let bttDir = (projectDir as NSString).appendingPathComponent(".btt")
    let dest   = (bttDir as NSString).appendingPathComponent("BTTInstrumentor")
    let src: String = {
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/") && fm.fileExists(atPath: arg0) { return arg0 }
        let t = Process(); t.launchPath = "/usr/bin/which"; t.arguments = ["BTTInstrumentor"]
        let p = Pipe(); t.standardOutput = p; t.standardError = Pipe()
        try? t.run(); t.waitUntilExit()
        let s = String(data: p.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? arg0 : s
    }()
    do {
        if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
        try fm.copyItem(atPath: src, toPath: dest)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
    } catch {
        BTTLog.error("Binary copy failed: \(error.localizedDescription)")
    }
}

// MARK: - Clean up

private func cleanupBttFolder(projectDir: String) {
    try? fm.removeItem(atPath: (projectDir as NSString).appendingPathComponent(".btt"))
}

// MARK: - Entry

func run() {
    let args = parseArgs()
    guard !args.command.isEmpty else { printHelp(); exit(0) }
    switch args.command {
    case "install":              cmdInstall(args: args)
    case "instrument":           cmdInstrument(args: args)
    case "uninstall":            cmdUninstall(args: args)
    case "help", "--help", "-h": printHelp()
    default: BTTLog.error("Unknown command: \(args.command)"); printHelp(); exit(1)
    }
}

run()
