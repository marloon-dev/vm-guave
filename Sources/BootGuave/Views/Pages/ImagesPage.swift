import AppKit
import SwiftUI

struct ImagesPage: View {
    private let images = ImageLibrary.shared
    private let router = AppRouter.shared
    @State private var search = ""
    @State private var family: Family = .all

    enum Family: String, CaseIterable, Identifiable {
        case all, linux, windows, macOS
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .all: return "Todas"
            case .linux: return "Linux"
            case .windows: return "Windows"
            case .macOS: return "macOS"
            }
        }
    }

    private var visible: [InstallImage] {
        images.images.filter { image in
            let familyOK: Bool
            switch family {
            case .all: familyOK = true
            case .linux: familyOK = image.os == .linux
            case .windows: familyOK = image.os == .windows
            case .macOS: familyOK = image.os == .macOS
            }
            let text = image.title + " " + (image.localURL?.lastPathComponent ?? "")
            return familyOK && (search.isEmpty || text.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        PageScroll {
            PageHeader("Imagens", subtitle: "Sistemas operacionais prontos para suas máquinas virtuais.")

            HStack(spacing: 16) {
                GuaveSearchField(text: $search, prompt: "Buscar imagens")
                Button {
                    if let url = FilePicker.chooseISO() { images.importImage(url) }
                } label: {
                    Label("Importar imagem", systemImage: "plus")
                }
                .buttonStyle(GuaveButtonStyle(large: true))
            }

            HStack(spacing: 10) {
                ForEach(Family.allCases) { item in
                    FilterChip(title: item.title, selected: family == item) { family = item }
                }
            }

            if let error = images.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Brand.pink)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 18)], alignment: .leading, spacing: 18) {
                ForEach(visible) { image in
                    ImageCard(image: image)
                }
            }

            Text("As ISOs ficam na pasta Downloads; imagens do macOS, no cache do VM Guave. Use sempre imagens ARM64 (aarch64).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onAppear { images.reload() }
    }
}

private struct ImageCard: View {
    let image: InstallImage
    private let library = ImageLibrary.shared
    private let router = AppRouter.shared

