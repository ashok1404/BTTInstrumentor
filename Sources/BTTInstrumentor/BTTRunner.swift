//
//  BTTRunner.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 12/06/26.
//
//  Top-level entry point. Parses no logic of its own — routes each
//  CLI command to the cmd* method that implements it.
//
//  Public commands  (shown in help)
//  ────────────────────────────────
//  install     – Adds scheme pre-action, saves target, then optionally injects immediately.
//  uninstall   – Reverts injection and removes scheme pre-action for one or all targets.
//  check       – Prints a numbered ✓/✗ checklist with diagnostics.
//
//  Internal command  (not shown in help)
//  ──────────────────────────────────────
//  instrument  – Called by btt_instrument.sh on every Xcode build (non-interactive inject).
//

#if os(macOS)
import Foundation

final class BTTRunner {
    private let args: BTTArgs

    init(args: BTTArgs) {
        self.args = args
        BTTLog.verboseEnabled = args.verbose
    }

    func run() {
        guard !args.command.isEmpty else { printHelp(); exit(0) }

        switch args.command {
        case "install", "instrument", "uninstall", "check":
            BTTLog.info("\(args.command) version \(BTTConstants.version)")
        default:
            break
        }

        switch args.command {
        case "install":              BTTCommand(args: args).cmdInstall()
        case "instrument":           BTTCommand(args: args).cmdInstrument()   // internal — called by btt_instrument.sh
        case "uninstall":            BTTCommand(args: args).cmdUninstall()
        case "check":                BTTDiagnostics(args: args).cmdCheck()
        case "help", "--help", "-h": printHelp()
        default:
            BTTLog.error("Unknown command: '\(args.command)'")
            printHelp()
            exit(1)
        }
    }

    private func printHelp() { BTTLog.info(BTTConstants.helpText) }
}

#endif
