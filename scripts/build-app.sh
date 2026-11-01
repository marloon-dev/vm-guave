#!/usr/bin/env bash
# Compila o VM Guave, monta o "VM Guave.app" e assina (ad-hoc) com a entitlement de virtualização.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/VM Guave.app"

# As Command Line Tools não trazem os plugins de macro do SwiftUI (@State); usa o Xcode se existir.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "$ROOT"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

# Ícone: refaz o .icns quando Resources/AppIcon.png muda.
ICNS="$ROOT/build/AppIcon.icns"
if [[ ! -f "$ICNS" || "$ROOT/Resources/AppIcon.png" -nt "$ICNS" ]]; then
    ICONSET="$ROOT/build/AppIcon.iconset"
    rm -rf "$ICONSET" && mkdir -p "$ICONSET"
    swift "$ROOT/scripts/make-icon.swift" "$ROOT/Resources/AppIcon.png" "$ROOT/build/AppIcon-1024.png"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$ROOT/build/AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) "$ROOT/build/AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$ICNS"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/BootGuave" "$APP/Contents/MacOS/BootGuave"
cp "$BIN_DIR/bgctl" "$APP/Contents/MacOS/bgctl"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"

# SIGN_IDENTITY="Developer ID Application: ..." para distribuir; padrão é ad-hoc (só roda sem alerta neste Mac).
# O bgctl é assinado antes, sem a entitlement de virtualização (ele só fala com o app).
codesign --force --sign "${SIGN_IDENTITY:--}" --options runtime "$APP/Contents/MacOS/bgctl"
codesign --force --sign "${SIGN_IDENTITY:--}" \
    --entitlements "$ROOT/Resources/BootGuave.entitlements" \
    --options runtime \
    "$APP"

echo "Pronto: $APP"
