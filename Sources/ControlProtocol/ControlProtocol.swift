import Foundation

/// Uma linha JSON por requisição; o app responde com uma linha JSON e fecha a conexão.
public struct ControlRequest: Codable, Sendable {
    public var command: String
    public var args: [String]

    public init(command: String, args: [String]) {
        self.command = command
        self.args = args
    }
}

public struct ControlResponse: Codable, Sendable {
    public var ok: Bool
    public var output: String

    public init(ok: Bool, output: String) {
        self.ok = ok
        self.output = output
    }
}

public enum ControlSocket {
    public static let bundleIdentifier = "dev.marloon.bootguave"

    public static var path: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Boot Guave/control.sock").path
    }

    /// Preenche um sockaddr_un com o caminho do socket. Retorna nil se o caminho não couber.
    public static func address() -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return addr
    }
}
