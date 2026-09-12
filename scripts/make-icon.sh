#!/bin/bash
# Draws Remit's app icon and packs it as Resources/AppIcon.icns, plus docs/images/icon.png.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=".build/icon"
rm -rf "$WORK"
mkdir -p "$WORK/AppIcon.iconset" Resources docs/images

swift scripts/icon.swift "$WORK/icon-1024.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$WORK/icon-1024.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$WORK/icon-1024.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$WORK/AppIcon.iconset" -o Resources/AppIcon.icns
sips -z 512 512 "$WORK/icon-1024.png" --out docs/images/icon.png >/dev/null
echo "Wrote Resources/AppIcon.icns and docs/images/icon.png"
