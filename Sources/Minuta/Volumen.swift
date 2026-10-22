import CoreAudio
import Foundation

/// Mientras dictas, baja el volumen del Mac (música, videos) y al terminar lo deja como estaba.
/// Así escuchas que está grabando y el micrófono no capta la música. Solo en el dictado: en una
/// reunión hay que escuchar la llamada. Usa el volumen de la salida de sonido actual (parlantes,
/// audífonos o AirPods); si esa salida no deja cambiar el volumen (algunas pantallas HDMI), no hace nada.
enum Volumen {
    /// Bajar el volumen al dictar (se cambia en Ajustes).
    static var encendido: Bool {
        get { UserDefaults.standard.object(forKey: "bajarVolumen") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "bajarVolumen") }
    }

    /// Cuánto queda del volumen mientras dictas.
    private static let fraccion: Float32 = 0.25

    /// El dispositivo y su volumen antes de bajarlo, para devolverlo igual.
    private static var guardado: (dispositivo: AudioDeviceID, elementos: [(UInt32, Float32)])?

    static func bajar() {
        guard encendido, guardado == nil, let dispositivo = salida() else { return }
        let elementos = elementosConVolumen(dispositivo)
        let antes = elementos.compactMap { e in leer(dispositivo, e).map { (e, $0) } }
        // Si ya está casi en silencio, no hay nada que bajar.
        guard let mayor = antes.map(\.1).max(), mayor > 0.05 else { return }
        guardado = (dispositivo, antes)
        for (e, v) in antes { escribir(dispositivo, e, v * fraccion) }
    }

    static func devolver() {
        guard let guardado else { return }
        self.guardado = nil
        for (e, v) in guardado.elementos { escribir(guardado.dispositivo, e, v) }
    }

    // MARK: CoreAudio

    private static func salida() -> AudioDeviceID? {
        var direccion = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var dispositivo = AudioDeviceID(0)
        var t = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &direccion, 0, nil, &t, &dispositivo) == noErr,
              dispositivo != 0 else { return nil }
        return dispositivo
    }

    /// El volumen general (elemento 0) o, si la salida no tiene, el de cada canal (izquierdo y derecho).
    private static func elementosConVolumen(_ dispositivo: AudioDeviceID) -> [UInt32] {
        if sePuedeCambiar(dispositivo, kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return [1, 2].filter { sePuedeCambiar(dispositivo, $0) }
    }

    private static func direccion(_ elemento: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: elemento)
    }

    private static func sePuedeCambiar(_ dispositivo: AudioDeviceID, _ elemento: UInt32) -> Bool {
        var d = direccion(elemento)
        var sePuede: DarwinBoolean = false
        return AudioObjectHasProperty(dispositivo, &d)
            && AudioObjectIsPropertySettable(dispositivo, &d, &sePuede) == noErr && sePuede.boolValue
    }

    private static func leer(_ dispositivo: AudioDeviceID, _ elemento: UInt32) -> Float32? {
        var d = direccion(elemento)
        var valor: Float32 = 0
        var t = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dispositivo, &d, 0, nil, &t, &valor) == noErr ? valor : nil
    }

    private static func escribir(_ dispositivo: AudioDeviceID, _ elemento: UInt32, _ valor: Float32) {
        var d = direccion(elemento)
        var v = min(max(valor, 0), 1)
        AudioObjectSetPropertyData(dispositivo, &d, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }
}
