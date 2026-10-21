import Carbon.HIToolbox

/// Atajo de teclado global (funciona aunque Minuta no esté al frente y aunque el ícono esté escondido).
/// Usa RegisterEventHotKey de Carbon, que no necesita permiso de Accesibilidad.
final class Atajo {
    private var referencia: EventHotKeyRef?
    private var manejador: EventHandlerRef?
    private let accion: () -> Void

    /// Por defecto ⌃⌥R (Control + Opción + R).
    init(tecla: Int = kVK_ANSI_R, modificadores: Int = controlKey | optionKey, accion: @escaping () -> Void) {
        self.accion = accion
        var tipo = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let contexto = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, contexto in
            guard let contexto else { return noErr }
            let atajo = Unmanaged<Atajo>.fromOpaque(contexto).takeUnretainedValue()
            DispatchQueue.main.async { atajo.accion() }
            return noErr
        }, 1, &tipo, contexto, &manejador)
        let id = EventHotKeyID(signature: OSType(0x4D4E5441), id: 1)   // "MNTA"
        RegisterEventHotKey(UInt32(tecla), UInt32(modificadores), id, GetApplicationEventTarget(), 0, &referencia)
    }

    deinit {
        if let referencia { UnregisterEventHotKey(referencia) }
        if let manejador { RemoveEventHandler(manejador) }
    }
}
