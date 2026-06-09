//
//  BTTTargetStore.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

import Foundation

// Stores [targetName] — list of instrumented targets
// and [targetName: Bool] — whether BTTSwiftUITracker was added by BTTInstrumentor
struct BTTTargetStore {

    private let path: String

    private struct StoreData: Codable {
        var targets: [String]
        var bttSwiftUITrackerAdded: [String: Bool] // targetName → true if we added BTTSwiftUITracker
    }

    init(projectDir: String) {
        let bttDir = (projectDir as NSString).appendingPathComponent(".btt")
        self.path  = (bttDir as NSString).appendingPathComponent("btt_config.json")
        if !FileManager.default.fileExists(atPath: bttDir) {
            try? FileManager.default.createDirectory(atPath: bttDir, withIntermediateDirectories: true)
        }
    }

    var targets: [String] {
        load()?.targets ?? []
    }

    func isInstrumented(_ target: String) -> Bool {
        targets.contains(target)
    }

    /// Returns true only if BTTInstrumentor added BTTSwiftUITracker for this target
    func didAddBTTSwiftUITracker(for target: String) -> Bool {
        load()?.bttSwiftUITrackerAdded[target] ?? false
    }

    func add(_ target: String, bttSwiftUITrackerAdded: Bool = false) {
        var data = load() ?? StoreData(targets: [], bttSwiftUITrackerAdded: [:])
        if !data.targets.contains(target) { data.targets.append(target) }
        data.bttSwiftUITrackerAdded[target] = bttSwiftUITrackerAdded
        save(data)
    }

    func remove(_ target: String) {
        guard var data = load() else { return }
        data.targets = data.targets.filter { $0 != target }
        data.bttSwiftUITrackerAdded.removeValue(forKey: target)
        save(data)
    }

    // MARK: - Private

    private func load() -> StoreData? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            BTTLog.warn("btt_config.json unreadable — starting fresh"); return nil
        }
        guard let data = try? JSONDecoder().decode(StoreData.self, from: raw) else {
            BTTLog.warn("btt_config.json corrupted — starting fresh")
            try? FileManager.default.removeItem(atPath: path); return nil
        }
        return data
    }

    private func save(_ data: StoreData) {
        guard let raw = try? JSONEncoder().encode(data) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        try? raw.write(to: URL(fileURLWithPath: path))
        try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
    }
}
