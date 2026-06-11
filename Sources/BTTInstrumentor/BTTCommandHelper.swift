//
//  BTTCommandHelper.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 11/06/26.
//

#if os(macOS)
import Foundation
import PathKit
import XcodeProj

extension BTTCommandHandler {

    func requireXcodeproj() -> String {
        BTTLog.verbose("Resolving .xcodeproj from rootPath='\(args.rootPath)' projectPath='\(args.projectPath ?? "nil")'")
        guard let path = BTTProjectResolver(args: args).resolveXcodeproj() else {
            BTTLog.error("No .xcodeproj found in \(args.rootPath)")
            exit(1)
        }
        BTTLog.verbose("Resolved .xcodeproj: \(path)")
        return path
    }

    func requireBTTVersion(xcodeprojPath: String) {
        BTTLog.verbose("Checking BlueTriangle SDK version (isForkedVersion=\(BTTConstants.isForkedVersion), minVersion=\(BTTConstants.minBTTVersion))...")
        guard BTTVersionChecker(xcodeprojPath: xcodeprojPath).checkAndProceed() else {
            BTTLog.verbose("Version check failed — exiting.")
            exit(0)
        }
        BTTLog.verbose("Version check passed.")
    }

    func promptTargetSelection(xcodeprojPath: String, store: BTTTargetStore) -> String {
        let resolver   = BTTProjectResolver(args: args)
        let allTargets = resolver.getTargets(in: xcodeprojPath)
        BTTLog.verbose("All targets from xcodebuild -list (\(allTargets.count)): \(allTargets.joined(separator: ", "))")

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
            BTTLog.verbose("User chose index \(idx) → '\(allTargets[idx - 1])'")
            return allTargets[idx - 1]
        }

