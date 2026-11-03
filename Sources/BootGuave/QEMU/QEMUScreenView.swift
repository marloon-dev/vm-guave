import AppKit
import SwiftUI

/// Tela de uma VM Windows dentro da janela do VM Guave (no lugar da VZVirtualMachineView das
/// VMs Linux e macOS). A imagem vem do QEMU por VNC local; teclado e mouse voltam pelo mesmo canal.
struct QEMUDisplayView: NSViewRepresentable {
    let socket: URL

    func makeNSView(context: Context) -> QEMUScreenView {
        QEMUScreenView(socket: socket)
    }

    func updateNSView(_ view: QEMUScreenView, context: Context) {
        view.connect(to: socket)
    }

    static func dismantleNSView(_ view: QEMUScreenView, coordinator: ()) {
        view.disconnect()
    }
}

final class QEMUScreenView: NSView {
    private var client: QEMUDisplayClient?
    private var socket: URL?
    private var frameSize = CGSize.zero
    private var buttons: UInt8 = 0
    /// Scancodes apertados, para soltar tudo quando a janela perde o foco.
    private var pressed = Set<UInt32>()
    private var modifierFlags: UInt = 0
    /// O cursor do Windows já vem desenhado na imagem; o do Mac some sobre a tela.
    private static let hiddenCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    init(socket: URL) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .trilinear
        connect(to: socket)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func connect(to socket: URL) {
        guard socket != self.socket else { return }
        disconnect()
        self.socket = socket
        let client = QEMUDisplayClient(socket: socket)
        client.onFrame = { [weak self] image in
            guard let self else { return }
            self.frameSize = CGSize(width: image.width, height: image.height)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layer?.contents = image
            CATransaction.commit()
        }
        client.start()
        self.client = client
    }

    func disconnect() {
        releaseAll()
        client?.stop()
        client = nil
        socket = nil
    }

