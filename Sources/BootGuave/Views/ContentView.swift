import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: VMLibrary
    @State private var selection: UUID?
    @State private var showingWizard = false
    @State private var showingDiskImport = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 270)
        } detail: {
            if let selection, let runner = library.runner(for: selection) {
                VMDetailView(
                    runner: runner,
                    onDelete: {
                        self.selection = nil
                        library.delete(selection)
                    },
                    onClone: { self.selection = $0 }
                )
                .id(selection)
            } else {
                EmptyDetailView(hasVMs: !library.configs.isEmpty) { showingWizard = true }
            }
        }
        .tint(Brand.leaf)
        // O logo já está na barra lateral; o título mostra a VM aberta.
        .navigationTitle(selection.flatMap { library.config(for: $0)?.name } ?? "")
        .toolbar {
            ToolbarItemGroup {
                importMenu
                    .help("Importar uma VM ou um disco")
                Button {
                    showingWizard = true
                } label: {
                    Label("Nova VM", systemImage: "plus")
                }
                .help("Criar uma máquina virtual")
            }
        }
        .sheet(isPresented: $showingWizard) {
            NewVMWizard { config in
                library.create(config)
                selection = config.id
                if config.os == .macOS {
                    library.runner(for: config.id)?.installMacOS()
                }
            }
        }
        .sheet(isPresented: $showingDiskImport) {
            ImportDiskSheet { source, os, name in
                Task {
                    if let id = await library.importDisk(from: source, os: os, name: name) { selection = id }
                }
            }
        }
        .overlay {
            if let message = library.busyMessage {
                VStack(spacing: 12) {
                    if let progress = library.busyProgress {
                        ProgressView(value: progress)
                            .frame(width: 220)
                        Text("\(Int(progress * 100))%").monospacedDigit().font(.caption)
                    } else {
                        ProgressView()
                    }
                    Text(message)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert(
            "Erro",
            isPresented: Binding(get: { library.lastError != nil }, set: { if !$0 { library.lastError = nil } })
        ) {
            Button("OK") { library.lastError = nil }
        } message: {
            Text(library.lastError ?? "")
        }
    }

    // MARK: Barra lateral

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: Self.logo)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                Text("VM Guave")
                    .font(.title2.weight(.bold))
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)

            Button {
                showingWizard = true
            } label: {
                Label("Nova VM", systemImage: "plus")
            }
            .buttonStyle(GuaveButtonStyle(expands: true))
            .keyboardShortcut("n", modifiers: .command)
            .padding(.horizontal, 14)
            .padding(.top, 16)

            HStack {
                Text("Máquinas virtuais")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                importMenu
                    .labelStyle(.iconOnly)
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Importar uma VM ou um disco")
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 4)

            if library.configs.isEmpty {
                VStack(spacing: 10) {
                    SmallCubeIcon()
                    Text("Nenhuma VM ainda")
                        .font(.headline)
                    Text("Crie sua primeira máquina virtual para começar.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 60)
            } else {
                List(library.configs, selection: $selection) { config in
                    if let runner = library.runner(for: config.id) {
                        VMRow(runner: runner)
                            .tag(config.id)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }

    /// Arte original do ícone; o applicationIconImage vem dentro do quadrado cinza do macOS.
    private static let logo: NSImage = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap(NSImage.init(contentsOf:)) ?? NSApp.applicationIconImage

    private var importMenu: some View {
        Menu {
            Button("VM exportada do VM Guave (.bootguave)…") { importVM() }
            Button("Disco de outro programa (qcow2, vmdk, vdi, vhdx)…") { showingDiskImport = true }
        } label: {
            Label("Importar", systemImage: "square.and.arrow.down")
        }
    }

    private func importVM() {
        guard let url = FilePicker.chooseVMToImport() else { return }
        Task {
            if let id = await library.importVM(from: url) { selection = id }
        }
    }
}

private struct VMRow: View {
    @ObservedObject var runner: VMRunner

    private var config: VMConfig { runner.config }

    var body: some View {
        HStack(spacing: 10) {
            OSTile(os: config.os, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(config.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(runner.state == .stopped
                     ? "\(config.os.displayName) · \(config.cpuCount) CPU · \(config.memoryGB) GB"
                     : runner.state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if runner.state != .stopped {
                Circle()
                    .fill(runner.state.color)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(runner.state.label)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Painel principal quando nenhuma VM está selecionada.
private struct EmptyDetailView: View {
    let hasVMs: Bool
    let onCreate: () -> Void

    var body: some View {
        ZStack {
            LeafBackdrop()
            VStack(spacing: 0) {
                VMIllustration()
                    .frame(width: 300, height: 250)
                Text(hasVMs ? "Escolha uma VM na barra lateral" : "Suas máquinas virtuais, em um só lugar")
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)
                Text(hasVMs
                     ? "Ou crie outra para testar um sistema novo."
                     : "Crie uma VM para rodar Linux, Windows ou macOS ao lado do seu Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                Button(hasVMs ? "Nova VM" : "Criar primeira VM", action: onCreate)
                    .buttonStyle(GuaveButtonStyle(large: true))
                    .padding(.top, 28)
            }
            .padding(40)
            .frame(maxWidth: 620)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
