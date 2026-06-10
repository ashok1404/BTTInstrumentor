//
//  BTTArgs.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

import Foundation

struct BTTArgs {

    // MARK: - Properties

    var command:     String  = ""
    var projectPath: String? = nil
    var target:      String? = nil
    var scheme:      String? = nil
    var rootPath:    String  = FileManager.default.currentDirectoryPath

    // MARK: - Factory

    /// Parses CommandLine.arguments and returns a populated BTTArgs value.
    static func parse() -> BTTArgs {
        var result    = BTTArgs()
        var remaining = Array(CommandLine.arguments.dropFirst())
        guard !remaining.isEmpty else { return result }

        result.command = remaining.removeFirst()

        var i = 0
        while i < remaining.count {
            switch remaining[i] {
            case "--target":
                if i + 1 < remaining.count { result.target = remaining[i + 1]; i += 1 }

            case "--scheme":
                if i + 1 < remaining.count { result.scheme = remaining[i + 1]; i += 1 }

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