    // MARK: Foco

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.window?.makeFirstResponder(self)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowLostFocus), name: NSWindow.didResignKeyNotification, object: window)
    }

    override func resignFirstResponder() -> Bool {
        releaseAll()
        return super.resignFirstResponder()
    }

    @objc private func windowLostFocus() { releaseAll() }

    /// Sem isso, uma tecla apertada na hora de trocar de janela ficaria presa no Windows.
    private func releaseAll() {
        for code in pressed { client?.sendKey(scancode: code, down: false) }
        pressed.removeAll()
        modifierFlags = 0
        if buttons != 0, let client {
            buttons = 0
            client.sendPointer(x: lastPoint.x, y: lastPoint.y, buttons: 0)
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        if imageRect.contains(convert(event.locationInWindow, from: nil)) {
            Self.hiddenCursor.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// Onde a imagem aparece dentro da view (proporção mantida, faixas pretas nas sobras).
    private var imageRect: CGRect {
        guard frameSize.width > 0, frameSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / frameSize.width, bounds.height / frameSize.height)
        let size = CGSize(width: frameSize.width * scale, height: frameSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    private var lastPoint = (x: 0, y: 0)

    private func sendPointer(_ event: NSEvent, buttons extra: UInt8 = 0) {
        let rect = imageRect
        guard rect.width > 0, let client else { return }
        let local = convert(event.locationInWindow, from: nil)
        let x = Int((local.x - rect.minX) / rect.width * frameSize.width)
        let y = Int((rect.maxY - local.y) / rect.height * frameSize.height) // a view não é invertida
        lastPoint = (x, y)
        client.sendPointer(x: x, y: y, buttons: buttons | extra)
        cursorUpdate(with: event)
    }

    private func setButton(_ mask: UInt8, down: Bool, _ event: NSEvent) {
        if down { buttons |= mask } else { buttons &= ~mask }
        sendPointer(event)
    }

    override func mouseMoved(with event: NSEvent) { sendPointer(event) }
    override func mouseDragged(with event: NSEvent) { sendPointer(event) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // ⌃ + clique vira clique direito, como no resto do Mac.
        setButton(event.modifierFlags.contains(.control) ? 4 : 1, down: true, event)
    }

    override func mouseUp(with event: NSEvent) {
        buttons &= ~(1 | 4)
        sendPointer(event)
    }

    override func rightMouseDown(with event: NSEvent) { window?.makeFirstResponder(self); setButton(4, down: true, event) }
    override func rightMouseUp(with event: NSEvent) { setButton(4, down: false, event) }
    override func otherMouseDown(with event: NSEvent) { setButton(2, down: true, event) }
    override func otherMouseUp(with event: NSEvent) { setButton(2, down: false, event) }

    private var scrollRemainder = CGPoint.zero

    override func scrollWheel(with event: NSEvent) {
        // Trackpad manda deltas pequenos e contínuos; cada "degrau" do RFB vale ~1 linha.
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
        scrollRemainder.x += event.scrollingDeltaX / step
        scrollRemainder.y += event.scrollingDeltaY / step
        // O sentido segue a preferência do Mac (rolagem natural), como nos outros apps.
        while abs(scrollRemainder.y) >= 1 {
            let up = scrollRemainder.y > 0
            click(wheel: up ? 8 : 16, event)
            scrollRemainder.y += up ? -1 : 1
        }
        while abs(scrollRemainder.x) >= 1 {
            let left = scrollRemainder.x > 0
            click(wheel: left ? 32 : 64, event)
            scrollRemainder.x += left ? -1 : 1
        }
    }

    private func click(wheel mask: UInt8, _ event: NSEvent) {
        sendPointer(event, buttons: mask)
        sendPointer(event)
    }

    // MARK: Teclado

    override func keyDown(with event: NSEvent) { key(event, down: true) }
    override func keyUp(with event: NSEvent) { key(event, down: false) }

    /// Atalhos com ⌘ (exceto os que o app pega antes, como ⌘F) vão para o Windows, como na tela
    /// das outras VMs, que captura as teclas do sistema.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        key(event, down: true)
        return true
    }

    private func key(_ event: NSEvent, down: Bool) {
        guard let code = QEMUKeyMap.scancode(for: event.keyCode) else { return }
        if down { pressed.insert(code) } else { pressed.remove(code) }
        let keysym = event.charactersIgnoringModifiers?.unicodeScalars.first.map { UInt32($0.value) } ?? 0
        client?.sendKey(scancode: code, keysym: keysym < 0x80 ? keysym : 0, down: down)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let code = QEMUKeyMap.scancode(for: event.keyCode) else { return }
        if event.keyCode == 0x39 { // Caps Lock: o Mac só avisa a troca; manda um toque.
            client?.sendKey(scancode: code, down: true)
            client?.sendKey(scancode: code, down: false)
            return
        }
        // Bits por lado (esquerda/direita) dos modificadores, do IOKit (NX_DEVICE*KEYMASK).
        let raw = event.modifierFlags.rawValue
        guard let mask = QEMUKeyMap.deviceMask[event.keyCode] else { return }
        let down = raw & mask != 0
        if down { pressed.insert(code) } else { pressed.remove(code) }
        client?.sendKey(scancode: code, down: down)
    }
}

/// Teclas do Mac (kVK_*) → scancodes do PC no formato "qnum" do QEMU (0x80 | byte depois do 0xE0).
enum QEMUKeyMap {
    static func scancode(for keyCode: UInt16) -> UInt32? { table[keyCode] }

    static let deviceMask: [UInt16: UInt] = [
        0x3B: 0x0001, 0x3E: 0x2000, // Control esquerdo, direito
        0x38: 0x0002, 0x3C: 0x0004, // Shift
        0x37: 0x0008, 0x36: 0x0010, // Command → tecla Windows
        0x3A: 0x0020, 0x3D: 0x0040, // Option → Alt
    ]

    private static let table: [UInt16: UInt32] = [
        0x00: 0x1E, 0x01: 0x1F, 0x02: 0x20, 0x03: 0x21, 0x04: 0x23, 0x05: 0x22, 0x06: 0x2C, 0x07: 0x2D,
        0x08: 0x2E, 0x09: 0x2F, 0x0A: 0x56, 0x0B: 0x30, 0x0C: 0x10, 0x0D: 0x11, 0x0E: 0x12, 0x0F: 0x13,
        0x10: 0x15, 0x11: 0x14, 0x12: 0x02, 0x13: 0x03, 0x14: 0x04, 0x15: 0x05, 0x16: 0x07, 0x17: 0x06,
        0x18: 0x0D, 0x19: 0x0A, 0x1A: 0x08, 0x1B: 0x0C, 0x1C: 0x09, 0x1D: 0x0B, 0x1E: 0x1B, 0x1F: 0x18,
        0x20: 0x16, 0x21: 0x1A, 0x22: 0x17, 0x23: 0x19, 0x24: 0x1C, 0x25: 0x26, 0x26: 0x24, 0x27: 0x28,
        0x28: 0x25, 0x29: 0x27, 0x2A: 0x2B, 0x2B: 0x33, 0x2C: 0x35, 0x2D: 0x31, 0x2E: 0x32, 0x2F: 0x34,
        0x30: 0x0F, 0x31: 0x39, 0x32: 0x29, 0x33: 0x0E, 0x35: 0x01,
        // Modificadores
        0x36: 0xDC, 0x37: 0xDB, 0x38: 0x2A, 0x39: 0x3A, 0x3A: 0x38, 0x3B: 0x1D, 0x3C: 0x36, 0x3D: 0xB8, 0x3E: 0x9D,
        // Teclado numérico
        0x41: 0x53, 0x43: 0x37, 0x45: 0x4E, 0x47: 0x45, 0x4B: 0xB5, 0x4C: 0x9C, 0x4E: 0x4A, 0x51: 0x59,
        0x52: 0x52, 0x53: 0x4F, 0x54: 0x50, 0x55: 0x51, 0x56: 0x4B, 0x57: 0x4C, 0x58: 0x4D, 0x59: 0x47,
        0x5B: 0x48, 0x5C: 0x49,
        // Volume
        0x48: 0xB0, 0x49: 0xAE, 0x4A: 0xA0,
        // Japonês (JIS)
        0x5D: 0x7D, 0x5E: 0x73, 0x5F: 0x7E, 0x66: 0x7B, 0x68: 0x70,
        // Teclas de função
        0x7A: 0x3B, 0x78: 0x3C, 0x63: 0x3D, 0x76: 0x3E, 0x60: 0x3F, 0x61: 0x40, 0x62: 0x41, 0x64: 0x42,
        0x65: 0x43, 0x6D: 0x44, 0x67: 0x57, 0x6F: 0x58,
        // Navegação
        0x72: 0xD2, 0x73: 0xC7, 0x74: 0xC9, 0x75: 0xD3, 0x77: 0xCF, 0x79: 0xD1,
        0x7B: 0xCB, 0x7C: 0xCD, 0x7D: 0xD0, 0x7E: 0xC8, 0x6E: 0xDD,
    ]
}
