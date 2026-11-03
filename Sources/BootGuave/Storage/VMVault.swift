import Foundation
import Security

/// VM criptografada: os arquivos da máquina ficam dentro de um sparsebundle APFS com AES-256
/// (vault.sparsebundle no pacote). Desbloquear = montar em Mounts/<id>; bloquear = desmontar.
/// config.json fica fora, para a VM aparecer na lista mesmo bloqueada.
enum VMVault {
    private static let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")

    /// Arquivo-marca dentro do volume: confirma que o ponto de montagem é mesmo o cofre.
    static let markerName = ".bootguave-vault"

    static func create(at vault: URL, volumeName: String, password: String) async throws {
        // 2 TB é só o teto: um sparsebundle cresce conforme o uso.
        try await run(["create", "-size", "2t", "-type", "SPARSEBUNDLE", "-fs", "APFS",
                       "-encryption", "AES-256", "-stdinpass", "-volname", volumeName, vault.path],
                      password: password)
    }

    static func attach(_ vault: URL, at mountPoint: URL, password: String) async throws {
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        do {
            try await run(["attach", "-stdinpass", "-nobrowse", "-noautoopen", "-owners", "on",
                           "-mountpoint", mountPoint.path, vault.path],
                          password: password)
        } catch {
            throw VaultError.wrongPassword
        }
    }

    static func detach(_ mountPoint: URL) async throws {
        do {
            try await run(["detach", mountPoint.path], password: nil)
        } catch {
            try await run(["detach", "-force", mountPoint.path], password: nil)
        }
        try? FileManager.default.removeItem(at: mountPoint)
    }

    /// Versão bloqueante para usar ao encerrar o app.
    static func detachSync(_ mountPoint: URL) {
        let process = Process()
        process.executableURL = hdiutil
        process.arguments = ["detach", "-force", mountPoint.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: mountPoint)
    }

    private static func run(_ arguments: [String], password: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = hdiutil
            process.arguments = arguments
            let input = Pipe()
            let err = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = err
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    continuation.resume(throwing: VaultError.hdiutil(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do {
                try process.run()
                // A senha vai pela entrada padrão, nunca na linha de comando (visível no ps).
                if let password { input.fileHandleForWriting.write(Data(password.utf8)) }
                try input.fileHandleForWriting.close()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Senhas dos cofres no Keychain do usuário (opcional, escolhido ao desbloquear).
enum VaultKeychain {
    private static let service = "dev.marloon.bootguave.vault"

    static func save(_ password: String, for id: UUID) {
        delete(for: id)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(password.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for id: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum VaultError: LocalizedError {
    case wrongPassword
    case locked
    case hdiutil(String)

    var errorDescription: String? {
        switch self {
        case .wrongPassword: return String(localized: "Senha incorreta (ou o cofre já está em uso).")
        case .locked: return String(localized: "A VM está criptografada e bloqueada. Desbloqueie com a senha primeiro.")
        case .hdiutil(let message): return String(localized: "Falha na imagem criptografada: \(message)")
        }
    }
}
