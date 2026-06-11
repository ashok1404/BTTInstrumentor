//
//  BTTTargetStore.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

import Foundation

struct BTTTargetStore {
    private struct StoreData: Codable {
        var targets: [String]
        var bttSwiftUITrackerAdded: [String: Bool]
    }

    private let configPath: String

    init(projectDir: String) {
        let bttDir   = (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName)
        self.configPath = (bttDir as NSString).appendingPathComponent(BTTConstants.configFileName)
        BTTLog.verbose("BTTTargetStore.init — configPath: \(configPath)")

        if !FileManager.default.fileExists(atPath: bttDir) {
            BTTLog.verbose("  .btt directory missing — creating: \(bttDir)")
            do {
                try FileManager.default.createDirectory(
                    atPath: bttDir,
                    withIntermediateDirectories: true
                )
                BTTLog.verbose("  .btt directory created ✓")
            } catch {
                BTTLog.verbose("  ✗ Failed to create .btt directory: \(error.localizedDescription)")
            }
        } else {
            BTTLog.verbose("  .btt directory present ✓")
        }
    }

    // MARK: - Read

    internal var targets: [String] {
        let t = load()?.targets ?? []
        BTTLog.verbose("BTTTargetStore.targets → [\(t.joined(separator: ", "))]")
        return t
    }

    func isInstrumented(_ target: String) -> Bool {
        let result = targets.contains(target)
        BTTLog.verbose("BTTTargetStore.isInstrumented('\(target)') → \(result)")
        return result
    }

    func didAddBTTSwiftUITracker(for target: String) -> Bool {
        let result = load()?.bttSwiftUITrackerAdded[target] ?? false
        BTTLog.verbose("BTTTargetStore.didAddBTTSwiftUITracker('\(target)') → \(result)")
        return result
    }

    // MARK: - Write
    func add(_ target: String, bttSwiftUITrackerAdded: Bool = false) {
        BTTLog.verbose("BTTTargetStore.add('\(target)') bttSwiftUITrackerAdded=\(bttSwiftUITrackerAdded)")
        var data = load() ?? StoreData(targets: [], bttSwiftUITrackerAdded: [:])
        if !data.targets.contains(target) {
            data.targets.append(target)
            BTTLog.verbose("  Target '\(target)' appended — targets now: [\(data.targets.joined(separator: ", "))]")
        } else {
            BTTLog.verbose("  Target '\(target)' already in store — updating bttSwiftUITrackerAdded only.")
        }
        data.bttSwiftUITrackerAdded[target] = bttSwiftUITrackerAdded
        save(data)
    }

    func remove(_ target: String) {
        BTTLog.verbose("BTTTargetStore.remove('\(target)')")
        guard var data = load() else {
            BTTLog.verbose("  Store empty or unreadable — nothing to remove.")
            return
        }
        let before = data.targets
        data.targets = data.targets.filter { $0 != target }
        data.bttSwiftUITrackerAdded.removeValue(forKey: target)
        BTTLog.verbose("  Targets before: [\(before.joined(separator: ", "))] → after: [\(data.targets.joined(separator: ", "))]")
        save(data)
    }

    // MARK: - Private
    private func load() -> StoreData? {
        guard FileManager.default.fileExists(atPath: configPath) else {
            BTTLog.verbose("  load() — config file not found: \(configPath)")
            return nil
        }
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else {
            BTTLog.verbose("  load() — could not read data from: \(configPath)")
            BTTLog.warn("\(BTTConstants.configFileName) unreadable — starting fresh")
            return nil
        }
        guard let data = try? JSONDecoder().decode(StoreData.self, from: raw) else {
            BTTLog.verbose("  load() — JSON decode failed for: \(configPath) — deleting corrupted file")
            BTTLog.warn("\(BTTConstants.configFileName) corrupted — starting fresh")
            do {
                try FileManager.default.removeItem(atPath: configPath)
                BTTLog.verbose("  Corrupted config removed.")
            } catch {
                BTTLog.verbose("  ✗ Failed to remove corrupted config: \(error.localizedDescription)")
            }
            return nil
        }
        BTTLog.verbose("  load() → targets=[\(data.targets.joined(separator: ", "))] trackerAdded=\(data.bttSwiftUITrackerAdded)")
        return data
    }

    private func save(_ data: StoreData) {
        guard let raw = try? JSONEncoder().encode(data) else {
            BTTLog.verbose("  save() — JSON encode failed")
            return
        }
        BTTLog.verbose("  save() — writing \(raw.count) bytes to: \(configPath)")
        do {
            // Temporarily make writable, write, then lock read-only
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: configPath)
            try raw.write(to: URL(fileURLWithPath: configPath))
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: configPath)
            BTTLog.verbose("  save() ✓ (permissions set to 0o444)")
        } catch {
            BTTLog.verbose("  save() ✗ failed: \(error.localizedDescription)")
            // Still attempt write even if chmod failed (first-time file creation)
            try? raw.write(to: URL(fileURLWithPath: configPath))
            try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: configPath)
        }
    }
}
