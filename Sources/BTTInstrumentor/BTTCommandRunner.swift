//
//  BTTCommandRunner.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 09/06/26.
//

//
//  Commands
//  ────────
//  install     – Adds scheme pre-action and saves target; no immediate injection.
//                When called non-interactively (scheme pre-action), runs inject instead.
//  instrument  – install + immediately injects @BTTTrack into all discovered Swift files.
//  uninstall   – Reverts injection and removes scheme pre-action for one or all targets.
//  check       – Prints a ✓/✗ status for every setup step.
//  inject      – Internal command called from scheme pre-action on every build.
//

#if os(macOS)
import Foundation
import PathKit
import XcodeProj

final class BTTCommandRunner {
    private let args: BTTArgs
   
    init(args: BTTArgs) {
        self.args = args
    }

    func run() {
        guard !args.command.isEmpty else { printHelp(); exit(0) }

        switch args.command {
        case "install":              runInstall()
        case "instrument":           runInstrument()
        case "uninstall":            runUninstall()
        case "check":                runCheck()
        case "help", "--help", "-h": printHelp()
        default:
            BTTLog.error("Unknown command: '\(args.command)'")
            printHelp()
            exit(1)
        }
    }

    // MARK: - install
    private func runInstall() {
        // Non-interactive — triggered by scheme pre-action on every Xcode build
        if isatty(STDIN_FILENO) == 0 { runInject(); return }

        BTTLog.info("BlueTriangle BTTInstrumentor")

        let xcodeprojPath = requireXcodeproj()
        requireBTTVersion(xcodeprojPath: xcodeprojPath)

        let projectDir = (xcodeprojPath as NSString).deletingLastPathComponent
        let store      = BTTTargetStore(projectDir: projectDir)
        let selected   = promptTargetSelection(xcodeprojPath: xcodeprojPath, store: store)

        let writer = BTTScriptWriter(projectDir: projectDir)
        writer.copyBinary()
        writer.writeInstrumentScript()

        let buildPhase   = BTTBuildPhase(xcodeprojPath: xcodeprojPath)
        let trackerAdded = buildPhase.addPreAction(for: selected)
        store.add(selected, bttSwiftUITrackerAdded: trackerAdded)

        BTTLog.success("✓ '\(selected)' is ready — build in Xcode to inject @\(BTTConstants.trackAttribute).")
    }

    // MARK: - instrument

    private func runInstrument() {
        BTTLog.info("BlueTriangle BTTInstrumentor — Instrument")

        let xcodeprojPath = requireXcodeproj()
        requireBTTVersion(xcodeprojPath: xcodeprojPath)

        let projectDir = (xcodeprojPath as NSString).deletingLastPathComponent
        let store      = BTTTargetStore(projectDir: projectDir)
        let selected   = promptTargetSelection(xcodeprojPath: xcodeprojPath, store: store)

        let writer = BTTScriptWriter(projectDir: projectDir)
        writer.copyBinary()
        writer.writeInstrumentScript()

        let buildPhase   = BTTBuildPhase(xcodeprojPath: xcodeprojPath)
        let trackerAdded = buildPhase.addPreAction(for: selected)
        store.add(selected, bttSwiftUITrackerAdded: trackerAdded)

        injectViews(for: selected, in: xcodeprojPath)
    }

