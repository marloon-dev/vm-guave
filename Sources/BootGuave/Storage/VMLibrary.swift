import Foundation
import Virtualization

/// Lista de VMs em disco + sessões em execução.
@MainActor
final class VMLibrary: ObservableObject {
    /// Instância única: usada pela interface e pelo servidor do bgctl.
    static let shared = VMLibrary()

    @Published private(set) var configs: [VMConfig] = []
    @Published var lastError: String?
    /// Operação longa em andamento (exportar/importar), mostrada como overlay.
    @Published private(set) var busyMessage: String?
    /// 0...1 quando a operação longa sabe o próprio progresso (ex.: conversão de disco).
    @Published private(set) var busyProgress: Double?

    private var runners: [UUID: VMRunner] = [:]

    init() {
        reload()
    }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: VMBundle.libraryURL, withIntermediateDirectories: true)
        let urls = (try? fm.contentsOfDirectory(at: VMBundle.libraryURL, includingPropertiesForKeys: nil)) ?? []
        configs = urls
            .filter { $0.pathExtension == "bootguave" }
            .compactMap { try? VMBundle(url: $0).loadConfig() }
            .sorted { $0.createdAt < $1.createdAt }
        for config in configs {
            runners[config.id]?.config = config
        }
    }

    func config(for id: UUID) -> VMConfig? {
        configs.first { $0.id == id }
    }

    private func bundle(_ id: UUID) -> VMBundle {
        VMBundle(url: VMBundle.url(for: id))
    }

    /// Executa uma operação de disco e mostra o erro no alerta global, se houver.
    @discardableResult
    private func attempt<T>(_ body: () throws -> T) -> T? {
        do {
            return try body()
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func ensureNotActive(_ id: UUID) throws {
        if runners[id]?.state.isActive == true { throw BootGuaveError.vmIsRunning }
    }

    private func ensureUnlocked(_ id: UUID) throws {
        if !bundle(id).isUnlocked { throw VaultError.locked }
    }

    func isLocked(_ id: UUID) -> Bool {
        !bundle(id).isUnlocked
    }

    func create(_ config: VMConfig) {
        attempt { _ = try VMBundle.create(config) }
        reload()
    }

    func update(_ config: VMConfig) {
        attempt { try bundle(config.id).save(config) }
        reload()
    }

    /// Salva configurações editadas. Mudar hardware invalida o estado suspenso.
    func applySettings(_ config: VMConfig) {
        guard let old = self.config(for: config.id) else { return }
        var config = config
        if config.networkMode != .nat && config.networkSubnet == nil {
            config.networkSubnet = VMNetworkFactory.allocateSubnet(excluding: configs.compactMap(\.networkSubnet))
        }
        attempt {
            try ensureNotActive(config.id)
            let bundle = bundle(config.id)
            if config.diskGB > old.diskGB || config.extraDisks != old.extraDisks {
                try ensureUnlocked(config.id)
            }
            if config.diskGB > old.diskGB {
                try bundle.growDisk(toGB: config.diskGB)
            }
            try bundle.syncExtraDisks(from: old.extraDisks, to: config.extraDisks)
            var hardwareChanged = old
            hardwareChanged.name = config.name
            hardwareChanged.autoStart = config.autoStart
            if hardwareChanged != config && bundle.isUnlocked {
                bundle.discardSavedState()
            }
            try bundle.save(config)
        }
        reload()
        runners[config.id]?.refreshState()
    }

    func delete(_ id: UUID) {
        guard attempt({ try ensureNotActive(id) }) != nil else { return }
        runners[id] = nil
        let bundle = bundle(id)
        if bundle.isEncrypted && bundle.isUnlocked {
            VMVault.detachSync(bundle.mountURL)
        }
        VaultKeychain.delete(for: id)
        attempt { try FileManager.default.removeItem(at: bundle.url) }
        reload()
    }

    /// Clone completo via APFS (instantâneo, ocupa espaço só conforme diverge).
    /// Recebe MAC e identificador de máquina novos para não conflitar com a original.
    func clone(_ id: UUID) -> UUID? {
        guard let source = config(for: id) else { return nil }
        let newID = attempt { () -> UUID in
            try ensureNotActive(id)
            if source.encrypted { throw BootGuaveError.encryptedNotSupported("Clonar") }
            var copy = source
            copy.networkSubnet = nil
            if copy.networkMode != .nat {
                copy.networkSubnet = VMNetworkFactory.allocateSubnet(excluding: configs.compactMap(\.networkSubnet))
            }
            copy.id = UUID()
            copy.name = "\(source.name) (cópia)"
            copy.macAddress = VZMACAddress.randomLocallyAdministered().string
            copy.createdAt = Date()

            let from = bundle(id)
            let to = bundle(copy.id)
            try FileManager.default.createDirectory(at: to.url, withIntermediateDirectories: true)
            do {
                // machine-id fica de fora: o clone gera um identificador novo ao iniciar.
                for file in VMBundle.machineFiles {
                    let source = from.url.appendingPathComponent(file)
                    if FileManager.default.fileExists(atPath: source.path) {
                        try FileCloner.clone(source, to: to.url.appendingPathComponent(file))
                    }
                }
                try to.save(copy)
            } catch {
                try? FileManager.default.removeItem(at: to.url)
                throw error
            }
            return copy.id
        }
        reload()
        return newID
    }

    // MARK: Snapshots

    func snapshots(for id: UUID) -> [VMSnapshot] {
        bundle(id).snapshots()
    }

    func createSnapshot(for id: UUID, named name: String) {
        attempt {
            try ensureNotActive(id)
            try ensureUnlocked(id)
            _ = try bundle(id).createSnapshot(named: name)
        }
    }

    func restoreSnapshot(_ snapshot: VMSnapshot, for id: UUID) {
        guard let current = config(for: id) else { return }
        attempt {
            try ensureNotActive(id)
            try ensureUnlocked(id)
            let bundle = bundle(id)
            try bundle.restoreSnapshot(snapshot)
            // Nome e ID não fazem parte do "estado" da máquina; mantém os atuais
            // (o ID pode diferir se a VM foi importada com ID novo).
            var restored = try bundle.loadConfig()
            restored.id = current.id
            restored.name = current.name
            restored.encrypted = current.encrypted
            restored.networkSubnet = current.networkSubnet
            try bundle.save(restored)
        }
        reload()
        runners[id]?.refreshState()
    }

    func deleteSnapshot(_ snapshot: VMSnapshot, for id: UUID) {
        attempt { try bundle(id).deleteSnapshot(snapshot) }
    }

    func resetNVRAM(_ id: UUID) {
        attempt {
            try ensureNotActive(id)
            try ensureUnlocked(id)
            bundle(id).resetNVRAM()
        }
    }

    // MARK: Exportar / importar

    /// Exporta (ou faz backup) para <pasta>/<nome>.bootguave, com snapshots e estado suspenso.
    func export(_ id: UUID, to folder: URL) async -> URL? {
        guard let config = config(for: id),
              attempt({ try ensureNotActive(id) }) != nil else { return nil }
        var destination = folder.appendingPathComponent("\(config.name).bootguave")
        if FileManager.default.fileExists(atPath: destination.path) {
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: "-")
            destination = folder.appendingPathComponent("\(config.name) \(stamp).bootguave")
        }
        let source = bundle(id).url
        let target = destination
        busyMessage = "Exportando \(config.name)…"
        defer { busyMessage = nil }
        do {
            // Cofre montado não pode ser copiado com segurança; bloqueia antes.
            if bundle(id).isEncrypted && bundle(id).isUnlocked {
                try await VMVault.detach(bundle(id).mountURL)
            }
            try await Task.detached { try FileCloner.copyTree(source, to: target) }.value
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Importa um .bootguave. Se já existir uma VM com o mesmo ID (ex.: backup da mesma VM),
    /// a importada vira uma VM nova, com ID, MAC e identificador de máquina próprios.
    func importVM(from source: URL) async -> UUID? {
        let source = source.standardizedFileURL
        if source.deletingLastPathComponent().standardizedFileURL == VMBundle.libraryURL.standardizedFileURL {
            return (try? VMBundle(url: source).loadConfig())?.id
        }
        guard let original = try? VMBundle(url: source).loadConfig() else {
            lastError = BootGuaveError.notAVirtualMachine(source.path).localizedDescription
            return nil
        }
        var config = original
        let duplicate = configs.contains { $0.id == original.id }
        if duplicate {
            config.id = UUID()
            config.name = "\(original.name) (importada)"
            config.macAddress = VZMACAddress.randomLocallyAdministered().string
        }
        let destination = VMBundle(url: VMBundle.url(for: config.id))
        busyMessage = "Importando \(config.name)…"
        defer { busyMessage = nil }
        do {
            try FileManager.default.createDirectory(at: VMBundle.libraryURL, withIntermediateDirectories: true)
            let target = destination.url
            try await Task.detached { try FileCloner.copyTree(source, to: target) }.value
            if duplicate && !destination.isEncrypted {
                try? FileManager.default.removeItem(at: destination.machineIdentifierURL)
                destination.discardSavedState()
            }
            if config.networkMode != .nat {
                config.networkSubnet = VMNetworkFactory.allocateSubnet(excluding: configs.compactMap(\.networkSubnet))
            }
            try destination.save(config)
        } catch {
            try? FileManager.default.removeItem(at: destination.url)
            lastError = error.localizedDescription
            return nil
        }
        reload()
        return config.id
    }

    /// Cria uma VM a partir de um disco de outro virtualizador (qcow2, vmdk, vdi, vhdx, raw).
    func importDisk(from source: URL, os: GuestOS, name: String) async -> UUID? {
        var config = VMConfig(
            id: UUID(),
            name: name,
            os: os,
            cpuCount: min(4, HostLimits.cpuRange.upperBound),
            memoryGB: min(os == .windows ? 8 : 4, HostLimits.memoryGBRange.upperBound),
            diskGB: 0,
            installerISOPath: nil,
            sharedFolderPath: nil,
            macAddress: VZMACAddress.randomLocallyAdministered().string,
            displayWidth: 1920,
            displayHeight: 1200,
            createdAt: Date()
        )
        let bundle = bundle(config.id)
        busyMessage = "Convertendo \(source.lastPathComponent)…"
        busyProgress = 0
        defer { busyMessage = nil; busyProgress = nil }
        do {
            let size = try await DiskImporter.virtualSize(of: source)
            config.diskGB = max(1, Int((Double(size) / 1_073_741_824).rounded(.up)))
            try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
            let destination = os.usesQEMU ? bundle.qcow2DiskURL : bundle.diskURL
            if os.usesQEMU {
                let vars = try QEMUTools.require(QEMUTools.firmwareVarsTemplate, "Firmware EFI do QEMU")
                try FileManager.default.copyItem(at: vars, to: bundle.efiVariableStoreURL)
            }
            try await DiskImporter.convert(source, to: destination, format: os.usesQEMU ? "qcow2" : "raw") { value in
                Task { @MainActor in VMLibrary.shared.busyProgress = value }
            }
            try bundle.save(config)
        } catch {
            try? FileManager.default.removeItem(at: bundle.url)
            lastError = error.localizedDescription
            return nil
        }
        reload()
        return config.id
    }

    // MARK: Criptografia

    /// Move os arquivos da máquina para um cofre AES-256. Os originais só são apagados
    /// depois que tudo foi copiado; se algo falhar, o cofre é descartado e nada se perde.
    func encrypt(_ id: UUID, password: String, remember: Bool) async {
        guard var config = config(for: id), attempt({ try ensureNotActive(id) }) != nil else { return }
        let bundle = bundle(id)
        guard !bundle.isEncrypted else { return }
        busyMessage = "Criptografando \(config.name)…"
        defer { busyMessage = nil }
        do {
            try await VMVault.create(at: bundle.vaultURL, volumeName: "VM Guave \(config.name)", password: password)
            try await VMVault.attach(bundle.vaultURL, at: bundle.mountURL, password: password)
            let plain = bundle.url
            let vault = bundle.mountURL
            try await Task.detached {
                let fm = FileManager.default
                let present = VMBundle.vaultFiles.filter { fm.fileExists(atPath: plain.appendingPathComponent($0).path) }
                for name in present {
                    try FileCloner.copyTree(plain.appendingPathComponent(name), to: vault.appendingPathComponent(name))
                }
                fm.createFile(atPath: vault.appendingPathComponent(VMVault.markerName).path, contents: nil)
                for name in present {
                    try fm.removeItem(at: plain.appendingPathComponent(name))
                }
            }.value
            config.encrypted = true
            try bundle.save(config)
            if remember { VaultKeychain.save(password, for: id) }
        } catch {
            if !FileManager.default.fileExists(atPath: bundle.mountURL.appendingPathComponent(VMVault.markerName).path) {
                try? await VMVault.detach(bundle.mountURL)
                try? FileManager.default.removeItem(at: bundle.vaultURL)
            }
            lastError = error.localizedDescription
        }
        reload()
        runners[id]?.refreshState()
    }

    /// Tira os arquivos do cofre e apaga a imagem criptografada.
    func decrypt(_ id: UUID, password: String) async {
        guard var config = config(for: id), attempt({ try ensureNotActive(id) }) != nil else { return }
        let bundle = bundle(id)
        guard bundle.isEncrypted else { return }
        busyMessage = "Removendo criptografia de \(config.name)…"
        defer { busyMessage = nil }
        let plain = bundle.url
        let vault = bundle.mountURL
        var copied: [String] = []
        do {
            if !bundle.isUnlocked {
                try await VMVault.attach(bundle.vaultURL, at: vault, password: password)
            }
            copied = try await Task.detached { () -> [String] in
                let fm = FileManager.default
                let present = VMBundle.vaultFiles.filter { fm.fileExists(atPath: vault.appendingPathComponent($0).path) }
                for name in present {
                    try FileCloner.copyTree(vault.appendingPathComponent(name), to: plain.appendingPathComponent(name))
                }
                return present
            }.value
            try await VMVault.detach(vault)
            try FileManager.default.removeItem(at: bundle.vaultURL)
            config.encrypted = false
            try bundle.save(config)
            VaultKeychain.delete(for: id)
        } catch {
            for name in copied { try? FileManager.default.removeItem(at: plain.appendingPathComponent(name)) }
            lastError = error.localizedDescription
        }
        reload()
        runners[id]?.refreshState()
    }

    /// Monta o cofre. Retorna false se a senha estiver errada.
    @discardableResult
    func unlock(_ id: UUID, password: String, remember: Bool) async -> Bool {
        let bundle = bundle(id)
        guard bundle.isEncrypted, !bundle.isUnlocked else { return true }
        do {
            try await VMVault.attach(bundle.vaultURL, at: bundle.mountURL, password: password)
            guard bundle.isUnlocked else {
                try? await VMVault.detach(bundle.mountURL)
                throw VaultError.wrongPassword
            }
            if remember { VaultKeychain.save(password, for: id) }
            runners[id]?.refreshState()
            objectWillChange.send()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func lock(_ id: UUID) async {
        let bundle = bundle(id)
        guard bundle.isEncrypted, bundle.isUnlocked,
              attempt({ try ensureNotActive(id) }) != nil else { return }
        do {
            try await VMVault.detach(bundle.mountURL)
        } catch {
            lastError = error.localizedDescription
        }
        runners[id]?.refreshState()
        objectWillChange.send()
    }

    /// Ao encerrar o app: nenhum cofre fica montado.
    func lockAllSync() {
        for config in configs where config.encrypted {
            let bundle = bundle(config.id)
            if bundle.isUnlocked { VMVault.detachSync(bundle.mountURL) }
        }
    }

    // MARK: Sessões

    var activeRunners: [VMRunner] {
        runners.values.filter { $0.state.isActive }
    }

    func startAutoStartVMs() {
        for config in configs where config.autoStart {
            runner(for: config.id)?.start()
        }
    }

    /// Runner único por VM, compartilhado entre a lista e a janela da tela.
    func runner(for id: UUID) -> VMRunner? {
        if let existing = runners[id] { return existing }
        guard let config = config(for: id) else { return nil }
        let runner = VMRunner(config: config)
        runner.onConfigSaved = { [weak self] in self?.reload() }
        runners[id] = runner
        return runner
    }
}
