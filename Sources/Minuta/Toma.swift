import Foundation

/// Un dictado en curso. Junta el audio (16 kHz mono) y, mientras sigues hablando, lo corta en trozos
/// en los silencios: cada trozo se transcribe al tiro, así al terminar solo falta el último. Si es largo,
/// Claude lo ordena completo al final (ya abierto desde los 4 s, para no esperar a que parta): ordenarlo
/// por partes era más rápido, pero cuando divagabas el texto quedaba enredado.
final class Toma {
    let desde = Date()

    /// Un trozo se corta después de este largo, en el primer silencio…
    private static let trozoMinimo = 8 * 16_000
    /// …y si no hay silencio, igual se corta aquí (en el momento más callado de los últimos 2 s).
    private static let trozoMaximo = 20 * 16_000
    /// Claude se abre a los 4 s de dictado: lo más corto casi nunca llega a 25 palabras.
    private static let abrirClaude: TimeInterval = 4

    private let candado = NSLock()
    private var muestras: [Float] = []
    private var cortado = 0                  // hasta dónde ya se mandó a transcribir
    private var trozos = 0
    private var crudos: [Int: String] = [:]  // lo que entendió Whisper de cada trozo
    private var fallo: Error?
    private var ordenador: Ordenador?
    private var intentoClaude = false
    private var descartada = false
    private(set) var nivel: Float = 0

    private let colaTrozos = DispatchQueue(label: "ai.caravana.minuta.trozos")   // de a uno y en orden
    private let transcribiendo = DispatchGroup()

    /// Llega desde el micrófono (hilo de audio).
    func agregar(_ nuevas: [Float]) {
        let energia = nuevas.reduce(0) { $0 + $1 * $1 } / Float(max(nuevas.count, 1))
        candado.lock()
        muestras.append(contentsOf: nuevas)
        nivel = nivelDeVoz(decibeles: 10 * log10(max(energia, 1e-16)))
        candado.unlock()
    }

    /// Cada 0,25 s (hilo principal).
    func revisar() {
        if !intentoClaude, Dictado.ordenarConIA, Date().timeIntervalSince(desde) >= Self.abrirClaude {
            intentoClaude = true
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let nuevo = Ordenador()
                candado.lock()
                if descartada { nuevo?.cerrar() } else { ordenador = nuevo }
                candado.unlock()
            }
        }
        candado.lock()
        let total = muestras.count
        let pendiente = total - cortado
        var corte: Int?
        if pendiente >= Self.trozoMinimo {
            let ultimos = Array(muestras[(total - 6_400)..<total])   // 0,4 s
            if Self.decibeles(ultimos) < -40 {
                corte = total - 3_200            // al medio del silencio
            } else if pendiente >= Self.trozoMaximo {
                corte = Self.momentoMasCallado(muestras, desde: total - 32_000, hasta: total)
            }
        }
        var trozo: [Float] = []
        var numero = 0
        if let corte {
            trozo = Array(muestras[cortado..<corte])
            cortado = corte
            numero = trozos
            trozos += 1
        }
        candado.unlock()
        if corte != nil { procesar(trozo, numero) }
    }

    /// Ya no se graba: manda el último trozo y, cuando todo esté listo, entrega el texto.
    func cerrar(alOrdenar: @escaping () -> Void, alTerminar: @escaping (Result<Dictado.Entrega?, Error>) -> Void) {
        candado.lock()
        let segundos = Double(muestras.count) / 16_000
        let resto = Array(muestras[cortado...])
        let numero = trozos
        if resto.count >= 4_800 { trozos += 1 }   // menos de 0,3 s es un clic, no una palabra
        candado.unlock()
        guard segundos >= 0.6 else {
            cerrarClaude()
            return alTerminar(.success(nil))
        }
        if resto.count >= 4_800 { procesar(resto, numero) }

        transcribiendo.notify(queue: .global(qos: .userInitiated)) { [self] in
            candado.lock()
            let crudo = (0..<trozos).compactMap { crudos[$0] }.filter { !$0.isEmpty }.joined(separator: " ")
            let error = fallo
            candado.unlock()
            if crudo.isEmpty {
                cerrarClaude()
                return alTerminar(error.map { .failure($0) } ?? .success(nil))
            }
            // Corto: sale tal cual, sin esperar a Claude aunque ya estuviera ordenando.
            guard Dictado.valeLaPenaOrdenar(crudo) else {
                cerrarClaude()
                return alTerminar(.success(Dictado.Entrega(texto: crudo, original: nil, sinOrdenar: false)))
            }
            alOrdenar()
            let entregar = { [self] (ordenado: String?) in
                cerrarClaude()
                alTerminar(.success(Dictado.Entrega(texto: ordenado ?? crudo, original: ordenado == nil ? nil : crudo,
                                                    sinOrdenar: ordenado == nil)))
            }
            candado.lock()
            let ordenador = self.ordenador
            candado.unlock()
            // Todo el dictado de una vez, para que Claude vea las vueltas completas y junte cada tema.
            // Si el Claude ya abierto falla, se ordena con uno nuevo (unos segundos más).
            guard let ordenador else { return entregar(Dictado.ordenar(crudo)) }
            ordenador.ordenar(crudo) { resultado in
                if let resultado, !resultado.isEmpty { return entregar(resultado) }
                DispatchQueue.global(qos: .userInitiated).async { entregar(Dictado.ordenar(crudo)) }
            }
        }
    }

    func descartar() {
        candado.lock()
        descartada = true
        candado.unlock()
        cerrarClaude()
    }

    // MARK: Interno

    private func procesar(_ trozo: [Float], _ numero: Int) {
        transcribiendo.enter()
        colaTrozos.async { [self] in
            defer { transcribiendo.leave() }
            let texto: String
            do { texto = try Dictado.transcribir(trozo) } catch {
                candado.lock(); fallo = error; candado.unlock()
                return
            }
            candado.lock()
            crudos[numero] = texto
            candado.unlock()
        }
    }

    private func cerrarClaude() {
        candado.lock()
        let ordenador = self.ordenador
        self.ordenador = nil
        candado.unlock()
        ordenador?.cerrar()
    }

    private static func decibeles(_ muestras: ArraySlice<Float>) -> Float {
        let energia = muestras.reduce(0) { $0 + $1 * $1 } / Float(max(muestras.count, 1))
        return 10 * log10(max(energia, 1e-16))
    }

    private static func decibeles(_ muestras: [Float]) -> Float { decibeles(muestras[...]) }

    /// El tramo de 0,1 s más callado entre `desde` y `hasta`: ahí se corta si no hubo un silencio claro.
    private static func momentoMasCallado(_ muestras: [Float], desde: Int, hasta: Int) -> Int {
        var mejor = hasta, menor = Float.greatestFiniteMagnitude
        var i = max(desde, 0)
        while i + 1_600 <= hasta {
            let db = decibeles(muestras[i..<(i + 1_600)])
            if db < menor { menor = db; mejor = i + 800 }
            i += 800
        }
        return mejor
    }
}
