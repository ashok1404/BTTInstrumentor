//
//  BTTTargetStore.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

import Foundation

struct BTTTargetStore {
    private struct StoreData: Codable {
        var targets:                [String]
        var bttSwiftUITrackerAdded: [String: Bool]
    }
    
    private let configPath: String

    init(projectDir: String) {
        let bttDir   = (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName)
        self.configPath = (bttDir as NSString).appendingPathComponent(BTTConstants.configFileName)

        if !FileManager.default.fileExists(atPath: bttDir) {
            try? FileManager.default.createDirectory(
                atPath: bttDir,
                withIntermediateDirectories: true
            )
        }
    }

    // MARK: - Read
    internal var targets: [String] { load()?.targets ?? [] }

    func isInstrumented(_ target: String) -> Bool {
        targets.contains(target)
    }

    func didAddBTTSwiftUITracker(for target: String) -> Bool {
        load()?.bttSwiftUITrackerAdded[target] ?? false
    }

    // MARK: - Write
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
        guard FileManager.default.fileExists(atPath: configPath) else { return nil }

        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else {
            BTTLog.warn("\(BTTConstants.configFileName) unreadable — starting fresh")
            return nil
        }
        guard let data = try? JSONDecoder().decode(StoreData.self, from: raw) else {
            BTTLog.warn("\(BTTConstants.configFileName) corrupted — starting fresh")
            try? FileManager.default.removeItem(atPath: configPath)
            return nil
        }
        return data
    }

    private func save(_ data: StoreData) {
        guard let raw = try? JSONEncoder().encode(data) else { return }
        // Temporarily make writable, write, then lock read-only
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: configPath)
        try? raw.write(to: URL(fileURLWithPath: configPath))
        try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: configPath)
    }
}
