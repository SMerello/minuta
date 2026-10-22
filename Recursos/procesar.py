#!/usr/bin/env python3
"""Transcribe y resume una reunión grabada con Minuta (o cualquier audio).

Uso:
  procesar.py --carpeta ~/Reuniones/2026-10-21-1530   # carpeta con microfono.caf y/o llamada.caf
  procesar.py --archivo ~/Downloads/nota-de-voz.m4a   # cualquier audio o video
  procesar.py --carpeta ~/Reuniones/... --en-vivo     # mientras se graba: transcribe a medida que se habla

En vivo, la app lo lanza al empezar a grabar y crea el archivo ".detener" en la carpeta al terminar:
mientras tanto va transcribiendo de a trozos las copias livianas del audio (microfono.pcm y llamada.pcm,
16 kHz mono que crecen mientras se graba). Así, al detener, solo falta el último trozo y el resumen.

Pasos: (1) convierte cada pista a WAV 16 kHz y detecta los silencios con ffmpeg,
(2) transcribe con whisper.cpp en el Mac, (3) junta las pistas por tiempo marcando quién habló,
(4) resume con Claude, (5) le pone un nombre a la carpeta según el tema.

Va avisando a la app por la salida estándar: "ETAPA: ...", "ERROR: ..." y al final "LISTO: <ruta de resumen.md>".
Solo usa la biblioteca estándar de Python (funciona con el python3 que trae macOS).
"""

import argparse
import datetime as dt
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import unicodedata
import urllib.request
import wave
from pathlib import Path

SOPORTE = Path.home() / "Library/Application Support/Minuta"
AQUI = Path(__file__).resolve().parent

CONFIG_INICIAL = {
    "carpeta": "~/Reuniones",
    "nombre": "Yo",                 # cómo se llama la pista del micrófono en la transcripción
    "idioma": "es",                 # "es", "en", ... o "auto"
    "modelo": str(SOPORTE / "ggml-large-v3-turbo.bin"),
    "plantilla": None,              # None → SOPORTE/plantilla.md si existe, si no la que viene con la app
    "resumen_con": "claude",        # "claude" (Claude Code, usa tu suscripción) | "api" | "ninguno"
    "modelo_claude": "sonnet",      # para "claude"; para "api" usa un id como "claude-sonnet-5-5"
    "borrar_audio": False,          # True → borra los .caf cuando todo salió bien
    "vocabulario": "",              # nombres y palabras que Whisper debe reconocer (empresas, siglas, jerga)
}

# Frases que Whisper inventa en silencios (vienen de subtítulos de YouTube con que se entrenó).
ALUCINACIONES = (
    "amara.org", "subtítulos realizados", "subtitulos realizados", "subtítulos por la comunidad",
    "gracias por ver", "suscríbete", "suscribete", "suscríbanse", "dale like", "no olvides suscribirte", "thanks for watching",
)

_log = None


def decir(prefijo, texto):
    linea = f"{prefijo}: {texto}"
    print(linea, flush=True)
    if _log:
        _log.write(f"{dt.datetime.now():%H:%M:%S} {linea}\n")
        _log.flush()


def cargar_config():
    config = dict(CONFIG_INICIAL)
    ruta = SOPORTE / "config.json"
    if ruta.exists():
        config.update(json.loads(ruta.read_text(encoding="utf-8")))
    config["carpeta"] = Path(os.path.expanduser(config["carpeta"]))
    config["modelo"] = Path(os.path.expanduser(config["modelo"]))
    return config


def herramienta(nombre):
    for carpeta in ("/opt/homebrew/bin", "/usr/local/bin"):
        ruta = Path(carpeta) / nombre
        if ruta.exists():
            return str(ruta)
    ruta = shutil.which(nombre)
    if not ruta:
        raise RuntimeError(f"No encontré '{nombre}'. Instálalo con: brew install "
                           + ("whisper-cpp" if nombre == "whisper-cli" else nombre))
    return ruta


# ---------- 1. Audio ----------

