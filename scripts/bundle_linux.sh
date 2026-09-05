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

# Multi-major configs nest their pinned targets under `majors.<major>.targets`; the
# original single-major shape kept a flat `targets` map. Read BOTH so a namespace that
# only ever ships one major needs no migration.
PIN="$(python3 -c '
import json,sys
cfg=json.load(open(sys.argv[1])); target=sys.argv[2]; major=str(sys.argv[3])
t=(cfg.get("majors",{}).get(major,{}).get("targets") or cfg.get("targets",{})).get(target)
if not t: raise SystemExit("target %s (major %s) not pinned in config" % (target, major))
print(t["url"]); print(t["sha256"])
' "$CFG" "$TARGET" "$MAJOR")"
URL="$(printf "%s\n" "$PIN" | sed -n 1p)"
SHA="$(printf "%s\n" "$PIN" | sed -n 2p)"
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

# OTN condition: Oracle's notices must travel WITH the redistributed libraries.
# The Instant Client package carries them beside the libs as BASIC_LICENSE / BASIC_README
# (verified against instantclient-basic-linux.x64-23.26.3.0.0). Fail loudly if none is
# found rather than shipping a bundle that silently drops the licence.
echo "==> stage Oracle notices (BASIC_LICENSE / BASIC_README)"
found=0
for f in "$ICDIR"/*LICENSE* "$ICDIR"/*README*; do
  [ -e "$f" ] || continue
  cp -L "$f" "$STAGE/"; found=$((found+1))
done
[ "$found" -gt 0 ] || { echo "ERROR: no Oracle LICENSE/README found in $ICDIR - refusing to ship without the notices"; exit 4; }
echo "    staged $found notice file(s)"

echo "==> bundle libaio.so.1 (the client's DT_NEEDED)"
# The Instant Client links against libaio.so.1, which is NOT part of Oracle's zip and is
# absent on minimal distros/containers -> DPI-1047 "libaio.so.1: cannot open shared object
# file". Ubuntu 24.04 further renamed the package to libaio1t64 (soname libaio.so.1t64),
# so the system file may not even be called libaio.so.1. We therefore copy whatever the
# host has and install it under the name the client actually asks for (libaio.so.1) in the
# bundle root; $ORIGIN is on the search path, so the loader satisfies DT_NEEDED from the
# bundle with no system package. The 1t64 build is the 64-bit-time_t rebuild of the same
# ABI, so serving it under the legacy name is safe for these calls.
command -v ldconfig >/dev/null || true
AIO="$(ldconfig -p 2>/dev/null | awk '/libaio\.so\.1(t64)?$/ {print $NF; exit}')"
if [ -z "${AIO:-}" ]; then
  sudo apt-get update -y && { sudo apt-get install -y libaio1 || sudo apt-get install -y libaio1t64; }
  AIO="$(ldconfig -p 2>/dev/null | awk '/libaio\.so\.1(t64)?$/ {print $NF; exit}')"
fi
[ -n "${AIO:-}" ] || { echo "ERROR: libaio.so.1 not found on the build host"; exit 3; }
cp -L "$AIO" "$STAGE/libaio.so.1"
echo "    bundled $AIO -> libaio.so.1"

echo "==> set rpath \$ORIGIN so siblings resolve with no LD_LIBRARY_PATH"
command -v patchelf >/dev/null || { sudo apt-get update -y && sudo apt-get install -y patchelf; }
for so in "$STAGE"/*.so*; do patchelf --set-rpath '$ORIGIN' "$so" 2>/dev/null || true; done

echo "==> zip + sha256"
( cd "$OUT" && zip -qry "${NAME}.zip" "$NAME" && sha256sum "${NAME}.zip" > "${NAME}.zip.sha256" )
echo "OK: ${OUT}/${NAME}.zip"; cat "${OUT}/${NAME}.zip.sha256"
