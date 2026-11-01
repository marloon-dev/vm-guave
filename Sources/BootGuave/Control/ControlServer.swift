import ControlProtocol
import Foundation

/// Socket Unix (só o usuário dono acessa) que recebe comandos do bgctl.
final class ControlServer: @unchecked Sendable {
    static let shared = ControlServer()

    typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "dev.marloon.bootguave.control")

    func start(handler: @escaping Handler) {
        guard source == nil, var addr = ControlSocket.address() else { return }
        let path = ControlSocket.path
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            return
        }
        chmod(path, 0o600)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            if client >= 0 { self?.serve(client, handler: handler) }
        }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        unlink(ControlSocket.path)
    }

    private func serve(_ client: Int32, handler: @escaping Handler) {
        // Cliente travado não pode segurar o servidor.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 64 * 1024 {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if data.contains(0x0A) { break }
        }

        guard let line = data.split(separator: 0x0A).first,
              let request = try? JSONDecoder().decode(ControlRequest.self, from: Data(line)) else {
            Self.reply(ControlResponse(ok: false, output: "Requisição inválida."), to: client)
            return
        }
        Task {
            let response = await handler(request)
            Self.reply(response, to: client)
        }
    }

    private static func reply(_ response: ControlResponse, to client: Int32) {
        var out = (try? JSONEncoder().encode(response)) ?? Data()
        out.append(0x0A)
        out.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(client, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
        close(client)
    }
}
