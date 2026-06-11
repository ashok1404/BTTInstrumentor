//
//  BTTCommandRunner.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 09/06/26.
//
//  Entry point — parses the command and routes to BTTCommandHandler.
//

#if os(macOS)
import Foundation

final class BTTCommandRunner {
    private let args: BTTArgs

    init(args: BTTArgs) {
        self.args = args
        BTTLog.verboseEnabled = args.verbose
    }

    func run() {
        BTTLog.verbose("BTTCommandRunner.run() — command='\(args.command)' rootPath='\(args.rootPath)' projectPath='\(args.projectPath ?? "nil")' target='\(args.target ?? "nil")' scheme='\(args.scheme ?? "nil")' verbose=\(args.verbose)")
        BTTLog.verbose("isatty(STDIN_FILENO)=\(isatty(STDIN_FILENO)) (0=non-interactive/scheme pre-action)")

        guard !args.command.isEmpty else { BTTLog.info(BTTConstants.helpText); exit(0) }

        let handler = BTTCommandHandler(args: args)

        switch args.command {
        case "install":              handler.runInstall()
        case "instrument":           handler.runInstrument()
        case "uninstall":            handler.runUninstall()
        case "check":                handler.runCheck()
        case "help", "--help", "-h": BTTLog.info(BTTConstants.helpText)
        default:
            BTTLog.error("Unknown command: '\(args.command)'")
            BTTLog.info(BTTConstants.helpText)
            exit(1)
        }
    }
}

#endif