def preparar_pista(entrada, wav):
    """Convierte a WAV 16 kHz mono y devuelve (volumen máximo en dB, tramos de silencio, duración en s)."""
    r = subprocess.run(
        [herramienta("ffmpeg"), "-hide_banner", "-nostats", "-y", "-i", str(entrada),
         "-af", "silencedetect=noise=-40dB:d=0.8,volumedetect",
         "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", str(wav)],
        capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"ffmpeg no pudo leer {Path(entrada).name}: {r.stderr.strip()[-300:]}")
    maximo = re.search(r"max_volume: (-?[\d.]+|-inf) dB", r.stderr)
    volumen = float(maximo.group(1)) if maximo and maximo.group(1) != "-inf" else -999.0
    silencios, abierto = [], None
    for linea in r.stderr.splitlines():
        if m := re.search(r"silence_start: (-?[\d.]+)", linea):
            abierto = max(0.0, float(m.group(1)))
        elif (m := re.search(r"silence_end: ([\d.]+)", linea)) and abierto is not None:
            silencios.append((abierto, float(m.group(1))))
            abierto = None
    duracion = 0.0
    if m := re.search(r"time=(\d+):(\d+):([\d.]+)", r.stderr.replace("\r", "\n")):
        duracion = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))
    if abierto is not None:
        silencios.append((abierto, max(duracion, abierto) + 1e9))
    return volumen, silencios, duracion


PAUSA = 1.0   # segundos de silencio entre tramos con voz en el audio compactado


def compactar(wav, silencios, duracion, destino):
    """Arma un WAV solo con los tramos con voz, separados por PAUSA segundos de silencio.
    Whisper se confunde con silencios largos: inventa frases y se salta lo que viene después.
    Devuelve el mapa [(inicio_compacto, fin_compacto, inicio_original)] para volver a la hora real,
    o None si no hay voz."""
    margen = 0.25
    tramos, cursor = [], 0.0
    for a, b in sorted(silencios):
        if a > cursor:
            tramos.append((cursor, a))
        cursor = max(cursor, b)
    if cursor < duracion:
        tramos.append((cursor, duracion))
    juntos = []
    # Tramos de menos de 0,3 s son clics o golpes (teclado, mesa), no voz.
    for a, b in ((max(0.0, a - margen), min(duracion, b + margen)) for a, b in tramos if b - a > 0.3):
        if juntos and a <= juntos[-1][1]:
            juntos[-1] = (juntos[-1][0], max(juntos[-1][1], b))
        else:
            juntos.append((a, b))
    if sum(b - a for a, b in juntos) < 0.5:
        return None

    with wave.open(str(wav), "rb") as entrada, wave.open(str(destino), "wb") as salida:
        salida.setparams(entrada.getparams())
        tasa, ancho = entrada.getframerate(), entrada.getsampwidth() * entrada.getnchannels()
        silencio = b"\x00" * (int(PAUSA * tasa) * ancho)
        mapa, posicion = [], 0.0
        for a, b in juntos:
            entrada.setpos(min(int(a * tasa), entrada.getnframes()))
            cuadros = entrada.readframes(int((b - a) * tasa))
            largo = len(cuadros) / ancho / tasa
            salida.writeframes(cuadros + silencio)
            mapa.append((posicion, posicion + largo, a))
            posicion += largo + PAUSA
    return mapa


def tramo_de(t, mapa):
    """Índice del tramo al que pertenece el instante t del audio compactado."""
    for i, (_, fin, _) in enumerate(mapa):
        if t < fin + PAUSA / 2:
            return i
    return len(mapa) - 1


ABREN = "¿¡«\"'(["   # puntuación que va pegada a la palabra que viene después


