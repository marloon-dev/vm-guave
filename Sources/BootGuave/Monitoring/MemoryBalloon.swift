import Foundation
import Virtualization

/// Devolve memória das VMs Linux ao Mac quando o macOS avisa que a RAM está acabando.
///
/// Uma VM ocupa toda a memória configurada, mesmo parada. Com pressão de memória, o balão
/// virtio "infla" dentro do convidado (o Linux solta primeiro o cache de disco) e o Mac recupera
/// a diferença; quando a pressão passa, a VM volta a ter tudo. Os limites são conservadores
/// para não faltar memória para o que já roda na VM.
@MainActor
final class MemoryBalloon {
    static let shared = MemoryBalloon()

    enum Level { case normal, warning, critical }

    private var source: DispatchSourceMemoryPressure?
    private(set) var level: Level = .normal

    func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self, let event = self.source?.data else { return }
            MainActor.assumeIsolated {
                if event.contains(.critical) {
                    self.apply(.critical)
                } else if event.contains(.warning) {
                    self.apply(.warning)
                } else {
                    self.apply(.normal)
                }
            }
        }
        source.resume()
        self.source = source
    }

    private func apply(_ newLevel: Level) {
        level = newLevel
        for runner in VMLibrary.shared.activeRunners {
            runner.applyMemoryTarget(Self.target(forConfiguredGB: runner.config.memoryGB, level: newLevel))
        }
    }

    /// Alvo em bytes: 100% normal, 75% em alerta, 50% em crítico; nunca abaixo de 2 GB.
    static func target(forConfiguredGB gb: Int, level: Level) -> UInt64 {
        let full = UInt64(gb) << 30
        let fraction: Double
        switch level {
        case .normal: return full
        case .warning: fraction = 0.75
        case .critical: fraction = 0.5
        }
        let floor: UInt64 = min(full, 2 << 30)
        let mb = UInt64((Double(full) * fraction) / 1_048_576)
        return max(floor, mb * 1_048_576) // múltiplo de 1 MB, como o framework exige
    }
}

extension VMRunner {
    /// Ajusta o balão de memória (só VMs Linux no motor da Apple; o macOS convidado e o QEMU não).
    func applyMemoryTarget(_ bytes: UInt64) {
        guard config.os == .linux, state == .running || state == .paused,
              let balloon = virtualMachine?.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice else { return }
        if balloon.targetVirtualMachineMemorySize != bytes {
            balloon.targetVirtualMachineMemorySize = bytes
        }
    }
}
