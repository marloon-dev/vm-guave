import AppKit
import SwiftUI

struct VMDetailView: View {
    @ObservedObject var runner: VMRunner
    let onDelete: () -> Void
    let onClone: (UUID) -> Void

    @EnvironmentObject private var library: VMLibrary
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingDelete = false
    @State private var showingSettings = false
    @State private var snapshots: [VMSnapshot] = []
    @State private var namingSnapshot = false
    @State private var snapshotName = ""
    @State private var restoring: VMSnapshot?
    @State private var confirmingNVRAMReset = false
    @State private var passwordMode: VaultPasswordSheet.Mode?
    @State private var startAfterUnlock = false

    private var config: VMConfig { runner.config }
    private var isActive: Bool { runner.state.isActive }
    private var isLocked: Bool { library.isLocked(config.id) }

    var body: some View {
        withDialogs(form)
    }

    private var form: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: config.os.symbol)
                        .font(.system(size: 34))
                        .frame(width: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(config.name).font(.title2.bold())
                        StatusBadge(state: runner.state)
                    }
                    Spacer()
                }
                if config.encrypted {
                    HStack {
                        Label(isLocked ? "Criptografada · bloqueada" : "Criptografada · desbloqueada",
                              systemImage: isLocked ? "lock.fill" : "lock.open")
                            .foregroundStyle(isLocked ? .orange : .secondary)
                        Spacer()
                        if isLocked {
                            Button("Desbloquear…") {
                                startAfterUnlock = false
                                passwordMode = .unlock
                            }
                        }
                    }
                }
                if case .error(let message) = runner.state {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                if runner.state == .downloading || runner.state == .installing {
                    HStack {
                        if let progress = runner.progress {
                            ProgressView(value: progress)
                            Text("\(Int(progress * 100))%")
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        if runner.state == .downloading {
                            Button("Cancelar") { runner.cancelDownload() }
                        }
                    }
                    Text(runner.state == .downloading
                         ? "Baixando a imagem do macOS da Apple (~15 GB). Pode demorar."
                         : "Instalando o macOS. Leva de 10 a 30 minutos; não feche o app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let notice = runner.notice {
                    HStack(alignment: .top) {
                        Text(notice).font(.callout).foregroundStyle(.orange)
                        Spacer()
                        Button("OK") { runner.notice = nil }
                    }
                }
            }

            Section("Controles") {
                HStack {
                    if isActive {
                        activeControls
                    } else {
                        stoppedControls
                    }
                }
            }

            Section("Configuração") {
                LabeledContent("Sistema", value: config.os.displayName)
                LabeledContent("CPUs", value: "\(config.cpuCount)")
                LabeledContent("Memória", value: "\(config.memoryGB) GB")
                LabeledContent("Disco", value: "\(config.diskGB) GB")
                LabeledContent("Rede", value: networkSummary)
                if !config.extraDisks.isEmpty {
                    LabeledContent("Discos adicionais", value: config.extraDisks.map { "\($0.sizeGB) GB" }.joined(separator: ", "))
                }
                if config.os == .linux {
                    LabeledContent("Área de transferência", value: config.clipboardSharing ? "Compartilhada" : "Isolada")
                    LabeledContent("Rosetta", value: config.rosettaEnabled ? "Ativado" : "Desativado")
                }
                LabeledContent("Iniciar ao abrir o app", value: config.autoStart ? "Sim" : "Não")
                if !config.os.usesQEMU {
                    sharedFolderRows
                }
            }

            if config.os == .macOS {
                Section("Instalação") {
                    LabeledContent("macOS", value: config.macOSInstalled ? "Instalado" : "Não instalado")
                    LabeledContent("Imagem") {
                        Text(config.installerIPSWPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Mais recente (download)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } else {
                linuxInstallSection
            }

            snapshotsSection

            Section {
                Button("Excluir VM…", role: .destructive) { confirmingDelete = true }
                    .disabled(isActive)
            }
        }
        .formStyle(.grouped)
    }

    private var networkSummary: String {
        let ip: String? = config.networkMode == .nat
            ? VMNetworkFactory.natIPAddress(forMAC: config.macAddress)
            : config.guestIPAddress
        var parts = [config.os.usesQEMU ? "NAT (QEMU)" : config.networkMode.displayName]
        if let ip, !config.os.usesQEMU { parts.append(ip) }
        if !config.portForwards.isEmpty {
            parts.append(config.portForwards.map { "\($0.hostPort)→\($0.guestPort)" }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var sharedFolderRows: some View {
                LabeledContent("Pasta compartilhada") {
                    HStack {
                        Text(config.sharedFolderPath ?? "Nenhuma")
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.head)
                        if config.sharedFolderPath != nil {
                            Button("Remover") { edit { $0.sharedFolderPath = nil } }
                        }
                        Button("Escolher…") {
                            if let url = FilePicker.chooseFolder() { edit { $0.sharedFolderPath = url.path } }
                        }
                    }
                    .disabled(isActive)
                }
                if config.sharedFolderPath != nil {
                    Text(config.os == .macOS
                         ? "No macOS convidado: aparece sozinha em /Volumes/My Shared Files"
                         : "No Linux: sudo mount -t virtiofs \(VMConfig.sharedFolderTag) /mnt")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
    }

    private var linuxInstallSection: some View {
            Section("Instalação") {
                LabeledContent("ISO") {
                    HStack {
                        Text(config.installerISOPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Ejetada")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(config.installerISOPath == nil ? "Inserir ISO…" : "Trocar ISO…") {
                            if let url = FilePicker.chooseISO() { edit { $0.installerISOPath = url.path } }
                        }
                    }
                    .disabled(isActive)
                }
                if config.installerISOPath != nil {
                    Button("Ejetar ISO (depois de instalar o sistema)") {
                        edit { $0.installerISOPath = nil }
                    }
                    .disabled(isActive)
                }
                if config.os == .windows {
                    LabeledContent("Drivers virtio-win") {
                        HStack {
                            Text(config.driversISOPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Nenhum")
                            if config.driversISOPath != nil {
                                Button("Ejetar") { edit { $0.driversISOPath = nil } }
                            }
                            Button("Escolher…") {
                                if let url = FilePicker.chooseISO() { edit { $0.driversISOPath = url.path } }
                            }
                        }
                        .disabled(isActive)
                    }
                }
            }
    }

    /// Folhas e diálogos ficam separados do formulário para não estourar o type-checker.
    private func withDialogs<Content: View>(_ content: Content) -> some View {
        content
        .onAppear(perform: reloadSnapshots)
        .onChange(of: runner.passwordNeeded) { _, needed in
            guard needed else { return }
            runner.passwordNeeded = false
            startAfterUnlock = true
            passwordMode = .unlock
        }
        .sheet(item: $passwordMode) { mode in
            VaultPasswordSheet(mode: mode, vmName: config.name) { password, remember in
                await submitPassword(mode, password, remember)
            }
        }
        .sheet(isPresented: $showingSettings) {
            VMSettingsView(config: config, isSuspended: runner.state == .suspended) { updated in
                library.applySettings(updated)
            }
        }
        .confirmationDialog(
            "Excluir \"\(config.name)\"?",
            isPresented: $confirmingDelete
        ) {
            Button("Excluir disco, snapshots e configuração", role: .destructive, action: onDelete)
        } message: {
            Text("O disco virtual será apagado permanentemente.")
        }
        .alert("Novo snapshot", isPresented: $namingSnapshot) {
            TextField("Nome", text: $snapshotName)
            Button("Criar") {
                library.createSnapshot(for: config.id, named: snapshotName)
                reloadSnapshots()
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(runner.state == .suspended
                 ? "A VM está suspensa: o snapshot inclui a memória e restaura com os programas abertos."
                 : "Guarda o disco e a configuração atuais.")
        }
        .confirmationDialog(
            "Restaurar \"\(restoring?.name ?? "")\"?",
            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })
        ) {
            Button("Restaurar", role: .destructive) {
                if let restoring { library.restoreSnapshot(restoring, for: config.id) }
                restoring = nil
            }
        } message: {
            Text("Tudo o que mudou na VM depois desse snapshot será perdido. Crie outro snapshot antes, se quiser guardar o estado atual.")
        }
        .confirmationDialog("Redefinir a NVRAM de \"\(config.name)\"?", isPresented: $confirmingNVRAMReset) {
            Button("Redefinir", role: .destructive) { library.resetNVRAM(config.id) }
        } message: {
            Text("Apaga as variáveis do firmware EFI, incluindo a ordem de boot. Na próxima inicialização o firmware procura a ISO/USB primeiro e depois o disco. Use se a VM não der boot pela ISO ou ficar presa no menu do EFI.")
        }
    }

    /// Erros da senha aparecem na própria folha, não no alerta global.
    private func submitPassword(_ mode: VaultPasswordSheet.Mode, _ password: String, _ remember: Bool) async -> Bool {
        library.lastError = nil
        switch mode {
        case .unlock:
            let ok = await library.unlock(config.id, password: password, remember: remember)
            library.lastError = nil
            if ok {
                reloadSnapshots()
                if startAfterUnlock { start() }
            }
            return ok
        case .encrypt:
            await library.encrypt(config.id, password: password, remember: remember)
        case .decrypt:
            await library.decrypt(config.id, password: password)
        }
        reloadSnapshots()
        return library.lastError == nil
    }

    private func start() {
        runner.start()
        if !config.os.usesQEMU { openWindow(value: config.id) }
    }

    private func showScreen() {
        if config.os.usesQEMU {
            runner.showQEMUWindow()
        } else {
            openWindow(value: config.id)
        }
    }

    @ViewBuilder
    private var activeControls: some View {
        Button { showScreen() } label: {
            Label("Mostrar tela", systemImage: "display")
        }
        if runner.state == .paused {
            Button { runner.resume() } label: { Label("Continuar", systemImage: "play.fill") }
        } else {
            Button { runner.pause() } label: { Label("Pausar", systemImage: "pause.fill") }
                .disabled(runner.state != .running)
        }
        if !config.os.usesQEMU {
            Button { runner.suspend() } label: { Label("Suspender", systemImage: "moon.zzz") }
                .disabled(!runner.canSuspend || (runner.state != .running && runner.state != .paused))
                .help(runner.suspendUnavailableReason ?? "Salva o estado e desliga; ao iniciar, volta de onde parou")
        }
        Button { runner.restart() } label: { Label("Reiniciar", systemImage: "arrow.clockwise") }
            .disabled(runner.state != .running && runner.state != .paused)
        Button { runner.requestStop() } label: { Label("Desligar", systemImage: "power") }
            .disabled(runner.state != .running)
        Button(role: .destructive) { runner.forceStop() } label: {
            Label("Forçar", systemImage: "bolt.slash")
        }
    }

    @ViewBuilder
    private var stoppedControls: some View {
        if config.os == .macOS && !config.macOSInstalled {
            Button { runner.installMacOS() } label: {
                Label("Instalar macOS", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button {
                start()
            } label: {
                Label(runner.state == .suspended ? "Retomar" : "Iniciar", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        Button { showingSettings = true } label: { Label("Configurações…", systemImage: "slider.horizontal.3") }
        Menu {
            Button("Clonar") {
                if let id = library.clone(config.id) { onClone(id) }
            }
            .disabled(config.encrypted)
            Button("Exportar / fazer backup…") { export() }
            Divider()
            if config.encrypted {
                if !isLocked {
                    Button("Bloquear") { Task { await library.lock(config.id) } }
                }
                Button("Remover criptografia…") { passwordMode = .decrypt }
            } else {
                Button("Criptografar…") { passwordMode = .encrypt }
            }
            Divider()
            if config.os == .linux {
                Button("Redefinir NVRAM (ordem de boot)…") { confirmingNVRAMReset = true }
            }
            if runner.state == .suspended {
                Divider()
                Button("Descartar estado suspenso", role: .destructive) { runner.discardSavedState() }
            }
        } label: {
            Label("Mais", systemImage: "ellipsis.circle")
        }
        .fixedSize()
    }

    private func export() {
        guard let folder = FilePicker.chooseFolder(title: "Escolha onde salvar a VM", prompt: "Exportar") else { return }
        Task {
            if let destination = await library.export(config.id, to: folder) {
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            }
        }
    }

    private var snapshotsSection: some View {
        Section {
            if isLocked {
                Text("Desbloqueie a VM para ver e criar snapshots.")
                    .foregroundStyle(.secondary)
            } else if snapshots.isEmpty {
                Text("Nenhum snapshot. Crie um antes de instalar algo arriscado.")
                    .foregroundStyle(.secondary)
            }
            ForEach(snapshots) { snapshot in
                HStack {
                    Image(systemName: snapshot.includesMachineState ? "memorychip" : "externaldrive")
                        .foregroundStyle(.secondary)
                        .help(snapshot.includesMachineState ? "Inclui memória (VM suspensa)" : "Só disco")
                    VStack(alignment: .leading) {
                        Text(snapshot.name)
                        Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restaurar") { restoring = snapshot }
                        .disabled(isActive)
                    Button(role: .destructive) {
                        library.deleteSnapshot(snapshot, for: config.id)
                        reloadSnapshots()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            HStack {
                Text("Snapshots")
                Spacer()
                Button("Criar snapshot…") {
                    snapshotName = "Snapshot \(snapshots.count + 1)"
                    namingSnapshot = true
                }
                .disabled(isActive || isLocked)
                .help(isActive ? "Desligue ou suspenda a VM para criar um snapshot" : "")
            }
        }
    }

    private func reloadSnapshots() {
        snapshots = library.snapshots(for: config.id)
    }

    private func edit(_ change: (inout VMConfig) -> Void) {
        var updated = config
        change(&updated)
        library.update(updated)
    }
}

struct StatusBadge: View {
    let state: VMRunState

    private var color: Color {
        switch state {
        case .running: return .green
        case .starting, .stopping, .saving: return .orange
        case .downloading, .installing: return .blue
        case .paused, .suspended: return .yellow
        case .error: return .red
        case .stopped: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(state.label).font(.callout).foregroundStyle(.secondary)
        }
    }
}

