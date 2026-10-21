# Minuta

Graba tus reuniones desde la barra de arriba del Mac, las transcribe **en tu propio computador** con Whisper y te deja un resumen con Claude. Sin bots que se meten a la llamada, sin video, sin suscripciones.

```
● Grabar reunión  →  Detener y resumir  →  ~/Reuniones/2026-10-21-1530-acme/
                                              ├── resumen.md
                                              ├── transcripcion.md
                                              ├── microfono.caf   (tu voz)
                                              └── llamada.caf     (lo que sonó por el Mac)
```

## Cómo funciona

1. **Graba dos pistas separadas** con ScreenCaptureKit: tu micrófono y el audio del Mac (Meet, Zoom, Teams, WhatsApp, lo que sea). No graba la pantalla.
2. **Transcribe cada pista con [whisper.cpp](https://github.com/ggml-org/whisper.cpp)** (modelo `large-v3-turbo`) en el Mac. El audio no sale de tu computador.
3. **Junta las pistas por tiempo**, así la transcripción dice quién habló: tú o la llamada. Saca los silencios, las frases que Whisper inventa ("subtítulos por la comunidad de Amara.org") y el eco si usas parlantes.
4. **Resume con Claude** usando una plantilla que puedes editar. Por defecto usa [Claude Code](https://claude.com/claude-code) (`claude -p`) con tu suscripción; también puede usar la API de Anthropic.
5. **Le pone nombre a la carpeta** según el tema de la reunión.

También sirve para **cualquier audio que ya tengas** (notas de voz, grabaciones viejas): menú › *Procesar un audio…*

## Instalar

Necesitas un Mac con Apple Silicon y macOS 15 o más nuevo, [Homebrew](https://brew.sh) y Xcode o sus Command Line Tools.

```bash
git clone <este repo> && cd minuta
scripts/instalar.sh          # instala ffmpeg y whisper-cpp, baja el modelo (~1,6 GB) y arma la app
open ~/Applications/Minuta.app
```

La primera vez que grabes, macOS te pide dos permisos: **Micrófono** y **Grabación de pantalla y audio del sistema** (este último es el que deja captar la llamada). Si después de una actualización deja de grabar, revisa esos permisos en *Ajustes del Sistema › Privacidad y seguridad*.

Para el resumen necesitas una de estas dos:
- **Claude Code** instalado y con sesión iniciada (`claude` en la terminal). Es la opción por defecto.
- **Una clave de la API de Anthropic**: guárdala en el llavero con
  `security add-generic-password -s minuta-anthropic -a minuta -w` y pon `"resumen_con": "api"` en la configuración.

## Configurar

`~/Library/Application Support/Minuta/config.json` (todo es opcional):

```json
{
  "carpeta": "~/Reuniones",
  "nombre": "Santiago",
  "idioma": "es",
  "modelo": "~/Library/Application Support/Minuta/ggml-large-v3-turbo.bin",
  "resumen_con": "claude",
  "modelo_claude": "sonnet",
  "borrar_audio": false
}
```

- `nombre`: cómo aparece tu micrófono en la transcripción.
- `idioma`: `es`, `en`, … o `auto`.
- `resumen_con`: `claude` (Claude Code), `api` (API de Anthropic, con `modelo_claude` tipo `claude-sonnet-5-5`) o `ninguno` (solo transcribe).
- `borrar_audio`: borra los `.caf` después de resumir.

**La plantilla del resumen** es un texto común: copia `Recursos/plantillas/resumen.md` a `~/Library/Application Support/Minuta/plantilla.md` y cámbiala como quieras (secciones, idioma, tono). Su primera línea de respuesta debe ser `TITULO: …`, que se usa para nombrar la carpeta.

**Sin la app**, desde la terminal:

```bash
python3 Recursos/procesar.py --archivo ~/Downloads/nota-de-voz.m4a
python3 Recursos/procesar.py --carpeta ~/Reuniones/2026-10-21-1530
```

## Consejos

- **Usa audífonos** en las llamadas: así tu micrófono capta solo tu voz y la transcripción sabe mejor quién habló.
- En reuniones **presenciales**, todo queda en la pista del micrófono; el resumen distingue a las personas por el contexto.
- Una reunión de una hora tarda unos minutos en transcribirse. Puedes grabar la siguiente mientras tanto.
- **Avisa que estás grabando.** Es lo correcto y en muchos países es obligatorio.

## Limitaciones

- La pista "Llamada" junta a todas las personas remotas: no separa voces dentro de ella (el resumen lo deduce por contexto).
- La app va firmada solo para tu Mac (firma *ad hoc*). Para repartirla ya armada a otros hay que firmarla con una cuenta de desarrollador de Apple.

## Licencia

MIT. Ver [LICENSE](LICENSE).
