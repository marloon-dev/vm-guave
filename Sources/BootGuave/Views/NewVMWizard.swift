import AppKit
import SwiftUI
import Virtualization

struct NewVMWizard: View {
    /// Sistema e imagem já escolhidos (ex.: "Usar imagem" na página Imagens).
    var initialOS: GuestOS? = nil
    var initialISO: URL? = nil
    let onCreate: (VMConfig) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = "Ubuntu"
    @State private var nameEdited = false
    @State private var os: GuestOS = .linux
    @State private var cpuCount = AppSettings.defaultCPUs
    @State private var memoryGB = AppSettings.defaultMemoryGB
    @State private var diskGB = AppSettings.defaultDiskGB
    @State private var isoURL: URL?
    @State private var ipswURL: URL?
    @State private var driversURL: URL?
    @State private var sharedFolderURL: URL?

    // Download em andamento (ISO de distro ou drivers do Windows)
    @State private var downloadLabel: String?
    @State private var downloadProgress: Double?
    @State private var downloader: FileDownloader?
    @State private var downloadTask: Task<Void, Never>?
    @State private var downloadError: String?

    private var canCreate: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, downloadLabel == nil else { return false }
        switch os {
        case .linux: return isoURL != nil
        case .macOS: return true
        case .windows: return isoURL != nil && QEMUTools.isInstalled
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Sistema") {
                    TextField("Nome", text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
                    Picker("Sistema operacional", selection: $os) {
                        ForEach(GuestOS.allCases) { os in
                            Label(os.displayName, systemImage: os.symbol).tag(os)
                        }
                    }
                    .onChange(of: os) { _, newOS in applyDefaults(for: newOS) }
                }

                switch os {
                case .linux: linuxInstallerSection
                case .macOS: macOSInstallerSection
                case .windows: windowsInstallerSection
                }

                if downloadLabel != nil || downloadError != nil {
                    Section { downloadStatus }
                }

                Section("Recursos") {
                    Stepper("CPUs: \(cpuCount)", value: $cpuCount, in: HostLimits.cpuRange)
                    Stepper("Memória: \(memoryGB) GB", value: $memoryGB, in: HostLimits.memoryGBRange)
                    Stepper("Disco: \(diskGB) GB", value: $diskGB, in: HostLimits.diskGBRange, step: 8)
                    Text("O disco é esparso: só ocupa no Mac o que a VM realmente usar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !os.usesQEMU {
                    Section("Compartilhamento") {
                        HStack {
                            Text("Pasta compartilhada")
                            Spacer()
                            Text(sharedFolderURL?.path ?? String(localized: "Nenhuma"))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                            if sharedFolderURL != nil {
                                Button("Remover") { sharedFolderURL = nil }
                            }
                            Button("Escolher…") {
                                if let url = FilePicker.chooseFolder() { sharedFolderURL = url }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(os == .macOS ? "Criar e instalar" : "Criar VM") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .padding()
        }
        .frame(width: 560, height: 660)
        .onAppear(perform: applyInitialChoice)
        .onDisappear(perform: cancelDownload)
    }

    private var isoRow: some View {
        HStack {
            Text(os == .windows ? "ISO do Windows 11 ARM" : "ISO de instalação")
            Spacer()
            Text(isoURL?.lastPathComponent ?? String(localized: "Nenhuma"))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if os == .linux {
                Menu("Baixar") {
                    ForEach(Distro.allCases) { distro in
                        Button(distro.displayName) { download(distro) }
                    }
                }
                .fixedSize()
                .guaveHover(.text)
                .disabled(downloadLabel != nil)
            }
            Button("Escolher…") {
                if let url = FilePicker.chooseISO() { isoURL = url }
            }
            .disabled(downloadLabel != nil)
        }
    }

    private var linuxInstallerSection: some View {
        Section("Instalação") {
            isoRow
            Text("Use uma ISO ARM64 (aarch64). \"Baixar\" pega a versão mais recente do site oficial e salva em Downloads.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var macOSInstallerSection: some View {
        Section("Instalação") {
            HStack {
                Text("Imagem do macOS")
                Spacer()
                Text(ipswURL?.lastPathComponent ?? String(localized: "Mais recente compatível (download)"))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if ipswURL != nil {
                    Button("Usar download") { ipswURL = nil }
                }
                Button("Usar .ipsw…") {
                    if let url = FilePicker.chooseIPSW() { ipswURL = url }
                }
            }
            Text(ipswURL == nil
                 ? "A Apple fornece a imagem (~15 GB). O download fica em cache e é reaproveitado por outras VMs macOS."
                 : "A instalação usa o arquivo escolhido.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Para o macOS, recomendo pelo menos 4 CPUs, 8 GB de memória e 80 GB de disco.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var windowsInstallerSection: some View {
        Section("Instalação") {
            if !QEMUTools.isInstalled {
                Label("O Windows roda no motor QEMU, que não está instalado. \(QEMUTools.installHint)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            isoRow
            Button("Baixar Windows 11 ARM no site da Microsoft…") {
                NSWorkspace.shared.open(WindowsDownloads.windows11ARMPage)
            }
            .buttonStyle(.link)
            .guaveHover(.text)
            HStack {
                Text("Drivers virtio-win (rede)")
                Spacer()
                Text(driversURL?.lastPathComponent ?? String(localized: "Nenhum"))
                    .foregroundStyle(.secondary)
                if driversURL == nil {
                    Button("Baixar (~880 MB)") { downloadDrivers() }
                        .disabled(downloadLabel != nil)
                } else {
                    Button("Remover") { driversURL = nil }
                }
            }
            Text("A tela do Windows aparece na janela da VM, como nas outras VMs. Ao iniciar a instalação, aperte uma tecla quando aparecer \"Press any key to boot from CD\". A rede só funciona depois de instalar os drivers do CD virtio-win (pasta NetKVM/w11/ARM64).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            let cached = DownloadLocations.driversFolder.appendingPathComponent(WindowsDownloads.virtioWinISO.lastPathComponent)
            if driversURL == nil, FileManager.default.fileExists(atPath: cached.path) { driversURL = cached }
        }
    }

    @ViewBuilder
    private var downloadStatus: some View {
        if let downloadLabel {
            HStack {
                if let downloadProgress {
                    ProgressView(value: downloadProgress)
                    Text("\(Int(downloadProgress * 100))%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Preparando download de \(downloadLabel)…")
                        .font(.caption)
                }
                Button("Cancelar", action: cancelDownload)
            }
        }
        if let downloadError {
            Text(downloadError).font(.caption).foregroundStyle(.red)
        }
    }

    private func applyInitialChoice() {
        guard let initialOS else { return }
        if initialOS != os {
            os = initialOS // o onChange aplica os padrões do sistema e limpa a ISO
        }
        DispatchQueue.main.async {
            guard let initialISO else { return }
            if initialOS == .macOS {
                ipswURL = initialISO
            } else {
                isoURL = initialISO
                if !nameEdited { name = Self.suggestedName(for: initialISO, os: initialOS) }
            }
        }
    }

    /// "ubuntu-24.04.2-desktop-arm64.iso" → "Ubuntu"; o resto fica com o nome do sistema.
    private static func suggestedName(for iso: URL, os: GuestOS) -> String {
        let file = iso.lastPathComponent.lowercased()
        for (needle, name) in [("ubuntu", "Ubuntu"), ("fedora", "Fedora"), ("debian", "Debian"), ("kali", "Kali"),
                               ("alpine", "Alpine"), ("arch", "Arch Linux"), ("opensuse", "openSUSE"), ("rocky", "Rocky Linux")]
        where file.contains(needle) {
            return name
        }
        return os == .windows ? "Windows 11" : iso.deletingPathExtension().lastPathComponent
    }

    private func applyDefaults(for os: GuestOS) {
        // Parte dos padrões dos Ajustes; macOS e Windows 11 têm mínimos próprios.
        memoryGB = AppSettings.defaultMemoryGB
        diskGB = AppSettings.defaultDiskGB
        switch os {
        case .macOS:
            memoryGB = min(max(memoryGB, 4), HostLimits.memoryGBRange.upperBound)
            diskGB = max(diskGB, 64)
            if !nameEdited { name = "macOS" }
        case .linux:
            if !nameEdited { name = "Ubuntu" }
        case .windows:
            memoryGB = min(max(memoryGB, 4), HostLimits.memoryGBRange.upperBound)
            diskGB = max(diskGB, 64)
            if !nameEdited { name = "Windows 11" }
        }
        isoURL = nil
    }

    private func download(_ distro: Distro) {
        startDownload(label: distro.displayName, folder: DownloadLocations.isoFolder, resolve: { try await distro.latestISOURL() }) { url in
            isoURL = url
            if !nameEdited { name = distro.suggestedVMName }
        }
    }

    private func downloadDrivers() {
        startDownload(label: "drivers virtio-win", folder: DownloadLocations.driversFolder, resolve: { WindowsDownloads.virtioWinISO }) { url in
            driversURL = url
        }
    }

    /// Resolve a URL, baixa para a pasta (se ainda não existir lá) e entrega o arquivo local.
    private func startDownload(label: String, folder: URL, resolve: @escaping () async throws -> URL, onDone: @escaping (URL) -> Void) {
        downloadError = nil
        downloadLabel = label
        downloadProgress = nil
        downloadTask = Task {
            do {
                let remote = try await resolve()
                let destination = folder.appendingPathComponent(remote.lastPathComponent)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    downloadProgress = 0
                    let downloader = FileDownloader(destination: destination) { value in
                        Task { @MainActor in downloadProgress = value }
                    }
                    self.downloader = downloader
                    _ = try await downloader.download(from: remote)
                }
                onDone(destination)
            } catch {
                if !(error is CancellationError) { downloadError = error.localizedDescription }
            }
            downloadLabel = nil
            downloadProgress = nil
            downloader = nil
        }
    }

    private func cancelDownload() {
        downloader?.cancel()
        downloadTask?.cancel()
    }

    private func create() {
        var config = VMConfig(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespaces),
            os: os,
            cpuCount: cpuCount,
            memoryGB: memoryGB,
            diskGB: diskGB,
            installerISOPath: os == .macOS ? nil : isoURL?.path,
            sharedFolderPath: os.usesQEMU ? nil : sharedFolderURL?.path,
            macAddress: VZMACAddress.randomLocallyAdministered().string,
            displayWidth: 1920,
            displayHeight: 1200,
            createdAt: Date()
        )
        config.installerIPSWPath = os == .macOS ? ipswURL?.path : nil
        config.driversISOPath = os == .windows ? driversURL?.path : nil
        config.clipboardSharing = AppSettings.defaultClipboardSharing
        if !os.usesQEMU { config.networkMode = AppSettings.defaultNetworkMode }
        onCreate(config)
        dismiss()
    }
}
