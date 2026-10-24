import AppKit
import Carbon.HIToolbox

/// Mientras hay un dictado largo, apretar solo Espacio lo termina (en reuniones no hace nada).
/// Ese Espacio no le llega a la app donde estás, para que no se escriba un espacio antes del texto:
/// por eso usa un "event tap", que solo está encendido durante el dictado largo. Necesita Accesibilidad.
final class EspacioTermina {
    var alApretar: () -> Void = {}

    /// Apagado por defecto: así puedes seguir escribiendo (con espacios) mientras dictas algo largo, y el
    /// dictado largo se termina con ⌃⌥Espacio o con Detener. Se prende en Ajustes.
    static var encendido: Bool {
        get { UserDefaults.standard.bool(forKey: "espacioTermina") }
        set { UserDefaults.standard.set(newValue, forKey: "espacioTermina") }
    }

    private var tap: CFMachPort?
    private var comiendo = false   // si me quedé con el Espacio al bajar, también me quedo con el de subir

    var activo = false {
        didSet {
            guard activo != oldValue else { return }
            if activo && tap == nil { crear() }
            if let tap { CGEvent.tapEnable(tap: tap, enable: activo) }
            if !activo { comiendo = false }
        }
    }

    private func crear() {
        let tipos = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let yo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(tipos), callback: { _, tipo, evento, contexto in
            guard let contexto else { return Unmanaged.passUnretained(evento) }
            return Unmanaged<EspacioTermina>.fromOpaque(contexto).takeUnretainedValue().recibir(tipo, evento)
        }, userInfo: yo) else { return }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    }

    func recibir(_ tipo: CGEventType, _ evento: CGEvent) -> Unmanaged<CGEvent>? {
        let sigue = Unmanaged.passUnretained(evento)
        // macOS apaga el tap si una respuesta se demora; si aún hay dictado largo, se vuelve a encender.
        if tipo == .tapDisabledByTimeout || tipo == .tapDisabledByUserInput {
            if activo, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return sigue
        }
        guard activo, evento.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Space) else { return sigue }
        if tipo == .keyUp {
            guard comiendo else { return sigue }
            comiendo = false
            return nil
        }
        // Solo Espacio, sin ⌃⌥⇧⌘ (así ⌃⌥Espacio sigue siendo el atajo) y sin la repetición de tecla sostenida.
        let modificadores = evento.flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand])
        guard tipo == .keyDown, modificadores.isEmpty,
              evento.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return sigue }
        comiendo = true
        DispatchQueue.main.async { [weak self] in self?.alApretar() }
        return nil
    }
}
