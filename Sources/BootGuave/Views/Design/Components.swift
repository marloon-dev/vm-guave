import AppKit
import SwiftUI

/// Superfícies do layout novo (fundo quase preto no escuro, como as referências; claro no tema claro).
enum Surface {
    static let window = Color(light: 0xF5F6F1, dark: 0x0E100D)
    static let sidebar = Color(light: 0xECEFE6, dark: 0x121510)
    static let card = Color(light: 0xFFFFFF, dark: 0x161914)
    static let cardHeader = Color(light: 0xF2F4EC, dark: 0x1B1F18)
    static let field = Color(light: 0xFFFFFF, dark: 0x1A1D17)
    static let stroke = Color(light: 0xDFE3D6, dark: 0x262B23)
    static let leafShadow = Color(light: 0xD7E8CF, dark: 0x16301E)
}

// MARK: - Cabeçalho de página

/// Título grande + subtítulo, com ações à direita (ex.: "Nova VM").
struct PageHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            HStack(spacing: 10) { trailing() }
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// Fundo das páginas: preto com folhas nos cantos.
struct PageBackground: View {
    var body: some View {
        ZStack {
            Surface.window
            LeafBackdrop()
        }
        .ignoresSafeArea()
    }
}

/// Página rolável com o espaçamento padrão.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content()
            }
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .padding(.bottom, 36)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(PageBackground())
    }
}

// MARK: - Cartões

struct CardModifier: ViewModifier {
    var padding: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Surface.card))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Surface.stroke))
    }
}

extension View {
    func guaveCard(padding: CGFloat = 20) -> some View {
        modifier(CardModifier(padding: padding))
    }
}

/// Título de seção dentro da página ou do cartão.
struct SectionTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title).font(.title2.weight(.bold))
    }
}

/// Cartão de número (Visão Geral, Armazenamento): ícone redondo, rótulo, valor grande e detalhe.
struct StatCard: View {
    let symbol: String
    let tint: Color
    let title: LocalizedStringKey
    let value: String
    var unit: String? = nil
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(Circle().fill(tint.opacity(0.18)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 30, weight: .bold))
                        .monospacedDigit()
                    if let unit {
                        Text(unit).font(.title3).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                if let detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            Spacer(minLength: 0)
        }
        .guaveCard(padding: 18)
        .overlay(alignment: .bottomTrailing) {
            LeafShape()
                .fill(Brand.leaf.opacity(0.22))
                .frame(width: 30, height: 40)
                .rotationEffect(.degrees(28))
                .padding(10)
                .allowsHitTesting(false)
        }
    }
}

/// Folha simples (duas curvas), usada como enfeite.
struct LeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: rect.minX - rect.width * 0.2, y: rect.midY))
        p.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.maxY), control: CGPoint(x: rect.maxX + rect.width * 0.2, y: rect.midY))
        return p
    }
}

// MARK: - Tabela

/// Linha com colunas de largura proporcional (as frações somam 1). Cabeçalho e linhas usam as
/// mesmas frações, então as colunas ficam alinhadas sem medir o texto.
struct ColumnsLayout: Layout {
    let fractions: [CGFloat]
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        let widths = columnWidths(width)
        let height = subviews.enumerated().map { index, view in
            view.sizeThatFits(ProposedViewSize(width: widths[safe: index] ?? 0, height: nil)).height
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(bounds.width)
        var x = bounds.minX
        for (index, view) in subviews.enumerated() {
            let w = widths[safe: index] ?? 0
            view.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                       proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + spacing
        }
    }

    private func columnWidths(_ total: CGFloat) -> [CGFloat] {
        let available = max(0, total - spacing * CGFloat(max(0, fractions.count - 1)))
        return fractions.map { available * $0 }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Cabeçalho de tabela em cartão.
struct TableHeaderRow: View {
    let titles: [LocalizedStringKey]
    let fractions: [CGFloat]

    var body: some View {
        ColumnsLayout(fractions: fractions) {
            ForEach(Array(titles.enumerated()), id: \.offset) { _, title in
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Surface.cardHeader)
    }
}

// MARK: - Controles

/// Campo de busca grande com lupa.
struct GuaveSearchField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.title3)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Surface.field))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Surface.stroke))
    }
}

