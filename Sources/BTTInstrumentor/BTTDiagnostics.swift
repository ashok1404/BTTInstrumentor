//
//  BTTDiagnostics.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 12/06/26.
//
//  Implements the `check` command — a numbered ✓/✗ checklist that verifies
//  every step of BTTInstrumentor's setup, with a diagnostic line under each
//  failure explaining the actual cause.
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
        BTTLog.info("\nBlueTriangle BTTInstrumentor — Setup Check\n")

        let xcodeprojPath = requireXcodeproj()
        let projectDir    = (xcodeprojPath as NSString).deletingLastPathComponent
        let bttDir        = (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName)
        let store         = BTTTargetStore(projectDir: projectDir)
        let fm            = FileManager.default

        var step = 0
        func next() -> Int { step += 1; return step }

        checkItem(next(),
            exists: true,
            pass: "Project: \(URL(fileURLWithPath: xcodeprojPath).lastPathComponent)",
            fail: ""
        )

        if let saved = store.savedXcodeprojPath() {
            checkItem(next(),
                exists: saved == xcodeprojPath,
                pass: "Saved project path matches: \(URL(fileURLWithPath: saved).lastPathComponent)",
                fail: "Saved project path mismatch — run 'BTTInstrumentor install'",
                diagnose: "saved: \(saved)\n       current: \(xcodeprojPath)"
            )
        } else {
            checkItem(next(),
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
            checkItem(next(),
                exists: BTTVersionChecker.isVersion(version, atLeast: BTTConstants.minBTTVersion),
                pass: "BlueTriangle version: \(version) (>= \(BTTConstants.minBTTVersion))",
                fail: "BlueTriangle version: \(version) (requires >= \(BTTConstants.minBTTVersion))",
                diagnose: "Package.resolved pins BlueTriangle \(version); open Xcode → File → Packages → Update to Latest Package Versions"
            )
        } else {
            checkItem(next(),
                exists: false,
                pass: "",
                fail: "BlueTriangle version: not found in Package.resolved",
                diagnose: "no 'btt-swift-sdk' pin found in any Package.resolved (checked project, workspace, and root)"
            )
        }

        checkItem(next(),
            exists: fm.fileExists(atPath: bttDir),
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
                    let hasDep = linkedProducts.contains(BTTConstants.bttSwiftUITrackerProduct)
                    checkItem(next(),
                        exists: hasDep,
                        pass: "\(BTTConstants.bttSwiftUITrackerProduct) linked: \(target)",
                        fail: "\(BTTConstants.bttSwiftUITrackerProduct) not linked in '\(target)' — run 'BTTInstrumentor install'",
                        diagnose: "current dependencies for '\(target)': \(linkedProducts.isEmpty ? "(none)" : linkedProducts.joined(separator: ", "))"
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
            checkItem(next(),
                exists: hasPreAction,
                pass: "Pre-action in scheme: \(target)",
                fail: "Pre-action missing for '\(target)' — run 'BTTInstrumentor install'",
                diagnose: schemePaths.isEmpty
                    ? "no .xcscheme files found in xcshareddata/xcschemes or xcuserdata"
                    : "checked scheme(s): \(schemePaths.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }.joined(separator: ", ")) — none reference target '\(target)' with pre-action '\(BTTConstants.preActionTitle)'"
            )
        }

        BTTLog.info("")
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
