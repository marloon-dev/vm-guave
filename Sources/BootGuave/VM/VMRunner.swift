import Foundation
import Virtualization

enum VMRunState: Equatable {
    case stopped
    case suspended
    case starting
    case running
    case paused
    case saving
    case stopping
    case downloading
    case installing
    case error(String)

    var isActive: Bool {
        switch self {
        case .starting, .running, .paused, .saving, .stopping, .downloading, .installing: return true
        case .stopped, .suspended, .error: return false
        }
    }

    var label: String {
        switch self {
        case .stopped: return String(localized: "Desligada")
        case .suspended: return String(localized: "Suspensa")
        case .starting: return String(localized: "Iniciando…")
        case .running: return String(localized: "Em execução")
        case .paused: return String(localized: "Pausada")
        case .saving: return String(localized: "Suspendendo…")
        case .stopping: return String(localized: "Desligando…")
        case .downloading: return String(localized: "Baixando macOS…")
        case .installing: return String(localized: "Instalando macOS…")
        case .error: return String(localized: "Erro")
        }
    }
}

/// Controla o ciclo de vida de uma VM. VZVirtualMachine é usada sempre na main queue.
@MainActor
final class VMRunner: NSObject, ObservableObject, VZVirtualMachineDelegate {
    @Published var config: VMConfig
    @Published private(set) var state: VMRunState {
        didSet { logTransition(from: oldValue) }
    }
    @Published private(set) var virtualMachine: VZVirtualMachine?
    /// Aviso não fatal (ex.: não deu para suspender, mas a VM segue rodando).
    @Published var notice: String?
    /// 0...1 durante download/instalação do macOS.
    @Published private(set) var progress: Double?
    /// VM criptografada bloqueada e sem senha no Keychain: a interface pede a senha.
    @Published var passwordNeeded = false

    /// Chamado quando o próprio runner grava a config (ex.: instalação do macOS).
    var onConfigSaved: (() -> Void)?

    /// Registra na Atividade só as mudanças que interessam (pausar e retomar ficam de fora).
    private func logTransition(from old: VMRunState) {
        guard old != state else { return }
        let name = config.name
        switch state {
        case .running where old == .starting:
            ActivityLog.shared.add(.started, name)
        case .stopped where old.isActive:
            ActivityLog.shared.add(.stopped, name)
        case .suspended where old == .saving:
            ActivityLog.shared.add(.suspended, name)
        case .error:
            ActivityLog.shared.add(.failed, name)
        default:
            break
        }
    }

    private var bundle: VMBundle { VMBundle(url: VMBundle.url(for: config.id)) }
    private var downloader: FileDownloader?
    private var installObservation: NSKeyValueObservation?
    /// Motor QEMU (VMs Windows).
    private var qemu: QEMUMachine?

    init(config: VMConfig) {
        self.config = config
        self.state = VMBundle(url: VMBundle.url(for: config.id)).hasSavedState ? .suspended : .stopped
    }

    /// Liga a VM; se houver estado suspenso, retoma de onde parou.
    func start() {
        guard !state.isActive else { return }
        notice = nil
        if bundle.isEncrypted && !bundle.isUnlocked {
            unlockThenStart()
            return
        }
        if config.os.usesQEMU {
            startQEMU()
            return
        }
        do {
            if config.os == .macOS && !config.macOSInstalled {
                throw BootGuaveError.macOSNotInstalled
            }
            let vzConfig = try VMConfigurationBuilder.build(for: config, bundle: bundle)
            let vm = VZVirtualMachine(configuration: vzConfig)
            vm.delegate = self
            virtualMachine = vm
            state = .starting
            if bundle.hasSavedState {
                restore(vm)
            } else {
                boot(vm)
            }
        } catch {
            fail(error)
        }
    }

    /// Tenta a senha do Keychain; sem ela (ou se falhar), pede a senha na interface.
    private func unlockThenStart() {
        guard let password = VaultKeychain.load(for: config.id) else {
            passwordNeeded = true
            return
        }
        let bundle = bundle
        state = .starting
        Task {
            do {
                try await VMVault.attach(bundle.vaultURL, at: bundle.mountURL, password: password)
                state = .stopped
                refreshState()
                start()
            } catch {
                state = .stopped
                passwordNeeded = true
            }
        }
    }

