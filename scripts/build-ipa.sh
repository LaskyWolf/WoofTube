#!/usr/bin/env bash
# Builds the tweaks and injects them into a decrypted YouTube IPA.
# Usage: scripts/build-ipa.sh path/to/YouTube.ipa [output.ipa]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export THEOS="${THEOS:-$HOME/theos}"
BUILD="$ROOT/.build"
IPA="${1:-}"
OUT="${2:-$ROOT/out/WoofTube.ipa}"

if [[ -z "$IPA" || ! -f "$IPA" ]]; then
    echo "Usage: scripts/build-ipa.sh path/to/YouTube.ipa [output.ipa]" >&2
    exit 1
fi

binary="$(unzip -Z1 "$IPA" | grep -E '^Payload/[^/]+\.app/YouTube$' | head -n 1 || true)"
if [[ -z "$binary" ]]; then
    echo "$IPA is not a YouTube IPA (Payload/*.app/YouTube is missing)." >&2
    exit 1
fi

# An App Store IPA is encrypted and crashes on launch once injected.
export PATH="$THEOS/toolchain/linux/iphone/bin:$PATH"
mkdir -p "$BUILD"
unzip -p "$IPA" "$binary" > "$BUILD/YouTube.bin"
if otool -l "$BUILD/YouTube.bin" | grep -q 'cryptid 1'; then
    echo "$IPA is encrypted. Use a decrypted YouTube IPA." >&2
    exit 1
fi
rm "$BUILD/YouTube.bin"

"$ROOT/scripts/build-tweaks.sh"

if [[ ! -x "$BUILD/venv/bin/cyan" ]]; then
    echo "==> Installing cyan"
    python3 -m venv "$BUILD/venv"
    "$BUILD/venv/bin/pip" install --quiet https://github.com/asdfzxcvbn/pyzule-rw/archive/main.zip
fi

echo "==> Injecting tweaks"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
# -u remove device restrictions, -w remove watch app, -e remove app extensions, -f fakesign
"$BUILD/venv/bin/cyan" -i "$IPA" -o "$OUT" -uwef "$BUILD"/dylibs/*.dylib

echo "==> Done: $OUT"
