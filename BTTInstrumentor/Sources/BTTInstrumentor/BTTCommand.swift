//
//  BTTCommand.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 12/06/26.
//

#if os(macOS)
import Foundation
import Darwin
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
        let buildPhase    = BTTBuildPhase(xcodeprojPath: xcodeprojPath)
        let schemeResult  = buildPhase.addPreAction(for: selected)
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

        // Always save the target — instrumentation can work even without a scheme
        // (immediate injection now, or manual `BTTInstrumentor instrument` later).
        store.add(selected)
        store.saveXcodeprojName(xcodeprojPath)

        if schemeResult.matchedSchemes.isEmpty {
            BTTLog.warn("No scheme found for target '\(selected)' — pre-action was not injected.")
            BTTLog.warn("  ↳ Auto-instrumentation on every build won't work until you:")
            BTTLog.warn("     1. Create a scheme for '\(selected)' in Xcode (Product → Scheme → New Scheme)")
            BTTLog.warn("     2. Quit Xcode and re-run 'BTTInstrumentor install'")
            BTTLog.success("BTTInstrumentor \(BTTConstants.version) installed for target '\(selected)' (scheme pending)")
        } else {
            BTTLog.verbose("Pre-action present for target \(selected) in scheme(s) \(schemeResult.matchedSchemes.joined(separator: ", "))")
            if !schemeResult.hasSharedScheme {
                BTTLog.warn("Pre-action was injected into a user-local scheme only (\(schemeResult.userOnlySchemes.joined(separator: ", "))).")
                BTTLog.warn("  ↳ User schemes are not shared with the team (typically gitignored).")
                BTTLog.warn("  ↳ To apply to all team members: in Xcode, mark the scheme as Shared (Manage Schemes → tick Shared), then re-run 'BTTInstrumentor install'.")
            }
            BTTLog.success("Successfully installed BTTInstrumentor \(BTTConstants.version) to project \(projName).xcodeproj target \(selected)")
        }

        promptImmediateInstrumentation(for: selected, in: xcodeprojPath, resolver: resolver, hasScheme: !schemeResult.matchedSchemes.isEmpty)
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

        for file in files {
            guard !injector.isIgnored(file: file) else { continue }

            if injector.hasParseErrors(file: file) {
                let name = URL(fileURLWithPath: file).lastPathComponent
                BTTLog.warn("  ✗ \(name) skipped — file has syntax errors, fix and rebuild to instrument")
                continue
            }

            let isModified = isFileModifiedSinceLastInjection(file)
            let isInjected = injector.isInjected(file: file)

            if isModified && isInjected {
                injector.revert(file: file)
                clearInjectionMtime(for: file)
            } else if !isModified && isInjected {
                continue
            }
            let count = injector.inject(file: file)
            if count > 0 {
                if !injector.lastHadComplexViews {
                    setInjectionMtime(for: file)
                }
                injectedViews += count
                injectedFiles += 1
            } else if isInjected && !injector.lastHadComplexViews {
                // File has .bttTrackScreen() but all views were already handled (manual instrumentation).
                // Mark as processed so it isn't re-run on every build.
                setInjectionMtime(for: file)
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

        guard !args.nonInteractive else {
            BTTLog.warn("Uninstall requires interactive mode — run from terminal.")
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
    private func promptImmediateInstrumentation(for target: String, in xcodeprojPath: String, resolver: BTTProjectResolver, hasScheme: Bool) {
        BTTLog.info("Scanning project...")

        let files = resolver.getSwiftFiles(for: target, in: xcodeprojPath)
        guard !files.isEmpty else {
            BTTLog.warn("No Swift files found for '\(target)'.")
            printNextBuildMessage(hasScheme: hasScheme)
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

        guard !args.nonInteractive else { return }

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

                if !hasScheme {
                    BTTLog.warn("This is a one-time injection — new or modified views won't be re-instrumented automatically.")
                    BTTLog.warn("  ↳ Create a scheme for '\(target)' in Xcode and re-run 'BTTInstrumentor install' to enable auto-instrumentation on every build.")
                }
            } else {
                printNextBuildMessage(hasScheme: hasScheme)
            }
        } else {
            printNextBuildMessage(hasScheme: hasScheme)
        }
    }

    private func printNextBuildMessage(hasScheme: Bool) {
        if hasScheme {
            BTTLog.info("On next build all SwiftUI views will be instrumented automatically. For more info see \(BTTConstants.docsURL)\n")
        } else {
            BTTLog.warn("Auto-instrumentation on build is not active — no scheme is set up.")
            BTTLog.warn("  ↳ Create a scheme for your target in Xcode and re-run 'BTTInstrumentor install'.")
        }
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

        guard !args.nonInteractive else { return allTargets[0] }

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
                if !matchedSchemes.matchedSchemes.isEmpty {
                    store.add(target)
                }
            }
        }
    }

    private func removeBttFolder(projectDir: String) {
        let bttDir = (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName)
        try? FileManager.default.removeItem(atPath: bttDir)
    }

    /// Returns the Objects-normal directory where Xcode stores .o files from the previous build.
    /// Pre-actions run before compilation so OBJECT_FILE_DIR_normal and CURRENT_ARCH are not yet set.
    /// We derive Objects-normal from OBJECT_FILE_DIR by replacing the trailing "Objects" component.
    // MARK: - Xattr-based injection tracking

    private static let bttXattrKey = "com.bluetriangle.btt-injected"

    /// True if the file's mtime differs from what was recorded at last injection.
    /// Falls back to true (inject) when no xattr exists — e.g. first build or clean.
    private func isFileModifiedSinceLastInjection(_ path: String) -> Bool {
        guard let currentMtime = swiftMtime(path) else { return true }
        guard let stored = readXattr(path: path, key: Self.bttXattrKey),
              let storedMtime = Int(stored)
        else { return true }
        return Int(currentMtime.timeIntervalSince1970) != storedMtime
    }

    private func setInjectionMtime(for path: String) {
        guard let mtime = swiftMtime(path) else { return }
        writeXattr(path: path, key: Self.bttXattrKey, value: "\(Int(mtime.timeIntervalSince1970))")
    }

    private func clearInjectionMtime(for path: String) {
        removexattr(path, Self.bttXattrKey, 0)
    }

    private func swiftMtime(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func readXattr(path: String, key: String) -> String? {
        let len = getxattr(path, key, nil, 0, 0, 0)
        guard len > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard getxattr(path, key, &buf, len, 0, 0) == len else { return nil }
        return String(bytes: buf, encoding: .utf8)
    }

    private func writeXattr(path: String, key: String, value: String) {
        value.withCString { ptr in
            _ = setxattr(path, key, ptr, strlen(ptr), 0, 0)
        }
    }
}

#endif
