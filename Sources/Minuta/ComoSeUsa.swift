import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics

/// La página "Cómo se usa" de la ventana Minuta (reemplaza al cartel de ayuda de antes). Arriba los permisos,
/// cada uno con ✓ si está o ⚠ y un botón "Activar" que lleva directo a su lugar en Ajustes del Sistema; después
/// cómo dictar y grabar con tus atajos de verdad, botones para abrir cada cosa que se cambia a mano (plantillas,
/// correcciones, config.json) y dónde queda todo. Los permisos se cambian afuera de Minuta, así que se vuelven
/// a mirar cada vez que la ventana se pinta (al volver al frente y cada 5 s).
enum Ayuda {
    struct Permiso {
        let id: String         // lo que manda el botón: "microfono", "pantalla", "accesibilidad", "calendario"
        let nombre: String
        let para: String
        let listo: Bool
    }

    /// Cómo están ahora los cuatro permisos. Ninguno de estos muestra un diálogo: solo miran.
    static func permisos() -> [Permiso] {
        [
            Permiso(id: "microfono", nombre: "Micrófono",
                    para: "Para escuchar tu voz al dictar y en las reuniones.",
                    listo: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized),
            Permiso(id: "pantalla", nombre: "Grabación de pantalla y audio del sistema",
                    para: "Para grabar lo que dicen los demás en la llamada. No graba la pantalla.",
                    listo: CGPreflightScreenCaptureAccess()),
            Permiso(id: "accesibilidad", nombre: "Accesibilidad",
                    para: "Para escribir el dictado donde está el cursor. Sin él, queda copiado y lo pegas con ⌘V.",
                    listo: AXIsProcessTrusted()),
            Permiso(id: "calendario", nombre: "Calendario",
                    para: "Para ponerle a cada reunión su nombre y sus invitados.",
                    listo: Calendario.conPermiso),
        ]
    }

    /// El panel de Privacidad y seguridad de cada permiso.
    private static let paneles = [
        "microfono": "Privacy_Microphone", "pantalla": "Privacy_ScreenCapture",
        "accesibilidad": "Privacy_Accessibility", "calendario": "Privacy_Calendars",
    ]

