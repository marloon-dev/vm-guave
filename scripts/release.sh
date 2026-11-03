#!/usr/bin/env bash
# Publica uma versão nova do VM Guave. Os apps abertos detectam em até 10 minutos (ou na hora,
# quando o app volta para a frente) e oferecem atualizar sozinhos.
#
#   ./scripts/release.sh 0.3.0 "Notas da versão em Markdown"
#   ./scripts/release.sh 0.3.0 notas.md
#
# Faz: versão no Info.plist → commit → instalador .dmg → tag v<versão> → Release no GitHub com o
# .dmg anexado. A tag dispara o GitHub Actions, que anexa os instaladores de Windows e Linux à
# mesma Release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?Use: ./scripts/release.sh <versão> <notas ou arquivo .md>}"
NOTES="${2:?Informe as notas da versão (texto ou arquivo .md)}"
cd "$ROOT"

[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "Versão inválida: $VERSION (ex.: 0.3.0)"; exit 1; }
git diff --quiet && git diff --cached --quiet || { echo "Há mudanças sem commit. Faça o commit antes de publicar."; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "A tag v$VERSION já existe."; exit 1; }
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
command -v gh >/dev/null || { echo "Instale o GitHub CLI (brew install gh) e faça gh auth login."; exit 1; }
# A chave de assinatura das atualizações (Keychain) tem de existir antes de criar a tag.
swift "$ROOT/scripts/update-signing.swift" public >/dev/null || exit 1

PLIST="$ROOT/Resources/Info.plist"
CURRENT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
if [[ "$CURRENT" != "$VERSION" ]]; then
    /usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set CFBundleVersion $((BUILD + 1))" "$PLIST"
    git add "$PLIST"
    git commit -q -m "Versão $VERSION"
fi

"$ROOT/scripts/make-dmg.sh"
DMG="$ROOT/build/VMGuave-$VERSION.dmg"
[[ -f "$DMG" ]] || { echo "Instalador não encontrado: $DMG"; exit 1; }

# Assinatura Ed25519: os apps instalados só aceitam atualizações assinadas com esta chave.
swift "$ROOT/scripts/update-signing.swift" sign "$DMG"

git tag "v$VERSION"
git push -q origin HEAD "v$VERSION"

if [[ -f "$NOTES" ]]; then NOTES_ARGS=(--notes-file "$NOTES"); else NOTES_ARGS=(--notes "$NOTES"); fi
gh release create "v$VERSION" "$DMG" "$DMG.sig" --title "VM Guave $VERSION" "${NOTES_ARGS[@]}" --latest

echo "Publicada: VM Guave $VERSION. Os apps abertos vão oferecer a atualização."
