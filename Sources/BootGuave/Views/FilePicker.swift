import AppKit
import UniformTypeIdentifiers

/// Seletores de arquivo via NSOpenPanel. Cada um tem destino fixo, então o resultado
/// nunca cai no campo errado (o .fileImporter compartilhado perdia o alvo ao fechar).
@MainActor
enum FilePicker {
    static func chooseISO() -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Escolha a ISO de instalação (ARM64)")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage, .diskImage, .data]
        panel.directoryURL = DownloadLocations.isoFolder
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseIPSW() -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Escolha a imagem de restauração do macOS (.ipsw)")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "ipsw") ?? .data]
        panel.directoryURL = DownloadLocations.isoFolder
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFolder(title: String = String(localized: "Escolha a pasta a compartilhar com a VM"), prompt: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        if let prompt { panel.prompt = prompt }
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Um .bootguave é uma pasta (pacote); por isso aceita diretórios terminados em .bootguave.
    static func chooseVMToImport() -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Escolha uma VM exportada (.bootguave)")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "bootguave", conformingTo: .package) ?? .package]
        return panel.runModal() == .OK ? panel.url : nil
    }
}
