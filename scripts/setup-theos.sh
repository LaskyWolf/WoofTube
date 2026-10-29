#!/usr/bin/env bash
# Installs Theos, the iOS toolchain and the iOS SDK without sudo.
# Safe to run again: finished steps are skipped.
set -euo pipefail

export THEOS="${THEOS:-$HOME/theos}"
ARCH="$(uname -m)"

if [[ "$(uname -s)" != "Linux" || ! "$ARCH" =~ ^(x86_64|aarch64)$ ]]; then
    echo "This script supports Linux on x86_64 or aarch64 only." >&2
    echo "For other systems, follow https://theos.dev/docs/installation" >&2
    exit 1
fi

missing=()
for cmd in git curl tar xz perl make python3 unzip; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
done
if (( ${#missing[@]} )); then
    echo "Missing commands: ${missing[*]}" >&2
    echo "Install them with your package manager, then run this script again." >&2
    exit 1
fi

if [[ ! -d "$THEOS/makefiles" ]]; then
    echo "==> Cloning Theos into $THEOS"
    git clone --quiet --recursive https://github.com/theos/theos.git "$THEOS"
fi

if [[ ! -x "$THEOS/toolchain/linux/iphone/bin/clang" ]]; then
    echo "==> Downloading the iOS toolchain"
    curl -fsSL "https://github.com/L1ghtmann/llvm-project/releases/latest/download/iOSToolchain-$ARCH.tar.xz" \
        | tar -xJf - -C "$THEOS/toolchain/"
fi

if ! ls "$THEOS/sdks" 2>/dev/null | grep -q '\.sdk$'; then
    echo "==> Downloading the iOS SDK"
    "$THEOS/bin/install-sdk" latest
fi

echo "==> Theos is ready at $THEOS"
if [[ "$THEOS" == "$HOME/theos" ]]; then
    echo "    The build scripts find it there automatically."
else
    echo "    Export THEOS=$THEOS before running the build scripts."
fi
