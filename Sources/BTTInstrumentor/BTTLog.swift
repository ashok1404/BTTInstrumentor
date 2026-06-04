//
//  BTTLog.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

import Foundation
 
enum BTTLog {
    private static let reset  = "\u{001B}[0m"
    private static let bold   = "\u{001B}[1m"
    private static let green  = "\u{001B}[0;32m"
    private static let yellow = "\u{001B}[1;33m"
    private static let red    = "\u{001B}[0;31m"
    private static let blue   = "\u{001B}[0;34m"
    private static let cyan   = "\u{001B}[0;36m"
 
    static func info(_ msg: String)    { print("\(cyan)\(msg)\(reset)") }
    static func success(_ msg: String) { print("\(green)\(msg)\(reset)") }
    static func warn(_ msg: String)    { print("\(yellow)warning: \(msg)\(reset)") }
    static func error(_ msg: String)   { print("\(red)error: \(msg)\(reset)") }
}
