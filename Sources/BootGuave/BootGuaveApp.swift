import AppKit
import SwiftUI

@main
struct BootGuaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = VMLibrary.shared

    init() {
        AppSettings.registerDefaults()
    }

    var body: some Scene {
        WindowGroup("VM Guave", id: "main") {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            // A antiga janela Ajustes virou a página Configuração; ⌘, leva até ela.
            CommandGroup(replacing: .appSettings) {
                Button("Configuração…") { AppRouter.shared.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("Nova VM…") { AppRouter.shared.newVM() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Ir") {
                ForEach(Array(AppPage.allCases.enumerated()), id: \.element) { index, page in
                    Button(page.title) { AppRouter.shared.go(page) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
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
    /// Outra cópia já está aberta: esta só repassa os arquivos e sai, sem tocar em VMs nem no socket.
    private var isDuplicate = false
    private var pendingForward: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        isDuplicate = !SingleInstance.acquire()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isDuplicate {
            handOverToRunningInstance()
            return
        }
        AppSettings.theme.apply()
        HostMonitor.shared.start()
        UpdateChecker.shared.startAutomaticChecks()
        installFullScreenShortcut()
        ControlServer.shared.start { request in
            await ControlCommands.handle(request, library: .shared)
        }
        if AppSettings.autoStartEnabled {
            VMLibrary.shared.startAutoStartVMs()
        }
    }

    /// Traz a cópia aberta para a frente, entrega a ela os arquivos recebidos e encerra esta.
    /// Usa exit em vez de terminate para não passar por applicationWillTerminate, que apagaria
    /// o socket e trancaria os cofres da outra cópia.
    private func handOverToRunningInstance() {
        for window in NSApp.windows { window.orderOut(nil) }
        guard let other = SingleInstance.otherInstance() else {
            let alert = NSAlert()
            alert.messageText = String(localized: "O VM Guave já está aberto")
            alert.informativeText = String(localized: "Outra cópia do VM Guave está em execução neste Mac. Use a que já está aberta.")
            alert.runModal()
            exit(0)
        }
        other.activate()
        SingleInstance.forward(pendingForward, to: other) {
            DispatchQueue.main.async { exit(0) }
        }
    }

    /// ⌘F alterna a tela cheia de qualquer janela do app. O monitor local pega o atalho antes
    /// da tela da VM, que captura o teclado (capturesSystemKeys) e o mandaria ao convidado.
    private func installFullScreenShortcut() {
        fullScreenKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .function, .numericPad])
            guard AppSettings.fullScreenShortcut,
                  flags == .command, event.charactersIgnoringModifiers?.lowercased() == "f",
                  let window = event.window,
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
        HostMonitor.shared.save()
        // Atualização pronta é instalada ao fechar (e reabre o app se o idioma também pediu).
        if !UpdateChecker.shared.installOnQuitIfReady(relaunch: AppRelauncher.pending) {
            AppRelauncher.launchWaiterIfPending()
        }
    }

    /// Duplo clique num .bootguave no Finder importa a VM.
    func application(_ application: NSApplication, open urls: [URL]) {
        if isDuplicate {
            pendingForward += urls.filter { $0.pathExtension == "bootguave" }
            return
        }
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

        switch AppSettings.quitBehavior {
        case .shutdown: return .terminateNow
        case .suspend: return suspendAndQuit(active, sender: sender)
        case .ask: break
        }

        let alert = NSAlert()
        alert.messageText = active.count == 1
            ? String(localized: "\"\(active[0].config.name)\" está em execução")
            : String(localized: "\(active.count) VMs estão em execução")
        let unsuspendable = active.filter { !$0.canSuspend }.map(\.config.name)
        alert.informativeText = String(localized: "Suspender salva o estado: ao abrir de novo, elas voltam de onde pararam. Sair sem suspender equivale a tirar da tomada.")
            + (unsuspendable.isEmpty ? "" : String(localized: "\n\nNão podem ser suspensas (Windows ou rede personalizada) e serão desligadas na hora: \(unsuspendable.joined(separator: ", ")). Desligue-as pelo sistema convidado antes, se possível."))
        alert.addButton(withTitle: String(localized: "Suspender e sair"))
        alert.addButton(withTitle: String(localized: "Cancelar"))
        alert.addButton(withTitle: String(localized: "Sair sem suspender"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return suspendAndQuit(active, sender: sender)
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    /// Suspende as VMs que podem ser suspensas e fecha quando todas terminarem de salvar.
    /// As outras são desligadas na hora, junto com o app.
    private func suspendAndQuit(_ active: [VMRunner], sender: NSApplication) -> NSApplication.TerminateReply {
        for runner in active where runner.canSuspend { runner.suspend() }
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(120)
            while active.contains(where: { $0.state == .saving }), Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
