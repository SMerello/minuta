import Carbon.HIToolbox

/// Atajo de teclado global (funciona aunque Minuta no esté al frente y aunque el ícono esté escondido).
/// Usa RegisterEventHotKey de Carbon, que no necesita permiso de Accesibilidad.
final class Atajo {
    private static var siguienteId: UInt32 = 1

    private let id: UInt32
    private var referencia: EventHotKeyRef?
    private var manejador: EventHandlerRef?
    private let accion: () -> Void

    /// `tecla` es un kVK_ANSI_*; los modificadores por defecto son ⌃⌥ (Control + Opción).
    init(tecla: Int, modificadores: Int = controlKey | optionKey, accion: @escaping () -> Void) {
        id = Atajo.siguienteId
        Atajo.siguienteId += 1
        self.accion = accion
        var tipo = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let contexto = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, evento, contexto in
            guard let evento, let contexto else { return OSStatus(eventNotHandledErr) }
            let atajo = Unmanaged<Atajo>.fromOpaque(contexto).takeUnretainedValue()
            var apretado = EventHotKeyID()
            GetEventParameter(evento, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &apretado)
            // Cada atajo tiene su propio manejador: si no es el mío, lo dejo pasar al siguiente.
            guard apretado.id == atajo.id else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { atajo.accion() }
            return noErr
        }, 1, &tipo, contexto, &manejador)
        let hotKeyId = EventHotKeyID(signature: OSType(0x4D4E5441), id: id)   // "MNTA"
        RegisterEventHotKey(UInt32(tecla), UInt32(modificadores), hotKeyId, GetApplicationEventTarget(), 0, &referencia)
    }

    deinit {
        if let referencia { UnregisterEventHotKey(referencia) }
        if let manejador { RemoveEventHandler(manejador) }
    }
}
