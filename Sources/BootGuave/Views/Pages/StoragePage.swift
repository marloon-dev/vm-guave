import SwiftUI

/// Um disco de VM na tabela de volumes.
private struct VolumeRow: Identifiable, Sendable {
    let id: String
    let name: String
    let vmID: UUID
    let vmName: String
    let provisionedGB: Int
    let url: URL
    var allocatedBytes: Int64?
}

private struct StorageStats: Sendable {
    var totalBytes: Int64 = 0
    var availableBytes: Int64 = 0
    var vmBytes: Int64 = 0
    var imageBytes: Int64 = 0
    var volumes: [VolumeRow] = []

    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    var otherBytes: Int64 { max(0, usedBytes - vmBytes - imageBytes) }
}

struct StoragePage: View {
    @EnvironmentObject private var library: VMLibrary
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var images = ImageLibrary.shared
    @State private var stats: StorageStats?
    @State private var creatingVolume = false

    var body: some View {
        PageScroll {
            PageHeader("Armazenamento", subtitle: "Acompanhe discos e espaço disponível.")

            if let stats {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
                    StatCard(symbol: "cylinder.split.1x2.fill", tint: Brand.green, title: "Espaço total", value: Self.format(stats.totalBytes))
                    StatCard(symbol: "chart.pie.fill", tint: Brand.pink, title: "Em uso", value: Self.format(stats.usedBytes))
                    StatCard(symbol: "leaf.fill", tint: Brand.green, title: "Disponível", value: Self.format(stats.availableBytes))
                }
                usageBar(stats)
                volumes(stats)
            } else {
                ProgressView("Calculando o espaço…")
                    .frame(maxWidth: .infinity, minHeight: 200)
            }
        }
        .task(id: library.configs) { await load() }
        .sheet(isPresented: $creatingVolume, onDismiss: { Task { await load() } }) {
            CreateVolumeSheet()
        }
    }

    // MARK: Barra

    private func usageBar(_ stats: StorageStats) -> some View {
        let total = Double(max(1, stats.totalBytes))
        let segments: [(LocalizedStringKey, Int64, Color)] = [
            ("Discos de VMs", stats.vmBytes, Brand.green),
            ("Imagens", stats.imageBytes, Brand.cream),
            ("Outros arquivos", stats.otherBytes, Color.secondary.opacity(0.5)),
            ("Disponível", stats.availableBytes, Brand.pink),
        ]
        return VStack(alignment: .leading, spacing: 16) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        Rectangle()
                            .fill(segment.2)
                            .frame(width: max(0, geo.size.width * Double(segment.1) / total))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 36)

            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .top, spacing: 12) {
                        Circle().fill(segment.2).frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(segment.0).font(.title3.weight(.semibold))
                            Text(verbatim: "\((Double(segment.1) / total).formatted(.percent.precision(.fractionLength(0)))) (\(Self.format(segment.1)))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Discos de VMs e imagens contam só o espaço de fato ocupado: os discos são esparsos e crescem conforme a VM usa.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Volumes

    private static let columns: [CGFloat] = [0.36, 0.26, 0.15, 0.15, 0.08]

    private func volumes(_ stats: StorageStats) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionTitle("Volumes")
                Spacer()
                Button { creatingVolume = true } label: {
                    Label("Criar volume", systemImage: "plus")
                }
                .buttonStyle(GuaveButtonStyle(large: true))
                .disabled(library.configs.isEmpty)
            }
            VStack(spacing: 0) {
                TableHeaderRow(titles: ["Nome", "Máquina", "Tamanho", "Uso", ""], fractions: Self.columns)
                if stats.volumes.isEmpty {
                    Text("Nenhum disco ainda.")
                        .foregroundStyle(.secondary)
                        .padding(30)
                }
                ForEach(stats.volumes) { volume in
                    Divider()
                    ColumnsLayout(fractions: Self.columns) {
                        HStack(spacing: 16) {
                            Image(systemName: "externaldrive")
                                .font(.system(size: 24, weight: .regular))
                                .foregroundStyle(Brand.cream)
                            Text(verbatim: volume.name)
                                .font(.title3.weight(.semibold))
                                .lineLimit(1)
                        }
                        Text(verbatim: volume.vmName).lineLimit(1)
                        Text(verbatim: "\(volume.provisionedGB) GB").monospacedDigit()
                        Text(verbatim: volume.allocatedBytes.map(Self.format) ?? "—").monospacedDigit()
                        HStack {
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
                    .guaveHover(.row(AnyShape(Rectangle())))
                    .onTapGesture { router.open(vm: volume.vmID) }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Surface.card))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Surface.stroke))
        }
    }

    // MARK: Cálculo

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func load() async {
        images.reload()
        var rows: [VolumeRow] = []
        for config in library.configs {
            let bundle = VMBundle(url: VMBundle.url(for: config.id))
            if config.encrypted && !bundle.isUnlocked {
                rows.append(VolumeRow(id: "\(config.id)-vault", name: String(localized: "Disco criptografado (bloqueado)"),
                                      vmID: config.id, vmName: config.name,
                                      provisionedGB: config.diskGB + config.extraDisks.map(\.sizeGB).reduce(0, +),
                                      url: bundle.vaultURL))
                continue
            }
            rows.append(VolumeRow(id: "\(config.id)-main", name: String(localized: "Disco de \(config.name)"),
                                  vmID: config.id, vmName: config.name, provisionedGB: config.diskGB,
                                  url: config.os.usesQEMU ? bundle.qcow2DiskURL : bundle.diskURL))
            for (index, disk) in config.extraDisks.enumerated() {
                rows.append(VolumeRow(id: disk.id.uuidString, name: String(localized: "Disco adicional \(index + 1)"),
                                      vmID: config.id, vmName: config.name, provisionedGB: disk.sizeGB,
                                      url: bundle.extraDiskURL(disk)))
            }
        }
        // IPSWs entram pela pasta do cache, logo abaixo; aqui só as ISOs.
        let imageURLs = images.images.filter { $0.source != .macOS }.compactMap(\.localURL)
        let library = VMBundle.libraryURL
        let support = library.deletingLastPathComponent()
        let extraImageFolders = [DownloadLocations.ipswFolder, DownloadLocations.driversFolder]

        let result = await Task.detached(priority: .utility) { () -> StorageStats in
            var stats = StorageStats()
            let values = try? support.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            stats.totalBytes = Int64(values?.volumeTotalCapacity ?? 0)
            stats.availableBytes = values?.volumeAvailableCapacityForImportantUsage ?? 0
            stats.vmBytes = Self.allocated(library)
            // ISOs do catálogo (não as que já estão dentro de outras pastas contadas) + caches.
            stats.imageBytes = imageURLs.map { Self.allocated($0) }.reduce(0, +)
                + extraImageFolders.map { Self.allocated($0) }.reduce(0, +)
            stats.volumes = rows.map { row in
                var row = row
                row.allocatedBytes = FileManager.default.fileExists(atPath: row.url.path) ? Self.allocated(row.url) : nil
                return row
            }
            return stats
        }.value
        stats = result
    }

    /// Espaço realmente ocupado (arquivos esparsos contam só os blocos usados).
    nonisolated private static func allocated(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isDirectory != true { return Int64(values.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        while let item = enumerator?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

/// Novo disco vazio para uma VM desligada (aparece como /dev/vdb, /dev/vdc… no Linux).
private struct CreateVolumeSheet: View {
    @EnvironmentObject private var library: VMLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var vmID: UUID?
    @State private var sizeGB = 32

    private var candidates: [VMConfig] {
        library.configs.filter { config in
            !config.os.usesQEMU
                && library.runner(for: config.id)?.state == .stopped
                && !library.isLocked(config.id)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Novo volume") {
                    Picker("Máquina", selection: $vmID) {
                        Text("Escolha…").tag(UUID?.none)
                        ForEach(candidates) { Text(verbatim: $0.name).tag(UUID?.some($0.id)) }
                    }
                    Stepper("Tamanho: \(sizeGB) GB", value: $sizeGB, in: HostLimits.diskGBRange, step: 8)
                    Text("O disco aparece vazio dentro da VM (no Linux: /dev/vdb, /dev/vdc…); formate antes de usar. Só VMs Linux e macOS desligadas (não suspensas) aparecem aqui.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Criar volume") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(vmID == nil)
            }
            .padding()
        }
        .frame(width: 460, height: 300)
        .onAppear { vmID = candidates.first?.id }
    }

    private func create() {
        guard let vmID, var config = library.config(for: vmID) else { return }
        config.extraDisks.append(ExtraDisk(id: UUID(), sizeGB: sizeGB))
        library.applySettings(config)
        dismiss()
    }
}
