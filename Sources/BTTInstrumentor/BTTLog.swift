//
//  BTTLog.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

#if os(macOS)
import Foundation

enum BTTLog {
    // MARK: - Verbose flag
    static var verboseEnabled: Bool = false
    static var prefix: String = "BTTInstrumentor: "

    // MARK: - Private
    private static let isTTY  = isatty(STDOUT_FILENO) != 0
    private static let reset  = isTTY ? "\u{001B}[0m"    : ""
    private static let green  = isTTY ? "\u{001B}[0;32m" : ""
    private static let yellow = isTTY ? "\u{001B}[1;33m" : ""
    private static let red    = isTTY ? "\u{001B}[0;31m" : ""
    private static let cyan   = isTTY ? "\u{001B}[0;36m" : ""
    private static let dim    = isTTY ? "\u{001B}[0;37m" : ""

    // MARK: - Public
    static func info(_ msg: String)    { print("\(cyan)\(prefix)\(msg)\(reset)") }
    static func success(_ msg: String) { print("\n\(green)\(prefix)\(msg)\(reset)") }
    static func warn(_ msg: String)    { print("\n\(yellow)\(prefix)warning: \(msg)\(reset)") }
    static func error(_ msg: String)   { print("\n\(red)\(prefix)error: \(msg)\(reset)") }

    /// Prints only when BTTLog.verboseEnabled is true.
    static func verbose(_ msg: String) {
        guard verboseEnabled else { return }
        print("\(dim)(verbose) \(prefix)\(msg)\(reset)")
    }

    /// Prints a prompt with no prefix and no color, then leaves the cursor on
    /// the same line (no trailing newline) so the user's input appears inline.
    /// Use for interactive prompts: "Enter the number: ", "Instrument all? (y/n): "
    static func prompt(_ msg: String) {
        print(msg, terminator: "")
    }

    /// Prints a single numbered checklist line with no prefix and no leading newline.
    /// `ok == true` → green ✓, `ok == false` → red ✗.
    static func checklist(_ msg: String, ok: Bool) {
        let color = ok ? green : red
        print("\(color)\(msg)\(reset)")
    }
}
#endif
