#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "$0")"

if [[ "$(uname -s)" != Darwin ]]; then
  printf 'Codex Rainbow requires macOS.\n' >&2
  exit 1
fi

output=${1:-"$PWD/dist"}
name="Codex Rainbow"
command="rainbow"
mode=${2:---launcher}
if [ "$mode" = "--preview" ]; then
  name="Rainbow Preview"
  command="rainbow-preview"
elif [ "$mode" = "--launcher" ]; then
  name="Codex Rainbow"
elif [ "$mode" != "--overlay" ]; then
  printf 'Unknown build option: %s\n' "$mode" >&2
  exit 1
fi
mkdir -p "$output/module-cache" "$output/$name.app/Contents/MacOS"
output=$(cd -- "$output" && pwd)
app="$output/$name.app"

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx13.0" -warnings-as-errors \
  -module-cache-path "$output/module-cache" \
  Sources/*.swift -o "$app/Contents/MacOS/rainbow"
cp Info.plist "$app/Contents/Info.plist"
if [ "$mode" = "--preview" ]; then
  /usr/libexec/PlistBuddy \
    -c 'Set :CFBundleName Rainbow Preview' \
    -c 'Set :CFBundleDisplayName Rainbow Preview' \
    -c 'Set :CFBundleIdentifier tools.codexrainbow.preview' \
    -c 'Set :LSUIElement false' "$app/Contents/Info.plist"
elif [ "$mode" = "--launcher" ]; then
  resources="$app/Contents/Resources"
  mkdir -p "$resources"
  cp Launcher/controller.mjs "$resources/"
  /usr/libexec/PlistBuddy \
    -c 'Set :CFBundleIdentifier tools.codexrainbow.launcher' \
    -c 'Set :CFBundleShortVersionString 0.3.0' \
    -c 'Set :CFBundleVersion 5' "$app/Contents/Info.plist"
  codex=$("$app/Contents/MacOS/rainbow" codex-path)
  icon=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$codex/Contents/Info.plist" 2>/dev/null || :)
  if [[ -n "$icon" && -f "$codex/Contents/Resources/${icon%.icns}.icns" ]]; then
    cp "$codex/Contents/Resources/${icon%.icns}.icns" "$resources/Codex.icns"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string Codex.icns' "$app/Contents/Info.plist"
  fi
fi
codesign --force --sign "${SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
ln -sfn "$name.app/Contents/MacOS/rainbow" "$output/$command"
printf '%s\n' "$app"
