import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: VMLibrary
    @State private var selection: UUID?
    @State private var showingWizard = false
    @State private var showingDiskImport = false

    var body: some View {
        NavigationSplitView {
            List(library.configs, selection: $selection) { config in
                VMRow(config: config)
                    .tag(config.id)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .overlay {
                if library.configs.isEmpty {
                    ContentUnavailableView(
                        "Nenhuma VM",
                        systemImage: "shippingbox",
                        description: Text("Clique em + para criar sua primeira máquina virtual.")
                    )
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    Menu {
                        Button("VM exportada do VM Guave (.bootguave)…") { importVM() }
                        Button("Disco de outro programa (qcow2, vmdk, vdi, vhdx)…") { showingDiskImport = true }
                    } label: {
                        Label("Importar", systemImage: "square.and.arrow.down")
                    }
                    .help("Importar uma VM ou um disco")
                    Button {
                        showingWizard = true
                    } label: {
                        Label("Nova VM", systemImage: "plus")
                    }
                }
            }
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
                Text("Selecione uma VM")
                    .foregroundStyle(.secondary)
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

    private func importVM() {
        guard let url = FilePicker.chooseVMToImport() else { return }
        Task {
            if let id = await library.importVM(from: url) { selection = id }
        }
    }
}

private struct VMRow: View {
    let config: VMConfig

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: config.os.symbol)
                .frame(width: 22)
            VStack(alignment: .leading) {
                Text(config.name).font(.headline)
                Text("\(config.os.displayName) · \(config.cpuCount) CPU · \(config.memoryGB) GB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
