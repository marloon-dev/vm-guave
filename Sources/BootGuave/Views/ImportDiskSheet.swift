import SwiftUI
import UniformTypeIdentifiers

/// Criar uma VM a partir do disco de outro virtualizador (UTM, VirtualBox, VMware, Parallels…).
struct ImportDiskSheet: View {
    let onImport: (_ source: URL, _ os: GuestOS, _ name: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var source: URL?
    @State private var os: GuestOS = .linux
    @State private var name = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Disco") {
                    HStack {
                        Text("Arquivo")
                        Spacer()
                        Text(source?.lastPathComponent ?? String(localized: "Nenhum"))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Escolher…", action: choose)
                    }
                    Text("Formatos: \(DiskImporter.supportedExtensions.joined(separator: ", ")). O disco é convertido; o original não é alterado.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("VM") {
                    TextField("Nome", text: $name)
                    Picker("Sistema do disco", selection: $os) {
                        Text("Linux").tag(GuestOS.linux)
                        Text("Windows").tag(GuestOS.windows)
                    }
                    Text("O sistema dentro do disco precisa ser ARM64. Discos de PCs Intel/AMD (x86_64) não dão boot no Mac com Apple Silicon.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    if !QEMUTools.isInstalled {
                        Text("A conversão usa o qemu-img. \(QEMUTools.installHint)")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Importar") {
                    if let source { onImport(source, os, name.trimmingCharacters(in: .whitespaces)) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(source == nil || name.trimmingCharacters(in: .whitespaces).isEmpty || !QEMUTools.isInstalled)
            }
            .padding()
        }
        .frame(width: 500, height: 420)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Escolha o disco a importar")
        panel.allowedContentTypes = DiskImporter.supportedExtensions.compactMap { UTType(filenameExtension: $0) } + [.data]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        source = url
        if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
    }
}
