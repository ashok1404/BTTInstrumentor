//
//  BTTTargetStore.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

import Foundation

struct BTTTargetStore {
    private struct StoreData: Codable {
        var version:       String
        var xcodeprojName: String?
        var targets:       [String]
    }

    private let configPath: String

    init(projectDir: String) {
        let bttDir      = (projectDir as NSString).appendingPathComponent(BTTConstants.bttFolderName)
        self.configPath = (bttDir as NSString).appendingPathComponent(BTTConstants.configFileName)
    }

    // MARK: - Read

    var targets: [String] {
        load()?.targets ?? []
    }

    func isInstrumented(_ target: String) -> Bool {
        targets.contains(target)
    }

    func savedXcodeprojName() -> String? { load()?.xcodeprojName }

    /// Saves just the .xcodeproj filename — never the full path.
    func saveXcodeprojName(_ xcodeprojPath: String) {
        let name = URL(fileURLWithPath: xcodeprojPath).lastPathComponent
        var data = load() ?? StoreData(version: BTTConstants.version, xcodeprojName: nil, targets: [])
        guard data.xcodeprojName != name else { return }
        data.xcodeprojName = name
        save(data)
    }

    func add(_ target: String) {
        var data = load() ?? StoreData(version: BTTConstants.version, xcodeprojName: nil, targets: [])
        if !data.targets.contains(target) { data.targets.append(target) }
        data.version = BTTConstants.version
        save(data)
    }

    func remove(_ target: String) {
        guard var data = load() else { return }
        data.targets.removeAll { $0 == target }
        save(data)
    }

    // MARK: - Private

    private func load() -> StoreData? {
        guard FileManager.default.fileExists(atPath: configPath) else { return nil }
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: configPath)) else {
            BTTLog.warn("\(BTTConstants.configFileName) unreadable — starting fresh")
            return nil
        }
        let decoder = JSONDecoder()
        guard let data = try? decoder.decode(StoreData.self, from: raw) else {
            BTTLog.warn("\(BTTConstants.configFileName) corrupted — starting fresh")
            try? FileManager.default.removeItem(atPath: configPath)
            return nil
        }
        return data
    }

    private func save(_ data: StoreData) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let raw = try? encoder.encode(data) else { return }
        let bttDir = (configPath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: bttDir) {
            try? FileManager.default.createDirectory(atPath: bttDir, withIntermediateDirectories: true)
        }
        do {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: configPath)
            try raw.write(to: URL(fileURLWithPath: configPath))
            try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: configPath)
        } catch {
            try? raw.write(to: URL(fileURLWithPath: configPath))
            try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: configPath)
        }
    }
}
