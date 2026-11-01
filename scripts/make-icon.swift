// Gera o ícone do VM Guave em PNG 1024x1024 a partir de Resources/AppIcon.png,
// com a margem que o macOS espera em volta da arte.
// Uso: swift scripts/make-icon.swift <origem.png> <saida.png>
import AppKit

let args = CommandLine.arguments
guard args.count > 2, let source = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("Uso: swift make-icon.swift <origem.png> <saida.png>\n".utf8))
    exit(1)
}

let size: CGFloat = 1024
let inset: CGFloat = 100

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
source.draw(in: NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset))
NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
