//
//  BTTScriptWriter.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//
//  Writes btt_instrument.sh into the .btt folder.
//  This script is called by the Xcode scheme pre-action on every build
//  and is responsible for finding and running the BTTInstrumentor binary.
//

#if os(macOS)
import Foundation

func writeBTTInstrumentScript(to projectDir: String) {
    let bttDir     = (projectDir as NSString).appendingPathComponent(".btt")
    let scriptPath = (bttDir as NSString).appendingPathComponent("btt_instrument.sh")
    let content = """
#!/bin/bash
export PATH="$PATH:/usr/local/bin"
export PATH="$PATH:/opt/homebrew/bin"

if [[ -x "$SRCROOT/.btt/BTTInstrumentor" ]]; then
    "$SRCROOT/.btt/BTTInstrumentor" install "$SRCROOT"
elif [[ -x "$(command -v BTTInstrumentor)" ]]; then
    "$(command -v BTTInstrumentor)" install "$SRCROOT"
else
    exit 0
fi
"""
    try? content.write(toFile: scriptPath, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
}

#endif
