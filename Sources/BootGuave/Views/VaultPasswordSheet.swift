import SwiftUI

/// Senha do cofre: desbloquear, criptografar (com confirmação) ou remover a criptografia.
struct VaultPasswordSheet: View {
    enum Mode: Identifiable {
        case unlock, encrypt, decrypt
        var id: Self { self }
    }

    let mode: Mode
    let vmName: String
    /// Retorna true se deu certo (fecha a folha); false mantém aberta com erro.
    let onSubmit: (_ password: String, _ remember: Bool) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var remember = true
    @State private var working = false
    @State private var failed = false

    private var title: String {
        switch mode {
        case .unlock: return String(localized: "Desbloquear \"\(vmName)\"")
        case .encrypt: return String(localized: "Criptografar \"\(vmName)\"")
        case .decrypt: return String(localized: "Remover criptografia de \"\(vmName)\"")
        }
    }

    private var canSubmit: Bool {
        guard !working, !password.isEmpty else { return false }
        if mode == .encrypt { return password.count >= 8 && password == confirmation }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            switch mode {
            case .encrypt:
                Text("Disco, snapshots e estado suspenso vão para uma imagem criptografada com AES-256. Sem a senha, ninguém lê os dados, nem você: se esquecer, a VM é irrecuperável.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .decrypt:
                Text("Os arquivos voltam a ficar sem criptografia no disco do Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .unlock:
                EmptyView()
            }

            SecureField("Senha", text: $password)
            if mode == .encrypt {
                SecureField("Confirmar senha", text: $confirmation)
                if !password.isEmpty && password.count < 8 {
                    Text("Use pelo menos 8 caracteres.").font(.caption).foregroundStyle(.secondary)
                } else if !confirmation.isEmpty && password != confirmation {
                    Text("As senhas não conferem.").font(.caption).foregroundStyle(.red)
                }
            }
            if mode != .decrypt {
                Toggle("Guardar a senha no Keychain (desbloqueia sozinha ao iniciar)", isOn: $remember)
            }
            if failed {
                Text(mode == .unlock ? "Senha incorreta." : "Não deu certo. Veja a mensagem de erro.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                Button(mode == .unlock ? "Desbloquear" : mode == .encrypt ? "Criptografar" : "Remover") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func submit() {
        working = true
        failed = false
        Task {
            let ok = await onSubmit(password, remember && mode != .decrypt)
            working = false
            if ok { dismiss() } else { failed = true }
        }
    }
}
