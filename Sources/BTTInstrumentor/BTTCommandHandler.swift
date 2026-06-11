//
//  BTTCommandHandler.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 09/06/26.


//  All command implementations:
//  ────────────────────────────
//  runInstall()    – Adds scheme pre-action and saves target (no immediate injection).
//                    Delegates to runInject() when called non-interactively.
//  runInstrument() – install + immediately injects @BTTTrack into all Swift files.
//  runUninstall()  – Reverts injection and removes pre-action for one or all targets.
//  runCheck()      – Prints a ✓/✗ status for every setup step.
//

#if os(macOS)
import Foundation
import PathKit
import XcodeProj

final class BTTCommandHandler {
    let args: BTTArgs

    init(args: BTTArgs) {
        self.args = args
    }

    // MARK: - install
    func runInstall() {
        if isatty(STDIN_FILENO) == 0 {
            BTTLog.verbose("Non-interactive mode detected — delegating to runInject()")
            runInject()
            return
        }

        BTTLog.info("BlueTriangle BTTInstrumentor")
        BTTLog.verbose("── runInstall (interactive) ──")

        let xcodeprojPath = requireXcodeproj()
        requireBTTVersion(xcodeprojPath: xcodeprojPath)

        let projectDir = (xcodeprojPath as NSString).deletingLastPathComponent
        BTTLog.verbose("projectDir: \(projectDir)")

        let store = BTTTargetStore(projectDir: projectDir)
        BTTLog.verbose("Existing instrumented targets in store: \(store.targets.isEmpty ? "(none)" : store.targets.joined(separator: ", "))")

        let selected = promptTargetSelection(xcodeprojPath: xcodeprojPath, store: store)
        BTTLog.verbose("User selected target: '\(selected)'")

        let writer = BTTScriptWriter(projectDir: projectDir)
        BTTLog.verbose("Copying BTTInstrumentor binary to .btt/")
        writer.copyBinary()
        BTTLog.verbose("Writing btt_instrument.sh to .btt/")
        writer.writeInstrumentScript()

        let buildPhase   = BTTBuildPhase(xcodeprojPath: xcodeprojPath)
        BTTLog.verbose("Adding pre-action for target '\(selected)'...")
        let trackerAdded = buildPhase.addPreAction(for: selected)
        BTTLog.verbose("addPreAction returned: trackerAdded=\(trackerAdded)")

        store.add(selected, bttSwiftUITrackerAdded: trackerAdded)
        BTTLog.verbose("Store updated — targets now: \(store.targets.joined(separator: ", "))")

        BTTLog.success("✓ '\(selected)' is ready — build in Xcode to inject @\(BTTConstants.trackAttribute).")
    }

    // MARK: - instrument
    func runInstrument() {
        BTTLog.info("BlueTriangle BTTInstrumentor — Instrument")
        BTTLog.verbose("── runInstrument ──")

        let xcodeprojPath = requireXcodeproj()
        requireBTTVersion(xcodeprojPath: xcodeprojPath)

        let projectDir = (xcodeprojPath as NSString).deletingLastPathComponent
        BTTLog.verbose("projectDir: \(projectDir)")

        let store = BTTTargetStore(projectDir: projectDir)
        BTTLog.verbose("Existing instrumented targets in store: \(store.targets.isEmpty ? "(none)" : store.targets.joined(separator: ", "))")

        let selected = promptTargetSelection(xcodeprojPath: xcodeprojPath, store: store)
        BTTLog.verbose("User selected target: '\(selected)'")

        let writer = BTTScriptWriter(projectDir: projectDir)
        BTTLog.verbose("Copying binary and writing instrument script...")
        writer.copyBinary()
        writer.writeInstrumentScript()

        let buildPhase   = BTTBuildPhase(xcodeprojPath: xcodeprojPath)
        BTTLog.verbose("Adding pre-action for target '\(selected)'...")
        let trackerAdded = buildPhase.addPreAction(for: selected)
        BTTLog.verbose("addPreAction returned: trackerAdded=\(trackerAdded)")

        store.add(selected, bttSwiftUITrackerAdded: trackerAdded)
        BTTLog.verbose("Store updated — targets now: \(store.targets.joined(separator: ", "))")

        injectViews(for: selected, in: xcodeprojPath)
    }