    // MARK: - uninstall
    private func runUninstall() {
        BTTLog.info("BlueTriangle BTTInstrumentor — Uninstall")

        let xcodeprojPath = requireXcodeproj()
        let projectDir    = (xcodeprojPath as NSString).deletingLastPathComponent
        let store         = BTTTargetStore(projectDir: projectDir)
        let instrumented  = store.targets

        guard !instrumented.isEmpty else {
            BTTLog.warn("No instrumented targets found.")
            return
        }

        BTTLog.info("\nWhich target do you want to remove?\n")
        instrumented.enumerated().forEach { i, t in BTTLog.info("\(i + 1). \(t)") }
        BTTLog.info("\(instrumented.count + 1). Remove all (full clean up)")
        BTTLog.info("\nEnter the number: ")

        guard let input = readLine()?.trimmingCharacters(in: .whitespaces),
              let idx   = Int(input),
              (1...instrumented.count + 1).contains(idx)
        else {
            BTTLog.warn("Invalid selection.")
            return
        }

        let buildPhase = BTTBuildPhase(xcodeprojPath: xcodeprojPath)
        let injector   = BTTInjector()
        let resolver   = BTTProjectResolver(args: args)

        if idx == instrumented.count + 1 {
            // Remove all
            for target in instrumented {
                revertSwiftFiles(for: target, in: xcodeprojPath, resolver: resolver, injector: injector)
            }
            buildPhase.removePreActions(store: store)
            removeBttFolder(projectDir: projectDir)
            BTTLog.success("✓ All BTT instrumentation removed.")
        } else {
            // Remove single target
            let target      = instrumented[idx - 1]
            let keepTargets = instrumented.filter { $0 != target }
            revertSwiftFiles(for: target, in: xcodeprojPath, resolver: resolver, injector: injector)
            buildPhase.removePreActions(for: target, keepTargets: keepTargets, store: store)
            store.remove(target)
            BTTLog.success("✓ '\(target)' removed.")
        }
    }

    // MARK: - check
    private func runCheck() {
        BTTLog.info("\nBlueTriangle BTTInstrumentor — Setup Check\n")

        let xcodeprojPath = requireXcodeproj()
        let projectDir    = (xcodeprojPath as NSString).deletingLastPathComponent
        let bttDir        = (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName)
        let store         = BTTTargetStore(projectDir: projectDir)
        let fm            = FileManager.default

        // 1. xcodeproj found
        BTTLog.success("✓ Project: \(URL(fileURLWithPath: xcodeprojPath).lastPathComponent)")

        // 2. BlueTriangle SDK version
        let checker = BTTVersionChecker(xcodeprojPath: xcodeprojPath)
        if let version = checker.resolvedVersion() {
            if BTTVersionChecker.isVersion(version, atLeast: BTTConstants.minBTTVersion) {
                BTTLog.success("✓ BlueTriangle version: \(version) (>= \(BTTConstants.minBTTVersion))")
            } else {
                BTTLog.error("✗ BlueTriangle version: \(version) (requires >= \(BTTConstants.minBTTVersion))")
            }
        } else {
            BTTLog.error("✗ BlueTriangle version: not found in Package.resolved")
        }

        // 3. .btt folder
        checkItem(
            exists: fm.fileExists(atPath: bttDir),
            pass: "✓ .btt folder exists",
            fail: "✗ .btt folder missing — run 'BTTInstrumentor install'"
        )

        // 4. Binary
        checkItem(
            exists: fm.fileExists(atPath: (bttDir as NSString).appendingPathComponent(BTTConstants.binaryName)),
            pass: "✓ BTTInstrumentor binary: .btt/\(BTTConstants.binaryName)",
            fail: "✗ BTTInstrumentor binary missing — run 'BTTInstrumentor install'"
        )

        // 5. btt_instrument.sh
        checkItem(
            exists: fm.fileExists(atPath: (bttDir as NSString).appendingPathComponent(BTTConstants.scriptFileName)),
            pass: "✓ \(BTTConstants.scriptFileName) exists",
            fail: "✗ \(BTTConstants.scriptFileName) missing — run 'BTTInstrumentor install'"
        )

        // 6. btt_config.json
        checkItem(
            exists: fm.fileExists(atPath: (bttDir as NSString).appendingPathComponent(BTTConstants.configFileName)),
            pass: "✓ \(BTTConstants.configFileName) exists",
            fail: "✗ \(BTTConstants.configFileName) missing — run 'BTTInstrumentor install'"
        )

        // 7. Instrumented targets
        let targets = store.targets
        if targets.isEmpty {
            BTTLog.error("✗ No instrumented targets found — run 'BTTInstrumentor install'")
        } else {
            BTTLog.success("✓ Instrumented targets: \(targets.joined(separator: ", "))")
        }

        // 8. BTTSwiftUITracker dependency per target
        if let xcodeproj = try? XcodeProj(path: Path(xcodeprojPath)) {
            for target in targets {
                if let native = xcodeproj.pbxproj.nativeTargets.first(where: { $0.name == target }) {
                    let hasDep = (native.packageProductDependencies ?? [])
                        .contains { $0.productName == BTTConstants.bttSwiftUITrackerProduct }
                    checkItem(
                        exists: hasDep,
                        pass: "✓ \(BTTConstants.bttSwiftUITrackerProduct) linked: \(target)",
                        fail: "✗ \(BTTConstants.bttSwiftUITrackerProduct) not linked in '\(target)' — run 'BTTInstrumentor install'"
                    )
                }
            }
        }

        // 9. Scheme pre-action per target
        let buildPhase   = BTTBuildPhase(xcodeprojPath: xcodeprojPath)
        let schemePaths  = buildPhase.collectSchemePaths()
        for target in targets {
            let hasPreAction = schemePaths.contains { path in
                guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
                return content.contains(BTTConstants.preActionTitle) &&
                       content.contains("BlueprintName = \"\(target)\"")
            }
            checkItem(
                exists: hasPreAction,
                pass: "✓ Pre-action in scheme: \(target)",
                fail: "✗ Pre-action missing in scheme for '\(target)' — run 'BTTInstrumentor install'"
            )
        }

        BTTLog.info("")
    }

