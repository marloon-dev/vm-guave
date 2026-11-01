import Foundation

/// Distros Linux ARM64 com download guiado. Em vez de URLs fixas (que envelhecem),
/// lê o índice do espelho oficial e escolhe a versão mais recente.
enum Distro: String, CaseIterable, Identifiable {
    case ubuntuDesktop
    case ubuntuServer
    case fedoraWorkstation
    case debian

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ubuntuDesktop: return "Ubuntu Desktop (LTS)"
        case .ubuntuServer: return "Ubuntu Server (LTS)"
        case .fedoraWorkstation: return "Fedora Workstation"
        case .debian: return "Debian (netinst)"
        }
    }

    var suggestedVMName: String {
        switch self {
        case .ubuntuDesktop, .ubuntuServer: return "Ubuntu"
        case .fedoraWorkstation: return "Fedora"
        case .debian: return "Debian"
        }
    }

    func latestISOURL() async throws -> URL {
        switch self {
        case .ubuntuDesktop: return try await Self.ubuntu(flavor: "desktop")
        case .ubuntuServer: return try await Self.ubuntu(flavor: "live-server")
        case .fedoraWorkstation: return try await Self.fedora()
        case .debian: return try await Self.debian()
        }
    }

    // MARK: Resolvedores

    private static func ubuntu(flavor: String) async throws -> URL {
        let base = URL(string: "https://cdimage.ubuntu.com/releases/")!
        // LTS = YY.04 com ano par.
        let lts = try await matches(in: base, pattern: #"href="(\d{2}\.04)/""#)
            .filter { (Int($0.prefix(2)) ?? 1) % 2 == 0 }
        guard let version = lts.max(by: numericLess) else { throw DownloadError.notFound("Ubuntu") }
        let release = base.appendingPathComponent("\(version)/release/")
        let isos = try await matches(in: release, pattern: #"(ubuntu-[0-9.]+-\#(flavor)-arm64\.iso)"#)
        guard let iso = isos.max(by: numericLess) else { throw DownloadError.notFound("Ubuntu") }
        return release.appendingPathComponent(iso)
    }

    private static func fedora() async throws -> URL {
        let base = URL(string: "https://dl.fedoraproject.org/pub/fedora/linux/releases/")!
        let versions = try await matches(in: base, pattern: #"href="(\d+)/""#)
            .compactMap(Int.init)
            .sorted(by: >)
        // A versão mais nova pode ainda não ter a ISO aarch64 publicada; tenta a anterior.
        for version in versions.prefix(2) {
            let dir = base.appendingPathComponent("\(version)/Workstation/aarch64/iso/")
            if let iso = try? await matches(in: dir, pattern: #"(Fedora-Workstation-Live-[A-Za-z0-9._-]+\.aarch64\.iso)"#)
                .max(by: numericLess) {
                return dir.appendingPathComponent(iso)
            }
        }
        throw DownloadError.notFound("Fedora")
    }

    private static func debian() async throws -> URL {
        let dir = URL(string: "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/")!
        guard let iso = try await matches(in: dir, pattern: #"(debian-[0-9.]+-arm64-netinst\.iso)"#)
            .max(by: numericLess) else { throw DownloadError.notFound("Debian") }
        return dir.appendingPathComponent(iso)
    }

    /// Baixa uma página de índice e devolve o 1º grupo de captura de cada ocorrência.
    private static func matches(in url: URL, pattern: String) async throws -> [String] {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadError.httpStatus(http.statusCode)
        }
        let html = String(decoding: data, as: UTF8.self)
        let regex = try NSRegularExpression(pattern: pattern)
        let results = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        return Array(Set(results.compactMap { match in
            Range(match.range(at: 1), in: html).map { String(html[$0]) }
        }))
    }

    private static func numericLess(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedAscending
    }
}

enum DownloadLocations {
    static var isoFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// IPSWs ficam num cache compartilhado entre VMs macOS (cada um tem ~15 GB).
    static var ipswFolder: URL {
        VMBundle.libraryURL.deletingLastPathComponent().appendingPathComponent("IPSW", isDirectory: true)
    }

    /// Drivers do Windows (virtio-win), compartilhados entre VMs.
    static var driversFolder: URL {
        VMBundle.libraryURL.deletingLastPathComponent().appendingPathComponent("Drivers", isDirectory: true)
    }
}

enum WindowsDownloads {
    /// A Microsoft exige escolher idioma e gera um link temporário; abrimos a página oficial.
    static let windows11ARMPage = URL(string: "https://www.microsoft.com/software-download/windows11arm64")!
    /// Drivers virtio (inclui ARM64) mantidos pelo projeto Fedora: rede virtio-net etc.
    static let virtioWinISO = URL(string: "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso")!
}
