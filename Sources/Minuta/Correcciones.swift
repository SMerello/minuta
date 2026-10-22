import Foundation

/// Tu lista de palabras que Whisper escribe mal ("Bucines → Business"), en
/// ~/Library/Application Support/Minuta/correcciones.txt. Se aplica a cada dictado; las reuniones
/// la aplica procesar.py con la misma regla. Se vuelve a leer sola cuando cambias el archivo.
enum Correcciones {
    static var archivo: URL { Config.soporte.appendingPathComponent("correcciones.txt") }

    private static var leidas: [(NSRegularExpression, String)] = []
    private static var fechaLeida: Date?
    private static let candado = NSLock()

    /// Cambia cada palabra (o frase) completa de la lista, sin importar mayúsculas a la izquierda.
    static func aplicar(_ texto: String) -> String {
        reglas().reduce(texto) { t, regla in
            regla.0.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t),
                                             withTemplate: NSRegularExpression.escapedTemplate(for: regla.1))
        }
    }

    /// Crea el archivo desde la plantilla si no existe (para el botón de Ajustes).
    static func asegurarArchivo() {
        guard !FileManager.default.fileExists(atPath: archivo.path) else { return }
        try? FileManager.default.createDirectory(at: Config.soporte, withIntermediateDirectories: true)
        if let plantilla = Bundle.main.url(forResource: "correcciones", withExtension: "txt", subdirectory: "plantillas") {
            try? FileManager.default.copyItem(at: plantilla, to: archivo)
        }
    }

    private static func reglas() -> [(NSRegularExpression, String)] {
        candado.lock()
        defer { candado.unlock() }
        let fecha = (try? FileManager.default.attributesOfItem(atPath: archivo.path))?[.modificationDate] as? Date
        guard fecha != fechaLeida else { return leidas }
        fechaLeida = fecha
        leidas = ((try? String(contentsOf: archivo, encoding: .utf8)) ?? "")
            .components(separatedBy: .newlines)
            .compactMap(regla)
        return leidas
    }

    /// "Bucines → Business" (también "->" o "=") → la expresión que la encuentra y el reemplazo.
    private static func regla(_ linea: String) -> (NSRegularExpression, String)? {
        let limpia = linea.trimmingCharacters(in: .whitespaces)
        guard !limpia.isEmpty, !limpia.hasPrefix("#"),
              let flecha = ["→", "->", "=>", "="].lazy.compactMap({ limpia.range(of: $0) }).first else { return nil }
        let mal = limpia[..<flecha.lowerBound].trimmingCharacters(in: .whitespaces)
        let bien = limpia[flecha.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !mal.isEmpty, !bien.isEmpty else { return nil }
        // Solo palabras completas: "Bucines" sí, "Bucinesco" no. Los espacios de la frase aceptan uno o más.
        let frase = mal.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+")
        guard let expresion = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + frase + "(?![\\p{L}\\p{N}])",
                                                       options: [.caseInsensitive]) else { return nil }
        return (expresion, bien)
    }
}
