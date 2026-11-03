import Darwin
import Foundation

struct VMSnapshot: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    /// Snapshot tirado com a VM suspensa: restaurar volta com os programas abertos.
    var includesMachineState: Bool
}

/// Snapshots via clone APFS: cópia instantânea que só ocupa espaço conforme o disco diverge.
/// snapshots/<id>/{meta.json, config.json, arquivos da máquina, state.vzvmsave?}
extension VMBundle {
    var snapshotsURL: URL { dataURL.appendingPathComponent("snapshots", isDirectory: true) }

    private func snapshotURL(_ id: UUID) -> URL {
        snapshotsURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// config.json fica fora do cofre nas VMs criptografadas, por isso é tratado à parte.
    private static let snapshotFiles = VMBundle.machineFiles

    func snapshots() -> [VMSnapshot] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: snapshotsURL, includingPropertiesForKeys: nil)) ?? []
        return dirs
            .compactMap { try? JSONDecoder.iso8601.decode(VMSnapshot.self, from: Data(contentsOf: $0.appendingPathComponent("meta.json"))) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func createSnapshot(named name: String) throws -> VMSnapshot {
        let snapshot = VMSnapshot(id: UUID(), name: name, createdAt: Date(), includesMachineState: hasSavedState)
        let dir = snapshotURL(snapshot.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            for file in Self.snapshotFiles where FileManager.default.fileExists(atPath: dataURL.appendingPathComponent(file).path) {
                try FileCloner.clone(dataURL.appendingPathComponent(file), to: dir.appendingPathComponent(file))
            }
            // Windows: a memória já vai junto no disk.qcow2; basta copiar o marcador.
            for state in [savedStateURL, qemuSavedStateURL] where FileManager.default.fileExists(atPath: state.path) {
                try FileCloner.clone(state, to: dir.appendingPathComponent(state.lastPathComponent))
            }
            try FileManager.default.copyItem(at: configURL, to: dir.appendingPathComponent("config.json"))
            try JSONEncoder.iso8601.encode(snapshot).write(to: dir.appendingPathComponent("meta.json"))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
        return snapshot
    }

    func restoreSnapshot(_ snapshot: VMSnapshot) throws {
        let dir = snapshotURL(snapshot.id)
        // Antes de trocar o disco: o estado suspenso atual mora no qcow2 de agora.
        discardSavedState()
        for file in Self.snapshotFiles {
            let target = dataURL.appendingPathComponent(file)
            let source = dir.appendingPathComponent(file)
            try? FileManager.default.removeItem(at: target)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileCloner.clone(source, to: target)
            }
        }
        if snapshot.includesMachineState {
            for state in [savedStateURL, qemuSavedStateURL] {
                let source = dir.appendingPathComponent(state.lastPathComponent)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileCloner.clone(source, to: state)
                }
            }
        }
        let savedConfig = dir.appendingPathComponent("config.json")
        if FileManager.default.fileExists(atPath: savedConfig.path) {
            try? FileManager.default.removeItem(at: configURL)
            try FileManager.default.copyItem(at: savedConfig, to: configURL)
        }
    }

    func deleteSnapshot(_ snapshot: VMSnapshot) throws {
        try FileManager.default.removeItem(at: snapshotURL(snapshot.id))
    }
}

extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
