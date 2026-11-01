import Foundation

/// Converte discos de outros virtualizadores (qcow2, vmdk, vdi, vhdx, raw) com o qemu-img.
/// Linux vira raw esparso (Virtualization.framework); Windows vira qcow2 (QEMU).
enum DiskImporter {
    static let supportedExtensions = ["qcow2", "vmdk", "vdi", "vhdx", "vhd", "img", "raw"]

    /// Tamanho virtual do disco em bytes.
    static func virtualSize(of source: URL) async throws -> UInt64 {
        let qemuImg = try QEMUTools.require(QEMUTools.qemuImg, "qemu-img")
        let json = try await QEMUTools.run(qemuImg, ["info", "--output=json", source.path])
        guard let info = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let size = (info["virtual-size"] as? NSNumber)?.uint64Value else {
            throw QEMUError.toolFailed("qemu-img", "não consegui ler o tamanho do disco")
        }
        return size
    }

    /// Converte para o formato que o motor da VM usa. `progress` recebe 0...1.
    static func convert(_ source: URL, to destination: URL, format: String,
                        progress: @escaping @Sendable (Double) -> Void) async throws {
        let qemuImg = try QEMUTools.require(QEMUTools.qemuImg, "qemu-img")
        // -p imprime "(12.34/100%)"; raw sai esparso (blocos zerados não são gravados).
        let pattern = try NSRegularExpression(pattern: #"\((\d+(?:\.\d+)?)/100%\)"#)
        _ = try await QEMUTools.run(qemuImg, ["convert", "-p", "-O", format, source.path, destination.path]) { chunk in
            let range = NSRange(chunk.startIndex..., in: chunk)
            if let last = pattern.matches(in: chunk, range: range).last,
               let number = Range(last.range(at: 1), in: chunk),
               let value = Double(chunk[number]) {
                progress(value / 100)
            }
        }
    }
}
