import AppKit
import ApplicationServices
import AVFoundation

/// Dictado: graba el micrófono, lo transcribe con Whisper y escribe el texto donde está el cursor.
/// El texto además queda en el portapapeles y en el historial ~/Reuniones/Dictados/AAAA-MM-DD.md.
final class Dictado {
    private var grabadora: AVAudioRecorder?
    private var archivo: URL?
    private(set) var desde: Date?

    var activo: Bool { grabadora != nil }

    func empezar() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minuta-dictado-\(UUID().uuidString).wav")
        // WAV 16 kHz mono: lo que Whisper usa directo, sin convertir.
        let ajustes: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let grabadora = try AVAudioRecorder(url: url, settings: ajustes)
        grabadora.isMeteringEnabled = true   // para las barritas que se mueven con tu voz
        guard grabadora.record() else { throw ErrorDictado.noGraba }
        ServidorWhisper.compartido.preparar()   // carga el modelo mientras hablas
        self.grabadora = grabadora
        archivo = url
        desde = Date()
    }

    /// Volumen del micrófono ahora mismo, de 0 (silencio) a 1.
    func nivel() -> Float {
        guard let grabadora else { return 0 }
        grabadora.updateMeters()
        return nivelDeVoz(decibeles: grabadora.averagePower(forChannel: 0))
    }

    /// Corta sin transcribir ni escribir nada (el botón ✕ de la barra).
    func descartar() {
        grabadora?.stop()
        if let archivo { try? FileManager.default.removeItem(at: archivo) }
        grabadora = nil
        archivo = nil
        desde = nil
        ServidorWhisper.compartido.soltar()
    }

    /// Detiene, transcribe y entrega el texto (o nil si no se entendió nada) en el hilo principal.
    func terminar(alTerminar: @escaping (Result<String?, Error>) -> Void) {
        guard let grabadora, let archivo, let desde else { return }
        self.grabadora = nil
        self.desde = nil
        let segundos = Date().timeIntervalSince(desde)
        // Sigue grabando medio segundo más: la gente aprieta el atajo antes de terminar la última palabra.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
            grabadora.stop()
            defer { try? FileManager.default.removeItem(at: archivo) }
            let resultado: Result<String?, Error>
            if segundos < 0.6 {
                resultado = .success(nil)
            } else {
                resultado = Result { try Dictado.transcribir(archivo) }
            }
            DispatchQueue.main.async { alTerminar(resultado) }
        }
    }

    private static func transcribir(_ wav: URL) throws -> String? {
        let duracion = (try? AVAudioFile(forReading: wav)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? 30
        let bruto = try ServidorWhisper.compartido.transcribir(wav, segundos: duracion) ?? transcribirSinServidor(wav)
        let texto = bruto.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return texto.isEmpty || esAlucinacion(texto) ? nil : texto
    }

    /// Como antes del servidor: whisper-cli carga el modelo en cada dictado (unos segundos más).
    private static func transcribirSinServidor(_ wav: URL) throws -> String {
        guard let whisper = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw ErrorDictado.sinWhisper }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: whisper)
        p.arguments = ["-m", Config.modelo, "-f", wav.path, "-l", Config.idioma, "-nt", "-np"]
            + (Config.vocabulario.isEmpty ? [] : ["--prompt", Config.vocabulario])
        let salida = Pipe()
        p.standardOutput = salida
        p.standardError = FileHandle.nullDevice
        try p.run()
        let datos = salida.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ErrorDictado.whisperFallo }
        return String(data: datos, encoding: .utf8) ?? ""
    }

    /// Frases que Whisper inventa cuando no escucha voz (igual que en procesar.py).
    private static func esAlucinacion(_ texto: String) -> Bool {
        // Con silencio, Whisper a veces devuelve letras sueltas: ", a, a, a,".
        if !texto.split(whereSeparator: { !$0.isLetter }).contains(where: { $0.count > 1 }) { return true }
        let t = texto.lowercased().replacingOccurrences(of: " ", with: "")
        let frases = ["amara.org", "subtítulosrealizados", "subtitulosrealizados", "graciasporver",
                      "suscríbete", "suscribete", "suscríbanse", "thanksforwatching", "[música]", "(música)"]
        return frases.contains { t.contains($0) }
    }

    // MARK: Escribir el texto

    /// Deja el texto en el portapapeles y lo pega donde está el cursor (simula ⌘V).
    /// Devuelve false si macOS no dio permiso de Accesibilidad: en ese caso queda solo copiado.
    @discardableResult
    static func escribir(_ texto: String) -> Bool {
        let portapapeles = NSPasteboard.general
        portapapeles.clearContents()
        portapapeles.setString(texto, forType: .string)

        let opciones = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opciones) else { return false }
        let fuente = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9   // tecla V
        for abajo in [true, false] {
            let evento = CGEvent(keyboardEventSource: fuente, virtualKey: v, keyDown: abajo)
            evento?.flags = .maskCommand
            evento?.post(tap: .cghidEventTap)
        }
        return true
    }

    /// El último dictado del historial (sirve aunque hayas cerrado Minuta entremedio).
    static func ultimo() -> String? {
        let carpeta = Config.carpetaReuniones.appendingPathComponent("Dictados")
        guard let dias = try? FileManager.default.contentsOfDirectory(atPath: carpeta.path),
              let dia = dias.filter({ $0.hasSuffix(".md") }).max(),
              let texto = try? String(contentsOf: carpeta.appendingPathComponent(dia), encoding: .utf8),
              let marca = texto.range(of: #"(?m)^\[\d{2}:\d{2}\] "#, options: [.regularExpression, .backwards])
        else { return nil }
        // Un dictado ordenado puede tener varias líneas; termina donde empieza su "> Original:".
        var dictado = String(texto[marca.upperBound...])
        if let original = dictado.range(of: "\n> Original:") { dictado = String(dictado[..<original.lowerBound]) }
        dictado = dictado.trimmingCharacters(in: .whitespacesAndNewlines)
        return dictado.isEmpty ? nil : dictado
    }

    // MARK: Ordenar con Claude

    /// Ordenar con Claude los dictados largos (se cambia en Ajustes).
    static var ordenarConIA: Bool {
        get { UserDefaults.standard.object(forKey: "ordenarDictados") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ordenarDictados") }
    }

    /// Desde cuántas palabras vale la pena ordenarlo: lo corto sale tal cual y al instante.
    static let palabrasParaOrdenar = 25

    static func valeLaPenaOrdenar(_ texto: String) -> Bool {
        ordenarConIA && texto.split(whereSeparator: { $0.isWhitespace }).count >= palabrasParaOrdenar
    }

    /// Le pasa el dictado a Claude (`claude -p`, con tu suscripción) para sacar repeticiones, muletillas
    /// y vueltas. Tarda unos 6 s. Devuelve nil si Claude no está o no respondió: ahí se escribe tal cual.
    static func ordenar(_ texto: String) -> String? {
        guard let claude = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                            FileManager.default.homeDirectoryForCurrentUser.path + "/.local/bin/claude"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        // Tu versión en Application Support (si la hiciste) manda sobre la del repo.
        let propia = Config.soporte.appendingPathComponent("dictado.md")
        guard var instrucciones = (try? String(contentsOf: propia, encoding: .utf8))
                ?? Bundle.main.url(forResource: "dictado", withExtension: "md", subdirectory: "plantillas")
                    .flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else { return nil }
        if !Config.vocabulario.isEmpty {
            instrucciones += "\nNombres y palabras que suele usar (escríbelos así): \(Config.vocabulario)\n"
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = ["-p", "--model", Config.modeloDictado, "--tools", "", "--no-session-persistence",
                       "--strict-mcp-config", "--system-prompt", instrucciones]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        var entorno = ProcessInfo.processInfo.environment
        entorno["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (entorno["PATH"] ?? "/usr/bin:/bin")
        p.environment = entorno
        let entrada = Pipe(), salida = Pipe()
        p.standardInput = entrada
        p.standardOutput = salida
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        entrada.fileHandleForWriting.write(Data("<dictado>\n\(texto)\n</dictado>\n".utf8))
        try? entrada.fileHandleForWriting.close()
        // Si se cuelga, mejor escribir el dictado tal cual que dejarte esperando.
        let corte = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 40, execute: corte)
        let datos = salida.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        corte.cancel()
        guard p.terminationStatus == 0 else { return nil }
        let ordenado = (String(data: datos, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ordenado.isEmpty ? nil : ordenado
    }

    /// Agrega el dictado al historial del día.
    /// Si lo ordenó Claude, `original` es lo que dijiste tal cual: queda debajo, por si se perdió algo.
    static func guardar(_ texto: String, original: String? = nil) {
        let carpeta = Config.carpetaReuniones.appendingPathComponent("Dictados")
        try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        let dia = DateFormatter(), hora = DateFormatter()
        dia.dateFormat = "yyyy-MM-dd"
        hora.dateFormat = "HH:mm"
        let ahora = Date()
        let url = carpeta.appendingPathComponent("\(dia.string(from: ahora)).md")
        let linea = "[\(hora.string(from: ahora))] \(texto)\n" + (original.map { "> Original: \($0)\n" } ?? "") + "\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(linea.utf8))
            try? h.close()
        } else {
            try? ("# Dictados · \(dia.string(from: ahora))\n\n" + linea).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

enum ErrorDictado: LocalizedError {
    case noGraba, sinWhisper, whisperFallo

    var errorDescription: String? {
        switch self {
        case .noGraba: return "No pude usar el micrófono. Revisa el permiso de Micrófono de Minuta."
        case .sinWhisper: return "Falta whisper-cpp. Instálalo con: brew install whisper-cpp"
        case .whisperFallo: return "Whisper no pudo transcribir el dictado."
        }
    }
}