    private var progress: Double?? { library.downloads[image.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Spacer()
                ImageGlyph(source: image.source, title: image.title)
                    .frame(width: 118, height: 118)
                Spacer()
            }
            .overlay(alignment: .topTrailing) { cardMenu }

            Text(image.title)
                .font(.title3.weight(.bold))
                .lineLimit(2)
                .frame(minHeight: 44, alignment: .topLeading)

            if image.isOfficial {
                TagPill(text: String(localized: "Oficial"), symbol: "checkmark.shield.fill")
            } else {
                TagPill(text: String(localized: "Personalizada"), symbol: "person", tint: .secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "cylinder")
                    .foregroundStyle(.secondary)
                if let size = image.sizeBytes {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                } else {
                    Text(image.source == .macOS ? "Baixada ao criar a VM (~15 GB)" : "Não baixada")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .lineLimit(1)

            actionButton
        }
        .guaveCard(padding: 18)
    }

    @ViewBuilder
    private var actionButton: some View {
        if let progress {
            HStack {
                if let value = progress {
                    ProgressView(value: value)
                    Text(value.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .font(.caption)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Preparando…").font(.caption)
                    Spacer()
                }
                Button { library.cancelDownload(image) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .guaveHover(.icon)
                    .help("Cancelar")
            }
            .frame(height: 40)
        } else if image.localURL != nil || image.source == .macOS {
            CardActionButton(title: "Usar imagem", symbol: "arrow.right", primary: true) {
                router.newVM(os: image.os, iso: image.localURL)
            }
        } else if image.source == .windows {
            CardActionButton(title: "Baixar no site da Microsoft", symbol: "arrow.up.right", primary: false) {
                NSWorkspace.shared.open(WindowsDownloads.windows11ARMPage)
            }
            .help(WindowsDownloads.windows11ARMPage.absoluteString)
        } else {
            CardActionButton(title: "Baixar", symbol: "arrow.down", primary: false) {
                library.download(image)
            }
        }
    }

    private var cardMenu: some View {
        Menu {
            if let url = image.localURL {
                Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            if image.localURL != nil || image.source == .macOS {
                Button("Criar VM com esta imagem") { router.newVM(os: image.os, iso: image.localURL) }
            }
            if library.canRemoveFromList(image) {
                Divider()
                Button("Remover da lista") { library.removeFromList(image) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .guaveHover(.icon)
    }
}

/// Botão do cartão: no hover cresce, brilha, mostra a mãozinha de link e a seta anda na direção
/// da ação (→ usar, ↓ baixar, ↗ abrir site).
private struct CardActionButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let primary: Bool
    let action: () -> Void
    @State private var hovering = false

    private var arrowOffset: CGSize {
        guard hovering else { return .zero }
        switch symbol {
        case "arrow.down": return CGSize(width: 0, height: 3)
        case "arrow.up.right": return CGSize(width: 3, height: -3)
        default: return CGSize(width: 4, height: 0)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Image(systemName: symbol)
                    .font(.body.weight(.bold))
                    .offset(arrowOffset)
            }
        }
        .buttonStyle(CardButtonStyle(primary: primary, hovering: hovering))
        .onHover { hovering = $0 }
        .pointingHandCursor()
        .animation(.spring(response: 0.28, dampingFraction: 0.6), value: hovering)
    }
}

private struct CardButtonStyle: ButtonStyle {
    let primary: Bool
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let fill: Color = primary ? Brand.green : (hovering ? Brand.green.opacity(0.16) : Surface.field)
        return configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(primary ? Brand.ink : (hovering ? Brand.green : Color.primary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(primary ? Color.clear : (hovering ? Brand.green : Surface.stroke), lineWidth: hovering ? 1.5 : 1)
            )
            .brightness(primary && hovering ? 0.06 : 0)
            .shadow(color: Brand.green.opacity(hovering ? 0.4 : 0), radius: hovering ? 12 : 0, y: hovering ? 5 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : (hovering ? 1.03 : 1))
            .offset(y: hovering && !configuration.isPressed ? -2 : 0)
            .contentShape(Rectangle())
    }
}

/// Logotipo oficial de cada sistema (Resources/Logos, SVG do Simple Icons) nas cores da marca,
/// com os "raios" verdes e rosa do visual do VM Guave.
struct ImageGlyph: View {
    let source: InstallImage.Source
    let title: String

    var body: some View {
        ZStack {
            rays
            logo
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        }
        .accessibilityLabel(Text(verbatim: title))
    }

    @ViewBuilder
    private var logo: some View {
        switch source {
        case .distro(let distro):
            switch distro {
            case .ubuntuDesktop, .ubuntuServer:
                // Etiqueta laranja com o "Circle of Friends" em branco, como o logotipo oficial.
                Circle()
                    .fill(Color(hex: 0xE95420))
                    .frame(width: 88, height: 88)
                    .overlay(SystemLogo(name: "ubuntu").foregroundStyle(.white).frame(width: 60, height: 60))
            case .fedoraWorkstation:
                // O desenho é o círculo azul com o "f" vazado; o branco atrás preenche o "f".
                ZStack {
                    Circle().fill(.white).frame(width: 76, height: 76)
                    SystemLogo(name: "fedora").foregroundStyle(Color(hex: 0x51A2DA)).frame(width: 86, height: 86)
                }
            case .debian:
                SystemLogo(name: "debian").foregroundStyle(Color(hex: 0xD70A53)).frame(width: 84, height: 84)
            }
        case .windows:
            LinearGradient(colors: [Color(hex: 0x4CC2FF), Color(hex: 0x0067C0)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: 78, height: 78)
                .mask(SystemLogo(name: "windows11").frame(width: 78, height: 78))
        case .macOS:
            SystemLogo(name: "apple").foregroundStyle(Color(light: 0x1D1D1F, dark: 0xF2F2F2)).frame(width: 76, height: 76)
        case .custom:
            Circle()
                .fill(Brand.leaf)
                .frame(width: 84, height: 84)
                .overlay(Image(systemName: "opticaldisc").font(.system(size: 38, weight: .semibold)).foregroundStyle(.white))
        }
    }

    private var rays: some View {
        Canvas { context, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let rays: [(Double, Color)] = [(-135, Brand.pink), (-160, Brand.green), (-110, Brand.green), (20, Brand.pink), (-20, Brand.green)]
            for (angle, color) in rays {
                let rad = angle * .pi / 180
                var path = Path()
                path.move(to: CGPoint(x: c.x + cos(rad) * 52, y: c.y + sin(rad) * 52))
                path.addLine(to: CGPoint(x: c.x + cos(rad) * 62, y: c.y + sin(rad) * 62))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }
        }
    }
}

/// SVG de Resources/Logos como imagem-modelo (a cor vem do foregroundStyle).
private struct SystemLogo: View {
    let name: String

    private static var cache: [String: NSImage] = [:]

    private var image: NSImage? {
        if let cached = Self.cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "Logos"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        Self.cache[name] = image
        return image
    }

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "opticaldisc").resizable().aspectRatio(contentMode: .fit)
        }
    }
}
