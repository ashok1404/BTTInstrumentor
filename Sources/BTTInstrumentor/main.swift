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
  BTTInstrumentor install [project.xcodeproj]
  BTTInstrumentor remove  [project.xcodeproj]

COMMANDS
  install   Instrument a target — adds scheme pre-action, saves target
  remove    Remove instrumentation for a target or clean up everything

EXAMPLE
  cd MyApp && BTTInstrumentor install
  cd MyApp && BTTInstrumentor remove
""")
}

// MARK: - Install (interactive — run once by developer)

func cmdInstall(args: BTTArgs) {

    // Non-interactive — called from scheme pre-action every build
    if isatty(STDIN_FILENO) == 0 { cmdInject(args: args); return }

    BTTLog.info("BlueTriangle BTTInstrumentor")

    guard let xcodeprojPath = resolveXcodeproj(args: args) else {
        BTTLog.error("No .xcodeproj found in \(args.rootPath)"); exit(1)
    }
    let projectDir = (xcodeprojPath as NSString).deletingLastPathComponent
    let store      = BTTTargetStore(projectDir: projectDir)

    // Show all targets with (instrumented) badge
    let allTargets = getTargets(in: xcodeprojPath)
    guard !allTargets.isEmpty else { BTTLog.error("No targets found"); exit(1) }

    BTTLog.info("\nWhich target do you want to instrument?\n")
    allTargets.enumerated().forEach { i, t in
        BTTLog.info("\(i + 1). \(t)\(store.isInstrumented(t) ? " (instrumented)" : "")")
    }
    BTTLog.info("\nEnter the number of the target to instrument: ")

    var selected = allTargets[0]
    if let input = readLine()?.trimmingCharacters(in: .whitespaces),
       let idx = Int(input), (1...allTargets.count).contains(idx) {
        selected = allTargets[idx - 1]
    }

    copyBinary(to: projectDir)
    addBuildPhase(xcodeprojPath: xcodeprojPath, targetName: selected)
    store.add(selected)
    BTTLog.success("✓ '\(selected)' is ready to instrument")
}

// MARK: - Remove (interactive — removes instrumentation)

func cmdRemove(args: BTTArgs) {
    BTTLog.info("BlueTriangle BTTInstrumentor — Remove")

    guard let xcodeprojPath = resolveXcodeproj(args: args) else {
        BTTLog.error("No .xcodeproj found in \(args.rootPath)"); exit(1)
    }
    let projectDir = (xcodeprojPath as NSString).deletingLastPathComponent
    let store      = BTTTargetStore(projectDir: projectDir)

    let instrumented = store.targets
    guard !instrumented.isEmpty else {
        BTTLog.warn("No instrumented targets found"); return
    }

    // Show instrumented targets + remove all option
    BTTLog.info("\nWhich target do you want to remove?\n")
    instrumented.enumerated().forEach { i, t in BTTLog.info("\(i + 1). \(t)") }
    BTTLog.info("\(instrumented.count + 1). Remove all (full clean up)")
    BTTLog.info("\nEnter the number: ")

    guard let input = readLine()?.trimmingCharacters(in: .whitespaces),
          let idx = Int(input), (1...instrumented.count + 1).contains(idx)
    else { BTTLog.warn("Invalid selection"); return }

    if idx == instrumented.count + 1 {
        // Remove all — full clean up
        removePreActions(for: nil, in: xcodeprojPath)
        cleanupBttFolder(projectDir: projectDir)
        BTTLog.success("✓ All BTT instrumentation removed.")
    } else {
        // Remove single target — keep pre-action in schemes shared with other instrumented targets
        let target       = instrumented[idx - 1]
        let keepTargets  = instrumented.filter { $0 != target }
        removePreActions(for: target, in: xcodeprojPath, keepTargets: keepTargets)
        store.remove(target)
        BTTLog.success("✓ '\(target)' removed.")
    }
}

// MARK: - Inject (called by scheme pre-action every build)

func cmdInject(args: BTTArgs) {
    guard let xcodeproj = resolveXcodeproj(args: args) else {
        BTTLog.warn("No .xcodeproj found"); return
    }

    let projectDir = (xcodeproj as NSString).deletingLastPathComponent
    let store      = BTTTargetStore(projectDir: projectDir)
    let targets    = store.targets.isEmpty ? getTargets(in: xcodeproj) : store.targets

    var files: [String] = []
    var seen  = Set<String>()
    func add(_ f: [String]) { f.filter { seen.insert($0).inserted }.forEach { files.append($0) } }

    for target in targets { add(getSwiftFiles(for: target, in: xcodeproj)) }

    guard !files.isEmpty else { BTTLog.warn("No Swift files found"); return }

    var injected = 0
    for file in files where injectFile(file) {
        injected += 1
        BTTLog.success("Injected: \(URL(fileURLWithPath: file).lastPathComponent)")
    }
    BTTLog.success("BTT: Injected \(injected) view(s)")
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

// MARK: - Full clean up

private func cleanupBttFolder(projectDir: String) {
    let bttDir = (projectDir as NSString).appendingPathComponent(".btt")
    try? fm.removeItem(atPath: bttDir)
}

// MARK: - Entry

func run() {
    let args = parseArgs()
    guard !args.command.isEmpty else { printHelp(); exit(0) }
    switch args.command {
    case "install":              cmdInstall(args: args)
    case "remove":               cmdRemove(args: args)
    case "help", "--help", "-h": printHelp()
    default: BTTLog.error("Unknown command: \(args.command)"); printHelp(); exit(1)
    }
}

run()