/// Botão secundário: fundo escuro com borda, como "Configurar" e "Cancelar".
struct SecondaryButtonStyle: ButtonStyle {
    var large = false
    /// Ocupa toda a largura disponível (botões dos cartões).
    var expands = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .title3.weight(.medium) : .body.weight(.medium))
            .padding(.horizontal, large ? 22 : 14)
            .padding(.vertical, large ? 11 : 7)
            .frame(maxWidth: expands ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: large ? 12 : 9, style: .continuous)
                    .fill(Surface.field.opacity(configuration.isPressed ? 0.6 : 1))
            )
            .overlay(RoundedRectangle(cornerRadius: large ? 12 : 9, style: .continuous).strokeBorder(Surface.stroke))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// Filtro em pílula ("Todas", "Linux"...).
struct FilterChip: View {
    let title: LocalizedStringKey
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Brand.ink : .primary)
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(Capsule().fill(selected ? Brand.green : Surface.field))
                .overlay(Capsule().strokeBorder(selected ? Color.clear : Surface.stroke))
        }
        .buttonStyle(.plain)
    }
}

/// Estado da VM em pílula cheia (verde ligada, rosa desligada…), como na lista de máquinas.
struct SolidStatusPill: View {
    let state: VMRunState

    private var fill: Color {
        switch state {
        case .running: return Brand.green
        case .stopped, .error: return Brand.pink
        case .suspended, .paused: return Brand.cream
        default: return Color(light: 0xF5C451, dark: 0xF5C451)
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Brand.ink).frame(width: 8, height: 8)
            Text(state.label)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Brand.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(fill))
        .fixedSize()
    }
}

/// Pílula pequena de status de texto livre ("Ativa", "Oficial"…).
struct TagPill: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = Brand.green

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol).font(.caption.weight(.bold))
            } else {
                Circle().frame(width: 8, height: 8)
            }
            Text(text).font(.callout.weight(.medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Capsule().fill(tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.3)))
        .fixedSize()
    }
}

/// Cubo (a VM) em perspectiva, creme e rosa como na ilustração; usado em listas e no diagrama de rede.
struct CubeGlyph: View {
    var size: CGFloat = 26

    var body: some View {
        Canvas { context, canvasSize in
            let s = min(canvasSize.width, canvasSize.height)
            let w = s * 0.86, h = s * 0.96
            let ox = (canvasSize.width - w) / 2, oy = (canvasSize.height - h) / 2
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * w, y: oy + y * h) }
            func poly(_ points: [CGPoint]) -> Path {
                var p = Path(); p.addLines(points); p.closeSubpath(); return p
            }
            let top = poly([pt(0.5, 0), pt(1, 0.25), pt(0.5, 0.5), pt(0, 0.25)])
            let left = poly([pt(0, 0.25), pt(0.5, 0.5), pt(0.5, 1), pt(0, 0.75)])
            let right = poly([pt(0.5, 0.5), pt(1, 0.25), pt(1, 0.75), pt(0.5, 1)])
            context.fill(top, with: .color(Brand.cream))
            context.fill(left, with: .color(Color(hex: 0xF4E2B8)))
            context.fill(right, with: .color(Brand.pink))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Folhas grandes nos cantos de baixo da barra lateral.
struct SidebarLeaves: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h))
                    p.addLine(to: CGPoint(x: 0, y: h * 0.62))
                    p.addCurve(to: CGPoint(x: w * 0.95, y: h),
                               control1: CGPoint(x: w * 0.45, y: h * 0.58),
                               control2: CGPoint(x: w * 0.55, y: h * 0.9))
                    p.closeSubpath()
                }
                .fill(Surface.leafShadow.opacity(0.9))

                LeafShape()
                    .fill(Brand.leaf.opacity(0.75))
                    .frame(width: 46, height: 82)
                    .rotationEffect(.degrees(-35))
                    .position(x: w * 0.2, y: h * 0.86)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Cursor de link

extension View {
    /// Mãozinha de link enquanto o mouse está em cima (como num site).
    func pointingHandCursor() -> some View {
        modifier(PointingHandCursor())
    }
}

private struct PointingHandCursor: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, !pushed {
                    NSCursor.pointingHand.push()
                    pushed = true
                } else if !inside, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed { NSCursor.pop(); pushed = false }
            }
    }
}
