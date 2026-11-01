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
    private var fullScreenKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installF11FullScreen()
        ControlServer.shared.start { request in
            await ControlCommands.handle(request, library: .shared)
        }
        VMLibrary.shared.startAutoStartVMs()
    }

    /// F11 alterna a tela cheia de qualquer janela, como no Windows e no Linux. O monitor local
    /// pega a tecla antes da tela da VM, que captura o teclado para o convidado.
    private func installF11FullScreen() {
        let f11: UInt16 = 103 // kVK_F11
        fullScreenKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.function)
            guard event.keyCode == f11, flags.isEmpty, let window = event.window,
                  window.level == .normal // o Picture in Picture usa .floating
            else { return event }
            window.toggleFullScreen(nil)
            return nil
        }
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
