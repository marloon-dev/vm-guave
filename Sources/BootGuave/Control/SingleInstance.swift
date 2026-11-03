import AppKit
import ControlProtocol
import Foundation

/// Garante uma única cópia do app por usuário. Duas cópias disputariam as mesmas VMs e o
/// socket do bgctl (a que fechasse por último apagaria o socket da outra).
///
/// Usa flock num arquivo em Application Support: o kernel libera a trava sozinho se o app
/// travar ou for morto, então nunca sobra trava velha. Vale também para cópias em pastas
/// diferentes (ex.: build/ e /Applications), que o macOS trataria como apps distintos.
enum SingleInstance {
    private static var lockFD: Int32 = -1

    static var lockPath: String {
        ((ControlSocket.path as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("app.lock")
    }

    /// Tenta pegar a trava. Retorna false se outra cópia já está aberta.
    static func acquire() -> Bool {
        if lockFD >= 0 { return true }
        let path = lockPath
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        // O_CLOEXEC: processos filhos (QEMU, swtpm) não podem herdar a trava e segurá-la
        // depois que o app fechar.
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true } // sem como travar, não impede o app de abrir
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        // PID só para diagnóstico; a trava em si é o flock.
        ftruncate(fd, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(fd, $0, strlen($0)) }
        lockFD = fd
        return true
    }

    /// A outra cópia em execução (mesmo bundle id, qualquer pasta).
    static func otherInstance() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: ControlSocket.bundleIdentifier)
            .first { $0.processIdentifier != me }
    }

    /// Entrega arquivos .bootguave à cópia que já está aberta.
    static func forward(_ urls: [URL], to other: NSRunningApplication, completion: @escaping @Sendable () -> Void) {
        guard !urls.isEmpty, let appURL = other.bundleURL else {
            completion()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: configuration) { _, _ in
            completion()
        }
    }
}
