import CoreGraphics
import Foundation

/// Cliente VNC (RFB 3.8) mínimo para a tela das VMs Windows, falando com o QEMU por um socket
/// Unix local (`-vnc unix:…`). Só o necessário: pixels "raw" em 32 bits, mudança de resolução,
/// teclado por scancode (extensão do QEMU) e mouse absoluto (usb-tablet).
///
/// A leitura roda numa thread própria; `onFrame` é chamado na main queue com a imagem nova.
final class QEMUDisplayClient: @unchecked Sendable {
    private let socketPath: String
    private var fd: Int32 = -1
    private let writeLock = NSLock()
    private let frameLock = NSLock()
    private var stopped = false

    private var width = 0
    private var height = 0
    private var framebuffer = Data()
    private var framePending = false

    /// Imagem nova (main queue).
    var onFrame: ((CGImage) -> Void)?
    /// Conexão perdida depois de aberta (main queue).
    var onDisconnect: (() -> Void)?

    init(socket: URL) {
        socketPath = socket.path
    }

    var size: CGSize {
        frameLock.lock()
        defer { frameLock.unlock() }
        return CGSize(width: width, height: height)
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "VM Guave – tela do QEMU"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        writeLock.lock()
        stopped = true
        if fd >= 0 { shutdown(fd, SHUT_RDWR) }
        writeLock.unlock()
    }

    // MARK: Entrada

    /// Tecla por scancode do PC (código "qnum" do QEMU). `keysym` é opcional.
    func sendKey(scancode: UInt32, keysym: UInt32 = 0, down: Bool) {
        var message = Data([255, 0])
        message.appendBigEndian(UInt16(down ? 1 : 0))
        message.appendBigEndian(keysym)
        message.appendBigEndian(scancode)
        send(message)
    }

    /// Posição absoluta em pixels do framebuffer; `buttons` é a máscara do RFB
    /// (1 esquerdo, 2 meio, 4 direito, 8/16 rodinha para cima/baixo, 32/64 para os lados).
    func sendPointer(x: Int, y: Int, buttons: UInt8) {
        let size = size
        guard size.width > 0 else { return }
        var message = Data([5, buttons])
        message.appendBigEndian(UInt16(clamping: min(max(x, 0), Int(size.width) - 1)))
        message.appendBigEndian(UInt16(clamping: min(max(y, 0), Int(size.height) - 1)))
        send(message)
    }

