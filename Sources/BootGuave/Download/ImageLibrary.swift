import Observation
import AppKit
import Foundation

/// Uma imagem de instalação na página Imagens: do catálogo oficial ou adicionada pelo usuário.
struct InstallImage: Identifiable, Hashable {
    enum Source: Hashable {
        case distro(Distro)
        case windows
        case macOS
        case custom
    }

    let id: String
    let title: String
    let source: Source
    let os: GuestOS
    /// Arquivo no Mac, se já baixado/importado.
    var localURL: URL?
    var sizeBytes: Int64?

    var isOfficial: Bool { source != .custom }
}

/// Monta a lista de imagens e baixa as do catálogo. Compartilhado para o progresso continuar
/// quando o usuário troca de página.
@MainActor
@Observable
final class ImageLibrary {
    static let shared = ImageLibrary()

    private(set) var images: [InstallImage] = []
    /// Downloads em andamento: id da imagem → progresso (nil = preparando).
    private(set) var downloads: [String: Double?] = [:]
    var lastError: String?

    @ObservationIgnored private var downloaders: [String: FileDownloader] = [:]
    private let importedKey = "importedImages"

    private var importedPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: importedKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: importedKey) }
    }

    func reload() {
        let fm = FileManager.default
        var isoFiles = ((try? fm.contentsOfDirectory(at: DownloadLocations.isoFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { $0.pathExtension.lowercased() == "iso" }
        for path in importedPaths where fm.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if !isoFiles.contains(url) { isoFiles.append(url) }
        }
        // Drivers do Windows não são sistemas.
        isoFiles.removeAll { $0.lastPathComponent.lowercased().contains("virtio-win") }

        var used = Set<URL>()
        var result: [InstallImage] = []

        for distro in Distro.allCases {
            let match = isoFiles.filter { Self.matches(distro, $0) }.max { $0.lastPathComponent < $1.lastPathComponent }
            if let match { used.insert(match) }
            result.append(InstallImage(id: "distro-\(distro.rawValue)", title: distro.displayName, source: .distro(distro),
                                       os: .linux, localURL: match, sizeBytes: match.flatMap(Self.size)))
        }

        let windows = isoFiles.filter { Self.isWindows($0) }.max { $0.lastPathComponent < $1.lastPathComponent }
        if let windows { used.insert(windows) }
        result.append(InstallImage(id: "windows11", title: "Windows 11 ARM", source: .windows, os: .windows,
                                   localURL: windows, sizeBytes: windows.flatMap(Self.size)))

        let ipsw = ((try? fm.contentsOfDirectory(at: DownloadLocations.ipswFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "ipsw" }
            .max { $0.lastPathComponent < $1.lastPathComponent }
        result.append(InstallImage(id: "macos", title: "macOS", source: .macOS, os: .macOS,
                                   localURL: ipsw, sizeBytes: ipsw.flatMap(Self.size)))

        for url in isoFiles where !used.contains(url) {
            result.append(InstallImage(id: "custom-\(url.path)", title: url.deletingPathExtension().lastPathComponent,
                                       source: .custom, os: Self.isWindows(url) ? .windows : .linux,
                                       localURL: url, sizeBytes: Self.size(url)))
        }
        images = result
    }

    /// Adiciona uma ISO escolhida pelo usuário (fica onde está; só entra na lista).
    func importImage(_ url: URL) {
        if !importedPaths.contains(url.path) { importedPaths.append(url.path) }
        ActivityLog.shared.add(.imageImported, url.lastPathComponent)
        reload()
    }

    func canRemoveFromList(_ image: InstallImage) -> Bool {
        guard let url = image.localURL else { return false }
        return importedPaths.contains(url.path)
    }

    func removeFromList(_ image: InstallImage) {
        guard let url = image.localURL else { return }
        importedPaths.removeAll { $0 == url.path }
        reload()
    }

    func download(_ image: InstallImage) {
        guard case .distro(let distro) = image.source, downloads[image.id] == nil else { return }
        downloads[image.id] = .some(nil)
        lastError = nil
        Task {
            do {
                let remote = try await distro.latestISOURL()
                let destination = DownloadLocations.isoFolder.appendingPathComponent(remote.lastPathComponent)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    let id = image.id
                    let downloader = FileDownloader(destination: destination) { value in
                        Task { @MainActor in
                            if ImageLibrary.shared.downloads[id] != nil { ImageLibrary.shared.downloads[id] = value }
                        }
                    }
                    downloaders[image.id] = downloader
                    downloads[image.id] = 0
                    _ = try await downloader.download(from: remote)
                    try await ISOChecksum.verify(destination, downloadedFrom: remote)
                }
                ActivityLog.shared.add(.imageDownloaded, remote.lastPathComponent)
            } catch {
                if case DownloadError.cancelled = error {} else { lastError = error.localizedDescription }
            }
            downloads[image.id] = nil
            downloaders[image.id] = nil
            reload()
        }
    }

    func cancelDownload(_ image: InstallImage) {
        downloaders[image.id]?.cancel()
    }

    // MARK: Reconhecer arquivos

    private static func matches(_ distro: Distro, _ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        switch distro {
        case .ubuntuDesktop: return name.contains("ubuntu") && name.contains("desktop")
        case .ubuntuServer: return name.contains("ubuntu") && name.contains("server")
        case .fedoraWorkstation: return name.contains("fedora") && name.contains("workstation")
        case .debian: return name.contains("debian")
        }
    }

    private static func isWindows(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return (name.contains("win11") || name.contains("windows")) && !name.contains("virtio")
    }

    private static func size(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }
}
