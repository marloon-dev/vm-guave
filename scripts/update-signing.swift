// Assinatura das atualizações do VM Guave (Ed25519, como o Sparkle).
//
//   swift scripts/update-signing.swift generate          cria o par de chaves (uma vez só)
//   swift scripts/update-signing.swift public            mostra a chave pública (vai no app)
//   swift scripts/update-signing.swift sign <arquivo>    grava <arquivo>.sig
//
// A chave privada fica no Keychain do Mac (serviço "VM Guave – assinatura de atualizações"),
// nunca no repositório nem no GitHub. Faça uma cópia segura dela: sem ela, as versões novas
// não são aceitas pelo app instalado dos usuários (teriam de reinstalar à mão).
import CryptoKit
import Foundation

let service = "VM Guave – assinatura de atualizações"
let account = "ed25519"

func security(_ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (p.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
}

func privateKey() -> Curve25519.Signing.PrivateKey {
    let found = security(["find-generic-password", "-s", service, "-a", account, "-w"])
    guard found.status == 0, let raw = Data(base64Encoded: found.output),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        FileHandle.standardError.write("Chave de assinatura não encontrada no Keychain. Rode: swift scripts/update-signing.swift generate\n".data(using: .utf8)!)
        exit(1)
    }
    return key
}

func sha256(_ url: URL) -> Data {
    let handle = try! FileHandle(forReadingFrom: url)
    var hasher = SHA256()
    while let chunk = try! handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return Data(hasher.finalize())
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "generate":
    if security(["find-generic-password", "-s", service, "-a", account]).status == 0 {
        print("Já existe uma chave no Keychain; nada foi alterado.")
        exit(0)
    }
    let key = Curve25519.Signing.PrivateKey()
    let added = security(["add-generic-password", "-s", service, "-a", account, "-w", key.rawRepresentation.base64EncodedString()])
    guard added.status == 0 else { print("Não consegui gravar no Keychain."); exit(1) }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case "public":
    print(privateKey().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard let path = args.dropFirst().first else { print("Uso: sign <arquivo>"); exit(1) }
    let url = URL(fileURLWithPath: path)
    // Assina o SHA-256 do arquivo (32 bytes); o app confere o mesmo hash que já calcula.
    let signature = try! privateKey().signature(for: sha256(url))
    try! (signature.base64EncodedString() + "\n").write(to: URL(fileURLWithPath: path + ".sig"), atomically: true, encoding: .utf8)
    print("Assinado: \(path).sig")
default:
    print("Uso: generate | public | sign <arquivo>")
    exit(1)
}
