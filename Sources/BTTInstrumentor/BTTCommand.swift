//
//  BTTCommand.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 12/06/26.
//

#if os(macOS)
import Foundation
import PathKit
import XcodeProj

final class BTTCommand {
    private let args: BTTArgs

    init(args: BTTArgs) {
        self.args = args
    }

    // MARK: - install (public)
    func cmdInstall() {
        BTTLog.verbose("Looking for .xcodeproj files")
        let xcodeprojPath = requireXcodeproj()
        let projName      = ((xcodeprojPath as NSString).lastPathComponent as NSString).deletingPathExtension
        BTTLog.verbose("Found \(projName).xcodeproj")

        requireBTTVersion(xcodeprojPath: xcodeprojPath)

        // ── Resolve targets ───────────────────────────────────────────────────
        let projectDir = (xcodeprojPath as NSString).deletingLastPathComponent
        let store      = BTTTargetStore(projectDir: projectDir)
        store.saveXcodeprojName(xcodeprojPath)

        // ── Set up .btt folder early so update check can compare binaries ─────
        let bttDir        = (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName)
        let bttDirExisted = FileManager.default.fileExists(atPath: bttDir)
        let writer        = BTTScriptWriter(projectDir: projectDir)

        if !bttDirExisted {
            try? FileManager.default.createDirectory(atPath: bttDir, withIntermediateDirectories: true)
            BTTLog.verbose("Created .btt folder")
        }

        // ── Check for newer version ───────────────────────────────────────────
        let wasUpdated = writer.promptUpdateIfAvailable()
        if wasUpdated && !store.targets.isEmpty {
            switch writer.writeInstrumentScript() {
            case .written:            BTTLog.verbose("Updated \(BTTConstants.scriptFileName)")
            case .unchanged:          BTTLog.verbose("\(BTTConstants.scriptFileName) already up to date")
            case .failed(let reason): BTTLog.warn("Script update failed — \(reason)")
            }
            store.saveXcodeprojName(xcodeprojPath)
        }

        let resolver   = BTTProjectResolver(args: args)
        let allTargets = resolver.getTargets(in: xcodeprojPath)
        BTTLog.verbose("Found \(allTargets.count) target(s) in \(projName).xcodeproj: \(allTargets.joined(separator: ", "))")

        let selected = promptTargetSelection(store: store, allTargets: allTargets)

        if !store.isInstrumented(selected) {
            requireBlueTriangle(xcodeprojPath: xcodeprojPath, target: selected)
        }

        let binaryResult = writer.copyBinary()
        switch binaryResult {
        case .written:
            BTTLog.verbose("Injected BTTInstrumentor binary into .btt/")
        case .unchanged:
            break
        case .failed(let reason):
            BTTLog.error("Install failed — could not install BTTInstrumentor binary.")
            BTTLog.error("  ↳ \(reason)")
            exit(1)
        }

        // ── Inject pre-action ─────────────────────────────────────────────────
        let buildPhase      = BTTBuildPhase(xcodeprojPath: xcodeprojPath)
        let matchingSchemes = buildPhase.addPreAction(for: selected)
        BTTLog.verbose("Created \(BTTConstants.configFileName)")

        let scriptResult = writer.writeInstrumentScript()
        switch scriptResult {
        case .written:
            BTTLog.verbose("Created \(BTTConstants.scriptFileName)")
        case .unchanged:
            BTTLog.verbose("\(BTTConstants.scriptFileName) already up to date")
        case .failed(let reason):
            BTTLog.error("Install failed — could not write \(BTTConstants.scriptFileName).")
            BTTLog.error("  ↳ \(reason)")
            exit(1)
        }

        if matchingSchemes.isEmpty {
            BTTLog.warn("No scheme found referencing target '\(selected)' — pre-action was not injected.")
            BTTLog.warn("  ↳ instrumentation will not run automatically on build. Add the target to a scheme and re-run 'BTTInstrumentor install'.")
        } else {
            BTTLog.verbose("Pre-action present for target \(selected) in scheme(s) \(matchingSchemes.joined(separator: ", "))")
        }


        let setupSucceeded = !matchingSchemes.isEmpty
        if setupSucceeded {
            store.add(selected)
            store.saveXcodeprojName(xcodeprojPath)
        } else {
            store.remove(selected)
        }

        if !setupSucceeded {
            BTTLog.warn("Install completed with warnings for project \(projName).xcodeproj target \(selected). Run 'BTTInstrumentor check' for details.")
            return
        }

        BTTLog.success("Successfully installed BTTInstrumentor \(BTTConstants.version) to project \(projName).xcodeproj target \(selected)")

        promptImmediateInstrumentation(for: selected, in: xcodeprojPath, resolver: resolver)
    }

