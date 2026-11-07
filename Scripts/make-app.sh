#!/bin/bash
# Movie Cut.app を組み立てる。
# 使い方: Scripts/make-app.sh [dmg] [--edition personal|public] [--dry-run]
#   --edition personal(既定): 今までどおり build/ に作る。バンドル ID jp.local.moviecut、データは個人の環境。
#   --edition public: 配布用。build/public/ に作る。バンドル ID jp.local.moviecut.public、データは別フォルダ・別設定。
#                     作ったバンドルに個人のファイルや名前が入っていないかを調べ、見つかったら失敗する。
#                     配布版だけ Sparkle(自動アップデート)を組み込む。公開鍵は環境変数 MOVIECUT_SPARKLE_PUBLIC_KEY(Base64)で渡す。
#                     未設定ならプレースホルダが入り、アプリはアップデートの確認を始めない(秘密鍵はこのスクリプトでは扱わない)。
#   --dry-run: 何もビルドせず、やることを表示し、仮のバンドルで個人情報の検査だけ試す(build/ には触らない)。
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=0.2.1
APP_NAME="Movie Cut"
EDITION=personal
DRY_RUN=0
MAKE_DMG=0
while [ $# -gt 0 ]; do
  case "$1" in
    dmg) MAKE_DMG=1 ;;
    --edition) shift; EDITION="${1:-}" ;;
    --edition=*) EDITION="${1#--edition=}" ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "不明な引数: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$EDITION" in
  personal) BUNDLE_ID="jp.local.moviecut"; OUT_DIR="build" ;;
  public)   BUNDLE_ID="jp.local.moviecut.public"; OUT_DIR="build/public" ;;
  *) echo "--edition は personal か public: $EDITION" >&2; exit 2 ;;
esac
APP="${OUT_DIR}/${APP_NAME}.app"

# 個人のファイル・名前がバンドルに入っていないかを調べる(見つかったら 1 を返す)
scan_bundle() {
  local bundle="$1" bad=0 hits
  # 例外: 配布用アップデートの公開 URL(github.com/uyuk216/MovieCut)、署名の CodeResources(ハッシュの文字列がたまたま一致する)
  hits=""
  while IFS= read -r f; do
    case "$f" in */_CodeSignature/CodeResources) continue ;; esac
    if sed 's#github\.com/uyuk216/MovieCut/#GH/#g' "$f" | grep -q -e '/Users/' -e 'uyu'; then hits="${hits}${f}"$'\n'; fi
  done < <(grep -rIl -e '/Users/' -e 'uyu' "$bundle" 2>/dev/null || true)
  [ -n "$hits" ] && { echo "NG: 個人のパス・名前を含むテキスト:"; echo "$hits"; bad=1; }
  hits="$(find "$bundle" -type f \( -iname '*.psd' -o -iname '*.psb' -o -iname '*.mov' -o -iname '*.mp4' -o -iname '*.m4v' -o -iname '*.wav' -o -iname '*.mp3' -o -iname '*.ymproj' -o -iname '*.mcpjc' -o -iname '*.mcrecover' -o -iname '*Fixtures*' \) 2>/dev/null)"
  [ -n "$hits" ] && { echo "NG: 個人の素材・試験用ファイルらしきもの:"; echo "$hits"; bad=1; }
  hits="$(find "$bundle" \( -name PSDCache -o -name Recovery -o -name Fixtures -o -name Fonts -o -name Proxies \) 2>/dev/null)"
  [ -n "$hits" ] && { echo "NG: データフォルダがバンドルに入っている:"; echo "$hits"; bad=1; }
  # バイナリ内の文字列(Swift のパスなど)
  hits=""
  while IFS= read -r -d '' f; do
    if strings -a "$f" 2>/dev/null | grep -q -e '/Users/' -e 'uyu'; then hits="${hits}${f}"$'\n'; fi
  done < <(find "$bundle" -type f \( -perm -u+x -o -name '*.dylib' \) -print0 2>/dev/null)
  [ -n "$hits" ] && { echo "NG: 実行ファイルに個人のパス・名前の文字列:"; printf '%s' "$hits"; bad=1; }
  return $bad
}

