import AppKit
import SwiftUI

struct MachinesPage: View {
    @EnvironmentObject private var library: VMLibrary
    @ObservedObject private var router = AppRouter.shared
    @State private var search = ""
    @State private var filter: StatusFilter = .all

    enum StatusFilter: String, CaseIterable, Identifiable {
        case all, running, stopped, suspended
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .all: return "Todos os status"
            case .running: return "Em execução"
            case .stopped: return "Desligadas"
            case .suspended: return "Suspensas ou pausadas"
            }
        }

        func matches(_ state: VMRunState) -> Bool {
            switch self {
            case .all: return true
            case .running: return state.isActive && state != .paused
            case .stopped: return state == .stopped || { if case .error = state { return true } else { return false } }()
            case .suspended: return state == .suspended || state == .paused
            }
        }
    }

    static let columns: [CGFloat] = [0.27, 0.17, 0.15, 0.15, 0.14, 0.12]

    private var visible: [VMConfig] {
        library.configs.filter { config in
            let matchesSearch = search.isEmpty
                || config.name.localizedCaseInsensitiveContains(search)
                || config.os.displayName.localizedCaseInsensitiveContains(search)
            let state = library.runner(for: config.id)?.state ?? .stopped
            return matchesSearch && filter.matches(state)
        }
    }

    var body: some View {
        PageScroll {
            PageHeader("Máquinas Virtuais", subtitle: "Gerencie e acompanhe suas instâncias.") {
                Menu {
                    Button("VM exportada do VM Guave (.bootguave)…") { importVM() }
                    Button("Disco de outro programa (qcow2, vmdk, vdi, vhdx)…") { router.showingDiskImport = true }
                } label: {
                    Label("Importar", systemImage: "square.and.arrow.down")
                }
                .menuStyle(.button)
                .buttonStyle(SecondaryButtonStyle(large: true))
                .fixedSize()
                Button { router.newVM() } label: {
                    Label("Nova VM", systemImage: "plus")
                }
                .buttonStyle(GuaveButtonStyle(large: true))
            }

            if library.configs.isEmpty {
                EmptyMachinesView { router.newVM() }
                    .guaveCard()
            } else {
                HStack(spacing: 16) {
                    GuaveSearchField(text: $search, prompt: "Buscar máquinas")
                    Menu {
                        Picker("Status", selection: $filter) {
                            ForEach(StatusFilter.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "line.3.horizontal.decrease")
                            Text(filter.title).font(.title3)
                            Spacer()
                            Image(systemName: "chevron.down").font(.callout.weight(.semibold))
                        }
                        .padding(.horizontal, 16)
                        .frame(width: 300, height: 50)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Surface.field))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Surface.stroke))
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                VStack(spacing: 0) {
                    TableHeaderRow(
                        titles: ["Nome", "Status", "Sistema", "CPU / RAM", "Armazenamento", "Ações"],
                        fractions: Self.columns
                    )
                    if visible.isEmpty {
                        Text("Nenhuma máquina com esse filtro.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(30)
                    }
                    ForEach(visible) { config in
                        if let runner = library.runner(for: config.id) {
                            Divider()
                            MachineRow(runner: runner)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Surface.card))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Surface.stroke))
            }
        }
    }

    private func importVM() {
        guard let url = FilePicker.chooseVMToImport() else { return }
        Task {
            if let id = await library.importVM(from: url) {
                router.open(vm: id)
            }
        }
    }
}

private struct MachineRow: View {
    @ObservedObject var runner: VMRunner
    @EnvironmentObject private var library: VMLibrary
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var router = AppRouter.shared
    @State private var hovering = false
    @State private var confirmingDelete = false

    private var config: VMConfig { runner.config }

    var body: some View {
        ColumnsLayout(fractions: MachinesPage.columns) {
            HStack(spacing: 14) {
                ZStack(alignment: .bottomTrailing) {
                    CubeGlyph(size: 24)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Surface.cardHeader))
                    Circle()
                        .fill(runner.state.isActive ? Brand.green : Brand.pink)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Surface.card, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
                Text(config.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
            }
            SolidStatusPill(state: runner.state)
            Text(config.os.displayName)
            Text(verbatim: "\(config.cpuCount) vCPU · \(config.memoryGB) GB")
                .monospacedDigit()
            Text(verbatim: "\(config.diskGB + config.extraDisks.map(\.sizeGB).reduce(0, +)) GB")
                .monospacedDigit()
            actionsMenu
        }
        .font(.body)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { router.open(vm: config.id) }
        .confirmationDialog("Excluir \"\(config.name)\"?", isPresented: $confirmingDelete) {
            Button("Excluir disco, snapshots e configuração", role: .destructive) {
                library.delete(config.id)
            }
        } message: {
            Text("O disco virtual será apagado permanentemente.")
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button("Abrir detalhes") { router.open(vm: config.id) }
            Divider()
            if runner.state.isActive {
                Button("Mostrar tela") { showScreen() }
                if runner.state == .running {
                    Button("Desligar") { runner.requestStop() }
                }
                Button("Forçar desligamento", role: .destructive) { runner.forceStop() }
            } else if !(config.os == .macOS && !config.macOSInstalled) {
                Button(runner.state == .suspended ? "Retomar" : "Iniciar") { start() }
            }
            Divider()
            Button("Clonar") {
                _ = library.clone(config.id)
            }
            .disabled(runner.state.isActive || config.encrypted)
            Button("Excluir VM…", role: .destructive) { confirmingDelete = true }
                .disabled(runner.state.isActive)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.bold))
                .frame(width: 48, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Surface.cardHeader))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func start() {
        runner.start()
        if !config.os.usesQEMU { openWindow(value: config.id) }
    }

    private func showScreen() {
        if config.os.usesQEMU { runner.showQEMUWindow() } else { openWindow(value: config.id) }
    }
}