    // MARK: - uninstall
    func runUninstall() {
        BTTLog.info("BlueTriangle BTTInstrumentor — Uninstall")
        BTTLog.verbose("── runUninstall ──")

        let xcodeprojPath = requireXcodeproj()
        let projectDir    = (xcodeprojPath as NSString).deletingLastPathComponent
        let store         = BTTTargetStore(projectDir: projectDir)
        let instrumented  = store.targets

        BTTLog.verbose("Instrumented targets found: \(instrumented.isEmpty ? "(none)" : instrumented.joined(separator: ", "))")

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

        BTTLog.verbose("User input: '\(input)' → index \(idx)")

        let buildPhase = BTTBuildPhase(xcodeprojPath: xcodeprojPath)
        let injector   = BTTInjector()
        let resolver   = BTTProjectResolver(args: args)

        if idx == instrumented.count + 1 {
            BTTLog.verbose("Removing all \(instrumented.count) target(s): \(instrumented.joined(separator: ", "))")
            for target in instrumented {
                BTTLog.verbose("Reverting Swift files for target '\(target)'...")
                revertSwiftFiles(for: target, in: xcodeprojPath, resolver: resolver, injector: injector)
            }
            BTTLog.verbose("Removing pre-actions from all schemes...")
            buildPhase.removePreActions(store: store)
            BTTLog.verbose("Deleting .btt folder at: \((projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName))")
            removeBttFolder(projectDir: projectDir)
            BTTLog.success("✓ All BTT instrumentation removed.")
        } else {
            let target      = instrumented[idx - 1]
            let keepTargets = instrumented.filter { $0 != target }
            BTTLog.verbose("Removing target '\(target)' — keepTargets: \(keepTargets.isEmpty ? "(none)" : keepTargets.joined(separator: ", "))")
            revertSwiftFiles(for: target, in: xcodeprojPath, resolver: resolver, injector: injector)
            BTTLog.verbose("Removing pre-action for '\(target)' from schemes...")
            buildPhase.removePreActions(for: target, keepTargets: keepTargets, store: store)
            store.remove(target)
            BTTLog.verbose("Removed '\(target)' from store — remaining: \(store.targets.isEmpty ? "(none)" : store.targets.joined(separator: ", "))")
            BTTLog.success("✓ '\(target)' removed.")
        }
    }

