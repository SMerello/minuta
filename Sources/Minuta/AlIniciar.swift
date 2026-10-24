import Foundation
import ServiceManagement

/// Abrir Minuta sola al iniciar sesión, para que los atajos y el aviso de llamadas estén siempre listos.
/// Usa el registro de macOS (aparece en Ajustes del Sistema › General › Ítems de inicio de sesión).
enum AlIniciar {
    static var encendido: Bool { SMAppService.mainApp.status == .enabled }

    /// Si macOS pide que lo apruebes en Ajustes del Sistema (pasa a veces la primera vez).
    static var esperaAprobacion: Bool { SMAppService.mainApp.status == .requiresApproval }

    @discardableResult
    static func cambiar(_ prender: Bool) -> Bool {
        do {
            if prender { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            NSLog("Minuta: no pude cambiar el inicio de sesión: \(error)")
            return false
        }
    }

    /// La primera vez que se abre esta versión, se prende sola (Santiago lo pidió). Después manda Ajustes:
    /// si la apagas, no se vuelve a prender.
    static func prenderLaPrimeraVez() {
        guard !UserDefaults.standard.bool(forKey: "alIniciarConfigurado") else { return }
        UserDefaults.standard.set(true, forKey: "alIniciarConfigurado")
        if !encendido { cambiar(true) }
    }
}
