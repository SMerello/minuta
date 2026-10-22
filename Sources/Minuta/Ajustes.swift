import AppKit
import Carbon.HIToolbox

/// Ventana "Ajustes de Minuta": para elegir los atajos de Grabar reunión y Dictar.
/// Al hacer clic en un atajo, la siguiente combinación que aprietes pasa a ser la nueva (Esc cancela).
final class Ajustes: NSObject, NSWindowDelegate {
    /// Suelta los atajos globales: mientras capturo uno nuevo, apretar el actual no debe grabar ni dictar.
    var alSoltarAtajos: () -> Void = {}
    /// Vuelve a registrar los atajos que hay en `Atajos` y dice cuáles aceptó macOS.
    var alRegistrarAtajos: () -> (reunion: Bool, dictado: Bool) = { (true, true) }

    private enum Accion {
        case reunion, dictado
        var nombre: String { self == .reunion ? "Grabar reunión" : "Dictar" }
    }

    private var ventana: NSWindow?
    private let botonReunion = NSButton(title: "", target: nil, action: nil)
    private let botonDictado = NSButton(title: "", target: nil, action: nil)
    private let aviso = NSTextField(wrappingLabelWithString: "")
    private var capturando: Accion?
    private var monitor: Any?

    func mostrar() {
        if ventana == nil { ventana = armarVentana() }
        actualizarBotones()
        avisar("")
        ventana?.center()
        NSApp.activate(ignoringOtherApps: true)   // la app es .accessory: sin esto la ventana queda detrás
        ventana?.makeKeyAndOrderFront(nil)
    }

    private func armarVentana() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Ajustes de Minuta"
        w.isReleasedWhenClosed = false
        w.delegate = self

