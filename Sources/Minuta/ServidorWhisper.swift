import Foundation
import Darwin

/// Whisper ya cargado en memoria (whisper-server) para que el dictado no espere a cargar el modelo.
/// Parte al empezar a dictar, así carga mientras hablas, y se cierra tras un rato sin dictar
/// para no dejar ~1,7 GB ocupados todo el día. Si algo falla, el dictado usa whisper-cli como antes.
final class ServidorWhisper {
    static let compartido = ServidorWhisper()

    /// Tiempo sin dictar antes de cerrar el servidor. Corto a propósito: ocupa ~1,7 GB y el Mac tiene 16,
    /// y volver a cargarlo toma menos de 1 s y pasa mientras hablas, así que no se nota.
    private static let espera: TimeInterval = 2 * 60

    private let cola = DispatchQueue(label: "ai.caravana.minuta.whisper")
    private var proceso: Process?
    private var puerto: UInt16 = 0
    private var apagado: DispatchWorkItem?

    /// Arranca el servidor si no está corriendo y cancela el cierre pendiente.
    func preparar() {
        cola.async { [self] in
            apagado?.cancel()
            apagado = nil
            if proceso?.isRunning != true { arrancar() }
        }
    }

    /// Texto que entiende el servidor ("" si no escuchó nada), o nil si el servidor no está disponible.
    func transcribir(_ wav: URL, segundos: Double) -> String? {
        defer { programarApagado() }
        let (p, puerto) = cola.sync { (proceso, self.puerto) }
        guard let p else { return nil }
        let base = URL(string: "http://127.0.0.1:\(puerto)")!

        // Normalmente ya cargó mientras hablabas; si no, espera un poco.
        let limite = Date().addingTimeInterval(30)
        while Self.pedir(URLRequest(url: base, timeoutInterval: 1)) == nil {
            guard p.isRunning, Date() < limite else { return nil }
            Thread.sleep(forTimeInterval: 0.1)
        }

        guard let audio = try? Data(contentsOf: wav) else { return nil }
        var campos = ["response_format": "json", "language": Config.idioma,
                      "audio_ctx": String(Self.contextoAudio(segundos))]
        if !Config.vocabulario.isEmpty { campos["prompt"] = Config.vocabulario }
        var pedido = URLRequest(url: base.appendingPathComponent("inference"), timeoutInterval: 60)
        pedido.httpMethod = "POST"
        let limiteMultipart = "minuta-\(UUID().uuidString)"
        pedido.setValue("multipart/form-data; boundary=\(limiteMultipart)", forHTTPHeaderField: "Content-Type")
        pedido.httpBody = Self.formulario(campos, audio: audio, limite: limiteMultipart)

        guard let (datos, respuesta) = Self.pedir(pedido), respuesta.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: datos) as? [String: Any],
              let texto = json["text"] as? String else { return nil }
        return texto
    }

    /// Ya no se va a usar ahora (dictado descartado): se cierra tras el rato de espera de siempre.
    func soltar() {
        programarApagado()
    }

    func apagar() {
        cola.sync {
            apagado?.cancel()
            proceso?.terminate()
            proceso = nil
        }
    }

    /// Cierra un servidor que haya quedado de una ejecución anterior de Minuta (por ejemplo, si se cayó).
    /// Va en la misma cola que `preparar`, así nunca cierra uno recién partido.
    func limpiarRestos() {
        cola.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            p.arguments = ["-f", "whisper-server -m " + NSRegularExpression.escapedPattern(for: Config.modelo)]
            try? p.run()
            p.waitUntilExit()
        }
    }

    // MARK: Interno

    private func arrancar() {
        guard let bin = ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let libre = Self.puertoLibre() else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-m", Config.modelo, "-l", Config.idioma, "--host", "127.0.0.1", "--port", String(libre)]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        proceso = p
        puerto = libre
    }

    private func programarApagado() {
        cola.async { [self] in
            apagado?.cancel()
            let tarea = DispatchWorkItem { [weak self] in
                self?.proceso?.terminate()
                self?.proceso = nil
            }
            apagado = tarea
            cola.asyncAfter(deadline: .now() + Self.espera, execute: tarea)
        }
    }

    /// Whisper procesa siempre 30 s de audio aunque el dictado dure 5. Pedirle solo lo que dura
    /// (50 cuadros por segundo, más ~2,5 s de margen para no cortar el final) lo hace 2 a 3 veces más rápido.
    private static func contextoAudio(_ segundos: Double) -> Int {
        let cuadros = Int((segundos * 50).rounded(.up)) + 128
        let redondeado = (cuadros + 63) / 64 * 64
        return redondeado >= 1500 ? 0 : redondeado   // 0 = los 30 s completos
    }

    private static func formulario(_ campos: [String: String], audio: Data, limite: String) -> Data {
        var cuerpo = Data()
        for (nombre, valor) in campos {
            cuerpo.append(Data("--\(limite)\r\nContent-Disposition: form-data; name=\"\(nombre)\"\r\n\r\n\(valor)\r\n".utf8))
        }
        cuerpo.append(Data("--\(limite)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictado.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        cuerpo.append(audio)
        cuerpo.append(Data("\r\n--\(limite)--\r\n".utf8))
        return cuerpo
    }

    /// Pedido HTTP que espera la respuesta (se llama desde un hilo de fondo).
    private static func pedir(_ pedido: URLRequest) -> (Data, HTTPURLResponse)? {
        let listo = DispatchSemaphore(value: 0)
        var resultado: (Data, HTTPURLResponse)?
        URLSession.shared.dataTask(with: pedido) { datos, respuesta, _ in
            if let datos, let respuesta = respuesta as? HTTPURLResponse { resultado = (datos, respuesta) }
            listo.signal()
        }.resume()
        listo.wait()
        return resultado
    }

    /// Un puerto libre en 127.0.0.1 (el sistema elige uno al pedir el puerto 0).
    private static func puertoLibre() -> UInt16? {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { return nil }
        defer { close(s) }
        var dir = sockaddr_in()
        dir.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        dir.sin_family = sa_family_t(AF_INET)
        dir.sin_addr.s_addr = inet_addr("127.0.0.1")
        var largo = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &dir) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, largo) == 0 && getsockname(s, $0, &largo) == 0
            }
        }
        return ok ? UInt16(bigEndian: dir.sin_port) : nil
    }
}