    // MARK: - instrument (internal — invoked by btt_instrument.sh on every Xcode build)
    func cmdInstrument() {
        BTTLog.verbose("Looking for .xcodeproj files")
        guard let xcodeprojPath = BTTProjectResolver(args: args).resolveXcodeproj() else {
            BTTLog.warn("No .xcodeproj found")
            return
        }
        let projName      = ((xcodeprojPath as NSString).lastPathComponent as NSString).deletingPathExtension
        BTTLog.verbose("Found \(projName).xcodeproj")
        
        let projectDir = (xcodeprojPath as NSString).deletingLastPathComponent
        let store      = BTTTargetStore(projectDir: projectDir)

        repairBttFolder(projectDir: projectDir, xcodeprojPath: xcodeprojPath, store: store)

        let resolver = BTTProjectResolver(args: args)
        let targets  = store.targets.isEmpty ? resolver.getTargets(in: xcodeprojPath) : store.targets
        BTTLog.verbose("Found instrumented targets: \(targets.joined(separator: ", "))")
        BTTLog.verbose("Scanning project ...")
        
        var files = [String]()
        var seen  = Set<String>()
        for target in targets {
            resolver.getSwiftFiles(for: target, in: xcodeprojPath)
                .filter { seen.insert($0).inserted }
                .forEach { files.append($0) }
        }

        guard !files.isEmpty else { BTTLog.warn("No Swift files found"); return }

        let injector      = BTTInjectRevertHandler()
        var injectedFiles = 0
        var injectedViews = 0
        let start         = Date()

        let objectFileDir = ProcessInfo.processInfo.environment["OBJECT_FILE_DIR"]
        for file in files {
            guard !injector.isIgnored(file: file) else { continue }

            let isModified = isFileModifiedSinceLastCompile(file, objectFileDir: objectFileDir)
            let isInjected = injector.isInjected(file: file)

            if isModified && isInjected {
                // File changed and was previously injected — strip and re-inject
                injector.revert(file: file)
            } else if !isModified && isInjected {
                // File unchanged and already injected — nothing to do
                continue
            }
            // Remaining cases: modified+not-injected, or not-modified+not-injected → inject
            let count = injector.inject(file: file)
            if count > 0 {
                injectedViews += count
                injectedFiles += 1
            }
        }

        let ms = Int(Date().timeIntervalSince(start) * 1000)
        BTTLog.success("Instrumentation completed — SwiftUI files \(injectedFiles), SwiftUI views \(injectedViews), time taken \(ms) ms")
    }

