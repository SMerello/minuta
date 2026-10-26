import AppKit
import CoreAudio

/// Se da cuenta de cuándo empieza y termina una llamada: mira qué apps están usando el micrófono
/// (Zoom, Teams, Meet en el navegador, WhatsApp, FaceTime…). No graba nada: solo avisa, y la app
/// ofrece grabar o detener. Mira cada 2 s; no necesita permisos.
final class Llamadas {
    /// Empezó una llamada en esta app (nombre para mostrar).
    var alEmpezar: (String) -> Void = { _ in }
    /// Ninguna app de llamadas usa el micrófono hace un rato.
    var alTerminar: () -> Void = {}

    var encendido: Bool {
        get { UserDefaults.standard.object(forKey: "ofrecerGrabarLlamadas") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ofrecerGrabarLlamadas") }
    }

    /// Prefijo del identificador de la app → nombre. Los navegadores cuentan porque Meet va en el navegador.
    private static let apps: [(String, String)] = [
        ("us.zoom", "Zoom"), ("com.microsoft.teams", "Teams"), ("net.whatsapp", "WhatsApp"),
        ("com.apple.FaceTime", "FaceTime"), ("com.tinyspeck.slackmacgap", "Slack"), ("com.hnc.Discord", "Discord"),
        ("com.cisco", "Webex"), ("Cisco-Systems.Spark", "Webex"),
        ("com.google.Chrome", "Chrome"), ("com.apple.Safari", "Safari"), ("com.apple.WebKit.GPU", "Safari"),
        ("company.thebrowser", "Arc"), ("com.brave.Browser", "Brave"), ("com.microsoft.edgemac", "Edge"),
        ("org.mozilla.firefox", "Firefox"), ("com.operasoftware", "Opera"),
    ]
    /// Una llamada se da por terminada si nadie usa el micrófono durante este rato (evita cortes por un mute).
    private static let silencioParaTerminar: TimeInterval = 15

    /// La app de la llamada en curso ("Google Meet", "Zoom"…), o nil si no hay llamada.
    private(set) var appActual: String?

    private static let navegadores: Set<String> = ["Chrome", "Safari", "Arc", "Brave", "Edge", "Firefox", "Opera"]

    private var reloj: Timer?
    private var enLlamada = false
    private var sinLlamadaDesde: Date?

    func vigilar() {
        reloj = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.revisar() }
    }

    /// Mira siempre (para saber de qué app es cada reunión), pero solo ofrece grabar si está encendido.
    private func revisar() {
        let nombres = Self.appsConMicrofono()
        if let primera = nombres.first {
            appActual = Self.navegadores.contains(primera) ? Self.llamadaEnNavegador() ?? primera : primera
            sinLlamadaDesde = nil
            if !enLlamada {
                enLlamada = true
                if encendido { alEmpezar(appActual ?? primera) }
            }
        } else if enLlamada {
            let desde = sinLlamadaDesde ?? Date()
            sinLlamadaDesde = desde
            if Date().timeIntervalSince(desde) >= Self.silencioParaTerminar {
                enLlamada = false
                appActual = nil
                sinLlamadaDesde = nil
                if encendido { alTerminar() }
            }
        }
    }

    /// Si la llamada es en el navegador, el título de la ventana dice cuál es ("Meet - abc-defg-hij").
    /// Leer títulos de ventanas usa el permiso de Grabación de pantalla, que Minuta ya tiene para grabar.
    private static func llamadaEnNavegador() -> String? {
        guard let ventanas = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        let titulos = ventanas.compactMap { $0[kCGWindowName as String] as? String }
        let conocidas = [("Meet", "Google Meet"), ("Teams", "Teams"), ("Zoom", "Zoom"), ("WhatsApp", "WhatsApp"),
                         ("Webex", "Webex"), ("Slack", "Slack")]
        return conocidas.first { nombre in titulos.contains { $0.contains(nombre.0) } }?.1
    }

    /// Las apps de llamadas que tienen el micrófono abierto ahora (CoreAudio, macOS 14+).
    private static func appsConMicrofono() -> [String] {
        let sistema = AudioObjectID(kAudioObjectSystemObject)
        var direccion = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var tamano: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sistema, &direccion, 0, nil, &tamano) == noErr, tamano > 0 else { return [] }
        var procesos = [AudioObjectID](repeating: 0, count: Int(tamano) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sistema, &direccion, 0, nil, &tamano, &procesos) == noErr else { return [] }
        let propio = Bundle.main.bundleIdentifier ?? "ai.caravana.minuta"
        return procesos.compactMap { proceso in
            var usaMicrofono: UInt32 = 0
            var t = UInt32(MemoryLayout<UInt32>.size)
            var d = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(proceso, &d, 0, nil, &t, &usaMicrofono) == noErr, usaMicrofono != 0 else { return nil }
            d.mSelector = kAudioProcessPropertyBundleID
            var identificador: Unmanaged<CFString>?
            t = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(proceso, &d, 0, nil, &t, &identificador) == noErr,
                  let id = identificador?.takeRetainedValue() as String?, !id.hasPrefix(propio) else { return nil }
            return apps.first { id.hasPrefix($0.0) }?.1
        }
    }
}

