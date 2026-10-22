import AppKit
import WebKit

/// Ventana "Minuta", hecha con barra lateral y tarjetas. A la izquierda dos botones, Inicio y Reuniones,
/// y abajo un recuadro con los atajos; a la derecha la página elegida:
/// - Inicio: el saludo, las cifras y TODOS los dictados y reuniones juntos por día (máximo 3 líneas cada uno).
///   Clic en un dictado lo copia; clic en una reunión la abre.
/// - Reuniones: la lista con buscador y el botón para grabar. Clic en una reunión: sus pestañas Notas, Minuta
///   y Transcripción, con los botones Copiar correo, Copiar notas y Abrir carpeta.
/// Todo se dibuja en HTML dentro de un solo WKWebView (así se ve igual de cuidado en claro y oscuro) y los clics
/// llegan acá por `window.webkit.messageHandlers.minuta`. Vuelve a leer las carpetas al abrirse, al volver al
/// frente y cada 5 s mientras se ve: lo que se termina de procesar aparece solo, y si nada cambió no se toca
/// la página (así el scroll no salta).
final class VentanaReuniones: NSObject, NSWindowDelegate, WKNavigationDelegate {
    enum Seccion: String {
        case inicio, reuniones
    }

    /// Las pestañas de Inicio: todo junto, solo dictados o solo reuniones.
    enum Filtro: String {
        case todo, dictados, reuniones
    }

    enum Pestana: String {
        case notas, minuta, transcripcion
        var nombre: String {
            switch self {
            case .notas: return "Notas"
            case .minuta: return "Minuta"
            case .transcripcion: return "Transcripción"
            }
        }
    }

    /// Botón "Grabar reunión" / "Detener y resumir" de la página Reuniones (los conecta main.swift).
    var alGrabar: (() -> Void)?
    var alDetener: (() -> Void)?

    private(set) var ventana: NSWindow?
    let web: WKWebView = {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.underPageBackgroundColor = .textBackgroundColor
        return web
    }()
    private var listo = false                        // ya cargó la página base (antes no se le puede mandar nada)
    private var enviado: [String: String] = [:]      // lo último que mandé a cada parte de la página
    private var vistaEnviada = ""
    private var seccionEnviada = ""
    private var reloj: Timer?

    private var todas: [Reunion] = []
    private var guardadas: [String: Reunion] = [:]   // carpeta → reunión ya leída (se vuelve a leer si cambia algo)
    private var dictados: [DictadoGuardado] = []     // el más nuevo primero
    private var diasDictados: [String: (firma: Date, entradas: [DictadoGuardado])] = [:]   // archivo → lo leído
    private var cuerpoGuardado: (clave: String, html: String)?   // el detalle ya armado (la transcripción larga cuesta)

    private var seccion: Seccion = .inicio
    private var filtro: Filtro = .todo
    private var elegida: String?                     // carpeta de la reunión abierta; nil: se ve la lista
    private var pestana: Pestana = .notas
    private var busqueda = ""
    private var grabando = false

    override init() {
        super.init()
        web.navigationDelegate = self
        web.configuration.userContentController.add(Mensajero(self), name: "minuta")
    }

    /// Abre la ventana (o la trae al frente). Con `carpeta`, abre directo esa reunión.
    func mostrar(seleccionar carpeta: URL? = nil) {
        preparar(seleccionar: carpeta)
        // Mientras la ventana está abierta, Minuta es una app normal: se ve en el Dock y en ⌘Tab.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        ventana?.makeKeyAndOrderFront(nil)
    }

    /// Abre la ventana en Inicio o en Reuniones.
    func mostrar(seccion nueva: Seccion) {
        seccion = nueva
        elegida = nil
        mostrar()
    }