    // MARK: - uninstall (public)
    func cmdUninstall() {
        BTTLog.verbose("Looking for .xcodeproj files")
        let xcodeprojPath = requireXcodeproj()
        let projName      = ((xcodeprojPath as NSString).lastPathComponent as NSString).deletingPathExtension
        BTTLog.verbose("Found \(projName).xcodeproj")

        let projectDir   = (xcodeprojPath as NSString).deletingLastPathComponent
        let store        = BTTTargetStore(projectDir: projectDir)
        let instrumented = store.targets

        guard !instrumented.isEmpty else {
            BTTLog.warn("No instrumented targets found.")
            return
        }

        BTTLog.verbose("Instrumented targets: \(instrumented.joined(separator: ", "))")

        BTTLog.prompt("\nWhich target do you want to remove?\n\n")
        instrumented.enumerated().forEach { i, t in BTTLog.prompt("  \(i + 1). \(t)\n") }
        BTTLog.prompt("  \(instrumented.count + 1). Remove all (full clean up)\n")
        BTTLog.prompt("\nEnter the number: ")

        guard let input = readLine()?.trimmingCharacters(in: .whitespaces),
              let idx   = Int(input),
              (1...instrumented.count + 1).contains(idx)
        else {
            BTTLog.warn("Invalid selection.")
            return
        }

        let buildPhase = BTTBuildPhase(xcodeprojPath: xcodeprojPath)
        let injector   = BTTInjectRevertHandler()
        let resolver   = BTTProjectResolver(args: args)

        if idx == instrumented.count + 1 {
            // ── Remove all ────────────────────────────────────────────────────
            BTTLog.verbose("Reverting all targets: \(instrumented.joined(separator: ", "))")
            var totalFiles = 0
            var totalViews = 0
            let start      = Date()

            for target in instrumented {
                let (f, v) = revertSwiftFiles(for: target, in: xcodeprojPath, resolver: resolver, injector: injector)
                totalFiles += f
                totalViews += v
            }

            let preActionsRemoved = buildPhase.removePreActions(store: store)
            if preActionsRemoved {
                BTTLog.verbose("Removed pre-action scripts")
            } else {
                BTTLog.warn("No pre-action scripts found to remove — schemes may already be clean.")
            }

            let bttDirPath = (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName)
            let bttDirExistedBeforeRemoval = FileManager.default.fileExists(atPath: bttDirPath)
            removeBttFolder(projectDir: projectDir)
            let bttDirStillExists = FileManager.default.fileExists(atPath: bttDirPath)
            if bttDirStillExists {
                BTTLog.error("Failed to remove .btt folder at \(bttDirPath).")
                BTTLog.error("  ↳ check folder permissions and remove it manually if needed.")
            } else if bttDirExistedBeforeRemoval {
                BTTLog.verbose("Removed .btt folder")
            }

            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if totalFiles == 0 && totalViews == 0 {
                BTTLog.warn("Uninstall ran but no instrumented SwiftUI files were found to revert (time taken \(ms) ms).")
            } else {
                BTTLog.success("Uninstall completed — SwiftUI files \(totalFiles), SwiftUI views \(totalViews), time taken \(ms) ms")
            }

            if bttDirStillExists || !preActionsRemoved {
                BTTLog.warn("All BTT instrumentation removal completed with warnings. Run 'BTTInstrumentor check' for details.")
            } else {
                BTTLog.success("✓ All BTT instrumentation removed.")
            }
        } else {
            // ── Remove single target ──────────────────────────────────────────
            let target      = instrumented[idx - 1]
            let keepTargets = instrumented.filter { $0 != target }

            let start = Date()
            let (revertedFiles, revertedViews) = revertSwiftFiles(
                for: target, in: xcodeprojPath, resolver: resolver, injector: injector
            )

            let preActionRemoved = buildPhase.removePreActions(for: target, keepTargets: keepTargets, store: store)
            store.remove(target)
            if preActionRemoved {
                BTTLog.verbose("Removed pre-action script for target \(target)")
            } else {
                BTTLog.warn("No pre-action script found for target '\(target)' — scheme may already be clean.")
            }

            // If this was the last instrumented target, the .btt folder is no
            // longer needed — clean it up the same way "remove all" does.
            var bttFolderRemoved = false
            var bttDirStillExists = false
            if store.targets.isEmpty {
                BTTLog.verbose("'\(target)' was the last instrumented target — removing .btt folder")
                let bttDirPath = (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName)
                removeBttFolder(projectDir: projectDir)
                bttDirStillExists = FileManager.default.fileExists(atPath: bttDirPath)
                if bttDirStillExists {
                    BTTLog.error("Failed to remove .btt folder at \(bttDirPath).")
                    BTTLog.error("  ↳ check folder permissions and remove it manually if needed.")
                } else {
                    BTTLog.verbose("Removed .btt folder")
                    bttFolderRemoved = true
                }
            }

            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if revertedFiles == 0 && revertedViews == 0 {
                BTTLog.warn("Uninstall ran but no instrumented SwiftUI files were found for '\(target)' (time taken \(ms) ms).")
            } else {
                BTTLog.success("Uninstall completed — SwiftUI files \(revertedFiles), SwiftUI views \(revertedViews), time taken \(ms) ms")
            }

            if preActionRemoved && !bttDirStillExists {
                BTTLog.success("✓ '\(target)' removed.")
                if bttFolderRemoved {
                    BTTLog.success("✓ .btt folder removed (no instrumented targets remain).")
                }
            } else {
                BTTLog.warn("'\(target)' removed with warnings. Run 'BTTInstrumentor check' for details.")
            }
        }
    }