    /// Botón "Activar". Si macOS todavía no ha preguntado (micrófono y calendario), pregunta ahora; si ya
    /// preguntó y le dijiste que no, solo se puede cambiar en Ajustes del Sistema: abre ese panel justo.
    /// `listo` llega en el hilo principal, para volver a pintar la página con la respuesta.
    static func activar(_ id: String, listo: @escaping () -> Void) {
        if id == "microfono", AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { listo() } }
        } else if id == "calendario", Calendario.sinPreguntar {
            Calendario.pedirPermiso { _ in listo() }
        } else if let panel = paneles[id],
                  let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + panel) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Abrir archivos y carpetas

    /// Los botones de Personalizar y de Dónde queda todo. Los archivos que no existen se crean desde la
    /// plantilla que viene con la app, así siempre se abre algo para editar.
    static func abrir(_ cual: String) {
        switch cual {
        case "correcciones":
            Correcciones.asegurarArchivo()
            editar(Correcciones.archivo)
        case "plantilla":
            editar(copiaPropia("plantilla.md", de: "resumen"))      // procesar.py usa esta si existe
        case "dictado":
            editar(copiaPropia("dictado.md", de: "dictado"))        // Dictado.instruccionesParaOrdenar, igual
        case "config":
            editar(asegurarConfig())
        case "reuniones":
            mostrar(Config.carpetaReuniones)
        case "dictados":
            mostrar(Config.carpetaReuniones.appendingPathComponent("Dictados"))
        case "soporte":
            mostrar(Config.soporte)
        default:
            break
        }
    }

    /// Tu copia en Application Support; la primera vez, copiada de la que viene con la app.
    private static func copiaPropia(_ nombre: String, de plantilla: String) -> URL {
        let fm = FileManager.default
        let propia = Config.soporte.appendingPathComponent(nombre)
        if !fm.fileExists(atPath: propia.path),
           let original = Bundle.main.url(forResource: plantilla, withExtension: "md", subdirectory: "plantillas") {
            try? fm.createDirectory(at: Config.soporte, withIntermediateDirectories: true)
            try? fm.copyItem(at: original, to: propia)
        }
        return propia
    }

    /// config.json es opcional. Si no está, lo creo solo con lo que vale igual para la app y para procesar.py
    /// (el "nombre", por ejemplo, no: cada uno tiene el suyo por defecto y escribirlo cambiaría la transcripción).
    private static func asegurarConfig() -> URL {
        let fm = FileManager.default
        let url = Config.soporte.appendingPathComponent("config.json")
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: Config.soporte, withIntermediateDirectories: true)
            let inicial = """
            {
              "carpeta": "~/Reuniones",
              "idioma": "es",
              "resumen_con": "claude",
              "vocabulario": ""
            }

            """
            try? inicial.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// Siempre en TextEdit: un .md o un .json, con doble clic, pueden abrirse en Xcode o en nada.
    private static func editar(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        if FileManager.default.fileExists(atPath: textEdit.path) {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    private static func mostrar(_ carpeta: URL) {
        try? FileManager.default.createDirectory(at: carpeta, withIntermediateDirectories: true)
        NSWorkspace.shared.open(carpeta)
    }

    /// "/Users/santiago/Reuniones" → "~/Reuniones", para mostrarlo corto.
    static func corta(_ url: URL) -> String {
        let casa = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(casa + "/") ? "~" + url.path.dropFirst(casa.count) : url.path
    }

    // MARK: Íconos

    private static func svg(_ cuerpo: String, grosor: String = "1.6") -> String {
        #"<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="\#(grosor)" stroke-linecap="round" stroke-linejoin="round">\#(cuerpo)</svg>"#
    }
    /// El de la barra lateral (como el SF Symbol questionmark.circle).
    static let iconoNav = svg(#"<circle cx="10" cy="10" r="7.4"/><path d="M7.7 7.8a2.35 2.35 0 1 1 3.3 2.15c-.65.3-1 .8-1 1.45v.35"/><circle cx="10" cy="14.3" r=".55" fill="currentColor"/>"#)
    fileprivate static let bien = svg(#"<path d="m5.6 10.4 3 3 5.8-6.6"/>"#, grosor: "2.2")
    fileprivate static let falta = svg(#"<path d="M10 6v5"/><circle cx="10" cy="14" r=".7" fill="currentColor"/>"#, grosor: "2.2")
    fileprivate static let ajustes = svg(#"<path d="M3.5 6h5M12.5 6h4M3.5 14h2M9.5 14h7"/><circle cx="10.5" cy="6" r="2"/><circle cx="7.5" cy="14" r="2"/>"#)
    fileprivate static let correcciones = svg(#"<path d="M3 15.5 6.4 5h1.2l3.4 10.5M4.3 11.6h5.4"/><path d="m11.8 11.8 1.9 1.9 3.6-4.2"/>"#)
    fileprivate static let plantilla = svg(#"<path d="M5.5 2.8h6l3.5 3.5v9.4a1.5 1.5 0 0 1-1.5 1.5h-8a1.5 1.5 0 0 1-1.5-1.5V4.3a1.5 1.5 0 0 1 1.5-1.5z"/><path d="M11.3 2.9v3.6h3.6M7 10h6M7 13h4"/>"#)
    fileprivate static let dictado = svg(#"<path d="M3.5 4.5h13a1.5 1.5 0 0 1 1.5 1.5v6.5a1.5 1.5 0 0 1-1.5 1.5H9l-3.6 2.8V14H3.5A1.5 1.5 0 0 1 2 12.5V6a1.5 1.5 0 0 1 1.5-1.5z"/><path d="M6 9.2h8M6 11.4h5"/>"#)
    fileprivate static let llaves = svg(#"<path d="M7 3.3c-1.8 0-2.3.8-2.3 2.3v2c0 1-.6 1.9-1.6 2.4 1 .5 1.6 1.4 1.6 2.4v2c0 1.5.5 2.3 2.3 2.3M13 3.3c1.8 0 2.3.8 2.3 2.3v2c0 1 .6 1.9 1.6 2.4-1 .5-1.6 1.4-1.6 2.4v2c0 1.5-.5 2.3-2.3 2.3"/>"#)
    fileprivate static let carpeta = svg(#"<path d="M2.6 6.2a2 2 0 0 1 2-2h3l1.9 1.9h5.9a2 2 0 0 1 2 2v6.4a2 2 0 0 1-2 2H4.6a2 2 0 0 1-2-2z"/>"#)
    fileprivate static let pausa = svg(#"<path d="M7.5 5.5v9M12.5 5.5v9"/>"#, grosor: "2.2")
    fileprivate static let detener = #"<svg viewBox="0 0 20 20"><rect x="5.5" y="5.5" width="9" height="9" rx="1.6" fill="currentColor"/></svg>"#
    fileprivate static let cruz = svg(#"<path d="m6 6 8 8M14 6l-8 8"/>"#, grosor: "2")
    fileprivate static let cartel = svg(#"<rect x="2.3" y="5.3" width="10.8" height="9.4" rx="2.2"/><path d="m13.1 8.6 4.6-2.5v7.8l-4.6-2.5z"/>"#)
    fileprivate static let barritas = svg(#"<path d="M4 8.5v3M7.3 6v8M10.6 4v12M13.9 7v6M17 9v2"/>"#, grosor: "1.9")
    fileprivate static let reloj = svg(#"<circle cx="10" cy="10" r="7.2"/><path d="M10 6v4.3l2.8 1.8"/>"#)
    fileprivate static let notas = svg(#"<rect x="2.5" y="3.5" width="15" height="13" rx="2.6"/><path d="M6 7.6h8M6 10h8M6 12.4h5"/>"#)
    fileprivate static let calendario = svg(#"<rect x="2.8" y="4" width="14.4" height="13" rx="2.4"/><path d="M2.8 8.2h14.4M6.6 2.4v3M13.4 2.4v3"/>"#)
    fileprivate static let copiar = svg(#"<rect x="6.8" y="6.8" width="10" height="10.5" rx="2"/><path d="M13.2 6.8V4.7a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v6.4a2 2 0 0 0 2 2h1.8"/>"#)
    fileprivate static let candado = svg(#"<rect x="4" y="8.6" width="12" height="8.6" rx="2.2"/><path d="M6.8 8.6V6.3a3.2 3.2 0 0 1 6.4 0v2.3"/>"#)

    // MARK: Estilo

    /// Se suma al de la ventana (usa sus colores: --acento, --linea, --caja, --verde…).
    static let estilo = """
    :root { --ambar: #a35f00; --ambar-fondo: #fff3df; --verde-ok: #1d7f3e; --verde-ok-fondo: #e6f5ea; }
    @media (prefers-color-scheme: dark) {
      :root { --ambar: #ffb547; --ambar-fondo: rgba(255,159,10,.15); --verde-ok: #63d184; --verde-ok-fondo: rgba(48,209,88,.14); }
    }
    #ayuda .contenido { max-width: 820px; }
    .ayuda-cabeza { margin-bottom: 28px; }
    .bajada { margin: 10px 0 0; color: var(--suave); font-size: 15.5px; max-width: 640px; }
    .tarjeta-ayuda { border: 1px solid var(--linea); border-radius: 16px; padding: 22px 26px 20px; margin-bottom: 18px; }
    .tarjeta-cabeza { display: flex; align-items: center; gap: 12px; margin-bottom: 4px; }
    .tarjeta-cabeza .paso-numero { flex: none; width: 26px; height: 26px; border-radius: 50%; display: grid; place-items: center;
      background: var(--acento); color: var(--acento-texto); font-size: 13px; font-weight: 700; }
    .tarjeta-ayuda h2 { margin: 0; font-family: var(--serif); font-size: 23px; font-weight: 400; letter-spacing: -.008em; }
    .tarjeta-cabeza .estado { margin-left: auto; font-size: 12px; font-weight: 650; border-radius: 999px; padding: 3px 11px; white-space: nowrap; }
    .estado.ok { color: var(--verde-ok); background: var(--verde-ok-fondo); }
    .estado.falta { color: var(--ambar); background: var(--ambar-fondo); }
    .tarjeta-bajada { margin: 4px 0 12px 38px; color: var(--tenue); font-size: 13.5px; }

    .filas-ayuda > div { display: flex; align-items: center; gap: 14px; padding: 12px 0; border-top: 1px solid var(--linea); }
    .filas-ayuda > div:first-child { border-top: 0; }
    .senal { flex: none; width: 26px; height: 26px; border-radius: 50%; display: grid; place-items: center; }
    .senal svg { width: 15px; height: 15px; }
    .senal.ok { color: var(--verde-ok); background: var(--verde-ok-fondo); }
    .senal.falta { color: var(--ambar); background: var(--ambar-fondo); }
    .senal.lugar { color: var(--suave); background: var(--caja); }
    .fila-ayuda-texto { flex: 1; min-width: 0; }
    .fila-ayuda-nombre { font-weight: 600; font-size: 14.5px; }
    .fila-ayuda-para { color: var(--suave); font-size: 13.5px; line-height: 1.5; }
    .fila-ayuda-para code, .ruta { font: 12.5px var(--mono); background: var(--caja); border-radius: 5px; padding: 1px 6px; color: var(--texto); }
    .activar { flex: none; padding: 5px 15px; border-radius: 999px; background: var(--acento); color: var(--acento-texto);
      font-size: 12.5px; font-weight: 650; white-space: nowrap; box-shadow: 0 1px 2px rgba(0,0,0,.08); }
    .activar:hover { filter: brightness(.95); }
    .activado { flex: none; font-size: 12.5px; color: var(--tenue); white-space: nowrap; }
    .boton-chico { flex: none; padding: 4px 12px; border-radius: 8px; border: 1px solid var(--linea-fuerte);
      font-size: 12.5px; font-weight: 500; white-space: nowrap; }
    .boton-chico:hover { background: var(--hover); }
    .nota-ayuda { margin: 10px 0 0; color: var(--tenue); font-size: 12.5px; }

    .teclas { flex: none; width: 104px; display: flex; flex-wrap: wrap; gap: 4px; justify-content: flex-start; }
    .teclas kbd { font-size: 12.5px; padding: 1px 8px; }
    .teclas .tecla-icono { display: inline-grid; place-items: center; width: 26px; height: 24px; border-radius: 6px;
      background: var(--tecla); border: 1px solid var(--linea-fuerte); border-bottom-width: 2px; color: var(--texto); }
    .teclas .tecla-icono svg { width: 13px; height: 13px; }
    .teclas .icono-suelto { display: inline-grid; place-items: center; width: 30px; height: 26px; color: var(--suave); }
    .teclas .icono-suelto svg { width: 19px; height: 19px; }
    .pasos strong { font-weight: 650; }

    .opciones { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 10px; margin-top: 8px; }
    .opcion { display: flex; align-items: flex-start; gap: 12px; padding: 13px 14px; border-radius: 12px; border: 1px solid var(--linea); }
    .opcion:hover { background: var(--hover); border-color: var(--linea-fuerte); }
    .opcion-icono { flex: none; width: 34px; height: 34px; border-radius: 9px; display: grid; place-items: center; background: var(--caja); color: var(--suave); }
    .opcion-icono svg { width: 18px; height: 18px; }
    .opcion-nombre { font-weight: 600; font-size: 14px; }
    .opcion-para { color: var(--suave); font-size: 13px; line-height: 1.45; margin-top: 1px; }

    .privado { display: flex; gap: 12px; margin-top: 14px; padding: 14px 18px; border-radius: 12px;
      background: var(--tldr-fondo); border: 1px solid var(--tldr-borde); font-size: 14px; line-height: 1.55; }
    .privado svg { flex: none; width: 18px; height: 18px; margin-top: 2px; color: var(--tldr-texto); }
    .privado strong { font-weight: 650; }

    """
}

// MARK: - La página

extension Pagina {
    /// Toda la página Cómo se usa. Los permisos llegan aparte para poder dibujarla con cualquier estado (pruebas).
    static func comoSeUsa(permisos: [Ayuda.Permiso]) -> String {
        let e = Markdown.escapar
        let r = e(Atajos.reunion.texto), d = e(Atajos.dictado.texto)
        func tarjeta(_ numero: Int, _ titulo: String, extra: String = "", bajada: String, _ cuerpo: String) -> String {
            """
            <section class="tarjeta-ayuda"><div class="tarjeta-cabeza"><span class="paso-numero">\(numero)</span><h2>\(titulo)</h2>\(extra)</div>\
            <p class="tarjeta-bajada">\(bajada)</p>\(cuerpo)</section>
            """
        }
        func paso(_ teclas: String, _ texto: String) -> String {
            #"<div><div class="teclas">\#(teclas)</div><div class="fila-ayuda-para">\#(texto)</div></div>"#
        }
        func tecla(_ s: String) -> String { "<kbd>\(s)</kbd>" }
        func teclaIcono(_ svg: String) -> String { #"<span class="tecla-icono">\#(svg)</span>"# }
        func icono(_ svg: String) -> String { #"<span class="icono-suelto">\#(svg)</span>"# }

        // 1. Permisos
        let faltan = permisos.filter { !$0.listo }.count
        let estado = faltan == 0 ? #"<span class="estado ok">Todo listo</span>"#
            : #"<span class="estado falta">\#(faltan == 1 ? "Falta 1" : "Faltan \(faltan)")</span>"#
        let filasPermisos = permisos.map { p in
            let senal = p.listo ? #"<span class="senal ok">\#(Ayuda.bien)</span>"# : #"<span class="senal falta">\#(Ayuda.falta)</span>"#
            let boton = p.listo ? #"<span class="activado">Activado</span>"#
                : #"<span class="activar" role="button" data-accion="permiso" data-valor="\#(e(p.id))">Activar</span>"#
            return """
            <div>\(senal)<div class="fila-ayuda-texto"><div class="fila-ayuda-nombre">\(e(p.nombre))</div>\
            <div class="fila-ayuda-para">\(e(p.para))</div></div>\(boton)</div>
            """
        }.joined()
        let permisosHTML = tarjeta(1, "Permisos", extra: estado,
            bajada: "macOS los pide una sola vez. Si falta alguno, «Activar» te lleva directo a su lugar en Ajustes del Sistema: prende Minuta en la lista.",
            #"<div class="filas-ayuda">\#(filasPermisos)</div>"#
            + #"<p class="nota-ayuda">Al activar Grabación de pantalla, macOS puede pedirte salir de Minuta y abrirla de nuevo. Esta lista se actualiza sola al volver a esta ventana.</p>"#)

        // 2. Dictar
        let dictar = tarjeta(2, "Dictar",
            bajada: "En cualquier app: el texto se escribe donde está el cursor, queda copiado y se guarda en Inicio.",
            #"<div class="filas-ayuda pasos">"# + [
                paso(tecla("⌃⌥"), "<strong>Corto:</strong> mantén apretadas Control + Opción, habla y suéltalas."),
                paso(tecla(d), "<strong>Largo:</strong> aprieta \(tecla(d)), habla todo lo que quieras y termina apretando solo \(tecla("Espacio")) (o \(tecla(d)) otra vez)."),
                paso(tecla("Espacio"), "<strong>¿Partiste corto y te alargaste?</strong> Sin soltar ⌃⌥, aprieta Espacio: sigue como dictado largo, sin cortarse."),
                paso(teclaIcono(Ayuda.cruz), "<strong>Descartar:</strong> la ✕ de la barra de abajo bota el dictado sin escribir nada."),
                paso(icono(Ayuda.copiar), "<strong>¿Se pegó donde no era?</strong> Ícono de arriba › Copiar último dictado, o haz clic en el dictado en Inicio."),
                paso(icono(Ayuda.dictado), "<strong>Claude lo ordena:</strong> si hablas más de \(Dictado.palabrasParaOrdenar) palabras, saca muletillas y repeticiones antes de escribirlo. En el historial queda también lo que dijiste tal cual."),
                paso(icono(Ayuda.barritas), "<strong>La música baja</strong> mientras dictas y vuelve como estaba al terminar."),
            ].joined() + "</div>"
            + #"<p class="nota-ayuda">El dictado corto, el orden con Claude y bajar la música se apagan en Ajustes.</p>"#)

        // 3. Reuniones
        let reuniones = tarjeta(3, "Reuniones",
            bajada: "Graba tu voz y la de la llamada (Meet, Zoom, Teams, WhatsApp…) sin meter bots a la reunión.",
            #"<div class="filas-ayuda pasos">"# + [
                paso(tecla(r), "<strong>Grabar:</strong> aprieta \(tecla(r)) (y otra vez para detener), o el botón Grabar reunión de la página Reuniones."),
                paso(icono(Ayuda.cartel), "<strong>Cuando empieza una llamada</strong> aparece un cartel: «¿La grabo?». Al terminar ofrece Detener y resumir."),
                paso(teclaIcono(Ayuda.pausa) + teclaIcono(Ayuda.detener) + teclaIcono(Ayuda.cruz),
                     "<strong>La barra de abajo:</strong> pausa (no graba nada mientras dura), detener y resumir, y ✕ para descartar (va a la Papelera, sin resumen)."),
                paso(icono(Ayuda.barritas), "<strong>Las barritas se mueven con tu voz.</strong> Si quedan planas mientras hablas, el micrófono no te capta: a los 30 s sale el aviso «Sin voz»."),
                paso(icono(Ayuda.reloj), "<strong>Se transcribe mientras hablan,</strong> así el resumen llega más o menos un minuto después de detener. Te avisa con una notificación."),
                paso(icono(Ayuda.notas), "<strong>Queda en Reuniones</strong> con sus pestañas Notas, Minuta (si fue una reunión de venta) y Transcripción, y botones para copiar el correo o las notas."),
                paso(icono(Ayuda.calendario), "<strong>Usa tu calendario</strong> para ponerle el nombre de la reunión y saber quiénes estaban invitados."),
            ].joined() + "</div>")

        // 4. Personalizar
        let opciones: [(accion: String, valor: String, icono: String, nombre: String, para: String)] = [
            ("abrirAjustes", "", Ayuda.ajustes, "Ajustes y atajos…",
             "Cambia los atajos y prende o apaga el dictado corto, Claude, el cartel de llamadas, el calendario y la música."),
            ("abrirArchivo", "correcciones", Ayuda.correcciones, "Correcciones de palabras",
             "Lo que Whisper escribe mal, una por línea: «Bucines → Business». Vale para dictados y reuniones."),
            ("abrirArchivo", "plantilla", Ayuda.plantilla, "Plantilla del resumen",
             "Las secciones, el tono y el idioma de las notas de cada reunión. Desde que la abres, Minuta usa tu copia."),
            ("abrirArchivo", "dictado", Ayuda.dictado, "Instrucciones del dictado",
             "Cómo ordena Claude los dictados largos. Desde que la abres, Minuta usa tu copia."),
            ("abrirArchivo", "config", Ayuda.llaves, "Vocabulario y configuración",
             "Nombres y siglas que Whisper debe reconocer, idioma y carpeta. Vale desde que vuelves a abrir Minuta; las comillas, rectas (\")."),
            ("abrirArchivo", "reuniones", Ayuda.carpeta, "Abrir carpeta de reuniones",
             "Cada reunión en su carpeta, en el Finder."),
        ]
        let personalizar = tarjeta(4, "Personalizar",
            bajada: "Los archivos se abren en TextEdit: cámbialos y guarda con ⌘S. Se usan desde el próximo dictado o la próxima reunión.",
            #"<div class="opciones">"# + opciones.map { o in
                """
                <div class="opcion" role="button" data-accion="\(o.accion)" data-valor="\(e(o.valor))"><div class="opcion-icono">\(o.icono)</div>\
                <div><div class="opcion-nombre">\(e(o.nombre))</div><div class="opcion-para">\(e(o.para))</div></div></div>
                """
            }.joined() + "</div>")

        // 5. Dónde queda todo
        let lugares: [(valor: String, nombre: String, ruta: URL, para: String)] = [
            ("reuniones", "Reuniones", Config.carpetaReuniones, "Una carpeta por reunión: el audio, la transcripción, las notas y la minuta."),
            ("dictados", "Dictados", Config.carpetaReuniones.appendingPathComponent("Dictados"), "Un archivo por día con todo lo que dictaste."),
            ("soporte", "Tus ajustes", Config.soporte, "La configuración, tus plantillas, las correcciones y el modelo de Whisper."),
        ]
        let donde = tarjeta(5, "Dónde queda todo",
            bajada: "Son archivos comunes: puedes abrirlos, copiarlos o respaldarlos como cualquier otro.",
            #"<div class="filas-ayuda">"# + lugares.map { l in
                """
                <div><span class="senal lugar">\(Ayuda.carpeta)</span><div class="fila-ayuda-texto"><div class="fila-ayuda-nombre">\(e(l.nombre)) \
                <span class="ruta">\(e(Ayuda.corta(l.ruta)))</span></div><div class="fila-ayuda-para">\(e(l.para))</div></div>\
                <span class="boton-chico" role="button" data-accion="abrirArchivo" data-valor="\(l.valor)">Abrir</span></div>
                """
            }.joined() + "</div>"
            + """
            <div class="privado">\(Ayuda.candado)<div><strong>Todo queda en tu Mac.</strong> El audio nunca sale del computador: \
            Whisper transcribe aquí mismo. Solo el texto va a Claude: la transcripción, para hacer el resumen, y los dictados largos, para ordenarlos.</div></div>
            """)

        return """
        <div class="ayuda-cabeza"><div class="titulo-pagina">Cómo se usa Minuta</div>\
        <p class="bajada">Minuta vive en la barra de arriba del Mac, en el ícono ⏺. Revisa los permisos una vez; después, dictar y grabar es solo un atajo.</p></div>
        """ + permisosHTML + dictar + reuniones + personalizar + donde
    }
}
