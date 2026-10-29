import EventKit
import Foundation

/// Una reunión del Calendario del Mac (ahí está sincronizado el calendario de Google).
struct Evento {
    struct Asistente {
        let nombre: String     // el del invitado, o su correo si el calendario no trae nombre
        let email: String?
        let organizador: Bool
    }

    let titulo: String
    let inicio: Date
    let fin: Date
    let asistentes: [Asistente]  // sin ti
    let app: String?             // "Google Meet", "Zoom", "Teams", "Webex"… según el link de la reunión
    let organizador: String?
    var link: URL? = nil         // el link de video ("Entrar" en Inicio), el mismo que dio `app`
    var identificador = ""       // distingue cada reunión del día (las que se repiten comparten id en EventKit)
    // Solo para elegir cuál es la reunión de ahora.
    var todoElDia = false
    var rechazado = false        // le dijiste que no a la invitación

    /// Lo que va a info.json de la carpeta: lo leen la ventana Minuta y procesar.py (para Claude).
    var info: [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current   // "2026-10-22T15:30:00-03:00": así procesar.py muestra la hora de aquí
        var info: [String: Any] = [
            "titulo": titulo,
            "inicio": iso.string(from: inicio),
            "fin": iso.string(from: fin),
            "asistentes": asistentes.map { a -> [String: Any] in
                var d: [String: Any] = ["nombre": a.nombre]
                if let email = a.email { d["email"] = email }
                if a.organizador { d["organizador"] = true }
                return d
            },
        ]
        if let app { info["app"] = app }
        return info
    }
}

