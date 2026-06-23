//
//  BTTArgs.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

import Foundation

struct BTTArgs {
    var command:        String  = ""
    var projectPath:    String? = nil
    var verbose:        Bool    = false
    var nonInteractive: Bool    = false   // true when invoked from btt_instrument.sh (Xcode build)
    var rootPath:       String  = FileManager.default.currentDirectoryPath

    /// Parses CommandLine.arguments and returns a populated BTTArgs value.
    static func parse() -> BTTArgs {
        var result    = BTTArgs()
        var remaining = Array(CommandLine.arguments.dropFirst())
        guard !remaining.isEmpty else { return result }

        result.command = remaining.removeFirst()

        var i = 0
        while i < remaining.count {
            switch remaining[i] {
            case "--verbose":
                result.verbose = true

            case "--non-interactive":
                result.nonInteractive = true

            default:
                guard !remaining[i].hasPrefix("--") else { break }
                if remaining[i].hasSuffix(".xcodeproj") {
                    result.projectPath = remaining[i]
                } else {
                    result.rootPath = remaining[i].hasPrefix("~")
                        ? NSHomeDirectory() + remaining[i].dropFirst()
                        : remaining[i]
                }
            }
            i += 1
        }
        return result
    }
}
