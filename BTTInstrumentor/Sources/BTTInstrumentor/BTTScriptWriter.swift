//
//  BTTScriptWriter.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 09/06/26.
//

#if os(macOS)
import Foundation

enum BTTWriteResult {
    case unchanged
    case written
    case failed(reason: String)
}

final class BTTScriptWriter {
    private let projectDir: String
    private let fm = FileManager.default
    private var bttDir: String { (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName) }

    init(projectDir: String) {
        self.projectDir = projectDir
    }

    // MARK: - Public

    @discardableResult
    func writeInstrumentScript() -> BTTWriteResult {
        let scriptPath  = (bttDir as NSString).appendingPathComponent(BTTConstants.scriptFileName)
        let verboseFlag = BTTLog.verboseEnabled ? " --verbose" : ""
        let flags       = "--non-interactive\(verboseFlag)"

        let content = """
        #!/bin/bash
        export PATH="$PATH:/usr/local/bin"
        export PATH="$PATH:/opt/homebrew/bin"
        if [[ -x "$SRCROOT/\(BTTConstants.bttFolderName)/\(BTTConstants.binaryName)" ]]; then
            "$SRCROOT/\(BTTConstants.bttFolderName)/\(BTTConstants.binaryName)" instrument "$SRCROOT" \(flags)
        elif [[ -x "$(command -v \(BTTConstants.binaryName))" ]]; then
            "$(command -v \(BTTConstants.binaryName))" instrument "$SRCROOT" \(flags)
        else
            exit 0
        fi
        """

        let existing = try? String(contentsOfFile: scriptPath, encoding: .utf8)
        if existing == content {
            BTTLog.verbose("Script unchanged — skipping rewrite.")
            return .unchanged
        }

        do {
            try content.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            BTTLog.verbose("Script \(existing == nil ? "created" : "updated"): \(scriptPath)")
            return .written
        } catch {
            return .failed(reason: "Failed to write \(BTTConstants.scriptFileName) at \(scriptPath): \(error.localizedDescription)")
        }
    }

    @discardableResult
    func promptUpdateIfAvailable() -> Bool {
        guard !BTTLog.nonInteractive else { return false }

        let dest = (bttDir as NSString).appendingPathComponent(BTTConstants.binaryName)

        guard fm.fileExists(atPath: dest) else { return false }
        guard let pathBinary = resolvePathBinary() else { return false }

        let destVersion = BTTVersionChecker.binaryVersion(at: dest)
        let pathVersion = BTTVersionChecker.binaryVersion(at: pathBinary)

        BTTLog.verbose("  .btt version: \(destVersion ?? "unknown")")
        BTTLog.verbose("  PATH version: \(pathVersion ?? "unknown") (\(pathBinary))")

        // Compare binary contents — version strings unreliable in subprocess
        let destData = fm.contents(atPath: dest)
        let pathData = fm.contents(atPath: pathBinary)
        guard let dd = destData, let pd = pathData, dd != pd else { return false }

        let dv = destVersion ?? "unknown"
        let pv = pathVersion ?? "unknown"

        BTTLog.prompt("\nNew version \(pv) is available (you are on \(dv)).\n")
        BTTLog.prompt("Do you want to update \(pv)? (y/n): ")

        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        guard answer == "y" || answer == "yes" else {
            BTTLog.info("Skipping update — continuing with \(dv).")
            return false
        }

        _ = performCopy(src: pathBinary, dest: dest)
        BTTLog.success("✓ Updated .btt/\(BTTConstants.binaryName) to \(pv).")
        return true
    }

    @discardableResult
    func copyBinary() -> BTTWriteResult {
        let dest = (bttDir as NSString).appendingPathComponent(BTTConstants.binaryName)
        let src  = resolveSourceBinaryPath()

        guard fm.fileExists(atPath: src) else {
            return .failed(reason: "Could not locate running BTTInstrumentor binary (tried: \(src))")
        }

        let destURL = URL(fileURLWithPath: dest)
        let itemExists = (try? destURL.checkResourceIsReachable()) ?? false
        if itemExists {
            BTTLog.verbose("Binary already present — skipping copy.")
            return .unchanged
        }

        return performCopy(src: src, dest: dest)
    }

    private func resolvePathBinary() -> String? {
        let task = Process()
        task.launchPath     = "/usr/bin/which"
        task.arguments      = [BTTConstants.binaryName]
        let pipe            = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        try? task.run()
        task.waitUntilExit()

        let found = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !found.isEmpty, !found.hasPrefix(bttDir) else { return nil }
        return found
    }

    private func performCopy(src: String, dest: String) -> BTTWriteResult {
        do {
            try? fm.removeItem(atPath: dest)
            try fm.copyItem(atPath: src, toPath: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
            BTTLog.verbose("Binary copied: \(src) → \(dest)")
            return .written
        } catch {
            return .failed(reason: "Binary copy failed (\(src) → \(dest)): \(error.localizedDescription)")
        }
    }

    private func resolveSourceBinaryPath() -> String {
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/") {
            let resolved = URL(fileURLWithPath: arg0).resolvingSymlinksInPath().path
            if fm.fileExists(atPath: resolved) { return resolved }
        }

        let task = Process()
        task.launchPath     = "/usr/bin/which"
        task.arguments      = [BTTConstants.binaryName]
        let pipe            = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        try? task.run()
        task.waitUntilExit()

        let found = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if found.isEmpty { return arg0 }
        let resolved = URL(fileURLWithPath: found).resolvingSymlinksInPath().path
        return fm.fileExists(atPath: resolved) ? resolved : found
    }
}

#endif
