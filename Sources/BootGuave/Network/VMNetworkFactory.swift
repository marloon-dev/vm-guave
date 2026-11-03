import Foundation
import Virtualization
import vmnet

/// Cria o anexo de rede de uma VM do Virtualization.framework.
/// Modos vmnet: as VMs no mesmo modo e na mesma /24 dividem uma rede (laboratório com várias
/// máquinas). Cada uma tem IP fixo (reserva DHCP pelo MAC, .2, .3…) e as regras de
/// redirecionamento de todas apontam para o IP de cada uma.
///
/// vmnet_network_ref chega ao Swift como ponteiro opaco (sem ARC): sem CFRelease a reserva da
/// sub-rede fica presa e a próxima partida falha. Por isso cada rede é guardada e reaproveitada
/// enquanto os membros e as regras dela não mudam.
@MainActor
enum VMNetworkFactory {
    private struct CachedNetwork {
        let key: String
        let network: OpaquePointer
        /// VMs que receberam esta rede (para saber se ainda há alguém usando ao recriar).
        var users: Set<UUID>
    }

    /// Chave: modo + sub-rede.
    private static var cache: [String: CachedNetwork] = [:]
    /// Avisos não fatais da última partida de cada VM (ex.: rede já em uso com regras antigas).
    private static var warnings: [UUID: String] = [:]

    static func attachment(for config: VMConfig) throws -> VZNetworkDeviceAttachment {
        guard config.networkMode != .nat else { return VZNATNetworkDeviceAttachment() }
        guard #available(macOS 26, *) else { throw NetworkError.requiresMacOS26 }
        return try vmnetAttachment(for: config)
    }

    /// Indica se a interface deve oferecer os modos vmnet.
    nonisolated static var vmnetAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    static func takeWarning(for id: UUID) -> String? {
        warnings.removeValue(forKey: id)
    }

    /// As VMs (Linux/macOS) que estão na mesma rede vmnet que `config`, incluindo ela.
    static func members(of config: VMConfig, in configs: [VMConfig]) -> [VMConfig] {
        guard config.networkMode != .nat, let subnet = config.networkSubnet else { return [config] }
        var result = configs.filter {
            $0.id != config.id && !$0.os.usesQEMU && $0.networkMode == config.networkMode && $0.networkSubnet == subnet
        }
        result.append(config)
        return result.sorted { $0.createdAt < $1.createdAt }
    }

    @available(macOS 26, *)
    private static func vmnetAttachment(for config: VMConfig) throws -> VZNetworkDeviceAttachment {
        let library = VMLibrary.shared
        let members = members(of: config, in: library.configs)
        let networkID = "\(config.networkMode.rawValue)|\(config.networkSubnet ?? "")"
        let key = cacheKey(members)

        if var cached = cache[networkID] {
            if cached.key == key {
                cached.users.insert(config.id)
                cache[networkID] = cached
                return VZVmnetNetworkDeviceAttachment(network: cached.network)
            }
            let othersRunning = cached.users.contains { $0 != config.id && library.runner(for: $0)?.state.isActive == true }
            if othersRunning {
                // Não dá para trocar a rede embaixo de quem está ligado: entra na que existe.
                // Quem ainda não tinha reserva recebe um IP qualquer do DHCP até a rede ser recriada.
                warnings[config.id] = String(localized: "A rede desta VM já está em uso por outra VM com regras antigas. Desligue todas as VMs desta rede e ligue de novo para aplicar o IP fixo e os redirecionamentos.")
                cached.users.insert(config.id)
                cache[networkID] = cached
                return VZVmnetNetworkDeviceAttachment(network: cached.network)
            }
            release(cached.network)
            cache[networkID] = nil
        }
        let network = try createNetwork(for: config, members: members)
        cache[networkID] = CachedNetwork(key: key, network: network, users: [config.id])
        return VZVmnetNetworkDeviceAttachment(network: network)
    }

    private static func cacheKey(_ members: [VMConfig]) -> String {
        members.map { member in
            let forwards = member.portForwards.map { "\($0.proto.rawValue):\($0.hostPort)>\($0.guestPort)" }.sorted()
            return ([member.macAddress, member.guestIPAddress ?? ""] + forwards).joined(separator: ",")
        }
        .sorted()
        .joined(separator: "|")
    }

    private static func release(_ pointer: OpaquePointer) {
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(pointer)).release()
    }

    @available(macOS 26, *)
    private static func createNetwork(for config: VMConfig, members: [VMConfig]) throws -> vmnet_network_ref {
        guard let subnet = config.networkSubnet, config.guestIPAddress != nil else {
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

        var usedPorts = Set<String>()
        for member in members {
            guard let ip = member.guestIPAddress else { continue }
            var guest = in_addr()
            inet_pton(AF_INET, ip, &guest)
            if var ether = etherAddress(member.macAddress) {
                try check(vmnet_network_configuration_add_dhcp_reservation(configuration, &ether, &guest), String(localized: "reservar IP"))
            }
            for forward in member.portForwards {
                // A mesma porta do Mac não pode ir para duas VMs; vale a da VM mais antiga.
                guard usedPorts.insert("\(forward.proto.rawValue):\(forward.hostPort)").inserted else { continue }
                let proto = UInt8(forward.proto == .tcp ? IPPROTO_TCP : IPPROTO_UDP)
                try check(
                    vmnet_network_configuration_add_port_forwarding_rule(
                        configuration, proto, sa_family_t(AF_INET), forward.guestPort, forward.hostPort, &guest
                    ),
                    String(localized: "redirecionar porta \(forward.hostPort)")
                )
            }
        }

        guard let network = vmnet_network_create(configuration, &status) else {
            throw NetworkError.vmnet(String(localized: "criar rede"), status)
        }
        return network
    }

    /// Endereço de uma VM que entra (ou muda) num modo vmnet: a rede que as outras VMs desse modo
    /// já usam, com o próximo IP livre; sem nenhuma, uma /24 nova em 192.168.200–250.
    nonisolated static func allocateAddress(for config: VMConfig, among configs: [VMConfig]) -> (subnet: String, host: Int) {
        let others = configs.filter { $0.id != config.id && !$0.os.usesQEMU }
        let sameMode = others.filter { $0.networkMode == config.networkMode && $0.networkSubnet != nil }
        // A rede mais cheia do modo (empate: a mais antiga), para todas acabarem juntas.
        let groups = Dictionary(grouping: sameMode) { $0.networkSubnet! }
        if let subnet = groups.max(by: { a, b in
            a.value.count != b.value.count ? a.value.count < b.value.count
                : (a.value.map(\.createdAt).min() ?? .distantPast) > (b.value.map(\.createdAt).min() ?? .distantPast)
        })?.key {
            let taken = Set(groups[subnet, default: []].map(\.networkHostNumber))
            if let host = (2...254).first(where: { !taken.contains($0) }) {
                return (subnet, host)
            }
        }
        let used = Set(configs.filter { $0.id != config.id }.compactMap(\.networkSubnet))
        let subnet = (200...250).map { "192.168.\($0).0" }.first { !used.contains($0) } ?? "192.168.251.0"
        return (subnet, 2)
    }

    /// IP atual de uma VM em modo NAT, lido das concessões DHCP do macOS.
    nonisolated static func natIPAddress(forMAC mac: String) -> String? {
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

    nonisolated private static func etherAddress(_ mac: String) -> ether_addr_t? {
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
