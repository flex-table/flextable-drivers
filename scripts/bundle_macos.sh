#!/usr/bin/env bash
# Bundle a portable macOS Instant Client (or other native driver) for one arch.
#
# Reads the pinned (url, sha256) for `<namespace>` + `macos-<arch>` from
# config/<namespace>.json, downloads + sha256-verifies the vendor package, copies
# its dylibs into a single symlink-free bundle root, rewrites Mach-O load paths to
# @loader_path so the libs find each other with no DYLD_LIBRARY_PATH, ad-hoc signs
# (Developer-ID re-sign is deferred to the macOS Gatekeeper spike - see the app
# repo Q3 decision), clears quarantine, and zips + sha256's for the signed manifest.
#
# Layout (matches the app install contract; the app copies CONTENTS into
# tools/<namespace>-<major>/):
#   <out>/<namespace>-<major>-macos-<arch>/
#     libclntsh.dylib libclntshcore.dylib libnnz.dylib libociei.dylib ...
#
# Usage: scripts/bundle_macos.sh <namespace> <major> <arch> <out_dir>
set -euo pipefail

NS="${1:?namespace, e.g. oracle-instantclient}"
MAJOR="${2:?major, e.g. 23}"
ARCH="${3:?arch: arm64 | x86_64}"
OUT="${4:?output dir}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

TARGET="macos-${ARCH}"
CFG="${ROOT}/config/${NS}.json"
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

NAME="${NS}-${MAJOR}-macos-${ARCH}"
STAGE="${OUT}/${NAME}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; hdiutil detach "$MP" >/dev/null 2>&1 || true' EXIT
rm -rf "$STAGE"; mkdir -p "$STAGE"

echo "==> download + verify ${URL##*/}"
curl -fL --retry 3 -o "$WORK/pkg.dmg" "$URL"
GOT="$(shasum -a 256 "$WORK/pkg.dmg" | cut -d' ' -f1)"
[ "$GOT" = "$SHA" ] || { echo "SHA256 MISMATCH: expected $SHA got $GOT"; exit 1; }

echo "==> mount + copy dylibs (dereference symlinks -> symlink-free bundle)"
MP="$(hdiutil attach "$WORK/pkg.dmg" -nobrowse -readonly | grep -o '/Volumes/.*' | head -1)"
# cp -RL follows symlinks so the bundle contains real files only (the installer's
# copy_tree rejects symlinks as a path-escape guard). Copy the loadable libs.
for f in "$MP"/*.dylib*; do [ -e "$f" ] && cp -RL "$f" "$STAGE/"; done

# OTN condition: Oracle's notices must travel WITH the redistributed libraries.
# The Instant Client package carries them beside the libs as BASIC_LICENSE / BASIC_README
# (verified against instantclient-basic-linux.x64-23.26.3.0.0). Fail loudly if none is
# found rather than shipping a bundle that silently drops the licence.
echo "==> stage Oracle notices (BASIC_LICENSE / BASIC_README)"
found=0
for f in "$MP"/*LICENSE* "$MP"/*README*; do
  [ -e "$f" ] || continue
  cp -RL "$f" "$STAGE/"; found=$((found+1))
done
[ "$found" -gt 0 ] || { echo "ERROR: no Oracle LICENSE/README found in $MP - refusing to ship without the notices"; exit 4; }
echo "    staged $found notice file(s)"
hdiutil detach "$MP" >/dev/null; MP=""

echo "==> rewrite load paths -> @loader_path (libs find siblings with no DYLD)"
shopt -s nullglob
for lib in "$STAGE"/*.dylib*; do
  base="$(basename "$lib")"
  install_name_tool -id "@loader_path/${base}" "$lib" 2>/dev/null || true
  otool -L "$lib" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    case "$dep" in
      /usr/lib/*|/System/*|@loader_path/*|@rpath/*) continue;;
    esac
    depbase="$(basename "$dep")"
    [ -e "$STAGE/$depbase" ] && install_name_tool -change "$dep" "@loader_path/${depbase}" "$lib" 2>/dev/null || true
  done
done

echo "==> ad-hoc codesign (Developer-ID re-sign is the deferred Gatekeeper spike)"
# install_name_tool invalidates any signature; re-sign so the libs load. Ad-hoc
# (-) is enough for a dev/self-hosted build; the production Dev-ID re-sign +
# library-validation entitlement is the app-repo Q3 spike, not wired here yet.
for lib in "$STAGE"/*.dylib*; do codesign --remove-signature "$lib" 2>/dev/null || true; codesign -s - -f "$lib"; done
xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null || true

echo "==> zip + sha256"
( cd "$OUT" && zip -qry "${NAME}.zip" "$NAME" && shasum -a 256 "${NAME}.zip" > "${NAME}.zip.sha256" )
echo "OK: ${OUT}/${NAME}.zip"
cat "${OUT}/${NAME}.zip.sha256"