    // MARK: - Post-install scan + prompt
    private func promptImmediateInstrumentation(for target: String, in xcodeprojPath: String, resolver: BTTProjectResolver) {
        BTTLog.info("Scanning project...")

        let files = resolver.getSwiftFiles(for: target, in: xcodeprojPath)
        guard !files.isEmpty else {
            BTTLog.warn("No Swift files found for '\(target)'.")
            printNextBuildMessage()
            return
        }

        // Dry-run: count without writing
        var swiftUIFiles = 0
        var swiftUIViews = 0
        let counter      = BTTInjectRevertHandler()
        for file in files {
            let count = counter.countInjectableViews(file: file)
            if count > 0 { swiftUIViews += count; swiftUIFiles += 1 }
        }

        BTTLog.info("Found \(swiftUIFiles) SwiftUI file(s) and \(swiftUIViews) view(s)\n")
        
        if swiftUIFiles > 0 {
            BTTLog.prompt("Instrument all? (y/n): ")
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
            if answer == "y" || answer == "yes" {
                let injector  = BTTInjectRevertHandler()
                var injFiles  = 0
                var injViews  = 0
                let start     = Date()
                
                for file in files {
                    let count = injector.inject(file: file)
                    if count > 0 { injViews += count; injFiles += 1 }
                }
                
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                BTTLog.success("Instrumentation completed — SwiftUI files \(injFiles), SwiftUI views \(injViews), time taken \(ms) ms")
            } else {
                printNextBuildMessage()
            }
        } else {
            printNextBuildMessage()
        }
    }

    private func printNextBuildMessage() {
        BTTLog.info("On next build all SwiftUI views will be instrumented automatically. For more info see \(BTTConstants.docsURL)\n")
    }

    // MARK: - Private helpers
    private func requireBTTVersion(xcodeprojPath: String) {
        guard BTTVersionChecker(xcodeprojPath: xcodeprojPath).checkAndProceed() else { exit(0) }
    }

    private func requireBlueTriangle(xcodeprojPath: String, target: String) {
        guard let xcodeproj = try? XcodeProj(path: Path(xcodeprojPath)),
              let native = xcodeproj.pbxproj.nativeTargets.first(where: { $0.name == target })
        else { return }
        let linked = (native.packageProductDependencies ?? []).map { $0.productName }
        guard !linked.contains(BTTConstants.bttProductName) else { return }
        BTTLog.error("\(BTTConstants.bttProductName) is not linked to '\(target)'.")
        BTTLog.error("  ↳ Add BlueTriangle SDK to your target in Xcode before running BTTInstrumentor.")
        exit(1)
    }

    private func requireXcodeproj() -> String {
        guard let path = BTTProjectResolver(args: args).resolveXcodeproj() else {
            BTTLog.error("No .xcodeproj found in \(args.rootPath)")
            exit(1)
        }
        return path
    }

