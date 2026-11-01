import Foundation
import Virtualization

/// Traduz um VMConfig numa VZVirtualMachineConfiguration pronta para rodar.
enum VMConfigurationBuilder {
    static func build(for config: VMConfig, bundle: VMBundle) throws -> VZVirtualMachineConfiguration {
        let vz = VZVirtualMachineConfiguration()
        vz.cpuCount = config.cpuCount
        vz.memorySize = UInt64(config.memoryGB) * 1024 * 1024 * 1024

        switch config.os {
        case .linux:
            try configureLinux(vz, config, bundle)
        case .macOS:
            try configureMacOS(vz, config, bundle)
        case .windows:
            // Windows roda no QEMU (QEMUMachine), não no Virtualization.framework.
            throw QEMUError.unsupported("O motor da Apple")
        }

        vz.storageDevices = try storageDevices(config, bundle, includeInstaller: config.os == .linux)
        vz.networkDevices = [try networkDevice(config)]
        vz.audioDevices = [audioDevice()]
        vz.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vz.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        try vz.validate()
        return vz
    }

    private static func configureLinux(_ vz: VZVirtualMachineConfiguration, _ config: VMConfig, _ bundle: VMBundle) throws {
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = try bundle.machineIdentifier()
        vz.platform = platform

        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = try bundle.efiVariableStore()
        vz.bootLoader = bootLoader

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(widthInPixels: config.displayWidth, heightInPixels: config.displayHeight)
        ]
        vz.graphicsDevices = [graphics]
        vz.keyboards = [VZUSBKeyboardConfiguration()]
        vz.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // Área de transferência compartilhada (requer spice-vdagent no Linux convidado).
        if config.clipboardSharing {
            let console = VZVirtioConsoleDeviceConfiguration()
            let spicePort = VZVirtioConsolePortConfiguration()
            spicePort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
            spicePort.attachment = VZSpiceAgentPortAttachment()
            console.ports[0] = spicePort
            vz.consoleDevices = [console]
        }

        var shares: [VZDirectorySharingDeviceConfiguration] = []
        if let share = sharedFolder(config, tag: VMConfig.sharedFolderTag) {
            shares.append(share)
        }
        if config.rosettaEnabled {
            guard VZLinuxRosettaDirectoryShare.availability == .installed else {
                throw BootGuaveError.rosettaUnavailable
            }
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: VMConfig.rosettaTag)
            fs.share = try VZLinuxRosettaDirectoryShare()
            shares.append(fs)
        }
        vz.directorySharingDevices = shares
    }

    private static func configureMacOS(_ vz: VZVirtualMachineConfiguration, _ config: VMConfig, _ bundle: VMBundle) throws {
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = try bundle.macHardwareModel()
        platform.machineIdentifier = try bundle.macMachineIdentifier()
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxiliaryStorageURL)
        vz.platform = platform
        vz.bootLoader = VZMacOSBootLoader()

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: config.displayWidth, heightInPixels: config.displayHeight, pixelsPerInch: 80
            )
        ]
        vz.graphicsDevices = [graphics]
        vz.keyboards = [VZMacKeyboardConfiguration()]
        vz.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // O macOS convidado monta esta tag sozinho em /Volumes/My Shared Files.
        if let share = sharedFolder(config, tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag) {
            vz.directorySharingDevices = [share]
        }
    }

    // MARK: Partes comuns

    private static func storageDevices(_ config: VMConfig, _ bundle: VMBundle, includeInstaller: Bool) throws -> [VZStorageDeviceConfiguration] {
        var storage: [VZStorageDeviceConfiguration] = []
        let disk = try VZDiskImageStorageDeviceAttachment(url: bundle.diskURL, readOnly: false)
        storage.append(VZVirtioBlockDeviceConfiguration(attachment: disk))

        for extra in config.extraDisks {
            let attachment = try VZDiskImageStorageDeviceAttachment(url: bundle.extraDiskURL(extra), readOnly: false)
            storage.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
        }

        // ISO como pendrive USB, para o EFI dar boot nela.
        if includeInstaller, let isoPath = config.installerISOPath {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: isoPath, isDirectory: &isDirectory) else {
                throw BootGuaveError.isoNotFound(isoPath)
            }
            guard !isDirectory.boolValue else {
                throw BootGuaveError.isoIsDirectory(isoPath)
            }
            let iso = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: isoPath), readOnly: true)
            storage.append(VZUSBMassStorageDeviceConfiguration(attachment: iso))
        }
        return storage
    }

    private static func networkDevice(_ config: VMConfig) throws -> VZVirtioNetworkDeviceConfiguration {
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = try VMNetworkFactory.attachment(for: config)
        if let mac = VZMACAddress(string: config.macAddress) {
            network.macAddress = mac
        }
        return network
    }

    private static func audioDevice() -> VZVirtioSoundDeviceConfiguration {
        let sound = VZVirtioSoundDeviceConfiguration()
        let output = VZVirtioSoundDeviceOutputStreamConfiguration()
        output.sink = VZHostAudioOutputStreamSink()
        sound.streams = [output]
        return sound
    }

    private static func sharedFolder(_ config: VMConfig, tag: String) -> VZVirtioFileSystemDeviceConfiguration? {
        guard let path = config.sharedFolderPath else { return nil }
        let directory = VZSharedDirectory(url: URL(fileURLWithPath: path), readOnly: false)
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        fs.share = VZSingleDirectoryShare(directory: directory)
        return fs
    }
}

/// Limites do host para o assistente de criação.
enum HostLimits {
    static var cpuRange: ClosedRange<Int> {
        let minCPU = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let maxCPU = min(VZVirtualMachineConfiguration.maximumAllowedCPUCount, ProcessInfo.processInfo.processorCount)
        return minCPU...max(minCPU, maxCPU)
    }

    static var memoryGBRange: ClosedRange<Int> {
        let hostGB = Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
        let maxVZ = Int(VZVirtualMachineConfiguration.maximumAllowedMemorySize / (1024 * 1024 * 1024))
        // Deixa pelo menos 2 GB para o macOS.
        return 1...max(1, min(maxVZ, hostGB - 2))
    }

    static let diskGBRange = 8...1024
}
