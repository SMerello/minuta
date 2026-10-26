#!/bin/bash
# Compila Minuta, arma Minuta.app y la deja en ~/Applications.
# Uso: scripts/instalar.sh [--sin-modelo]
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
SOPORTE="$HOME/Library/Application Support/Minuta"
MODELO="$SOPORTE/ggml-large-v3-turbo-q8_0.bin"
DESTINO="$HOME/Applications/Minuta.app"

echo "→ Revisando herramientas"
command -v brew >/dev/null || { echo "Falta Homebrew: https://brew.sh"; exit 1; }
command -v ffmpeg >/dev/null || brew install ffmpeg
command -v whisper-cli >/dev/null || brew install whisper-cpp

mkdir -p "$SOPORTE"
if [[ "${1:-}" != "--sin-modelo" && ! -f "$MODELO" ]]; then
  echo "→ Bajando el modelo de Whisper (large-v3-turbo comprimido q8, ~830 MB)"
  curl -L --fail -o "$MODELO.part" \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin
  mv "$MODELO.part" "$MODELO"
fi
# Detector de voz (menos de 1 MB): el dictado no le pasa a Whisper el ruido ni la música, donde inventa frases.
DETECTOR="$SOPORTE/ggml-silero-v5.1.2.bin"
if [[ "${1:-}" != "--sin-modelo" && ! -f "$DETECTOR" ]]; then
  echo "→ Bajando el detector de voz (Silero, <1 MB)"
  curl -L --fail -o "$DETECTOR.part" https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin
  mv "$DETECTOR.part" "$DETECTOR"
fi

echo "→ Compilando"
swift build -c release --package-path "$RAIZ"
BIN="$(swift build -c release --package-path "$RAIZ" --show-bin-path)/Minuta"

echo "→ Armando Minuta.app"
APP="$RAIZ/.build/Minuta.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Minuta"
cp "$RAIZ/Recursos/Info.plist" "$APP/Contents/Info.plist"
cp "$RAIZ/Recursos/procesar.py" "$RAIZ/Recursos/Minuta.icns" "$APP/Contents/Resources/"
cp -R "$RAIZ/Recursos/plantillas" "$APP/Contents/Resources/"
# Firma con un certificado del llavero ("Apple Development" o el que diga MINUTA_FIRMA).
# Así macOS reconoce la misma app en cada reinstalación y no se pierden los permisos
# (micrófono, grabación de pantalla, accesibilidad). La firma ad hoc cambia en cada
# compilación, por eso queda solo de respaldo si no hay certificado.
FIRMA="${MINUTA_FIRMA:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Apple Development/ {print $2; exit}')}"
if [[ -n "$FIRMA" ]]; then
  echo "→ Firmando con: $FIRMA"
  codesign --force --deep --sign "$FIRMA" "$APP"
else
  echo "⚠ No encontré un certificado para firmar: uso firma ad hoc."
  echo "  Los permisos se van a perder en cada reinstalación."
  codesign --force --deep --sign - "$APP"
fi

mkdir -p "$HOME/Applications"
pkill -x Minuta 2>/dev/null || true
rm -rf "$DESTINO"
cp -R "$APP" "$DESTINO"
echo "✓ Instalada en $DESTINO"
echo "  Ábrela con: open \"$DESTINO\""
