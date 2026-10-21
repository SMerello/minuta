import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

// Minuta: un ícono en la barra de arriba del Mac.
// Grabar → Detener → transcribe con Whisper en tu Mac → resume con Claude → deja todo en ~/Reuniones.
// Dictar (⌃⌥D) → transcribe y escribe el texto donde está el cursor.

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
    private var grabandoDesde: Date?
    private var reloj: Timer?
    private var enProceso: [String: String] = [:]   // carpeta → etapa actual
    private var ultimoResumen: URL?
    private var atajos: [Atajo] = []
    private let dictado = Dictado()
    private var transcribiendoDictado = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        atajos = [
            Atajo(tecla: kVK_ANSI_R) { [weak self] in
                guard let self else { return }
                if self.grabandoDesde == nil { self.grabar() } else { self.detener() }
            },
            Atajo(tecla: kVK_ANSI_D) { [weak self] in self?.alternarDictado() },
        ]
        grabador.alCortarse = { [weak self] error in
            DispatchQueue.main.async { self?.grabacionCortada(error) }
        }
        // Un solo reloj para el tiempo de grabación y de dictado (se ve en el menú y al pasar el mouse).
        reloj = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.grabandoDesde != nil || self.dictado.activo else { return }
            self.refrescar()
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refrescar()
    }

    /// Si abres Minuta otra vez (Spotlight, Finder) mientras corre, muestra el menú donde está el mouse.
    /// Sirve cuando el ícono queda escondido detrás de la muesca de la pantalla.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let menu = item.menu else { return false }
        menuNeedsUpdate(menu)
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard grabandoDesde != nil else { return }
        let listo = DispatchSemaphore(value: 0)
        Task { await grabador.detener(); listo.signal() }
        _ = listo.wait(timeout: .now() + 3)
    }

    // MARK: Menú

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let desde = grabandoDesde {
            menu.addItem(titulo("Grabando · \(Self.duracion(desde: desde))"))
            menu.addItem(accion("Detener y resumir  (⌃⌥R)", #selector(detener), tecla: "s"))
        } else {
            menu.addItem(accion("Grabar reunión  (⌃⌥R)", #selector(grabar), tecla: "r"))
        }
        if let desde = dictado.desde {
            menu.addItem(accion("Terminar dictado · \(Self.duracion(desde: desde))  (⌃⌥D)", #selector(alternarDictado)))
        } else if transcribiendoDictado {
            menu.addItem(titulo("Escribiendo el dictado…"))
        } else {
            menu.addItem(accion("Dictar  (⌃⌥D)", #selector(alternarDictado), tecla: "d"))
        }
        for (carpeta, etapa) in enProceso.sorted(by: { $0.key < $1.key }) {
            menu.addItem(titulo("\((carpeta as NSString).lastPathComponent): \(etapa)"))
        }
        menu.addItem(.separator())
        menu.addItem(accion("Procesar un audio…", #selector(procesarArchivo)))
        if ultimoResumen != nil {
            menu.addItem(accion("Abrir último resumen", #selector(abrirUltimo)))
        }
        menu.addItem(accion("Abrir carpeta de reuniones", #selector(abrirCarpeta)))
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
        guard let boton = item.button else { return }
        if dictado.activo || transcribiendoDictado {
            boton.image = NSImage(systemSymbolName: dictado.activo ? "mic.fill" : "ellipsis.circle",
                                  accessibilityDescription: "Dictando")
            boton.contentTintColor = .systemOrange
            boton.toolTip = "Dictando · ⌃⌥D para terminar"
        } else if let desde = grabandoDesde {
            boton.image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Grabando")
            boton.contentTintColor = .systemRed
            boton.toolTip = "Grabando · \(Self.duracion(desde: desde))"
        } else {
            let simbolo = enProceso.isEmpty ? "record.circle" : "ellipsis.circle"
            boton.image = NSImage(systemSymbolName: simbolo, accessibilityDescription: "Minuta")
            boton.contentTintColor = nil
            boton.toolTip = "Minuta · ⌃⌥R grabar reunión · ⌃⌥D dictar"
        }
        // Siempre del mismo ancho (sin el contador): si crece, macOS lo esconde cuando no cabe junto a la muesca.
        boton.title = ""
        boton.imagePosition = .imageOnly
    }

    private static func duracion(desde: Date) -> String {
        let s = Int(Date().timeIntervalSince(desde))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: Dictar

    @objc private func alternarDictado() {
        if dictado.activo {
            NSSound(named: "Pop")?.play()
            transcribiendoDictado = true
            refrescar()
            dictado.terminar { [weak self] resultado in
                guard let self else { return }
                self.transcribiendoDictado = false
                self.refrescar()
                switch resultado {
                case .success(let texto?):
                    Dictado.guardar(texto)
                    if !Dictado.escribir(texto) {
                        self.avisar("Texto copiado", "Pégalo con ⌘V. Para que se escriba solo, activa Minuta en Ajustes del Sistema › Privacidad y seguridad › Accesibilidad.")
                    }
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
                refrescar()
                avisar("Grabando", "Para detener: ⌃⌥R o el menú de Minuta.")
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
            refrescar()
            procesar(["--carpeta", carpeta.path], clave: carpeta.path)
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
    private func procesar(_ argumentos: [String], clave: String) {
        guard let script = Bundle.main.url(forResource: "procesar", withExtension: "py") else {
            avisar("Falta procesar.py", "La app está incompleta: vuelve a instalarla con scripts/instalar.sh.")
            return
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
                self.refrescar()
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
        } catch {
            enProceso[clave] = nil
            refrescar()
            avisar("No pude procesar la reunión", error.localizedDescription)
        }
    }

    // MARK: Otros

    @objc private func abrirUltimo() {
        if let ultimoResumen { NSWorkspace.shared.open(ultimoResumen) }
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
    static var vocabulario: String { (json["vocabulario"] as? String) ?? "" }

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