def palabras(fichas):
    """Junta las fichas de Whisper (pedazos de palabra: "Perfect" + "o", " ¿" + "Y") en palabras
    completas, para que una palabra nunca quede partida entre dos tramos.
    Devuelve [(desde, hasta, momento, texto)]: momento es el instante que decide el tramo."""
    juntas = []
    for desde, hasta, dtw, texto in fichas:
        letras = bool(re.search(r"\w", texto))
        # Abre palabra la ficha que empieza con espacio, salvo que sea puntuación de cierre (" ,")
        # o que la anterior sea solo un "¿" esperando su palabra.
        nueva = (not juntas or texto[:1].isspace() and (letras or texto.strip()[:1] in ABREN)
                 and re.search(r"\w", juntas[-1][3]))
        if nueva:
            juntas.append([desde, hasta, [], ""])
        p = juntas[-1]
        p[1] = max(p[1], hasta)
        p[3] += texto
        if letras:   # la puntuación no vota: Whisper le pone horas cualquiera, a veces dentro de la pausa
            p[2].append(dtw if dtw is not None else (desde + hasta) / 2)
    return [(a, b, votos[0] if votos else (a + b) / 2, t) for a, b, votos, t in juntas]


def a_hora_real(segmentos, mapa):
    """Pasa los segmentos de Whisper a la hora real. Cada palabra va al tramo con voz donde se dijo,
    y un segmento que cruza de un tramo a otro (dos intervenciones que en la reunión estaban
    separadas) se corta justo en el borde del tramo."""
    def real(t, i):
        inicio, fin, original = mapa[i]
        return original + min(max(0.0, t - inicio), fin - inicio)

    salida = []
    for desde, hasta, texto, fichas in segmentos:
        grupos, anterior = [], 0
        for p_desde, p_hasta, momento, p_texto in palabras(fichas):
            # Las palabras van en orden: un tramo nunca puede ser anterior al de la palabra previa.
            i = anterior = max(anterior, tramo_de(momento, mapa))
            # La hora de Whisper suele caer en la pausa de antes; la de DTW, un poco después: uso ambas.
            a, b = min(p_desde, momento), max(p_hasta, momento)
            if grupos and grupos[-1][0] == i:
                grupos[-1][2] = max(grupos[-1][2], b)
                grupos[-1][3] += p_texto
            else:
                grupos.append([i, a, b, p_texto])
        if not grupos:
            i = tramo_de((desde + hasta) / 2, mapa)
            grupos = [[i, desde, hasta, texto]]
        elif len(grupos) == 1:
            grupos[0][3] = texto   # el texto del segmento entero está mejor armado que la suma de fichas
        for i, a, b, t in grupos:
            if t.strip():
                inicio = real(a, i)
                salida.append((inicio, max(inicio, real(b, i)), t.strip()))
    return salida


def fraccion_con_voz(inicio, fin, silencios):
    largo = max(fin - inicio, 1e-3)
    en_silencio = sum(max(0.0, min(fin, b) - max(inicio, a)) for a, b in silencios)
    return 1 - en_silencio / largo


# ---------- 2. Whisper ----------

PRESETS_DTW = {"tiny", "tiny.en", "base", "base.en", "small", "small.en", "medium", "medium.en",
               "large.v1", "large.v2", "large.v3", "large.v3.turbo"}


def preset_dtw(modelo):
    """Nombre que whisper usa para el DTW de este modelo (ggml-large-v3-turbo.bin → large.v3.turbo),
    o None si no lo reconozco (entonces se usa la hora estimada de whisper)."""
    nombre = Path(modelo).stem
    nombre = re.sub(r"-q\d.*$", "", nombre[5:] if nombre.startswith("ggml-") else nombre)
    nombre = nombre.replace("-", ".")
    return nombre if nombre in PRESETS_DTW else None


