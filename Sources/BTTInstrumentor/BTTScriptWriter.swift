//
//  BTTScriptWriter.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 09/06/26.
//
//  Writes `btt_instrument.sh` and copies the BTTInstrumentor binary into the `.btt` folder.
//  The shell script is called by the Xcode scheme pre-action on every build
//  and is responsible for finding and running the BTTInstrumentor binary.
//

#if os(macOS)
import Foundation

final class BTTScriptWriter {
    private let projectDir: String
    private let fm = FileManager.default
    private var bttDir: String { (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName)}

    // MARK: - Init
    init(projectDir: String) {
        self.projectDir = projectDir
    }

    // MARK: - Public
    /// Writes `btt_instrument.sh` into the `.btt` folder with executable permissions.
    func writeInstrumentScript() {
        let scriptPath = (bttDir as NSString).appendingPathComponent(BTTConstants.scriptFileName)
        let content = """
        #!/bin/bash
        export PATH="$PATH:/usr/local/bin"
        export PATH="$PATH:/opt/homebrew/bin"

        if [[ -x "$SRCROOT/\(BTTConstants.bttFolderName)/\(BTTConstants.binaryName)" ]]; then
            "$SRCROOT/\(BTTConstants.bttFolderName)/\(BTTConstants.binaryName)" install "$SRCROOT"
        elif [[ -x "$(command -v \(BTTConstants.binaryName))" ]]; then
            "$(command -v \(BTTConstants.binaryName))" install "$SRCROOT"
        else
            exit 0
        fi
        """
        try? content.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
    }

    /// Copies the running BTTInstrumentor binary into the `.btt` folder.
    func copyBinary() {
        let dest = (bttDir as NSString).appendingPathComponent(BTTConstants.binaryName)
        let src  = resolveSourceBinaryPath()

        do {
            if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
            try fm.copyItem(atPath: src, toPath: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest)
        } catch {
            BTTLog.error("Binary copy failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private
    private func resolveSourceBinaryPath() -> String {
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/"), fm.fileExists(atPath: arg0) { return arg0 }

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
        return found.isEmpty ? arg0 : found
    }
}

#endif
