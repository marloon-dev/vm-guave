#!/usr/bin/env bash
# Gera o instalador build/VMGuave-<versão>.dmg (arrastar o app para Aplicativos).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-app.sh" release

APP="$ROOT/build/VM Guave.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/build/VMGuave-$VERSION.dmg"
STAGING="$ROOT/build/dmg-staging"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Aplicativos"
cp "$ROOT/build/AppIcon.icns" "$STAGING/.VolumeIcon.icns"

# Imagem gravável temporária → ajusta ícone do volume → comprime.
RW="$ROOT/build/rw.dmg"
rm -f "$RW"
hdiutil create -volname "VM Guave" -srcfolder "$STAGING" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\// {print $NF}')"
SetFile -a C "$MOUNT" 2>/dev/null || true
hdiutil detach "$MOUNT" -quiet
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -rf "$RW" "$STAGING"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" "$DMG"
fi

# Com Developer ID: NOTARY_PROFILE é o perfil salvo com
#   xcrun notarytool store-credentials <perfil> --apple-id … --team-id …
# A Apple confere o app e o "grampo" deixa o Gatekeeper aceitá-lo sem internet.
if [[ -n "${SIGN_IDENTITY:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "Instalador: $DMG"
