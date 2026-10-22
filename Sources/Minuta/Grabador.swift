import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Graba dos pistas de audio en paralelo con ScreenCaptureKit:
/// - `microfono.caf`: tu micrófono (lo que dices tú, o toda la sala si es presencial).
/// - `llamada.caf`: el sonido que sale por el Mac (lo que dicen los demás en Meet, Zoom, Teams, WhatsApp...).
/// No graba video: la pantalla se pide a 2x2 píxeles y esos cuadros se descartan.
/// Tenerlas separadas permite saber quién habló sin tener que adivinar voces.
final class Grabador: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let cola = DispatchQueue(label: "minuta.audio")
    private var pistas: [SCStreamOutputType: Pista] = [:]
    private var inicio: CMTime?
    /// Tramos en pausa, en la misma hora que traen los buffers (reloj del Mac). El último queda abierto mientras dura.
    private var pausas: [(desde: CMTime, hasta: CMTime?)] = []
    private(set) var carpeta: URL?

    /// Volumen de tu micrófono ahora mismo, de 0 a 1 (para las barritas de la barra flotante).
    /// Si hace rato que no llega audio del micrófono, cuenta como silencio.
    var nivelMicrofono: Float {
        candado.lock()
        defer { candado.unlock() }
        return Date().timeIntervalSince(ultimoNivel.cuando) < 0.4 ? ultimoNivel.valor : 0
    }
    /// Lo más fuerte que ha captado tu micrófono en esta grabación: si sigue en casi 0, no te está escuchando.
    var picoMicrofono: Float {
        candado.lock()
        defer { candado.unlock() }
        return pico
    }
    private let candado = NSLock()
    private var ultimoNivel: (valor: Float, cuando: Date) = (0, .distantPast)
    private var pico: Float = 0

    /// Se llama si la grabación se corta sola (por ejemplo, si quitas el permiso).
    var alCortarse: ((Error) -> Void)?

    func iniciar(en carpeta: URL) async throws {
        self.carpeta = carpeta
        inicio = nil
        pausas = []
        candado.withLock { pico = 0 }
        pistas = [
            .microphone: Pista(url: carpeta.appendingPathComponent("microfono.caf")),
            .audio: Pista(url: carpeta.appendingPathComponent("llamada.caf")),
        ]

        let contenido = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let pantalla = contenido.displays.first else { throw ErrorMinuta.sinPantalla }
        let filtro = SCContentFilter(display: pantalla, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Video al mínimo: no lo guardamos, pero ScreenCaptureKit exige una pantalla.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let stream = SCStream(filter: filtro, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: cola)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: cola)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: cola)
        try await stream.startCapture()
        self.stream = stream
    }

    func detener() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        cola.sync {
            for pista in pistas.values { pista.cerrar() }
            pistas = [:]
        }
    }

    /// En pausa no se escribe nada. Al seguir, el audio continúa pegado a lo anterior
    /// (sin un hueco de silencio del largo de la pausa) y las dos pistas siguen alineadas.
    func pausar() {
        let ahora = horaActual()
        cola.async { [self] in
            if pausas.last.map({ $0.hasta != nil }) ?? true { pausas.append((ahora, nil)) }
        }
    }

    func seguir() {
        let ahora = horaActual()
        cola.async { [self] in
            if let ultima = pausas.last, ultima.hasta == nil { pausas[pausas.count - 1].hasta = ahora }
        }
    }

    /// La hora en el mismo reloj con que ScreenCaptureKit marca los buffers.
    private func horaActual() -> CMTime {
        CMClockGetTime(stream?.synchronizationClock ?? CMClockGetHostTimeClock())
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of tipo: SCStreamOutputType) {
        guard tipo != .screen, buffer.isValid, let pista = pistas[tipo] else { return }
        let pts = buffer.presentationTimeStamp
        // Los buffers llegan con un poco de atraso: se descarta lo que se grabó dentro de una pausa.
        if pausas.contains(where: { pts >= $0.desde && ($0.hasta.map { pts < $0 } ?? true) }) { return }
        if inicio == nil { inicio = pts }
        guard let inicio, let pcm = Grabador.pcm(de: buffer) else { return }
        if tipo == .microphone {
            let valor = nivelDeVoz(decibeles: Grabador.decibeles(pcm))
            candado.lock()
            ultimoNivel = (valor, Date())
            pico = max(pico, valor)
            candado.unlock()
        }
        let enPausa = pausas.reduce(0.0) { suma, p in
            guard let hasta = p.hasta, hasta <= pts, p.desde >= inicio else { return suma }
            return suma + (hasta - p.desde).seconds
        }
        pista.escribir(pcm, segundosDesdeInicio: (pts - inicio).seconds - enPausa)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        alCortarse?(error)
    }

    /// Volumen promedio (RMS) del pedazo de audio, en decibeles (0 = lo más fuerte posible).
    private static func decibeles(_ pcm: AVAudioPCMBuffer) -> Float {
        let n = Int(pcm.frameLength)
        guard n > 0 else { return -160 }
        var suma: Float = 0
        if let canales = pcm.floatChannelData {
            for i in 0..<n { suma += canales[0][i] * canales[0][i] }
        } else if let canales = pcm.int16ChannelData {
            for i in 0..<n { let x = Float(canales[0][i]) / 32768; suma += x * x }
        } else {
            return -160
        }
        return 10 * log10(max(suma / Float(n), 1e-16))
    }

    /// Copia el audio de un CMSampleBuffer a un AVAudioPCMBuffer.
    private static func pcm(de buffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let descripcion = buffer.formatDescription else { return nil }
        let formato = AVAudioFormat(cmAudioFormatDescription: descripcion)
        let cuadros = AVAudioFrameCount(buffer.numSamples)
        guard cuadros > 0, let pcm = AVAudioPCMBuffer(pcmFormat: formato, frameCapacity: cuadros) else { return nil }
        pcm.frameLength = cuadros
        let estado = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            buffer, at: 0, frameCount: Int32(cuadros), into: pcm.mutableAudioBufferList)
        return estado == noErr ? pcm : nil
    }
}

