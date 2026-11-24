#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"
umask 077

pin=true
uninstall=false
for option in "$@"; do
  case "$option" in
    --no-dock) pin=false ;;
    --uninstall) uninstall=true ;;
    *) echo 'Usage: ./install.sh [--no-dock] [--uninstall]' >&2; exit 2 ;;
  esac
done

apps=${RAINBOW_APPLICATIONS_DIR:-"$HOME/Applications"}
mkdir -p "$apps"
dest="$apps/Codex Rainbow.app"
if [[ -e "$dest" || -L "$dest" ]]; then
  if [[ -L "$dest" ]] || [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$dest/Contents/Info.plist" 2>/dev/null || :)" != tools.codexrainbow.launcher ]]; then
    echo "A different app already occupies $dest. Choose another RAINBOW_APPLICATIONS_DIR." >&2
    exit 1
  fi
fi

if $uninstall; then
  if [[ -d "$dest" ]]; then
    if $pin; then "$dest/Contents/MacOS/rainbow" dock-remove; fi
    "$dest/Contents/MacOS/rainbow" trash-launcher
  fi
  echo 'Launcher removed. Your saved colors are still available.'
  exit 0
fi

build=${RAINBOW_BUILD_DIR:-"$PWD/dist/launcher"}
./build.sh "$build" --launcher
"$build/Codex Rainbow.app/Contents/MacOS/rainbow" launcher-check
# Stage on the destination volume for an atomic first install or upgrade.
stage=$(mktemp -d "$apps/.codex-rainbow.XXXXXXXX")
trap 'rm -rf -- "$stage"' EXIT
/usr/bin/ditto "$build/Codex Rainbow.app" "$stage/Codex Rainbow.app"
/usr/bin/codesign --verify --strict "$stage/Codex Rainbow.app"
/usr/bin/python3 - "$stage/Codex Rainbow.app" "$dest" <<'PY'
import ctypes
import fcntl
import os
import plistlib
import sys
source, dest = sys.argv[1:]
libc = ctypes.CDLL(None, use_errno=True)
# RENAME_EXCL prevents a first-install race. RENAME_SWAP keeps the previous build
# in staging until the replacement is in place.
lock = os.open(os.path.dirname(dest), os.O_RDONLY)
fcntl.flock(lock, fcntl.LOCK_EX)
if os.path.lexists(dest):
    if os.path.islink(dest):
        raise SystemExit("Refusing to replace a symlink.")
    with open(os.path.join(dest, "Contents", "Info.plist"), "rb") as info:
        if plistlib.load(info).get("CFBundleIdentifier") != "tools.codexrainbow.launcher":
            raise SystemExit("The destination changed during the build. Existing app preserved.")
flag = 2 if os.path.exists(dest) else 4
if libc.renamex_np(os.fsencode(source), os.fsencode(dest), flag):
    error = ctypes.get_errno()
    raise OSError(error, os.strerror(error), dest)
PY
"$dest/Contents/MacOS/rainbow" launcher-check
if $pin; then "$dest/Contents/MacOS/rainbow" dock-install; fi
echo "Installed $dest. On your next launch, open Codex Rainbow to restore your row colors."