    // MARK: - inject (internal — called from scheme pre-action)
    private func runInject() {
        guard let xcodeprojPath = BTTProjectResolver(args: args).resolveXcodeproj() else {
            BTTLog.warn("No .xcodeproj found")
            return
        }

        let projectDir = (xcodeprojPath as NSString).deletingLastPathComponent
        let store      = BTTTargetStore(projectDir: projectDir)

        repairBttFolder(projectDir: projectDir, xcodeprojPath: xcodeprojPath, store: store)

        let resolver = BTTProjectResolver(args: args)
        let targets  = store.targets.isEmpty ? resolver.getTargets(in: xcodeprojPath) : store.targets

        var files = [String]()
        var seen  = Set<String>()
        for target in targets {
            resolver.getSwiftFiles(for: target, in: xcodeprojPath)
                .filter { seen.insert($0).inserted }
                .forEach { files.append($0) }
        }

        guard !files.isEmpty else { BTTLog.warn("No Swift files found"); return }

        let injector = BTTInjector()
        var injected = 0
        for file in files where injector.inject(file: file) {
            injected += 1
            BTTLog.success("Injected: \(URL(fileURLWithPath: file).lastPathComponent)")
        }
        BTTLog.success("BTT: Injected \(injected) view(s)")
    }

    // MARK: - Shared helpers
    /// Resolves the .xcodeproj or exits with an error.
    private func requireXcodeproj() -> String {
        guard let path = BTTProjectResolver(args: args).resolveXcodeproj() else {
            BTTLog.error("No .xcodeproj found in \(args.rootPath)")
            exit(1)
        }
        return path
    }

    /// Checks the BTT SDK version gate; exits if the user decides not to proceed.
    private func requireBTTVersion(xcodeprojPath: String) {
        /*guard BTTVersionChecker(xcodeprojPath: xcodeprojPath).checkAndProceed() else {
            exit(0)
        }*/
    }

