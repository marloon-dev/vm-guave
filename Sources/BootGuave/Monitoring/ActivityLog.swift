import Observation
import Foundation
import SwiftUI

/// Uma ação registrada (VM iniciada, imagem baixada, configuração salva…).
struct ActivityEntry: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case started, stopped, suspended, failed
        case created, deleted, cloned, imported, exported
        case snapshotCreated, snapshotRestored
        case imageDownloaded, imageImported
        case settingsSaved
    }

    var id = UUID()
    var date: Date
    var kind: Kind
    /// Nome da VM ou da imagem; vazio para ações do app.
    var subject: String

    var symbol: String {
        switch kind {
        case .started: return "play.fill"
        case .stopped: return "stop.fill"
        case .suspended: return "moon.zzz.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .created: return "plus"
        case .deleted: return "trash"
        case .cloned: return "plus.square.on.square"
        case .imported, .imageImported, .imageDownloaded: return "arrow.down.to.line"
        case .exported: return "square.and.arrow.up"
        case .snapshotCreated, .snapshotRestored: return "clock.arrow.circlepath"
        case .settingsSaved: return "gearshape"
        }
    }

    var tint: Color {
        switch kind {
        case .started, .created, .cloned, .imported, .imageDownloaded, .imageImported: return Brand.green
        case .stopped, .deleted, .failed: return Brand.pink
        case .suspended, .snapshotCreated, .snapshotRestored, .exported: return Brand.cream
        case .settingsSaved: return .secondary
        }
    }

    /// Frase depois do nome em negrito ("iniciada com sucesso").
    var phrase: String {
        switch kind {
        case .started: return String(localized: "iniciada")
        case .stopped: return String(localized: "desligada")
        case .suspended: return String(localized: "suspensa")
        case .failed: return String(localized: "parou com erro")
        case .created: return String(localized: "criada")
        case .deleted: return String(localized: "excluída")
        case .cloned: return String(localized: "clonada")
        case .imported: return String(localized: "importada")
        case .exported: return String(localized: "exportada")
        case .snapshotCreated: return String(localized: "snapshot criado")
        case .snapshotRestored: return String(localized: "snapshot restaurado")
        case .imageDownloaded: return String(localized: "baixada")
        case .imageImported: return String(localized: "adicionada às imagens")
        case .settingsSaved: return String(localized: "Configuração atualizada")
        }
    }

    /// Imagens têm o prefixo "Imagem" antes do nome.
    var isImage: Bool { kind == .imageDownloaded || kind == .imageImported }
}

/// Histórico das últimas ações, salvo em Application Support (sobrevive a reinícios).
@MainActor
@Observable
final class ActivityLog {
    static let shared = ActivityLog()

    private(set) var entries: [ActivityEntry] = []
    private let limit = 200

    private var fileURL: URL {
        VMBundle.libraryURL.deletingLastPathComponent().appendingPathComponent("activity.json")
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder.iso8601.decode([ActivityEntry].self, from: data) {
            entries = saved
        }
    }

    func add(_ kind: ActivityEntry.Kind, _ subject: String = "") {
        entries.insert(ActivityEntry(date: Date(), kind: kind, subject: subject), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder.iso8601.encode(entries) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
