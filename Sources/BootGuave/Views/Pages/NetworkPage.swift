import Combine
import SwiftUI

/// Uma rede como aparece na página (a NAT padrão e as vmnet podem ter várias VMs).
private struct NetworkInfo: Identifiable {
    let id: String
    let title: String
    let mode: String
    let subnet: String
    let gateway: String
    let dhcp: Bool
    let members: [VMConfig]
}

struct NetworkPage: View {
    @Environment(VMLibrary.self) private var library
    private let router = AppRouter.shared
    /// Os IPs da NAT vêm do arquivo de concessões do DHCP do macOS; relê de tempos em tempos.
    @State private var tick = 0
    private let refresh = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    private var networks: [NetworkInfo] {
        var result: [NetworkInfo] = []
        let nat = library.configs.filter { !$0.os.usesQEMU && $0.networkMode == .nat }
        result.append(NetworkInfo(id: "nat", title: String(localized: "Rede padrão"), mode: String(localized: "NAT do macOS"),
                                  subnet: "192.168.64.0/24", gateway: "192.168.64.1", dhcp: true, members: nat))
        let qemu = library.configs.filter(\.os.usesQEMU)
        if !qemu.isEmpty {
            result.append(NetworkInfo(id: "qemu", title: String(localized: "NAT do QEMU"), mode: String(localized: "Rede de usuário do QEMU (Windows)"),
                                      subnet: "10.0.2.0/24", gateway: "10.0.2.2", dhcp: true, members: qemu))
        }
        // VMs no mesmo modo vmnet e na mesma sub-rede dividem uma rede.
        let vmnet = library.configs.filter { !$0.os.usesQEMU && $0.networkMode != .nat }
        var seen = Set<String>()
        for config in vmnet {
            let networkID = "\(config.networkMode.rawValue)|\(config.networkSubnet ?? config.id.uuidString)"
            guard seen.insert(networkID).inserted else { continue }
            let members = config.networkSubnet == nil ? [config] : VMNetworkFactory.members(of: config, in: vmnet)
            let base = config.networkSubnet.map { $0.split(separator: ".").prefix(3).joined(separator: ".") }
            let names = ListFormatter.localizedString(byJoining: members.map(\.name))
            result.append(NetworkInfo(
                id: networkID,
                title: String(localized: "Rede de \(names)"),
                mode: config.networkMode.displayName,
                subnet: config.networkSubnet.map { "\($0)/24" } ?? "—",
                gateway: base.map { "\($0).1" } ?? "—",
                dhcp: true,
                members: members
            ))
        }
        return result
    }

    var body: some View {
        PageScroll {
            PageHeader("Rede", subtitle: "Gerencie redes virtuais e conexões.") {
                Button { router.showSettings(.defaults) } label: {
                    Label("Configurar", systemImage: "gearshape")
                }
                .buttonStyle(SecondaryButtonStyle(large: true))
                .help("Modo de rede padrão das novas VMs")
            }

            ForEach(networks) { network in
                NetworkCard(network: network, isActive: isActive(network))
            }

            connectedMachines
        }
        .onReceive(refresh) { _ in tick += 1 }
    }

    private func isActive(_ network: NetworkInfo) -> Bool {
        network.members.contains { library.runner(for: $0.id)?.state.isActive == true }
    }

    private func ipAddress(_ config: VMConfig) -> String {
        _ = tick
        if config.os.usesQEMU { return "10.0.2.15" }
        if config.networkMode == .nat {
            return VMNetworkFactory.natIPAddress(forMAC: config.macAddress) ?? "—"
        }
        return config.guestIPAddress ?? "—"
    }

    private var connectedMachines: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Máquinas conectadas")
            if library.configs.isEmpty {
                Text("Nenhuma VM ainda.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    TableHeaderRow(titles: ["Máquina", "Rede", "Endereço IP", "Status"], fractions: [0.32, 0.26, 0.2, 0.22])
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    ForEach(library.configs) { config in
                        let active = library.runner(for: config.id)?.state.isActive == true
                        ColumnsLayout(fractions: [0.32, 0.26, 0.2, 0.22]) {
                            HStack(spacing: 12) {
                                CubeGlyph(size: 22)
                                Text(config.name).lineLimit(1)
                            }
                            Text(config.os.usesQEMU ? String(localized: "NAT do QEMU") : config.networkMode.displayName)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(verbatim: ipAddress(config))
                                .monospacedDigit()
                                .textSelection(.enabled)
                            HStack(spacing: 8) {
                                Circle().fill(active ? Brand.green : Color.secondary).frame(width: 10, height: 10)
                                Text(active ? "Conectada" : "Desligada")
                                    .foregroundStyle(active ? Brand.green : .secondary)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                        .guaveHover(.row(AnyShape(Rectangle())))
                        .onTapGesture { router.open(vm: config.id) }
                        Divider()
                    }
                }
            }
        }
        .guaveCard()
    }
}

