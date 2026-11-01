import Foundation

enum GuestOS: String, Codable, CaseIterable, Identifiable {
    case linux
    case macOS
    /// Windows 11 ARM: roda no motor QEMU (o framework da Apple não tem drivers para ele).
    case windows

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linux: return "Linux"
        case .macOS: return "macOS"
        case .windows: return "Windows"
        }
    }

    var symbol: String {
        switch self {
        case .linux: return "terminal"
        case .macOS: return "apple.logo"
        case .windows: return "pc"
        }
    }

    /// Windows usa QEMU; Linux e macOS usam o Virtualization.framework.
    var usesQEMU: Bool { self == .windows }
}

enum NetworkMode: String, Codable, CaseIterable, Identifiable {
    /// NAT padrão do Virtualization.framework.
    case nat
    /// Rede própria com internet, IP fixo e redirecionamento de portas (vmnet).
    case shared
    /// Rede isolada: só o Mac (e outras VMs na mesma rede) enxergam a VM, sem internet.
    case hostOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nat: return "NAT (padrão)"
        case .shared: return "Compartilhada com redirecionamento de portas"
        case .hostOnly: return "Só com o Mac (sem internet)"
        }
    }
}

struct PortForward: Codable, Hashable, Identifiable {
    enum Proto: String, Codable, CaseIterable { case tcp, udp }

    var id: UUID
    var proto: Proto
    var hostPort: UInt16
    var guestPort: UInt16
}

/// Configuração persistida de uma VM (salva como config.json dentro do pacote .bootguave).
struct VMConfig: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var os: GuestOS
    var cpuCount: Int
    var memoryGB: Int
    var diskGB: Int
    /// Caminho da ISO de instalação; nil depois de ejetada.
    var installerISOPath: String?
    /// Pasta do Mac compartilhada com a VM (montada com a tag "bootguave").
    var sharedFolderPath: String?
    var macAddress: String
    var displayWidth: Int
    var displayHeight: Int
    var createdAt: Date
    /// Área de transferência compartilhada (SPICE). Desligar isola a VM do clipboard do Mac.
    var clipboardSharing: Bool = true
    /// Expõe o Rosetta ao Linux convidado para rodar binários x86_64 (tag "rosetta").
    var rosettaEnabled: Bool = false
    /// Discos além do principal, em disks/<id>.img.
    var extraDisks: [ExtraDisk] = []
    /// Liga a VM quando o VM Guave abre.
    var autoStart: Bool = false
    /// macOS: imagem de restauração (.ipsw) usada na instalação.
    var installerIPSWPath: String?
    /// macOS: false até o VZMacOSInstaller terminar.
    var macOSInstalled: Bool = false
    var networkMode: NetworkMode = .nat
    /// Rede /24 própria da VM nos modos vmnet (ex.: "192.168.201.0"); a VM fica sempre no .2.
    var networkSubnet: String?
    var portForwards: [PortForward] = []
    /// Disco e arquivos da máquina ficam numa imagem criptografada (vault.sparsebundle).
    var encrypted: Bool = false
    /// Windows: ISO dos drivers virtio-win (rede) conectada como segundo CD.
    var driversISOPath: String?

    static let sharedFolderTag = "bootguave"
    static let rosettaTag = "rosetta"
}

extension VMConfig {
    // Campos novos usam decodeIfPresent para que configs antigas continuem abrindo.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        os = try c.decode(GuestOS.self, forKey: .os)
        cpuCount = try c.decode(Int.self, forKey: .cpuCount)
        memoryGB = try c.decode(Int.self, forKey: .memoryGB)
        diskGB = try c.decode(Int.self, forKey: .diskGB)
        installerISOPath = try c.decodeIfPresent(String.self, forKey: .installerISOPath)
        sharedFolderPath = try c.decodeIfPresent(String.self, forKey: .sharedFolderPath)
        macAddress = try c.decode(String.self, forKey: .macAddress)
        displayWidth = try c.decode(Int.self, forKey: .displayWidth)
        displayHeight = try c.decode(Int.self, forKey: .displayHeight)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        clipboardSharing = try c.decodeIfPresent(Bool.self, forKey: .clipboardSharing) ?? true
        rosettaEnabled = try c.decodeIfPresent(Bool.self, forKey: .rosettaEnabled) ?? false
        extraDisks = try c.decodeIfPresent([ExtraDisk].self, forKey: .extraDisks) ?? []
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        installerIPSWPath = try c.decodeIfPresent(String.self, forKey: .installerIPSWPath)
        macOSInstalled = try c.decodeIfPresent(Bool.self, forKey: .macOSInstalled) ?? false
        networkMode = try c.decodeIfPresent(NetworkMode.self, forKey: .networkMode) ?? .nat
        networkSubnet = try c.decodeIfPresent(String.self, forKey: .networkSubnet)
        portForwards = try c.decodeIfPresent([PortForward].self, forKey: .portForwards) ?? []
        encrypted = try c.decodeIfPresent(Bool.self, forKey: .encrypted) ?? false
        driversISOPath = try c.decodeIfPresent(String.self, forKey: .driversISOPath)
    }

    /// IP fixo da VM nos modos vmnet.
    var guestIPAddress: String? {
        guard networkMode != .nat, let subnet = networkSubnet else { return nil }
        return subnet.split(separator: ".").prefix(3).joined(separator: ".") + ".2"
    }
}

struct ExtraDisk: Codable, Hashable, Identifiable {
    var id: UUID
    var sizeGB: Int
}
