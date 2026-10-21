#!/bin/bash
# Compila Minuta, arma Minuta.app y la deja en ~/Applications.
# Uso: scripts/instalar.sh [--sin-modelo]
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
SOPORTE="$HOME/Library/Application Support/Minuta"
MODELO="$SOPORTE/ggml-large-v3-turbo.bin"
DESTINO="$HOME/Applications/Minuta.app"

echo "→ Revisando herramientas"
command -v brew >/dev/null || { echo "Falta Homebrew: https://brew.sh"; exit 1; }
command -v ffmpeg >/dev/null || brew install ffmpeg
command -v whisper-cli >/dev/null || brew install whisper-cpp

mkdir -p "$SOPORTE"
if [[ "${1:-}" != "--sin-modelo" && ! -f "$MODELO" ]]; then
  echo "→ Bajando el modelo de Whisper (large-v3-turbo, ~1,6 GB)"
  curl -L --fail -o "$MODELO.part" \
    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
  mv "$MODELO.part" "$MODELO"
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
# Firma local (ad hoc): basta para correr en tu Mac. Para repartirla a otros hay que firmar con Apple.
codesign --force --deep --sign - "$APP"

mkdir -p "$HOME/Applications"
pkill -x Minuta 2>/dev/null || true
rm -rf "$DESTINO"
cp -R "$APP" "$DESTINO"
echo "✓ Instalada en $DESTINO"
echo "  Ábrela con: open \"$DESTINO\""
