import ControlProtocol
import Foundation

/// Executa os comandos do bgctl usando a mesma VMLibrary da interface.
@MainActor
enum ControlCommands {
    private struct CommandError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    static func handle(_ request: ControlRequest, library: VMLibrary) async -> ControlResponse {
        do {
            let output = try await run(request.command, request.args, library)
            return ControlResponse(ok: true, output: output)
        } catch let error as CommandError {
            return ControlResponse(ok: false, output: error.message)
        } catch {
            return ControlResponse(ok: false, output: error.localizedDescription)
        }
    }

    private static func run(_ command: String, _ args: [String], _ library: VMLibrary) async throws -> String {
        switch command {
        case "list":
            return list(library)

        case "status":
            let (config, runner) = try resolve(args, 0, library)
            let snapshots = library.snapshots(for: config.id).count
            return """
            Nome:       \(config.name)
            ID:         \(config.id.uuidString)
            Estado:     \(runner.state.label)
            Sistema:    \(config.os.displayName)
            CPUs:       \(config.cpuCount)
            Memória:    \(config.memoryGB) GB
            Disco:      \(config.diskGB) GB\(config.extraDisks.isEmpty ? "" : " + \(config.extraDisks.count) adicional(is)")
            Snapshots:  \(snapshots)
            """

        case "start", "resume":
            let (config, runner) = try resolve(args, 0, library)
            if library.isLocked(config.id) && VaultKeychain.load(for: config.id) == nil {
                throw CommandError("\(config.name) está criptografada e bloqueada. Use 'bgctl unlock \"\(config.name)\"' antes.")
            }
            if runner.state == .paused {
                runner.resume()
                await waitWhile(runner, timeout: 10) { $0 == .paused }
            } else {
                runner.start()
            }
            await waitWhile(runner) { $0 == .starting }
            return try outcome(runner, config)

        case "stop":
            let (config, runner) = try resolve(args, 0, library)
            if args.contains("--force") {
                runner.forceStop()
            } else {
                runner.requestStop()
            }
            await waitWhile(runner, timeout: 10) { $0.isActive }
            return runner.state.isActive
                ? "\(config.name): desligamento solicitado (o sistema convidado ainda está encerrando)."
                : try outcome(runner, config)

        case "suspend":
            let (config, runner) = try resolve(args, 0, library)
            runner.suspend()
            await waitWhile(runner, timeout: 120) { $0 == .saving }
            if let notice = runner.notice { throw CommandError(notice) }
            return try outcome(runner, config)

        case "pause":
            let (config, runner) = try resolve(args, 0, library)
            runner.pause()
            await waitWhile(runner, timeout: 5) { $0 == .running }
            return try outcome(runner, config)

        case "restart":
            let (config, runner) = try resolve(args, 0, library)
            runner.restart()
            await waitWhile(runner) { $0 == .stopping || $0 == .starting }
            return try outcome(runner, config)

        case "clone":
            let (config, _) = try resolve(args, 0, library)
            let id = try capture(library) { library.clone(config.id) }
            guard let id, let copy = library.config(for: id) else { throw CommandError("Falha ao clonar.") }
            return "Clonada: \(copy.name) (\(id.uuidString))"

        case "snapshot":
            return try snapshot(args, library)

        case "export":
            let (config, _) = try resolve(args, 0, library)
            guard args.count > 1 else { throw CommandError("Informe a pasta de destino.") }
            let folder = URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
            library.lastError = nil
            let destination = await library.export(config.id, to: folder)
            if let error = library.lastError { library.lastError = nil; throw CommandError(error) }
            return "Exportada para \(destination?.path ?? folder.path)"

        case "encrypt", "decrypt", "unlock", "lock":
            let (config, runner) = try resolve(args, 0, library)
            let password = args.count > 1 ? args[1] : ""
            library.lastError = nil
            switch command {
            case "encrypt":
                guard password.count >= 8 else { throw CommandError("Use uma senha com pelo menos 8 caracteres.") }
                await library.encrypt(config.id, password: password, remember: false)
            case "decrypt":
                await library.decrypt(config.id, password: password)
            case "unlock":
                await library.unlock(config.id, password: password, remember: false)
            default:
                await library.lock(config.id)
            }
            if let error = library.lastError { library.lastError = nil; throw CommandError(error) }
            runner.refreshState()
            let current = library.config(for: config.id) ?? config
            return "\(config.name): " + (current.encrypted ? (library.isLocked(config.id) ? "criptografada, bloqueada" : "criptografada, desbloqueada") : "sem criptografia")

        case "import":
            guard let path = args.first else { throw CommandError("Informe o caminho do .bootguave.") }
            library.lastError = nil
            let id = await library.importVM(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            if let error = library.lastError { library.lastError = nil; throw CommandError(error) }
            guard let id, let config = library.config(for: id) else { throw CommandError("Falha ao importar.") }
            return "Importada: \(config.name) (\(id.uuidString))"

        default:
            throw CommandError("Comando desconhecido: \(command). Use 'bgctl help'.")
        }
    }

    private static func list(_ library: VMLibrary) -> String {
        guard !library.configs.isEmpty else { return "Nenhuma VM." }
        let rows = library.configs.map { config -> [String] in
            let state = library.runner(for: config.id)?.state.label ?? "-"
            return [config.name, state, config.os.displayName, "\(config.cpuCount)", "\(config.memoryGB) GB", String(config.id.uuidString.prefix(8))]
        }
        let header = ["NOME", "ESTADO", "SISTEMA", "CPU", "RAM", "ID"]
        let all = [header] + rows
        let widths = header.indices.map { col in all.map { $0[col].count }.max() ?? 0 }
        return all.map { row in
            row.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    private static func snapshot(_ args: [String], _ library: VMLibrary) throws -> String {
        guard let action = args.first else { throw CommandError("Use: snapshot list|create|restore|delete <vm> [nome]") }
        let (config, _) = try resolve(args, 1, library)
        if library.isLocked(config.id) { throw CommandError(VaultError.locked.localizedDescription) }
        let snapshots = library.snapshots(for: config.id)

        func named() throws -> VMSnapshot {
            guard args.count > 2 else { throw CommandError("Informe o nome do snapshot.") }
            let name = args[2...].joined(separator: " ")
            guard let match = snapshots.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw CommandError("Snapshot não encontrado: \(name)")
            }
            return match
        }

        switch action {
        case "list":
            guard !snapshots.isEmpty else { return "Nenhum snapshot." }
            return snapshots.map {
                "\($0.name)  ·  \($0.createdAt.formatted(date: .abbreviated, time: .shortened))\($0.includesMachineState ? "  ·  com memória" : "")"
            }.joined(separator: "\n")
        case "create":
            guard args.count > 2 else { throw CommandError("Informe o nome do snapshot.") }
            let name = args[2...].joined(separator: " ")
            try capture(library) { library.createSnapshot(for: config.id, named: name) }
            return "Snapshot criado: \(name)"
        case "restore":
            let snapshot = try named()
            try capture(library) { library.restoreSnapshot(snapshot, for: config.id) }
            return "Restaurado: \(snapshot.name)"
        case "delete":
            let snapshot = try named()
            try capture(library) { library.deleteSnapshot(snapshot, for: config.id) }
            return "Excluído: \(snapshot.name)"
        default:
            throw CommandError("Ação de snapshot desconhecida: \(action)")
        }
    }

    // MARK: Utilitários

    /// Aceita nome exato (sem diferenciar maiúsculas), prefixo de UUID ou prefixo único de nome.
    private static func resolve(_ args: [String], _ index: Int, _ library: VMLibrary) throws -> (VMConfig, VMRunner) {
        guard args.count > index else { throw CommandError("Informe a VM (nome ou ID).") }
        let query = args[index]
        let configs = library.configs
        let match = configs.first { $0.name.caseInsensitiveCompare(query) == .orderedSame }
            ?? configs.first { $0.id.uuidString.lowercased().hasPrefix(query.lowercased()) && query.count >= 4 }
            ?? {
                let prefixed = configs.filter { $0.name.lowercased().hasPrefix(query.lowercased()) }
                return prefixed.count == 1 ? prefixed[0] : nil
            }()
        guard let config = match, let runner = library.runner(for: config.id) else {
            throw CommandError("VM não encontrada: \(query)")
        }
        return (config, runner)
    }

    /// Operações da biblioteca reportam erro em lastError (para o alerta da interface);
    /// aqui o erro vira resposta do comando e não aparece como alerta.
    @discardableResult
    private static func capture<T>(_ library: VMLibrary, _ body: () -> T) throws -> T {
        library.lastError = nil
        let result = body()
        if let error = library.lastError {
            library.lastError = nil
            throw CommandError(error)
        }
        return result
    }

    private static func waitWhile(_ runner: VMRunner, timeout: TimeInterval = 60, _ condition: (VMRunState) -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while condition(runner.state), Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private static func outcome(_ runner: VMRunner, _ config: VMConfig) throws -> String {
        if case .error(let message) = runner.state { throw CommandError(message) }
        return "\(config.name): \(runner.state.label)"
    }
}
