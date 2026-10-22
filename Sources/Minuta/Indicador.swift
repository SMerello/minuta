import AppKit

/// Barra flotante abajo al centro de la pantalla mientras graba o dicta:
/// punto que parpadea, qué está haciendo, el tiempo y botones con íconos
/// (pausa solo en reuniones, detener y descartar).
/// No le quita el foco a la app donde estás escribiendo (panel "no activante").
final class Indicador {
    enum Modo {
        case reunion, dictado, escribiendo

        var color: NSColor { self == .reunion ? .systemRed : .systemOrange }
        var texto: String {
            switch self {
            case .reunion: return "Grabando"
            case .dictado: return "Dictando"
            case .escribiendo: return "Escribiendo…"
            }
        }
        var atajo: String { self == .reunion ? "⌃⌥R" : "⌃⌥D" }
    }

    var alDetener: ((Modo) -> Void)?
    var alPausar: (() -> Void)?
    var alDescartar: ((Modo) -> Void)?

    private static let alto: CGFloat = 36
    private static let lado: CGFloat = 26   // cada botón es un círculo de este tamaño

    private var panel: NSPanel?
    private var fondo: NSVisualEffectView?
    private let punto = NSView()
    private let etiqueta = NSTextField(labelWithString: "")
    private lazy var pausa = Indicador.boton("pause.fill", self, #selector(pausar))
    private lazy var detenerBoton = Indicador.boton("stop.fill", self, #selector(detener))
    private lazy var descartar = Indicador.boton("xmark", self, #selector(descartarTodo))
    private var modo: Modo = .reunion
    private var desde = Date()
    private var pausadoDesde: Date?

    /// `desde` es la hora en que empezó, ya corrida por el tiempo que estuvo en pausa.
    func mostrar(_ modo: Modo, desde: Date = Date(), pausadoDesde: Date? = nil) {
        self.modo = modo
        self.desde = desde
        self.pausadoDesde = pausadoDesde
        let panel = self.panel ?? armar()
        let enPausa = pausadoDesde != nil
        punto.layer?.backgroundColor = (enPausa ? NSColor.systemGray : modo.color).cgColor
        punto.layer?.opacity = 1
        if enPausa { punto.layer?.removeAnimation(forKey: "latido") } else { latir() }

        pausa.isHidden = modo != .reunion
        detenerBoton.isHidden = modo == .escribiendo
        descartar.isHidden = modo == .escribiendo
        pausa.image = Indicador.simbolo(enPausa ? "play.fill" : "pause.fill")
        pausa.toolTip = enPausa ? "Seguir grabando" : "Pausar"
        detenerBoton.toolTip = modo == .reunion ? "Detener y resumir (\(modo.atajo))" : "Terminar y escribir (\(modo.atajo))"
        descartar.toolTip = modo == .reunion ? "Descartar la grabación" : "Descartar el dictado"
        actualizar()
        // Si ya se ve (pausa, o pasa de dictando a escribiendo), queda donde la dejaste, con el mismo centro.
        let centro = panel.isVisible ? panel.frame.midX : nil
        acomodar(panel)
        if let centro {
            panel.setFrameOrigin(NSPoint(x: centro - panel.frame.width / 2, y: panel.frame.minY))
        } else {
            ubicar(panel)
        }
        panel.orderFrontRegardless()
    }

    func actualizar() {
        guard panel != nil else { return }
        if modo == .escribiendo {
            etiqueta.stringValue = modo.texto
            return
        }
        let s = Int((pausadoDesde ?? Date()).timeIntervalSince(desde))
        let tiempo = s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
        etiqueta.stringValue = "\(pausadoDesde != nil ? "En pausa" : modo.texto) · \(tiempo)"
    }

    func ocultar() {
        panel?.orderOut(nil)
    }

    @objc private func detener() { alDetener?(modo) }
    @objc private func pausar() { alPausar?() }
    @objc private func descartarTodo() { alDescartar?(modo) }

    private func armar() -> NSPanel {
        let alto = Indicador.alto
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: alto),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true

        let fondo = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 200, height: alto))
        fondo.material = .hudWindow
        fondo.state = .active
        fondo.appearance = NSAppearance(named: .darkAqua)
        fondo.wantsLayer = true
        fondo.layer?.cornerRadius = alto / 2
        fondo.layer?.masksToBounds = true
        panel.contentView = fondo
        self.fondo = fondo

        punto.frame = NSRect(x: 14, y: (alto - 10) / 2, width: 10, height: 10)
        punto.wantsLayer = true
        punto.layer?.cornerRadius = 5
        fondo.addSubview(punto)

        etiqueta.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        etiqueta.textColor = .white
        fondo.addSubview(etiqueta)
        for b in [pausa, detenerBoton, descartar] { fondo.addSubview(b) }

        self.panel = panel
        return panel
    }

    private func latir() {
        guard punto.layer?.animation(forKey: "latido") == nil else { return }
        let latido = CABasicAnimation(keyPath: "opacity")
        latido.fromValue = 1
        latido.toValue = 0.25
        latido.duration = 0.8
        latido.autoreverses = true
        latido.repeatCount = .infinity
        punto.layer?.add(latido, forKey: "latido")
    }

    /// El ancho depende de cuántos botones se ven (reunión 3, dictado 2, escribiendo ninguno).
    private func acomodar(_ panel: NSPanel) {
        let alto = Indicador.alto, lado = Indicador.lado
        let visibles = [pausa, detenerBoton, descartar].filter { !$0.isHidden }
        // Con botones, ancho fijo para que no baile con el reloj; sin botones, justo el texto.
        let anchoTexto: CGFloat = visibles.isEmpty ? ceil(etiqueta.intrinsicContentSize.width) + 10 : 132
        let ancho = 32 + anchoTexto + CGFloat(visibles.count) * (lado + 4) + 6
        etiqueta.frame = NSRect(x: 32, y: (alto - 17) / 2, width: anchoTexto, height: 17)
        var x = 32 + anchoTexto
        for b in visibles {
            b.frame = NSRect(x: x, y: (alto - lado) / 2, width: lado, height: lado)
            x += lado + 4
        }
        panel.setContentSize(NSSize(width: ancho, height: alto))
        fondo?.frame = NSRect(x: 0, y: 0, width: ancho, height: alto)
    }

    private static func boton(_ simbolo: String, _ destino: AnyObject, _ accion: Selector) -> NSButton {
        let b = NSButton(image: Indicador.simbolo(simbolo) ?? NSImage(), target: destino, action: accion)
        b.isBordered = false
        b.contentTintColor = .white
        b.wantsLayer = true
        b.layer?.cornerRadius = lado / 2
        b.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        return b
    }

    private static func simbolo(_ nombre: String) -> NSImage? {
        NSImage(systemSymbolName: nombre, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
    }

    /// Abajo al centro de la pantalla donde está el mouse, sobre el Dock.
    private func ubicar(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let pantalla = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let zona = pantalla?.visibleFrame else { return }
        let tam = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: zona.midX - tam.width / 2, y: zona.minY + 28))
    }
}
