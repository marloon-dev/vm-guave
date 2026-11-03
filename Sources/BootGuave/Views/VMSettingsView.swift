import SwiftUI
import Virtualization

/// Editar uma VM existente (desligada ou suspensa).
struct VMSettingsView: View {
    let original: VMConfig
    let isSuspended: Bool
    let onSave: (VMConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var config: VMConfig
    @State private var rosettaAvailability = VZLinuxRosettaDirectoryShare.availability
    @State private var installingRosetta = false
    @State private var rosettaError: String?
    @State private var newDiskGB = 32

    init(config: VMConfig, isSuspended: Bool, onSave: @escaping (VMConfig) -> Void) {
        self.original = config
        self.isSuspended = isSuspended
        self.onSave = onSave
        _config = State(initialValue: config)
    }

    private var hardwareChanged: Bool {
        var other = original
        other.name = config.name
        other.autoStart = config.autoStart
        return other != config
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Geral") {
                    TextField("Nome", text: $config.name)
                    Toggle("Iniciar quando o VM Guave abrir", isOn: $config.autoStart)
                }

                Section("Hardware") {
                    Stepper("CPUs: \(config.cpuCount)", value: $config.cpuCount, in: HostLimits.cpuRange)
                    Stepper("Memória: \(config.memoryGB) GB", value: $config.memoryGB, in: HostLimits.memoryGBRange)
                    Stepper(
                        "Disco: \(config.diskGB) GB",
                        value: $config.diskGB,
                        in: original.diskGB...HostLimits.diskGBRange.upperBound,
                        step: 8
                    )
                    if config.diskGB > original.diskGB {
                        Text(config.os == .windows
                             ? "Depois de aumentar, estenda a partição no Gerenciamento de Disco do Windows."
                             : "Depois de aumentar, expanda a partição dentro do convidado (no Linux: GNOME Disks ou growpart + resize2fs).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Discos adicionais") {
                    ForEach(config.extraDisks) { disk in
                        HStack {
                            Image(systemName: "externaldrive")
                                .foregroundStyle(.secondary)
                            Text("\(disk.sizeGB) GB")
                            if !original.extraDisks.contains(disk) {
                                Text("novo").font(.caption).foregroundStyle(.green)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                config.extraDisks.removeAll { $0.id == disk.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .guaveHover(.icon)
                        }
                    }
                    HStack {
                        Stepper("Novo disco: \(newDiskGB) GB", value: $newDiskGB, in: HostLimits.diskGBRange, step: 8)
                        Button("Adicionar") {
                            config.extraDisks.append(ExtraDisk(id: UUID(), sizeGB: newDiskGB))
                        }
                    }
                    if original.extraDisks.contains(where: { disk in !config.extraDisks.contains(disk) }) {
                        Text("Os discos removidos serão apagados ao salvar.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Text("Aparecem no convidado como discos vazios (no Linux: /dev/vdb, /dev/vdc…); formate antes de usar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                networkSection

                if config.os == .linux {
                    Section("Integração e isolamento") {
                        Toggle("Área de transferência compartilhada", isOn: $config.clipboardSharing)
                        Text("Desligado, nada copiado no Mac chega à VM e vice-versa.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if config.os == .linux {
                    Section("Rosetta (programas x86_64 no Linux)") {
                        Toggle("Ativar Rosetta", isOn: $config.rosettaEnabled)
                            .disabled(rosettaAvailability != .installed)
                        switch rosettaAvailability {
                        case .installed:
                            Text("No Linux: sudo mount -t virtiofs \(VMConfig.rosettaTag) /media/rosetta e registre no binfmt (veja o README).")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        case .notInstalled:
                            HStack {
                                Text("Rosetta para Linux não está instalado.")
                                    .font(.caption)
                                Spacer()
                                Button(installingRosetta ? "Instalando…" : "Instalar Rosetta") { installRosetta() }
                                    .disabled(installingRosetta)
                            }
                        default:
                            Text("Rosetta não é suportado neste Mac.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let rosettaError {
                            Text(rosettaError).font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                if isSuspended && hardwareChanged {
                    Text("A VM está suspensa. Mudar o hardware descarta o estado salvo e ela vai iniciar do zero.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Salvar") {
                    onSave(config)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(config.name.trimmingCharacters(in: .whitespaces).isEmpty || config == original || duplicateHostPorts)
            }
            .padding()
        }
        .frame(width: 540, height: 640)
    }

    /// Portas: Windows usa o redirecionamento do QEMU; Linux/macOS usam o modo vmnet "Compartilhada".
    private var supportsPortForwarding: Bool {
        config.os.usesQEMU || config.networkMode == .shared
    }

    /// O IP só é conhecido depois de salvar quando a VM troca de modo (entra na rede do modo novo).
    private var fixedIP: String {
        guard config.networkMode == original.networkMode, let ip = config.guestIPAddress else {
            return String(localized: "(definido ao salvar)")
        }
        return ip
    }

    private var duplicateHostPorts: Bool {
        let keys = config.portForwards.map { "\($0.proto.rawValue):\($0.hostPort)" }
        return Set(keys).count != keys.count
    }

    private var networkSection: some View {
        Section("Rede") {
            if config.os.usesQEMU {
                LabeledContent("Modo", value: String(localized: "NAT do QEMU"))
            } else {
                Picker("Modo", selection: $config.networkMode) {
                    ForEach(NetworkMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .disabled(!VMNetworkFactory.vmnetAvailable)
                if !VMNetworkFactory.vmnetAvailable {
                    Text("Redes personalizadas exigem macOS 26 ou mais recente.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                switch config.networkMode {
                case .nat:
                    Text("A VM acessa a internet pelo Mac. O Mac também alcança a VM pelo IP dela (192.168.64.x).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .shared:
                    Text("Internet pelo Mac, IP fixo \(fixedIP) e redirecionamento de portas. As VMs neste modo ficam na mesma rede e se enxergam.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .hostOnly:
                    Text("Sem internet. Só o Mac e as outras VMs neste modo alcançam a VM, pelo IP fixo \(fixedIP). Bom para laboratório isolado.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if supportsPortForwarding {
                ForEach($config.portForwards) { $forward in
                    HStack {
                        Picker("", selection: $forward.proto) {
                            ForEach(PortForward.Proto.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 80)
                        Text("Mac")
                        TextField("", value: $forward.hostPort, format: .number.grouping(.never))
                            .frame(width: 70)
                        Image(systemName: "arrow.right")
                        Text("VM")
                        TextField("", value: $forward.guestPort, format: .number.grouping(.never))
                            .frame(width: 70)
                        Spacer()
                        Button(role: .destructive) {
                            config.portForwards.removeAll { $0.id == forward.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .guaveHover(.icon)
                    }
                }
                Button("Adicionar redirecionamento") {
                    let (host, guest): (UInt16, UInt16) = config.os == .windows ? (3390, 3389) : (2222, 22)
                    config.portForwards.append(PortForward(id: UUID(), proto: .tcp, hostPort: host, guestPort: guest))
                }
                if duplicateHostPorts {
                    Text("Duas regras usam a mesma porta do Mac.").font(.caption).foregroundStyle(.red)
                }
                Text(config.os == .windows
                     ? "Ex.: Mac 3390 → VM 3389 para Área de Trabalho Remota. Use portas do Mac acima de 1024."
                     : "Ex.: Mac 2222 → VM 22 para SSH (ssh -p 2222 usuario@localhost). Use portas do Mac acima de 1024.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func installRosetta() {
        installingRosetta = true
        rosettaError = nil
        VZLinuxRosettaDirectoryShare.installRosetta { error in
            installingRosetta = false
            if let error { rosettaError = error.localizedDescription }
            rosettaAvailability = VZLinuxRosettaDirectoryShare.availability
        }
    }
}