        BTTLog.verbose("Invalid/empty input — defaulting to first target '\(allTargets[0])'")
        return allTargets[0]
    }
    
    func runInject() {
        BTTLog.verbose("── runInject (non-interactive / scheme pre-action) ──")

        guard let xcodeprojPath = BTTProjectResolver(args: args).resolveXcodeproj() else {
            BTTLog.warn("No .xcodeproj found in '\(args.rootPath)' — injection skipped.")
            return
        }
        BTTLog.verbose("Resolved xcodeproj: \(xcodeprojPath)")

        let projectDir = (xcodeprojPath as NSString).deletingLastPathComponent
        let store      = BTTTargetStore(projectDir: projectDir)
        BTTLog.verbose("Store targets before repair: \(store.targets.isEmpty ? "(none)" : store.targets.joined(separator: ", "))")

        repairBttFolder(projectDir: projectDir, xcodeprojPath: xcodeprojPath, store: store)

        let resolver = BTTProjectResolver(args: args)
        let targets  = store.targets.isEmpty ? resolver.getTargets(in: xcodeprojPath) : store.targets
        BTTLog.verbose("Targets to inject (\(targets.count)): \(targets.joined(separator: ", "))")
        BTTLog.verbose("Source: \(store.targets.isEmpty ? "xcodebuild -list fallback" : "btt_config.json")")

        var files = [String]()
        var seen  = Set<String>()
        for target in targets {
            let targetFiles = resolver.getSwiftFiles(for: target, in: xcodeprojPath)
                .filter { seen.insert($0).inserted }
            BTTLog.verbose("  Target '\(target)': \(targetFiles.count) unique Swift file(s)")
            files.append(contentsOf: targetFiles)
        }

        BTTLog.verbose("Total unique Swift files to scan: \(files.count)")

        guard !files.isEmpty else {
            BTTLog.warn("No Swift files found across targets: \(targets.joined(separator: ", ")) — injection skipped.")
            return
        }

        let injector = BTTInjector()
        var injected = 0
        var skipped  = 0
        for file in files {
            let name = URL(fileURLWithPath: file).lastPathComponent
            if injector.inject(file: file) {
                injected += 1
                BTTLog.verbose("  ✓ Injected:  \(name)")
            } else {
                skipped += 1
                BTTLog.verbose("  – Skipped:   \(name) (already instrumented, no View, or parse error)")
            }
        }

        BTTLog.verbose("Injection complete — injected=\(injected) skipped=\(skipped)")
        BTTLog.success("BTT: Injected \(injected) view(s)\(args.verbose ? ", \(skipped) skipped" : "")")
    }

    func injectViews(for target: String, in xcodeprojPath: String) {
        BTTLog.info("Injecting @\(BTTConstants.trackAttribute) into '\(target)'...")
        BTTLog.verbose("── injectViews target='\(target)' ──")

        let resolver = BTTProjectResolver(args: args)
        let files    = resolver.getSwiftFiles(for: target, in: xcodeprojPath)
        BTTLog.verbose("Swift files resolved for '\(target)': \(files.count)")

        guard !files.isEmpty else {
            BTTLog.warn("No Swift files found for '\(target)'.")
            return
        }

        if BTTLog.verboseEnabled {
            files.forEach { BTTLog.verbose("  \($0)") }
        }

        let injector = BTTInjector()
        var injected = 0
        var skipped  = 0
        for file in files {
            let name = URL(fileURLWithPath: file).lastPathComponent
            if injector.inject(file: file) {
                injected += 1
                BTTLog.success("  ✓ Injected: \(name)")
            } else {
                skipped += 1
                BTTLog.verbose("  – Skipped:  \(name) (already instrumented, no View, or parse error)")
            }
        }

        BTTLog.verbose("injectViews complete — injected=\(injected) skipped=\(skipped)")
        BTTLog.success("✓ '\(target)' instrumented — \(injected) view(s) injected\(args.verbose ? ", \(skipped) skipped" : "").")
    }

    func revertSwiftFiles(
        for target: String,
        in xcodeprojPath: String,
        resolver: BTTProjectResolver,
        injector: BTTInjector
    ) {
        BTTLog.verbose("── revertSwiftFiles target='\(target)' ──")
        let files = resolver.getSwiftFiles(for: target, in: xcodeprojPath)
        BTTLog.verbose("Swift files to scan for revert: \(files.count)")

        var removed = 0
        var skipped = 0
        for file in files {
            let name = URL(fileURLWithPath: file).lastPathComponent
            if injector.revert(file: file) {
                removed += 1
                BTTLog.success("  Revert injection: \(name)")
                BTTLog.verbose("  Full path:  \(file)")
            } else {
                skipped += 1
                BTTLog.verbose("  – Skipped (no BTT annotations): \(name)")
            }
        }

        BTTLog.verbose("revertSwiftFiles complete — removed=\(removed) skipped=\(skipped)")
        if removed > 0 {
            BTTLog.success("BTT: Removed instrumentation from \(removed) file(s).")
        } else {
            BTTLog.verbose("No files needed reverting for target '\(target)'.")
        }
    }

    func repairBttFolder(projectDir: String, xcodeprojPath: String, store: BTTTargetStore) {
        let fm         = FileManager.default
        let bttDir     = (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName)
        let binaryPath = (bttDir as NSString).appendingPathComponent(BTTConstants.binaryName)
        let scriptPath = (bttDir as NSString).appendingPathComponent(BTTConstants.scriptFileName)
        let configPath = (bttDir as NSString).appendingPathComponent(BTTConstants.configFileName)
        let writer     = BTTScriptWriter(projectDir: projectDir)

        BTTLog.verbose("── repairBttFolder ──")
        BTTLog.verbose("bttDir:     \(bttDir)")
        BTTLog.verbose("binaryPath: \(binaryPath)")
        BTTLog.verbose("scriptPath: \(scriptPath)")
        BTTLog.verbose("configPath: \(configPath)")

        if !fm.fileExists(atPath: bttDir) {
            BTTLog.verbose(".btt folder missing — creating: \(bttDir)")
            try? fm.createDirectory(atPath: bttDir, withIntermediateDirectories: true)
        } else {
            BTTLog.verbose(".btt folder present ✓")
        }

        if !fm.fileExists(atPath: binaryPath) {
            BTTLog.verbose("Binary missing — copying...")
            writer.copyBinary()
        } else {
            BTTLog.verbose("Binary present ✓")
        }

        if !fm.fileExists(atPath: scriptPath) {
            BTTLog.verbose("Script missing — writing...")
            writer.writeInstrumentScript()
        } else {
            BTTLog.verbose("Script present ✓")
        }

        if !fm.fileExists(atPath: configPath) {
            BTTLog.verbose("Config missing — rebuilding from xcodebuild targets (fallback path)...")
            BTTLog.warn("BTT: \(BTTConstants.configFileName) missing — re-run 'BTTInstrumentor install' to reconfigure.")
            let resolver   = BTTProjectResolver(args: args)
            let buildPhase = BTTBuildPhase(xcodeprojPath: xcodeprojPath)
            let targets    = resolver.getTargets(in: xcodeprojPath)
            BTTLog.verbose("Fallback targets from xcodebuild: \(targets.joined(separator: ", "))")
            for target in targets {
                let added = buildPhase.addPreAction(for: target)
                BTTLog.verbose("  addPreAction('\(target)') → \(added)")
                store.add(target, bttSwiftUITrackerAdded: added)
            }
            BTTLog.verbose("Config rebuilt for \(targets.count) target(s).")
        } else {
            BTTLog.verbose("Config present ✓")
        }

        BTTLog.verbose("repairBttFolder complete.")
    }

    func removeBttFolder(projectDir: String) {
        let bttDir = (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName)
        BTTLog.verbose("Removing .btt folder: \(bttDir)")
        do {
            try FileManager.default.removeItem(atPath: bttDir)
            BTTLog.verbose(".btt folder removed ✓")
        } catch {
            BTTLog.verbose(".btt folder removal failed: \(error.localizedDescription)")
        }
    }

    func checkItem(exists: Bool, pass: String, fail: String) {
        if exists { BTTLog.success(pass) } else { BTTLog.error(fail) }
    }
}

#endif
