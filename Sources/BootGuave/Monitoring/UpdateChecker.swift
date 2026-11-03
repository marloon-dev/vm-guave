import Observation
import AppKit
import ControlProtocol
import CryptoKit
import Foundation

/// Procura versões novas na última release do GitHub (o repositório é público) e atualiza o app:
/// baixa o .dmg, confere o SHA-256 publicado pelo GitHub e a assinatura Ed25519 do VM Guave, copia o app de dentro e troca o app
/// instalado quando ele fecha. Os avisos usam só os alertas padrão do macOS, sem mexer nas telas.
///
/// "Na hora": verifica ao abrir, a cada 10 minutos e sempre que o app volta para a frente
/// (no máximo uma vez a cada 2 minutos). Para publicar, use scripts/release.sh.
@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()
    static let feedURL = URL(string: "https://api.github.com/repos/marloon-dev/vm-guave/releases/latest")!
    static let siteURL = URL(string: "https://marloon-dev.github.io/vm-guave/")!
    /// Chave pública Ed25519 das releases. A privada fica só no Keychain de quem publica
    /// (scripts/update-signing.swift); sem a assinatura dela, nenhuma atualização é instalada,
    /// mesmo que alguém consiga publicar no GitHub.
    nonisolated static let signingPublicKey = "/XrQ89hXWupunTtgLHGqSTknixnQR/d5nO4vuClgSZo="
    private static let interval: TimeInterval = 10 * 60
    private static let minimumGap: TimeInterval = 2 * 60

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: AppSettings.Key.lastUpdateCheck) as? Date

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Última release encontrada mais nova que este app.
    @ObservationIgnored private var latest: Release?
    /// Resposta anterior da API: com If-None-Match o GitHub responde 304 (sem corpo e sem
    /// gastar o limite de consultas) quando nada mudou.
    @ObservationIgnored private var feedETag: String?
    @ObservationIgnored private var feedData: Data?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activationObserver: Any?
    /// Versões já anunciadas nesta sessão ("Depois" não insiste até o app abrir de novo).
    @ObservationIgnored private var announced: Set<String> = []
    /// Aviso esperando o app voltar para a frente (não interrompe quem está em outro app).
    @ObservationIgnored private var pendingAnnouncement: Release?
    @ObservationIgnored private var downloading = false
    /// App novo já copiado do .dmg; é instalado quando o VM Guave fecha.
    @ObservationIgnored private var stagedApp: URL?
    @ObservationIgnored private var stagedVersion: String?
    @ObservationIgnored private var relaunchAfterInstall = false

    private var downloadsDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ControlSocket.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }

    // MARK: Verificação

    /// Chamado ao abrir o app.
    func startAutomaticChecks() {
        guard timer == nil else { return }
        removeLeftovers()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor in UpdateChecker.shared.automaticCheck() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in UpdateChecker.shared.appBecameActive() }
        }
        automaticCheck()
    }

    private func automaticCheck() {
        guard AppSettings.autoCheckUpdates else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.minimumGap { return }
        Task { await check(announce: true) }
    }

    private func appBecameActive() {
        if let release = pendingAnnouncement {
            pendingAnnouncement = nil
            announce(release)
        } else {
            automaticCheck()
        }
    }

    /// Verificação manual (botão "Verificar agora") não abre aviso; a página mostra o resultado.
    func check(announce: Bool = false) async {
        if status == .checking || downloading { return }
        status = .checking
        do {
            var request = URLRequest(url: Self.feedURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            if let feedETag, feedData != nil { request.setValue(feedETag, forHTTPHeaderField: "If-None-Match") }
            var (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 304, let cached = feedData {
                    data = cached
                } else if !(200..<300).contains(http.statusCode) {
                    throw DownloadError.httpStatus(http.statusCode)
                } else {
                    feedETag = http.value(forHTTPHeaderField: "ETag")
                    feedData = data
                }
            }
            let release = try Release.parse(data)
            if Self.isNewer(release.version, than: Self.currentVersion) {
                latest = release
                status = .available(version: release.version, url: release.pageURL)
                let skipped = UserDefaults.standard.string(forKey: AppSettings.Key.skippedUpdateVersion)
                if announce, release.version != skipped, release.version != stagedVersion,
                   !announced.contains(release.version) {
                    announced.insert(release.version)
                    if NSApp.isActive {
                        self.announce(release)
                    } else {
                        // Pisca o ícone no Dock e avisa quando o usuário voltar ao app.
                        pendingAnnouncement = release
                        NSApp.requestUserAttention(.informationalRequest)
                    }
                }
            } else {
                status = .upToDate
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
        lastCheck = Date()
        UserDefaults.standard.set(lastCheck, forKey: AppSettings.Key.lastUpdateCheck)
    }

    /// Botão "Baixar" da página Configuração: atualiza pelo app (ou abre o site, se não der).
    func update() {
        guard let latest else {
            NSWorkspace.shared.open(Self.siteURL)
            return
        }
        install(latest)
    }

    // MARK: Avisos (alertas padrão do macOS)

    private func announce(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Nova versão do VM Guave")
        var text = String(localized: "A versão \(release.version) está disponível. Você está com a \(Self.currentVersion).")
        let notes = Self.plainText(release.notes)
        if !notes.isEmpty { text += "\n\n" + notes }
        alert.informativeText = text
        alert.addButton(withTitle: String(localized: "Atualizar agora"))
        alert.addButton(withTitle: String(localized: "Depois"))
        alert.addButton(withTitle: String(localized: "Pular esta versão"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            install(release)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(release.version, forKey: AppSettings.Key.skippedUpdateVersion)
        default:
            break
        }
    }

    private func announceReady(_ version: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Atualização pronta")
        alert.informativeText = String(localized: "A versão \(version) foi baixada e conferida. O VM Guave vai fechar e abrir de novo já atualizado; se houver VMs ligadas, ele pergunta antes o que fazer com elas.\n\nSe escolher \"Depois\", a atualização é instalada quando você fechar o app.")
        alert.addButton(withTitle: String(localized: "Reiniciar e atualizar"))
        alert.addButton(withTitle: String(localized: "Depois"))
        if alert.runModal() == .alertFirstButtonReturn {
            relaunchAfterInstall = true
            NSApp.terminate(nil)
        }
    }

    private func announceFailure(_ message: String, release: Release) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Não foi possível atualizar")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Baixar pelo site"))
        alert.addButton(withTitle: String(localized: "Fechar"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.pageURL)
        }
    }

    /// Notas da release em texto simples (sem #, ** e afins), cortadas para caber no alerta.
    private static func plainText(_ markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.components(separatedBy: .newlines) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "• " + line.dropFirst(2) }
            lines.append(line.trimmingCharacters(in: .whitespaces))
        }
        var text = lines.joined(separator: "\n")
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 700 { text = String(text.prefix(700)) + "…" }
        return text
    }

    // MARK: Baixar e preparar

    /// Pode trocar o app no lugar? (não dá se ele roda direto do .dmg ou de pasta sem permissão)
    private var canInstallInPlace: Bool {
        let app = Bundle.main.bundleURL
        guard !app.path.contains("/AppTranslocation/"), !app.path.hasPrefix("/Volumes/") else { return false }
        let fm = FileManager.default
        return fm.isWritableFile(atPath: app.deletingLastPathComponent().path) && fm.isWritableFile(atPath: app.path)
    }

    private func install(_ release: Release) {
        if release.version == stagedVersion {
            announceReady(release.version)
            return
        }
        guard let dmgURL = release.dmgURL, canInstallInPlace else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        guard !downloading else { return }
        downloading = true
        Task {
            defer { downloading = false }
            do {
                let dir = downloadsDir
                try? FileManager.default.removeItem(at: dir)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dmg = dir.appendingPathComponent(dmgURL.lastPathComponent)
                _ = try await FileDownloader(destination: dmg) { _ in }.download(from: dmgURL)
                guard let signatureURL = release.signatureURL else { throw UpdateError.badSignature }
                let signature = dir.appendingPathComponent(signatureURL.lastPathComponent)
                _ = try await FileDownloader(destination: signature) { _ in }.download(from: signatureURL)
                let staged = try await Self.prepare(dmg: dmg, signature: signature, release: release, in: dir)
                try? FileManager.default.removeItem(at: dir)
                stagedApp = staged
                stagedVersion = release.version
                announceReady(release.version)
            } catch {
                announceFailure(error.localizedDescription, release: release)
            }
        }
    }

    enum UpdateError: LocalizedError {
        case checksumMismatch
        case badSignature
        case appNotFound
        case wrongApp(String)

        var errorDescription: String? {
            switch self {
            case .checksumMismatch:
                return String(localized: "O arquivo baixado não confere com o publicado (SHA-256 diferente). Nada foi instalado.")
            case .badSignature:
                return String(localized: "A atualização não tem a assinatura do VM Guave. Por segurança, nada foi instalado.")
            case .appNotFound:
                return String(localized: "O instalador baixado não contém o VM Guave.")
            case .wrongApp(let detail):
                return String(localized: "O app baixado não é a versão esperada (\(detail)). Nada foi instalado.")
            }
        }
    }

    /// Confere o .dmg, monta sem abrir janela, confere o app de dentro e copia ao lado do app
    /// instalado (mesmo volume: a troca vira um simples "mv").
    nonisolated private static func prepare(dmg: URL, signature: URL, release: Release, in dir: URL) async throws -> URL {
        // Sem o hash publicado não há o que conferir: recusa em vez de pular a verificação.
        guard let expected = release.sha256 else { throw UpdateError.checksumMismatch }
        let digest = try await Task.detached { try sha256(of: dmg) }.value
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else { throw UpdateError.checksumMismatch }
        // Autenticidade: a assinatura Ed25519 do hash tem de ser da chave do VM Guave.
        guard let text = try? String(contentsOf: signature, encoding: .utf8),
              let signatureData = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let keyData = Data(base64Encoded: signingPublicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              key.isValidSignature(signatureData, for: digest) else {
            throw UpdateError.badSignature
        }
        let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
        let mount = dir.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        _ = try await QEMUTools.run(hdiutil, ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { try? Process.run(hdiutil, arguments: ["detach", mount.path, "-force"]).waitUntilExit() }

        let contents = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let source = contents.first(where: { $0.pathExtension == "app" }),
              let plist = NSDictionary(contentsOf: source.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.appNotFound
        }
        let bundleID = plist["CFBundleIdentifier"] as? String
        let version = plist["CFBundleShortVersionString"] as? String
        guard bundleID == ControlSocket.bundleIdentifier else { throw UpdateError.wrongApp(bundleID ?? "?") }
        guard version == release.version else { throw UpdateError.wrongApp(version ?? "?") }

        let parent = await MainActor.run { Bundle.main.bundleURL.deletingLastPathComponent() }
        let staged = parent.appendingPathComponent(".VM Guave \(release.version).update.app", isDirectory: true)
        try? FileManager.default.removeItem(at: staged)
        _ = try await QEMUTools.run(URL(fileURLWithPath: "/usr/bin/ditto"), [source.path, staged.path])
        _ = try await QEMUTools.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", staged.path])
        _ = try? await QEMUTools.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", staged.path])
        return staged
    }

    nonisolated private static func sha256(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }

    // MARK: Instalar ao fechar

    /// Chamado em applicationWillTerminate. Se há atualização pronta, um shell espera este
    /// processo sair, troca o app (guardando o antigo até dar certo) e, se pedido, abre o novo.
    /// - Parameter relaunch: reabrir depois (pedido de "Reiniciar e atualizar" ou da troca de idioma).
    /// - Returns: true se havia atualização (aí ela cuida de reabrir; o reinício do idioma não roda).
    func installOnQuitIfReady(relaunch: Bool) -> Bool {
        guard let staged = stagedApp, FileManager.default.fileExists(atPath: staged.path) else { return false }
        let reopen = relaunch || relaunchAfterInstall
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        APP="$1"; NEW="$2"; RELAUNCH="$3"; OLD="$APP.old-$$"
        if mv "$APP" "$OLD" && mv "$NEW" "$APP"; then
            rm -rf "$OLD"
        else
            [ -d "$OLD" ] && [ ! -d "$APP" ] && mv "$OLD" "$APP"
        fi
        [ "$RELAUNCH" = 1 ] && exec /usr/bin/open "$APP"
        exit 0
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script, "vmguave-update", Bundle.main.bundlePath, staged.path, reopen ? "1" : "0"]
        try? task.run()
        return true
    }

    /// Cópias preparadas e nunca instaladas (o app foi morto antes de fechar normalmente).
    private func removeLeftovers() {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent()
        let items = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        for item in items where item.lastPathComponent.hasPrefix(".VM Guave ") && item.lastPathComponent.hasSuffix(".update.app") {
            try? FileManager.default.removeItem(at: item)
        }
        try? FileManager.default.removeItem(at: downloadsDir)
    }

    // MARK: Versões

    /// Compara "0.10.1" com "0.9.3" número a número.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = pa[safe: i] ?? 0, y = pb[safe: i] ?? 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Release do GitHub (só o que o atualizador usa).
private struct Release: Sendable {
    let version: String
    let notes: String
    let pageURL: URL
    let dmgURL: URL?
    /// SHA-256 do .dmg calculado pelo GitHub ("sha256:…" no campo digest).
    let sha256: String?
    /// Assinatura Ed25519 do .dmg (<nome>.dmg.sig, enviada pelo scripts/release.sh).
    let signatureURL: URL?

    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let digest: String?
        }
        let tag_name: String
        let body: String?
        let html_url: URL
        let assets: [Asset]
    }

    static func parse(_ data: Data) throws -> Release {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let dmg = payload.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
        let tag = payload.tag_name
        return Release(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            notes: payload.body ?? "",
            pageURL: payload.html_url,
            dmgURL: dmg?.browser_download_url,
            sha256: dmg?.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil },
            signatureURL: dmg.flatMap { dmg in payload.assets.first { $0.name == dmg.name + ".sig" }?.browser_download_url }
        )
    }
}
