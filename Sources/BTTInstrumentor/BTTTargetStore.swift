//
//  BTTTargetStore.swift
//  BTTInstrumentor
//
//  Created by Ashok Singh on 04/06/26.
//

import Foundation

struct BTTTargetStore {

    private let path: String

    init(projectDir: String) {
        let bttDir = (projectDir as NSString).appendingPathComponent(".btt")
        self.path  = (bttDir as NSString).appendingPathComponent("targets.json")
        if !FileManager.default.fileExists(atPath: bttDir) {
            try? FileManager.default.createDirectory(atPath: bttDir, withIntermediateDirectories: true)
        }
    }

    var targets: [String] {
        guard fm.fileExists(atPath: path) else { return [] }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            BTTLog.warn("targets.json is unreadable — starting fresh")
            return []
        }
        guard let list = try? JSONDecoder().decode([String].self, from: data) else {
            BTTLog.warn("targets.json is corrupted — starting fresh")
            try? fm.removeItem(atPath: path)
            return []
        }
        return list
    }

    func add(_ target: String) {
        var list = targets
        guard !list.contains(target) else { return }
        list.append(target)
        save(list)
    }

    func remove(_ target: String) {
        save(targets.filter { $0 != target })
    }

    func isInstrumented(_ target: String) -> Bool {
        targets.contains(target)
    }

    private func save(_ list: [String]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        // Remove read-only if exists before writing
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        try? data.write(to: URL(fileURLWithPath: path))
        // Make read-only — prevents manual edits
        try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: path)
    }
}
