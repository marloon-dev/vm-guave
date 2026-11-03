import CoreGraphics
import Foundation

/// Cliente VNC (RFB 3.8) mínimo para a tela das VMs Windows, falando com o QEMU por um socket
/// Unix local (`-vnc unix:…`). Só o necessário: pixels "raw" em 32 bits, mudança de resolução,
/// teclado por scancode (extensão do QEMU) e mouse absoluto (usb-tablet).
///
/// A leitura roda numa thread própria e escreve os pixels direto no framebuffer (sem buffers
/// intermediários). A tela puxa as áreas alteradas no ritmo do monitor (`copyDirty`).
final class QEMUDisplayClient: @unchecked Sendable {
    private let socketPath: String
    private var fd: Int32 = -1
    private let writeLock = NSLock()
    private let frameLock = NSLock()
    private var stopped = false

    private var width = 0
    private var height = 0
    /// BGRX, `width * 4` bytes por linha.
    private var framebuffer: UnsafeMutableRawPointer?
    /// Área alterada desde a última `copyDirty` (em pixels do framebuffer).
    private var dirty = CGRect.null
    /// Muda a cada troca de resolução; a tela recria as superfícies quando vê um valor novo.
    private(set) var generation = 0
    /// Rascunho reaproveitado para retângulos mais estreitos que a tela.
    private var scratch: UnsafeMutableRawPointer?
    private var scratchSize = 0

    /// Conexão perdida depois de aberta (main queue).
    var onDisconnect: (() -> Void)?

    init(socket: URL) {
        socketPath = socket.path
    }

    deinit {
        framebuffer?.deallocate()
        scratch?.deallocate()
    }

    /// Copia para `destination` (mesmo tamanho, `bytesPerRow` próprio) o que mudou desde a
    /// última chamada e devolve essa área, ou nil se nada mudou. `force` copia a tela toda.
    func copyDirty(into destination: UnsafeMutableRawPointer, bytesPerRow: Int, force: Bool) -> (rect: CGRect, generation: Int)? {
        frameLock.lock()
        defer { frameLock.unlock() }
        guard let framebuffer, width > 0, height > 0 else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        let area = force ? full : dirty.intersection(full)
        guard !area.isNull, !area.isEmpty else { return nil }
        let x = Int(area.minX), y = Int(area.minY), w = Int(area.width), h = Int(area.height)
        let stride = width * 4
        for row in y..<(y + h) {
            let target = destination + row * bytesPerRow + x * 4
            memcpy(target, framebuffer + row * stride + x * 4, w * 4)
            // O 4º byte vem zerado do QEMU; na tela ele é a opacidade. O laço vira SIMD no -O.
            let pixels = target.assumingMemoryBound(to: UInt32.self)
            for i in 0..<w { pixels[i] |= 0xFF00_0000 }
        }
        dirty = .null
        return (area, generation)
    }

    /// Área alterada sem consumir (para a tela saber se há o que desenhar).
    var hasChanges: Bool {
        frameLock.lock()
        defer { frameLock.unlock() }
        return !dirty.isNull
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
        framebuffer?.deallocate()
        framebuffer = w > 0 && h > 0 ? UnsafeMutableRawPointer.allocate(byteCount: w * h * 4, alignment: 64) : nil
        if let framebuffer { memset(framebuffer, 0, w * h * 4) }
        width = w
        height = h
        dirty = CGRect(x: 0, y: 0, width: w, height: h)
        generation += 1
        return true
    }

    /// Pixels "raw": vão do socket direto para o framebuffer. Com a largura toda, numa leitura
    /// só; mais estreitos, pelo rascunho e depois linha a linha (poucas chamadas ao sistema).
    private func readRaw(x: Int, y: Int, w: Int, h: Int) throws {
        let rowBytes = w * 4
        guard rowBytes > 0, h > 0 else { return }
        let total = rowBytes * h
        frameLock.lock()
        let fits = framebuffer != nil && x + w <= width && y + h <= height
        let fullWidth = fits && x == 0 && w == width
        let stride = width * 4
        let target = framebuffer
        frameLock.unlock()

        guard fits, let target else {
            try skip(total)
            return
        }
        if fullWidth {
            // A escrita concorre com a cópia da tela, mas só nas linhas deste retângulo,
            // que ainda vão ser marcadas como alteradas: no pior caso aparece um quadro misto.
            try readExact(into: target + y * stride, count: total)
        } else {
            if scratchSize < total {
                scratch?.deallocate()
                scratch = UnsafeMutableRawPointer.allocate(byteCount: total, alignment: 64)
                scratchSize = total
            }
            try readExact(into: scratch!, count: total)
            frameLock.lock()
            for row in 0..<h {
                memcpy(target + (y + row) * stride + x * 4, scratch! + row * rowBytes, rowBytes)
            }
            frameLock.unlock()
        }
        frameLock.lock()
        dirty = dirty.union(CGRect(x: x, y: y, width: w, height: h))
        frameLock.unlock()
    }

    // MARK: Leitura

    /// Leitura com buffer para os cabeçalhos pequenos; os pixels usam `readExact(into:)`.
    private var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    private var bufferStart = 0
    private var bufferEnd = 0

    private func fill() throws {
        bufferStart = 0
        let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard n > 0 else { throw DisplayError.closed }
        bufferEnd = n
    }

    private func read(_ count: Int) throws -> Data {
        var result = Data(capacity: count)
        while result.count < count {
            if bufferStart == bufferEnd { try fill() }
            let take = min(count - result.count, bufferEnd - bufferStart)
            result.append(contentsOf: buffer[bufferStart..<(bufferStart + take)])
            bufferStart += take
        }
        return result
    }

    /// Lê `count` bytes direto para `destination`: primeiro o que sobrou no buffer, depois
    /// leituras do socket sem cópia intermediária.
    private func readExact(into destination: UnsafeMutableRawPointer, count: Int) throws {
        var done = 0
        let buffered = min(count, bufferEnd - bufferStart)
        if buffered > 0 {
            _ = buffer.withUnsafeBytes { memcpy(destination, $0.baseAddress! + bufferStart, buffered) }
            bufferStart += buffered
            done = buffered
        }
        while done < count {
            let n = Darwin.read(fd, destination + done, count - done)
            guard n > 0 else { throw DisplayError.closed }
            done += n
        }
    }

    private func skip(_ count: Int) throws {
        var left = count
        while left > 0 {
            if bufferStart == bufferEnd { try fill() }
            let take = min(left, bufferEnd - bufferStart)
            bufferStart += take
            left -= take
        }
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
