import AppKit
import ApplicationServices

/// El texto que tienes seleccionado en la app del frente, para que el asistente trabaje sobre él
/// ("respóndele que sí", "tradúcelo", "hazlo más corto").
enum Seleccion {
    /// Primero pregunta por Accesibilidad (no toca nada); si la app no lo dice (Chrome, apps web, Electron),
    /// copia con ⌘C y devuelve el portapapeles como estaba. Llamar con las teclas ya sueltas.
    static func leer() -> String? {
        if let texto = porAccesibilidad(), !texto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return texto }
        return copiando()
    }

    private static func porAccesibilidad() -> String? {
        let sistema = AXUIElementCreateSystemWide()
        var foco: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sistema, kAXFocusedUIElementAttribute as CFString, &foco) == .success,
              let foco, CFGetTypeID(foco) == AXUIElementGetTypeID() else { return nil }
        var seleccion: CFTypeRef?
        guard AXUIElementCopyAttributeValue(foco as! AXUIElement, kAXSelectedTextAttribute as CFString, &seleccion) == .success
        else { return nil }
        return seleccion as? String
    }

    /// ⌘C simulado: si cambia el portapapeles, eso estaba seleccionado. Después lo deja como estaba.
    private static func copiando() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let portapapeles = NSPasteboard.general
        let antes = portapapeles.changeCount
        let guardado = portapapeles.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
        } ?? []
        let fuente = CGEventSource(stateID: .combinedSessionState)
        for abajo in [true, false] {
            let evento = CGEvent(keyboardEventSource: fuente, virtualKey: 8, keyDown: abajo)   // tecla C
            evento?.flags = .maskCommand
            evento?.post(tap: .cghidEventTap)
        }
        // La app tarda un momento en copiar.
        let limite = Date().addingTimeInterval(0.35)
        while portapapeles.changeCount == antes && Date() < limite { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        guard portapapeles.changeCount != antes else { return nil }
        let texto = portapapeles.string(forType: .string)
        portapapeles.clearContents()
        let items = guardado.map { tipos -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (tipo, datos) in tipos { item.setData(datos, forType: tipo) }
            return item
        }
        if !items.isEmpty { portapapeles.writeObjects(items) }
        return texto
    }
}

/// El asistente (mantener ⌃⌥⌘): se prende y apaga en Ajustes.
enum Asistente {
    static var encendido: Bool {
        get { UserDefaults.standard.object(forKey: "asistenteEncendido") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "asistenteEncendido") }
    }
}
