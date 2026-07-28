#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="$repo_dir/dist/Subwave Prism.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"
icon_source="$repo_dir/macos/SubwavePrism/AppIcon.png"
icon_work_dir="$repo_dir/dist/AppIcon.iconset"

rm -rf "$app_dir" "$repo_dir/dist/Subwave-Prism-macOS.zip" "$icon_work_dir"
mkdir -p "$macos_dir" "$resources_dir"

cp "$repo_dir/macos/SubwavePrism/Info.plist" "$contents_dir/Info.plist"

mkdir -p "$icon_work_dir"
sips -z 16 16 "$icon_source" --out "$icon_work_dir/icon_16x16.png" >/dev/null
sips -z 32 32 "$icon_source" --out "$icon_work_dir/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$icon_source" --out "$icon_work_dir/icon_32x32.png" >/dev/null
sips -z 64 64 "$icon_source" --out "$icon_work_dir/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$icon_source" --out "$icon_work_dir/icon_128x128.png" >/dev/null
sips -z 256 256 "$icon_source" --out "$icon_work_dir/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$icon_source" --out "$icon_work_dir/icon_256x256.png" >/dev/null
sips -z 512 512 "$icon_source" --out "$icon_work_dir/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$icon_source" --out "$icon_work_dir/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$icon_source" --out "$icon_work_dir/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$icon_work_dir" -o "$resources_dir/SubwavePrism.icns"

swiftc \
  -O \
  -framework Cocoa \
  -framework AVFoundation \
  -framework WebKit \
  "$repo_dir/macos/SubwavePrism/main.swift" \
  -o "$macos_dir/Subwave Prism"

codesign --force --deep --sign - "$app_dir" >/dev/null
ditto -c -k --keepParent "$app_dir" "$repo_dir/dist/Subwave-Prism-macOS.zip"

echo "$repo_dir/dist/Subwave-Prism-macOS.zip"