private struct NetworkCard: View {
    let network: NetworkInfo
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 20) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Brand.green)
                    .frame(width: 76, height: 76)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Surface.cardHeader))
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Text(network.title).font(.system(size: 26, weight: .bold))
                        TagPill(text: isActive ? String(localized: "Ativa") : String(localized: "Ociosa"),
                                tint: isActive ? Brand.green : .secondary)
                    }
                    HStack(spacing: 0) {
                        fact("Sub-rede", network.subnet)
                        Divider().frame(height: 34).padding(.horizontal, 22)
                        fact("Gateway", network.gateway)
                        Divider().frame(height: 34).padding(.horizontal, 22)
                        fact("DHCP", network.dhcp ? String(localized: "Ativado") : String(localized: "Desativado"))
                        Divider().frame(height: 34).padding(.horizontal, 22)
                        fact("Modo", network.mode)
                    }
                }
            }
            if !network.members.isEmpty {
                NetworkDiagram(title: network.title, members: network.members)
                    .frame(height: 240)
            } else {
                Text("Nenhuma VM usa esta rede.")
                    .foregroundStyle(.secondary)
            }
        }
        .guaveCard(padding: 26)
    }

    private func fact(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.callout).foregroundStyle(.secondary)
            Text(verbatim: value).font(.title3.weight(.semibold)).monospacedDigit().lineLimit(1)
        }
    }
}

/// Roteador no alto ligado a cada VM embaixo por linhas verdes (até 6 VMs; o resto vira "+N").
private struct NetworkDiagram: View {
    let title: String
    let members: [VMConfig]

    private var shown: [VMConfig] { Array(members.prefix(6)) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let count = max(1, shown.count)
            let spacing = min(220, w / CGFloat(count))
            let startX = w / 2 - spacing * CGFloat(count - 1) / 2
            // Faixas verticais: roteador (12–78), nome (~92), barramento (118), VMs (136–208), nomes (~224).
            let routerX = w / 2
            let lineStartY: CGFloat = 106
            let busY: CGFloat = 120
            let nodeTopY: CGFloat = 136
            let nodeY: CGFloat = 172

            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: routerX, y: lineStartY))
                    p.addLine(to: CGPoint(x: routerX, y: busY))
                    for index in 0..<count {
                        let x = startX + spacing * CGFloat(index)
                        p.move(to: CGPoint(x: routerX, y: busY))
                        p.addLine(to: CGPoint(x: x, y: busY))
                        p.addLine(to: CGPoint(x: x, y: nodeTopY))
                    }
                }
                .stroke(Brand.green, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))

                ForEach(0..<count, id: \.self) { index in
                    Circle().fill(Brand.green).frame(width: 10, height: 10)
                        .position(x: startX + spacing * CGFloat(index), y: nodeTopY)
                }

                VStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Surface.card)
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Surface.stroke, lineWidth: 1.5))
                        VStack(spacing: 4) {
                            Image(systemName: "wifi")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(Brand.pink)
                            Capsule()
                                .fill(Brand.cream)
                                .frame(width: 70, height: 18)
                                .overlay(HStack(spacing: 5) {
                                    Circle().fill(Brand.ink).frame(width: 5)
                                    Circle().fill(Brand.ink).frame(width: 5)
                                    Circle().fill(Brand.green).frame(width: 5)
                                })
                        }
                    }
                    .frame(width: 104, height: 66)
                    Text(verbatim: title).font(.callout.weight(.medium))
                }
                .position(x: routerX, y: 56)

                ForEach(Array(shown.enumerated()), id: \.element.id) { index, config in
                    VStack(spacing: 8) {
                        CubeGlyph(size: 44)
                            .frame(width: 92, height: 72)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Surface.cardHeader))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Surface.stroke, lineWidth: 1.5))
                        Text(verbatim: config.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .frame(maxWidth: spacing - 10)
                    }
                    .position(x: startX + spacing * CGFloat(index), y: nodeY + 14)
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if members.count > shown.count {
                Text(verbatim: "+\(members.count - shown.count)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