/// Un archivo de audio (AAC dentro de CAF, que aguanta mejor un corte a mitad de grabación).
/// Si al audio le faltan pedazos (por ejemplo, el Mac no manda nada mientras hay silencio),
/// rellena con silencio para que las dos pistas queden alineadas en el tiempo.
private final class Pista {
    let url: URL
    private var archivo: AVAudioFile?
    private var cuadrosEscritos: AVAudioFramePosition = 0

    init(url: URL) { self.url = url }

    func escribir(_ pcm: AVAudioPCMBuffer, segundosDesdeInicio: Double) {
        let formato = pcm.format
        if archivo == nil {
            let ajustes: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: formato.sampleRate,
                AVNumberOfChannelsKey: formato.channelCount,
            ]
            archivo = try? AVAudioFile(
                forWriting: url, settings: ajustes,
                commonFormat: formato.commonFormat, interleaved: formato.isInterleaved)
        }
        guard let archivo else { return }

        let esperado = Double(cuadrosEscritos) / formato.sampleRate
        let hueco = segundosDesdeInicio - esperado
        if hueco > 0.05 {
            escribirSilencio(AVAudioFrameCount(hueco * formato.sampleRate), formato: formato, en: archivo)
        }
        do {
            try archivo.write(from: pcm)
            cuadrosEscritos += AVAudioFramePosition(pcm.frameLength)
        } catch {
            NSLog("Minuta: no se pudo escribir audio en \(url.lastPathComponent): \(error)")
        }
    }

    private func escribirSilencio(_ total: AVAudioFrameCount, formato: AVAudioFormat, en archivo: AVAudioFile) {
        var restante = total
        while restante > 0 {
            let n = min(restante, 48_000)
            guard let silencio = AVAudioPCMBuffer(pcmFormat: formato, frameCapacity: n) else { return }
            silencio.frameLength = n
            let abl = UnsafeMutableAudioBufferListPointer(silencio.mutableAudioBufferList)
            for b in abl { if let datos = b.mData { memset(datos, 0, Int(b.mDataByteSize)) } }
            guard (try? archivo.write(from: silencio)) != nil else { return }
            cuadrosEscritos += AVAudioFramePosition(n)
            restante -= n
        }
    }

    func cerrar() {
        archivo?.close()
        archivo = nil
    }
}

enum ErrorMinuta: LocalizedError {
    case sinPantalla

    var errorDescription: String? {
        switch self {
        case .sinPantalla: return "No encontré una pantalla para iniciar la captura de audio."
        }
    }
}
