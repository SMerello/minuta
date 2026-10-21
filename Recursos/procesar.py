#!/usr/bin/env python3
"""Transcribe y resume una reunión grabada con Minuta (o cualquier audio).

Uso:
  procesar.py --carpeta ~/Reuniones/2026-10-21-1530   # carpeta con microfono.caf y/o llamada.caf
  procesar.py --archivo ~/Downloads/nota-de-voz.m4a   # cualquier audio o video

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


def a_hora_real(segmentos, mapa):
    """Pasa los segmentos de Whisper a la hora real. Si un segmento cruza de un tramo a otro
    (dos frases que en la reunión estaban separadas), lo corta usando la hora de cada palabra."""
    def real(t, i):
        inicio, fin, original = mapa[i]
        return original + min(max(0.0, t - inicio), fin - inicio)

    salida = []
    for desde, hasta, texto, fichas in segmentos:
        grupos = []
        for f_desde, f_hasta, f_texto in fichas:
            i = tramo_de((f_desde + f_hasta) / 2, mapa)
            if grupos and grupos[-1][0] == i:
                grupos[-1][2] = f_hasta
                grupos[-1][3] += f_texto
            else:
                grupos.append([i, f_desde, f_hasta, f_texto])
        if len(grupos) <= 1:
            i = tramo_de(desde, mapa)
            salida.append((real(desde, i), real(hasta, tramo_de(hasta, mapa)), texto))
        else:
            salida += [(real(a, i), real(b, i), t.strip()) for i, a, b, t in grupos if t.strip()]
    return salida


def fraccion_con_voz(inicio, fin, silencios):
    largo = max(fin - inicio, 1e-3)
    en_silencio = sum(max(0.0, min(fin, b) - max(inicio, a)) for a, b in silencios)
    return 1 - en_silencio / largo


# ---------- 2. Whisper ----------

def transcribir(wav, config, etiqueta):
    base = wav.with_suffix("")          # whisper agrega ".json" a este nombre
    salida_json = Path(f"{base}.json")
    comando = [herramienta("whisper-cli"), "-m", str(config["modelo"]), "-f", str(wav),
               "-l", config["idioma"], "-oj", "-ojf", "-of", str(base), "-pp", "-np"]
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
        fichas = [(t["offsets"]["from"] / 1000, t["offsets"]["to"] / 1000, t["text"])
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
    args = args.parse_args()
    config = cargar_config()

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
        if not pistas:
            raise RuntimeError("No hay audio para procesar.")
        if not config["modelo"].exists():
            raise RuntimeError(f"Falta el modelo de Whisper en {config['modelo']}")

        transcritas, duracion = [], 0.0
        for ruta, quien in pistas:
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
        texto = juntar(list(por_quien.items()))
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
        resumen_md.write_text(resumen, encoding="utf-8")

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
