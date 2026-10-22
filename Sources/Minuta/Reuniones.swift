import AppKit
import WebKit

/// Ventana "Reuniones": a la izquierda la lista de reuniones (la más nueva arriba, agrupadas por día) y a la
/// derecha la reunión elegida, bonita, con pestañas Notas, Minuta y Transcripción. Así no hay que abrir los .md sueltos.
/// Vuelve a leer las carpetas al abrirse, al volver al frente y cada 5 s mientras se ve:
/// la reunión que se termina de procesar aparece sola.
final class VentanaReuniones: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Pestana {
        case notas, minuta, transcripcion
        var nombre: String {
            switch self {
            case .notas: return "Notas"
            case .minuta: return "Minuta"
            case .transcripcion: return "Transcripción"
            }
        }
    }

    private enum Fila {
        case dia(String)
        case reunion(Reunion)
    }

    private(set) var ventana: NSWindow?
    let web: WKWebView = {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false   // solo muestro texto
        let web = WKWebView(frame: .zero, configuration: config)
        web.underPageBackgroundColor = .textBackgroundColor
        return web
    }()
    private let tabla = NSTableView()
    private let buscar = NSSearchField()
    private let pestanas = NSSegmentedControl(labels: [], trackingMode: .selectOne, target: nil, action: nil)
    private lazy var copiarCorreoBoton = VentanaReuniones.boton("Copiar correo", "envelope", self, #selector(copiarCorreo))
    private lazy var copiarNotasBoton = VentanaReuniones.boton("Copiar notas", "doc.on.doc", self, #selector(copiarNotas))
    private lazy var abrirCarpetaBoton = VentanaReuniones.boton("Abrir carpeta", "folder", self, #selector(abrirCarpeta))
    private let aviso = NSView()
    private let avisoTexto = NSTextField(labelWithString: "Copiado")
    private var avisoReloj: Timer?
    private var reloj: Timer?

    private var todas: [Reunion] = []
    private var guardadas: [String: Reunion] = [:]   // carpeta → reunión ya leída (se vuelve a leer si cambia algo)
    private var filas: [Fila] = []
    private var elegida: String?                     // ruta de la carpeta elegida
    private var pestana: Pestana = .notas
    private var visibles: [Pestana] = []
    private var ultimoHTML = ""
    private var callado = false                      // cambio la selección yo, no el usuario

    /// Abre la ventana (o la trae al frente). Con `carpeta`, deja elegida esa reunión.
    func mostrar(seleccionar carpeta: URL? = nil) {
        let w = ventana ?? armarVentana()
        ventana = w
        if let carpeta { elegida = carpeta.resolvingSymlinksInPath().path }
        recargar(forzar: true)
        NSApp.activate(ignoringOtherApps: true)   // la app es .accessory: sin esto la ventana queda detrás
        w.makeKeyAndOrderFront(nil)
        if reloj == nil {
            let r = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                guard let self, let w = self.ventana, w.isVisible, w.occlusionState.contains(.visible) else { return }
                self.recargar()
            }
            RunLoop.main.add(r, forMode: .common)
            reloj = r
        }
    }

    /// Cambia de pestaña (también lo usan las capturas de prueba).
    func elegir(_ nueva: Pestana) {
        pestana = nueva
        mostrarReunion()
    }

    // MARK: Armar

    private func armarVentana() -> NSWindow {
        let w = VentanaConTeclas(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                 backing: .buffered, defer: false)
        w.title = "Reuniones"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.alBuscar = { [weak self] in self?.ventana?.makeFirstResponder(self?.buscar) }

        let lista = NSViewController()
        lista.view = armarLista()
        let detalle = NSViewController()
        detalle.view = armarDetalle()
        let division = NSSplitViewController()
        let lado = NSSplitViewItem(sidebarWithViewController: lista)
        lado.minimumThickness = 230
        lado.maximumThickness = 380
        lado.canCollapse = false
        let centro = NSSplitViewItem(viewController: detalle)
        centro.minimumThickness = 520
        division.addSplitViewItem(lado)
        division.addSplitViewItem(centro)
        division.splitView.autosaveName = "Reuniones"
        division.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        w.contentViewController = division
        w.contentMinSize = NSSize(width: 760, height: 480)
        w.initialFirstResponder = tabla   // con el foco en la lista, las flechas cambian de reunión

        // Tamaño y lugar: los de la última vez; la primera vez, 1000×700 al centro.
        if !w.setFrameUsingName("Reuniones") {
            w.setContentSize(NSSize(width: 1000, height: 700))
            w.center()
        }
        w.setFrameAutosaveName("Reuniones")
        return w
    }

    private func armarLista() -> NSView {
        buscar.placeholderString = "Buscar en reuniones"
        buscar.target = self
        buscar.action = #selector(buscarCambio)
        buscar.translatesAutoresizingMaskIntoConstraints = false

        let columna = NSTableColumn(identifier: .init("reunion"))
        columna.resizingMask = .autoresizingMask
        tabla.addTableColumn(columna)
        tabla.headerView = nil
        tabla.style = .sourceList
        tabla.floatsGroupRows = false
        tabla.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tabla.backgroundColor = .clear
        tabla.dataSource = self
        tabla.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = tabla
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let vista = NSView()
        vista.addSubview(buscar)
        vista.addSubview(scroll)
        NSLayoutConstraint.activate([
            buscar.topAnchor.constraint(equalTo: vista.topAnchor, constant: 12),
            buscar.leadingAnchor.constraint(equalTo: vista.leadingAnchor, constant: 12),
            buscar.trailingAnchor.constraint(equalTo: vista.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: buscar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: vista.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: vista.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: vista.bottomAnchor),
        ])
        return vista
    }

    private func armarDetalle() -> NSView {
        pestanas.target = self
        pestanas.action = #selector(pestanaCambio)

        let acciones = NSStackView(views: [copiarCorreoBoton, copiarNotasBoton, abrirCarpetaBoton])
        acciones.spacing = 8
        let barra = Fondo()
        for v in [pestanas, acciones] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            barra.addSubview(v)
        }
        let linea = NSBox()
        linea.boxType = .separator

        // El aviso "Copiado": una pastilla oscura abajo al centro que se desvanece sola.
        aviso.wantsLayer = true
        aviso.layer?.cornerRadius = 9
        aviso.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        aviso.alphaValue = 0
        avisoTexto.font = .systemFont(ofSize: 13, weight: .semibold)
        avisoTexto.textColor = .white
        avisoTexto.translatesAutoresizingMaskIntoConstraints = false
        aviso.addSubview(avisoTexto)

        let vista = Fondo()
        for v in [barra, linea, web, aviso] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            vista.addSubview(v)
        }
        NSLayoutConstraint.activate([
            barra.topAnchor.constraint(equalTo: vista.topAnchor),
            barra.leadingAnchor.constraint(equalTo: vista.leadingAnchor),
            barra.trailingAnchor.constraint(equalTo: vista.trailingAnchor),
            barra.heightAnchor.constraint(equalToConstant: 52),
            pestanas.leadingAnchor.constraint(equalTo: barra.leadingAnchor, constant: 20),
            pestanas.centerYAnchor.constraint(equalTo: barra.centerYAnchor),
            acciones.trailingAnchor.constraint(equalTo: barra.trailingAnchor, constant: -16),
            acciones.centerYAnchor.constraint(equalTo: barra.centerYAnchor),
            acciones.leadingAnchor.constraint(greaterThanOrEqualTo: pestanas.trailingAnchor, constant: 12),
            linea.topAnchor.constraint(equalTo: barra.bottomAnchor),
            linea.leadingAnchor.constraint(equalTo: vista.leadingAnchor),
            linea.trailingAnchor.constraint(equalTo: vista.trailingAnchor),
            web.topAnchor.constraint(equalTo: linea.bottomAnchor),
            web.leadingAnchor.constraint(equalTo: vista.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: vista.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: vista.bottomAnchor),
            aviso.centerXAnchor.constraint(equalTo: web.centerXAnchor),
            aviso.bottomAnchor.constraint(equalTo: vista.bottomAnchor, constant: -24),
            avisoTexto.leadingAnchor.constraint(equalTo: aviso.leadingAnchor, constant: 16),
            avisoTexto.trailingAnchor.constraint(equalTo: aviso.trailingAnchor, constant: -16),
            avisoTexto.topAnchor.constraint(equalTo: aviso.topAnchor, constant: 7),
            avisoTexto.bottomAnchor.constraint(equalTo: aviso.bottomAnchor, constant: -7),
        ])
        return vista
    }

    private static func boton(_ titulo: String, _ simbolo: String, _ destino: AnyObject, _ accion: Selector) -> NSButton {
        let imagen = NSImage(systemSymbolName: simbolo, accessibilityDescription: nil) ?? NSImage()
        let b = NSButton(title: titulo, image: imagen, target: destino, action: accion)
        b.imagePosition = .imageLeading
        b.bezelStyle = .rounded
        return b
    }

    // MARK: Leer las carpetas

    /// Lee las carpetas de reuniones. Solo vuelve a leer las que cambiaron, y solo redibuja si algo cambió.
    private func recargar(forzar: Bool = false) {
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
        guard forzar || nuevas.map(\.firma) != todas.map(\.firma) else { return }
        todas = nuevas

        // Al terminar de resumir, procesar.py le agrega el tema al nombre de la carpeta: sigo en la misma reunión.
        if let elegida, guardadas[elegida] == nil {
            let antes = (elegida as NSString).lastPathComponent
            self.elegida = todas.first { $0.carpeta.lastPathComponent.hasPrefix(antes + "-") }?.carpeta.path
        }
        armarFilas()
    }

    /// Arma la lista (con los días como títulos) según lo que dice el buscador, y vuelve a marcar la elegida.
    private func armarFilas() {
        let texto = buscar.stringValue.trimmingCharacters(in: .whitespaces)
        var nuevas: [Fila] = []
        var dia = ""
        for r in todas where texto.isEmpty || r.contiene(texto) {
            let esteDia = Reunion.nombreDia(r.fecha)
            if esteDia != dia {
                nuevas.append(.dia(esteDia))
                dia = esteDia
            }
            nuevas.append(.reunion(r))
        }
        filas = nuevas
        callado = true
        tabla.reloadData()
        let indice = filas.firstIndex { if case .reunion(let r) = $0 { return r.carpeta.path == elegida } else { return false } }
            ?? filas.firstIndex { if case .reunion = $0 { return true } else { return false } }
        if let indice {
            tabla.selectRowIndexes([indice], byExtendingSelection: false)
            tabla.scrollRowToVisible(indice)
            if case .reunion(let r) = filas[indice] { elegida = r.carpeta.path }
        } else {
            tabla.deselectAll(nil)
        }
        callado = false
        mostrarReunion()
    }

    private var reunionElegida: Reunion? {
        guard tabla.selectedRow >= 0, tabla.selectedRow < filas.count,
              case .reunion(let r) = filas[tabla.selectedRow] else { return nil }
        return r
    }

    // MARK: Mostrar

    /// Pone las pestañas y botones de la reunión elegida y la dibuja en la parte derecha.
    private func mostrarReunion() {
        guard let r = reunionElegida else {
            pestanas.isHidden = true
            for b in [copiarCorreoBoton, copiarNotasBoton, abrirCarpetaBoton] { b.isHidden = true }
            let busqueda = buscar.stringValue.trimmingCharacters(in: .whitespaces)
            cargar(busqueda.isEmpty
                   ? Pagina.vacia("Todavía no hay reuniones", "Graba una desde el ícono de Minuta, arriba en la barra del Mac. Cuando termine de resumirse, aparece aquí sola.")
                   : Pagina.vacia("Sin resultados", "No encontré reuniones con «\(busqueda)»."))
            return
        }
        visibles = [.notas] + (r.minuta != nil ? [.minuta] : []) + [.transcripcion]
        if !visibles.contains(pestana) { pestana = .notas }
        pestanas.isHidden = false
        pestanas.segmentCount = visibles.count
        for (i, p) in visibles.enumerated() {
            pestanas.setLabel(p.nombre, forSegment: i)
            pestanas.setWidth(0, forSegment: i)   // 0: el ancho justo para el texto
        }
        pestanas.selectedSegment = visibles.firstIndex(of: pestana) ?? 0
        copiarCorreoBoton.isHidden = r.correo == nil
        copiarNotasBoton.isHidden = false
        copiarNotasBoton.isEnabled = r.resumen != nil
        abrirCarpetaBoton.isHidden = false

        switch pestana {
        case .notas: cargar(Pagina.notas(r))
        case .minuta: cargar(Pagina.minuta(r))
        case .transcripcion: cargar(Pagina.transcripcion(r))
        }
    }

    /// Si es lo mismo que ya se ve, no recarga (así no salta al principio cada 5 s).
    private func cargar(_ html: String) {
        guard html != ultimoHTML else { return }
        ultimoHTML = html
        web.loadHTMLString(html, baseURL: nil)
    }

    // MARK: Acciones

    @objc private func buscarCambio() { armarFilas() }

    @objc private func pestanaCambio() {
        let i = pestanas.selectedSegment
        guard i >= 0, i < visibles.count else { return }
        elegir(visibles[i])
    }

    @objc private func copiarCorreo() {
        guard let correo = reunionElegida?.correo else { return }
        copiar(correo)
    }

    @objc private func copiarNotas() {
        guard let resumen = reunionElegida?.resumen else { return }
        copiar(resumen)
    }

    @objc private func abrirCarpeta() {
        guard let r = reunionElegida else { return }
        NSWorkspace.shared.open(r.carpeta)
    }

    private func copiar(_ texto: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(texto, forType: .string)
        avisoReloj?.invalidate()
        aviso.alphaValue = 1
        avisoReloj = Timer.scheduledTimer(withTimeInterval: 1.3, repeats: false) { [weak self] _ in
            NSAnimationContext.runAnimationGroup { contexto in
                contexto.duration = 0.3
                self?.aviso.animator().alphaValue = 0
            }
        }
    }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { filas.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .dia = filas[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .reunion = filas[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .dia = filas[row] { return 28 }
        return 50
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch filas[row] {
        case .dia(let nombre):
            let id = NSUserInterfaceItemIdentifier("dia")
            let celda = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = id
                let t = NSTextField(labelWithString: "")
                t.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(t)
                c.textField = t
                NSLayoutConstraint.activate([
                    t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                    t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                    t.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            celda.textField?.stringValue = nombre
            return celda
        case .reunion(let r):
            let id = NSUserInterfaceItemIdentifier("reunion")
            let celda = tableView.makeView(withIdentifier: id, owner: nil) as? FilaReunion ?? FilaReunion(id)
            celda.mostrar(r)
            return celda
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !callado else { return }
        elegida = reunionElegida?.carpeta.path
        mostrarReunion()
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) { recargar() }

    func windowWillClose(_ notification: Notification) {
        reloj?.invalidate()
        reloj = nil
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

    private static let archivos = ["resumen.md", "minuta.md", "transcripcion.md", "proceso.log"]

    init(carpeta: URL, firma: String) {
        self.carpeta = carpeta
        self.firma = firma
        func leer(_ nombre: String) -> String? {
            try? String(contentsOf: carpeta.appendingPathComponent(nombre), encoding: .utf8)
        }
        resumen = leer("resumen.md")
        minuta = leer("minuta.md")
        transcripcion = leer("transcripcion.md")

        let nombre = carpeta.lastPathComponent
        let creada = (try? carpeta.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        fecha = Reunion.formatoCarpeta.date(from: String(nombre.prefix(15))) ?? creada
        titulo = resumen.flatMap(Reunion.titulo(de:)) ?? Reunion.tema(de: nombre)
        duracion = transcripcion?.components(separatedBy: "\n").first?
            .components(separatedBy: " · ").last
            .flatMap { $0.hasSuffix("min") ? $0.trimmingCharacters(in: .whitespaces) : nil }

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

// MARK: - Piezas de la ventana

/// Una fila de la lista: título, hora y duración (o "procesando…"), y la marca "Venta" si hay minuta.
private final class FilaReunion: NSTableCellView {
    private let titulo = NSTextField(labelWithString: "")
    private let detalle = NSTextField(labelWithString: "")
    private let venta = Insignia(texto: "Venta")

    init(_ id: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        identifier = id
        titulo.font = .systemFont(ofSize: 13, weight: .medium)
        titulo.lineBreakMode = .byTruncatingTail
        titulo.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detalle.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        detalle.textColor = .secondaryLabelColor
        detalle.lineBreakMode = .byTruncatingTail
        detalle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        venta.setContentCompressionResistancePriority(.required, for: .horizontal)
        textField = titulo
        for v in [titulo, detalle, venta] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            titulo.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titulo.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titulo.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            detalle.topAnchor.constraint(equalTo: titulo.bottomAnchor, constant: 2),
            detalle.leadingAnchor.constraint(equalTo: titulo.leadingAnchor),
            venta.leadingAnchor.constraint(equalTo: detalle.trailingAnchor, constant: 6),
            venta.centerYAnchor.constraint(equalTo: detalle.centerYAnchor),
            venta.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("no se usa") }

    // Fila elegida con fondo de color: el texto gris pasaría a no leerse.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let resaltada = backgroundStyle == .emphasized
            detalle.textColor = resaltada ? .alternateSelectedControlTextColor : .secondaryLabelColor
            venta.resaltada = resaltada
        }
    }

    func mostrar(_ r: Reunion) {
        titulo.stringValue = r.titulo
        detalle.stringValue = ([r.hora] + [r.estado ?? r.duracion].compactMap { $0 }).joined(separator: " · ")
        venta.isHidden = !r.esVenta
        toolTip = r.carpeta.lastPathComponent
    }
}

/// Pastillita de color con texto (la marca "Venta"). Se dibuja sola, así cambia bien entre claro y oscuro.
private final class Insignia: NSView {
    private let texto: String
    /// Sobre la fila elegida (fondo de color) va en blanco, que el verde ahí no se lee.
    var resaltada = false { didSet { needsDisplay = true } }
    private var atributos: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: resaltada ? NSColor.white : NSColor.systemGreen]
    }

    init(texto: String) {
        self.texto = texto
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("no se usa") }

    override var intrinsicContentSize: NSSize {
        let tam = (texto as NSString).size(withAttributes: atributos)
        return NSSize(width: ceil(tam.width) + 12, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        (resaltada ? NSColor.white.withAlphaComponent(0.22) : NSColor.systemGreen.withAlphaComponent(0.16)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let tam = (texto as NSString).size(withAttributes: atributos)
        (texto as NSString).draw(at: NSPoint(x: (bounds.width - tam.width) / 2, y: (bounds.height - tam.height) / 2),
                                 withAttributes: atributos)
    }
}

/// Fondo del color del texto (blanco en claro, gris muy oscuro en oscuro), igual que las páginas de la derecha.
private final class Fondo: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
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

// MARK: - Páginas (HTML)

/// Arma las páginas que se ven a la derecha: un HTML con estilo propio, que sigue el modo claro u oscuro del Mac.
enum Pagina {
    static func notas(_ r: Reunion) -> String {
        guard let resumen = r.resumen else { return procesando(r) }
        return envolver(encabezado(r) + Markdown.html(Markdown.sinTitulo(resumen)))
    }

    static func minuta(_ r: Reunion) -> String {
        guard let minuta = r.minuta else { return procesando(r) }
        return envolver(encabezado(r, sub: "Minuta comercial") + Markdown.html(Markdown.sinTitulo(minuta)))
    }

    static func transcripcion(_ r: Reunion) -> String {
        guard let texto = r.transcripcion else {
            return envolver(encabezado(r) + vacio("Todavía no hay transcripción", r.etapa.map { "Ahora: \($0)." } ?? ""))
        }
        return envolver(encabezado(r, sub: "Transcripción") + Markdown.dialogo(texto))
    }

    static func vacia(_ titulo: String, _ texto: String) -> String {
        envolver(vacio(titulo, texto))
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
        return envolver(encabezado(r) + vacio(titulo, detalle))
    }

    private static func encabezado(_ r: Reunion, sub: String? = nil) -> String {
        let venta = r.esVenta ? #"<span class="marca">Venta</span>"# : ""
        let antes = sub.map { #"<div class="sub">\#(Markdown.escapar($0))</div>"# } ?? ""
        return """
        <header>\(antes)<h1>\(Markdown.escapar(r.titulo))</h1>\
        <div class="fecha"><span>\(Markdown.escapar(r.fechaLarga))</span>\(venta)</div></header>
        """
    }

    private static func vacio(_ titulo: String, _ texto: String) -> String {
        #"<div class="vacio"><div class="vacio-titulo">\#(Markdown.escapar(titulo))</div><p>\#(Markdown.escapar(texto))</p></div>"#
    }

    private static func envolver(_ cuerpo: String) -> String {
        """
        <!doctype html><html lang="es"><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark"><style>\(estilo)</style></head>
        <body><main>\(cuerpo)</main></body></html>
        """
    }

    private static let estilo = """
    :root {
      --fondo: #ffffff; --texto: #1d1d1f; --suave: #48484a; --tenue: #86868b;
      --linea: rgba(0,0,0,.08); --caja: #f5f5f7; --nota: #a2670b;
      --tldr-fondo: #fff8e7; --tldr-borde: #f3e1ad; --tldr-texto: #9a5b00;
      --venta: #1f8a43; --venta-fondo: rgba(52,199,89,.14);
      --azul: #0a64c8; --azul-fondo: #edf4fe; --verde: #1d7f3e; --verde-fondo: #ecf7ef;
      --morado: #6e44c9; --morado-fondo: #f3eefc; --naranja: #b85a00; --naranja-fondo: #fdf2e5;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --fondo: #1e1e1e; --texto: #ececee; --suave: #c5c5ca; --tenue: #8d8d93;
        --linea: rgba(255,255,255,.09); --caja: #2a2a2d; --nota: #e2b259;
        --tldr-fondo: rgba(255,190,60,.09); --tldr-borde: rgba(255,190,60,.24); --tldr-texto: #f5c45e;
        --venta: #5fd27f; --venta-fondo: rgba(52,199,89,.16);
        --azul: #6db0ff; --azul-fondo: rgba(10,132,255,.15); --verde: #63d184; --verde-fondo: rgba(48,209,88,.13);
        --morado: #bf9cff; --morado-fondo: rgba(175,130,255,.15); --naranja: #ffb35c; --naranja-fondo: rgba(255,159,10,.14);
      }
    }
    * { box-sizing: border-box; }
    html { background: var(--fondo); }
    body { margin: 0; padding: 34px 44px 80px; background: var(--fondo); color: var(--texto);
      font: 15px/1.62 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
      -webkit-font-smoothing: antialiased; }
    main { max-width: 720px; margin: 0 auto; }
    header { margin-bottom: 26px; }
    .sub { font-size: 12px; font-weight: 600; letter-spacing: .06em; text-transform: uppercase; color: var(--tenue); margin-bottom: 4px; }
    h1 { font-size: 28px; line-height: 1.22; font-weight: 700; letter-spacing: -.022em; margin: 0 0 6px; }
    .fecha { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; color: var(--tenue); font-size: 13.5px; }
    .marca { font-size: 11.5px; font-weight: 600; color: var(--venta); background: var(--venta-fondo); border-radius: 999px; padding: 1px 9px; }
    h2 { font-size: 18px; line-height: 1.3; font-weight: 650; letter-spacing: -.012em; margin: 34px 0 10px; }
    h3 { font-size: 15px; font-weight: 600; margin: 22px 0 6px; }
    h3.tema { display: flex; align-items: center; gap: 9px; }
    h3.tema::before { content: ""; width: 3px; height: 15px; border-radius: 2px; background: var(--azul); opacity: .8; }
    p { margin: 0 0 12px; }
    strong { font-weight: 600; }
    code { font: 13px ui-monospace, Menlo, monospace; background: var(--caja); border-radius: 5px; padding: 1px 5px; }
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
    .vacio { text-align: center; color: var(--tenue); margin: 14vh auto 0; max-width: 420px; }
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
