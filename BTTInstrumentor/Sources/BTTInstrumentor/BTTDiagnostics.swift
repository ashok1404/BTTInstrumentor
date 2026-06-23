//
//  BTTDiagnostics.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 12/06/26.
//

#if os(macOS)
import Foundation
import PathKit
import XcodeProj

final class BTTDiagnostics {
    private let args: BTTArgs

    init(args: BTTArgs) {
        self.args = args
    }

    // MARK: - check (public)

    func cmdCheck() {
        BTTLog.info("Looking for .xcodeproj files")
        let xcodeprojPath = requireXcodeproj()
        let projectDir    = (xcodeprojPath as NSString).deletingLastPathComponent
        let bttDir        = (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName)
        let store         = BTTTargetStore(projectDir: projectDir)
        let fm            = FileManager.default

        var step = 0
        var failed = 0
        func next() -> Int { step += 1; return step }
        func check(_ n: Int, exists: Bool, pass: String, fail: String, diagnose: String? = nil) {
            if !exists { failed += 1 }
            checkItem(n, exists: exists, pass: pass, fail: fail, diagnose: diagnose)
        }

        check(next(),
            exists: true,
            pass: "Project: \(URL(fileURLWithPath: xcodeprojPath).lastPathComponent)",
            fail: ""
        )

        if let savedName = store.savedXcodeprojName() {
            let currentName = URL(fileURLWithPath: xcodeprojPath).lastPathComponent
            let namesMatch  = savedName == currentName

            check(next(),
                exists: namesMatch,
                pass: "Saved project matches: \(savedName)",
                fail: "Saved project mismatch — run 'BTTInstrumentor install'",
                diagnose: "saved: \(savedName)\n       current: \(currentName)"
            )
        } else {
            check(next(),
                exists: false,
                pass: "",
                fail: "No project path saved in config — run 'BTTInstrumentor install'",
                diagnose: "expected key 'xcodeprojPath' not found in \((bttDir as NSString).appendingPathComponent(BTTConstants.configFileName))"
            )
        }

        let checker = BTTVersionChecker(xcodeprojPath: xcodeprojPath)
        if BTTConstants.isForkedVersion {
            BTTLog.checklist("\(next()). ⚠ BlueTriangle: isForkedVersion = true — version check skipped.", ok: false)
            BTTLog.checklist("    ↳ set BTTConstants.isForkedVersion = false before release to enable this check", ok: false)
        } else if let version = checker.resolvedVersion() {
            check(next(),
                exists: BTTVersionChecker.isVersion(version, atLeast: BTTConstants.minBTTVersion),
                pass: "BlueTriangle version: \(version) (>= \(BTTConstants.minBTTVersion))",
                fail: "BlueTriangle version: \(version) (requires >= \(BTTConstants.minBTTVersion))",
                diagnose: "Package.resolved pins BlueTriangle \(version); open Xcode → File → Packages → Update to Latest Package Versions"
            )
        } else {
            check(next(),
                exists: false,
                pass: "",
                fail: "BlueTriangle version: not found in Package.resolved",
                diagnose: "no 'btt-swift-sdk' pin found in any Package.resolved (checked project, workspace, and root)"
            )
        }

        let bttDirExists = fm.fileExists(atPath: bttDir)
        checkItem(next(),
            exists: bttDirExists,
            pass: ".btt folder exists",
            fail: ".btt folder missing — run 'BTTInstrumentor install'",
            diagnose: "expected at \(bttDir)"
        )

        let binaryPath = (bttDir as NSString).appendingPathComponent(BTTConstants.binaryName)
        checkItem(next(),
            exists: fm.fileExists(atPath: binaryPath),
            pass: "BTTInstrumentor binary present",
            fail: "BTTInstrumentor binary missing — run 'BTTInstrumentor install'",
            diagnose: "expected at \(binaryPath)"
        )

        let scriptPath = (bttDir as NSString).appendingPathComponent(BTTConstants.scriptFileName)
        checkItem(next(),
            exists: fm.fileExists(atPath: scriptPath),
            pass: "\(BTTConstants.scriptFileName) exists",
            fail: "\(BTTConstants.scriptFileName) missing — run 'BTTInstrumentor install'",
            diagnose: "expected at \(scriptPath)"
        )

        let configPath = (bttDir as NSString).appendingPathComponent(BTTConstants.configFileName)
        checkItem(next(),
            exists: fm.fileExists(atPath: configPath),
            pass: "\(BTTConstants.configFileName) exists",
            fail: "\(BTTConstants.configFileName) missing — run 'BTTInstrumentor install'",
            diagnose: "expected at \(configPath)"
        )

        let targets = store.targets
        checkItem(next(),
            exists: !targets.isEmpty,
            pass: "Instrumented targets: \(targets.joined(separator: ", "))",
            fail: "No instrumented targets found — run 'BTTInstrumentor install'",
            diagnose: "'targets' array in \(configPath) is empty"
        )

        if let xcodeproj = try? XcodeProj(path: Path(xcodeprojPath)) {
            for target in targets {
                if let native = xcodeproj.pbxproj.nativeTargets.first(where: { $0.name == target }) {
                    let linkedProducts = (native.packageProductDependencies ?? []).map { $0.productName }
                    let hasBTT = linkedProducts.contains(BTTConstants.bttProductName)
                    check(next(),
                        exists: hasBTT,
                        pass: "\(BTTConstants.bttProductName) linked: \(target)",
                        fail: "\(BTTConstants.bttProductName) not linked in '\(target)' — add BlueTriangle SDK to this target",
                        diagnose: "current dependencies: \(linkedProducts.isEmpty ? "(none)" : linkedProducts.joined(separator: ", "))"
                    )
                }
            }
        }

        let buildPhase  = BTTBuildPhase(xcodeprojPath: xcodeprojPath)
        let schemePaths = buildPhase.collectSchemePaths()
        for target in targets {
            let hasPreAction = schemePaths.contains { path in
                guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
                return content.contains(BTTConstants.preActionTitle) &&
                       content.contains("BlueprintName = \"\(target)\"")
            }
            check(next(),
                exists: hasPreAction,
                pass: "Pre-action in scheme: \(target)",
                fail: "Pre-action missing for '\(target)' (quit Xcode, mandatory for proper instrumentation) — run 'BTTInstrumentor install'",
                diagnose: schemePaths.isEmpty
                    ? "no .xcscheme files found — create a scheme for '\(target)' in Xcode (Product → Scheme → New Scheme), then re-run 'BTTInstrumentor install'"
                    : "checked scheme(s): \(schemePaths.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }.joined(separator: ", ")) — none reference target '\(target)' with pre-action '\(BTTConstants.preActionTitle)'"
            )
        }

        if !bttDirExists {
            BTTLog.warn(".btt folder is missing, so the items above show as missing too — run 'BTTInstrumentor install' to recreate everything.")
        }
    }

    // MARK: - Private helpers

    private func requireXcodeproj() -> String {
        guard let path = BTTProjectResolver(args: args).resolveXcodeproj() else {
            BTTLog.error("No .xcodeproj found in \(args.rootPath)")
            exit(1)
        }
        return path
    }

    /// Prints a numbered checklist line: `N. ✓ message` or `N. ✗ message`.
    /// On failure, optionally prints an indented `   ↳ reason` diagnostic line.
    private func checkItem(_ n: Int, exists: Bool, pass: String, fail: String, diagnose: String? = nil) {
        BTTLog.checklist("\(n). \(exists ? "✓" : "✗") \(exists ? pass : fail)", ok: exists)
        if !exists, let diagnose, !diagnose.isEmpty {
            BTTLog.checklist("    ↳ \(diagnose)", ok: false)
        }
    }
}

#endif
