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
        guard grabadora.record() else { throw ErrorDictado.noGraba }
        self.grabadora = grabadora
        archivo = url
        desde = Date()
    }

    /// Detiene, transcribe y entrega el texto (o nil si no se entendió nada) en el hilo principal.
    func terminar(alTerminar: @escaping (Result<String?, Error>) -> Void) {
        guard let grabadora, let archivo, let desde else { return }
        grabadora.stop()
        self.grabadora = nil
        self.desde = nil
        let segundos = Date().timeIntervalSince(desde)
        DispatchQueue.global(qos: .userInitiated).async {
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
        let texto = (String(data: datos, encoding: .utf8) ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return texto.isEmpty || esAlucinacion(texto) ? nil : texto
    }

    /// Frases que Whisper inventa cuando no escucha voz (igual que en procesar.py).
    private static func esAlucinacion(_ texto: String) -> Bool {
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

    /// Agrega el dictado al historial del día.
    static func guardar(_ texto: String) {
        let carpeta = Config.carpetaReuniones.appendingPathComponent("Dictados")
        try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        let dia = DateFormatter(), hora = DateFormatter()
        dia.dateFormat = "yyyy-MM-dd"
        hora.dateFormat = "HH:mm"
        let ahora = Date()
        let url = carpeta.appendingPathComponent("\(dia.string(from: ahora)).md")
        let linea = "[\(hora.string(from: ahora))] \(texto)\n\n"
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