def transcribir(wav, config, etiqueta):
    base = wav.with_suffix("")          # whisper agrega ".json" a este nombre
    salida_json = Path(f"{base}.json")
    comando = [herramienta("whisper-cli"), "-m", str(config["modelo"]), "-f", str(wav),
               "-l", config["idioma"], "-oj", "-ojf", "-of", str(base), "-pp", "-np"]
    if config.get("vocabulario"):
        comando += ["--prompt", config["vocabulario"]]
    if preset := preset_dtw(config["modelo"]):
        # Hora de cada palabra alineada con el audio (DTW). Sin esto whisper la estima repartiendo
        # el segmento, y la primera palabra de cada intervención cae en la pausa de antes y se va
        # con la intervención anterior. DTW no funciona con flash attention: por eso -nfa.
        comando += ["-dtw", preset, "-nfa"]
    proceso = subprocess.Popen(comando, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    ultimo = -1
    cola = []
    for linea in proceso.stderr:
        cola = (cola + [linea])[-20:]
        if m := re.search(r"progress\s*=\s*(\d+)%", linea):
            avance = int(m.group(1))
            if avance >= ultimo + 10:
                ultimo = avance
                decir("ETAPA", f"transcribiendo {etiqueta} {avance}%")
    if proceso.wait() != 0:
        raise RuntimeError("whisper falló: " + "".join(cola).strip()[-300:])
    datos = json.loads(salida_json.read_text(encoding="utf-8", errors="replace"))
    salida_json.unlink(missing_ok=True)
    segmentos = []
    for s in datos.get("transcription", []):
        # Las frases inventadas se sacan aquí, antes de cortar el segmento en pedazos (después ya no se reconocen).
        if not s.get("text", "").strip() or es_alucinacion(s["text"]):
            continue
        # t_dtw viene en centésimas de segundo (−1 si whisper no lo calculó).
        fichas = [(t["offsets"]["from"] / 1000, t["offsets"]["to"] / 1000,
                   t["t_dtw"] / 100 if t.get("t_dtw", -1) >= 0 else None, t["text"])
                  for t in s.get("tokens", []) if not t.get("text", "").startswith("[_")]
        segmentos.append((s["offsets"]["from"] / 1000, s["offsets"]["to"] / 1000, s["text"].strip(), fichas))
    return segmentos


def es_alucinacion(texto):
    bajo = re.sub(r"\s+", " ", texto.lower())
    junto = bajo.replace(" ", "")
    return any(frase in bajo or frase.replace(" ", "") in junto for frase in ALUCINACIONES)


def limpiar(segmentos, silencios):
    limpios = []
    for inicio, fin, texto in segmentos:
        if es_alucinacion(texto):
            continue
        if re.fullmatch(r"[\W_]*|\[.*\]|\(.*\)", texto):   # "[Música]", "(risas)", puntuación suelta
            continue
        if fraccion_con_voz(inicio, fin, silencios) < 0.15:
            continue
        limpios.append((inicio, fin, texto))
    return limpios


# ---------- 2b. En vivo ----------

TASA_PCM = 16000 * 2        # bytes por segundo de las copias livianas (16 kHz, mono, 16 bits)
TROZO_MINIMO = 20           # segundos nuevos antes de transcribir un trozo (se corta en el último silencio)
TROZO_MAXIMO = 150          # si nadie hace una pausa en tanto rato, se corta igual
SIN_AUDIO_NUEVO = 120       # si el audio deja de crecer este rato sin ".detener", la app se cayó: termino igual


def segundos_pcm(ruta):
    return ruta.stat().st_size / TASA_PCM if ruta.exists() else 0.0


def recorte_wav(pcm, desde, hasta, destino):
    """Copia [desde, hasta) de la copia liviana a un WAV común."""
    with open(pcm, "rb") as f:
        f.seek(int(desde * 16000) * 2)
        datos = f.read(max(0, int(hasta * 16000) - int(desde * 16000)) * 2)
    with wave.open(str(destino), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(datos)


def transcribir_trozo(pcm, desde, hasta, config, etiqueta, carpeta):
    """Transcribe un trozo de la reunión. Devuelve (segmentos, silencios) con la hora real de la reunión."""
    crudo, wav, compacto = (carpeta / f"{pcm.stem}.trozo{x}.wav" for x in ("", ".16k", ".voz"))
    try:
        recorte_wav(pcm, desde, hasta, crudo)
        volumen, silencios, segundos = preparar_pista(crudo, wav)
        mapa = compactar(wav, silencios, segundos, compacto) if volumen >= -50 else None
        segmentos = limpiar(a_hora_real(transcribir(compacto, config, etiqueta), mapa), silencios) if mapa else []
    finally:
        for archivo in (crudo, wav, compacto):
            archivo.unlink(missing_ok=True)
    corridos = [(a + desde, b + desde, t) for a, b, t in segmentos]
    return corridos, [(a + desde, min(b + desde, hasta)) for a, b in silencios]


def donde_cortar(pcm, desde, hasta, carpeta):
    """El medio del último silencio entre lo pendiente, para no partir una frase; None si conviene esperar."""
    if hasta - desde < TROZO_MINIMO:
        return None
    muestra, wav = carpeta / f"{pcm.stem}.corte.wav", carpeta / f"{pcm.stem}.corte.16k.wav"
    try:
        recorte_wav(pcm, desde, hasta, muestra)
        _, silencios, _ = preparar_pista(muestra, wav)
    finally:
        muestra.unlink(missing_ok=True)
        wav.unlink(missing_ok=True)
    cortes = [desde + (a + min(b, hasta - desde)) / 2 for a, b in silencios if a > 10]
    if cortes:
        return cortes[-1]
    return hasta if hasta - desde >= TROZO_MAXIMO else None


def en_vivo(carpeta, pistas, config):
    """Transcribe mientras se graba. pistas: [(ruta .pcm, quien)].
    Termina cuando aparece ".detener" (o si el audio deja de crecer mucho rato) con el último trozo.
    Devuelve ([(quien, segmentos)], duración, {quien: silencios})."""
    hecho = {quien: 0.0 for _, quien in pistas}
    segmentos = {quien: [] for _, quien in pistas}
    silencios = {quien: [] for _, quien in pistas}
    ultimo_largo, ultimo_cambio = -1.0, time.time()
    decir("ETAPA", "transcribiendo en vivo")
    while True:
        if not carpeta.exists():          # la descartaste: no queda nada que hacer
            sys.exit(0)
        detener = (carpeta / ".detener").exists()
        largos = {quien: segundos_pcm(pcm) for pcm, quien in pistas}
        if sum(largos.values()) != ultimo_largo:
            ultimo_largo, ultimo_cambio = sum(largos.values()), time.time()
        elif time.time() - ultimo_cambio > SIN_AUDIO_NUEVO:
            detener = True
        for pcm, quien in pistas:
            etiqueta = "tu micrófono" if pcm.name.startswith("micro") else "la llamada"
            hasta = largos[quien] if detener else donde_cortar(pcm, hecho[quien], largos[quien], carpeta)
            if hasta is None or hasta - hecho[quien] < 0.3:
                continue
            nuevos, sil = transcribir_trozo(pcm, hecho[quien], hasta, config, etiqueta, carpeta)
            segmentos[quien] += nuevos
            silencios[quien] += sil
            hecho[quien] = hasta
            if not detener:
                decir("ETAPA", f"transcribiendo en vivo · {int(min(hecho.values()) // 60)} min listos")
        if detener:
            break
        time.sleep(3)
    return [(q, segmentos[q]) for _, q in pistas if segmentos[q]], max(largos.values(), default=0.0), silencios


# ---------- 2c. Correcciones ----------

def leer_correcciones():
    """Tu lista de ~/Library/Application Support/Minuta/correcciones.txt ("Bucines → Business").
    Misma regla que en la app: palabras o frases completas, sin importar mayúsculas a la izquierda."""
    ruta = SOPORTE / "correcciones.txt"
    reglas = []
    if not ruta.exists():
        return reglas
    for linea in ruta.read_text(encoding="utf-8").splitlines():
        linea = linea.strip()
        if not linea or linea.startswith("#"):
            continue
        for flecha in ("→", "->", "=>", "="):
            if flecha in linea:
                mal, _, bien = linea.partition(flecha)
                mal, bien = mal.strip(), bien.strip()
                if mal and bien:
                    frase = r"\s+".join(re.escape(p) for p in mal.split())
                    reglas.append((re.compile(rf"(?<!\w){frase}(?!\w)", re.IGNORECASE), bien))
                break
    return reglas


def corregir(texto, reglas):
    for expresion, bien in reglas:
        texto = expresion.sub(lambda _: bien, texto)
    return texto


# ---------- 3. Juntar pistas ----------

def quitar_eco(mic, llamada):
    """Si usas parlantes, el micrófono también capta la llamada: borra esas frases repetidas."""
    def parecido(a, b):
        return difflib.SequenceMatcher(None, a.lower(), b.lower()).ratio()
    return [s for s in mic
            if not any(l[0] < s[1] + 1 and s[0] < l[1] + 1 and parecido(s[2], l[2]) > 0.6 for l in llamada)]


def juntar(pistas):
    """pistas: [(quien, segmentos)] → texto con un párrafo por turno de habla."""
    todos = sorted((s[0], s[1], quien, s[2]) for quien, segs in pistas for s in segs)
    turnos = []
    for inicio, fin, quien, texto in todos:
        if turnos and turnos[-1][2] == quien and inicio - turnos[-1][1] < 2.5:
            turnos[-1] = (turnos[-1][0], fin, quien, turnos[-1][3] + " " + texto)
        else:
            turnos.append((inicio, fin, quien, texto))
    una_voz = len({q for q, segs in pistas if segs}) <= 1
    lineas = []
    for inicio, _, quien, texto in turnos:
        hora = str(dt.timedelta(seconds=int(inicio))).zfill(8)
        lineas.append(f"[{hora}] {texto}" if una_voz and quien == "Audio" else f"[{hora}] {quien}: {texto}")
    return "\n\n".join(lineas)


# ---------- 4. Resumen ----------

def plantilla(config):
    for ruta in (config.get("plantilla"), SOPORTE / "plantilla.md", AQUI / "plantillas/resumen.md"):
        if ruta and Path(os.path.expanduser(str(ruta))).exists():
            return Path(os.path.expanduser(str(ruta))).read_text(encoding="utf-8")
    raise RuntimeError("No encontré la plantilla del resumen.")


def clave_api():
    if os.environ.get("ANTHROPIC_API_KEY"):
        return os.environ["ANTHROPIC_API_KEY"]
    r = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", "minuta-anthropic", "-w"],
                       capture_output=True, text=True)
    if r.returncode == 0 and r.stdout.strip():
        return r.stdout.strip()
    raise RuntimeError("Falta la clave de Anthropic. Guárdala con: "
                       "security add-generic-password -s minuta-anthropic -a minuta -w")


def resumir(transcripcion, datos, config, carpeta):
    instrucciones = plantilla(config)
    mensaje = f"{datos}\n\n<transcripcion>\n{transcripcion}\n</transcripcion>"
    if config["resumen_con"] == "api":
        cuerpo = json.dumps({
            "model": config["modelo_claude"] if config["modelo_claude"].startswith("claude-") else "claude-sonnet-5-5",
            "max_tokens": 8000, "system": instrucciones,
            "messages": [{"role": "user", "content": mensaje}],
        }).encode()
        pedido = urllib.request.Request("https://api.anthropic.com/v1/messages", data=cuerpo, headers={
            "x-api-key": clave_api(), "anthropic-version": "2023-06-01", "content-type": "application/json"})
        with urllib.request.urlopen(pedido, timeout=600) as r:
            respuesta = json.load(r)
        return "".join(b.get("text", "") for b in respuesta["content"]).strip()

    r = subprocess.run(
        [herramienta("claude"), "-p", "--model", config["modelo_claude"], "--tools", "",
         "--no-session-persistence", "--system-prompt", instrucciones],
        input=mensaje, capture_output=True, text=True, timeout=900, cwd=str(carpeta))
    if r.returncode != 0 or not r.stdout.strip():
        raise RuntimeError("Claude no respondió: " + (r.stderr or r.stdout).strip()[-300:])
    return r.stdout.strip()


def separar_titulo(resumen):
    """La plantilla pide que la primera línea sea "TITULO: ..."; la saco del texto y la devuelvo aparte."""
    lineas = resumen.splitlines()
    for i, linea in enumerate(lineas[:3]):
        if m := re.match(r"\s*T[IÍ]TULO\s*:\s*(.+)", linea, re.IGNORECASE):
            resto = lineas[:i] + lineas[i + 1:]
            return m.group(1).strip(), "\n".join(resto).strip() + "\n"
    return None, resumen.strip() + "\n"


def slug(texto):
    texto = unicodedata.normalize("NFKD", texto).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "-", texto).strip("-")[:50]


