#!/bin/bash
# Assembles dist/Switchboard.app from the SwiftPM executable and App/Info.plist, then signs it
# ad hoc (there is no developer identity; the DDC transport uses private IOKit entry points, so
# this app is never distributed through the App Store).
#
#     make app          # or: Scripts/make-app.sh
#     make run-app      # or: open dist/Switchboard.app
#
# The result is dist/Switchboard.app; its path is the last line printed.
set -euo pipefail

cd "$(dirname "$0")/.."
root="$(pwd)"

# Same rule as the Makefile: Xcode's toolchain, even when xcode-select points at the Command Line
# Tools (docs/DESIGN.md, "Toolchain").
xcode_developer_dir="/Applications/Xcode.app/Contents/Developer"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "$xcode_developer_dir" ]; then
    export DEVELOPER_DIR="$xcode_developer_dir"
fi

bundle_id="io.github.fgiannazzo.switchboard"
app="$root/dist/Switchboard.app"

echo "Building SwitchboardApp (release)..." >&2
swift build -c release --product SwitchboardApp
bin_dir="$(swift build -c release --product SwitchboardApp --show-bin-path)"

plutil -lint App/Info.plist >&2

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/SwitchboardApp" "$app/Contents/MacOS/SwitchboardApp"
cp App/Info.plist "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

# The icon is drawn by Scripts/make-icon.swift. It is a nicety (notifications and Finder show it):
# if it cannot be drawn the app is still complete.
iconset="$root/dist/Switchboard.iconset"
rm -rf "$iconset"
if swift Scripts/make-icon.swift "$iconset" >&2 && iconutil -c icns "$iconset" -o "$app/Contents/Resources/Switchboard.icns" >&2; then
    :
else
    echo "warning: could not generate the app icon; continuing without one" >&2
fi
rm -rf "$iconset"

codesign --force --sign - --identifier "$bundle_id" "$app" >&2
codesign --verify --strict "$app" >&2

echo "$app"
