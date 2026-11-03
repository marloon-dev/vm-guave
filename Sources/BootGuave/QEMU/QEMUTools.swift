import Foundation

/// Localiza o QEMU/swtpm instalados pelo Homebrew (Apple Silicon ou Intel).
enum QEMUTools {
    private static let prefixes = ["/opt/homebrew", "/usr/local"]

    private static func find(_ relative: String) -> URL? {
        prefixes
            .map { URL(fileURLWithPath: $0).appendingPathComponent(relative) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var qemuImg: URL? { find("bin/qemu-img") }
    static var qemuSystem: URL? { find("bin/qemu-system-aarch64") }
    static var swtpm: URL? { find("bin/swtpm") }
    static var firmwareCode: URL? { find("share/qemu/edk2-aarch64-code.fd") }
    static var firmwareVarsTemplate: URL? { find("share/qemu/edk2-arm-vars.fd") }

    static var isInstalled: Bool {
        qemuImg != nil && qemuSystem != nil && firmwareCode != nil && firmwareVarsTemplate != nil
    }

    static let installHint = String(localized: "Instale com: brew install qemu swtpm")

    /// Versão mínima recomendada: correções de segurança recentes e o suspender completo
    /// (estado do ramfb e do TPM no snapshot).
    static let recommendedMajor = 9

    nonisolated(unsafe) private static var cachedVersion: (major: Int, minor: Int)?

    /// Versão do qemu-system-aarch64 instalado (lida uma vez por sessão).
    static func installedVersion() async -> (major: Int, minor: Int)? {
        if let cachedVersion { return cachedVersion }
        guard let qemu = qemuSystem, let output = try? await run(qemu, ["--version"]) else { return nil }
        // "QEMU emulator version 11.1.3"
        guard let range = output.range(of: #"version (\d+)\.(\d+)"#, options: .regularExpression) else { return nil }
        let numbers = output[range].dropFirst("version ".count).split(separator: ".").compactMap { Int($0) }
        guard numbers.count >= 2 else { return nil }
        cachedVersion = (numbers[0], numbers[1])
        return cachedVersion
    }

    /// Aviso (não bloqueia) quando o QEMU instalado é antigo.
    static func outdatedWarning() async -> String? {
        guard let version = await installedVersion(), version.major < recommendedMajor else { return nil }
        return String(localized: "O QEMU instalado (\(version.major).\(version.minor)) é antigo e pode ter falhas de segurança. Atualize com: brew upgrade qemu")
    }

    static func require(_ tool: URL?, _ name: String) throws -> URL {
        guard let tool else { throw QEMUError.notInstalled(name) }
        return tool
    }

    /// Roda uma ferramenta e devolve a saída padrão. `onOutput` recebe pedaços conforme chegam.
    static func run(_ tool: URL, _ arguments: [String], onOutput: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err

            let collected = OutputBuffer()
            out.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                collected.append(text)
                onOutput?(text)
            }
            process.terminationHandler = { process in
                out.fileHandleForReading.readabilityHandler = nil
                let rest = out.fileHandleForReading.readDataToEndOfFile()
                collected.append(String(decoding: rest, as: UTF8.self))
                let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: collected.value)
                } else {
                    let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: QEMUError.toolFailed(tool.lastPathComponent, message))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private var text = ""
    private let lock = NSLock()
    func append(_ more: String) { lock.withLock { text += more } }
    var value: String { lock.withLock { text } }
}

enum QEMUError: LocalizedError {
    case notInstalled(String)
    case toolFailed(String, String)
    case qmp(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name):
            return String(localized: "\(name) não encontrado. \(QEMUTools.installHint)")
        case .toolFailed(let tool, let message):
            return String(localized: "\(tool) falhou: \(message.isEmpty ? "erro desconhecido" : message)")
        case .qmp(let message):
            return String(localized: "Controle do QEMU falhou: \(message)")
        case .unsupported(let what):
            return String(localized: "\(what) não é suportado em VMs Windows (motor QEMU).")
        }
    }
}
