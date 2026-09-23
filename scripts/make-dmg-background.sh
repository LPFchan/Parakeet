#!/bin/sh
# Renders Packaging/dmg-background.html to Packaging/DMGBackground.png
# (1200×1200, i.e. 600×600 at 2×) with headless Chrome.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
chrome=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
"$chrome" --headless --disable-gpu --hide-scrollbars --window-size=600,600 --force-device-scale-factor=2 \
    --screenshot="$root/Packaging/DMGBackground.png" "file://$root/Packaging/dmg-background.html" 2>/dev/null
echo "$root/Packaging/DMGBackground.png"
