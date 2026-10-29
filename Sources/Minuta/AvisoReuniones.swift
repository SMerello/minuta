import Foundation

/// Un minuto antes de una reunión del calendario con link de video (Meet, Zoom, Teams…), avisa para
/// grabarla. Así no depende de acordarse de apretar el atajo ni de que la llamada ya haya empezado.
/// Mira el calendario cada 30 s; cada reunión se avisa una sola vez.
final class AvisoReuniones {
    /// Se llama con la reunión que está por empezar (en el hilo principal).
    var alAvisar: (Evento) -> Void = { _ in }

    /// Avisar antes de las reuniones (se cambia en Ajustes).
    static var encendido: Bool {
        get { UserDefaults.standard.object(forKey: "avisoAntesDeReuniones") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "avisoAntesDeReuniones") }
    }

    /// Desde cuánto antes de empezar se avisa, y hasta cuánto después (si el Mac despertó tarde).
    private static let antes: TimeInterval = 75
    private static let despues: TimeInterval = 60

    private var reloj: Timer?
    private var avisadas = Set<String>()

    func vigilar() {
        reloj = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.revisar() }
        RunLoop.main.add(reloj!, forMode: .common)
    }

    private func revisar() {
        guard Self.encendido, Calendario.encendido, Calendario.conPermiso,
              let evento = Calendario.reunionAhora(), evento.app != nil else { return }
        let falta = evento.inicio.timeIntervalSinceNow
        guard falta <= Self.antes, falta >= -Self.despues else { return }
        let clave = "\(evento.titulo)|\(Int(evento.inicio.timeIntervalSince1970))"
        guard avisadas.insert(clave).inserted else { return }
        alAvisar(evento)
    }
}
