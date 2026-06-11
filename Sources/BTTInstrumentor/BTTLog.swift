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
    static func success(_ msg: String) { print("\(green)\(prefix)\(msg)\(reset)") }
    static func warn(_ msg: String)    { print("\(yellow)\(prefix)warning: \(msg)\(reset)") }
    static func error(_ msg: String)   { print("\(red)\(prefix)error: \(msg)\(reset)") }
    
    /// Prints only when BTTLog.verboseEnabled is true.
    static func verbose(_ msg: String) {
        guard verboseEnabled else { return }
        print("\(dim)[verbose] \(prefix)\(msg)\(reset)")
    }
}
#endif
