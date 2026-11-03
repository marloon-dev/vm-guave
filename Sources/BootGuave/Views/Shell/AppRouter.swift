import Observation
import SwiftUI

/// Seções da barra lateral.
enum AppPage: String, CaseIterable, Identifiable {
    case overview
    case machines
    case images
    case network
    case storage
    case settings

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .overview: return "Visão Geral"
        case .machines: return "Máquinas Virtuais"
        case .images: return "Imagens"
        case .network: return "Rede"
        case .storage: return "Armazenamento"
        case .settings: return "Configuração"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "house"
        case .machines: return "cube"
        case .images: return "opticaldisc"
        case .network: return "point.3.connected.trianglepath.dotted"
        case .storage: return "cylinder.split.1x2"
        case .settings: return "gearshape"
        }
    }
}

/// Seções da página Configuração.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case defaults
    case updates
    case about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: return "Geral"
        case .defaults: return "Recursos padrão"
        case .updates: return "Atualizações"
        case .about: return "Sobre"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .defaults: return "desktopcomputer"
        case .updates: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        }
    }
}

/// Estado da navegação, compartilhado com os menus do app (⌘N, ⌘,).
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    /// Página aberta; o app volta nela na próxima vez.
    var page: AppPage = AppPage(rawValue: UserDefaults.standard.string(forKey: "lastPage") ?? "") ?? .overview {
        didSet { UserDefaults.standard.set(page.rawValue, forKey: "lastPage") }
    }
    /// VM aberta em detalhe dentro de "Máquinas Virtuais".
    var openVM: UUID?
    var settingsSection: SettingsSection = .general

    /// Pedido para o assistente de nova VM (com imagem já escolhida, se veio da página Imagens).
    var wizardRequest: WizardRequest?
    var showingDiskImport = false

    func go(_ page: AppPage) {
        self.page = page
        if page != .machines { openVM = nil }
    }

    func open(vm id: UUID) {
        page = .machines
        openVM = id
    }

    func newVM(os: GuestOS? = nil, iso: URL? = nil) {
        wizardRequest = WizardRequest(os: os, iso: iso)
    }

    func showSettings(_ section: SettingsSection = .general) {
        settingsSection = section
        go(.settings)
    }
}

struct WizardRequest: Identifiable {
    let id = UUID()
    var os: GuestOS?
    var iso: URL?
}
