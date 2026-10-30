#!/usr/bin/env bash
# Downloads and compiles the bundled tweaks into .build/dylibs/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export THEOS="${THEOS:-$HOME/theos}"
BUILD="$ROOT/.build"

# Tweaks injected into the IPA, as GitHub owner/repo.
# YTABGoodies is a runtime dependency of YouTube-X.
# YTPlaybackFix recovers playback that sideloaded installs lose after seeking.
TWEAKS=(PoomSmart/YTABGoodies PoomSmart/YouTube-X Mark02-2012/YTPlaybackFix)

if [[ ! -x "$THEOS/toolchain/linux/iphone/bin/clang" ]]; then
    echo "Theos not found at $THEOS. Run scripts/setup-theos.sh first." >&2
    exit 1
fi

# Fetches a repo, or fast-forwards it to the latest commit.
sync_repo() {
    local repo="$1" dir="$2"
    if [[ -d "$dir/.git" ]]; then
        git -C "$dir" pull --quiet --ff-only
    else
        git clone --quiet --depth 1 "https://github.com/$repo.git" "$dir"
    fi
    echo "    $repo @ $(git -C "$dir" rev-parse --short HEAD)"
}

echo "==> Fetching sources"
sync_repo PoomSmart/YouTubeHeader "$THEOS/include/YouTubeHeader"
for repo in "${TWEAKS[@]}"; do
    sync_repo "$repo" "$BUILD/src/${repo#*/}"
done

rm -rf "$BUILD/dylibs"
mkdir -p "$BUILD/dylibs"
for dir in "${TWEAKS[@]/#*\//$BUILD/src/}" "$ROOT/tweak"; do
    echo "==> Building $(basename "$dir")"
    command make -C "$dir" FINALPACKAGE=1 --no-print-directory >/dev/null
    cp "$dir"/.theos/obj/*.dylib "$BUILD/dylibs/"
done

echo "==> Built: $(cd "$BUILD/dylibs" && echo *.dylib)"
