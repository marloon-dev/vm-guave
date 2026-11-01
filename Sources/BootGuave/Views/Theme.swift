import AppKit
import SwiftUI

/// Cores da identidade (tiradas do ícone da goiaba), com variante para o modo escuro.
enum Brand {
    static let green = Color(light: 0xA6CE39, dark: 0xA6CE39)   // casca
    static let leaf = Color(light: 0x2F9E6B, dark: 0x3DB87A)    // folha
    static let pink = Color(light: 0xD93A62, dark: 0xE2456A)    // polpa
    static let cream = Color(light: 0xFFF1D0, dark: 0xFFF1D0)
    static let ink = Color(hex: 0x1B2219)                       // texto sobre o verde
    static let tileBackground = Color(light: 0xF1F4EA, dark: 0x262B23)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// Botão principal: verde da casca com texto escuro (contraste melhor que branco sobre verde-claro).
struct GuaveButtonStyle: ButtonStyle {
    var large = false
    /// Ocupa toda a largura disponível (botão da barra lateral).
    var expands = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .title3.weight(.semibold) : .body.weight(.semibold))
            .foregroundStyle(Brand.ink)
            .padding(.horizontal, large ? 26 : 14)
            .padding(.vertical, large ? 12 : 7)
            .frame(maxWidth: expands ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: large ? 12 : 9, style: .continuous)
                    .fill(Brand.green.opacity(configuration.isPressed ? 0.8 : 1))
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Ícone do sistema convidado num quadrado arredondado.
struct OSTile: View {
    let os: GuestOS
    var size: CGFloat = 30

    private var tint: Color {
        switch os {
        case .linux: return Brand.leaf
        case .macOS: return .secondary
        case .windows: return Color(light: 0x2B7BD3, dark: 0x5AA2F0)
        }
    }

    var body: some View {
        Image(systemName: os.symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(tint.opacity(0.14)))
    }
}

/// Estado da VM como etiqueta colorida.
struct StatusPill: View {
    let state: VMRunState

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(state.color).frame(width: 7, height: 7)
            Text(state.label).font(.callout.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(state.color.opacity(0.14)))
    }
}

extension VMRunState {
    var color: Color {
        switch self {
        case .running: return Brand.leaf
        case .starting, .stopping, .saving: return .orange
        case .downloading, .installing: return .blue
        case .paused, .suspended: return .yellow
        case .error: return .red
        case .stopped: return .secondary
        }
    }
}

// MARK: Ilustrações

