// bgctl — controla o VM Guave pelo terminal. Fala com o app por um socket Unix;
// se o app não estiver aberto, abre em segundo plano.
import ControlProtocol
import Foundation

let usage = """
Uso: bgctl <comando> [argumentos]

  list                              Lista as VMs e o estado de cada uma
  status   <vm>                     Detalhes de uma VM
  start    <vm>                     Liga (ou retoma, se suspensa)
  stop     <vm> [--force]           Desliga (--force: corta a energia)
  suspend  <vm>                     Salva o estado em disco e desliga
  pause    <vm> | resume <vm>       Pausa / continua
  restart  <vm>                     Reinicia
  clone    <vm>                     Clona a VM (precisa estar desligada)
  snapshot list    <vm>
  snapshot create  <vm> <nome>
  snapshot restore <vm> <nome>
  snapshot delete  <vm> <nome>
  export   <vm> <pasta>             Exporta/backup da VM para uma pasta
  import   <caminho.bootguave>      Importa uma VM exportada
  encrypt  <vm>                     Criptografa a VM (AES-256) — pede a senha
  decrypt  <vm>                     Remove a criptografia — pede a senha
  unlock   <vm> | lock <vm>         Desbloqueia / bloqueia uma VM criptografada

Senha: digitada sem eco no terminal, ou lida da entrada padrão com --password-stdin.

<vm> pode ser o nome (sem diferenciar maiúsculas) ou o começo do ID.
"""

func connectToApp() -> Int32? {
    guard var addr = ControlSocket.address() else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if result == 0 { return fd }
    close(fd)
    return nil
}

func launchAppAndConnect() -> Int32? {
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "-b", ControlSocket.bundleIdentifier]
    try? open.run()
    open.waitUntilExit()
    for _ in 0..<60 {
        if let fd = connectToApp() { return fd }
        usleep(250_000)
    }
    return nil
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || ["help", "-h", "--help"].contains(arguments[0]) {
    print(usage)
    exit(0)
}
let command = arguments.removeFirst()

// Senha nunca vai na linha de comando (ficaria visível no ps e no histórico).
if ["encrypt", "decrypt", "unlock"].contains(command) {
    let fromStdin = arguments.contains("--password-stdin")
    arguments.removeAll { $0 == "--password-stdin" }
    let password: String?
    if fromStdin {
        password = readLine(strippingNewline: true)
    } else {
        password = getpass("Senha: ").map { String(cString: $0) }
    }
    guard let password, !password.isEmpty else { fail("Senha vazia.") }
    if command == "encrypt" && !fromStdin {
        let again = getpass("Confirme a senha: ").map { String(cString: $0) }
        guard again == password else { fail("As senhas não conferem.") }
    }
    arguments.append(password)
}

guard let fd = connectToApp() ?? launchAppAndConnect() else {
    fail("Não foi possível falar com o VM Guave. Ele está instalado em /Applications?")
}

var payload = (try? JSONEncoder().encode(ControlRequest(command: command, args: arguments))) ?? Data()
payload.append(0x0A)
_ = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
shutdown(fd, SHUT_WR)

var received = Data()
var buffer = [UInt8](repeating: 0, count: 16 * 1024)
while true {
    let n = read(fd, &buffer, buffer.count)
    if n <= 0 { break }
    received.append(buffer, count: n)
}
close(fd)

guard let response = try? JSONDecoder().decode(ControlResponse.self, from: received) else {
    fail("Resposta inválida do VM Guave.")
}
if response.ok {
    if !response.output.isEmpty { print(response.output) }
} else {
    fail("Erro: \(response.output)")
}