    /// Arma la ventana y la deja al día, sin mostrarla ni activar la app (también lo usan las capturas de prueba).
    func preparar(seleccionar carpeta: URL? = nil) {
        let w = ventana ?? armarVentana()
        ventana = w
        if let carpeta {
            seccion = .reuniones
            elegida = carpeta.resolvingSymlinksInPath().path
            pestana = .notas
        }
        recargar(arriba: carpeta != nil)
        if reloj == nil {
            let r = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                guard let self, let w = self.ventana, w.isVisible, w.occlusionState.contains(.visible) else { return }
                self.recargar()
            }
            RunLoop.main.add(r, forMode: .common)
            reloj = r
        }
    }

    /// main.swift avisa (desde refrescar(), cada segundo mientras graba) si hay una reunión grabándose.
    func actualizarGrabando(_ ahora: Bool) {
        guard ahora != grabando else { return }
        grabando = ahora
        pintar()
    }

    // Para las capturas de prueba (y por si sirven desde el menú).
    func ir(a nueva: Seccion, filtro nuevo: Filtro = .todo) {
        seccion = nueva
        filtro = nuevo
        elegida = nil
        pintar(arriba: true)
    }

    func abrir(carpeta: URL, pestana nueva: Pestana = .notas) {
        elegida = carpeta.resolvingSymlinksInPath().path
        pestana = nueva
        pintar(arriba: true)
    }

    /// Cambia de pestaña en la reunión abierta.
    func elegir(_ nueva: Pestana) {
        pestana = nueva
        pintar(arriba: true)
    }

    // MARK: Armar

    private func armarVentana() -> NSWindow {
        // La barra de título es transparente y la página llega hasta arriba (como otras apps de notas): la barra lateral
        // queda bajo los tres botones de colores. Una franja invisible arriba deja arrastrar la ventana.
        let w = VentanaConTeclas(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        w.title = "Minuta"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.alBuscar = { [weak self] in self?.buscarConTeclado() }

        let vista = NSView()
        let arrastre = Arrastre()
        for v in [web, arrastre] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            vista.addSubview(v)
        }
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: vista.topAnchor),
            web.leadingAnchor.constraint(equalTo: vista.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: vista.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: vista.bottomAnchor),
            arrastre.topAnchor.constraint(equalTo: vista.topAnchor),
            arrastre.leadingAnchor.constraint(equalTo: vista.leadingAnchor),
            arrastre.trailingAnchor.constraint(equalTo: vista.trailingAnchor),
            arrastre.heightAnchor.constraint(equalToConstant: 30),
        ])
        w.contentView = vista
        w.contentMinSize = NSSize(width: 820, height: 520)
        w.initialFirstResponder = web   // así ⌘C y ⌘A van a la página

        // Tamaño y lugar: los de la última vez; la primera vez, 1180×780 al centro.
        if !w.setFrameUsingName("Reuniones") {
            w.setContentSize(NSSize(width: 1180, height: 780))
            w.center()
        }
        w.setFrameAutosaveName("Reuniones")
        web.loadHTMLString(Pagina.base(icono: Self.iconoApp()), baseURL: nil)
        return w
    }

    /// El ícono de la app como imagen para la página (arriba de la barra lateral).
    private static func iconoApp() -> String {
        let imagen = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSApp.applicationIconImage?.draw(in: rect)
            return true
        }
        guard let tiff = imagen.tiffRepresentation, let mapa = NSBitmapImageRep(data: tiff),
              let png = mapa.representation(using: .png, properties: [:]) else { return "" }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    // MARK: Leer las carpetas

    /// Lee las reuniones y los dictados (solo vuelve a leer lo que cambió) y pone la página al día.
    private func recargar(arriba: Bool = false) {
        let fm = FileManager.default
        let raiz = Config.carpetaReuniones
        let urls = (try? fm.contentsOfDirectory(at: raiz, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        var nuevas: [Reunion] = []
        var leidas: [String: Reunion] = [:]
        for url in urls.map({ $0.resolvingSymlinksInPath() }) {
            guard url.lastPathComponent != "Dictados",
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let firma = Reunion.firma(url)
            let r = guardadas[url.path].flatMap { $0.firma == firma ? $0 : nil } ?? Reunion(carpeta: url, firma: firma)
            leidas[url.path] = r
            nuevas.append(r)
        }
        guardadas = leidas
        nuevas.sort { $0.fecha != $1.fecha ? $0.fecha > $1.fecha : $0.carpeta.lastPathComponent > $1.carpeta.lastPathComponent }
        todas = nuevas

        // Al terminar de resumir, procesar.py le agrega el tema al nombre de la carpeta: sigo en la misma reunión.
        if let elegida, guardadas[elegida] == nil {
            let antes = (elegida as NSString).lastPathComponent
            self.elegida = todas.first { $0.carpeta.lastPathComponent.hasPrefix(antes + "-") }?.carpeta.path
        }

        // Dictados/AAAA-MM-DD.md: uno por día. Solo se vuelve a leer el archivo que cambió (normalmente el de hoy).
        let carpetaDictados = raiz.appendingPathComponent("Dictados")
        let archivos = ((try? fm.contentsOfDirectory(atPath: carpetaDictados.path)) ?? []).filter { $0.hasSuffix(".md") }
        var dias: [String: (firma: Date, entradas: [DictadoGuardado])] = [:]
        for archivo in archivos {
            let url = carpetaDictados.appendingPathComponent(archivo)
            let firma = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            if let ya = diasDictados[archivo], ya.firma == firma {
                dias[archivo] = ya
            } else {
                let texto = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                dias[archivo] = (firma, DictadoGuardado.leer(texto, archivo: archivo))
            }
        }
        diasDictados = dias
        dictados = dias.values.flatMap(\.entradas).sorted {
            $0.fecha != $1.fecha ? $0.fecha > $1.fecha : ($0.archivo != $1.archivo ? $0.archivo > $1.archivo : $0.orden > $1.orden)
        }
        pintar(arriba: arriba)
    }

    private var reunionAbierta: Reunion? { elegida.flatMap { guardadas[$0] } }

    // MARK: Dibujar

    /// Arma cada parte de la página y le manda solo las que cambiaron. `arriba`: la página visible vuelve al principio.
    private func pintar(arriba: Bool = false) {
        guard listo else { return }
        let abierta = reunionAbierta
        let vista = abierta != nil ? "detalle" : seccion.rawValue
        let encontradas = busqueda.isEmpty ? todas : todas.filter { $0.contiene(busqueda) }
        var partes: [String: String] = [
            "atajos": Pagina.atajos(),
            "boton-grabar": Pagina.botonGrabar(grabando: grabando),
            "inicio-cabeza": Pagina.cabezaInicio(nombre: Config.nombre, dictados: dictados, reuniones: todas),
            "inicio-filtros": Pagina.filtros(filtro),
            "inicio-lista": Pagina.listaInicio(dictados: dictados, reuniones: todas, filtro: filtro),
            "reuniones-lista": Pagina.listaReuniones(encontradas, busqueda: busqueda, hayAlguna: !todas.isEmpty),
        ]
        if let r = abierta {
            let visibles: [Pestana] = [.notas] + (r.minuta != nil ? [.minuta] : []) + [.transcripcion]
            if !visibles.contains(pestana) { pestana = .notas }
            partes["detalle-barra"] = Pagina.barraDetalle(r, pestanas: visibles, elegida: pestana,
                                                          volverA: seccion == .inicio ? "Inicio" : "Reuniones")
            let clave = "\(r.firma)|\(pestana.rawValue)"
            if cuerpoGuardado?.clave != clave {
                let html: String
                switch pestana {
                case .notas: html = Pagina.notas(r)
                case .minuta: html = Pagina.minuta(r)
                case .transcripcion: html = Pagina.transcripcion(r)
                }
                cuerpoGuardado = (clave, html)
            }
            partes["detalle-cuerpo"] = cuerpoGuardado?.html
        }
        let cambios = partes.filter { enviado[$0.key] != $0.value }
        guard !cambios.isEmpty || arriba || vista != vistaEnviada || seccion.rawValue != seccionEnviada else { return }
        enviado.merge(cambios) { $1 }
        vistaEnviada = vista
        seccionEnviada = seccion.rawValue
        web.callAsyncJavaScript("poner(cambios, vista, seccion, arriba)",
                                arguments: ["cambios": cambios, "vista": vista, "seccion": seccion.rawValue, "arriba": arriba],
                                in: nil, in: .page, completionHandler: nil)
    }

    // MARK: Lo que llega de la página

    fileprivate func recibir(_ cuerpo: Any) {
        guard let datos = cuerpo as? [String: Any], let accion = datos["accion"] as? String else { return }
        let valor = datos["valor"] as? String ?? ""
        switch accion {
        case "ir":
            guard let nueva = Seccion(rawValue: valor) else { return }
            let mismaPagina = nueva == seccion && elegida == nil
            seccion = nueva
            elegida = nil
            pintar(arriba: mismaPagina)   // apretar la página en que ya estás la lleva al principio
        case "filtro":
            guard let nuevo = Filtro(rawValue: valor) else { return }
            filtro = nuevo
            pintar(arriba: true)
        case "buscar":
            busqueda = valor.trimmingCharacters(in: .whitespaces)
            pintar()
        case "abrir":
            guard guardadas[valor] != nil else { return }
            elegida = valor
            pestana = .notas
            pintar(arriba: true)
        case "volver":
            elegida = nil
            pintar()
        case "pestana":
            if let nueva = Pestana(rawValue: valor) { elegir(nueva) }
        case "copiarDictado":
            if let d = dictados.first(where: { $0.id == valor }) { copiar(d.texto) }
        case "copiarCorreo":
            if let correo = reunionAbierta?.correo { copiar(correo) }
        case "copiarNotas":
            if let resumen = reunionAbierta?.resumen { copiar(resumen) }
        case "abrirCarpeta":
            if let r = reunionAbierta { NSWorkspace.shared.open(r.carpeta) }
        case "grabar":
            alGrabar?()
        case "detener":
            alDetener?()
        default:
            break
        }
    }

    private func copiar(_ texto: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(texto, forType: .string)
        web.evaluateJavaScript("aviso('Copiado')", completionHandler: nil)
    }

    /// ⌘F: a Reuniones, con el cursor en el buscador.
    private func buscarConTeclado() {
        seccion = .reuniones
        elegida = nil
        pintar()
        ventana?.makeFirstResponder(web)
        web.evaluateJavaScript("enfocarBuscar()", completionHandler: nil)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // También pasa si alguien recarga la página (menú del clic derecho): se le vuelve a mandar todo.
        listo = true
        enviado = [:]
        vistaEnviada = ""
        busqueda = ""
        pintar(arriba: true)
    }

    /// La página es solo nuestra: no se sigue ningún enlace.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .other || navigationAction.navigationType == .reload ? .allow : .cancel)
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { recargar() }

    func windowWillClose(_ notification: Notification) {
        reloj?.invalidate()
        reloj = nil
        // La próxima vez se abre en Inicio.
        seccion = .inicio
        elegida = nil
        // Vuelve a vivir solo en la barra de arriba (el ícono del Dock queda fijo si lo agregaste).
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}

/// Pasa los mensajes de la página a la ventana sin retenerla (WebKit retiene fuerte a quien los recibe).
private final class Mensajero: NSObject, WKScriptMessageHandler {
    private weak var ventana: VentanaReuniones?

    init(_ ventana: VentanaReuniones) {
        self.ventana = ventana
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        ventana?.recibir(message.body)
    }
}

/// Franja invisible arriba de la ventana: la página llega hasta el borde, así que se arrastra desde aquí.
private final class Arrastre: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with evento: NSEvent) {
        if evento.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: evento) }
    }
}

/// La app no tiene menú de Edición (vive en la barra de arriba), así que ⌘C, ⌘A, ⌘F y ⌘W se atienden aquí.
private final class VentanaConTeclas: NSWindow {
    var alBuscar: (() -> Void)?

    override func performKeyEquivalent(with evento: NSEvent) -> Bool {
        guard evento.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let tecla = evento.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: evento) }
        switch tecla {
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case "a": return NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: self)
        case "f": alBuscar?(); return true
        case "w": performClose(nil); return true
        default: return super.performKeyEquivalent(with: evento)
        }
    }
}

/// Una reunión leída de su carpeta `AAAA-MM-DD-HHMM-tema/`.
struct Reunion {
    let carpeta: URL
    let firma: String          // cambia si cambia alguno de sus archivos
    let fecha: Date
    let titulo: String
    let duracion: String?      // "2 min", de la primera línea de transcripcion.md
    let resumen: String?
    let minuta: String?
    let transcripcion: String?
    let estado: String?        // nil si ya tiene resumen; si no, "procesando…" o qué falló
    let etapa: String?         // lo último que anotó procesar.py en proceso.log
    let app: String?           // de info.json ({"app": "Google Meet"}), si la grabación partió con una llamada
    let asistentes: [String]   // de info.json: los invitados según el calendario (sin ti)
    let tldr: String?          // el TL;DR de las notas (o el resumen), en una sola línea, para las listas

    private static let archivos = ["resumen.md", "minuta.md", "transcripcion.md", "proceso.log", "info.json"]

