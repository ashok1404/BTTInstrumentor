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
    var succeeded: Bool {
        switch self {
        case .unchanged, .written: return true
        case .failed:return false
        }
    }
    
    var wasWritten: Bool {
        if case .written = self { return true }
        return false
    }
}

final class BTTScriptWriter {
    private let projectDir: String
    private let fm = FileManager.default
    private var bttDir: String { (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName) }

    init(projectDir: String) {
        self.projectDir = projectDir
    }

    // MARK: - Public

    /// Writes `btt_instrument.sh` into the `.btt` folder with executable permissions.
    /// The script calls `instrument` (the internal command) so Xcode pre-action builds
    /// never trigger the interactive `install` flow.
    @discardableResult
    func writeInstrumentScript() -> BTTWriteResult {
        let scriptPath  = (bttDir as NSString).appendingPathComponent(BTTConstants.scriptFileName)
        let verboseFlag = BTTLog.verboseEnabled ? " --verbose" : ""

        let content = """
        #!/bin/bash
        export PATH="$PATH:/usr/local/bin"
        export PATH="$PATH:/opt/homebrew/bin"
        if [[ -x "$SRCROOT/\(BTTConstants.bttFolderName)/\(BTTConstants.binaryName)" ]]; then
            "$SRCROOT/\(BTTConstants.bttFolderName)/\(BTTConstants.binaryName)" instrument "$SRCROOT"\(verboseFlag)
        elif [[ -x "$(command -v \(BTTConstants.binaryName))" ]]; then
            "$(command -v \(BTTConstants.binaryName))" instrument "$SRCROOT"\(verboseFlag)
        else
            exit 0
        fi
        """

        let existing = try? String(contentsOfFile: scriptPath, encoding: .utf8)
        if existing == content {
            return .unchanged
        }

        do {
            try content.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
            return .written
        } catch {
            return .failed(reason: "Failed to write \(BTTConstants.scriptFileName) at \(scriptPath): \(error.localizedDescription)")
        }
    }

    /// Copies the running BTTInstrumentor binary into the `.btt` folder.
    @discardableResult
    func copyBinary() -> BTTWriteResult {
        let dest = (bttDir as NSString).appendingPathComponent(BTTConstants.binaryName)
        let src  = resolveSourceBinaryPath()

        guard fm.fileExists(atPath: src) else {
            return .failed(reason: "Could not locate running BTTInstrumentor binary (tried: \(src))")
        }

        do {
            if fm.fileExists(atPath: dest) {
                try fm.removeItem(atPath: dest)
            }
            try fm.copyItem(atPath: src, toPath: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
            return .written
        } catch {
            return .failed(reason: "Binary copy failed (\(src) → \(dest)): \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func resolveSourceBinaryPath() -> String {
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/"), fm.fileExists(atPath: arg0) {
            return arg0
        }
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
            return arg0
        }
        return found
    }
}

#endif
