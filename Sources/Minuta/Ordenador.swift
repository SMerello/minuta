import Foundation

/// Claude abierto mientras dictas, para ordenar el dictado por partes a medida que hablas.
/// Cada respuesta de Claude tarda al menos ~3,5 s aunque sea una frase; si cada trozo se ordena
/// apenas se transcribe, al terminar solo queda esperar el último. Usa `claude -p` en modo
/// conversación (stream-json): el proceso queda esperando partes hasta que se cierra.
final class Ordenador {
    private let proceso = Process()
    private let entrada = Pipe()
    private let cola = DispatchQueue(label: "ai.caravana.minuta.ordenador")
    private var esperando: [(String?) -> Void] = []   // una por parte enviada, en el orden en que se mandaron
    private var partes = 0
    private var vivo = true

    private static let porPartes = """

    El dictado te llega por partes, a medida que la persona habla, cada una en <parte n="…">. Responde cada parte \
    con solo esa parte ya ordenada, para pegarla a continuación de las anteriores (sin repetirlas). Si en esta parte \
    repite algo que ya dijo en una parte anterior, omítelo. Si una parte no agrega nada nuevo, responde exactamente: (nada)
    """

    init?() {
        guard let claude = Dictado.rutaClaude(), let instrucciones = Dictado.instruccionesParaOrdenar() else { return nil }
        proceso.executableURL = URL(fileURLWithPath: claude)
        proceso.arguments = ["-p", "--model", Config.modeloDictado, "--tools", "", "--no-session-persistence",
                             "--strict-mcp-config", "--input-format", "stream-json", "--output-format", "stream-json",
                             "--verbose", "--system-prompt", instrucciones + Self.porPartes]
        proceso.currentDirectoryURL = FileManager.default.temporaryDirectory
        var entorno = ProcessInfo.processInfo.environment
        entorno["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (entorno["PATH"] ?? "/usr/bin:/bin")
        proceso.environment = entorno
        let salida = Pipe()
        proceso.standardInput = entrada
        proceso.standardOutput = salida
        proceso.standardError = FileHandle.nullDevice
        guard (try? proceso.run()) != nil else { return nil }

        // Lee las respuestas línea por línea; cada "result" responde la parte más antigua pendiente.
        Thread.detachNewThread { [weak self] in
            var pendiente = Data()
            let lector = salida.fileHandleForReading
            while case let datos = lector.availableData, !datos.isEmpty {
                pendiente.append(datos)
                while let salto = pendiente.firstIndex(of: 0x0A) {
                    let linea = pendiente[pendiente.startIndex..<salto]
                    pendiente.removeSubrange(pendiente.startIndex...salto)
                    guard let evento = try? JSONSerialization.jsonObject(with: linea) as? [String: Any],
                          evento["type"] as? String == "result" else { continue }
                    let bien = evento["subtype"] as? String == "success" && evento["is_error"] as? Bool != true
                    let texto = (evento["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.responder(bien ? (texto == "(nada)" ? "" : texto) : nil)
                }
            }
            self?.morir()
        }
    }

    /// Manda una parte. `alTerminar` recibe esa parte ordenada ("" si no agregaba nada) o nil si Claude falló.
    func ordenar(_ texto: String, alTerminar: @escaping (String?) -> Void) {
        cola.async { [self] in
            guard vivo else { return alTerminar(nil) }
            partes += 1
            esperando.append(alTerminar)
            let mensaje: [String: Any] = ["type": "user", "message": [
                "role": "user", "content": "<parte n=\"\(partes)\">\n\(texto)\n</parte>"]]
            guard var linea = try? JSONSerialization.data(withJSONObject: mensaje) else { return responder(nil) }
            linea.append(0x0A)
            entrada.fileHandleForWriting.write(linea)
        }
    }

    func cerrar() {
        cola.async { [self] in
            try? entrada.fileHandleForWriting.close()
            if proceso.isRunning { proceso.terminate() }
        }
    }

    private func responder(_ texto: String?) {
        cola.async { [self] in
            guard !esperando.isEmpty else { return }
            esperando.removeFirst()(texto)
        }
    }

    /// Claude se cerró (o se cayó): lo que estaba esperando queda sin ordenar.
    private func morir() {
        cola.async { [self] in
            vivo = false
            let pendientes = esperando
            esperando = []
            pendientes.forEach { $0(nil) }
        }
    }
}
