//
//  BTTScriptWriter.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 09/06/26.
//

#if os(macOS)
import Foundation

final class BTTScriptWriter {
    private let projectDir: String
    private let fm = FileManager.default
    private var bttDir: String { (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName) }

    init(projectDir: String) {
        self.projectDir = projectDir
    }

    // MARK: - Public

    /// Writes `btt_instrument.sh` into the `.btt` folder with executable permissions.
    /// If `--verbose` was passed at install time, it is baked directly into the script
    /// so every subsequent Xcode build also runs verbose — no marker file needed.
    func writeInstrumentScript() {
        let scriptPath  = (bttDir as NSString).appendingPathComponent(BTTConstants.scriptFileName)
        let verboseFlag = BTTLog.verboseEnabled ? " --verbose" : ""

        BTTLog.verbose("writeInstrumentScript — path: \(scriptPath)")
        BTTLog.verbose("  verboseFlag baked into script: '\(verboseFlag.isEmpty ? "(none)" : verboseFlag.trimmingCharacters(in: .whitespaces))'")

        let content = """
        #!/bin/bash
        export PATH="$PATH:/usr/local/bin"
        export PATH="$PATH:/opt/homebrew/bin"
        if [[ -x "$SRCROOT/\(BTTConstants.bttFolderName)/\(BTTConstants.binaryName)" ]]; then
            "$SRCROOT/\(BTTConstants.bttFolderName)/\(BTTConstants.binaryName)" install "$SRCROOT"\(verboseFlag)
        elif [[ -x "$(command -v \(BTTConstants.binaryName))" ]]; then
            "$(command -v \(BTTConstants.binaryName))" install "$SRCROOT"\(verboseFlag)
        else
            exit 0
        fi
        """

        // Only rewrite if content changed — re-install with/without --verbose updates the baked flag
        let existing = try? String(contentsOfFile: scriptPath, encoding: .utf8)
        if existing == content {
            BTTLog.verbose("  Script unchanged — skipping rewrite.")
            return
        }

        do {
            try content.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            let reason = existing == nil ? "created" : "updated (verbose flag \(BTTLog.verboseEnabled ? "added" : "removed"))"
            BTTLog.verbose("  Script \(reason): \(scriptPath)")
        } catch {
            BTTLog.verbose("  ✗ Script write failed: \(error.localizedDescription)")
        }
    }

    /// Copies the running BTTInstrumentor binary into the `.btt` folder.
    func copyBinary() {
        let dest = (bttDir as NSString).appendingPathComponent(BTTConstants.binaryName)
        let src  = resolveSourceBinaryPath()
        BTTLog.verbose("copyBinary — src: \(src) → dest: \(dest)")

        do {
            if fm.fileExists(atPath: dest) {
                BTTLog.verbose("  Existing binary found at dest — removing before copy.")
                try fm.removeItem(atPath: dest)
            }
            try fm.copyItem(atPath: src, toPath: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
            BTTLog.verbose("  ✓ Binary copied and made executable.")
        } catch {
            BTTLog.verbose("  ✗ Binary copy failed: \(error.localizedDescription)")
            BTTLog.error("Binary copy failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private
    private func resolveSourceBinaryPath() -> String {
        let arg0 = CommandLine.arguments[0]
        BTTLog.verbose("  resolveSourceBinaryPath — CommandLine.arguments[0]: \(arg0)")

        if arg0.hasPrefix("/"), fm.fileExists(atPath: arg0) {
            BTTLog.verbose("  Using absolute path from argv[0]: \(arg0)")
            return arg0
        }

        BTTLog.verbose("  argv[0] is not absolute or doesn't exist — falling back to 'which \(BTTConstants.binaryName)'")
        let task = Process()
        task.launchPath = "/usr/bin/which"
        task.arguments  = [BTTConstants.binaryName]
        let pipe        = Pipe()
        task.standardOutput = pipe
        task.standardError  = Pipe()
        try? task.run()
        task.waitUntilExit()

        let found = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if found.isEmpty {
            BTTLog.verbose("  'which' returned empty — falling back to argv[0]: \(arg0)")
            return arg0
        }

        BTTLog.verbose("  'which' resolved binary at: \(found)")
        return found
    }
}

#endif