/// El micrófono que está usando el Mac ahora (el de "Entrada" en Ajustes del Sistema › Sonido).
enum Microfono {
    static func nombre() -> String? {
        let sistema = AudioObjectID(kAudioObjectSystemObject)
        var direccion = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var dispositivo = AudioDeviceID(0)
        var t = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sistema, &direccion, 0, nil, &t, &dispositivo) == noErr, dispositivo != 0 else { return nil }
        direccion.mSelector = kAudioObjectPropertyName
        var nombre: Unmanaged<CFString>?
        t = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dispositivo, &direccion, 0, nil, &t, &nombre) == noErr else { return nil }
        return nombre?.takeRetainedValue() as String?
    }
}

/// Cartelito abajo en la pantalla con una pregunta y un botón ("¿Grabo esta llamada? · Grabar").
/// Igual que la barra de grabación, no le quita el foco a la app donde estás. Se esconde solo.
final class Oferta {
    private var panel: NSPanel?
    private let etiqueta = NSTextField(labelWithString: "")
    private let boton = NSButton(title: "", target: nil, action: nil)
    private let cerrar = NSButton(title: "", target: nil, action: nil)
    private var accion: (() -> Void)?
    private var esconder: DispatchWorkItem?

    func mostrar(_ texto: String, boton titulo: String, durante segundos: TimeInterval, accion: @escaping () -> Void) {
        self.accion = accion
        // Si estaba escondida, se arma de nuevo: una ventana escondida queda amarrada al escritorio donde se
        // mostró la última vez, y al volver a mostrarla podía aparecer allá (por ejemplo, con la Terminal
        // en pantalla completa en otro escritorio) en vez de donde estás.
        if let viejo = self.panel, !viejo.isVisible {
            viejo.contentView = nil   // suelta las piezas (barritas, texto, botones) para la ventana nueva
            self.panel = nil
        }
        let panel = self.panel ?? armar()
        etiqueta.stringValue = texto
        boton.attributedTitle = NSAttributedString(string: titulo, attributes: [
            .foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        etiqueta.sizeToFit()
        boton.sizeToFit()
        let alto: CGFloat = 40
        let anchoBoton = boton.frame.width + 16
        let ancho = 18 + etiqueta.frame.width + 12 + anchoBoton + 8 + 24 + 10
        etiqueta.frame.origin = NSPoint(x: 18, y: (alto - etiqueta.frame.height) / 2)
        boton.frame = NSRect(x: 18 + etiqueta.frame.width + 12, y: (alto - 26) / 2, width: anchoBoton, height: 26)
        cerrar.frame = NSRect(x: ancho - 34, y: (alto - 24) / 2, width: 24, height: 24)
        panel.setContentSize(NSSize(width: ancho, height: alto))
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: ancho, height: alto)
        // Un poco más arriba que la barra de grabación, para que no se tapen.
        let mouse = NSEvent.mouseLocation
        if let zona = (NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: zona.midX - ancho / 2, y: zona.minY + 76))
        }
        panel.orderFrontRegardless()
        esconder?.cancel()
        let tarea = DispatchWorkItem { [weak self] in self?.ocultar() }
        esconder = tarea
        DispatchQueue.main.asyncAfter(deadline: .now() + segundos, execute: tarea)
    }

    func ocultar() {
        esconder?.cancel()
        panel?.orderOut(nil)
    }

    @objc private func aceptar() {
        ocultar()
        accion?()
    }

    @objc private func descartar() { ocultar() }

    private func armar() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let fondo = NSVisualEffectView()
        fondo.material = .hudWindow
        fondo.state = .active
        fondo.appearance = NSAppearance(named: .darkAqua)
        fondo.wantsLayer = true
        fondo.layer?.cornerRadius = 20
        fondo.layer?.masksToBounds = true
        panel.contentView = fondo

        etiqueta.font = .systemFont(ofSize: 13, weight: .semibold)
        etiqueta.textColor = .white
        boton.target = self
        boton.action = #selector(aceptar)
        boton.isBordered = false
        boton.wantsLayer = true
        boton.layer?.backgroundColor = NSColor.systemRed.cgColor
        boton.layer?.cornerRadius = 13
        cerrar.target = self
        cerrar.action = #selector(descartar)
        cerrar.isBordered = false
        cerrar.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cerrar")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        cerrar.contentTintColor = .white
        for v in [etiqueta, boton, cerrar] { fondo.addSubview(v) }
        self.panel = panel
        return panel
    }
}