    private func promptTargetSelection(store: BTTTargetStore, allTargets: [String]) -> String {
        guard !allTargets.isEmpty else {
            BTTLog.error("No targets found in project.")
            exit(1)
        }

        BTTLog.prompt("\nWhich target do you want to instrument?\n\n")
        allTargets.enumerated().forEach { i, t in
            let tag = store.isInstrumented(t) ? " (already instrumented)" : ""
            BTTLog.prompt("  \(i + 1). \(t)\(tag)\n")
        }
        BTTLog.prompt("\nEnter the number: ")

        if let input = readLine()?.trimmingCharacters(in: .whitespaces),
           let idx   = Int(input),
           (1...allTargets.count).contains(idx) {
            return allTargets[idx - 1]
        }
        return allTargets[0]
    }

    /// Reverts Swift files for `target` and returns (revertedFiles, revertedViews).
    @discardableResult
    private func revertSwiftFiles(
        for target: String,
        in xcodeprojPath: String,
        resolver: BTTProjectResolver,
        injector: BTTInjectRevertHandler
    ) -> (files: Int, views: Int) {
        let files = resolver.getSwiftFiles(for: target, in: xcodeprojPath)
        BTTLog.verbose("Scanning \(files.count) Swift file(s) for target \(target)")
        var removedFiles = 0
        var removedViews = 0
        for file in files {
            let count = injector.revert(file: file)
            if count > 0 { removedFiles += 1; removedViews += count }
        }
        return (removedFiles, removedViews)
    }

    private func repairBttFolder(projectDir: String, xcodeprojPath: String, store: BTTTargetStore) {
        let fm         = FileManager.default
        let bttDir     = (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName)
        let binaryPath = (bttDir as NSString).appendingPathComponent(BTTConstants.binaryName)
        let configPath = (bttDir as NSString).appendingPathComponent(BTTConstants.configFileName)
        let writer     = BTTScriptWriter(projectDir: projectDir)

        if !fm.fileExists(atPath: bttDir) {
            try? fm.createDirectory(atPath: bttDir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: binaryPath) {
            if case .failed(let reason) = writer.copyBinary() {
                BTTLog.warn("Could not restore BTTInstrumentor binary — \(reason)")
            }
        }

        switch writer.writeInstrumentScript() {
        case .written:
            BTTLog.verbose("Updated \(BTTConstants.scriptFileName) (was stale)")
        case .unchanged:
            break
        case .failed(let reason):
            BTTLog.warn("Could not update \(BTTConstants.scriptFileName) — \(reason)")
        }
        if !fm.fileExists(atPath: configPath) {
            BTTLog.warn("\(BTTConstants.configFileName) missing — re-run 'BTTInstrumentor install' to reconfigure.")
            let resolver   = BTTProjectResolver(args: args)
            let buildPhase = BTTBuildPhase(xcodeprojPath: xcodeprojPath)
            for target in resolver.getTargets(in: xcodeprojPath) {
                let matchedSchemes = buildPhase.addPreAction(for: target)
                if !matchedSchemes.isEmpty {
                    store.add(target)
                }
            }
        }
    }

    private func removeBttFolder(projectDir: String) {
        let bttDir = (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName)
        try? FileManager.default.removeItem(atPath: bttDir)
    }

    /// Returns true if the Swift file is newer than its compiled .o counterpart.
    /// OBJECT_FILE_DIR is always set by Xcode when instrument runs via pre-action.
    /// Falls back to true when .o doesn't exist yet (clean/first build).
    private func isFileModifiedSinceLastCompile(_ swiftFile: String, objectFileDir: String?) -> Bool {
        guard let objDir = objectFileDir else { return true }
        let baseName = ((swiftFile as NSString).lastPathComponent as NSString).deletingPathExtension
        let objFile  = (objDir as NSString).appendingPathComponent("\(baseName).o")
        let fm       = FileManager.default
        guard fm.fileExists(atPath: objFile),
              let swiftMtime = (try? fm.attributesOfItem(atPath: swiftFile))?[.modificationDate] as? Date,
              let objMtime   = (try? fm.attributesOfItem(atPath: objFile))?[.modificationDate] as? Date
        else { return true }
        return swiftMtime > objMtime
    }
}

#endif
