import AppKit
import SwiftUI

/// Rascunho dos ajustes: as mudanças só valem em "Salvar alterações".
private struct SettingsDraft: Equatable {
    var language: String          // "" = idioma do sistema
    var theme: AppTheme
    var autoStartEnabled: Bool
    var quitBehavior: QuitBehavior
    var fullScreenShortcut: Bool
    var hideBarsInFullScreen: Bool
    var cpus: Int
    var memoryGB: Int
    var diskGB: Int
    var networkMode: NetworkMode
    var clipboardSharing: Bool
    var autoCheckUpdates: Bool

    static func load() -> SettingsDraft {
        let d = UserDefaults.standard
        return SettingsDraft(
            language: AppLanguage.override ?? "",
            theme: AppSettings.theme,
            autoStartEnabled: AppSettings.autoStartEnabled,
            quitBehavior: AppSettings.quitBehavior,
            fullScreenShortcut: AppSettings.fullScreenShortcut,
            hideBarsInFullScreen: d.bool(forKey: AppSettings.Key.hideBarsInFullScreen),
            cpus: AppSettings.defaultCPUs,
            memoryGB: AppSettings.defaultMemoryGB,
            diskGB: AppSettings.defaultDiskGB,
            networkMode: AppSettings.defaultNetworkMode,
            clipboardSharing: AppSettings.defaultClipboardSharing,
            autoCheckUpdates: AppSettings.autoCheckUpdates
        )
    }

    func save() {
        let d = UserDefaults.standard
        AppLanguage.override = language.isEmpty ? nil : language
        d.set(theme.rawValue, forKey: AppSettings.Key.appTheme)
        d.set(autoStartEnabled, forKey: AppSettings.Key.autoStartEnabled)
        d.set(quitBehavior.rawValue, forKey: AppSettings.Key.quitBehavior)
        d.set(fullScreenShortcut, forKey: AppSettings.Key.fullScreenShortcut)
        d.set(hideBarsInFullScreen, forKey: AppSettings.Key.hideBarsInFullScreen)
        d.set(cpus, forKey: AppSettings.Key.defaultCPUs)
        d.set(memoryGB, forKey: AppSettings.Key.defaultMemoryGB)
        d.set(diskGB, forKey: AppSettings.Key.defaultDiskGB)
        d.set(networkMode.rawValue, forKey: AppSettings.Key.defaultNetworkMode)
        d.set(clipboardSharing, forKey: AppSettings.Key.defaultClipboardSharing)
        d.set(autoCheckUpdates, forKey: AppSettings.Key.autoCheckUpdates)
    }
}

struct SettingsPage: View {
    @ObservedObject private var router = AppRouter.shared
    @State private var saved = SettingsDraft.load()
    @State private var draft = SettingsDraft.load()
    @State private var askRelaunch = false

    private var hasChanges: Bool { draft != saved }

    var body: some View {
        HStack(spacing: 0) {
            sectionList
                .frame(width: 250)
                .background(Surface.sidebar)
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        PageHeader("Configuração", subtitle: "Preferências do ambiente e da aplicação.")
                            .padding(.bottom, 4)
                        switch router.settingsSection {
                        case .general: generalSection
                        case .defaults: defaultsSection
                        case .updates: UpdatesSection(autoCheck: $draft.autoCheckUpdates)
                        case .about: AboutSection()
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 28)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if router.settingsSection != .about {
                    Divider()
                    HStack(spacing: 14) {
                        if hasChanges {
                            Text("Alterações não salvas").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancelar") { draft = saved }
                            .buttonStyle(SecondaryButtonStyle(large: true))
                            .disabled(!hasChanges)
                            .keyboardShortcut(.cancelAction)
                        Button("Salvar alterações") { save() }
                            .buttonStyle(GuaveButtonStyle(large: true))
                            .disabled(!hasChanges)
                            .keyboardShortcut("s", modifiers: .command)
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 16)
                }
            }
            .background(PageBackground())
        }
        .alert("Reabrir o VM Guave agora?", isPresented: $askRelaunch) {
            Button("Reabrir agora") { AppRelauncher.relaunch() }
            Button("Depois", role: .cancel) {}
        } message: {
            Text("O idioma muda quando o app abre de novo. VMs ligadas seguem o que está em \"Ao fechar com VMs ligadas\".")
        }
    }

