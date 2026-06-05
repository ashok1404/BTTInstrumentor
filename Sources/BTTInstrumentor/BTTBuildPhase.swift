//
//  BTTBuildPhase.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

#if os(macOS)
import Foundation

// MARK: - Ruby script — adds phase to specific target only
private let rubyScript = """
require 'xcodeproj'
proj_path    = ARGV[0]
phase_name   = ARGV[1]
phase_script = ARGV[2]
target_name  = ARGV[3]
project  = Xcodeproj::Project.open(proj_path)
modified = false
project.targets.each do |target|
  next unless target.is_a?(Xcodeproj::Project::Object::PBXNativeTarget)
  next unless target.product_type == "com.apple.product-type.application"
  next unless target_name.empty? || target.name == target_name
  existing = target.build_phases.find { |p| p.display_name == phase_name }
  if existing
    if existing.shell_script != phase_script
      existing.shell_script = phase_script
      puts "Updated build phase in #{target.name}"
      modified = true
    else
      puts "Build phase already up to date in #{target.name}"
    end
    next
  end
  phase = target.new_shell_script_build_phase(phase_name)
  phase.shell_script         = phase_script
  phase.show_env_vars_in_log = "0"
  compile_idx = target.build_phases.index { |p|
    p.is_a?(Xcodeproj::Project::Object::PBXSourcesBuildPhase)
  }
  target.build_phases.move(phase, compile_idx || 0)
  puts "Added build phase to #{target.name}"
  modified = true
end
project.save if modified
"""

// MARK: - Build script content
// scheme = nil  → all schemes selected → inject target files + ALL local package dependencies
// scheme = "XYZ" → specific scheme → inject only that scheme/target files

private func buildScript(scheme: String?) -> String {
    // If nil — no --scheme flag — cmdInject will inject target + all its package deps
    let schemeArg = scheme.map { "--scheme \"\($0)\"" } ?? ""
    return """
export PATH="$PATH:/usr/local/bin"
export PATH="$PATH:/opt/homebrew/bin"

if [[ -x "$SRCROOT/.btt/BTTInstrumentor" ]]
then
    instrumentorExecutable="$SRCROOT/.btt/BTTInstrumentor"
    echo "using local BlueTriangle instrumentor in: $instrumentorExecutable"
elif [[ -x "$(command -v BTTInstrumentor)" ]]
then
    instrumentorExecutable="$(command -v BTTInstrumentor)"
    echo "using system BlueTriangle instrumentor in: $instrumentorExecutable"
else
    echo "error: No BTTInstrumentor found. Install via: brew install bluetriangle/tools/bttinstrumentor"
    exit 1
fi

"$instrumentorExecutable" install "$SRCROOT" --target "$TARGET_NAME" \(schemeArg)
exit $?
"""
}

// MARK: - Add build phase to specific target

func addBuildPhase(xcodeprojPath: String, targetName: String, scheme: String?) {
    ensureXcodeprojGem()

    let script = buildScript(scheme: scheme)
    let tmp = NSTemporaryDirectory() + "btt_phase.rb"
    try? rubyScript.write(toFile: tmp, atomically: true, encoding: .utf8)

    let task = Process()
    task.launchPath = "/usr/bin/ruby"
    task.arguments = [tmp, xcodeprojPath, "BTT Instrumentation", script, targetName]
    try? task.run()
    task.waitUntilExit()
    try? FileManager.default.removeItem(atPath: tmp)

    BTTLog.success("Build phase added to target: \(targetName)")
}

// MARK: - Gem helper
private func ensureXcodeprojGem() {
    let check = Process()
    check.launchPath = "/usr/bin/gem"
    check.arguments = ["list", "xcodeproj", "-i"]
    let pipe = Pipe()
    check.standardOutput = pipe
    check.standardError = Pipe()
    try? check.run()
    check.waitUntilExit()

    let installed = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    guard !installed else { return }

    BTTLog.info("Installing xcodeproj gem...")
    let install = Process()
    install.launchPath = "/usr/bin/gem"
    install.arguments = ["install", "xcodeproj", "--silent"]
    try? install.run()
    install.waitUntilExit()
}

#endif
