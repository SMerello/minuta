# Minuta

Graba tus reuniones desde la barra de arriba del Mac, las transcribe **en tu propio computador** con Whisper y te deja un resumen con Claude. Sin bots que se meten a la llamada, sin video, sin suscripciones.

```
● ⌃⌥R Grabar reunión  →  ⌃⌥R Detener y resumir  →  ~/Reuniones/2026-10-21-1530-acme/
                                              ├── resumen.md        (TL;DR, puntos clave, decisiones, tareas)
                                              ├── minuta.md         (solo si fue reunión comercial)
                                              ├── transcripcion.md
                                              ├── microfono.caf   (tu voz)
                                              └── llamada.caf     (lo que sonó por el Mac)
```

## Cómo funciona

1. **Graba dos pistas separadas** con ScreenCaptureKit: tu micrófono y el audio del Mac (Meet, Zoom, Teams, WhatsApp, lo que sea). No graba la pantalla.
2. **Transcribe cada pista con [whisper.cpp](https://github.com/ggml-org/whisper.cpp)** (modelo `large-v3-turbo`) en el Mac. El audio no sale de tu computador.
3. **Junta las pistas por tiempo**, así la transcripción dice quién habló: tú o la llamada. Saca los silencios, las frases que Whisper inventa ("subtítulos por la comunidad de Amara.org") y el eco si usas parlantes.
4. **Resume con Claude** al estilo de las notas de reunión: TL;DR, resumen general, puntos clave, decisiones, tareas y preguntas abiertas, con una plantilla que puedes editar. Por defecto usa [Claude Code](https://claude.com/claude-code) (`claude -p`) con tu suscripción; también puede usar la API de Anthropic.
5. **Le pone nombre a la carpeta** según el tema de la reunión.

**Dictado:** para algo corto, mantén apretadas `⌃⌥` (Control + Opción) mientras hablas y suéltalas. Para algo largo, aprieta `⌃⌥Espacio`, habla todo lo que quieras y termina apretando solo Espacio (o ⌃⌥Espacio otra vez); si partiste manteniendo ⌃⌥ y te alargaste, aprieta Espacio sin soltar y sigue como largo. El texto se escribe solo donde está el cursor (un chat, un correo, cualquier campo), queda copiado en el portapapeles y se guarda en `~/Reuniones/Dictados/AAAA-MM-DD.md`. Para que se escriba solo, macOS pide el permiso de **Accesibilidad** la primera vez; sin él, el texto queda copiado y lo pegas con ⌘V. Al empezar a dictar, Minuta carga Whisper en memoria (`whisper-server`) mientras hablas y lo deja cargado 15 minutos después del último dictado, así el texto aparece en un segundo o dos; pasado ese rato lo cierra para liberar ~1,7 GB.

**Barra flotante:** mientras grabas o dictas aparece abajo una barra con unas barritas que se mueven con tu voz (si quedan planas mientras hablas, el micrófono no está captando), el tiempo y tres botones: pausa (solo en reuniones: no graba nada mientras dura), detener y ✕ para descartar (la reunión descartada va a la Papelera, sin resumen). Si un dictado se pegó en el lugar equivocado, ícono › **Copiar último dictado**.

**Atajos:** ⌃⌥R (reunión) y ⌃⌥Espacio (dictado largo) son los de fábrica; los cambias en ícono › **Ajustes…** (haz clic en el atajo y aprieta la combinación nueva). Ahí también se apaga el dictado corto con ⌃⌥.

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
  "borrar_audio": false,
  "vocabulario": "Caravana, UF, RUT, TAG, Acme"
}
```

- `nombre`: cómo aparece tu micrófono en la transcripción.
- `idioma`: `es`, `en`, … o `auto`.
- `resumen_con`: `claude` (Claude Code), `api` (API de Anthropic, con `modelo_claude` tipo `claude-sonnet-5-5`) o `ninguno` (solo transcribe).
- `borrar_audio`: borra los `.caf` después de resumir.
- `vocabulario`: nombres y siglas que Whisper debe reconocer (empresas, productos, jerga local).

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
- El instalador firma la app con tu certificado "Apple Development" si lo tienes en el llavero (lo crea Xcode al entrar con tu Apple ID), o con el que indiques en `MINUTA_FIRMA`. Así macOS la reconoce como la misma app y los permisos se mantienen al reinstalar. Sin certificado usa firma *ad hoc*, y los permisos hay que darlos de nuevo en cada reinstalación. Para repartirla ya armada a otros hay que firmarla con "Developer ID" y notarizarla.

## Licencia

MIT. Ver [LICENSE](LICENSE).
