import AppKit
import SwiftUI

@main
struct BootGuaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = VMLibrary.shared

    var body: some Scene {
        WindowGroup("VM Guave", id: "main") {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 760, minHeight: 480)
        }

        // Uma janela por VM, identificada pelo UUID.
        WindowGroup("Tela da VM", for: UUID.self) { $vmID in
            if let vmID, let runner = library.runner(for: vmID) {
                VMWindowView(runner: runner)
            } else {
                Text("VM não encontrada").padding()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ControlServer.shared.start { request in
            await ControlCommands.handle(request, library: .shared)
        }
        VMLibrary.shared.startAutoStartVMs()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ControlServer.shared.stop()
        // Nenhum cofre de VM criptografada fica montado depois que o app fecha.
        VMLibrary.shared.lockAllSync()
    }

    /// Duplo clique num .bootguave no Finder importa a VM.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task {
            for url in urls where url.pathExtension == "bootguave" {
                _ = await VMLibrary.shared.importVM(from: url)
            }
        }
    }

    /// Fechar o app mata as VMs; oferece suspender para não perder nada.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let active = VMLibrary.shared.activeRunners
        guard !active.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = active.count == 1
            ? "\"\(active[0].config.name)\" está em execução"
            : "\(active.count) VMs estão em execução"
        let unsuspendable = active.filter { !$0.canSuspend }.map(\.config.name)
        alert.informativeText = "Suspender salva o estado: ao abrir de novo, elas voltam de onde pararam. Sair sem suspender equivale a tirar da tomada."
            + (unsuspendable.isEmpty ? "" : "\n\nNão podem ser suspensas (Windows ou rede personalizada) e serão desligadas na hora: \(unsuspendable.joined(separator: ", ")). Desligue-as pelo sistema convidado antes, se possível.")
        alert.addButton(withTitle: "Suspender e sair")
        alert.addButton(withTitle: "Cancelar")
        alert.addButton(withTitle: "Sair sem suspender")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for runner in active where runner.canSuspend { runner.suspend() }
            Task { @MainActor in
                let deadline = Date().addingTimeInterval(120)
                while active.contains(where: { $0.state == .saving }), Date() < deadline {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