    // MARK: - check
    func runCheck() {
        BTTLog.info("\nBlueTriangle BTTInstrumentor — Setup Check\n")
        BTTLog.verbose("── runCheck ──")

        let xcodeprojPath = requireXcodeproj()
        let projectDir    = (xcodeprojPath as NSString).deletingLastPathComponent
        let bttDir        = (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName)
        let store         = BTTTargetStore(projectDir: projectDir)
        let fm            = FileManager.default

        BTTLog.verbose("projectDir: \(projectDir)")
        BTTLog.verbose("bttDir:     \(bttDir)")

        // 1. xcodeproj found
        BTTLog.success("✓ Project: \(URL(fileURLWithPath: xcodeprojPath).lastPathComponent)")
        BTTLog.verbose("  Full path: \(xcodeprojPath)")

        // 2. BlueTriangle SDK version
        let checker = BTTVersionChecker(xcodeprojPath: xcodeprojPath)
        if BTTConstants.isForkedVersion {
            BTTLog.warn("⚠ BlueTriangle: isForkedVersion = true — version check skipped. Set to false before release.")
        } else if let version = checker.resolvedVersion() {
            if BTTVersionChecker.isVersion(version, atLeast: BTTConstants.minBTTVersion) {
                BTTLog.success("✓ BlueTriangle version: \(version) (>= \(BTTConstants.minBTTVersion))")
            } else {
                BTTLog.error("✗ BlueTriangle version: \(version) (requires >= \(BTTConstants.minBTTVersion))")
            }
            BTTLog.verbose("  Resolved version string: '\(version)'")
        } else {
            BTTLog.error("✗ BlueTriangle version: not found in Package.resolved")
            BTTLog.verbose("  BTTVersionChecker searched candidates for xcodeproj: \(xcodeprojPath)")
        }

        // 3. .btt folder
        let bttExists = fm.fileExists(atPath: bttDir)
        BTTLog.verbose("Check .btt folder exists (\(bttDir)): \(bttExists)")
        checkItem(exists: bttExists,
                  pass: "✓ .btt folder exists",
                  fail: "✗ .btt folder missing — run 'BTTInstrumentor install'")

        // 4. Binary
        let binaryPath   = (bttDir as NSString).appendingPathComponent(BTTConstants.binaryName)
        let binaryExists = fm.fileExists(atPath: binaryPath)
        BTTLog.verbose("Check binary exists (\(binaryPath)): \(binaryExists)")
        checkItem(exists: binaryExists,
                  pass: "✓ BTTInstrumentor binary: .btt/\(BTTConstants.binaryName)",
                  fail: "✗ BTTInstrumentor binary missing — run 'BTTInstrumentor install'")

        // 5. btt_instrument.sh
        let scriptPath   = (bttDir as NSString).appendingPathComponent(BTTConstants.scriptFileName)
        let scriptExists = fm.fileExists(atPath: scriptPath)
        BTTLog.verbose("Check script exists (\(scriptPath)): \(scriptExists)")
        checkItem(exists: scriptExists,
                  pass: "✓ \(BTTConstants.scriptFileName) exists",
                  fail: "✗ \(BTTConstants.scriptFileName) missing — run 'BTTInstrumentor install'")

        // 6. btt_config.json
        let configPath   = (bttDir as NSString).appendingPathComponent(BTTConstants.configFileName)
        let configExists = fm.fileExists(atPath: configPath)
        BTTLog.verbose("Check config exists (\(configPath)): \(configExists)")
        checkItem(exists: configExists,
                  pass: "✓ \(BTTConstants.configFileName) exists",
                  fail: "✗ \(BTTConstants.configFileName) missing — run 'BTTInstrumentor install'")

        // 7. Instrumented targets
        let targets = store.targets
        BTTLog.verbose("Targets from store (\(targets.count)): \(targets.isEmpty ? "(none)" : targets.joined(separator: ", "))")
        if targets.isEmpty {
            BTTLog.error("✗ No instrumented targets found — run 'BTTInstrumentor install'")
        } else {
            BTTLog.success("✓ Instrumented targets: \(targets.joined(separator: ", "))")
        }

        // 8. BTTSwiftUITracker dependency per target
        BTTLog.verbose("Loading XcodeProj to check BTTSwiftUITracker linkage...")
        if let xcodeproj = try? XcodeProj(path: Path(xcodeprojPath)) {
            for target in targets {
                if let native = xcodeproj.pbxproj.nativeTargets.first(where: { $0.name == target }) {
                    let deps   = (native.packageProductDependencies ?? []).map { $0.productName }
                    let hasDep = deps.contains(BTTConstants.bttSwiftUITrackerProduct)
                    BTTLog.verbose("  Target '\(target)' package dependencies: \(deps.joined(separator: ", "))")
                    checkItem(exists: hasDep,
                              pass: "✓ \(BTTConstants.bttSwiftUITrackerProduct) linked: \(target)",
                              fail: "✗ \(BTTConstants.bttSwiftUITrackerProduct) not linked in '\(target)' — run 'BTTInstrumentor install'")
                } else {
                    BTTLog.verbose("  Target '\(target)' not found in pbxproj nativeTargets")
                    BTTLog.error("✗ Target '\(target)' not found in project")
                }
            }
        } else {
            BTTLog.verbose("  Failed to load XcodeProj at '\(xcodeprojPath)' — skipping dependency check")
        }

        // 9. Scheme pre-action per target
        let buildPhase  = BTTBuildPhase(xcodeprojPath: xcodeprojPath)
        let schemePaths = buildPhase.collectSchemePaths()
        BTTLog.verbose("Scheme files scanned (\(schemePaths.count)):")
        schemePaths.forEach { BTTLog.verbose("  \(URL(fileURLWithPath: $0).lastPathComponent) (\($0))") }

        for target in targets {
            var matchingScheme: String?
            let hasPreAction = schemePaths.contains { path in
                guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                    BTTLog.verbose("  Could not read scheme file: \(path)")
                    return false
                }
                let hasAction = content.contains(BTTConstants.preActionTitle)
                let hasTarget = content.contains("BlueprintName = \"\(target)\"")
                BTTLog.verbose("  Scheme '\(URL(fileURLWithPath: path).lastPathComponent)': hasPreAction=\(hasAction) hasTarget=\(hasTarget)")
                if hasAction && hasTarget { matchingScheme = path }
                return hasAction && hasTarget
            }
            if hasPreAction, let scheme = matchingScheme {
                BTTLog.verbose("  Pre-action for '\(target)' found in: \(URL(fileURLWithPath: scheme).lastPathComponent)")
            }
            checkItem(exists: hasPreAction,
                      pass: "✓ Pre-action in scheme: \(target)",
                      fail: "✗ Pre-action missing in scheme for '\(target)' — run 'BTTInstrumentor install'")
        }

        BTTLog.info("")
    }
}

#endif