        for (boton, selector) in [(botonReunion, #selector(cambiarReunion)), (botonDictado, #selector(cambiarDictado))] {
            boton.bezelStyle = .rounded
            boton.target = self
            boton.action = selector
            boton.widthAnchor.constraint(equalToConstant: 190).isActive = true
        }
        let grilla = NSGridView(views: [
            [NSTextField(labelWithString: "Grabar reunión"), botonReunion],
            [NSTextField(labelWithString: "Dictar"), botonDictado],
        ])
        grilla.rowSpacing = 10
        grilla.columnSpacing = 12
        grilla.column(at: 0).xPlacement = .trailing
        grilla.rowAlignment = .firstBaseline

        aviso.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        aviso.alignment = .center
        aviso.preferredMaxLayoutWidth = 340
        aviso.widthAnchor.constraint(equalToConstant: 340).isActive = true
        // Espacio fijo para dos líneas, así la ventana no salta de alto cuando aparece un aviso.
        aviso.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true

        let restaurar = NSButton(title: "Volver a los de siempre", target: self, action: #selector(volverALosDeSiempre))
        restaurar.bezelStyle = .rounded

        let pila = NSStackView(views: [grilla, aviso, restaurar])
        pila.orientation = .vertical
        pila.alignment = .centerX
        pila.spacing = 14
        pila.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        pila.translatesAutoresizingMaskIntoConstraints = false
        let contenido = NSView()
        contenido.addSubview(pila)
        NSLayoutConstraint.activate([
            pila.leadingAnchor.constraint(equalTo: contenido.leadingAnchor),
            pila.trailingAnchor.constraint(equalTo: contenido.trailingAnchor),
            pila.topAnchor.constraint(equalTo: contenido.topAnchor),
            pila.bottomAnchor.constraint(equalTo: contenido.bottomAnchor),
        ])
        w.contentView = contenido
        w.setContentSize(contenido.fittingSize)
        return w
    }

    private func actualizarBotones() {
        botonReunion.title = capturando == .reunion ? "Aprieta la combinación…" : Atajos.reunion.texto
        botonDictado.title = capturando == .dictado ? "Aprieta la combinación…" : Atajos.dictado.texto
    }

    private func avisar(_ texto: String, error: Bool = false) {
        aviso.stringValue = texto
        aviso.textColor = error ? .systemRed : .secondaryLabelColor
    }

    // MARK: Capturar

    @objc private func cambiarReunion() { alternarCaptura(.reunion) }
    @objc private func cambiarDictado() { alternarCaptura(.dictado) }

    /// Clic en un atajo: empieza a capturar. Otro clic en el mismo, o Esc, cancela.
    private func alternarCaptura(_ accion: Accion) {
        let estaba = capturando
        if estaba != nil { cancelarCaptura() }
        guard estaba != accion else { return }
        alSoltarAtajos()
        capturando = accion
        actualizarBotones()
        avisar("Esc para cancelar.")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] evento in
            guard let self, self.capturando != nil else { return evento }
            self.teclaApretada(evento)
            return nil   // me la quedo: que no la reciba el botón ni la ventana
        }
    }

    private func teclaApretada(_ evento: NSEvent) {
        guard let accion = capturando else { return }
        let nueva = Combinacion(evento: evento)
        if nueva.tecla == kVK_Escape && nueva.modificadores == 0 {
            cancelarCaptura()
            avisar("")
            return
        }
        // Si no sirve, sigo esperando otra combinación.
        guard nueva.sirveComoAtajo else {
            avisar("Usa al menos ⌃, ⌥ o ⌘ (solo ⇧ no basta). Las teclas F1 a F20 pueden ir solas.", error: true)
            return
        }
        let otra = accion == .reunion ? Atajos.dictado : Atajos.reunion
        guard nueva != otra else {
            avisar("\(nueva.texto) ya es el atajo de \(accion == .reunion ? Accion.dictado.nombre : Accion.reunion.nombre).", error: true)
            return
        }
        terminarCaptura()
        if accion == .reunion {
            aplicar(reunion: nueva, dictado: Atajos.dictado)
        } else {
            aplicar(reunion: Atajos.reunion, dictado: nueva)
        }
    }

    private func terminarCaptura() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        capturando = nil
        actualizarBotones()
    }

    /// Deja todo como estaba antes del clic y vuelve a registrar los atajos de siempre del usuario.
    private func cancelarCaptura() {
        guard capturando != nil else { return }
        terminarCaptura()
        _ = alRegistrarAtajos()
    }

    @objc private func volverALosDeSiempre() {
        cancelarCaptura()
        aplicar(reunion: Atajos.reunionDeSiempre, dictado: Atajos.dictadoDeSiempre)
    }

    /// Guarda y registra los atajos. Si macOS rechaza uno nuevo (lo usa otra app o el sistema), vuelve al anterior.
    private func aplicar(reunion: Combinacion, dictado: Combinacion) {
        let antes = (reunion: Atajos.reunion, dictado: Atajos.dictado)
        Atajos.reunion = reunion
        Atajos.dictado = dictado
        var resultado = alRegistrarAtajos()
        var rechazados: [String] = []
        if !resultado.reunion && reunion != antes.reunion {
            rechazados.append(reunion.texto)
            Atajos.reunion = antes.reunion
        }
        if !resultado.dictado && dictado != antes.dictado {
            rechazados.append(dictado.texto)
            Atajos.dictado = antes.dictado
        }
        if !rechazados.isEmpty { resultado = alRegistrarAtajos() }
        actualizarBotones()

        if !rechazados.isEmpty {
            let cual = rechazados.joined(separator: " y ")
            avisar(rechazados.count == 1 ? "Esa combinación (\(cual)) la usa otra app o el sistema. Elige otra."
                                         : "Esas combinaciones (\(cual)) las usa otra app o el sistema.", error: true)
        } else if !resultado.reunion || !resultado.dictado {
            // El que no cambió tampoco quedó: estaba tomado desde antes.
            let tomado = !resultado.reunion ? Atajos.reunion.texto : Atajos.dictado.texto
            avisar("\(tomado) no funciona: lo usa otra app o el sistema. Elige otro.", error: true)
        } else {
            avisar("Listo: \(Atajos.reunion.texto) graba y \(Atajos.dictado.texto) dicta.")
        }
    }

    // MARK: NSWindowDelegate

    // Si cierras la ventana o te vas a otra app a mitad de captura, los atajos no pueden quedar sueltos.
    func windowWillClose(_ notification: Notification) { cancelarCaptura() }

    func windowDidResignKey(_ notification: Notification) {
        guard capturando != nil else { return }
        cancelarCaptura()
        avisar("")
    }
}
