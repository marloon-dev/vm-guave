import Darwin
import Foundation
import Virtualization

/// Pacote em disco de uma VM:
/// <id>.bootguave/{config.json, disk.img, disks/, efi-vars.fd, machine-id, state.vzvmsave?, snapshots/}
/// VMs macOS têm ainda hardware-model e aux.img (NVRAM do Mac virtual) no lugar de efi-vars.fd.
/// VMs Windows (QEMU) usam disk.qcow2, efi-vars.fd do QEMU e tpm/.
/// Criptografada: tudo menos config.json fica em vault.sparsebundle, montado em Mounts/<id>.
struct VMBundle {
    let url: URL

    var configURL: URL { url.appendingPathComponent("config.json") }

    // MARK: Cofre (criptografia)

    var vaultURL: URL { url.appendingPathComponent("vault.sparsebundle") }
    var mountURL: URL {
        Self.libraryURL.deletingLastPathComponent()
            .appendingPathComponent("Mounts/\(url.deletingPathExtension().lastPathComponent)", isDirectory: true)
    }
    var isEncrypted: Bool { FileManager.default.fileExists(atPath: vaultURL.path) }
    var isUnlocked: Bool {
        !isEncrypted || FileManager.default.fileExists(atPath: mountURL.appendingPathComponent(VMVault.markerName).path)
    }
    /// Onde ficam os arquivos da máquina: o próprio pacote, ou o cofre montado.
    var dataURL: URL { isEncrypted ? mountURL : url }

    var diskURL: URL { dataURL.appendingPathComponent("disk.img") }
    var qcow2DiskURL: URL { dataURL.appendingPathComponent("disk.qcow2") }
    var extraDisksURL: URL { dataURL.appendingPathComponent("disks", isDirectory: true) }
    var efiVariableStoreURL: URL { dataURL.appendingPathComponent("efi-vars.fd") }
    var machineIdentifierURL: URL { dataURL.appendingPathComponent("machine-id") }
    var hardwareModelURL: URL { dataURL.appendingPathComponent("hardware-model") }
    var auxiliaryStorageURL: URL { dataURL.appendingPathComponent("aux.img") }
    var tpmStateURL: URL { dataURL.appendingPathComponent("tpm", isDirectory: true) }
    /// Memória e dispositivos da VM suspensa. Só vale para o disco no estado em que foi salvo.
    var savedStateURL: URL { dataURL.appendingPathComponent("state.vzvmsave") }

    /// Arquivos que definem o estado da máquina (copiados em snapshots e clones).
    static let machineFiles = ["disk.img", "disk.qcow2", "disks", "efi-vars.fd", "hardware-model", "aux.img", "tpm"]
    /// Tudo o que vai para dentro do cofre ao criptografar.
    static let vaultFiles = machineFiles + ["machine-id", "state.vzvmsave", "snapshots"]

