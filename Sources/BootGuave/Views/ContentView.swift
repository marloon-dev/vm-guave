import AppKit
import SwiftUI

/// Janela principal: barra lateral com as seções e a página escolhida.
struct ContentView: View {
    @Environment(VMLibrary.self) private var library
    @Bindable private var router = AppRouter.shared

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 300)
        } detail: {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Sem a faixa cinza da barra de ferramentas: o fundo preto vai até o topo.
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .tint(Brand.green)
        .navigationTitle("")
        .sheet(item: $router.wizardRequest) { request in
            NewVMWizard(initialOS: request.os, initialISO: request.iso) { config in
                library.create(config)
                router.open(vm: config.id)
                if config.os == .macOS {
                    library.runner(for: config.id)?.installMacOS()
                }
            }
        }
        .sheet(isPresented: $router.showingDiskImport) {
            ImportDiskSheet { source, os, name in
                Task {
                    if let id = await library.importDisk(from: source, os: os, name: name) {
                        router.open(vm: id)
                    }
                }
            }
        }
        .overlay {
            if let message = library.busyMessage {
                VStack(spacing: 12) {
                    if let progress = library.busyProgress {
                        ProgressView(value: progress)
                            .frame(width: 220)
                        Text("\(Int(progress * 100))%").monospacedDigit().font(.caption)
                    } else {
                        ProgressView()
                    }
                    Text(message)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .alert(
            "Erro",
            isPresented: Binding(get: { library.lastError != nil }, set: { if !$0 { library.lastError = nil } })
        ) {
            Button("OK") { library.lastError = nil }
        } message: {
            Text(library.lastError ?? "")
        }
        // Por último, para valer também nas folhas: botões sem estilo próprio (formulários,
        // assistentes) ganham a animação de hover do app.
        .buttonStyle(HoverDefaultButtonStyle())
    }

    @ViewBuilder
    private var page: some View {
        switch router.page {
        case .overview: OverviewPage()
        case .machines:
            if let id = router.openVM, let runner = library.runner(for: id) {
                VMDetailPage(runner: runner)
                    .id(id)
            } else {
                MachinesPage()
            }
        case .images: ImagesPage()
        case .network: NetworkPage()
        case .storage: StoragePage()
        case .settings: SettingsPage()
        }
    }
}

// MARK: - Barra lateral

private struct Sidebar: View {
    private let router = AppRouter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: AppLogo.image)
                    .resizable()
                    .frame(width: 46, height: 46)
                    .accessibilityHidden(true)
                Text(verbatim: "VM Guave")
                    .font(.system(size: 26, weight: .bold))
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 26)

            VStack(spacing: 6) {
                ForEach(AppPage.allCases) { page in
                    SidebarItem(page: page, selected: router.page == page) { router.go(page) }
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 20)

            Text("Ambientes que impulsionam ideias.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 170, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            ZStack(alignment: .bottom) {
                Surface.sidebar
                SidebarLeaves()
                    .frame(height: 240)
            }
            .ignoresSafeArea()
        }
    }
}

private struct SidebarItem: View {
    let page: AppPage
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: page.symbol)
                    .font(.system(size: 18, weight: selected ? .semibold : .regular))
                    .frame(width: 26)
                Text(page.title)
                    .font(.title3.weight(selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Brand.ink : .primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Brand.green : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .guaveHover(selected ? .primary : .secondary(HoverKind.rounded(12)))
    }
}

/// Arte original do ícone; o applicationIconImage vem dentro do quadrado cinza do macOS.
enum AppLogo {
    static let image: NSImage = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap(NSImage.init(contentsOf:)) ?? NSApp.applicationIconImage
}

/// Ilustração quando ainda não há VMs (usada na lista de máquinas).
struct EmptyMachinesView: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VMIllustration()
                .frame(width: 280, height: 230)
            Text("Suas máquinas virtuais, em um só lugar")
                .font(.system(size: 24, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 20)
            Text("Crie uma VM para rodar Linux, Windows ou macOS ao lado do seu Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
            Button("Criar primeira VM", action: onCreate)
                .buttonStyle(GuaveButtonStyle(large: true))
                .padding(.top, 24)
        }
        .padding(40)
        .frame(maxWidth: .infinity)
    }
}
