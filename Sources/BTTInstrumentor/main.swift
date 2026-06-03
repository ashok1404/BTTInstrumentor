// Sources/BTTInstrumentor/main.swift

import Foundation
import SwiftSyntax
import SwiftParser
import SwiftSyntaxBuilder
import PathKit
import XcodeProj

// MARK: - Colors

enum C {
    static let reset  = "\u{001B}[0m"
    static let bold   = "\u{001B}[1m"
    static let green  = "\u{001B}[0;32m"
    static let yellow = "\u{001B}[1;33m"
    static let red    = "\u{001B}[0;31m"
    static let blue   = "\u{001B}[0;34m"
    static let cyan   = "\u{001B}[0;36m"
}

func step(_ m: String) { print("\n\(C.bold)\(C.blue)▶ \(m)\(C.reset)") }
func ok(_ m: String)   { print("  \(C.green)✅ \(m)\(C.reset)") }
func warn(_ m: String) { print("  \(C.yellow)⚠️  \(m)\(C.reset)") }
func info(_ m: String) { print("  \(C.cyan)ℹ️  \(m)\(C.reset)") }
func fail(_ m: String) { print("  \(C.red)❌ \(m)\(C.reset)") }

// MARK: - Arguments

struct Args {
    var command: String = ""
    var projectPath: String? = nil
    var target: String? = nil
    var scheme: String? = nil
    var rootPath: String = FileManager.default.currentDirectoryPath
}

func parseArgs() -> Args {
    var result = Args()
    var remaining = Array(CommandLine.arguments.dropFirst())
    guard !remaining.isEmpty else { return result }
    result.command = remaining.removeFirst()
    var i = 0
    while i < remaining.count {
        let arg = remaining[i]
        switch arg {
        case "--target":
            if i + 1 < remaining.count { result.target = remaining[i + 1]; i += 1 }
        case "--scheme":
            if i + 1 < remaining.count { result.scheme = remaining[i + 1]; i += 1 }
        default:
            if !arg.hasPrefix("--") {
                if arg.hasSuffix(".xcodeproj") { result.projectPath = arg }
                else {
                    result.rootPath = arg.hasPrefix("~")
                        ? NSHomeDirectory() + arg.dropFirst()
                        : arg
                }
            }
        }
        i += 1
    }
    return result
}

// MARK: - XcodeProj helpers

let fm = FileManager.default

/// Run xcodebuild -list and return parsed output
func xcodebuildList(projPath: String) -> String {
    let task = Process()
    task.launchPath = "/usr/bin/xcodebuild"
    task.arguments = ["-list", "-project", projPath]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    try? task.run()
    task.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

/// Parse a section from xcodebuild -list output
func parseSection(_ section: String, from output: String) -> [String] {
    var results: [String] = []
    var seen = Set<String>()
    var inSection = false
    for line in output.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == "\(section):" { inSection = true; continue }
        if inSection {
            if trimmed.isEmpty { continue }
            if trimmed.hasSuffix(":") { break }
            if !seen.contains(trimmed) { seen.insert(trimmed); results.append(trimmed) }
        }
    }
    return results
}

/// Get all targets (including test targets) using xcodebuild -list
func getTargets(from projPath: String) -> [String] {
    return parseSection("Targets", from: xcodebuildList(projPath: projPath))
}

/// Get all schemes (deduplicated) using xcodebuild -list
func getAllSchemes(from projPath: String) -> [String] {
    return parseSection("Schemes", from: xcodebuildList(projPath: projPath)).sorted()
}

/// Get exact Swift source files for a target using XcodeProj
/// Uses the exact file list Xcode defines for that target — no filtering
func getSourceFiles(for targetName: String, in projPath: String) -> [String] {
    guard let xcodeproj = try? XcodeProj(path: Path(projPath)),
          let target = xcodeproj.pbxproj.nativeTargets.first(where: { $0.name == targetName }),
          let sourceFiles = try? target.sourceFiles() else {
        return []
    }

    let projDir = Path(projPath).parent()

    return sourceFiles.compactMap { file -> String? in
        guard let path = file.path, path.hasSuffix(".swift") else { return nil }

        // Use fullPath which resolves relative paths correctly
        let fullPath: Path
        if let fp = try? file.fullPath(sourceRoot: projDir) {
            fullPath = fp
        } else {
            // Fallback: manual resolution
            fullPath = projDir + Path(path)
        }

        let pathString = fullPath.string
        return fm.fileExists(atPath: pathString) ? pathString : nil
    }
}

