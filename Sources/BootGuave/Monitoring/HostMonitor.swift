import Darwin
import Foundation

/// Um ponto do gráfico: uso de CPU e de memória do Mac, de 0 a 1.
struct UsageSample: Codable, Hashable {
    var date: Date
    var cpu: Double
    var memory: Double
}

/// Mede CPU e memória do Mac enquanto o app está aberto. O macOS não informa o uso de dentro de
/// cada VM, então o gráfico mostra o Mac inteiro (que inclui as VMs ligadas).
@MainActor
final class HostMonitor: ObservableObject {
    static let shared = HostMonitor()

    /// Últimos valores (atualizados a cada 5 s).
    @Published private(set) var cpu: Double = 0
    @Published private(set) var memoryUsedBytes: UInt64 = 0
    /// Um ponto por minuto (média), até 24 h.
    @Published private(set) var history: [UsageSample] = []

    let coreCount = ProcessInfo.processInfo.activeProcessorCount
    let memoryTotalBytes = ProcessInfo.processInfo.physicalMemory

    var memoryFraction: Double {
        memoryTotalBytes == 0 ? 0 : Double(memoryUsedBytes) / Double(memoryTotalBytes)
    }

    private var previousTicks: (used: UInt64, total: UInt64)?
    private var minuteSamples: [(cpu: Double, memory: Double)] = []
    private var timer: Timer?
    private var lastSave = Date.distantPast

    private var fileURL: URL {
        VMBundle.libraryURL.deletingLastPathComponent().appendingPathComponent("usage-history.json")
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder.iso8601.decode([UsageSample].self, from: data) {
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            history = saved.filter { $0.date > cutoff }
        }
    }

    func start() {
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    /// Grava o histórico (também chamado ao fechar o app).
    func save() {
        guard let data = try? JSONEncoder.iso8601.encode(history) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        lastSave = Date()
    }

    private func sample() {
        if let ticks = Self.cpuTicks() {
            if let previous = previousTicks, ticks.total > previous.total {
                cpu = Double(ticks.used - previous.used) / Double(ticks.total - previous.total)
            }
            previousTicks = ticks
        }
        if let used = Self.memoryUsed() { memoryUsedBytes = used }

        minuteSamples.append((cpu, memoryFraction))
        if minuteSamples.count >= 12 { // 12 × 5 s = 1 min
            let n = Double(minuteSamples.count)
            history.append(UsageSample(
                date: Date(),
                cpu: minuteSamples.map(\.cpu).reduce(0, +) / n,
                memory: minuteSamples.map(\.memory).reduce(0, +) / n
            ))
            minuteSamples.removeAll()
            let cutoff = Date().addingTimeInterval(-24 * 3600)
            history.removeAll { $0.date < cutoff }
            if Date().timeIntervalSince(lastSave) > 600 { save() }
        }
    }

    /// Soma dos ticks de todos os núcleos (usados = user + system + nice).
    private static func cpuTicks() -> (used: UInt64, total: UInt64)? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var used: UInt64 = 0, total: UInt64 = 0
        for core in 0..<Int(count) {
            let base = core * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)])
            let system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)])
            let idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            used += user + system + nice
            total += user + system + nice + idle
        }
        return (used, total)
    }

    /// Memória em uso como no Monitor de Atividade: ativa + fixa + comprimida.
    private static func memoryUsed() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return pages * page
    }
}