# ---------- Principal ----------

def main():
    global _log
    args = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    grupo = args.add_mutually_exclusive_group(required=True)
    grupo.add_argument("--carpeta", type=Path)
    grupo.add_argument("--archivo", type=Path)
    args.add_argument("--en-vivo", action="store_true",
                      help="con --carpeta: transcribe mientras se graba, hasta que aparezca .detener")
    args.add_argument("--sin-resumen", action="store_true",
                      help="solo transcribe (para probar sin llamar a Claude)")
    args = args.parse_args()
    config = cargar_config()
    if args.sin_resumen:
        config["resumen_con"] = "ninguno"

    if args.carpeta:
        carpeta = args.carpeta.expanduser()
        pistas = [(carpeta / "microfono.caf", config["nombre"]), (carpeta / "llamada.caf", "Llamada")]
        pistas = [(ruta, quien) for ruta, quien in pistas if ruta.exists() and ruta.stat().st_size > 0]
        origen = "grabación de Minuta"
    else:
        archivo = args.archivo.expanduser().resolve()
        carpeta = config["carpeta"] / f"{dt.datetime.now():%Y-%m-%d-%H%M}-{slug(archivo.stem) or 'audio'}"
        carpeta.mkdir(parents=True, exist_ok=True)
        pistas = [(archivo, "Audio")] if archivo.exists() else []
        origen = f"archivo {archivo}"

    _log = open(carpeta / "proceso.log", "a", encoding="utf-8")
    try:
        if not pistas and not args.en_vivo:
            raise RuntimeError("No hay audio para procesar.")
        if not config["modelo"].exists():
            raise RuntimeError(f"Falta el modelo de Whisper en {config['modelo']}")

        transcritas, duracion = [], 0.0
        vivas = [(carpeta / f"{ruta.stem}.pcm", quien) for ruta, quien in pistas] if args.carpeta else []
        if args.en_vivo:
            # Espera a que la grabación cree sus copias livianas (o termine sin ellas: grabador antiguo).
            while not any(pcm.exists() for pcm, _ in vivas) and not (carpeta / ".detener").exists():
                time.sleep(1)
                vivas = [(carpeta / f"{n}.pcm", q) for n, q in (("microfono", config["nombre"]), ("llamada", "Llamada"))]
            vivas = [(pcm, quien) for pcm, quien in vivas if pcm.exists()]
            if vivas:
                transcritas, duracion, _ = en_vivo(carpeta, vivas, config)
                decir("ETAPA", "terminando la transcripción")
            pistas = [(carpeta / f"{n}.caf", q) for n, q in (("microfono", config["nombre"]), ("llamada", "Llamada"))]
            pistas = [(ruta, quien) for ruta, quien in pistas if ruta.exists() and ruta.stat().st_size > 0]
        for ruta, quien in ([] if args.en_vivo and vivas else pistas):
            etiqueta = "audio" if quien == "Audio" else ("tu micrófono" if ruta.name.startswith("micro") else "la llamada")
            decir("ETAPA", f"preparando {etiqueta}")
            wav = carpeta / f"{ruta.stem}.16k.wav"
            volumen, silencios, segundos = preparar_pista(ruta, wav)
            duracion = max(duracion, segundos)
            compacto = carpeta / f"{ruta.stem}.voz.wav"
            mapa = compactar(wav, silencios, segundos, compacto) if volumen >= -50 else None
            wav.unlink(missing_ok=True)
            if mapa is None:
                decir("ETAPA", f"{etiqueta}: sin voz, la salto")
                compacto.unlink(missing_ok=True)
                continue
            segmentos = a_hora_real(transcribir(compacto, config, etiqueta), mapa)
            compacto.unlink(missing_ok=True)
            transcritas.append((quien, limpiar(segmentos, silencios)))

        por_quien = dict(transcritas)
        if config["nombre"] in por_quien and "Llamada" in por_quien:
            por_quien[config["nombre"]] = quitar_eco(por_quien[config["nombre"]], por_quien["Llamada"])
        texto = corregir(juntar(list(por_quien.items())), leer_correcciones())
        if not texto.strip():
            raise RuntimeError("No se escuchó a nadie hablar en la grabación.")

        fecha = dt.datetime.now()
        if m := re.match(r"(\d{4}-\d{2}-\d{2})-(\d{2})(\d{2})", carpeta.name):
            fecha = dt.datetime.strptime(m.group(0), "%Y-%m-%d-%H%M")
        minutos = round(duracion / 60)
        hablantes = ", ".join(por_quien) or "—"
        encabezado = (f"Transcripción · {fecha:%Y-%m-%d %H:%M} · {minutos} min\n"
                      f"Origen: {origen}\nPistas: {hablantes}\n\n")
        (carpeta / "transcripcion.md").write_text(encabezado + texto + "\n", encoding="utf-8")
        # Las copias livianas ya no sirven: el audio bueno queda en los .caf.
        for sobra in (carpeta / "microfono.pcm", carpeta / "llamada.pcm", carpeta / ".detener"):
            sobra.unlink(missing_ok=True)

        resumen_md = carpeta / "resumen.md"
        if config["resumen_con"] == "ninguno":
            decir("LISTO", str(carpeta / "transcripcion.md"))
            return 0

        decir("ETAPA", "resumiendo con Claude")
        datos = (f"Fecha: {fecha:%Y-%m-%d %H:%M}. Duración: {minutos} min.\n"
                 f"Pistas: {hablantes}. "
                 f"\"{config['nombre']}\" es el micrófono del Mac (la persona que grabó; si la reunión fue "
                 f"presencial, también se escucha ahí al resto de la sala). \"Llamada\" es todo lo que sonó por "
                 f"el computador (puede ser más de una persona). \"Audio\" es un archivo de una sola pista.")
        try:
            resumen = resumir(texto, datos, config, carpeta)
        except Exception as e:  # la transcripción ya quedó guardada: aviso y entrego eso
            decir("ERROR", f"El resumen falló ({e}). La transcripción quedó guardada.")
            decir("LISTO", str(carpeta / "transcripcion.md"))
            return 2
        titulo, resumen = separar_titulo(resumen)
        # La plantilla puede agregar una minuta comercial después de "===MINUTA===": va en su propio archivo.
        resumen, _, minuta = resumen.partition("===MINUTA===")
        resumen_md.write_text(resumen.strip() + "\n", encoding="utf-8")
        if minuta.strip():
            (carpeta / "minuta.md").write_text(minuta.strip() + "\n", encoding="utf-8")

        if config["borrar_audio"] and args.carpeta:
            for ruta, _ in pistas:
                ruta.unlink(missing_ok=True)

        if titulo and slug(titulo) and re.fullmatch(r"\d{4}-\d{2}-\d{2}-\d{4}", carpeta.name):
            nueva = carpeta.with_name(f"{carpeta.name}-{slug(titulo)}")
            if not nueva.exists():
                _log.close()
                carpeta.rename(nueva)
                carpeta = nueva
                _log = open(carpeta / "proceso.log", "a", encoding="utf-8")
        decir("LISTO", str(carpeta / "resumen.md"))
        return 0
    except Exception as e:
        decir("ERROR", str(e))
        return 1
    finally:
        _log.close()


if __name__ == "__main__":
    sys.exit(main())