/// Find all Swift files as fallback
func findAllSwiftFiles(in root: String) -> [String] {
    var files: [String] = []
    guard let e = fm.enumerator(at: URL(fileURLWithPath: root),
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]) else { return files }
    for case let url as URL in e {
        let path = url.path
        guard path.hasSuffix(".swift") else { continue }
        guard !path.contains("/Pods/") else { continue }
        guard !path.contains("/.build/") else { continue }
        guard !path.contains("/DerivedData/") else { continue }
        files.append(path)
    }
    return files
}

/// Find xcodeproj files
func findXcodeprojFiles(in root: String) -> [String] {
    var results: [String] = []
    guard let e = fm.enumerator(at: URL(fileURLWithPath: root),
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]) else { return results }
    for case let url as URL in e {
        let depth = url.pathComponents.count - URL(fileURLWithPath: root).pathComponents.count
        if depth > 4 { e.skipDescendants(); continue }
        if url.pathExtension == "xcodeproj" { results.append(url.path) }
    }
    return results
}


/// Interactive numbered selection with "all" option
func interactiveSelectWithAll(
    from options: [String],
    prompt: String,
    allLabel: String
) -> [String]? {

    print("\n  \(C.bold)\(prompt)\(C.reset)\n")

    for (i, opt) in options.enumerated() {
        print("  \(C.bold)[\(i + 1)]\(C.reset) \(opt)")
    }
    let allIdx = options.count + 1
    print("  \(C.bold)[\(allIdx)]\(C.reset) \(allLabel)")
    print("")
    print("  Enter number: ", terminator: "")

    if let input = readLine()?.trimmingCharacters(in: .whitespaces) {
        if let idx = Int(input) {
            if idx == allIdx { return options }
            if idx >= 1 && idx <= options.count {
                print("  \(C.cyan)Selected: \(options[idx - 1])\(C.reset)")
                return [options[idx - 1]]
            }
        }
    }
    print("  \(C.cyan)Selected: \(options[0])\(C.reset)")
    return [options[0]]
}

// MARK: - Resolve files

func resolveFiles(args: Args) -> [String] {
    let root = args.rootPath
    var xcodeproj: String

    // ── Find xcodeproj ──────────────────────────────────────
    let found = findXcodeprojFiles(in: root)

    if let p = args.projectPath, fm.fileExists(atPath: p) {
        xcodeproj = p
        ok("Project: \((xcodeproj as NSString).lastPathComponent)")
    } else if found.isEmpty {
        info("No .xcodeproj found — scanning all Swift files")
        return findAllSwiftFiles(in: root)
    } else if found.count == 1 {
        xcodeproj = found[0]
        ok("Project: \((xcodeproj as NSString).lastPathComponent)")
    } else {
        guard let sel = interactiveSelectWithAll(
            from: found.map { ($0 as NSString).lastPathComponent },
            prompt: "Multiple projects found — select one:",
            allLabel: "all projects"
        )?.first else { fail("No project selected"); exit(1) }
        xcodeproj = found.first { ($0 as NSString).lastPathComponent == sel } ?? found[0]
    }

    // ── Step 1: Select target ───────────────────────────────
    let targets = getTargets(from: xcodeproj)
    var selectedTargets: [String] = []

    if let t = args.target {
        selectedTargets = [t]
        ok("Target: \(t)")
    } else if targets.isEmpty {
        info("No targets found — scanning all Swift files")
        return findAllSwiftFiles(in: (xcodeproj as NSString).deletingLastPathComponent)
    } else {
        print("")
        print("  \(C.bold)Fetching targets for \((xcodeproj as NSString).lastPathComponent)...\(C.reset)")

        guard let sel = interactiveSelectWithAll(
            from: targets,
            prompt: "Which target do you want to instrument?",
            allLabel: "all targets"
        ) else { fail("No target selected"); exit(1) }

        selectedTargets = sel
        if sel.count > 1 {
            ok("Instrumenting all targets")
        }
    }

    // ── Step 2: Select scheme ───────────────────────────────
    var selectedScheme: String? = args.scheme
    let allSchemes = getAllSchemes(from: xcodeproj)

    if selectedScheme == nil && !allSchemes.isEmpty {
        print("")
        print("  \(C.bold)Fetching all available schemes for \((xcodeproj as NSString).lastPathComponent)...\(C.reset)")

        guard let sel = interactiveSelectWithAll(
            from: allSchemes,
            prompt: "Which scheme do you want to instrument?",
            allLabel: "all schemes"
        ) else { fail("No scheme selected"); exit(1) }

        if sel.count == 1 {
            selectedScheme = sel[0]
            ok("Scheme: \(sel[0])")
        } else {
            ok("Instrumenting all schemes")
        }
    }

    // ── Collect files for selected targets + scheme ─────────
    var allFiles: [String] = []
    var seen = Set<String>()

    func addFiles(_ files: [String]) {
        for f in files where !seen.contains(f) {
            seen.insert(f); allFiles.append(f)
        }
    }

    if let scheme = selectedScheme {
        let isTarget = targets.contains(scheme)

        if isTarget {
            // xcodeproj target — get exact file list
            addFiles(getSourceFiles(for: scheme, in: xcodeproj))
        } else {
            // SPM package scheme — resolve local path
            if let pkgPath = resolvePackagePath(for: scheme, projPath: xcodeproj) {
                ok("Package path: \(pkgPath)")
                addFiles(findAllSwiftFiles(in: pkgPath))
            } else {
                // Remote package — cannot inject
                fail("'\(scheme)' is a remote package — cannot inject source files.")
                info("Only local packages and xcodeproj targets can be instrumented.")
                exit(1)
            }
        }
    } else {
        // All schemes — inject targets + all local SPM packages
        for target in selectedTargets {
            addFiles(getSourceFiles(for: target, in: xcodeproj))
        }
        let packages = resolveAllLocalPackages(projPath: xcodeproj)
        for (_, path) in packages {
            addFiles(findAllSwiftFiles(in: path))
        }
    }

    if allFiles.isEmpty {
        fail("No Swift files found for the selected target/scheme.")
        info("Make sure the target has source files and packages are resolved.")
        exit(1)
    }

    ok("Files to process: \(allFiles.count)")
    return allFiles
}

