import AppKit
import Foundation

/// Ajustes do app (janela Ajustes, ⌘,). Ficam no UserDefaults; as views usam @AppStorage com as
/// mesmas chaves. Os padrões reproduzem o comportamento de antes de existir a janela.
enum AppSettings {
    enum Key {
        static let autoStartEnabled = "autoStartEnabled"
        static let quitBehavior = "quitBehavior"
        static let defaultCPUs = "defaultCPUs"
        static let defaultMemoryGB = "defaultMemoryGB"
        static let defaultDiskGB = "defaultDiskGB"
        static let defaultNetworkMode = "defaultNetworkMode"
        static let defaultClipboardSharing = "defaultClipboardSharing"
        static let fullScreenShortcut = "fullScreenShortcut"
        static let hideBarsInFullScreen = "hideBarsInFullScreen"
        static let appTheme = "appTheme"
        static let autoCheckUpdates = "autoCheckUpdates"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let skippedUpdateVersion = "skippedUpdateVersion"
    }

    /// Chamado no início do app, antes de qualquer leitura.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.autoStartEnabled: true,
            Key.quitBehavior: QuitBehavior.ask.rawValue,
            Key.defaultCPUs: min(4, HostLimits.cpuRange.upperBound),
            Key.defaultMemoryGB: min(4, HostLimits.memoryGBRange.upperBound),
            Key.defaultDiskGB: 64,
            Key.defaultNetworkMode: NetworkMode.nat.rawValue,
            Key.defaultClipboardSharing: true,
            Key.fullScreenShortcut: true,
            Key.hideBarsInFullScreen: true,
            Key.appTheme: AppTheme.dark.rawValue,
            Key.autoCheckUpdates: true,
        ])
    }

    private static var store: UserDefaults { .standard }

    static var autoStartEnabled: Bool { store.bool(forKey: Key.autoStartEnabled) }
    static var quitBehavior: QuitBehavior {
        QuitBehavior(rawValue: store.string(forKey: Key.quitBehavior) ?? "") ?? .ask
    }
    static var fullScreenShortcut: Bool { store.bool(forKey: Key.fullScreenShortcut) }
    static var autoCheckUpdates: Bool { store.bool(forKey: Key.autoCheckUpdates) }
    static var theme: AppTheme { AppTheme(rawValue: store.string(forKey: Key.appTheme) ?? "") ?? .dark }

    /// Valores iniciais do assistente de nova VM, já dentro dos limites deste Mac.
    static var defaultCPUs: Int { clamp(store.integer(forKey: Key.defaultCPUs), HostLimits.cpuRange) }
    static var defaultMemoryGB: Int { clamp(store.integer(forKey: Key.defaultMemoryGB), HostLimits.memoryGBRange) }
    static var defaultDiskGB: Int { clamp(store.integer(forKey: Key.defaultDiskGB), HostLimits.diskGBRange) }
    static var defaultNetworkMode: NetworkMode {
        let mode = NetworkMode(rawValue: store.string(forKey: Key.defaultNetworkMode) ?? "") ?? .nat
        // Redes vmnet exigem macOS 26; num sistema mais antigo, volta para NAT.
        return VMNetworkFactory.vmnetAvailable ? mode : .nat
    }
    static var defaultClipboardSharing: Bool { store.bool(forKey: Key.defaultClipboardSharing) }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Aparência do app. O padrão é o escuro, como o visual de referência.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return String(localized: "Igual ao sistema")
        case .light: return String(localized: "Claro")
        case .dark: return String(localized: "Escuro")
        }
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// O que fazer com VMs ligadas quando o app fecha.
enum QuitBehavior: String, CaseIterable, Identifiable {
    case ask
    case suspend
    case shutdown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ask: return String(localized: "Perguntar")
        case .suspend: return String(localized: "Suspender as VMs")
        case .shutdown: return String(localized: "Desligar na hora")
        }
    }
}

/// Idiomas da interface. O código é o nome da pasta .lproj dentro do app.
struct AppLanguage: Identifiable, Hashable {
    let code: String
    /// Nome no próprio idioma, para quem não lê o idioma atual achar o seu.
    let nativeName: String

    var id: String { code }

    static let all: [AppLanguage] = [
        AppLanguage(code: "pt-BR", nativeName: "Português (Brasil)"),
        AppLanguage(code: "pt-PT", nativeName: "Português (Portugal)"),
        AppLanguage(code: "en", nativeName: "English"),
        AppLanguage(code: "es", nativeName: "Español"),
        AppLanguage(code: "fr", nativeName: "Français"),
        AppLanguage(code: "de", nativeName: "Deutsch"),
        AppLanguage(code: "it", nativeName: "Italiano"),
        AppLanguage(code: "ja", nativeName: "日本語"),
        AppLanguage(code: "zh-Hans", nativeName: "简体中文"),
        AppLanguage(code: "ko", nativeName: "한국어"),
        AppLanguage(code: "ru", nativeName: "Русский"),
    ]

    private static let appleLanguagesKey = "AppleLanguages"

    /// Idioma escolhido só para o VM Guave; nil = segue o idioma do sistema.
    static var override: String? {
        get {
            guard let domain = Bundle.main.bundleIdentifier,
                  let list = UserDefaults.standard.persistentDomain(forName: domain)?[appleLanguagesKey] as? [String]
            else { return nil }
            return list.first
        }
        set {
            if let newValue {
                UserDefaults.standard.set([newValue], forKey: appleLanguagesKey)
            } else {
                UserDefaults.standard.removeObject(forKey: appleLanguagesKey)
            }
        }
    }
}

/// Reabre o app depois que ele fecha (para aplicar o idioma). Um shell espera este processo
/// sair, assim a nova cópia não esbarra na trava de instância única.
enum AppRelauncher {
    @MainActor private(set) static var pending = false

    @MainActor static func relaunch() {
        pending = true
        NSApp.terminate(nil)
    }

    /// Chamado em applicationWillTerminate: só aqui o fechamento já é certo.
    @MainActor static func launchWaiterIfPending() {
        guard pending else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
    }
}