    private func save() {
        let languageChanged = draft.language != saved.language
        draft.save()
        draft.theme.apply()
        saved = draft
        ActivityLog.shared.add(.settingsSaved)
        if languageChanged { askRelaunch = true }
    }

    // MARK: Menu das seções

    private var sectionList: some View {
        VStack(spacing: 6) {
            ForEach(SettingsSection.allCases) { section in
                let selected = router.settingsSection == section
                Button { router.settingsSection = section } label: {
                    HStack(spacing: 14) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 18))
                            .frame(width: 26)
                        Text(section.title).font(.title3)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selected ? Color.primary : .secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(selected ? Brand.leaf.opacity(0.45) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 96)
    }

    // MARK: Geral

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard("Preferências gerais") {
                SettingsRow("Idioma") {
                    Picker("Idioma", selection: $draft.language) {
                        Text("Idioma do sistema").tag("")
                        Divider()
                        ForEach(AppLanguage.all) { Text(verbatim: $0.nativeName).tag($0.code) }
                    }
                }
                SettingsRow("Tema") {
                    Picker("Tema", selection: $draft.theme) {
                        ForEach(AppTheme.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                SettingsToggle("Ligar as VMs marcadas para iniciar sozinhas",
                               detail: "Cada VM tem a opção \"Iniciar quando o VM Guave abrir\" nas configurações dela.",
                               isOn: $draft.autoStartEnabled)
            }

            SettingsCard("Ao fechar com VMs ligadas") {
                SettingsRow("Ação") {
                    Picker("Ação", selection: $draft.quitBehavior) {
                        ForEach(QuitBehavior.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                Text(quitHelp)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SettingsCard("Tela e teclado") {
                SettingsToggle("Atalho ⌘F para entrar e sair da tela cheia",
                               detail: "Desligado, o ⌘F vai para o sistema da VM (por exemplo, para buscar). A tela cheia continua no botão da barra de ferramentas e no botão verde da janela.",
                               isOn: $draft.fullScreenShortcut)
                SettingsToggle("Esconder as barras na tela cheia",
                               detail: "Mostra só a tela da VM; as barras voltam ao encostar o mouse no topo. Exige macOS 15 ou mais recente.",
                               isOn: $draft.hideBarsInFullScreen)
            }
        }
    }

    private var quitHelp: String {
        switch draft.quitBehavior {
        case .ask:
            return String(localized: "Mostra um aviso para escolher entre suspender, cancelar ou sair.")
        case .suspend:
            return String(localized: "Salva o estado das VMs e fecha. VMs Windows ou com rede personalizada não podem ser suspensas e são desligadas na hora.")
        case .shutdown:
            return String(localized: "Fecha sem salvar nada, como tirar da tomada. Pode perder o que não foi salvo dentro das VMs.")
        }
    }

    // MARK: Recursos padrão

    private var memoryOptions: [Int] {
        let range = HostLimits.memoryGBRange
        return ([1, 2, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128].filter(range.contains) + [draft.memoryGB]).uniqueSorted()
    }

    private var diskOptions: [Int] {
        ([32, 48, 64, 80, 128, 256, 512, 1024].filter(HostLimits.diskGBRange.contains) + [draft.diskGB]).uniqueSorted()
    }

    private var defaultsSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard("Recursos padrão para novas VMs") {
                SettingsRow("CPU padrão") {
                    Picker("CPU padrão", selection: $draft.cpus) {
                        ForEach(Array(HostLimits.cpuRange), id: \.self) { Text(verbatim: "\($0) vCPU").tag($0) }
                    }
                }
                SettingsRow("Memória padrão") {
                    Picker("Memória padrão", selection: $draft.memoryGB) {
                        ForEach(memoryOptions, id: \.self) { Text(verbatim: "\($0) GB").tag($0) }
                    }
                }
                SettingsRow("Disco padrão") {
                    Picker("Disco padrão", selection: $draft.diskGB) {
                        ForEach(diskOptions, id: \.self) { Text(verbatim: "\($0) GB").tag($0) }
                    }
                }
                Text("O Windows 11 pede no mínimo 4 GB de memória e 64 GB de disco; o assistente sobe os valores se precisar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            SettingsCard("Rede e integração") {
                SettingsRow("Rede") {
                    Picker("Rede", selection: $draft.networkMode) {
                        ForEach(NetworkMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    .disabled(!VMNetworkFactory.vmnetAvailable)
                }
                SettingsToggle("Área de transferência compartilhada",
                               detail: "Valem para VMs Linux e macOS. O Windows usa a rede NAT do QEMU.",
                               isOn: $draft.clipboardSharing)
            }

            Button("Restaurar padrões") {
                draft.cpus = min(4, HostLimits.cpuRange.upperBound)
                draft.memoryGB = min(4, HostLimits.memoryGBRange.upperBound)
                draft.diskGB = 64
                draft.networkMode = .nat
                draft.clipboardSharing = true
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }
}

// MARK: - Atualizações e Sobre

private struct UpdatesSection: View {
    @Binding var autoCheck: Bool
    @ObservedObject private var checker = UpdateChecker.shared

    var body: some View {
        SettingsCard("Atualizações") {
            SettingsRow("Versão instalada") {
                Text(verbatim: UpdateChecker.currentVersion)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            SettingsToggle("Verificar automaticamente", detail: "Ao abrir o app, a cada 10 minutos e quando ele volta para a frente.", isOn: $autoCheck)
            HStack(spacing: 14) {
                Button {
                    Task { await checker.check() }
                } label: {
                    Label("Verificar agora", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(checker.status == .checking)
                statusView
                Spacer()
            }
            if let lastCheck = checker.lastCheck {
                Text("Última verificação: \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch checker.status {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .upToDate:
            Label("Você está na versão mais recente.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Brand.green)
        case .available(let version, _):
            HStack(spacing: 10) {
                Label("Versão \(version) disponível", systemImage: "sparkles")
                    .foregroundStyle(Brand.green)
                Button("Baixar") { checker.update() }
                    .buttonStyle(GuaveButtonStyle())
            }
        case .failed(let message):
            Label("Não foi possível verificar: \(message)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Brand.pink)
                .lineLimit(2)
        }
    }
}

private struct AboutSection: View {
    var body: some View {
        SettingsCard("Sobre") {
            HStack(spacing: 20) {
                Image(nsImage: AppLogo.image)
                    .resizable()
                    .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "VM Guave").font(.system(size: 28, weight: .bold))
                    Text("Versão \(UpdateChecker.currentVersion)")
                        .foregroundStyle(.secondary)
                    Text("Máquinas virtuais Linux, Windows e macOS no Mac com Apple Silicon.")
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Button("Site do VM Guave") { NSWorkspace.shared.open(UpdateChecker.siteURL) }
                    .buttonStyle(SecondaryButtonStyle())
                Text("Licença MIT").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Peças dos cartões

private struct SettingsCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.weight(.bold))
            content()
        }
        .guaveCard(padding: 24)
    }
}

/// Rótulo à esquerda, controle à direita (com largura fixa, como os menus da referência).
private struct SettingsRow<Control: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder var control: () -> Control

    init(_ label: LocalizedStringKey, @ViewBuilder control: @escaping () -> Control) {
        self.label = label
        self.control = control
    }

    var body: some View {
        HStack {
            Text(label).font(.title3)
            Spacer(minLength: 20)
            control()
                .labelsHidden()
                .frame(width: 320, alignment: .trailing)
        }
    }
}

private struct SettingsToggle: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, detail: LocalizedStringKey? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3)
                if let detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 20)
            Toggle(isOn: $isOn) { Text(title) }
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Brand.green)
                .controlSize(.large)
        }
    }
}

private extension Array where Element == Int {
    func uniqueSorted() -> [Int] { Array(Set(self)).sorted() }
}
