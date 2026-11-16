#!/bin/bash
# アプリアイコン(Resources/AppIcon.icns)を再生成する。
# 絵は Scripts/icon-draw.swift が CoreGraphics で描く(外部素材なし)。
# ついでに確認用の 1024px PNG(Resources/AppIcon-1024.png)も残す。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p Resources
SET="Resources/AppIcon.iconset"
rm -rf "$SET"
mkdir -p "$SET"
gen() { swift Scripts/icon-draw.swift "$2" "$SET/$1"; }
gen icon_16x16.png 16
gen icon_16x16@2x.png 32
gen icon_32x32.png 32
gen icon_32x32@2x.png 64
gen icon_128x128.png 128
gen icon_128x128@2x.png 256
gen icon_256x256.png 256
gen icon_256x256@2x.png 512
gen icon_512x512.png 512
gen icon_512x512@2x.png 1024
cp "$SET/icon_512x512@2x.png" Resources/AppIcon-1024.png
iconutil -c icns -o Resources/AppIcon.icns "$SET"
rm -rf "$SET"
echo "OK: Resources/AppIcon.icns"
