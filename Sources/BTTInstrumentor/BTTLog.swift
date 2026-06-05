//
//  BTTLog.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

#if os(macOS)
import Foundation

enum BTTLog {
    private static let isTTY  = isatty(STDOUT_FILENO) != 0
    private static let reset  = isTTY ? "\u{001B}[0m"    : ""
    private static let green  = isTTY ? "\u{001B}[0;32m" : ""
    private static let yellow = isTTY ? "\u{001B}[1;33m" : ""
    private static let red    = isTTY ? "\u{001B}[0;31m" : ""
    private static let cyan   = isTTY ? "\u{001B}[0;36m" : ""

    static func info(_ msg: String)    { print("\(cyan)\(msg)\(reset)") }
    static func success(_ msg: String) { print("\(green)\(msg)\(reset)") }
    static func warn(_ msg: String)    { print("\(yellow)warning: \(msg)\(reset)") }
    static func error(_ msg: String)   { print("\(red)error: \(msg)\(reset)") }
    static func plain(_ msg: String)   { print(msg) }
    static func prompt(_ msg: String)  { print(msg, terminator: "") }
}
#endif