/// Cubo (a VM) sobre uma base com luzes, entre folhas — a ilustração do estado vazio.
/// Desenhada num espaço de 260 x 220 e escalada para o tamanho pedido.
struct VMIllustration: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 260, size.height / 220)
            context.translateBy(x: (size.width - 260 * scale) / 2, y: (size.height - 220 * scale) / 2)
            context.scaleBy(x: scale, y: scale)

            let outline = Color(hex: 0x111410)
            func poly(_ points: [CGPoint]) -> Path {
                var path = Path()
                path.addLines(points)
                path.closeSubpath()
                return path
            }
            func fill(_ path: Path, _ color: Color) {
                context.fill(path, with: .color(color))
                context.stroke(path, with: .color(outline), style: StrokeStyle(lineWidth: 3.5, lineJoin: .round))
            }

            // Sombra no chão.
            context.fill(Path(ellipseIn: CGRect(x: 20, y: 168, width: 220, height: 46)), with: .color(Brand.leaf.opacity(0.18)))

            // Folhas.
            for (center, angle, color) in [(CGPoint(x: 52, y: 146), 32.0, Brand.leaf), (CGPoint(x: 210, y: 142), -32.0, Brand.green)] {
                var leaf = context
                leaf.translateBy(x: center.x, y: center.y)
                leaf.rotate(by: .degrees(angle))
                let shape = Path { p in
                    p.move(to: CGPoint(x: -36, y: 0))
                    p.addQuadCurve(to: CGPoint(x: 36, y: 0), control: CGPoint(x: 0, y: -30))
                    p.addQuadCurve(to: CGPoint(x: -36, y: 0), control: CGPoint(x: 0, y: 30))
                }
                leaf.fill(shape, with: .color(color))
            }

            // Base.
            fill(poly([CGPoint(x: 55, y: 152), CGPoint(x: 130, y: 187), CGPoint(x: 130, y: 207), CGPoint(x: 55, y: 172)]), Color(hex: 0x1F231D))
            fill(poly([CGPoint(x: 130, y: 187), CGPoint(x: 205, y: 152), CGPoint(x: 205, y: 172), CGPoint(x: 130, y: 207)]), Color(hex: 0x2A2F27))
            fill(poly([CGPoint(x: 130, y: 117), CGPoint(x: 205, y: 152), CGPoint(x: 130, y: 187), CGPoint(x: 55, y: 152)]), Color(hex: 0x353B31))
            for (index, color) in [Brand.green, Brand.cream, Brand.pink].enumerated() {
                let x = 152 + CGFloat(index) * 15
                let y = 191 - CGFloat(index) * 7
                context.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(color))
            }

            // Cubo.
            fill(poly([CGPoint(x: 82, y: 82), CGPoint(x: 130, y: 106), CGPoint(x: 130, y: 162), CGPoint(x: 82, y: 138)]), Color(hex: 0xF4E2B8))
            fill(poly([CGPoint(x: 130, y: 106), CGPoint(x: 178, y: 82), CGPoint(x: 178, y: 138), CGPoint(x: 130, y: 162)]), Brand.pink)
            fill(poly([CGPoint(x: 130, y: 58), CGPoint(x: 178, y: 82), CGPoint(x: 130, y: 106), CGPoint(x: 82, y: 82)]), Brand.cream)

            // Raios de "novo".
            let rays: [(CGPoint, CGPoint, Color)] = [
                (CGPoint(x: 112, y: 16), CGPoint(x: 118, y: 36), Brand.pink),
                (CGPoint(x: 160, y: 12), CGPoint(x: 152, y: 32), Brand.green),
                (CGPoint(x: 70, y: 46), CGPoint(x: 86, y: 56), Brand.green),
                (CGPoint(x: 194, y: 50), CGPoint(x: 178, y: 58), Brand.pink),
            ]
            for (from, to, color) in rays {
                var ray = Path()
                ray.move(to: from)
                ray.addLine(to: to)
                context.stroke(ray, with: .color(color), style: StrokeStyle(lineWidth: 6, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Versão pequena para a barra lateral vazia.
struct SmallCubeIcon: View {
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                ForEach([-25.0, 0, 25], id: \.self) { angle in
                    Capsule()
                        .fill(Brand.pink)
                        .frame(width: 3.5, height: 11)
                        .rotationEffect(.degrees(angle))
                        .offset(y: angle == 0 ? -3 : 0)
                }
            }
            Image(systemName: "cube")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.primary)
        }
        .accessibilityHidden(true)
    }
}

/// Formas orgânicas (folhas) nos cantos do painel principal.
struct LeafBackdrop: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Path { p in
                    p.move(to: .zero)
                    p.addLine(to: CGPoint(x: w * 0.22, y: 0))
                    p.addCurve(to: CGPoint(x: 0, y: h * 0.42),
                               control1: CGPoint(x: w * 0.16, y: h * 0.2),
                               control2: CGPoint(x: w * 0.02, y: h * 0.12))
                    p.closeSubpath()
                }
                .fill(Brand.leaf.opacity(0.13))

                Path { p in
                    p.move(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: w * 0.78, y: h))
                    p.addCurve(to: CGPoint(x: w, y: h * 0.58),
                               control1: CGPoint(x: w * 0.82, y: h * 0.8),
                               control2: CGPoint(x: w * 0.94, y: h * 0.66))
                    p.closeSubpath()
                }
                .fill(Brand.leaf.opacity(0.13))

                Path { p in
                    let c = CGPoint(x: w * 0.955, y: h * 0.86)
                    p.move(to: CGPoint(x: c.x - 34, y: c.y + 40))
                    p.addQuadCurve(to: CGPoint(x: c.x + 30, y: c.y - 44), control: CGPoint(x: c.x - 40, y: c.y - 30))
                    p.addQuadCurve(to: CGPoint(x: c.x - 34, y: c.y + 40), control: CGPoint(x: c.x + 36, y: c.y + 22))
                }
                .fill(Brand.leaf.opacity(0.28))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
