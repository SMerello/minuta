import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

// Minuta: un ícono en la barra de arriba del Mac.
// Grabar → Detener → transcribe con Whisper en tu Mac → resume con Claude → deja todo en ~/Reuniones.
// Dictar (mantén ⌃⌥ para algo corto, o ⌃⌥Espacio para algo largo) → transcribe y escribe el texto donde está el cursor.

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item: NSStatusItem = {
        // macOS pone los íconos nuevos a la izquierda de los demás; en los Mac con muesca eso suele
        // quedar escondido tras la cámara, y los primeros que esconde cuando la app del frente tiene
        // muchos menús son los de la izquierda. La primera vez lo dejo lo más a la derecha posible;
        // si después lo mueves con ⌘ + arrastrar, macOS recuerda tu posición.
        let clave = "NSStatusItem Preferred Position minuta"
        let actual = UserDefaults.standard.object(forKey: clave) as? Double
        if actual == nil || actual == 150 {   // 150 era la posición inicial de la versión 0.1
            UserDefaults.standard.set(1.0, forKey: clave)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "minuta"
        return item
    }()
    private let grabador = Grabador()
    private var grabandoDesde: Date?     // se corre hacia adelante lo que dure cada pausa
    private var pausadoDesde: Date?
    private var reloj: Timer?
    private var enProceso: [String: String] = [:]   // carpeta → etapa actual
    private var enVivo: [String: Process] = [:]      // carpeta → procesar.py transcribiendo mientras se graba
    private var ultimoResumen: URL?
    private var atajos: [Atajo] = []
    private let dictado = Dictado()
    private var transcribiendoDictado = false
    private var ordenandoDictado = false      // Claude está ordenando un dictado largo
    private let indicador = Indicador()
    private var modoIndicador: Indicador.Modo?
    private let ajustes = Ajustes()
    private let mantener = Mantener()
    private let espacio = EspacioTermina()
    private let llamadas = Llamadas()
    private let oferta = Oferta()
    private var avisoMicrofono = false       // ya avisé en esta grabación que el micrófono no capta
    private let ventanaReuniones = VentanaReuniones()

    func applicationDidFinishLaunching(_ notification: Notification) {
        ServidorWhisper.compartido.limpiarRestos()
        NSApp.mainMenu = menuPrincipal()
        registrarAtajos()
        ajustes.alSoltarAtajos = { [weak self] in self?.atajos = [] }
        ajustes.alRegistrarAtajos = { [weak self] in self?.registrarAtajos() ?? (false, false) }
        ajustes.mantener = mantener
        mantener.alEmpezar = { [weak self] in
            guard let self, !self.dictado.activo, !self.transcribiendoDictado else { return false }
            self.alternarDictado()
            return self.dictado.activo
        }
        mantener.alSoltar = { [weak self] in
            guard let self, let desde = self.dictado.desde else { return }
            // Un toque cortito no alcanza a ser un dictado: se descarta sin avisar "No escuché nada".
            if Date().timeIntervalSince(desde) < 0.6 { self.descartarDictado(sonido: false) } else { self.alternarDictado() }
        }
        mantener.alInterrumpir = { [weak self] in self?.descartarDictado(sonido: false) }
        mantener.vigilar()
        llamadas.alEmpezar = { [weak self] app in
            guard let self, self.grabandoDesde == nil else { return }
            // Si el calendario dice qué reunión es, la nombra: "Empezó «Reunión de prueba» en Google Meet".
            let texto: String
            if let evento = Calendario.reunionAhora() {
                let nombre = evento.titulo.count > 40 ? String(evento.titulo.prefix(39)).trimmingCharacters(in: .whitespaces) + "…" : evento.titulo
                texto = "Empezó «\(nombre)» en \(evento.app ?? app). ¿La grabo?"
            } else {
                texto = "Empezó una llamada en \(app). ¿La grabo?"
            }
            self.oferta.mostrar(texto, boton: "Grabar", durante: 25) { [weak self] in
                guard let self, self.grabandoDesde == nil else { return }
                self.grabar()
            }
        }
        llamadas.alTerminar = { [weak self] in
            guard let self, self.grabandoDesde != nil else { return }
            self.oferta.mostrar("Parece que la llamada terminó.", boton: "Detener y resumir", durante: 60) { [weak self] in
                self?.detener()
            }
        }
        llamadas.vigilar()
        ajustes.llamadas = llamadas
        // El permiso del calendario se pide una sola vez: después macOS recuerda la respuesta.
        if Calendario.encendido, Calendario.sinPreguntar { Calendario.pedirPermiso() }
        ventanaReuniones.alGrabar = { [weak self] in
            guard let self, self.grabandoDesde == nil else { return }
            self.grabar()
        }
        ventanaReuniones.alDetener = { [weak self] in self?.detener() }
        ventanaReuniones.alAbrirAjustes = { [weak self] in self?.ajustes.mostrar() }
        dictado.alOrdenar = { [weak self] in
            self?.ordenandoDictado = true
            self?.refrescar()
        }
        espacio.alApretar = { [weak self] in
            guard let self, self.dictado.activo, !self.mantener.grabando else { return }
            self.alternarDictado()
        }
        grabador.alCortarse = { [weak self] error in
            DispatchQueue.main.async { self?.grabacionCortada(error) }
        }
        // Un solo reloj para el tiempo de grabación y de dictado (se ve en el menú y al pasar el mouse).
        reloj = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.revisarMicrofono()
            guard let self, self.grabandoDesde != nil || self.dictado.activo else { return }
            self.refrescar()
        }
        indicador.alDetener = { [weak self] modo in
            if modo == .reunion { self?.detener() } else { self?.alternarDictado() }
        }
        indicador.alPausar = { [weak self] in self?.alternarPausa() }
        indicador.nivel = { [weak self] modo in
            guard let self else { return 0 }
            return modo == .reunion ? self.grabador.nivelMicrofono : self.dictado.nivel()
        }
        indicador.alDescartar = { [weak self] modo in
            if modo == .reunion { self?.descartarReunion() } else { self?.descartarDictado() }
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refrescar()
        if !UserDefaults.standard.bool(forKey: "vioAyuda") {
            UserDefaults.standard.set(true, forKey: "vioAyuda")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.ayuda() }
        }
    }

    /// Si abres Minuta otra vez (Dock, Spotlight, Finder) mientras corre, abre su ventana, como otras apps de notas.
    /// Ahí está todo lo del menú (grabar, dictados, reuniones), por si el ícono queda tras la muesca.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ventanaReuniones.mostrar()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Volumen.devolver()
        ServidorWhisper.compartido.apagar()
        guard grabandoDesde != nil else { return }
        let listo = DispatchSemaphore(value: 0)
        Task { await grabador.detener(); listo.signal() }
        _ = listo.wait(timeout: .now() + 3)
    }

    /// Registra los atajos globales que dicen los Ajustes y cuenta cuáles aceptó macOS.
    /// Suelta primero los anteriores: si no, volver a registrar la misma combinación falla.
    @discardableResult
    private func registrarAtajos() -> (reunion: Bool, dictado: Bool) {
        atajos = []
        let reunion = Atajo(Atajos.reunion) { [weak self] in
            guard let self else { return }
            // Si sostuviste ⌃⌥ un rato antes de la R, partió un dictado corto que no querías.
            if self.mantener.grabando { self.descartarDictado(sonido: false) }
            if self.grabandoDesde == nil { self.grabar() } else { self.detener() }
        }
        let dictar = Atajo(Atajos.dictado) { [weak self] in
            guard let self else { return }
            // Estabas manteniendo ⌃⌥ y apretaste Espacio: el mismo dictado sigue como largo, sin cortarse.
            if self.mantener.grabando, self.dictado.activo {
                self.mantener.olvidar()
                self.refrescar()   // ahora es largo: Espacio lo termina
            } else {
                self.alternarDictado()
            }
        }
        atajos = [reunion, dictar]
        refrescar()   // el toolTip muestra los atajos
        return (reunion.registrado, dictar.registrado)
    }

    // MARK: Menú

    /// El menú de arriba a la izquierda cuando la ventana de Minuta está al frente.
    private func menuPrincipal() -> NSMenu {
        let principal = NSMenu()
        let app = NSMenu(title: "Minuta")
        app.addItem(withTitle: "Acerca de Minuta", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(accion("Ajustes…", #selector(abrirAjustes), tecla: ","))
        app.addItem(.separator())
        app.addItem(withTitle: "Ocultar Minuta", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(accion("Salir de Minuta", #selector(salir), tecla: "q"))
        let item = NSMenuItem()
        item.submenu = app
        principal.addItem(item)
        return principal
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let r = Atajos.reunion.texto, d = Atajos.dictado.texto
        if let desde = grabandoDesde {
            menu.addItem(titulo("\(pausadoDesde == nil ? "Grabando" : "En pausa") · \(Self.duracion(desde: desde, hasta: pausadoDesde))"))
            menu.addItem(accion(pausadoDesde == nil ? "Pausar" : "Seguir grabando", #selector(alternarPausa)))
            menu.addItem(accion("Detener y resumir  (\(r))", #selector(detener), tecla: "s"))
        } else {
            menu.addItem(accion("Grabar reunión  (\(r))", #selector(grabar), tecla: "r"))
        }
        if let desde = dictado.desde {
            menu.addItem(accion("Terminar dictado · \(Self.duracion(desde: desde))  (\(d))", #selector(alternarDictado)))
        } else if transcribiendoDictado {
            menu.addItem(titulo(ordenandoDictado ? "Ordenando el dictado con Claude…" : "Escribiendo el dictado…"))
        } else {
            menu.addItem(accion("Dictar  (\(d))", #selector(alternarDictado), tecla: "d"))
        }
        if !dictado.activo, !transcribiendoDictado, Dictado.ultimo() != nil {
            menu.addItem(accion("Copiar último dictado", #selector(copiarUltimoDictado)))
        }
        for (carpeta, etapa) in enProceso.sorted(by: { $0.key < $1.key }) {
            menu.addItem(titulo("\((carpeta as NSString).lastPathComponent): \(etapa)"))
        }
        menu.addItem(.separator())
        menu.addItem(accion("Procesar un audio…", #selector(procesarArchivo)))
        if ultimoResumen != nil {
            menu.addItem(accion("Abrir último resumen", #selector(abrirUltimo)))
        }
        menu.addItem(accion("Abrir Minuta…", #selector(abrirReuniones), tecla: "o"))
        menu.addItem(accion("Abrir carpeta de reuniones", #selector(abrirCarpeta)))
        menu.addItem(accion("Ajustes…", #selector(abrirAjustes), tecla: ","))
        menu.addItem(accion("Cómo se usa", #selector(ayuda)))
        menu.addItem(.separator())
        menu.addItem(accion("Salir", #selector(salir), tecla: "q"))
    }

    private func titulo(_ texto: String) -> NSMenuItem {
        let i = NSMenuItem(title: texto, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func accion(_ texto: String, _ selector: Selector, tecla: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: texto, action: selector, keyEquivalent: tecla)
        i.target = self
        return i
    }

    private func refrescar() {
        ventanaReuniones.actualizarGrabando(grabandoDesde != nil)   // el botón Grabar / Detener de la ventana
        guard let boton = item.button else { return }
        // Espacio termina solo el dictado largo: nunca en reuniones ni en el dictado corto (ahí se suelta ⌃⌥).
        espacio.activo = dictado.activo && !mantener.grabando
        let modo: Indicador.Modo?
        if dictado.activo {
            modo = .dictado
            boton.image = Self.simbolo("mic.circle.fill", color: .systemOrange)
            boton.toolTip = "Dictando · \(Atajos.dictado.texto) para terminar"
        } else if transcribiendoDictado {
            modo = ordenandoDictado ? .ordenando : .escribiendo
            boton.image = Self.simbolo("ellipsis.circle.fill", color: .systemOrange)
            boton.toolTip = ordenandoDictado ? "Ordenando el dictado con Claude…" : "Escribiendo el dictado…"
        } else if let desde = grabandoDesde {
            modo = .reunion
            if pausadoDesde == nil {
                boton.image = Self.simbolo("record.circle.fill", color: .systemRed)
                boton.toolTip = "Grabando · \(Self.duracion(desde: desde))"
            } else {
                boton.image = Self.simbolo("pause.circle.fill", color: .systemGray)
                boton.toolTip = "En pausa · \(Self.duracion(desde: desde, hasta: pausadoDesde))"
            }
        } else {
            modo = nil
            boton.image = Self.simbolo(enProceso.isEmpty ? "record.circle" : "ellipsis.circle", color: nil)
            boton.toolTip = "Minuta · \(Atajos.reunion.texto) grabar reunión · \(Atajos.dictado.texto) dictar"
        }
        // Siempre del mismo ancho (sin el contador): si crece, macOS lo esconde cuando no cabe junto a la muesca.
        boton.title = ""
        boton.imagePosition = .imageOnly

        // La barra flotante en pantalla: se arma al cambiar de modo y después solo se actualiza el tiempo.
        if modo != modoIndicador {
            modoIndicador = modo
            switch modo {
            case .dictado?: indicador.mostrar(.dictado, desde: dictado.desde ?? Date())
            case .escribiendo?: indicador.mostrar(.escribiendo)
            case .ordenando?: indicador.mostrar(.ordenando)
            case .reunion?: indicador.mostrar(.reunion, desde: grabandoDesde ?? Date(), pausadoDesde: pausadoDesde)
            case nil: indicador.ocultar()
            }
        } else {
            indicador.actualizar()
        }
    }

    /// Ícono de la barra. Con color, va como imagen normal (las "template" las pinta macOS y pierden el rojo).
    private static func simbolo(_ nombre: String, color: NSColor?) -> NSImage? {
        let base = NSImage(systemSymbolName: nombre, accessibilityDescription: "Minuta")?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        guard let color else {
            base?.isTemplate = true
            return base
        }
        let pintada = base?.withSymbolConfiguration(.init(paletteColors: [color]))
        pintada?.isTemplate = false
        return pintada
    }

    private static func duracion(desde: Date, hasta: Date? = nil) -> String {
        let s = Int((hasta ?? Date()).timeIntervalSince(desde))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: Dictar

    private func descartarDictado(sonido: Bool = true) {
        mantener.olvidar()
        guard dictado.activo else { return }
        dictado.descartar()
        if sonido { NSSound(named: "Bottle")?.play() }
        refrescar()
    }

    @objc private func copiarUltimoDictado() {
        guard let texto = Dictado.ultimo() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(texto, forType: .string)
        avisar("Último dictado copiado", texto.count > 90 ? String(texto.prefix(90)) + "…" : texto)
    }

    /// Guarda el dictado en el historial y lo escribe donde está el cursor.
    private func entregar(_ texto: String, original: String? = nil) {
        // Otra pasada por tu lista de correcciones: Claude, al ordenar, a veces vuelve a la palabra mal escrita.
        let texto = Correcciones.aplicar(texto)
        Dictado.guardar(texto, original: original)
        if !Dictado.escribir(texto) {
            avisar("Texto copiado", "Pégalo con ⌘V. Para que se escriba solo, activa Minuta en Ajustes del Sistema › Privacidad y seguridad › Accesibilidad.")
        }
    }

    @objc private func alternarDictado() {
        if dictado.activo {
            mantener.olvidar()
            NSSound(named: "Pop")?.play()
            transcribiendoDictado = true
            refrescar()
            dictado.terminar { [weak self] resultado in
                guard let self else { return }
                self.transcribiendoDictado = false
                self.ordenandoDictado = false
                self.refrescar()
                switch resultado {
                case .success(let entrega?):
                    self.entregar(entrega.texto, original: entrega.original)
                    if entrega.sinOrdenar { self.avisar("No pude ordenar el dictado", "Lo escribí tal cual lo dijiste.") }
                case .success(nil):
                    self.avisar("No escuché nada", "Revisa qué micrófono está usando el Mac (por ejemplo, los AirPods).")
                case .failure(let error):
                    self.avisar("No pude transcribir el dictado", error.localizedDescription)
                }
            }
        } else {
            guard !transcribiendoDictado else { return }
            do {
                try dictado.empezar()
                NSSound(named: "Tink")?.play()
                refrescar()
            } catch {
                avisar("No pude empezar a dictar", error.localizedDescription)
            }
        }
    }

    // MARK: Grabar

    @objc private func grabar() {
        let formato = DateFormatter()
        formato.dateFormat = "yyyy-MM-dd-HHmm"
        let carpeta = Config.carpetaReuniones.appendingPathComponent(formato.string(from: Date()))
        do {
            try FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        } catch {
            avisar("No pude crear la carpeta", error.localizedDescription)
            return
        }
        Task { @MainActor in
            do {
                try await grabador.iniciar(en: carpeta)
                grabandoDesde = Date()
                // Transcribe mientras hablan: al detener solo falta el último trozo y el resumen.
                enVivo[carpeta.path] = procesar(["--carpeta", carpeta.path, "--en-vivo"], clave: carpeta.path)
                // De qué app fue (la ventana de reuniones lo muestra: "13:51 · Google Meet") y, si está en el
                // calendario, qué reunión es y a quién invitaron (procesar.py se lo pasa a Claude).
                var info: [String: Any] = llamadas.appActual.map { ["app": $0] } ?? [:]
                if let evento = Calendario.reunionAhora() {
                    info.merge(evento.info) { _, delCalendario in delCalendario }   // el link de video manda
                }
                if !info.isEmpty, let datos = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]) {
                    try? datos.write(to: carpeta.appendingPathComponent("info.json"))
                }
                avisoMicrofono = false
                indicador.aviso = nil
                oferta.ocultar()
                refrescar()
            } catch {
                try? FileManager.default.removeItem(at: carpeta)
                avisar("No pude empezar a grabar",
                       "Revisa en Ajustes del Sistema › Privacidad y seguridad que Minuta tenga permiso de Micrófono y de Grabación de pantalla y audio del sistema. (\(error.localizedDescription))")
            }
        }
    }

    @objc private func detener() {
        guard grabandoDesde != nil, let carpeta = grabador.carpeta else { return }
        Task { @MainActor in
            await grabador.detener()
            grabandoDesde = nil
            pausadoDesde = nil
            refrescar()
            // El que transcribe en vivo termina el último trozo y resume; si no está, se procesa todo ahora.
            if let vivo = enVivo[carpeta.path], vivo.isRunning {
                FileManager.default.createFile(atPath: carpeta.appendingPathComponent(".detener").path, contents: nil)
            } else {
                procesar(["--carpeta", carpeta.path], clave: carpeta.path)
            }
        }
    }

    /// A los 30 s de reunión, si tu micrófono no ha captado nada (como con los AirPods guardados), avisa
    /// diciendo qué micrófono está usando el Mac. Si después capta voz, el aviso de la barra se quita.
    private func revisarMicrofono() {
        guard let desde = grabandoDesde, pausadoDesde == nil else { return }
        let pico = grabador.picoMicrofono
        if pico >= 0.1 {
            indicador.aviso = nil
            return
        }
        guard !avisoMicrofono, Date().timeIntervalSince(desde) >= 30 else { return }
        avisoMicrofono = true
        indicador.aviso = "Sin voz"
        let cual = Microfono.nombre().map { "El Mac está usando «\($0)»." } ?? ""
        avisar("No te estoy escuchando", "En 30 s tu micrófono no captó voz. \(cual) Cámbialo en Ajustes del Sistema › Sonido › Entrada.")
    }

    /// Pausa o sigue la reunión. En pausa no se graba nada y el reloj se detiene.
    @objc private func alternarPausa() {
        guard let desde = grabandoDesde else { return }
        if let pausa = pausadoDesde {
            grabador.seguir()
            grabandoDesde = desde.addingTimeInterval(Date().timeIntervalSince(pausa))
            pausadoDesde = nil
        } else {
            grabador.pausar()
            pausadoDesde = Date()
        }
        indicador.mostrar(.reunion, desde: grabandoDesde ?? desde, pausadoDesde: pausadoDesde)
        refrescar()
    }

    /// Botón ✕ de la barra: corta la reunión sin resumir y manda la carpeta a la Papelera (se puede recuperar).
    private func descartarReunion() {
        guard grabandoDesde != nil else { return }
        let alerta = NSAlert()
        alerta.messageText = "¿Descartar esta grabación?"
        alerta.informativeText = "El audio se va a la Papelera y no se hace el resumen."
        alerta.addButton(withTitle: "Descartar")
        alerta.addButton(withTitle: "Seguir grabando")
        NSApp.activate(ignoringOtherApps: true)
        guard alerta.runModal() == .alertFirstButtonReturn,
              grabandoDesde != nil, let carpeta = grabador.carpeta else { return }
        Task { @MainActor in
            await grabador.detener()
            grabandoDesde = nil
            pausadoDesde = nil
            refrescar()
            enVivo[carpeta.path]?.terminate()
            try? FileManager.default.trashItem(at: carpeta, resultingItemURL: nil)
        }
    }

    private func grabacionCortada(_ error: Error) {
        guard grabandoDesde != nil else { return }
        avisar("La grabación se cortó", "Guardé lo grabado hasta ahora y lo voy a procesar. (\(error.localizedDescription))")
        detener()
    }

    // MARK: Procesar (transcribir + resumir)

    @objc private func procesarArchivo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.message = "Elige una grabación o nota de voz para transcribir y resumir"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        procesar(["--archivo", url.path], clave: url.path)
    }

    /// Corre `procesar.py`, que va avisando por pantalla "ETAPA: ..." y al final "LISTO: <resumen.md>".
    @discardableResult
    private func procesar(_ argumentos: [String], clave: String) -> Process? {
        guard let script = Bundle.main.url(forResource: "procesar", withExtension: "py") else {
            avisar("Falta procesar.py", "La app está incompleta: vuelve a instalarla con scripts/instalar.sh.")
            return nil
        }
        enProceso[clave] = "empezando…"
        refrescar()

        let proceso = Process()
        proceso.executableURL = URL(fileURLWithPath: Config.python)
        proceso.arguments = ["-u", script.path] + argumentos
        var entorno = ProcessInfo.processInfo.environment
        entorno["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (entorno["PATH"] ?? "/usr/bin:/bin")
        proceso.environment = entorno
        let salida = Pipe()
        proceso.standardOutput = salida
        proceso.standardError = salida

        // Todo lo que lee la salida pasa por esta cola, para no mezclar hilos.
        let colaSalida = DispatchQueue(label: "minuta.salida")
        var pendiente = ""
        var resumen: URL?
        var ultimoError = ""
        func consumir(_ datos: Data) {
            guard !datos.isEmpty, let texto = String(data: datos, encoding: .utf8) else { return }
            pendiente += texto
            while let salto = pendiente.firstIndex(of: "\n") {
                let linea = String(pendiente[..<salto])
                pendiente = String(pendiente[pendiente.index(after: salto)...])
                if linea.hasPrefix("ETAPA: ") {
                    let etapa = String(linea.dropFirst(7))
                    DispatchQueue.main.async { [weak self] in
                        if self?.enProceso[clave] != nil { self?.enProceso[clave] = etapa }
                    }
                } else if linea.hasPrefix("LISTO: ") {
                    resumen = URL(fileURLWithPath: String(linea.dropFirst(7)))
                } else if linea.hasPrefix("ERROR: ") {
                    ultimoError = String(linea.dropFirst(7))
                }
            }
        }
        salida.fileHandleForReading.readabilityHandler = { h in
            let datos = h.availableData
            colaSalida.async { consumir(datos) }
        }
        proceso.terminationHandler = { [weak self] p in
            salida.fileHandleForReading.readabilityHandler = nil
            let resto = salida.fileHandleForReading.readDataToEndOfFile()
            colaSalida.sync { consumir(resto) }
            let (resumen, ultimoError) = colaSalida.sync { (resumen, ultimoError) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.enProceso[clave] = nil
                self.enVivo[clave] = nil
                self.refrescar()
                // Descartaste la reunión (la carpeta está en la Papelera): no hay nada que avisar.
                if resumen == nil && !FileManager.default.fileExists(atPath: clave) { return }
                if let resumen {
                    self.ultimoResumen = resumen
                    self.avisar(p.terminationStatus == 0 ? "Resumen listo" : "Transcripción lista (el resumen falló)",
                                p.terminationStatus == 0 ? resumen.deletingLastPathComponent().lastPathComponent : ultimoError)
                } else {
                    self.avisar("No pude procesar la reunión", ultimoError.isEmpty ? "Mira proceso.log en la carpeta." : ultimoError)
                }
            }
        }
        do {
            try proceso.run()
            return proceso
        } catch {
            enProceso[clave] = nil
            refrescar()
            avisar("No pude procesar la reunión", error.localizedDescription)
            return nil
        }
    }

    // MARK: Otros

    /// "Cómo se usa" (y la primera vez que se abre Minuta): la ventana en su página de ayuda, con los permisos.
    @objc private func ayuda() { ventanaReuniones.mostrar(seccion: .comoSeUsa) }

    @objc private func abrirAjustes() { ajustes.mostrar() }

    @objc private func abrirReuniones() { ventanaReuniones.mostrar() }

    /// Abre la ventana Reuniones con la última reunión procesada ya elegida.
    @objc private func abrirUltimo() {
        if let ultimoResumen { ventanaReuniones.mostrar(seleccionar: ultimoResumen.deletingLastPathComponent()) }
    }

    @objc private func abrirCarpeta() {
        try? FileManager.default.createDirectory(at: Config.carpetaReuniones, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Config.carpetaReuniones)
    }

    @objc private func salir() {
        if grabandoDesde != nil {
            Task { @MainActor in
                await grabador.detener()
                grabandoDesde = nil
                NSApp.terminate(nil)
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    /// Notificación del sistema vía osascript (no necesita que la app esté firmada por Apple).
    private func avisar(_ titulo: String, _ texto: String) {
        func escapar(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(escapar(texto))\" with title \"Minuta\" subtitle \"\(escapar(titulo))\""]
        try? p.run()
    }
}

/// Lee `~/Library/Application Support/Minuta/config.json` (el mismo que usa procesar.py).
enum Config {
    static let soporte = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Minuta")

    private static let json: [String: Any] = {
        let url = soporte.appendingPathComponent("config.json")
        guard let datos = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: datos) as? [String: Any] else { return [:] }
        return obj
    }()

    static var carpetaReuniones: URL {
        let ruta = (json["carpeta"] as? String) ?? "~/Reuniones"
        return URL(fileURLWithPath: (ruta as NSString).expandingTildeInPath)
    }

    static var modelo: String {
        ((json["modelo"] as? String) ?? soporte.appendingPathComponent("ggml-large-v3-turbo.bin").path)
            .replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    static var idioma: String { (json["idioma"] as? String) ?? "es" }
    /// Para el saludo de la ventana ("Buenas tardes, Santiago.").
    static var nombre: String { (json["nombre"] as? String) ?? "Santiago" }
    static var vocabulario: String { (json["vocabulario"] as? String) ?? "" }
    /// Modelo de Claude para ordenar los dictados largos ("sonnet" ordena mejor que "haiku" y tarda casi lo mismo).
    static var modeloDictado: String { (json["modelo_dictado"] as? String) ?? "sonnet" }

    static var python: String {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    }
}

// Modo de prueba: `Minuta.app/Contents/MacOS/Minuta --prueba <segundos> <carpeta>` graba y sale, sin procesar.
if let i = CommandLine.arguments.firstIndex(of: "--prueba"), CommandLine.arguments.count > i + 2 {
    let segundos = Double(CommandLine.arguments[i + 1]) ?? 5
    let carpeta = URL(fileURLWithPath: CommandLine.arguments[i + 2])
    try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
    let grabador = Grabador()
    Task {
        do {
            try await grabador.iniciar(en: carpeta)
            print("grabando \(segundos) s en \(carpeta.path)")
            try await Task.sleep(nanoseconds: UInt64(segundos * 1e9))
            await grabador.detener()
            print("listo")
            exit(0)
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegado = App()
app.delegate = delegado
app.setActivationPolicy(.accessory)
app.run()
