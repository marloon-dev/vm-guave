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

    static let installHint = "Instale com: brew install qemu swtpm"

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
            return "\(name) não encontrado. \(QEMUTools.installHint)"
        case .toolFailed(let tool, let message):
            return "\(tool) falhou: \(message.isEmpty ? "erro desconhecido" : message)"
        case .qmp(let message):
            return "Controle do QEMU falhou: \(message)"
        case .unsupported(let what):
            return "\(what) não é suportado em VMs Windows (motor QEMU)."
        }
    }
}