    init(carpeta: URL, firma: String) {
        self.carpeta = carpeta
        self.firma = firma
        func leer(_ nombre: String) -> String? {
            try? String(contentsOf: carpeta.appendingPathComponent(nombre), encoding: .utf8)
        }
        resumen = leer("resumen.md")
        minuta = leer("minuta.md")
        transcripcion = leer("transcripcion.md")
        let info = leer("info.json").flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        app = (info?["app"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        asistentes = (info?["asistentes"] as? [[String: Any]] ?? []).compactMap { $0["nombre"] as? String }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let delCalendario = (info?["titulo"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        tldr = resumen.flatMap(Reunion.tldr(de:))

        let nombre = carpeta.lastPathComponent
        let creada = (try? carpeta.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        fecha = Reunion.formatoCarpeta.date(from: String(nombre.prefix(15))) ?? creada
        // Mientras se procesa (sin resumen ni nombre en la carpeta), el título del calendario en vez de "Reunión".
        let tema = Reunion.tema(de: nombre)
        titulo = resumen.flatMap(Reunion.titulo(de:)) ?? (tema == "Reunión" ? delCalendario : nil) ?? tema
        duracion = transcripcion?.components(separatedBy: "\n").first?
            .components(separatedBy: " · ").last
            .flatMap { $0.hasSuffix("min") ? $0.trimmingCharacters(in: .whitespaces) : nil }
            .map { $0 == "0 min" ? "<1 min" : $0 }   // una conversación de segundos

        // proceso.log: "HH:MM:SS ETAPA: …", "… ERROR: …", "… LISTO: …"
        let log = (leer("proceso.log") ?? "").components(separatedBy: "\n")
        let ultima = { (clave: String) in
            log.last { $0.contains(clave) }.flatMap { $0.components(separatedBy: clave).last }?
                .trimmingCharacters(in: .whitespaces)
        }
        let error = ultima("ERROR: ")
        if resumen != nil {
            estado = nil
            etapa = nil
        } else if let error, transcripcion != nil || log.last(where: { !$0.isEmpty })?.contains("LISTO") == true {
            estado = "sin resumen"
            etapa = error
        } else if let error {
            estado = "no se pudo procesar"
            etapa = error
        } else {
            estado = "procesando…"
            etapa = ultima("ETAPA: ")
        }
    }

    var esVenta: Bool { minuta != nil }

    /// Si fue una llamada (Meet, Zoom, Teams…): lo dice info.json o la transcripción tiene la voz de "Llamada".
    var fueLlamada: Bool { app != nil || transcripcion?.contains("] Llamada:") == true }

    /// Los minutos de "7 min", para sumar las horas de reunión.
    var minutos: Int? { duracion.flatMap { Int($0.components(separatedBy: " ").first ?? "") } }

    /// "13:10", de la carpeta (o de cuándo se creó, si el nombre no trae la hora).
    var hora: String { Reunion.formatoHora.string(from: fecha) }

    /// El borrador del correo de la minuta: desde "Asunto:" hasta que termina esa sección (sin el título "##").
    var correo: String? {
        guard let minuta else { return nil }
        let lineas = minuta.components(separatedBy: "\n")
        guard let inicio = lineas.firstIndex(where: { $0.hasPrefix("## ") && $0.lowercased().contains("correo") }) else { return nil }
        var cuerpo = Array(lineas[(inicio + 1)...])
        if let fin = cuerpo.firstIndex(where: { $0.hasPrefix("# ") || $0.hasPrefix("## ") }) { cuerpo = Array(cuerpo[..<fin]) }
        if let asunto = cuerpo.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Asunto:") }) {
            cuerpo = Array(cuerpo[asunto...])
        }
        let texto = cuerpo.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return texto.isEmpty ? nil : texto
    }

    /// Para el buscador: el título, las notas, la minuta y la transcripción (sin importar mayúsculas ni tildes).
    func contiene(_ texto: String) -> Bool {
        [titulo, resumen, minuta, transcripcion].contains {
            $0?.range(of: texto, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// Las fechas de modificación de sus archivos: si no cambian, no hace falta volver a leer la carpeta.
    static func firma(_ carpeta: URL) -> String {
        let fm = FileManager.default
        return ([carpeta.path] + archivos.map { nombre in
            let atributos = try? fm.attributesOfItem(atPath: carpeta.appendingPathComponent(nombre).path)
            return (atributos?[.modificationDate] as? Date).map { "\($0.timeIntervalSince1970)" } ?? "-"
        }).joined(separator: "|")
    }

    /// "# Transportes Acme · 2026-10-21" → "Transportes Acme". También acepta "Reunión: … · fecha".
    static func titulo(de texto: String) -> String? {
        guard var linea = texto.components(separatedBy: "\n").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        linea = linea.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        for prefijo in ["Reunión: ", "Minuta: "] where linea.hasPrefix(prefijo) { linea = String(linea.dropFirst(prefijo.count)) }
        linea = linea.reemplazando(#"\s*·\s*\d{4}-\d{2}-\d{2}.*$"#, por: "")
        return linea.isEmpty ? nil : linea
    }

    /// "2026-10-21-2310-prueba-reunion-de-venta" → "Prueba reunion de venta".
    static func tema(de nombre: String) -> String {
        let resto = nombre.count > 16 && formatoCarpeta.date(from: String(nombre.prefix(15))) != nil
            ? String(nombre.dropFirst(16)) : (formatoCarpeta.date(from: nombre) != nil ? "" : nombre)
        let tema = resto.replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
        return tema.isEmpty ? "Reunión" : tema.prefix(1).uppercased() + tema.dropFirst()
    }

    /// "Hoy", "Ayer", "Martes 21 de octubre" (con el año si no es este).
    static func nombreDia(_ fecha: Date) -> String {
        let calendario = Calendar.current
        if calendario.isDateInToday(fecha) { return "Hoy" }
        if calendario.isDateInYesterday(fecha) { return "Ayer" }
        let f = calendario.isDate(fecha, equalTo: Date(), toGranularity: .year) ? formatoDia : formatoDiaConAno
        let texto = f.string(from: fecha)
        return texto.prefix(1).uppercased() + texto.dropFirst()
    }

    /// "Martes 21 de octubre de 2026 · 23:10 · 2 min", para el encabezado de la reunión.
    var fechaLarga: String {
        let dia = Reunion.formatoDiaConAno.string(from: fecha)
        return ([dia.prefix(1).uppercased() + dia.dropFirst(), hora] + (duracion.map { [$0] } ?? [])).joined(separator: " · ")
    }

    private static let formatoCarpeta: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f
    }()
    private static let formatoHora: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let formatoDia: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_CL")
        f.dateFormat = "EEEE d 'de' MMMM"
        return f
    }()
    private static let formatoDiaConAno: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_CL")
        f.dateFormat = "EEEE d 'de' MMMM 'de' y"
        return f
    }()
}

extension Reunion {
    /// El TL;DR de resumen.md en una sola línea (sin viñetas ni **). Si no hay, la sección "Resumen".
    static func tldr(de texto: String) -> String? {
        let lineas = texto.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        func seccion(_ calza: (String) -> Bool) -> String? {
            guard let inicio = lineas.firstIndex(where: { $0.hasPrefix("## ") && calza($0.dropFirst(3).lowercased()) }) else { return nil }
            let cuerpo = lineas[(inicio + 1)...].prefix { !$0.hasPrefix("#") }
            let limpio = cuerpo.map { $0.trimmingCharacters(in: .whitespaces).reemplazando(#"^[-*•]\s+"#, por: "") }
                .filter { !$0.isEmpty && !$0.hasPrefix("|") }
                .joined(separator: " ")
                .replacingOccurrences(of: "**", with: "")
            return limpio.isEmpty ? nil : limpio
        }
        return seccion { $0.contains("tl;dr") } ?? seccion { $0.hasPrefix("resumen") }
    }
}

/// Un dictado del historial `Dictados/AAAA-MM-DD.md`, que escribe Dictado.guardar:
/// "[HH:MM] texto" (el texto puede seguir en varias líneas, por ejemplo con viñetas) y, si Claude lo ordenó,
/// una línea "> Original: …" con lo dicho tal cual. Un dictado termina donde empieza la próxima línea "[HH:MM] ".
struct DictadoGuardado {
    let id: String             // "2026-10-22.md#3": no cambia aunque lleguen dictados nuevos
    let archivo: String
    let orden: Int             // su lugar dentro del archivo (dos dictados pueden tener la misma hora)
    let fecha: Date
    let texto: String
    let original: String?

    var palabras: Int { texto.split(whereSeparator: \.isWhitespace).count }
    var hora: String { DictadoGuardado.formatoHora.string(from: fecha) }

    static func leer(_ contenido: String, archivo: String) -> [DictadoGuardado] {
        let dia = formatoDia.date(from: String(archivo.prefix(10))) ?? .distantPast
        var lista: [DictadoGuardado] = []
        var actual: (hora: Int, minuto: Int, texto: [String], original: [String]?)?
        func cerrar() {
            guard let a = actual else { return }
            actual = nil
            let texto = a.texto.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !texto.isEmpty else { return }
            let original = a.original?.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let fecha = Calendar.current.date(bySettingHour: a.hora, minute: a.minuto, second: 0, of: dia) ?? dia
            lista.append(DictadoGuardado(id: "\(archivo)#\(lista.count)", archivo: archivo, orden: lista.count,
                                         fecha: fecha, texto: texto, original: original?.isEmpty == false ? original : nil))
        }
        for linea in contenido.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            if let g = linea.grupos(#"^\[(\d{1,2}):(\d{2})\] ?(.*)$"#), g.count == 3 {
                cerrar()
                actual = (Int(g[0]) ?? 0, Int(g[1]) ?? 0, [g[2]], nil)
            } else if actual != nil, linea.hasPrefix("> Original:") {
                actual?.original = [String(linea.dropFirst("> Original:".count)).trimmingCharacters(in: .whitespaces)]
            } else if actual?.original != nil {
                actual?.original?.append(linea)
            } else {
                actual?.texto.append(linea)   // antes del primer "[HH:MM]" solo está el título: no se usa
            }
        }
        cerrar()
        return lista
    }

    private static let formatoDia: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let formatoHora: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

// MARK: - Páginas (HTML)

/// Arma la página de la ventana: una base fija (barra lateral, páginas, estilo y un poco de JavaScript) y los
/// pedazos que van cambiando (listas, cifras, la reunión abierta). Todo el texto se escapa antes de armar el HTML.
/// Sigue el modo claro u oscuro del Mac.
enum Pagina {
    // MARK: Base

    static func base(icono: String) -> String {
        let imagen = icono.isEmpty ? "" : #"<img src="\#(icono)" alt="">"#
        return """
        <!doctype html><html lang="es"><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark"><style>\(estiloBase)\(estilo)</style></head>
        <body data-vista="inicio" data-seccion="inicio">
        <aside id="lado">
          <div class="marca-app">\(imagen)<span>Minuta</span></div>
          <div class="nav" role="button" data-accion="ir" data-valor="inicio">\(Icono.casa)<span>Inicio</span></div>
          <div class="nav" role="button" data-accion="ir" data-valor="reuniones">\(Icono.lista)<span>Reuniones</span></div>
          <div class="caja-atajos" id="atajos"></div>
        </aside>
        <div id="centro">
          <section class="pagina" id="inicio"><div class="desplazable"><div class="contenido">
            <div id="inicio-cabeza"></div>
            <div id="inicio-filtros"></div>
            <div id="inicio-lista"></div>
          </div></div></section>
          <section class="pagina" id="reuniones"><div class="desplazable"><div class="contenido">
            <div class="cabeza-reuniones"><div class="titulo-pagina">Reuniones</div><div id="boton-grabar"></div></div>
            <label class="buscador">\(Icono.lupa)<input id="buscar" type="text" placeholder="Buscar en reuniones" autocomplete="off" spellcheck="false"></label>
            <div class="filtros"><span class="filtro activo">Todas</span></div>
            <div id="reuniones-lista"></div>
          </div></div></section>
          <section class="pagina" id="detalle">
            <div id="detalle-barra"></div>
            <div class="desplazable"><main class="doc" id="detalle-cuerpo"></main></div>
          </section>
          <div id="aviso">Copiado</div>
        </div>
        <script>\(guion)</script>
        </body></html>
        """
    }

    /// Los clics van a Swift; Swift manda de vuelta los pedazos de HTML que cambiaron con poner().
    private static let guion = #"""
    const enviar = (accion, valor) => window.webkit.messageHandlers.minuta.postMessage({accion, valor: valor || ""});
    document.addEventListener("click", e => {
      const el = e.target.closest("[data-accion]");
      if (!el || el.classList.contains("apagado")) return;
      e.preventDefault();
      enviar(el.dataset.accion, el.dataset.valor);
    });
    const buscar = document.getElementById("buscar");
    buscar.addEventListener("input", () => enviar("buscar", buscar.value));
    document.addEventListener("keydown", e => {
      if (e.key !== "Escape") return;
      if (document.activeElement === buscar && buscar.value) { buscar.value = ""; enviar("buscar", ""); }
      else if (document.body.dataset.vista === "detalle") enviar("volver");
    });
    function poner(cambios, vista, seccion, arriba) {
      for (const id in cambios) { const el = document.getElementById(id); if (el) el.innerHTML = cambios[id]; }
      document.body.dataset.vista = vista;
      document.body.dataset.seccion = seccion;
      if (arriba) { const d = document.querySelector("#" + vista + " .desplazable"); if (d) d.scrollTop = 0; }
    }
    function enfocarBuscar() { buscar.focus(); buscar.select(); }
    let relojAviso;
    function aviso(texto) {
      const a = document.getElementById("aviso");
      a.textContent = texto;
      a.classList.add("visible");
      clearTimeout(relojAviso);
      relojAviso = setTimeout(() => a.classList.remove("visible"), 1300);
    }
    """#

    // MARK: Barra lateral

    static func atajos() -> String {
        let filas = [("Mantén para dictar", "⌃⌥"), ("Dictado largo", Atajos.dictado.texto), ("Grabar reunión", Atajos.reunion.texto)]
        return #"<div class="rotulo">Atajos</div>"# + filas.map {
            #"<div class="atajo"><span>\#(Markdown.escapar($0.0))</span><kbd>\#(Markdown.escapar($0.1))</kbd></div>"#
        }.joined()
    }

    static func botonGrabar(grabando: Bool) -> String {
        grabando
            ? #"<div class="grabar grabando" role="button" data-accion="detener"><span class="punto"></span>Detener y resumir</div>"#
            : #"<div class="grabar" role="button" data-accion="grabar"><span class="punto"></span>Grabar reunión</div>"#
    }

    // MARK: Inicio

    /// "Buenas tardes, Santiago." y a la derecha las cifras, como otras apps de notas.
    static func cabezaInicio(nombre: String, dictados: [DictadoGuardado], reuniones: [Reunion], ahora: Date = Date()) -> String {
        let h = Calendar.current.component(.hour, from: ahora)
        let saludo = (5..<12).contains(h) ? "Buenos días" : (12..<20).contains(h) ? "Buenas tardes" : "Buenas noches"
        let nombre = nombre.trimmingCharacters(in: .whitespaces)
        let palabras = dictados.reduce(0) { $0 + $1.palabras }
        let horas = Double(reuniones.reduce(0) { $0 + ($1.minutos ?? 0) }) / 60
        let cifras = [
            (numero(dictados.count), "Dictados"),
            (numero(palabras), "Palabras dictadas"),
            (numero(reuniones.count), "Reuniones"),
            (formatoHoras.string(from: NSNumber(value: horas)) ?? "0", "Horas de reunión"),
        ]
        return """
        <div class="cabeza"><div class="saludo">\(Markdown.escapar(saludo + (nombre.isEmpty ? "" : ", " + nombre))).</div>\
        <div class="cifras">\(cifras.map { #"<div class="cifra"><div class="numero">\#($0.0)</div><div class="rotulo">\#($0.1)</div></div>"# }.joined())</div></div>
        """
    }

    static func filtros(_ elegido: VentanaReuniones.Filtro) -> String {
        let todos: [(VentanaReuniones.Filtro, String)] = [(.todo, "Todo"), (.dictados, "Dictados"), (.reuniones, "Reuniones")]
        return #"<div class="filtros">"# + todos.map {
            #"<span class="filtro\#($0.0 == elegido ? " activo" : "")" role="button" data-accion="filtro" data-valor="\#($0.0.rawValue)">\#($0.1)</span>"#
        }.joined() + "</div>"
    }

    /// Todos los dictados y todas las reuniones juntos, por día y lo más nuevo arriba. Máximo 3 líneas cada uno.
    static func listaInicio(dictados: [DictadoGuardado], reuniones: [Reunion], filtro: VentanaReuniones.Filtro) -> String {
        enum Cosa { case dictado(DictadoGuardado), reunion(Reunion) }
        var cosas: [(fecha: Date, cosa: Cosa)] = []
        if filtro != .reuniones { cosas += dictados.map { ($0.fecha, .dictado($0)) } }
        if filtro != .dictados { cosas += reuniones.map { ($0.fecha, .reunion($0)) } }
        // sort no es estable: los empates (misma hora) quedan en el orden en que venían.
        cosas = cosas.enumerated().sorted { $0.element.fecha != $1.element.fecha ? $0.element.fecha > $1.element.fecha : $0.offset < $1.offset }.map(\.element)
        guard !cosas.isEmpty else {
            switch filtro {
            case .dictados: return vacio("Todavía no hay dictados", "Mantén ⌃⌥, habla y suelta: el texto se escribe donde está el cursor y queda aquí.")
            case .reuniones: return vacio("Todavía no hay reuniones", "Graba una desde la página Reuniones o con \(Atajos.reunion.texto).")
            case .todo: return vacio("Todavía no hay nada", "Aquí van a aparecer tus dictados y tus reuniones, lo más nuevo arriba.")
            }
        }
        return porDia(cosas.map { ($0.fecha, $0.cosa) }) { cosa in
            switch cosa {
            case .dictado(let d):
                let ayuda = "Clic para copiar" + (d.original.map { "\n\nLo que dijiste tal cual: \($0)" } ?? "")
                return """
                <div class="item" role="button" data-accion="copiarDictado" data-valor="\(Markdown.escapar(d.id))" title="\(Markdown.escapar(ayuda))">\
                <div class="item-cabeza"><span>Dictado</span><span>\(d.hora)</span></div>\
                <div class="item-texto lineas-3">\(Markdown.escapar(d.texto))</div></div>
                """
            case .reunion(let r):
                let tipo = ["Reunión"] + (r.duracion.map { [$0] } ?? [])
                let texto = r.tldr ?? r.estado.map { $0 + (r.etapa.map { " · \($0)" } ?? "") } ?? ""
                return """
                <div class="item" role="button" data-accion="abrir" data-valor="\(Markdown.escapar(r.carpeta.path))">\
                <div class="item-cabeza"><span>\(Markdown.escapar(tipo.joined(separator: " · ")))</span><span>\(r.hora)</span></div>\
                <div class="item-titulo">\(Markdown.escapar(r.titulo))</div>\
                <div class="item-texto lineas-2\(r.tldr == nil ? " tenue" : "")">\(Markdown.escapar(texto))</div></div>
                """
            }
        }
    }

    // MARK: Reuniones

    static func listaReuniones(_ reuniones: [Reunion], busqueda: String, hayAlguna: Bool) -> String {
        guard !reuniones.isEmpty else {
            return hayAlguna
                ? vacio("Sin resultados", "No encontré reuniones con «\(busqueda)».")
                : vacio("Todavía no hay reuniones", "Graba una con el botón de arriba o con \(Atajos.reunion.texto). Cuando termine de resumirse, aparece aquí sola.")
        }
        return porDia(reuniones.map { ($0.fecha, $0) }) { r in
            let sub = [r.hora] + (r.app.map { [$0] } ?? []) + (r.estado.map { [$0] } ?? [])
            let chip = r.duracion.map { #"<span class="chip-min">\#(Markdown.escapar($0))</span>"# } ?? ""
            let venta = r.esVenta ? #"<span class="marca">Venta</span>"# : ""
            let tldr = r.tldr.map { #"<div class="fila-tldr lineas-2">\#(Markdown.escapar($0))</div>"# } ?? ""
            return """
            <div class="fila" role="button" data-accion="abrir" data-valor="\(Markdown.escapar(r.carpeta.path))" title="\(Markdown.escapar(r.carpeta.lastPathComponent))">\
            <div class="cuadro">\(r.fueLlamada ? Icono.video : Icono.microfono)</div>\
            <div class="fila-cuerpo"><div class="fila-titulo"><span class="nombre">\(Markdown.escapar(r.titulo))</span>\(chip)\(venta)</div>\
            <div class="fila-sub">\(Markdown.escapar(sub.joined(separator: " · ")))</div>\(tldr)</div>\
            <div class="chevron">\(Icono.chevron)</div></div>
            """
        }
    }

    /// Junta las cosas por día ("Hoy", "Ayer", "Martes 20 de octubre"), en el orden en que vienen.
    private static func porDia<T>(_ cosas: [(Date, T)], _ html: (T) -> String) -> String {
        var salida = ""
        var dia = ""
        for (fecha, cosa) in cosas {
            let esteDia = Reunion.nombreDia(fecha)
            if esteDia != dia {
                salida += (dia.isEmpty ? "" : "</div>") + #"<div class="dia">\#(Markdown.escapar(esteDia))</div><div class="grupo">"#
                dia = esteDia
            }
            salida += html(cosa)
        }
        return salida + (dia.isEmpty ? "" : "</div>")
    }

    // MARK: Detalle de una reunión

    static func barraDetalle(_ r: Reunion, pestanas: [VentanaReuniones.Pestana], elegida: VentanaReuniones.Pestana, volverA: String) -> String {
        let segmentos = pestanas.map {
            #"<span class="segmento\#($0 == elegida ? " activo" : "")" role="button" data-accion="pestana" data-valor="\#($0.rawValue)">\#($0.nombre)</span>"#
        }.joined()
        let correo = r.correo != nil ? #"<span class="accion" role="button" data-accion="copiarCorreo">\#(Icono.sobre)Copiar correo</span>"# : ""
        let notas = #"<span class="accion\#(r.resumen == nil ? " apagado" : "")" role="button" data-accion="copiarNotas">\#(Icono.copiar)Copiar notas</span>"#
        let carpeta = #"<span class="accion" role="button" data-accion="abrirCarpeta">\#(Icono.carpeta)Abrir carpeta</span>"#
        return """
        <div class="barra-detalle"><span class="volver" role="button" data-accion="volver">\(Icono.atras)\(volverA)</span>\
        <div class="segmentos">\(segmentos)</div><div class="acciones">\(correo)\(notas)\(carpeta)</div></div>
        """
    }

    static func notas(_ r: Reunion) -> String {
        guard let resumen = r.resumen else { return procesando(r) }
        return encabezado(r) + Markdown.html(Markdown.sinTitulo(resumen))
    }

    static func minuta(_ r: Reunion) -> String {
        guard let minuta = r.minuta else { return procesando(r) }
        return encabezado(r, sub: "Minuta comercial") + Markdown.html(Markdown.sinTitulo(minuta))
    }

    static func transcripcion(_ r: Reunion) -> String {
        guard let texto = r.transcripcion else {
            return encabezado(r) + vacio("Todavía no hay transcripción", r.etapa.map { "Ahora: \($0)." } ?? "")
        }
        return encabezado(r, sub: "Transcripción") + Markdown.dialogo(texto)
    }

    private static func procesando(_ r: Reunion) -> String {
        let titulo: String
        switch r.estado {
        case "sin resumen"?: titulo = "El resumen falló; la transcripción quedó guardada"
        case "no se pudo procesar"?: titulo = "No se pudo procesar esta reunión"
        default: titulo = "Procesando la reunión…"
        }
        let detalle = r.etapa.map { r.estado == "procesando…" ? "Ahora: \($0)." : $0 }
            ?? "En unos minutos aparece aquí sola."
        return encabezado(r) + vacio(titulo, detalle)
    }

    private static func encabezado(_ r: Reunion, sub: String? = nil) -> String {
        let venta = r.esVenta ? #"<span class="marca">Venta</span>"# : ""
        let antes = sub.map { #"<div class="sub">\#(Markdown.escapar($0))</div>"# } ?? ""
        let fecha = r.fechaLarga + (r.app.map { " · \($0)" } ?? "")
        // "Con Marcela Pérez, Rodrigo Soto" (los invitados del calendario); si son muchos, "y 4 más".
        let nombres = r.asistentes.count > 6
            ? r.asistentes.prefix(5).joined(separator: ", ") + " y \(r.asistentes.count - 5) más"
            : r.asistentes.joined(separator: ", ")
        let con = r.asistentes.isEmpty ? "" : #"<div class="con">Con \#(Markdown.escapar(nombres))</div>"#
        return """
        <header>\(antes)<h1>\(Markdown.escapar(r.titulo))</h1>\
        <div class="fecha"><span>\(Markdown.escapar(fecha))</span>\(venta)</div>\(con)</header>
        """
    }

    private static func vacio(_ titulo: String, _ texto: String) -> String {
        #"<div class="vacio"><div class="vacio-titulo">\#(Markdown.escapar(titulo))</div><p>\#(Markdown.escapar(texto))</p></div>"#
    }

    // MARK: Números

    private static func numero(_ n: Int) -> String { formatoNumero.string(from: NSNumber(value: n)) ?? "\(n)" }

    private static let formatoNumero: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "es_CL")
        f.numberStyle = .decimal
        return f
    }()
    /// "0,4", "12,5": horas con un decimal.
    private static let formatoHoras: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "es_CL")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f
    }()

    // MARK: Estilo

    /// La ventana: barra lateral, páginas, listas y botones. Abajo va `estilo`, el de las notas de la reunión.
    private static let estiloBase = """
    :root {
      --fondo: #ffffff; --lado: #f6f5f1; --texto: #1d1d1f; --suave: #48484a; --tenue: #86868b;
      --linea: rgba(0,0,0,.08); --linea-fuerte: rgba(0,0,0,.13); --caja: #f3f3f1; --hover: rgba(0,0,0,.035);
      --acento: #f5e663; --acento-texto: #1d1d1f; --rojo: #e5484d;
      --pildora: #ffffff; --pildora-texto: #1d1d1f; --pildora-borde: rgba(0,0,0,.14);
      --segmento: #ffffff; --tecla: #ffffff;
      --serif: ui-serif, "New York", Georgia, serif; --mono: ui-monospace, "SF Mono", Menlo, monospace;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --fondo: #18181a; --lado: #111113; --texto: #ececee; --suave: #c5c5ca; --tenue: #8d8d93;
        --linea: rgba(255,255,255,.08); --linea-fuerte: rgba(255,255,255,.14); --caja: #252528; --hover: rgba(255,255,255,.045);
        --acento: #f5e663; --acento-texto: #19190f; --rojo: #ff5a5f;
        --pildora: #f2f1ec; --pildora-texto: #18181a; --pildora-borde: transparent;
        --segmento: #3a3a3e; --tecla: #2a2a2d;
      }
    }
    * { box-sizing: border-box; }
    html, body { margin: 0; height: 100%; overflow: hidden; }
    body { display: flex; background: var(--fondo); color: var(--texto); cursor: default;
      font: 15px/1.55 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; -webkit-font-smoothing: antialiased; }
    [role=button] { cursor: pointer; -webkit-user-select: none; user-select: none; }

    #lado { width: 240px; flex: none; display: flex; flex-direction: column; gap: 3px; padding: 50px 14px 16px;
      background: var(--lado); border-right: 1px solid var(--linea); -webkit-user-select: none; user-select: none; }
    .marca-app { display: flex; align-items: center; gap: 9px; padding: 0 8px; margin-bottom: 20px;
      font-size: 17px; font-weight: 700; letter-spacing: -.015em; }
    .marca-app img { width: 26px; height: 26px; }
    .nav { display: flex; align-items: center; gap: 11px; padding: 9px 12px; border-radius: 10px;
      font-size: 15px; font-weight: 550; color: var(--suave); }
    .nav svg { width: 19px; height: 19px; flex: none; }
    .nav:hover { background: var(--hover); }
    body[data-seccion=inicio] .nav[data-valor=inicio], body[data-seccion=reuniones] .nav[data-valor=reuniones] {
      background: var(--acento); color: var(--acento-texto); }
    .caja-atajos { margin-top: auto; border: 1px solid var(--linea); border-radius: 12px; padding: 12px 13px 8px; font-size: 12.5px; color: var(--suave); }
    .caja-atajos .rotulo { font-size: 10px; font-weight: 700; letter-spacing: .14em; text-transform: uppercase; color: var(--tenue); margin-bottom: 6px; }
    .atajo { display: flex; align-items: center; justify-content: space-between; gap: 8px; margin: 0 0 7px; }
    kbd { font: 500 11.5px/1.5 -apple-system, sans-serif; color: var(--texto); background: var(--tecla); border: 1px solid var(--linea-fuerte);
      border-bottom-width: 2px; border-radius: 5px; padding: 0 6px; white-space: nowrap; }

    #centro { flex: 1; min-width: 0; position: relative; }
    .pagina { position: absolute; inset: 0; display: flex; flex-direction: column; visibility: hidden; }
    body[data-vista=inicio] #inicio, body[data-vista=reuniones] #reuniones, body[data-vista=detalle] #detalle { visibility: visible; }
    .desplazable { flex: 1; overflow-y: auto; }
    .contenido { max-width: 900px; margin: 0 auto; padding: 50px 52px 80px; }

    .cabeza { display: flex; flex-wrap: wrap; align-items: flex-end; justify-content: space-between; gap: 22px 28px; margin-bottom: 34px; }
    .saludo, .titulo-pagina { font-family: var(--serif); font-size: 34px; line-height: 1.12; font-weight: 400; letter-spacing: -.012em; }
    .cifras { display: flex; gap: 22px; }
    .cifra { min-width: 56px; max-width: 84px; }
    .cifra .numero { font-size: 26px; line-height: 1; font-weight: 500; letter-spacing: -.02em; font-variant-numeric: tabular-nums; }
    .cifra .rotulo { margin-top: 7px; font-size: 9.5px; line-height: 1.35; font-weight: 700; letter-spacing: .13em; text-transform: uppercase; color: var(--tenue); }

    .filtros { display: flex; gap: 24px; border-bottom: 1px solid var(--linea); margin-bottom: 4px; }
    .filtro { padding: 0 0 10px; margin-bottom: -1px; border-bottom: 2px solid transparent;
      font-size: 11.5px; font-weight: 700; letter-spacing: .13em; text-transform: uppercase; color: var(--tenue); }
    .filtro:hover { color: var(--suave); }
    .filtro.activo { color: var(--texto); border-bottom-color: var(--texto); }

    .dia { font-family: var(--serif); font-size: 21px; font-weight: 400; letter-spacing: -.005em; margin: 30px 0 4px; }
    .grupo > [role=button] { position: relative; margin: 0 -12px; padding: 13px 12px; border-radius: 10px; }
    .grupo > [role=button] + [role=button]::before { content: ""; position: absolute; top: 0; left: 12px; right: 12px; border-top: 1px solid var(--linea); }
    .grupo > [role=button]:hover { background: var(--hover); }
    .grupo > [role=button]:hover::before, .grupo > [role=button]:hover + [role=button]::before { opacity: 0; }
    .item-cabeza { display: flex; justify-content: space-between; gap: 12px; margin-bottom: 4px;
      font: 500 11px/1.4 var(--mono); letter-spacing: .06em; text-transform: uppercase; color: var(--tenue); }
    .item-titulo { font-weight: 650; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
    .item-texto { color: var(--texto); white-space: pre-line; }
    .item-titulo + .item-texto { color: var(--suave); font-size: 14.5px; }
    .tenue { color: var(--tenue) !important; }
    .lineas-3, .lineas-2 { display: -webkit-box; -webkit-box-orient: vertical; overflow: hidden; }
    .lineas-3 { -webkit-line-clamp: 3; }
    .lineas-2 { -webkit-line-clamp: 2; }

    .cabeza-reuniones { display: flex; align-items: center; justify-content: space-between; gap: 16px; margin-bottom: 22px; }
    .grabar { display: inline-flex; align-items: center; gap: 9px; padding: 8px 17px 8px 15px; border-radius: 999px;
      background: var(--pildora); color: var(--pildora-texto); border: 1px solid var(--pildora-borde);
      font-size: 13.5px; font-weight: 600; box-shadow: 0 1px 2px rgba(0,0,0,.07); white-space: nowrap; }
    .grabar:hover { filter: brightness(.96); }
    .grabar .punto { width: 9px; height: 9px; border-radius: 50%; background: var(--rojo); }
    .grabar.grabando .punto { border-radius: 2px; animation: latido 1.2s ease-in-out infinite; }
    @keyframes latido { 50% { opacity: .35; } }
    .buscador { display: flex; align-items: center; gap: 9px; padding: 9px 13px; margin-bottom: 24px;
      background: var(--caja); border-radius: 10px; color: var(--tenue); cursor: text; }
    .buscador svg { width: 15px; height: 15px; flex: none; }
    .buscador input { flex: 1; min-width: 0; border: 0; outline: none; background: transparent; color: var(--texto); font: inherit; font-size: 14px; }
    .buscador input::placeholder { color: var(--tenue); }

    .fila { display: flex; align-items: flex-start; gap: 14px; }
    .cuadro { flex: none; width: 40px; height: 40px; border-radius: 10px; display: grid; place-items: center;
      background: var(--caja); color: var(--suave); margin-top: 1px; }
    .cuadro svg { width: 19px; height: 19px; }
    .fila-cuerpo { flex: 1; min-width: 0; }
    .fila-titulo { display: flex; align-items: center; gap: 8px; min-width: 0; }
    .fila-titulo .nombre { font-weight: 650; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
    .chip-min { flex: none; font: 600 10px/1 var(--mono); letter-spacing: .07em; text-transform: uppercase;
      color: var(--suave); background: var(--caja); border-radius: 5px; padding: 4px 6px 3px; }
    .fila-titulo .marca { flex: none; }
    .fila-sub { font-size: 13px; color: var(--tenue); margin-top: 1px; font-variant-numeric: tabular-nums; }
    .fila-tldr { font-size: 13.5px; line-height: 1.5; color: var(--suave); margin-top: 5px; }
    .chevron { flex: none; align-self: center; color: var(--tenue); opacity: .7; }
    .chevron svg { width: 16px; height: 16px; display: block; }

    .barra-detalle { display: flex; flex-wrap: wrap; align-items: center; gap: 10px 16px; padding: 38px 22px 12px;
      border-bottom: 1px solid var(--linea); -webkit-user-select: none; user-select: none; }
    .volver { display: inline-flex; align-items: center; gap: 3px; padding: 4px 10px 4px 5px; border-radius: 8px;
      font-size: 14px; font-weight: 550; color: var(--suave); }
    .volver svg { width: 16px; height: 16px; }
    .volver:hover { background: var(--hover); color: var(--texto); }
    .segmentos { display: inline-flex; padding: 2px; border-radius: 9px; background: var(--caja); }
    .segmento { padding: 3px 13px; border-radius: 7px; font-size: 13px; font-weight: 500; color: var(--suave); }
    .segmento.activo { background: var(--segmento); color: var(--texto); box-shadow: 0 1px 2px rgba(0,0,0,.12), 0 0 0 .5px rgba(0,0,0,.05); }
    .acciones { margin-left: auto; display: flex; flex-wrap: wrap; gap: 8px; }
    .accion { display: inline-flex; align-items: center; gap: 6px; padding: 4px 11px; border-radius: 8px;
      border: 1px solid var(--linea-fuerte); font-size: 12.5px; font-weight: 500; color: var(--texto); white-space: nowrap; }
    .accion svg { width: 14px; height: 14px; color: var(--suave); }
    .accion:hover { background: var(--hover); }
    .accion.apagado { opacity: .4; cursor: default; }
    .doc { max-width: 720px; margin: 0 auto; padding: 30px 44px 80px; -webkit-user-select: text; user-select: text; cursor: auto; }

    #aviso { position: absolute; left: 50%; bottom: 26px; transform: translateX(-50%); padding: 7px 16px; border-radius: 9px;
      background: rgba(20,20,20,.86); color: #fff; font-size: 13px; font-weight: 600; opacity: 0; transition: opacity .3s; pointer-events: none; }
    #aviso.visible { opacity: 1; transition: opacity .12s; }

    """

    /// Las notas, la minuta y la transcripción de una reunión (el estilo que ya tenía la ventana Reuniones).
    private static let estilo = """
    :root {
      --nota: #a2670b;
      --tldr-fondo: #fffbe0; --tldr-borde: #f1e48f; --tldr-texto: #8a6d00;
      --venta: #1f8a43; --venta-fondo: rgba(52,199,89,.14);
      --azul: #0a64c8; --azul-fondo: #edf4fe; --verde: #1d7f3e; --verde-fondo: #ecf7ef;
      --morado: #6e44c9; --morado-fondo: #f3eefc; --naranja: #b85a00; --naranja-fondo: #fdf2e5;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --nota: #e2b259;
        --tldr-fondo: rgba(245,230,99,.08); --tldr-borde: rgba(245,230,99,.22); --tldr-texto: #f5e663;
        --venta: #5fd27f; --venta-fondo: rgba(52,199,89,.16);
        --azul: #6db0ff; --azul-fondo: rgba(10,132,255,.15); --verde: #63d184; --verde-fondo: rgba(48,209,88,.13);
        --morado: #bf9cff; --morado-fondo: rgba(175,130,255,.15); --naranja: #ffb35c; --naranja-fondo: rgba(255,159,10,.14);
      }
    }
    header { margin-bottom: 26px; }
    .sub { font-size: 12px; font-weight: 600; letter-spacing: .06em; text-transform: uppercase; color: var(--tenue); margin-bottom: 4px; }
    h1 { font-family: var(--serif); font-size: 32px; line-height: 1.18; font-weight: 500; letter-spacing: -.012em; margin: 0 0 6px; }
    .fecha { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; color: var(--tenue); font-size: 13.5px; }
    .con { color: var(--tenue); font-size: 13.5px; margin-top: 4px; }
    .marca { font-size: 11.5px; font-weight: 600; color: var(--venta); background: var(--venta-fondo); border-radius: 999px; padding: 1px 9px; }
    h2 { font-size: 18px; line-height: 1.3; font-weight: 650; letter-spacing: -.012em; margin: 34px 0 10px; }
    h3 { font-size: 15px; font-weight: 600; margin: 22px 0 6px; }
    h3.tema { display: flex; align-items: center; gap: 9px; }
    h3.tema::before { content: ""; width: 3px; height: 15px; border-radius: 2px; background: var(--azul); opacity: .8; }
    p { margin: 0 0 12px; }
    strong { font-weight: 600; }
    code { font: 13px var(--mono); background: var(--caja); border-radius: 5px; padding: 1px 5px; }
    ul, ol { margin: 0 0 14px; }
    ul { list-style: none; padding-left: 0; }
    ul > li { position: relative; padding-left: 20px; margin: 5px 0; }
    ul > li::before { content: ""; position: absolute; left: 6px; top: .7em; width: 5px; height: 5px; border-radius: 50%; background: var(--tenue); }
    ol { padding-left: 24px; }
    ol > li { margin: 5px 0; padding-left: 4px; }
    ol > li::marker { color: var(--tenue); font-variant-numeric: tabular-nums; }
    .nota { color: var(--nota); font-size: .93em; }
    dl.meta { display: grid; grid-template-columns: max-content 1fr; gap: 6px 18px; margin: 0 0 6px;
      padding: 14px 18px; background: var(--caja); border-radius: 12px; font-size: 14px; line-height: 1.5; }
    dl.meta dt { color: var(--tenue); font-weight: 500; }
    dl.meta dd { margin: 0; }
    section.tldr { margin: 4px 0 6px; }
    section.tldr .tarjeta { background: var(--tldr-fondo); border: 1px solid var(--tldr-borde); border-radius: 14px; padding: 15px 20px 4px; }
    section.tldr .etiqueta { font-size: 11.5px; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; color: var(--tldr-texto); margin-bottom: 5px; }
    section.tldr p { font-size: 16px; line-height: 1.58; }
    .tabla { border: 1px solid var(--linea); border-radius: 12px; overflow: hidden; margin: 4px 0 16px; }
    table { width: 100%; border-collapse: collapse; font-size: 14px; line-height: 1.5; }
    th { text-align: left; font-size: 11.5px; font-weight: 600; letter-spacing: .04em; text-transform: uppercase;
      color: var(--tenue); background: var(--caja); padding: 9px 14px; }
    td { padding: 10px 14px; border-top: 1px solid var(--linea); vertical-align: top; }
    ul.tareas { border: 1px solid var(--linea); border-radius: 12px; padding: 2px 16px; }
    ul.tareas > li { padding: 11px 0 11px 30px; margin: 0; border-top: 1px solid var(--linea); }
    ul.tareas > li:first-child { border-top: 0; }
    ul.tareas > li::before { left: 0; top: 14px; width: 17px; height: 17px; border-radius: 5px; background: none;
      border: 1.5px solid var(--tenue); opacity: .75; box-sizing: border-box; }
    .chips { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 6px; }
    .chip { display: inline-flex; align-items: center; gap: 5px; font-size: 12.5px; line-height: 1.45; color: var(--suave);
      background: var(--caja); border-radius: 999px; padding: 2px 10px 2px 8px; }
    .chip svg { width: 12px; height: 12px; flex: none; opacity: .7; }
    .chip .nota { font-size: 1em; }
    section.correo .tarjeta { border: 1px solid var(--linea); border-radius: 14px; padding: 0 22px 8px; }
    .asunto { font-weight: 600; padding: 13px 0 11px; border-bottom: 1px solid var(--linea); margin: 0 -22px 14px; padding-left: 22px; padding-right: 22px; }
    .asunto span { color: var(--tenue); font-weight: 500; margin-right: 8px; }
    .vacio { text-align: center; color: var(--tenue); margin: 12vh auto 0; max-width: 420px; }
    .vacio-titulo { font-size: 17px; font-weight: 600; color: var(--texto); margin-bottom: 6px; }
    .leyenda { display: flex; gap: 8px; margin: -10px 0 22px; }
    .persona { font-size: 12.5px; font-weight: 600; color: var(--c); background: var(--c-fondo); border-radius: 999px; padding: 2px 10px; }
    .turno { display: grid; grid-template-columns: 52px 1fr; gap: 12px; align-items: start; margin-top: 12px; }
    .turno.sigue { margin-top: 4px; }
    .hora { font-size: 12px; color: var(--tenue); font-variant-numeric: tabular-nums; text-align: right; padding-top: 9px; }
    .burbuja { background: var(--c-fondo); border-radius: 14px; padding: 7px 14px 9px; justify-self: start; }
    .quien { font-size: 12.5px; font-weight: 650; color: var(--c); margin-bottom: 1px; }
    .sigue .quien { display: none; }
    .sigue .burbuja { padding-top: 8px; }
    .c-azul { --c: var(--azul); --c-fondo: var(--azul-fondo); }
    .c-verde { --c: var(--verde); --c-fondo: var(--verde-fondo); }
    .c-morado { --c: var(--morado); --c-fondo: var(--morado-fondo); }
    .c-naranja { --c: var(--naranja); --c-fondo: var(--naranja-fondo); }
    """
}

/// Íconos dibujados a mano (en la página no están los SF Symbols), del grosor de los del Mac.
private enum Icono {
    private static func svg(_ cuerpo: String, grosor: String = "1.6") -> String {
        #"<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="\#(grosor)" stroke-linecap="round" stroke-linejoin="round">\#(cuerpo)</svg>"#
    }
    static let casa = svg(#"<path d="M3.5 8.8 10 3.4l6.5 5.4v6.7a1.5 1.5 0 0 1-1.5 1.5h-2.8v-4.6H7.8V17H5a1.5 1.5 0 0 1-1.5-1.5z"/>"#)
    static let lista = svg(#"<rect x="2.5" y="3.5" width="15" height="13" rx="2.6"/><path d="M8.6 7.6h5.6M8.6 10h5.6M8.6 12.4h5.6"/><circle cx="6" cy="7.6" r=".55" fill="currentColor"/><circle cx="6" cy="10" r=".55" fill="currentColor"/><circle cx="6" cy="12.4" r=".55" fill="currentColor"/>"#)
    static let video = svg(#"<rect x="2.3" y="5.3" width="10.8" height="9.4" rx="2.2"/><path d="m13.1 8.6 4.6-2.5v7.8l-4.6-2.5z"/>"#)
    static let microfono = svg(#"<rect x="7.4" y="2.6" width="5.2" height="9.6" rx="2.6"/><path d="M4.7 9.6a5.3 5.3 0 0 0 10.6 0M10 14.9v2.6"/>"#)
    static let lupa = svg(#"<circle cx="8.8" cy="8.8" r="5.3"/><path d="m12.8 12.8 4 4"/>"#, grosor: "1.8")
    static let chevron = svg(#"<path d="m7.5 4.5 5.5 5.5-5.5 5.5"/>"#, grosor: "1.8")
    static let atras = svg(#"<path d="M12.5 4.5 7 10l5.5 5.5"/>"#, grosor: "1.9")
    static let sobre = svg(#"<rect x="2.5" y="4.5" width="15" height="11" rx="2.2"/><path d="m3.2 5.6 6.8 5.2 6.8-5.2"/>"#)
    static let copiar = svg(#"<rect x="6.8" y="6.8" width="10" height="10.5" rx="2"/><path d="M13.2 6.8V4.7a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v6.4a2 2 0 0 0 2 2h1.8"/>"#)
    static let carpeta = svg(#"<path d="M2.6 6.2a2 2 0 0 1 2-2h3l1.9 1.9h5.9a2 2 0 0 1 2 2v6.4a2 2 0 0 1-2 2H4.6a2 2 0 0 1-2-2z"/>"#)
}

// MARK: - Markdown → HTML

/// Un conversor chico, hecho a la medida de lo que escribe procesar.py: títulos, viñetas, listas numeradas,
/// tablas, **negrita**, "Tema: …" como subtítulo y párrafos. Todo el texto se escapa antes de armar el HTML.
enum Markdown {
    /// Saca la primera línea (el título: "# Título · fecha" o "Minuta: Título · fecha"), que va en el encabezado.
    static func sinTitulo(_ texto: String) -> [String] {
        var lineas = texto.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        while let primera = lineas.first, primera.trimmingCharacters(in: .whitespaces).isEmpty { lineas.removeFirst() }
        if let primera = lineas.first, !primera.hasPrefix("## ") { lineas.removeFirst() }
        return lineas
    }

    static func html(_ lineas: [String]) -> String {
        var html = ""
        var parrafo: [String] = []
        var lista: (etiqueta: String, items: [String])?
        var tabla: [String] = []
        var meta: [(String, String)] = []
        var seccion: String?          // clase de la sección abierta ("", "tldr", "tareas", "correo")
        var antesDeSecciones = true

        func cerrarParrafo() {
            guard !parrafo.isEmpty else { return }
            html += "<p>" + parrafo.map(enLinea).joined(separator: "<br>") + "</p>\n"
            parrafo = []
        }
        func cerrarLista() {
            guard let l = lista else { return }
            let tareas = seccion == "tareas" && l.etiqueta == "ul"
            html += tareas ? "<ul class=\"tareas\">" : "<\(l.etiqueta)>"
            html += l.items.map { "<li>\(conClave($0))</li>" }.joined()
            html += "</\(l.etiqueta)>\n"
            lista = nil
        }
        func cerrarTabla() {
            guard !tabla.isEmpty else { return }
            html += armarTabla(tabla, comoTareas: seccion == "tareas")
            tabla = []
        }
        func cerrarMeta() {
            guard !meta.isEmpty else { return }
            html += "<dl class=\"meta\">" + meta.map { "<dt>\(escapar($0.0))</dt><dd>\(enLinea($0.1))</dd>" }.joined() + "</dl>\n"
            meta = []
        }
        func cerrarTodo() { cerrarParrafo(); cerrarLista(); cerrarTabla(); cerrarMeta() }
        func cerrarSeccion() {
            guard let s = seccion else { return }
            html += (s == "tldr" || s == "correo" ? "</div>" : "") + "</section>\n"
            seccion = nil
        }

        for cruda in lineas {
            let linea = cruda.trimmingCharacters(in: .whitespaces)
            if !linea.hasPrefix("|") { cerrarTabla() }
            if linea.isEmpty {
                cerrarParrafo(); cerrarLista()
                continue
            }
            if linea.hasPrefix("#") && !linea.hasPrefix("###"), let titulo = linea.grupos(#"^#{1,2}\s+(.+)$"#)?.first {
                cerrarTodo(); cerrarSeccion()
                antesDeSecciones = false
                let clave = titulo.lowercased()
                let clase = clave.contains("tl;dr") ? "tldr"
                    : (clave.hasPrefix("tareas") || clave.hasPrefix("próximos pasos")) ? "tareas"
                    : clave.contains("correo") ? "correo" : ""
                seccion = clase
                html += "<section class=\"\(clase)\">"
                switch clase {
                case "tldr": html += "<div class=\"tarjeta\"><div class=\"etiqueta\">\(escapar(titulo))</div>"
                case "correo": html += "<h2>\(enLinea(titulo))</h2><div class=\"tarjeta\">"
                default: html += "<h2>\(enLinea(titulo))</h2>"
                }
                html += "\n"
            } else if let titulo = linea.grupos(#"^#{3,6}\s+(.+)$"#)?.first {
                cerrarTodo()
                html += "<h3>\(enLinea(titulo))</h3>\n"
            } else if let tema = linea.grupos(#"^Tema:\s*(.+)$"#)?.first {
                cerrarTodo()
                html += "<h3 class=\"tema\">\(enLinea(tema))</h3>\n"
            } else if let item = linea.grupos(#"^[-*•]\s+(.*)$"#)?.first {
                cerrarParrafo(); cerrarMeta()
                if lista?.etiqueta != "ul" { cerrarLista(); lista = ("ul", []) }
                lista?.items.append(item)
            } else if let item = linea.grupos(#"^\d+[.)]\s+(.*)$"#)?.first {
                cerrarParrafo(); cerrarMeta()
                if lista?.etiqueta != "ol" { cerrarLista(); lista = ("ol", []) }
                lista?.items.append(item)
            } else if linea.hasPrefix("|") {
                cerrarParrafo(); cerrarLista(); cerrarMeta()
                tabla.append(linea)
            } else if antesDeSecciones, let par = linea.grupos(#"^([A-ZÁÉÍÓÚÑ][\p{L} ]{1,22}):\s+(.+)$"#), par.count == 2 {
                cerrarParrafo(); cerrarLista()
                meta.append((par[0], par[1]))
            } else if seccion == "correo", let asunto = linea.grupos(#"^Asunto:\s*(.*)$"#)?.first {
                cerrarTodo()
                html += "<div class=\"asunto\"><span>Asunto</span>\(enLinea(asunto))</div>\n"
            } else {
                cerrarLista(); cerrarMeta()
                parrafo.append(linea)
            }
        }
        cerrarTodo()
        cerrarSeccion()
        return html
    }

    /// Tabla markdown → tabla limpia. En "Tareas", si la primera columna es la tarea, va como lista con casillas.
    private static func armarTabla(_ lineas: [String], comoTareas: Bool) -> String {
        let filas = lineas.map { linea -> [String] in
            var celdas = linea.trimmingCharacters(in: .whitespaces)
            if celdas.hasPrefix("|") { celdas.removeFirst() }
            if celdas.hasSuffix("|") { celdas.removeLast() }
            return celdas.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }.filter { fila in !fila.allSatisfy { $0.range(of: #"^:?-{2,}:?$"#, options: .regularExpression) != nil } }
        guard let cabecera = filas.first else { return "" }
        let cuerpo = filas.dropFirst()

        if comoTareas, let primera = cabecera.first?.lowercased(), primera.hasPrefix("tarea") || primera.hasPrefix("acci") {
            var html = "<ul class=\"tareas\">"
            for fila in cuerpo {
                let chips = fila.indices.dropFirst().compactMap { i -> String? in
                    let valor = fila[i]
                    guard !valor.isEmpty, valor != "—", valor != "-" else { return nil }
                    let nombre = i < cabecera.count ? cabecera[i].lowercased() : ""
                    let icono = nombre.hasPrefix("respons") ? iconoPersona : nombre.hasPrefix("fecha") || nombre.hasPrefix("plazo") ? iconoCalendario : ""
                    return "<span class=\"chip\">\(icono)<span>\(enLinea(valor))</span></span>"
                }
                html += "<li><div>\(enLinea(fila.first ?? ""))</div>"
                html += chips.isEmpty ? "" : "<div class=\"chips\">\(chips.joined())</div>"
                html += "</li>"
            }
            return html + "</ul>\n"
        }

        var html = "<div class=\"tabla\"><table><thead><tr>"
        html += cabecera.map { "<th>\(enLinea($0))</th>" }.joined() + "</tr></thead><tbody>"
        for fila in cuerpo {
            html += "<tr>" + cabecera.indices.map { "<td>\(enLinea($0 < fila.count ? fila[$0] : ""))</td>" }.joined() + "</tr>"
        }
        return html + "</tbody></table></div>\n"
    }

    /// La transcripción ("[HH:MM:SS] Nombre: texto") como conversación: la hora en gris y cada persona con su color.
    static func dialogo(_ texto: String) -> String {
        var turnos: [(hora: String, quien: String, texto: String)] = []
        for linea in texto.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let limpia = linea.trimmingCharacters(in: .whitespaces)
            if let g = limpia.grupos(#"^\[(\d{1,2}):(\d{2}):(\d{2})\]\s*([^:]{1,40}):\s?(.*)$"#), g.count == 5 {
                let hora = (Int(g[0]) ?? 0) > 0 ? "\(Int(g[0]) ?? 0):\(g[1]):\(g[2])" : "\(g[1]):\(g[2])"
                turnos.append((hora, g[3].trimmingCharacters(in: .whitespaces), g[4]))
            } else if !limpia.isEmpty, !turnos.isEmpty {
                turnos[turnos.count - 1].texto += " " + limpia   // sigue la línea anterior
            }
        }
        guard !turnos.isEmpty else {
            return Markdown.html(sinTitulo(texto))
        }
        // "Llamada" siempre en verde; el resto, en orden de aparición (el primero, normalmente tú, en azul).
        var colores: [String: String] = ["Llamada": "c-verde"]
        let paleta = ["c-azul", "c-morado", "c-naranja"]
        var orden: [String] = []
        for t in turnos where !orden.contains(t.quien) {
            orden.append(t.quien)
            if colores[t.quien] == nil { colores[t.quien] = paleta[(orden.filter { $0 != "Llamada" }.count - 1) % paleta.count] }
        }
        var html = "<div class=\"leyenda\">"
        html += orden.map { "<span class=\"persona \(colores[$0] ?? "c-azul")\">\(escapar($0))</span>" }.joined()
        html += "</div><div class=\"dialogo\">"
        var anterior = ""
        for t in turnos {
            let sigue = t.quien == anterior
            anterior = t.quien
            html += "<div class=\"turno \(colores[t.quien] ?? "c-azul")\(sigue ? " sigue" : "")\">"
            html += "<div class=\"hora\">\(escapar(t.hora))</div>"
            html += "<div class=\"burbuja\"><div class=\"quien\">\(escapar(t.quien))</div><div>\(enLinea(t.texto))</div></div></div>"
        }
        return html + "</div>"
    }

    // MARK: En línea

    static func escapar(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// **negrita**, `código`, y los "(por confirmar)" / "(sugerida)" en color suave para que se noten las dudas.
    static func enLinea(_ s: String) -> String {
        escapar(s)
            .reemplazando(#"\*\*(.+?)\*\*"#, por: "<strong>$1</strong>")
            .reemplazando(#"`([^`]+)`"#, por: "<code>$1</code>")
            .reemplazando(#"\(([^()]*(?:por confirmar|sugerida|por definir)[^()]*)\)"#, por: "<span class=\"nota\">($1)</span>")
            .reemplazando(#"(\d{4})-(\d{2})-(\d{2})"#, por: "$1\u{2011}$2\u{2011}$3")   // que "2026-10-21" no se corte en dos líneas
    }

    /// En las viñetas, "Fecha: martes…" deja la palabra antes de los dos puntos en negrita.
    private static func conClave(_ s: String) -> String {
        if let g = s.grupos(#"^([A-ZÁÉÍÓÚÑ][\p{L} ]{1,18}):\s+(.+)$"#), g.count == 2 {
            return "<strong>\(escapar(g[0])):</strong> \(enLinea(g[1]))"
        }
        return enLinea(s)
    }

    private static let iconoPersona = #"<svg viewBox="0 0 16 16"><circle cx="8" cy="5.2" r="2.7" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M2.8 13.8c.6-2.6 2.7-4.1 5.2-4.1s4.6 1.5 5.2 4.1" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>"#
    private static let iconoCalendario = #"<svg viewBox="0 0 16 16"><rect x="2.2" y="3.2" width="11.6" height="10.6" rx="2.2" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M2.2 6.7h11.6M5.4 1.8v2.6M10.6 1.8v2.6" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>"#
}

fileprivate extension String {
    func reemplazando(_ patron: String, por plantilla: String) -> String {
        guard let re = try? NSRegularExpression(pattern: patron) else { return self }
        return re.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: plantilla)
    }

    /// Los grupos entre paréntesis del patrón, si la línea calza; nil si no calza.
    func grupos(_ patron: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: patron),
              let m = re.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return (1..<max(m.numberOfRanges, 1)).map { i in
            Range(m.range(at: i), in: self).map { String(self[$0]) } ?? ""
        }
    }
}
