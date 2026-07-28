#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_dir="$repo_dir/dist/Subwave Prism.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"
resources_dir="$contents_dir/Resources"

rm -rf "$app_dir" "$repo_dir/dist/Subwave-Prism-macOS.zip"
mkdir -p "$macos_dir" "$resources_dir"

cp "$repo_dir/macos/SubwavePrism/Info.plist" "$contents_dir/Info.plist"
swiftc \
  -O \
  -framework Cocoa \
  -framework WebKit \
  "$repo_dir/macos/SubwavePrism/main.swift" \
  -o "$macos_dir/Subwave Prism"

codesign --force --deep --sign - "$app_dir" >/dev/null
ditto -c -k --keepParent "$app_dir" "$repo_dir/dist/Subwave-Prism-macOS.zip"

echo "$repo_dir/dist/Subwave-Prism-macOS.zip"
