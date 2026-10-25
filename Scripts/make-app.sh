#!/bin/bash
# Movie Cut.app を組み立てる。  使い方: Scripts/make-app.sh [dmg]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=0.2.0
APP_NAME="Movie Cut"
APP="build/${APP_NAME}.app"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MovieCut" "$APP/Contents/MacOS/MovieCut"

# ヘルプメニューの「ライセンス」「第三者の規約」で開く文書(リポジトリ直下から)
REPO_ROOT="$(pwd)"
cp "$REPO_ROOT/LICENSE.ja.md" "$APP/Contents/Resources/LICENSE.ja.md"
cp "$REPO_ROOT/docs/第三者の規約.md" "$APP/Contents/Resources/第三者の規約.md"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MovieCut</string>
  <key>CFBundleIdentifier</key><string>jp.local.moviecut</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleDevelopmentRegion</key><string>ja</string>
  <key>CFBundleLocalizations</key><array><string>ja</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Movie Cut. All rights reserved.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Movie Cut プロジェクト</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>LSItemContentTypes</key><array><string>jp.local.moviecut.project</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Movie Cut 旧形式プロジェクト (.ymproj)</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>jp.local.yukkuri-editor.project</string></array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>jp.local.moviecut.project</string>
      <key>UTTypeDescription</key><string>Movie Cut プロジェクト</string>
      <key>UTTypeConformsTo</key><array><string>public.json</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>mcpjc</string></array>
      </dict>
    </dict>
  </array>
  <key>UTImportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key><string>jp.local.yukkuri-editor.project</string>
      <key>UTTypeDescription</key><string>Movie Cut 旧形式プロジェクト (.ymproj)</string>
      <key>UTTypeConformsTo</key><array><string>jp.local.moviecut.project</string></array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key><array><string>ymproj</string></array>
      </dict>
    </dict>
  </array>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP"
echo "OK: $APP"

if [ "${1:-}" = "dmg" ]; then
  DMG="build/MovieCut-${VERSION}-arm64.dmg"
  STAGE="build/dmg-stage"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  rm -rf "$STAGE"
  echo "OK: $DMG"
fi
