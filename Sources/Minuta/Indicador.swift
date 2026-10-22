import AppKit

/// Barra flotante abajo al centro de la pantalla mientras graba o dicta:
/// barritas que se mueven con el volumen de tu micrófono, qué está haciendo, el tiempo y botones con íconos
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
        var atajo: String { self == .reunion ? Atajos.reunion.texto : Atajos.dictado.texto }
    }

    var alDetener: ((Modo) -> Void)?
    var alPausar: (() -> Void)?
    var alDescartar: ((Modo) -> Void)?
    /// Volumen del micrófono (0 a 1) para el modo que se ve; se pregunta ~20 veces por segundo.
    var nivel: ((Modo) -> Float)?

    private static let alto: CGFloat = 36
    private static let lado: CGFloat = 26   // cada botón es un círculo de este tamaño

    private var panel: NSPanel?
    private var fondo: NSVisualEffectView?
    private let ondas = Ondas()
    private var cuadros: Timer?
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
        ondas.color = enPausa ? .systemGray : modo.color
        animar()

        pausa.isHidden = modo != .reunion
        detenerBoton.isHidden = modo == .escribiendo
        descartar.isHidden = modo == .escribiendo
        pausa.image = Indicador.simbolo(enPausa ? "play.fill" : "pause.fill")
        pausa.toolTip = enPausa ? "Seguir grabando" : "Pausar"
        detenerBoton.toolTip = modo == .reunion ? "Detener y resumir (\(modo.atajo))" : "Terminar y escribir (Espacio o \(modo.atajo))"
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
        cuadros?.invalidate()
        cuadros = nil
        panel?.orderOut(nil)
    }

    /// Mueve las barritas: con tu voz al grabar o dictar, planas en pausa, una ola suave mientras escribe.
    private func animar() {
        guard cuadros == nil else { return }
        let reloj = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.modo == .escribiendo {
                self.ondas.esperar()
            } else {
                self.ondas.mostrar(self.pausadoDesde == nil ? self.nivel?(self.modo) ?? 0 : 0)
            }
        }
        RunLoop.main.add(reloj, forMode: .common)   // .common: sigue moviéndose con el menú abierto
        cuadros = reloj
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

        ondas.frame = NSRect(x: 13, y: (alto - 16) / 2, width: Ondas.ancho, height: 16)
        fondo.addSubview(ondas)

        etiqueta.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        etiqueta.textColor = .white
        fondo.addSubview(etiqueta)
        for b in [pausa, detenerBoton, descartar] { fondo.addSubview(b) }

        self.panel = panel
        return panel
    }

    /// El ancho depende de cuántos botones se ven (reunión 3, dictado 2, escribiendo ninguno).
    private func acomodar(_ panel: NSPanel) {
        let alto = Indicador.alto, lado = Indicador.lado
        let visibles = [pausa, detenerBoton, descartar].filter { !$0.isHidden }
        // Con botones, ancho fijo para que no baile con el reloj; sin botones, justo el texto.
        let anchoTexto: CGFloat = visibles.isEmpty ? ceil(etiqueta.intrinsicContentSize.width) + 10 : 132
        let izquierda: CGFloat = 13 + Ondas.ancho + 9
        let ancho = izquierda + anchoTexto + CGFloat(visibles.count) * (lado + 4) + 6
        etiqueta.frame = NSRect(x: izquierda, y: (alto - 17) / 2, width: anchoTexto, height: 17)
        var x = izquierda + anchoTexto
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

/// Volumen en decibeles → 0 a 1. Una voz normal al micrófono anda entre −35 y −15 dB; bajo −55 es silencio.
func nivelDeVoz(decibeles: Float) -> Float {
    min(1, max(0, (decibeles + 55) / 40))
}

/// Cinco barritas tipo ecualizador. Suben rápido cuando hablas y bajan suave, para que se vea vivo y no nervioso.
final class Ondas: NSView {
    static let ancho: CGFloat = 5 * 3 + 4 * 2.5

    var color: NSColor = .systemRed {
        didSet { barras.forEach { $0.backgroundColor = color.cgColor } }
    }

    private static let pesos: [CGFloat] = [0.5, 0.8, 1, 0.75, 0.55]   // las del medio, más altas
    private var barras: [CALayer] = []
    private var suave: CGFloat = 0
    private var fase: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in Ondas.pesos {
            let barra = CALayer()
            barra.cornerRadius = 1.5
            barra.backgroundColor = color.cgColor
            layer?.addSublayer(barra)
            barras.append(barra)
        }
        dibujar { _ in 0 }
    }

    required init?(coder: NSCoder) { fatalError("no se usa") }

    /// `nivel` de 0 a 1. En silencio quedan casi planas: así se nota si el micrófono no está captando.
    func mostrar(_ nivel: Float) {
        let objetivo = CGFloat(nivel)
        suave = objetivo > suave ? objetivo : suave * 0.8 + objetivo * 0.2
        dibujar { i in self.suave * Ondas.pesos[i] * CGFloat.random(in: 0.7...1.15) }
    }

    /// Mientras Whisper transcribe: una ola que recorre las barritas.
    func esperar() {
        fase += 0.35
        dibujar { i in 0.25 + 0.3 * (1 + sin(self.fase - CGFloat(i) * 0.9)) }
    }

    private func dibujar(_ altura: (Int) -> CGFloat) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        for (i, barra) in barras.enumerated() {
            let alto = max(3, bounds.height * min(1, altura(i)))
            barra.frame = CGRect(x: CGFloat(i) * 5.5, y: (bounds.height - alto) / 2, width: 3, height: alto)
        }
        CATransaction.commit()
    }
}
