import AppKit

/// Barra flotante abajo al centro de la pantalla mientras graba o dicta:
/// punto que parpadea, qué está haciendo, el tiempo y un botón para detener.
/// No le quita el foco a la app donde estás escribiendo (panel "no activante").
final class Indicador {
    enum Modo {
        case reunion, dictado, escribiendo

        var color: NSColor { self == .reunion ? .systemRed : .systemOrange }
        var texto: String {
            switch self {
            case .reunion: return "Grabando reunión"
            case .dictado: return "Dictando"
            case .escribiendo: return "Escribiendo…"
            }
        }
        var atajo: String { self == .reunion ? "⌃⌥R" : "⌃⌥D" }
    }

    var alDetener: ((Modo) -> Void)?

    private var panel: NSPanel?
    private let punto = NSView()
    private let etiqueta = NSTextField(labelWithString: "")
    private let boton = NSButton(title: "Detener", target: nil, action: nil)
    private var modo: Modo = .reunion
    private var desde = Date()

    func mostrar(_ modo: Modo, desde: Date = Date()) {
        self.modo = modo
        self.desde = desde
        let panel = self.panel ?? armar()
        punto.layer?.backgroundColor = modo.color.cgColor
        boton.isHidden = modo == .escribiendo
        boton.title = "Detener  \(modo.atajo)"
        actualizar()
        ubicar(panel)
        panel.orderFrontRegardless()
    }

    func actualizar() {
        guard panel?.isVisible == true || panel != nil else { return }
        if modo == .escribiendo {
            etiqueta.stringValue = modo.texto
        } else {
            let s = Int(Date().timeIntervalSince(desde))
            let tiempo = s >= 3600
                ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                : String(format: "%02d:%02d", s / 60, s % 60)
            etiqueta.stringValue = "\(modo.texto) · \(tiempo)"
        }
    }

    func ocultar() {
        panel?.orderOut(nil)
    }

    @objc private func detener() {
        alDetener?(modo)
    }

    private func armar() -> NSPanel {
        let ancho: CGFloat = 370, alto: CGFloat = 46
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: ancho, height: alto),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true

        let fondo = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: ancho, height: alto))
        fondo.material = .hudWindow
        fondo.state = .active
        fondo.appearance = NSAppearance(named: .darkAqua)
        fondo.wantsLayer = true
        fondo.layer?.cornerRadius = alto / 2
        fondo.layer?.masksToBounds = true
        panel.contentView = fondo

        punto.frame = NSRect(x: 18, y: (alto - 12) / 2, width: 12, height: 12)
        punto.wantsLayer = true
        punto.layer?.cornerRadius = 6
        let latido = CABasicAnimation(keyPath: "opacity")
        latido.fromValue = 1
        latido.toValue = 0.25
        latido.duration = 0.8
        latido.autoreverses = true
        latido.repeatCount = .infinity
        punto.layer?.add(latido, forKey: "latido")
        fondo.addSubview(punto)

        etiqueta.font = .systemFont(ofSize: 14, weight: .semibold)
        etiqueta.textColor = .white
        etiqueta.frame = NSRect(x: 40, y: (alto - 18) / 2, width: 205, height: 18)
        fondo.addSubview(etiqueta)

        boton.target = self
        boton.action = #selector(detener)
        boton.bezelStyle = .rounded
        boton.controlSize = .regular
        boton.frame = NSRect(x: ancho - 122, y: (alto - 28) / 2, width: 110, height: 28)
        fondo.addSubview(boton)

        self.panel = panel
        return panel
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
