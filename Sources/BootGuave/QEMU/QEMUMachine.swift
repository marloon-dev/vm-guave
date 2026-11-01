import AppKit
import Foundation

/// Uma VM Windows rodando no QEMU (com hvf) + swtpm para o TPM 2.0 que o Windows 11 exige.
/// A tela abre numa janela própria do QEMU (Cocoa).
@MainActor
final class QEMUMachine {
    private let config: VMConfig
    private let bundle: VMBundle
    private var qemu: Process?
    private var swtpm: Process?
    private let runtimeDir: URL

    var onExit: ((Int32) -> Void)?

    init(config: VMConfig, bundle: VMBundle) {
        self.config = config
        self.bundle = bundle
        // Sockets Unix têm limite de ~104 bytes no caminho; o diretório temporário é curto.
        runtimeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bg-\(config.id.uuidString.prefix(8))", isDirectory: true)
    }

    private var qmpSocket: URL { runtimeDir.appendingPathComponent("qmp.sock") }
    private var tpmSocket: URL { runtimeDir.appendingPathComponent("tpm.sock") }

    var processIdentifier: pid_t? { qemu?.processIdentifier }

    func start() async throws {
        let qemuBinary = try QEMUTools.require(QEMUTools.qemuSystem, "qemu-system-aarch64")
        let firmware = try QEMUTools.require(QEMUTools.firmwareCode, "Firmware EFI do QEMU")
        try FileManager.default.createDirectory(at: runtimeDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: qmpSocket)
        try? FileManager.default.removeItem(at: tpmSocket)

        let usesTPM = QEMUTools.swtpm != nil
        if usesTPM {
            try await startTPM()
        }

        let process = Process()
        process.executableURL = qemuBinary
        process.arguments = arguments(firmware: firmware, tpm: usesTPM)
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor in self?.didExit(status) }
        }
        try process.run()
        qemu = process

        // Espera o QMP aparecer (ou o QEMU morrer com erro de argumento).
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: qmpSocket.path) { return }
            if !process.isRunning { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if !process.isRunning {
            let message = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw QEMUError.toolFailed("qemu-system-aarch64", message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func startTPM() async throws {
        let swtpmBinary = try QEMUTools.require(QEMUTools.swtpm, "swtpm")
        try FileManager.default.createDirectory(at: bundle.tpmStateURL, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = swtpmBinary
        process.arguments = [
            "socket", "--tpm2",
            "--tpmstate", "dir=\(bundle.tpmStateURL.path)",
            "--ctrl", "type=unixio,path=\(tpmSocket.path)",
            "--terminate",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        swtpm = process
        for _ in 0..<30 where !FileManager.default.fileExists(atPath: tpmSocket.path) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func arguments(firmware: URL, tpm: Bool) -> [String] {
        var args = [
            "-name", config.name,
            "-machine", "virt",
            "-accel", "hvf",
            "-cpu", "host",
            "-smp", "\(config.cpuCount)",
            "-m", "\(config.memoryGB * 1024)",
            "-drive", "if=pflash,format=raw,readonly=on,file=\(firmware.path)",
            "-drive", "if=pflash,format=raw,file=\(bundle.efiVariableStoreURL.path)",
            // ramfb: o Windows ARM não tem driver para virtio-gpu; usa o adaptador básico.
            "-device", "ramfb",
            "-device", "qemu-xhci,id=xhci",
            "-device", "usb-kbd",
            "-device", "usb-tablet",
            // NVMe: o instalador do Windows já tem driver (virtio-blk exigiria drivers extras).
            "-drive", "if=none,id=hd0,file=\(bundle.qcow2DiskURL.path),format=qcow2,discard=unmap",
            "-device", "nvme,drive=hd0,serial=BG\(config.id.uuidString.prefix(8))",
            "-audiodev", "coreaudio,id=snd0",
            "-device", "intel-hda",
            "-device", "hda-output,audiodev=snd0",
            "-rtc", "base=localtime",
            "-qmp", "unix:\(qmpSocket.path),server=on,wait=off",
            "-display", "cocoa,show-cursor=on",
        ]

        for (index, extra) in config.extraDisks.enumerated() {
            args += [
                "-drive", "if=none,id=xd\(index),file=\(bundle.extraDiskURL(extra).path),format=raw",
                "-device", "nvme,drive=xd\(index),serial=BGX\(index)",
            ]
        }

        // ISO do Windows e dos drivers como "pendrives" USB removíveis.
        for (id, path) in [("cd0", config.installerISOPath), ("cd1", config.driversISOPath)] {
            guard let path, FileManager.default.fileExists(atPath: path) else { continue }
            args += [
                "-drive", "if=none,id=\(id),media=cdrom,readonly=on,file=\(path)",
                "-device", "usb-storage,drive=\(id),removable=on",
            ]
        }

        var nic = "user,model=virtio-net-pci,mac=\(config.macAddress)"
        for forward in config.portForwards {
            nic += ",hostfwd=\(forward.proto.rawValue)::\(forward.hostPort)-:\(forward.guestPort)"
        }
        args += ["-nic", nic]

        if tpm {
            // ppi=off: a região PPI (1 KB) não é alinhada às páginas de 16 KB do hvf e derruba o QEMU.
            args += [
                "-chardev", "socket,id=chrtpm,path=\(tpmSocket.path)",
                "-tpmdev", "emulator,id=tpm0,chardev=chrtpm",
                "-device", "tpm-tis-device,tpmdev=tpm0,ppi=off",
            ]
        }
        return args
    }

    // MARK: Controle via QMP

    func requestStop() async throws { try await QMP.execute("system_powerdown", socket: qmpSocket) }
    func pause() async throws { try await QMP.execute("stop", socket: qmpSocket) }
    func resume() async throws { try await QMP.execute("cont", socket: qmpSocket) }
    func reset() async throws { try await QMP.execute("system_reset", socket: qmpSocket) }

    func forceStop() async {
        do {
            try await QMP.execute("quit", socket: qmpSocket)
        } catch {
            qemu?.terminate()
        }
    }

    /// Traz a janela do QEMU para a frente.
    func showWindow() {
        guard let pid = qemu?.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate()
    }

    private func didExit(_ status: Int32) {
        qemu = nil
        if swtpm?.isRunning == true { swtpm?.terminate() }
        swtpm = nil
        try? FileManager.default.removeItem(at: runtimeDir)
        onExit?(status)
    }
}

/// Cliente mínimo do QMP: uma conexão por comando (o servidor aceita reconexões).
enum QMP {
    static func execute(_ command: String, socket path: URL) async throws {
        try await Task.detached {
            try send(command, path: path.path)
        }.value
    }

    private static func send(_ command: String, path: String) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw QEMUError.qmp("caminho do socket longo demais") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw QEMUError.qmp("socket()") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw QEMUError.qmp("QEMU não está respondendo") }

        var pending = Data()
        func readLine() throws -> [String: Any] {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                if let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<newline]
                    pending.removeSubrange(pending.startIndex...newline)
                    guard let json = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                    // Eventos assíncronos (SHUTDOWN, RESET…) podem chegar no meio; ignora.
                    if json["event"] != nil { continue }
                    return json
                }
                let n = read(fd, &buffer, buffer.count)
                guard n > 0 else { throw QEMUError.qmp("conexão encerrada") }
                pending.append(buffer, count: n)
            }
        }
        func write(_ execute: String) throws -> [String: Any] {
            let line = Data(#"{"execute":"\#(execute)"}"#.utf8) + Data([0x0A])
            _ = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            return try readLine()
        }

        _ = try readLine() // saudação
        _ = try write("qmp_capabilities")
        let reply = try write(command)
        if let error = reply["error"] as? [String: Any] {
            throw QEMUError.qmp(error["desc"] as? String ?? "erro")
        }
    }
}
