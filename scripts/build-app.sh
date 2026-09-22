#!/bin/sh
# Builds Parakeet.app into build/. The app runs engine/engine.py from this
# checkout's .venv, so the checkout must stay where it is.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
app="$root/build/Parakeet.app"

swift build -c release --package-path "$root/app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$root/app/.build/release/Parakeet" "$app/Contents/MacOS/Parakeet"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>plus.lost.parakeet</string>
  <key>CFBundleName</key><string>Parakeet</string>
  <key>CFBundleExecutable</key><string>Parakeet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>Parakeet listens to system audio to show live captions. Audio never leaves this Mac.</string>
  <key>ParakeetRoot</key><string>$root</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
echo "$app"
