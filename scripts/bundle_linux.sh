#!/usr/bin/env bash
# Bundle a portable linux Instant Client (or other native driver) for one arch.
# Reads the pinned (url, sha256) for `<namespace>` + `linux-<arch>` from
# config/<namespace>.json, downloads + sha256-verifies, stages the .so closure,
# sets an $ORIGIN rpath so the libs find each other with no LD_LIBRARY_PATH, and
# zips + sha256's. No secrets, no signing (linux needs none).
#
# Layout: <out>/<namespace>-<major>-linux-<arch>/  (real files, symlink-free)
#
# Usage: scripts/bundle_linux.sh <namespace> <major> <arch> <out_dir>
set -euo pipefail

NS="${1:?namespace}"; MAJOR="${2:?major}"; ARCH="${3:?arch}"; OUT="${4:?out dir}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="linux-${ARCH}"; CFG="${ROOT}/config/${NS}.json"

URL="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['targets'][sys.argv[2]]['url'])" "$CFG" "$TARGET")"
SHA="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['targets'][sys.argv[2]]['sha256'])" "$CFG" "$TARGET")"
case "$URL$SHA" in *TODO*) echo "ERROR: $TARGET not pinned in $CFG (URL/sha are TODO)"; exit 2;; esac

NAME="${NS}-${MAJOR}-linux-${ARCH}"; STAGE="${OUT}/${NAME}"; WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
rm -rf "$STAGE"; mkdir -p "$STAGE"

echo "==> download + verify ${URL##*/}"
curl -fL --retry 3 -o "$WORK/pkg.zip" "$URL"
GOT="$(sha256sum "$WORK/pkg.zip" | cut -d' ' -f1)"
[ "$GOT" = "$SHA" ] || { echo "SHA256 MISMATCH: expected $SHA got $GOT"; exit 1; }

echo "==> extract + stage .so closure (dereference symlinks)"
unzip -q "$WORK/pkg.zip" -d "$WORK/x"
ICDIR="$(dirname "$(find "$WORK/x" -name 'libclntsh.so*' | head -1)")"
for f in "$ICDIR"/*.so*; do [ -e "$f" ] && cp -L "$f" "$STAGE/"; done

echo "==> set rpath \$ORIGIN so siblings resolve with no LD_LIBRARY_PATH"
command -v patchelf >/dev/null || { sudo apt-get update -y && sudo apt-get install -y patchelf; }
for so in "$STAGE"/*.so*; do patchelf --set-rpath '$ORIGIN' "$so" 2>/dev/null || true; done

echo "==> zip + sha256"
( cd "$OUT" && zip -qry "${NAME}.zip" "$NAME" && sha256sum "${NAME}.zip" > "${NAME}.zip.sha256" )
echo "OK: ${OUT}/${NAME}.zip"; cat "${OUT}/${NAME}.zip.sha256"