    private func send(_ data: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard fd >= 0, !stopped else { return }
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    // MARK: Conexão

    private func run() {
        // O QEMU cria o socket logo ao abrir; tenta por alguns segundos.
        var connectedFD: Int32 = -1
        for _ in 0..<50 {
            if isStopped { return }
            connectedFD = Self.connect(socketPath)
            if connectedFD >= 0 { break }
            usleep(100_000)
        }
        guard connectedFD >= 0 else { notifyDisconnect(); return }
        writeLock.lock()
        fd = connectedFD
        writeLock.unlock()
        defer {
            writeLock.lock()
            close(fd)
            fd = -1
            writeLock.unlock()
            notifyDisconnect()
        }
        do {
            try handshake()
            try receiveLoop()
        } catch {
            // Conexão encerrada (VM desligou ou a janela fechou).
        }
    }

    private var isStopped: Bool {
        writeLock.lock()
        defer { writeLock.unlock() }
        return stopped
    }

    private func notifyDisconnect() {
        guard !isStopped else { return }
        DispatchQueue.main.async { [weak self] in self?.onDisconnect?() }
    }

    private func handshake() throws {
        let version = try read(12)
        guard version.starts(with: Data("RFB ".utf8)) else { throw DisplayError.protocolError }
        send(Data("RFB 003.008\n".utf8))

        let count = Int(try read(1)[0])
        guard count > 0 else { throw DisplayError.protocolError }
        let types = try read(count)
        guard types.contains(1) else { throw DisplayError.protocolError } // 1 = sem senha (socket local)
        send(Data([1]))
        guard try readUInt32() == 0 else { throw DisplayError.protocolError }

        send(Data([1])) // ClientInit: conexão compartilhada
        let w = Int(try readUInt16())
        let h = Int(try readUInt16())
        _ = try read(16) // formato do servidor; o nosso vem a seguir
        let nameLength = Int(try readUInt32())
        _ = try read(nameLength)
        resize(width: w, height: h)

        // SetPixelFormat: 32 bpp, profundidade 24, little-endian, cor real, R<<16 G<<8 B → BGRX na memória.
        var format = Data([0, 0, 0, 0, 32, 24, 0, 1])
        format.appendBigEndian(UInt16(255)); format.appendBigEndian(UInt16(255)); format.appendBigEndian(UInt16(255))
        format.append(contentsOf: [16, 8, 0, 0, 0, 0])
        send(format)

        // SetEncodings: raw, DesktopSize, ExtendedDesktopSize, teclado por scancode do QEMU.
        let encodings: [Int32] = [0, -223, -308, -258]
        var message = Data([2, 0])
        message.appendBigEndian(UInt16(encodings.count))
        for encoding in encodings { message.appendBigEndian(UInt32(bitPattern: encoding)) }
        send(message)

        requestUpdate(incremental: false)
    }

    private func requestUpdate(incremental: Bool) {
        let size = size
        var message = Data([3, incremental ? 1 : 0])
        message.appendBigEndian(UInt16(0)); message.appendBigEndian(UInt16(0))
        message.appendBigEndian(UInt16(clamping: Int(size.width)))
        message.appendBigEndian(UInt16(clamping: Int(size.height)))
        send(message)
    }

    private func receiveLoop() throws {
        while !isStopped {
            let type = try read(1)[0]
            switch type {
            case 0: // FramebufferUpdate
                _ = try read(1)
                let rects = Int(try readUInt16())
                var resized = false
                for _ in 0..<rects {
                    let x = Int(try readUInt16()), y = Int(try readUInt16())
                    let w = Int(try readUInt16()), h = Int(try readUInt16())
                    let encoding = Int32(bitPattern: try readUInt32())
                    switch encoding {
                    case 0:
                        try readRaw(x: x, y: y, w: w, h: h)
                    case -223:
                        resized = resize(width: w, height: h) || resized
                    case -308:
                        // O QEMU repete este retângulo em toda atualização completa; só conta se mudou.
                        let screens = Int(try read(4)[0])
                        _ = try read(screens * 16)
                        resized = resize(width: w, height: h) || resized
                    case -258:
                        break // o servidor só confirma que aceita scancodes
                    default:
                        throw DisplayError.protocolError
                    }
                }
                publishFrame()
                requestUpdate(incremental: !resized)
            case 1: // SetColourMapEntries (não usado em cor real)
                _ = try read(3)
                let colors = Int(try readUInt16())
                _ = try read(colors * 6)
            case 2: // Bell
                break
            case 3: // ServerCutText
                _ = try read(3)
                _ = try read(Int(try readUInt32()))
            default:
                throw DisplayError.protocolError
            }
        }
    }

    /// Devolve true se a resolução mudou (aí o framebuffer recomeça vazio).
    @discardableResult
    private func resize(width w: Int, height h: Int) -> Bool {
        frameLock.lock()
        defer { frameLock.unlock() }
        guard w != width || h != height else { return false }
        width = w
        height = h
        framebuffer = Data(count: w * h * 4)
        return true
    }

    private func readRaw(x: Int, y: Int, w: Int, h: Int) throws {
        let rowBytes = w * 4
        guard rowBytes > 0, h > 0 else { return }
        let pixels = try read(rowBytes * h)
        frameLock.lock()
        defer { frameLock.unlock() }
        guard x + w <= width, y + h <= height else { return }
        let stride = width * 4
        framebuffer.withUnsafeMutableBytes { target in
            pixels.withUnsafeBytes { source in
                for row in 0..<h {
                    memcpy(target.baseAddress! + (y + row) * stride + x * 4, source.baseAddress! + row * rowBytes, rowBytes)
                }
            }
        }
    }

    /// Junta as atualizações: a main queue só monta uma imagem por vez.
    private func publishFrame() {
        frameLock.lock()
        let alreadyPending = framePending
        framePending = true
        frameLock.unlock()
        guard !alreadyPending else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameLock.lock()
            self.framePending = false
            let image = Self.makeImage(self.framebuffer, width: self.width, height: self.height)
            self.frameLock.unlock()
            if let image { self.onFrame?(image) }
        }
    }

    static func makeImage(_ data: Data, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    // MARK: Leitura

    private var pending = Data()

    private func read(_ count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while pending.count < count {
            let n = Darwin.read(fd, &buffer, buffer.count)
            guard n > 0 else { throw DisplayError.closed }
            pending.append(buffer, count: n)
        }
        let result = pending.prefix(count)
        pending.removeFirst(count)
        return Data(result)
    }

    private func readUInt16() throws -> UInt16 {
        let d = try read(2)
        return UInt16(d[0]) << 8 | UInt16(d[1])
    }

    private func readUInt32() throws -> UInt32 {
        let d = try read(4)
        return UInt32(d[0]) << 24 | UInt32(d[1]) << 16 | UInt32(d[2]) << 8 | UInt32(d[3])
    }

    private static func connect(_ path: String) -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return -1 }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 { close(fd); return -1 }
        return fd
    }

    private enum DisplayError: Error { case closed, protocolError }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(contentsOf: [UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}