    private func startQEMU() {
        let machine = QEMUMachine(config: config, bundle: bundle)
        machine.onExit = { [weak self] _ in
            guard let self, self.qemu === machine else { return }
            // Falha na partida já foi tratada pelo catch abaixo.
            if self.state == .starting { return }
            self.didStop()
        }
        qemu = machine
        state = .starting
        Task {
            do {
                try await machine.start()
                state = .running
                machine.showWindow()
            } catch {
                qemu = nil
                fail(error)
            }
        }
    }

    /// Comando para o QEMU; erro vira aviso, sem derrubar o estado.
    private func qemuCommand(_ body: @escaping (QEMUMachine) async throws -> Void, then newState: VMRunState? = nil) {
        guard let qemu else { return }
        Task {
            do {
                try await body(qemu)
                if let newState { state = newState }
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    /// VMs Windows: a tela é a janela do QEMU.
    func showQEMUWindow() {
        qemu?.showWindow()
    }

    private func boot(_ vm: VZVirtualMachine) {
        vm.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.state = .running
            case .failure(let error): self.fail(error)
            }
        }
    }

    private func restore(_ vm: VZVirtualMachine) {
        vm.restoreMachineStateFrom(url: bundle.savedStateURL) { [weak self] error in
            guard let self else { return }
            // O estado salvo vale uma vez só: assim que a VM roda, o disco diverge dele.
            self.bundle.discardSavedState()
            if let error {
                self.notice = String(localized: "Não deu para retomar o estado salvo (\(error.localizedDescription)). Iniciando do zero.")
                self.virtualMachine = nil
                self.state = .stopped
                self.start()
                return
            }
            vm.resume { [weak self] result in
                switch result {
                case .success: self?.state = .running
                case .failure(let error): self?.fail(error)
                }
            }
        }
    }

    func pause() {
        if qemu != nil { qemuCommand({ try await $0.pause() }, then: .paused); return }
        guard let vm = virtualMachine, vm.canPause else { return }
        vm.pause { [weak self] result in
            if case .failure(let error) = result { self?.fail(error) } else { self?.state = .paused }
        }
    }

    func resume() {
        if qemu != nil { qemuCommand({ try await $0.resume() }, then: .running); return }
        guard let vm = virtualMachine, vm.canResume else { return }
        vm.resume { [weak self] result in
            if case .failure(let error) = result { self?.fail(error) } else { self?.state = .running }
        }
    }

    /// O framework da Apple recusa salvar o estado de VMs em rede vmnet ("permission denied");
    /// no QEMU o suspender não foi implementado.
    var canSuspend: Bool {
        !config.os.usesQEMU && config.networkMode == .nat
    }

    var suspendUnavailableReason: String? {
        if config.os.usesQEMU { return QEMUError.unsupported(String(localized: "Suspender")).localizedDescription }
        if config.networkMode != .nat {
            return String(localized: "Suspender não é possível com rede personalizada: o macOS não salva o estado de VMs em redes vmnet. Use NAT para poder suspender.")
        }
        return nil
    }

    /// Salva memória e dispositivos em disco e desliga; o próximo start() retoma daqui.
    func suspend() {
        if let reason = suspendUnavailableReason {
            notice = reason
            return
        }
        guard let vm = virtualMachine, state == .running || state == .paused else { return }
        let wasPaused = state == .paused
        state = .saving
        let save = { [weak self] in
            guard let self else { return }
            vm.saveMachineStateTo(url: self.bundle.savedStateURL) { [weak self] error in
                guard let self else { return }
                if let error {
                    self.bundle.discardSavedState()
                    self.notice = String(localized: "Não foi possível suspender: \(error.localizedDescription)")
                    // Volta ao estado de antes, em vez de deixar a VM congelada.
                    self.state = .paused
                    if !wasPaused { self.resume() }
                    return
                }
                vm.stop { [weak self] _ in self?.didStop() }
            }
        }
        if wasPaused {
            save()
        } else {
            vm.pause { [weak self] result in
                if case .failure(let error) = result {
                    self?.notice = String(localized: "Não foi possível suspender: \(error.localizedDescription)")
                    self?.state = .running
                    return
                }
                save()
            }
        }
    }

    /// Reinício "a frio": desliga na hora e liga de novo.
    func restart() {
        if qemu != nil { qemuCommand({ try await $0.reset() }); return }
        guard let vm = virtualMachine, vm.canStop else { return }
        state = .stopping
        vm.stop { [weak self] error in
            guard let self else { return }
            if let error { self.fail(error); return }
            self.virtualMachine = nil
            self.state = .stopped
            self.start()
        }
    }

    /// Pede ao sistema convidado para desligar (como apertar o botão de energia).
    func requestStop() {
        if qemu != nil { qemuCommand({ try await $0.requestStop() }, then: .stopping); return }
        guard let vm = virtualMachine, vm.canRequestStop else { return }
        do {
            try vm.requestStop()
            state = .stopping
        } catch {
            fail(error)
        }
    }

    /// Desliga na hora, como tirar da tomada.
    func forceStop() {
        if let qemu { Task { await qemu.forceStop() }; return }
        guard let vm = virtualMachine, vm.canStop else { return }
        vm.stop { [weak self] error in
            if let error { self?.fail(error) } else { self?.didStop() }
        }
    }

    // MARK: Instalação do macOS

    /// Baixa o IPSW (se preciso), prepara o Mac virtual e roda o instalador da Apple.
    func installMacOS() {
        guard config.os == .macOS, !state.isActive else { return }
        notice = nil
        Task { await performMacOSInstall() }
    }

    func cancelDownload() {
        downloader?.cancel()
    }

    private func performMacOSInstall() async {
        do {
            let ipsw = try await ensureRestoreImage()

            state = .installing
            progress = 0
            let image = try await VZMacOSRestoreImage.image(from: ipsw)
            guard let requirements = image.mostFeaturefulSupportedConfiguration,
                  requirements.hardwareModel.isSupported else {
                throw BootGuaveError.macOSHardwareUnsupported
            }
            try bundle.prepareMacPlatform(hardwareModel: requirements.hardwareModel)

            var updated = config
            updated.macOSInstalled = false
            updated.cpuCount = max(updated.cpuCount, requirements.minimumSupportedCPUCount)
            let minimumGB = Int((Double(requirements.minimumSupportedMemorySize) / 1_073_741_824).rounded(.up))
            updated.memoryGB = max(updated.memoryGB, minimumGB)
            try saveConfig(updated)

            let vm = VZVirtualMachine(configuration: try VMConfigurationBuilder.build(for: config, bundle: bundle))
            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
            installObservation = installer.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                let value = progress.fractionCompleted
                Task { @MainActor in self?.progress = value }
            }
            try await installer.install()
            installObservation = nil

            updated = config
            updated.macOSInstalled = true
            try saveConfig(updated)
            progress = nil
            state = .stopped
        } catch {
            installObservation = nil
            progress = nil
            fail(error)
        }
    }