    static var libraryURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Boot Guave/VMs", isDirectory: true)
    }

    static func url(for id: UUID) -> URL {
        libraryURL.appendingPathComponent("\(id.uuidString).bootguave", isDirectory: true)
    }

    func extraDiskURL(_ disk: ExtraDisk) -> URL {
        extraDisksURL.appendingPathComponent("\(disk.id.uuidString).img")
    }

    func loadConfig() throws -> VMConfig {
        try JSONDecoder.iso8601.decode(VMConfig.self, from: Data(contentsOf: configURL))
    }

    func save(_ config: VMConfig) throws {
        try JSONEncoder.iso8601.encode(config).write(to: configURL, options: .atomic)
    }

    /// Cria o pacote: diretório, disco esparso (não ocupa espaço até a VM escrever) e config.
    /// Windows: disco qcow2 e NVRAM do QEMU (o TPM é criado no primeiro boot).
    static func create(_ config: VMConfig) throws -> VMBundle {
        let bundle = VMBundle(url: url(for: config.id))
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        if config.os.usesQEMU {
            let qemuImg = try QEMUTools.require(QEMUTools.qemuImg, "qemu-img")
            let vars = try QEMUTools.require(QEMUTools.firmwareVarsTemplate, String(localized: "Firmware EFI do QEMU"))
            try runSync(qemuImg, ["create", "-q", "-f", "qcow2", bundle.qcow2DiskURL.path, "\(config.diskGB)G"])
            try FileManager.default.copyItem(at: vars, to: bundle.efiVariableStoreURL)
        } else {
            try createBlankDisk(at: bundle.diskURL, sizeGB: config.diskGB)
        }
        try bundle.save(config)
        return bundle
    }

    /// Para comandos rápidos (criar/redimensionar qcow2).
    static func runSync(_ tool: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw QEMUError.toolFailed(tool.lastPathComponent, message)
        }
    }

    static func createBlankDisk(at url: URL, sizeGB: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw BootGuaveError.diskCreationFailed
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(sizeGB) * 1024 * 1024 * 1024)
    }

    var hasSavedState: Bool {
        FileManager.default.fileExists(atPath: savedStateURL.path)
    }

    func discardSavedState() {
        try? FileManager.default.removeItem(at: savedStateURL)
    }

    /// Só aumenta: diminuir cortaria partições do convidado.
    func growDisk(toGB gb: Int) throws {
        if FileManager.default.fileExists(atPath: qcow2DiskURL.path) {
            let qemuImg = try QEMUTools.require(QEMUTools.qemuImg, "qemu-img")
            try Self.runSync(qemuImg, ["resize", "-q", qcow2DiskURL.path, "\(gb)G"])
            return
        }
        let handle = try FileHandle(forWritingTo: diskURL)
        defer { try? handle.close() }
        let newSize = UInt64(gb) * 1024 * 1024 * 1024
        if try handle.seekToEnd() < newSize {
            try handle.truncate(atOffset: newSize)
        }
    }

    /// Cria arquivos dos discos novos e apaga os removidos.
    func syncExtraDisks(from old: [ExtraDisk], to new: [ExtraDisk]) throws {
        for disk in new where !old.contains(where: { $0.id == disk.id }) {
            try Self.createBlankDisk(at: extraDiskURL(disk), sizeGB: disk.sizeGB)
        }
        for disk in old where !new.contains(where: { $0.id == disk.id }) {
            try? FileManager.default.removeItem(at: extraDiskURL(disk))
        }
    }

    /// Apaga a NVRAM: o firmware volta à ordem de boot padrão (mídia removível/ISO primeiro).
    func resetNVRAM() {
        try? FileManager.default.removeItem(at: efiVariableStoreURL)
    }

    // MARK: Identidade da máquina

    func machineIdentifier() throws -> VZGenericMachineIdentifier {
        if let data = try? Data(contentsOf: machineIdentifierURL),
           let id = VZGenericMachineIdentifier(dataRepresentation: data) {
            return id
        }
        let id = VZGenericMachineIdentifier()
        try id.dataRepresentation.write(to: machineIdentifierURL)
        return id
    }

    func macMachineIdentifier() throws -> VZMacMachineIdentifier {
        if let data = try? Data(contentsOf: machineIdentifierURL),
           let id = VZMacMachineIdentifier(dataRepresentation: data) {
            return id
        }
        let id = VZMacMachineIdentifier()
        try id.dataRepresentation.write(to: machineIdentifierURL)
        return id
    }

    func efiVariableStore() throws -> VZEFIVariableStore {
        if FileManager.default.fileExists(atPath: efiVariableStoreURL.path) {
            return VZEFIVariableStore(url: efiVariableStoreURL)
        }
        return try VZEFIVariableStore(creatingVariableStoreAt: efiVariableStoreURL)
    }

    /// Grava o modelo de hardware e cria NVRAM e identificador novos para um Mac virtual.
    func prepareMacPlatform(hardwareModel: VZMacHardwareModel) throws {
        try hardwareModel.dataRepresentation.write(to: hardwareModelURL)
        try? FileManager.default.removeItem(at: auxiliaryStorageURL)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: auxiliaryStorageURL, hardwareModel: hardwareModel, options: [])
        try? FileManager.default.removeItem(at: machineIdentifierURL)
        _ = try macMachineIdentifier()
    }

    func macHardwareModel() throws -> VZMacHardwareModel {
        guard let data = try? Data(contentsOf: hardwareModelURL),
              let model = VZMacHardwareModel(dataRepresentation: data) else {
            throw BootGuaveError.macOSNotInstalled
        }
        guard model.isSupported else { throw BootGuaveError.macOSHardwareUnsupported }
        return model
    }
}

enum FileCloner {
    /// clonefile() no APFS; cópia normal como reserva (ex.: volume HFS+ externo).
    static func clone(_ source: URL, to destination: URL) throws {
        if Darwin.clonefile(source.path, destination.path, 0) == 0 { return }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// Cópia recursiva para exportar/importar: clona no mesmo volume APFS e,
    /// em outro disco, preserva os "buracos" dos discos esparsos.
    static func copyTree(_ source: URL, to destination: URL) throws {
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_DATA_SPARSE)
        guard copyfile(source.path, destination.path, nil, flags) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Falha ao copiar para \(destination.path): \(String(cString: strerror(errno)))")
            ])
        }
    }
}

enum BootGuaveError: LocalizedError {
    case diskCreationFailed
    case isoNotFound(String)
    case isoIsDirectory(String)
    case rosettaUnavailable
    case vmIsRunning
    case macOSNotInstalled
    case macOSHardwareUnsupported
    case notAVirtualMachine(String)
    case encryptedNotSupported(String)

    var errorDescription: String? {
        switch self {
        case .diskCreationFailed:
            return String(localized: "Não foi possível criar a imagem de disco.")
        case .isoNotFound(let path):
            return String(localized: "ISO não encontrada: \(path)")
        case .isoIsDirectory(let path):
            return String(localized: "O caminho da ISO é uma pasta, não um arquivo .iso: \(path). Use \"Trocar ISO…\".")
        case .rosettaUnavailable:
            return String(localized: "O Rosetta para Linux não está instalado. Instale em Configurações da VM ou desative a opção.")
        case .vmIsRunning:
            return String(localized: "Desligue ou suspenda a VM antes desta operação.")
        case .macOSNotInstalled:
            return String(localized: "O macOS ainda não foi instalado nesta VM. Use \"Instalar macOS\".")
        case .macOSHardwareUnsupported:
            return String(localized: "Esta versão do macOS não é suportada como VM neste Mac. Tente um IPSW mais recente.")
        case .notAVirtualMachine(let path):
            return String(localized: "Não é uma VM do VM Guave (falta config.json): \(path)")
        case .encryptedNotSupported(let what):
            return String(localized: "\(what) não está disponível para VMs criptografadas. Remova a criptografia antes.")
        }
    }
}
