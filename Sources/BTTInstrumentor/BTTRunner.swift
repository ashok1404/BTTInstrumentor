//
//  BTTRunner.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 12/06/26.
//

#if os(macOS)
import Foundation

final class BTTRunner {
    private let args: BTTArgs

    init(args: BTTArgs) {
        self.args = args
        BTTLog.verboseEnabled = args.verbose
        BTTLog.nonInteractive = args.nonInteractive
    }

    func run() {
        guard !args.command.isEmpty else { BTTLog.info(BTTConstants.helpText); exit(0) }

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
        case "--version", "version": BTTLog.info("BTTInstrumentor \(BTTConstants.version)")
        case "help", "--help", "-h": BTTLog.info(BTTConstants.helpText)
        default:
            BTTLog.error("Unknown command: '\(args.command)'")
            BTTLog.info(BTTConstants.helpText)
            exit(1)
        }
    }
}

#endif