if [ "$DRY_RUN" = 1 ]; then
  echo "[dry-run] edition=${EDITION} bundle-id=${BUNDLE_ID} 出力=${APP}$( [ "$MAKE_DMG" = 1 ] && echo " + dmg")"
  echo "[dry-run] swift build -c release --arch arm64、Info.plist に MovieCutEdition=${EDITION}、署名、"
  [ "$EDITION" = public ] && echo "[dry-run] 配布用: パス情報を消すビルドオプション、strip、個人情報の検査(見つかれば失敗)"
  TMPB="$(mktemp -d)"; trap 'rm -rf "$TMPB"' EXIT
  mkdir -p "$TMPB/${APP_NAME}.app/Contents/MacOS" "$TMPB/${APP_NAME}.app/Contents/Resources"
  printf 'dummy' > "$TMPB/${APP_NAME}.app/Contents/MacOS/MovieCut"; chmod +x "$TMPB/${APP_NAME}.app/Contents/MacOS/MovieCut"
  cp LICENSE.ja.md "$TMPB/${APP_NAME}.app/Contents/Resources/"
  if scan_bundle "$TMPB/${APP_NAME}.app"; then echo "[dry-run] 仮のバンドルの検査: OK"; else echo "[dry-run] 仮のバンドルの検査: NG"; exit 1; fi
  exit 0
fi

EXTRA_FLAGS=()
SPARKLE_KEY="${MOVIECUT_SPARKLE_PUBLIC_KEY:-}"
if [ "$EDITION" = public ]; then
  export MOVIECUT_SPARKLE=1   # Package.swift が Sparkle を取得・リンクする(個人版は付けない)
  if [ -z "$SPARKLE_KEY" ]; then
    SPARKLE_KEY="PLACEHOLDER_SET_MOVIECUT_SPARKLE_PUBLIC_KEY"
    echo "注意: MOVIECUT_SPARKLE_PUBLIC_KEY が未設定。公開鍵はプレースホルダのため、このビルドはアップデートを確認しません。" >&2
  fi
  # 配布版にビルドした場所(個人のパス)を残さない
  EXTRA_FLAGS=(-Xswiftc -file-prefix-map -Xswiftc "$(pwd)=/src" -Xswiftc -debug-prefix-map -Xswiftc "$(pwd)=/src")
fi
swift build -c release --arch arm64 ${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MovieCut" "$APP/Contents/MacOS/MovieCut"
SPARKLE_PLIST=""
if [ "$EDITION" = public ]; then
  # Sparkle.framework を同梱し、実行ファイルがそこを探せるようにする
  [ -d "$BIN/Sparkle.framework" ] || { echo "失敗: $BIN/Sparkle.framework が見つかりません" >&2; exit 1; }
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/MovieCut"
  SPARKLE_PLIST="  <key>SUFeedURL</key><string>https://github.com/uyuk216/MovieCut/releases/latest/download/appcast.xml</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUScheduledCheckInterval</key><integer>86400</integer>
  <key>SUPublicEDKey</key><string>${SPARKLE_KEY}</string>"
fi

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
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>MovieCutEdition</key><string>${EDITION}</string>
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
  <key>NSSpeechRecognitionUsageDescription</key><string>動画や音声の話し声を、このMacの中で文字にして字幕を作るために使います。音声は外部に送りません。</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
${SPARKLE_PLIST}
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
      <key>UTTypeIdentifier</key><string>jp.local.moviecut.dock-panel</string>
      <key>UTTypeDescription</key><string>Movie Cut パネル(画面内のドラッグ用)</string>
      <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    </dict>
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
if [ "$EDITION" = public ]; then
  strip -x "$APP/Contents/MacOS/MovieCut"
  if ! scan_bundle "$APP"; then echo "失敗: 配布版に個人の情報が入っています" >&2; exit 1; fi
  echo "OK: 個人情報の検査を通過"
fi
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP"
echo "OK: $APP"

if [ "$MAKE_DMG" = 1 ]; then
  DMG="${OUT_DIR}/MovieCut-${VERSION}-arm64.dmg"
  STAGE="${OUT_DIR}/dmg-stage"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
  rm -rf "$STAGE"
  echo "OK: $DMG"
fi
