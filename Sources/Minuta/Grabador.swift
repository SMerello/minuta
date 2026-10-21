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
    private(set) var carpeta: URL?

    /// Se llama si la grabación se corta sola (por ejemplo, si quitas el permiso).
    var alCortarse: ((Error) -> Void)?

    func iniciar(en carpeta: URL) async throws {
        self.carpeta = carpeta
        inicio = nil
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

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of tipo: SCStreamOutputType) {
        guard tipo != .screen, buffer.isValid, let pista = pistas[tipo] else { return }
        let pts = buffer.presentationTimeStamp
        if inicio == nil { inicio = pts }
        guard let inicio, let pcm = Grabador.pcm(de: buffer) else { return }
        pista.escribir(pcm, segundosDesdeInicio: (pts - inicio).seconds)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        alCortarse?(error)
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
