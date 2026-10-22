import AppKit

/// Dictado corto, tipo walkie-talkie: mientras mantienes apretadas ⌃⌥ (solas) graba, y al soltarlas escribe.
/// Para no confundirse con atajos como ⌃⌥R o ⌃⌥←, solo parte si las sostienes un momento sin otra tecla;
/// si después aprietas otra tecla, avisa con `alInterrumpir` (era un atajo, no un dictado).
/// Usa monitores globales de teclado, que necesitan el permiso de Accesibilidad (el mismo que usa el dictado para escribir).
final class Mantener {
    /// Devuelve false si no partió (ya había un dictado, por ejemplo uno largo con ⌃⌥Espacio): ahí soltar no hace nada.
    var alEmpezar: () -> Bool = { false }
    var alSoltar: () -> Void = {}
    var alInterrumpir: () -> Void = {}

    /// Cuánto hay que sostener ⌃⌥ antes de empezar a grabar.
    private static let espera: TimeInterval = 0.3

    private var monitores: [Any] = []
    private var pendiente: DispatchWorkItem?
    private(set) var grabando = false

    var encendido: Bool {
        get { UserDefaults.standard.object(forKey: "mantenerParaDictar") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "mantenerParaDictar")
            if !newValue { olvidar() }
        }
    }

    func vigilar() {
        // El global ve lo que pasa en otras apps; el local, lo que pasa en las ventanas de Minuta (Ajustes).
        let tipos: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: tipos, handler: { [weak self] in self?.recibir($0) }) {
            monitores.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: tipos, handler: { [weak self] in self?.recibir($0); return $0 }) {
            monitores.append(l)
        }
    }

    /// Deja de considerar el dictado como "mantenido" (por ejemplo, porque pasó a dictado largo con ⌃⌥Espacio):
    /// soltar ⌃⌥ ya no lo termina.
    func olvidar() {
        pendiente?.cancel()
        pendiente = nil
        grabando = false
    }

    private func recibir(_ evento: NSEvent) {
        guard encendido else { return }
        if evento.type == .keyDown {
            // Otra tecla junto a ⌃⌥: era un atajo. Si aún no partía, no parte; si ya partió, se descarta.
            pendiente?.cancel()
            pendiente = nil
            if grabando {
                grabando = false
                alInterrumpir()
            }
            return
        }
        let teclas = evento.modifierFlags.intersection([.control, .option, .shift, .command])
        if teclas == [.control, .option] {
            guard pendiente == nil, !grabando else { return }
            let tarea = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendiente = nil
                // Marcado antes de empezar, para que la app ya lo trate como corto (Espacio no lo termina).
                self.grabando = true
                self.grabando = self.alEmpezar()
            }
            pendiente = tarea
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.espera, execute: tarea)
        } else {
            pendiente?.cancel()
            pendiente = nil
            guard grabando else { return }
            grabando = false
            // Soltaste ⌃ u ⌥: escribe. Si en vez de soltar sumaste ⇧ o ⌘, ibas a otro atajo: se descarta.
            if teclas.isSubset(of: [.control, .option]) { alSoltar() } else { alInterrumpir() }
        }
    }
}
