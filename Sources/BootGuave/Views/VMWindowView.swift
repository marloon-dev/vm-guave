import AppKit
import SwiftUI
import Virtualization

/// Janela com a tela da VM: modo janela, tela cheia e Picture in Picture.
struct VMWindowView: View {
    let runner: VMRunner
    @State private var window: NSWindow?
    @State private var pictureInPicture = false
    @State private var frameBeforePiP: NSRect?
    @State private var dropTargeted = false
    @State private var dropMessage: String?

    var body: some View {
        Group {
            if let vm = runner.virtualMachine {
                VMDisplayView(virtualMachine: vm)
            } else if let socket = runner.qemuDisplaySocket, runner.state.isActive {
                QEMUDisplayView(socket: socket)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "display")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    StatusBadge(state: runner.state)
                    if case .error(let message) = runner.state {
                        Text(message).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                    if !runner.state.isActive {
                        Button(runner.state == .suspended ? "Retomar" : "Iniciar") { runner.start() }
                            .buttonStyle(.borderedProminent)
                            .guaveHover(.text)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 320, minHeight: 200)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 4)
                    .background(Color.accentColor.opacity(0.08))
                    .overlay(Text("Solte para copiar para a pasta compartilhada").font(.headline))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if let dropMessage {
                Text(dropMessage)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            copyToSharedFolder(urls)
        } isTargeted: { dropTargeted = $0 }
        .background(WindowAccessor(window: $window))
        .navigationTitle(runner.config.name)
        .modifier(HideToolbarInFullScreen())
        .toolbar {
            ToolbarItemGroup {
                StatusBadge(state: runner.state)
                if runner.state == .paused {
                    Button { runner.resume() } label: { Label("Continuar", systemImage: "play.fill") }
                } else {
                    Button { runner.pause() } label: { Label("Pausar", systemImage: "pause.fill") }
                        .disabled(runner.state != .running)
                }
                Button { runner.suspend() } label: { Label("Suspender", systemImage: "moon.zzz") }
                    .disabled(!runner.canSuspend || (runner.state != .running && runner.state != .paused))
                    .help(runner.suspendUnavailableReason ?? String(localized: "Salva o estado e desliga"))
                Button { togglePictureInPicture() } label: {
                    Label("Picture in Picture", systemImage: pictureInPicture ? "pip.exit" : "pip.enter")
                }
                .help("Janela pequena, sempre visível, em todos os espaços")
                Button { window?.toggleFullScreen(nil) } label: {
                    Label("Tela cheia", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .disabled(pictureInPicture)
                .help("Tela cheia (⌘F)")
            }
        }
    }

    /// Arrastar do Finder: copia para a pasta compartilhada, que o convidado já enxerga.
    private func copyToSharedFolder(_ urls: [URL]) -> Bool {
        guard let folderPath = runner.config.sharedFolderPath else {
            showDropMessage(String(localized: "Configure uma pasta compartilhada na VM para arrastar arquivos."))
            return false
        }
        let folder = URL(fileURLWithPath: folderPath)
        var copied = 0
        var failures: [String] = []
        for url in urls where url.isFileURL {
            do {
                try FileCloner.clone(url, to: uniqueDestination(for: url, in: folder))
                copied += 1
            } catch {
                failures.append(url.lastPathComponent)
            }
        }
        let place = runner.config.os == .macOS ? "/Volumes/My Shared Files" : String(localized: "a pasta compartilhada")
        if failures.isEmpty {
            showDropMessage(String(localized: "\(copied) item(ns) copiado(s) para \(place)"))
        } else {
            showDropMessage(String(localized: "Copiados \(copied); falharam: \(failures.joined(separator: ", "))"))
        }
        return copied > 0
    }

    private func uniqueDestination(for url: URL, in folder: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var candidate = folder.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = folder.appendingPathComponent(name)
            n += 1
        }
        return candidate
    }

    private func showDropMessage(_ message: String) {
        withAnimation { dropMessage = message }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if dropMessage == message { withAnimation { dropMessage = nil } }
        }
    }

    private func togglePictureInPicture() {
        guard let window else { return }
        if pictureInPicture {
            window.level = .normal
            window.collectionBehavior.remove(.canJoinAllSpaces)
            window.collectionBehavior.insert(.fullScreenPrimary)
            if let frame = frameBeforePiP { window.setFrame(frame, display: true, animate: true) }
        } else {
            frameBeforePiP = window.frame
            window.level = .floating
            window.collectionBehavior.remove(.fullScreenPrimary)
            window.collectionBehavior.insert(.canJoinAllSpaces)
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let size = NSSize(width: 480, height: 300)
            let origin = NSPoint(x: visible.maxX - size.width - 20, y: visible.minY + 20)
            window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
        }
        pictureInPicture.toggle()
    }
}

private struct VMDisplayView: NSViewRepresentable {
    let virtualMachine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        view.virtualMachine = virtualMachine
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== virtualMachine {
            view.virtualMachine = virtualMachine
        }
    }
}

/// Tela cheia "total": só a imagem da VM. A barra de ferramentas e a de menus se escondem e
/// reaparecem quando o mouse encosta no topo da tela.
private struct HideToolbarInFullScreen: ViewModifier {
    @AppStorage(AppSettings.Key.hideBarsInFullScreen) private var hideBars = true

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.windowToolbarFullScreenVisibility(hideBars ? .onHover : .visible)
        } else {
            content
        }
    }
}

/// Dá acesso à NSWindow que hospeda a view SwiftUI.
private struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if window !== view.window {
            DispatchQueue.main.async { window = view.window }
        }
    }
}