// MARK: - Package resolution

/// Resolve local SPM package path for a given scheme name
/// Uses xcodebuild -list output which includes resolved source packages
func resolvePackagePath(for schemeName: String, projPath: String) -> String? {
    let packages = resolveAllLocalPackages(projPath: projPath)
    return packages[schemeName]
}

/// Returns dict of [schemeName: localPath] for all local SPM packages
func resolveAllLocalPackages(projPath: String) -> [String: String] {
    let task = Process()
    task.launchPath = "/usr/bin/xcodebuild"
    task.arguments = ["-list", "-project", projPath]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    try? task.run()
    task.waitUntilExit()

    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    var packages: [String: String] = [:]

    // Parse lines like:
    //   FeatureLogin: /Users/.../ios/FeatureLogin
    //   Pulse: https://... (skip remote)
    for line in output.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.components(separatedBy: ": ")
        guard parts.count == 2 else { continue }
        let name = parts[0].trimmingCharacters(in: .whitespaces)
        let path = parts[1].trimmingCharacters(in: .whitespaces)

        // Only local paths (not https://)
        guard path.hasPrefix("/") else { continue }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }

        packages[name] = path
    }

    return packages
}

// MARK: - SwiftSyntax Rewriter

/// Injects @BTTTrack directly above every SwiftUI View struct using AST rewriting
final class BTTInjectRewriter: SyntaxRewriter {

    var injectedCount = 0

    override func visit(_ node: StructDeclSyntax) -> DeclSyntax {

        // Must conform to View
        guard conformsToView(node) else { return DeclSyntax(node) }

        // Must have var body
        guard hasBodyProperty(node) else { return DeclSyntax(node) }

        // Skip if @BTTTrack already present
        guard !hasAttribute("BTTTrack", in: node) else { return DeclSyntax(node) }

        // Skip if // btt:ignore in leading trivia
        guard !hasBTTIgnore(node) else { return DeclSyntax(node) }

        // Build @BTTTrack attribute with newline after it
        // so it appears on its own line directly above struct
        let attrSyntax = AttributeSyntax(
            atSign: .atSignToken(),
            attributeName: IdentifierTypeSyntax(
                name: .identifier("BTTTrack")
            ),
            trailingTrivia: .newline
        )

        // Preserve original leading trivia (indentation/comments) on the attribute
        // and put the struct's keyword on the next line with same indent
        let leadingTrivia = node.leadingTrivia

        // Strip leading trivia from struct — move it to the attribute
        let strippedNode = node.with(\.leadingTrivia, .spaces(0))

        // Build new attribute with original leading trivia
        let attrWithTrivia = attrSyntax.with(\.leadingTrivia, leadingTrivia)

        let newAttr = AttributeListSyntax([.attribute(attrWithTrivia)])
        var modified = strippedNode

        if node.attributes.isEmpty {
            modified = strippedNode.with(\.attributes, newAttr)
        } else {
            var combined = newAttr
            combined.append(contentsOf: strippedNode.attributes)
            modified = strippedNode.with(\.attributes, combined)
        }

        injectedCount += 1
        return DeclSyntax(modified)
    }

    private func conformsToView(_ node: StructDeclSyntax) -> Bool {
        node.inheritanceClause?.inheritedTypes.contains {
            $0.type.trimmedDescription == "View"
        } ?? false
    }