    private func ensureRestoreImage() async throws -> URL {
        if let path = config.installerIPSWPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        state = .downloading
        progress = 0
        let latest = try await VZMacOSRestoreImage.latestSupported
        let destination = DownloadLocations.ipswFolder.appendingPathComponent("macOS-\(latest.buildVersion).ipsw")
        if !FileManager.default.fileExists(atPath: destination.path) {
            let downloader = FileDownloader(destination: destination) { [weak self] value in
                Task { @MainActor in self?.progress = value }
            }
            self.downloader = downloader
            defer { self.downloader = nil }
            _ = try await downloader.download(from: latest.url)
        }
        var updated = config
        updated.installerIPSWPath = destination.path
        try saveConfig(updated)
        return destination
    }

    private func saveConfig(_ updated: VMConfig) throws {
        try bundle.save(updated)
        config = updated
        onConfigSaved?()
    }

    func discardSavedState() {
        guard state == .suspended else { return }
        bundle.discardSavedState()
        state = .stopped
    }

    /// Recalcula o estado após mudanças em disco (snapshot restaurado, config editada).
    func refreshState() {
        guard !state.isActive else { return }
        state = bundle.hasSavedState ? .suspended : .stopped
    }

    private func didStop() {
        virtualMachine = nil
        qemu = nil
        state = bundle.hasSavedState ? .suspended : .stopped
    }

    private func fail(_ error: Error) {
        state = .error(error.localizedDescription)
        virtualMachine = nil
    }

    // MARK: VZVirtualMachineDelegate (chamado na main queue da VM)

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { didStop() }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated { fail(error) }
    }
}