    /// Prompts the user to pick a target and returns the selection.
    private func promptTargetSelection(xcodeprojPath: String, store: BTTTargetStore) -> String {
        let resolver   = BTTProjectResolver(args: args)
        let allTargets = resolver.getTargets(in: xcodeprojPath)
        guard !allTargets.isEmpty else {
            BTTLog.error("No targets found in project.")
            exit(1)
        }

        BTTLog.info("\nWhich target do you want to instrument?\n")
        allTargets.enumerated().forEach { i, t in
            let tag = store.isInstrumented(t) ? " (instrumented)" : ""
            BTTLog.info("\(i + 1). \(t)\(tag)")
        }
        BTTLog.info("\nEnter the number of the target to instrument: ")

        if let input = readLine()?.trimmingCharacters(in: .whitespaces),
           let idx   = Int(input),
           (1...allTargets.count).contains(idx) {
            return allTargets[idx - 1]
        }
        return allTargets[0]
    }

    /// Injects @BTTTrack into Swift files for a target and prints a summary.
    private func injectViews(for target: String, in xcodeprojPath: String) {
        BTTLog.info("Injecting @\(BTTConstants.trackAttribute) into '\(target)'...")

        let resolver = BTTProjectResolver(args: args)
        let files    = resolver.getSwiftFiles(for: target, in: xcodeprojPath)
        guard !files.isEmpty else {
            BTTLog.warn("No Swift files found for '\(target)'.")
            return
        }

        let injector = BTTInjector()
        var injected = 0
        for file in files where injector.inject(file: file) {
            injected += 1
            BTTLog.success("Injected: \(URL(fileURLWithPath: file).lastPathComponent)")
        }
        BTTLog.success("✓ '\(target)' instrumented — \(injected) view(s) injected.")
    }

    /// Reverts all injected Swift files for a target and prints a summary.
    private func revertSwiftFiles(
        for target: String,
        in xcodeprojPath: String,
        resolver: BTTProjectResolver,
        injector: BTTInjector
    ) {
        let files   = resolver.getSwiftFiles(for: target, in: xcodeprojPath)
        var removed = 0
        for file in files where injector.revert(file: file) {
            removed += 1
            BTTLog.success("Uninjected: \(URL(fileURLWithPath: file).lastPathComponent)")
        }
        if removed > 0 {
            BTTLog.success("BTT: Removed instrumentation from \(removed) file(s).")
        }
    }

    /// Ensures all .btt artifacts exist; silently restores anything missing.
    private func repairBttFolder(projectDir: String, xcodeprojPath: String, store: BTTTargetStore) {
        let fm          = FileManager.default
        let bttDir      = (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName)
        let binaryPath  = (bttDir as NSString).appendingPathComponent(BTTConstants.binaryName)
        let scriptPath  = (bttDir as NSString).appendingPathComponent(BTTConstants.scriptFileName)
        let configPath  = (bttDir as NSString).appendingPathComponent(BTTConstants.configFileName)
        let writer      = BTTScriptWriter(projectDir: projectDir)

        if !fm.fileExists(atPath: bttDir) {
            try? fm.createDirectory(atPath: bttDir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: binaryPath) { writer.copyBinary() }
        if !fm.fileExists(atPath: scriptPath) { writer.writeInstrumentScript() }
        if !fm.fileExists(atPath: configPath) {
            BTTLog.warn("BTT: \(BTTConstants.configFileName) missing — re-run 'BTTInstrumentor install' to reconfigure.")
            let resolver   = BTTProjectResolver(args: args)
            let buildPhase = BTTBuildPhase(xcodeprojPath: xcodeprojPath)
            for target in resolver.getTargets(in: xcodeprojPath) {
                let added = buildPhase.addPreAction(for: target)
                store.add(target, bttSwiftUITrackerAdded: added)
            }
        }
    }

    private func removeBttFolder(projectDir: String) {
        let bttDir = (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName)
        try? FileManager.default.removeItem(atPath: bttDir)
    }

    private func checkItem(exists: Bool, pass: String, fail: String) {
        if exists { BTTLog.success(pass) } else { BTTLog.error(fail) }
    }

    private func printHelp() {
        BTTLog.info(BTTConstants.helpText)
    }
}

#endif