    private func hasBodyProperty(_ node: StructDeclSyntax) -> Bool {
        node.memberBlock.members.contains { member in
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { return false }
            return varDecl.bindings.contains { binding in
                binding.pattern.trimmedDescription == "body"
            }
        }
    }

    private func hasAttribute(_ name: String, in node: StructDeclSyntax) -> Bool {
        node.attributes.contains { attr in
            guard case .attribute(let a) = attr else { return false }
            return a.attributeName.trimmedDescription == name
        }
    }

    private func hasBTTIgnore(_ node: StructDeclSyntax) -> Bool {
        node.leadingTrivia.description.contains("btt:ignore")
    }
}


// MARK: - Inject / Uninstall single file

func injectFile(_ path: String) -> Bool {
    guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { return false }

    // Quick check — skip non-SwiftUI files
    guard source.contains("import SwiftUI") else { return false }
    guard !source.contains("@BTTTrack") || !source.contains("import BlueTriangle") else {
        // Already fully injected
        if source.contains("@BTTTrack") && source.contains("import BlueTriangle") { return false }
        return false
    }

    // Parse source into AST
    var tree = Parser.parse(source: source)

    // Step 1 — inject @BTTTrack on View structs
    let rewriter = BTTInjectRewriter()
    tree = rewriter.visit(tree).as(SourceFileSyntax.self) ?? tree

    guard rewriter.injectedCount > 0 else { return false }

    // Step 2 — add import BlueTriangle if missing
    var result = tree.description
    if !result.contains("import BlueTriangle"),
       let range = result.range(of: "import SwiftUI") {
        result.insert(contentsOf: "\nimport BlueTriangle", at: range.upperBound)
    }

    // Write back
    guard result != source else { return false }
    try? result.write(toFile: path, atomically: true, encoding: .utf8)
    return true
}

// MARK: - Help

func printHelp() {
    print("""

\(C.bold)BTTInstrumentor — BlueTriangle SwiftUI Screen Tracking\(C.reset)

\(C.bold)USAGE\(C.reset)
  BTTInstrumentor install [project.xcodeproj] [--target <TARGET>] [--scheme <SCHEME>]

\(C.bold)OPTIONS\(C.reset)
  --target     Scope to a specific Xcode target
  --scheme     Identify target via scheme name

\(C.bold)EXAMPLES\(C.reset)
  BTTInstrumentor install
  BTTInstrumentor install MyApp.xcodeproj
  BTTInstrumentor install MyApp.xcodeproj --target MyApp
  BTTInstrumentor install MyApp.xcodeproj --target MyApp --scheme MyApp
""")
}

func banner(_ sub: String) {
    print("")
    print("\(C.bold)╔══════════════════════════════════════════╗\(C.reset)")
    print("\(C.bold)║  BlueTriangle · BTTInstrumentor          ║\(C.reset)")
    print("\(C.bold)║  \(sub.padding(toLength: 40, withPad: " ", startingAt: 0))║\(C.reset)")
    print("\(C.bold)╚══════════════════════════════════════════╝\(C.reset)")
    print("")
}

// MARK: - Commands

func cmdInstall(args: Args) {
    banner("install")
    info("Project root: \(args.rootPath)")

    step("Resolving project and target...")
    let files = resolveFiles(args: args)

    if files.isEmpty { warn("No Swift files found."); return }

    step("Injecting @BTTTrack into SwiftUI views...")
    print("")

    var injected = 0
    var skipped  = 0

    for file in files {
        if injectFile(file) {
            injected += 1
            print("  \(C.green)✅ \(URL(fileURLWithPath: file).lastPathComponent)\(C.reset)")
        } else {
            skipped += 1
        }
    }

    print("")
    print("\(C.bold)\(C.green)╔══════════════════════════════════════════╗\(C.reset)")
    print("\(C.bold)\(C.green)║         Injection Complete 🎉            ║\(C.reset)")
    print("\(C.bold)\(C.green)╚══════════════════════════════════════════╝\(C.reset)")
    print("")
    print("  Total    : \(files.count)")
    print("  Injected : \(C.green)\(injected)\(C.reset)")
    print("  Skipped  : \(skipped) (no SwiftUI views or already annotated)")
    print("")
}

// MARK: - Entry

func run() {
    let args = parseArgs()
    guard !args.command.isEmpty else { printHelp(); exit(0) }
    switch args.command {
    case "install":              cmdInstall(args: args)
    case "help", "--help", "-h": printHelp()
    default: fail("Unknown command: \(args.command)"); printHelp(); exit(1)
    }
}

run()
