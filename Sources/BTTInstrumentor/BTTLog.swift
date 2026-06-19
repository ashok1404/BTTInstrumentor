//
//  BTTLog.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

#if os(macOS)
import Foundation

enum BTTLog {
    // MARK: - Flags
    static var verboseEnabled:  Bool = false
    static var nonInteractive:  Bool = false   // true when invoked from btt_instrument.sh (Xcode build)
    static var prefix: String = "BTTInstrumentor: "

    // MARK: - Private
    private static let isTTY  = isatty(STDOUT_FILENO) != 0
    private static let reset  = isTTY ? "\u{001B}[0m"    : ""
    private static let green  = isTTY ? "\u{001B}[0;32m" : ""
    private static let yellow = isTTY ? "\u{001B}[1;33m" : ""
    private static let red    = isTTY ? "\u{001B}[0;31m" : ""
    private static let cyan   = isTTY ? "\u{001B}[0;36m" : ""
    private static let dim    = isTTY ? "\u{001B}[0;37m" : ""

    static var isXcode: Bool { ProcessInfo.processInfo.environment["XCODE_VERSION_ACTUAL"] != nil }

    // MARK: - Public
    static func info(_ msg: String) {
        if isXcode { fputs("note: \(prefix)\(msg)\n", stderr) }
        else { print("\(cyan)\(prefix)\(msg)\(reset)") }
    }
    static func success(_ msg: String) {
        if isXcode { fputs("note: \(prefix)\(msg)\n", stderr) }
        else { print("\n\(green)\(prefix)\(msg)\(reset)") }
    }
    static func warn(_ msg: String) {
        if isXcode { fputs("warning: \(prefix)\(msg)\n", stderr) }
        else { print("\n\(yellow)\(prefix)warning: \(msg)\(reset)") }
    }
    static func error(_ msg: String) {
        if isXcode { fputs("error: \(prefix)\(msg)\n", stderr) }
        else { print("\n\(red)\(prefix)error: \(msg)\(reset)") }
    }

    /// Prints only when BTTLog.verboseEnabled is true.
    static func verbose(_ msg: String) {
        guard verboseEnabled else { return }
        if isXcode { fputs("[verbose] \(prefix)\(msg)\n", stderr) }
        else { print("\(dim)(verbose) \(prefix)\(msg)\(reset)") }
    }

    /// Prints a prompt with no prefix and no color, then leaves the cursor on
    static func prompt(_ msg: String) {
        print(msg, terminator: "")
    }

    /// Prints a single numbered checklist line with no prefix and no leading newline.
    /// `ok == true` → green ✓, `ok == false` → red ✗.
    static func checklist(_ msg: String, ok: Bool) {
        if isXcode {
            if ok { fputs("note: \(msg)\n", stderr) }
            else  { fputs("warning: \(msg)\n", stderr) }
        } else {
            let color = ok ? green : red
            print("\(color)\(msg)\(reset)")
        }
    }
}
#endif
