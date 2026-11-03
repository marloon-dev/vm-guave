import Foundation
import Virtualization
import vmnet

/// Cria o anexo de rede de uma VM do Virtualization.framework.
/// Modos vmnet: cada VM tem uma /24 própria, IP fixo no .2 (reserva DHCP pelo MAC)
/// e as regras de redirecionamento apontam para esse IP.
///
/// vmnet_network_ref chega ao Swift como ponteiro opaco (sem ARC): sem CFRelease a reserva da
/// sub-rede fica presa e a próxima partida da VM falha. Por isso a rede de cada VM é guardada
/// e reaproveitada enquanto a configuração de rede não muda.
enum VMNetworkFactory {
    private struct CachedNetwork {
        let key: String
        let network: OpaquePointer
    }

    nonisolated(unsafe) private static var cache: [UUID: CachedNetwork] = [:]
    private static let cacheLock = NSLock()

    static func attachment(for config: VMConfig) throws -> VZNetworkDeviceAttachment {
        guard config.networkMode != .nat else { return VZNATNetworkDeviceAttachment() }
        guard #available(macOS 26, *) else { throw NetworkError.requiresMacOS26 }
        return try vmnetAttachment(for: config)
    }

    /// Indica se a interface deve oferecer os modos vmnet.
    static var vmnetAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    @available(macOS 26, *)
    private static func vmnetAttachment(for config: VMConfig) throws -> VZNetworkDeviceAttachment {
        let key = cacheKey(config)
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[config.id] {
            if cached.key == key {
                return VZVmnetNetworkDeviceAttachment(network: cached.network)
            }
            // Configuração mudou (a VM está desligada para isso): libera a rede antiga.
            release(cached.network)
            cache[config.id] = nil
        }
        let network = try createNetwork(for: config)
        cache[config.id] = CachedNetwork(key: key, network: network)
        return VZVmnetNetworkDeviceAttachment(network: network)
    }

    private static func cacheKey(_ config: VMConfig) -> String {
        let forwards = config.portForwards.map { "\($0.proto.rawValue):\($0.hostPort)>\($0.guestPort)" }.sorted()
        return ([config.networkMode.rawValue, config.networkSubnet ?? "", config.macAddress] + forwards).joined(separator: "|")
    }

    private static func release(_ pointer: OpaquePointer) {
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(pointer)).release()
    }

    @available(macOS 26, *)
    private static func createNetwork(for config: VMConfig) throws -> vmnet_network_ref {
        guard let subnet = config.networkSubnet, let guestIP = config.guestIPAddress else {
            throw NetworkError.missingSubnet
        }

        let mode: vmnet_mode_t = config.networkMode == .hostOnly ? .VMNET_HOST_MODE : .VMNET_SHARED_MODE
        var status = vmnet_return_t.VMNET_SUCCESS
        guard let configuration = vmnet_network_configuration_create(mode, &status) else {
            throw NetworkError.vmnet(String(localized: "criar configuração"), status)
        }
        defer { release(configuration) }

        var gateway = in_addr()
        var mask = in_addr()
        inet_pton(AF_INET, subnet.split(separator: ".").prefix(3).joined(separator: ".") + ".1", &gateway)
        inet_pton(AF_INET, "255.255.255.0", &mask)
        try check(vmnet_network_configuration_set_ipv4_subnet(configuration, &gateway, &mask), String(localized: "definir sub-rede"))

        var guest = in_addr()
        inet_pton(AF_INET, guestIP, &guest)
        if var ether = etherAddress(config.macAddress) {
            try check(vmnet_network_configuration_add_dhcp_reservation(configuration, &ether, &guest), String(localized: "reservar IP"))
        }

        for forward in config.portForwards {
            let proto = UInt8(forward.proto == .tcp ? IPPROTO_TCP : IPPROTO_UDP)
            try check(
                vmnet_network_configuration_add_port_forwarding_rule(
                    configuration, proto, sa_family_t(AF_INET), forward.guestPort, forward.hostPort, &guest
                ),
                String(localized: "redirecionar porta \(forward.hostPort)")
            )
        }

        guard let network = vmnet_network_create(configuration, &status) else {
            throw NetworkError.vmnet(String(localized: "criar rede"), status)
        }
        return network
    }

    /// Escolhe uma /24 livre em 192.168.200–250 que nenhuma outra VM use.
    static func allocateSubnet(excluding used: [String]) -> String {
        let taken = Set(used)
        for third in 200...250 {
            let candidate = "192.168.\(third).0"
            if !taken.contains(candidate) { return candidate }
        }
        return "192.168.251.0"
    }

    /// IP atual de uma VM em modo NAT, lido das concessões DHCP do macOS.
    static func natIPAddress(forMAC mac: String) -> String? {
        guard let leases = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else { return nil }
        // O arquivo grava octetos sem zero à esquerda (ex.: "a:1b:..." para "0a:1b:...").
        let normalized = mac.lowercased().split(separator: ":").map { String(Int($0, radix: 16) ?? 0, radix: 16) }.joined(separator: ":")
        var ip: String?
        for line in leases.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("ip_address=") {
                ip = String(line.dropFirst("ip_address=".count))
            } else if line.hasPrefix("hw_address="), line.hasSuffix(normalized) {
                return ip
            }
        }
        return nil
    }

    private static func etherAddress(_ mac: String) -> ether_addr_t? {
        let parts = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard parts.count == 6 else { return nil }
        return ether_addr_t(octet: (parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]))
    }

    @available(macOS 26, *)
    private static func check(_ status: vmnet_return_t, _ step: String) throws {
        guard status == .VMNET_SUCCESS else { throw NetworkError.vmnet(step, status) }
    }
}

enum NetworkError: LocalizedError {
    case missingSubnet
    case requiresMacOS26
    case vmnet(String, vmnet_return_t)

    var errorDescription: String? {
        switch self {
        case .missingSubnet:
            return String(localized: "A VM está num modo de rede vmnet sem sub-rede definida. Abra Configurações e salve de novo.")
        case .requiresMacOS26:
            return String(localized: "Redes personalizadas e redirecionamento de portas exigem macOS 26 ou mais recente. Use o modo NAT.")
        case .vmnet(let step, let status):
            let detail: String
            switch status {
            case .VMNET_INVALID_ACCESS, .VMNET_NOT_AUTHORIZED: detail = String(localized: "acesso negado")
            case .VMNET_SHARING_SERVICE_BUSY: detail = String(localized: "serviço de rede ocupado ou porta já em uso no Mac")
            case .VMNET_INVALID_ARGUMENT: detail = String(localized: "argumento inválido")
            default: detail = String(localized: "código \(status.rawValue)")
            }
            return String(localized: "Rede: falha ao \(step) (\(detail)).")
        }
    }
}
