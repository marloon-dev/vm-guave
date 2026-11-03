import SwiftUI

/// Detalhe de uma VM dentro de "Máquinas Virtuais", com caminho de volta para a lista.
struct VMDetailPage: View {
    let runner: VMRunner
    @Environment(VMLibrary.self) private var library
    private let router = AppRouter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { router.openVM = nil } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                    Text("Máquinas Virtuais")
                }
                .font(.title3.weight(.medium))
                .foregroundStyle(Brand.green)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .guaveHover(.text)
            .padding(.horizontal, 36)
            .padding(.top, 22)

            VMDetailView(
                runner: runner,
                onDelete: {
                    let id = runner.config.id
                    router.openVM = nil
                    library.delete(id)
                },
                onClone: { router.open(vm: $0) }
            )
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 16)
        }
        .background(PageBackground())
    }
}
