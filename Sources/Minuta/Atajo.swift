import AppKit
import Carbon.HIToolbox

/// Atajo de teclado global (funciona aunque Minuta no esté al frente y aunque el ícono esté escondido).
/// Usa RegisterEventHotKey de Carbon, que no necesita permiso de Accesibilidad.
final class Atajo {
    private static var siguienteId: UInt32 = 1

    private let id: UInt32
    private var referencia: EventHotKeyRef?
    private var manejador: EventHandlerRef?
    private let accion: () -> Void
    /// Falso si macOS no lo aceptó (casi siempre porque otra app o el sistema ya usa esa combinación).
    private(set) var registrado = false

    /// `tecla` es un kVK_*; los modificadores por defecto son ⌃⌥ (Control + Opción).
    init(tecla: Int, modificadores: Int = controlKey | optionKey, accion: @escaping () -> Void) {
        id = Atajo.siguienteId
        Atajo.siguienteId += 1
        self.accion = accion
        var tipo = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let contexto = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, evento, contexto in
            guard let evento, let contexto else { return OSStatus(eventNotHandledErr) }
            let atajo = Unmanaged<Atajo>.fromOpaque(contexto).takeUnretainedValue()
            var apretado = EventHotKeyID()
            GetEventParameter(evento, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &apretado)
            // Cada atajo tiene su propio manejador: si no es el mío, lo dejo pasar al siguiente.
            guard apretado.id == atajo.id else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { atajo.accion() }
            return noErr
        }, 1, &tipo, contexto, &manejador)
        let hotKeyId = EventHotKeyID(signature: OSType(0x4D4E5441), id: id)   // "MNTA"
        let estado = RegisterEventHotKey(UInt32(tecla), UInt32(modificadores), hotKeyId,
                                         GetApplicationEventTarget(), 0, &referencia)
        registrado = estado == noErr && referencia != nil
    }

    convenience init(_ combinacion: Combinacion, accion: @escaping () -> Void) {
        self.init(tecla: combinacion.tecla, modificadores: combinacion.modificadores, accion: accion)
    }

    deinit {
        if let referencia { UnregisterEventHotKey(referencia) }
        if let manejador { RemoveEventHandler(manejador) }
    }
}

/// Una tecla más sus modificadores, como los entiende RegisterEventHotKey.
struct Combinacion: Codable, Equatable {
    /// kVK_* (la posición física de la tecla, no la letra).
    var tecla: Int
    /// Modificadores de Carbon: controlKey | optionKey | shiftKey | cmdKey.
    var modificadores: Int
    /// La letra que se vio al capturarla; solo se usa si no logro leerla del teclado actual.
    var caracter: String?

    init(tecla: Int, modificadores: Int, caracter: String? = nil) {
        self.tecla = tecla
        self.modificadores = modificadores
        self.caracter = caracter
    }

    /// La que se apretó en una ventana de Minuta (para capturar un atajo nuevo).
    init(evento: NSEvent) {
        let f = evento.modifierFlags
        var m = 0
        if f.contains(.control) { m |= controlKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.shift) { m |= shiftKey }
        if f.contains(.command) { m |= cmdKey }
        self.init(tecla: Int(evento.keyCode), modificadores: m,
                  caracter: evento.charactersIgnoringModifiers?.uppercased())
    }

    // Da lo mismo la letra guardada: dos combinaciones son iguales si son la misma tecla con los mismos modificadores.
    static func == (a: Combinacion, b: Combinacion) -> Bool {
        a.tecla == b.tecla && a.modificadores == b.modificadores
    }

    static let teclasF = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                          kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    var esTeclaF: Bool { Self.teclasF.contains(tecla) }

    /// Un atajo global necesita ⌃, ⌥ o ⌘ (con ⇧ solo te quitaría una letra en todas las apps); las F1–F20 pueden ir solas.
    var sirveComoAtajo: Bool {
        esTeclaF || modificadores & (controlKey | optionKey | cmdKey) != 0
    }

    /// Como lo muestra macOS en los menús: ⌃⌥⇧⌘ y la tecla, p. ej. "⌃⌥R".
    var texto: String {
        var s = ""
        if modificadores & controlKey != 0 { s += "⌃" }
        if modificadores & optionKey != 0 { s += "⌥" }
        if modificadores & shiftKey != 0 { s += "⇧" }
        if modificadores & cmdKey != 0 { s += "⌘" }
        return s + nombreTecla
    }

    /// Para explicarlo con palabras, p. ej. "Control + Opción + R".
    var textoLargo: String {
        var partes: [String] = []
        if modificadores & controlKey != 0 { partes.append("Control") }
        if modificadores & optionKey != 0 { partes.append("Opción") }
        if modificadores & shiftKey != 0 { partes.append("Mayúsculas") }
        if modificadores & cmdKey != 0 { partes.append("Comando") }
        return (partes + [nombreTecla]).joined(separator: " + ")
    }

    var nombreTecla: String {
        if let i = Self.teclasF.firstIndex(of: tecla) { return "F\(i + 1)" }
        switch tecla {
        case kVK_Space: return "Espacio"
        case kVK_Return: return "↩"
        case kVK_ANSI_KeypadEnter: return "⌅"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default: return Self.caracterSegunTeclado(tecla) ?? caracter ?? "Tecla \(tecla)"
        }
    }

    /// La letra que tiene esa tecla en la distribución de teclado que está usando el Mac (español, inglés…).
    private static func caracterSegunTeclado(_ tecla: Int) -> String? {
        guard let fuente = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let puntero = TISGetInputSourceProperty(fuente, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let datos = Unmanaged<CFData>.fromOpaque(puntero).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(datos) else { return nil }
        var teclaMuerta: UInt32 = 0
        var largo = 0
        var caracteres = [UniChar](repeating: 0, count: 4)
        let estado = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { distribucion in
            UCKeyTranslate(distribucion, UInt16(tecla), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysMask), &teclaMuerta, caracteres.count, &largo, &caracteres)
        }
        guard estado == noErr, largo > 0 else { return nil }
        let texto = String(utf16CodeUnits: caracteres, count: largo).trimmingCharacters(in: .whitespacesAndNewlines)
        return texto.isEmpty ? nil : texto.uppercased()
    }
}

/// Los atajos que eligió el usuario en Ajustes (quedan en UserDefaults); si nunca los cambió, ⌃⌥R y ⌃⌥D.
enum Atajos {
    static let reunionDeSiempre = Combinacion(tecla: kVK_ANSI_R, modificadores: controlKey | optionKey)
    static let dictadoDeSiempre = Combinacion(tecla: kVK_ANSI_D, modificadores: controlKey | optionKey)

    static var reunion: Combinacion {
        get { leer("atajoReunion") ?? reunionDeSiempre }
        set { guardar(newValue, "atajoReunion") }
    }

    static var dictado: Combinacion {
        get { leer("atajoDictado") ?? dictadoDeSiempre }
        set { guardar(newValue, "atajoDictado") }
    }

    private static func leer(_ clave: String) -> Combinacion? {
        guard let datos = UserDefaults.standard.data(forKey: clave) else { return nil }
        return try? JSONDecoder().decode(Combinacion.self, from: datos)
    }

    private static func guardar(_ combinacion: Combinacion, _ clave: String) {
        if let datos = try? JSONEncoder().encode(combinacion) {
            UserDefaults.standard.set(datos, forKey: clave)
        }
    }
}