/// Mira el Calendario del Mac para saber qué reunión se está grabando: su nombre, a quién invitaron
/// y si es por Meet, Zoom o Teams. Pide el permiso una sola vez; sin permiso no hace nada.
enum Calendario {
    /// "Usar mi calendario para nombrar las reuniones" (se cambia en Ajustes).
    static var encendido: Bool {
        get { UserDefaults.standard.object(forKey: "usarCalendario") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "usarCalendario") }
    }

    static var conPermiso: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    /// Todavía no te ha preguntado (después de responder, macOS no vuelve a preguntar).
    static var sinPreguntar: Bool { EKEventStore.authorizationStatus(for: .event) == .notDetermined }

    private static let almacen = EKEventStore()

    /// Pide acceso completo al calendario (macOS 14+). `listo` llega en el hilo principal.
    static func pedirPermiso(listo: @escaping (Bool) -> Void = { _ in }) {
        almacen.requestFullAccessToEvents { dado, _ in
            DispatchQueue.main.async { listo(dado) }
        }
    }

    /// La reunión que está pasando ahora o empieza en los próximos 10 min. nil si no hay, si la casilla
    /// está apagada o si no hay permiso.
    static func reunionAhora(_ ahora: Date = Date()) -> Evento? {
        guard encendido, conPermiso else { return nil }
        // Los que se cruzan con [ahora, ahora + 10 min]: los que ya empezaron y no terminan, y los que vienen.
        let filtro = almacen.predicateForEvents(withStart: ahora, end: ahora.addingTimeInterval(margen), calendars: nil)
        let eventos = almacen.events(matching: filtro).filter { $0.status != .canceled }.map(evento(de:))
        return elegir(eventos, ahora: ahora)
    }

    /// Las reuniones que quedan hoy, para "Hoy en tu calendario" en Inicio: desde las que empezaron hace
    /// media hora (o siguen) hasta el final del día, sin las de todo el día ni las rechazadas, por hora.
    /// [] si la casilla está apagada o no hay permiso. Se llama cada 5 s con la ventana a la vista, pero el
    /// calendario se lee como mucho una vez por minuto (el resto del tiempo se filtra lo ya leído).
    static func reunionesDeHoy(_ ahora: Date = Date()) -> [Evento] {
        guard encendido, conPermiso else { return [] }
        let dia = Calendar.current.startOfDay(for: ahora)
        if let c = cacheHoy, c.dia == dia, ahora.timeIntervalSince(c.leido) < 60, ahora >= c.leido {
            return deHoy(c.eventos, ahora: ahora)
        }
        let manana = Calendar.current.date(byAdding: .day, value: 1, to: dia) ?? dia.addingTimeInterval(86_400)
        let filtro = almacen.predicateForEvents(withStart: dia, end: manana, calendars: nil)
        let eventos = almacen.events(matching: filtro).filter { $0.status != .canceled }.map(evento(de:))
        cacheHoy = (ahora, dia, eventos)
        return deHoy(eventos, ahora: ahora)
    }

    /// Calendario encendido pero sin permiso: Inicio muestra una línea para conectarlo.
    static var faltaPermiso: Bool { encendido && !conPermiso }

    private static var cacheHoy: (leido: Date, dia: Date, eventos: [Evento])?

    /// El filtro de `reunionesDeHoy`, aparte de EventKit para poder probarlo con eventos inventados.
    static func deHoy(_ eventos: [Evento], ahora: Date) -> [Evento] {
        let desde = ahora.addingTimeInterval(-30 * 60)
        let finDelDia = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: ahora)) ?? ahora
        return eventos
            .filter { !$0.todoElDia && !$0.rechazado && $0.fin > desde && $0.inicio < finDelDia }
            .sorted { $0.inicio != $1.inicio ? $0.inicio < $1.inicio : $0.titulo < $1.titulo }
    }

    /// Cuánto antes de que empiece una reunión ya cuenta como "la de ahora".
    static let margen: TimeInterval = 10 * 60

    /// De los eventos del calendario, el que más parece ser la reunión que se graba ahora. Aparte de
    /// EventKit para poder probarlo sin permisos. Descarta los de todo el día, los rechazados y los que
    /// no se cruzan con ahora. Prefiere los que tienen link de video; después los que tienen invitados
    /// (uno sin invitados ni link, como "Almuerzo", solo si no hay otro); y entre iguales, el que empieza
    /// más cerca de ahora.
    static func elegir(_ eventos: [Evento], ahora: Date) -> Evento? {
        func prioridad(_ e: Evento) -> Int { e.app != nil ? 0 : (e.asistentes.isEmpty ? 2 : 1) }
        return eventos
            .filter { !$0.todoElDia && !$0.rechazado && $0.inicio <= ahora.addingTimeInterval(margen) && $0.fin > ahora }
            .min { a, b in
                prioridad(a) != prioridad(b) ? prioridad(a) < prioridad(b)
                    : abs(a.inicio.timeIntervalSince(ahora)) < abs(b.inicio.timeIntervalSince(ahora))
            }
    }

    /// Dominio del link → app, en el orden en que se buscan.
    private static let videos: [(String, String)] = [
        ("meet.google.com", "Google Meet"), ("zoom.us", "Zoom"), ("teams.microsoft.com", "Teams"),
        ("teams.live.com", "Teams"), ("webex.com", "Webex"), ("whereby.com", "Whereby"),
    ]

    /// La app del primer link de video que aparece en estos textos (el link del evento, el lugar, las notas).
    static func appDeVideo(en textos: [String?]) -> String? {
        for texto in textos.compactMap({ $0?.lowercased() }) {
            // Si las notas traen dos links, gana el que aparece primero.
            let encontrados = videos.compactMap { dominio, app in texto.range(of: dominio).map { ($0.lowerBound, app) } }
            if let primero = encontrados.min(by: { $0.0 < $1.0 }) { return primero.1 }
        }
        return nil
    }

    /// El primer link de video de estos textos (el mismo que encuentra `appDeVideo`), para el botón "Entrar".
    /// Acepta links sin "https://", como "meet.google.com/abc-defg-hij" en el lugar del evento.
    static func linkDeVideo(en textos: [String?]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for texto in textos.compactMap({ $0 }) {
            let links = detector.matches(in: texto, range: NSRange(texto.startIndex..., in: texto)).compactMap(\.url)
            if let link = links.first(where: { url in
                let host = url.host?.lowercased() ?? ""
                return url.scheme?.lowercased().hasPrefix("http") == true
                    && videos.contains { host == $0.0 || host.hasSuffix("." + $0.0) }
            }) { return link }
        }
        return nil
    }

    /// Correo de un invitado: su URL suele ser "mailto:marcela@empresa.cl".
    private static func correo(_ p: EKParticipant) -> String? {
        let url = p.url.absoluteString
        guard url.lowercased().hasPrefix("mailto:") else { return nil }
        let correo = String(url.dropFirst(7)).removingPercentEncoding ?? String(url.dropFirst(7))
        return correo.contains("@") ? correo : nil
    }

    private static func evento(de e: EKEvent) -> Evento {
        let invitados = e.attendees ?? []
        let textos = [e.url?.absoluteString, e.location, e.structuredLocation?.title, e.notes]
        let organizador = e.organizer
        let correoOrganizador = organizador.flatMap(correo)
        // Solo personas: una sala o un recurso ("Sala 3", un proyector) no es un invitado y, como se repite en
        // reuniones que no tienen nada que ver, emparejaba mal al buscar "la última vez" con esa gente.
        let asistentes = invitados.filter { !$0.isCurrentUser && ![.room, .resource].contains($0.participantType) }
            .compactMap { p -> Evento.Asistente? in
            let email = correo(p)
            let nombre = p.name?.trimmingCharacters(in: .whitespaces).nilSiVacio ?? email
            guard let nombre else { return nil }
            let organiza = p.participantRole == .chair || (email != nil && email?.lowercased() == correoOrganizador?.lowercased())
            return Evento.Asistente(nombre: nombre, email: email, organizador: organiza)
        }
        var evento = Evento(
            titulo: e.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilSiVacio ?? "Reunión",
            inicio: e.startDate, fin: e.endDate, asistentes: asistentes,
            app: appDeVideo(en: textos),
            organizador: organizador.flatMap { $0.name?.nilSiVacio ?? correo($0) },
            link: linkDeVideo(en: textos),
            identificador: "\(e.calendarItemIdentifier)|\(Int(e.startDate.timeIntervalSince1970))")
        evento.todoElDia = e.isAllDay
        evento.rechazado = invitados.contains { $0.isCurrentUser && $0.participantStatus == .declined }
        return evento
    }
}

private extension String {
    var nilSiVacio: String? { isEmpty ? nil : self }
}
