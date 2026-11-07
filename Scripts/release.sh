#!/bin/bash
# 配布版(public)を 1 コマンドでリリースする。
# 使い方: Scripts/release.sh --version X.Y.Z [--dry-run | --publish] [--skip-tests]
#   --version X.Y.Z  新しい版。Scripts/make-app.sh の VERSION を書き換える(作業ツリーがきれいなときだけ)。
#   --dry-run        既定。ローカルだけで作る。コミット・タグ・push・gh release はしない。
#                    終了時に VERSION の書き換えを元に戻す。GitHub へのアクセスも本物の鍵も要らない。
#                    キーチェーンには触れないので、署名は行わない(appcast は署名なしの下書きになる)。
#   --publish        署名(sign_update がキーチェーンの秘密鍵を使う)、版上げコミット、タグ、push、gh release まで行う。
#   --skip-tests     swift test を省く。
# 環境変数: MOVIECUT_SPARKLE_PUBLIC_KEY(必須・公開鍵 Base64)、SPARKLE_BIN(sign_update などのあるフォルダ)。
# 秘密鍵はこのスクリプトでは読まない・表示しない・書き出さない。
set -euo pipefail
cd "$(dirname "$0")/.."

REPO_SLUG="uyuk216/MovieCut"
MAKE_APP="Scripts/make-app.sh"
OUT_DIR="build/public"
APP_NAME="Movie Cut"

VERSION_NEW=""
MODE=dry-run
SKIP_TESTS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) shift; VERSION_NEW="${1:-}" ;;
    --version=*) VERSION_NEW="${1#--version=}" ;;
    --dry-run) MODE=dry-run ;;
    --publish) MODE=publish ;;
    --skip-tests) SKIP_TESTS=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "不明な引数: $1" >&2; exit 2 ;;
  esac
  shift
done

log() { echo "[release] $*"; }
warn() { echo "[release] 警告: $*" >&2; }
die() { echo "[release] 失敗: $*" >&2; exit 1; }

[[ "$VERSION_NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version X.Y.Z が必要(例: --version 0.2.1)"
TAG="v${VERSION_NEW}"
log "mode=${MODE} version=${VERSION_NEW} tag=${TAG}"

# ---- preflight ----
[ -z "$(git status --porcelain)" ] || die "作業ツリーがきれいではない。コミットか退避してから実行する"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null && die "タグ ${TAG} は既にある。新しい版にする"

if git remote get-url origin >/dev/null 2>&1; then
  log "origin: $(git remote get-url origin)"
else
  [ "$MODE" = publish ] && die "origin リモートがない"
  warn "origin リモートがない(dry-run なので続行)"
fi

if [ "$MODE" = publish ]; then
  command -v gh >/dev/null || die "gh がない(brew install gh)"
  gh auth status >/dev/null 2>&1 || die "gh が未ログイン。gh auth login を実行する"
else
  log "dry-run: gh auth は確認しない(GitHub へ接続しない)"
fi

[ -n "${MOVIECUT_SPARKLE_PUBLIC_KEY:-}" ] || die "MOVIECUT_SPARKLE_PUBLIC_KEY が未設定(generate_keys で出る公開鍵)"

find_tool() {
  local name="$1" p
  if [ -n "${SPARKLE_BIN:-}" ] && [ -x "${SPARKLE_BIN}/${name}" ]; then echo "${SPARKLE_BIN}/${name}"; return 0; fi
  p="$(find .build/artifacts -type f -name "$name" -not -path '*old_dsa_scripts*' 2>/dev/null | head -n 1 || true)"
  [ -n "$p" ] && { echo "$p"; return 0; }
  return 1
}
SIGN_UPDATE="$(find_tool sign_update || true)"
GENERATE_APPCAST="$(find_tool generate_appcast || true)"
if [ -z "$SIGN_UPDATE" ] || [ -z "$GENERATE_APPCAST" ]; then
  cat >&2 <<EOF
[release] Sparkle のツールが見つからない。次のどちらかで用意する:
  - 配布版を一度ビルドする: MOVIECUT_SPARKLE=1 swift build -c release  (.build/artifacts/ に入る)
  - https://github.com/sparkle-project/Sparkle/releases の Sparkle-2.x.tar.xz を展開し、
    SPARKLE_BIN=<展開先>/bin を環境変数に渡す
EOF
  [ "$MODE" = publish ] && die "sign_update / generate_appcast が必要"
  warn "dry-run なので続行(署名はどのみち行わない)"
fi
log "sign_update=${SIGN_UPDATE:-なし}"

# ---- 版上げ(dry-run では終了時に元へ戻す) ----
VERSION_COMMITTED=0
restore_version() {
  if [ "$VERSION_COMMITTED" = 0 ] && ! git diff --quiet -- "$MAKE_APP"; then
    git checkout -- "$MAKE_APP"
    log "VERSION の書き換えを元に戻した"
  fi
}
trap restore_version EXIT

CUR="$(sed -n 's/^VERSION=\(.*\)$/\1/p' "$MAKE_APP" | head -n 1)"
log "VERSION: ${CUR} -> ${VERSION_NEW}"
sed -i '' "s/^VERSION=.*/VERSION=${VERSION_NEW}/" "$MAKE_APP"
[ "$(sed -n 's/^VERSION=\(.*\)$/\1/p' "$MAKE_APP")" = "$VERSION_NEW" ] || die "VERSION の書き換えに失敗"

# ---- テスト ----
if [ "$SKIP_TESTS" = 1 ]; then warn "--skip-tests: swift test を省略"; else log "swift test"; swift test; fi

# ---- ビルド ----
log "配布版をビルド"
"$MAKE_APP" dmg --edition public
APP="${OUT_DIR}/${APP_NAME}.app"
DMG="${OUT_DIR}/MovieCut-${VERSION_NEW}-arm64.dmg"
ZIP="${OUT_DIR}/MovieCut-${VERSION_NEW}.zip"
[ -d "$APP" ] && [ -f "$DMG" ] || die "ビルド成果物が見つからない"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
LENGTH="$(stat -f%z "$ZIP")"
log "zip: ${ZIP} (${LENGTH} bytes)"

# ---- 署名 ----
ED_SIG=""
if [ "$MODE" = publish ]; then
  # sign_update は自分でキーチェーンの秘密鍵を使う。鍵そのものは出力されない。
  SIGN_OUT="$("$SIGN_UPDATE" "$ZIP")"
  ED_SIG="$(printf '%s' "$SIGN_OUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
  [ -n "$ED_SIG" ] || die "sign_update の出力から署名を取れない"
  log "署名済み(edSignature 長 ${#ED_SIG})"
else
  warn "dry-run: キーチェーンに触れないため署名しない。appcast は署名なしの下書き"
fi

# ---- リリースノート(前のタグ以降の git log) ----
PREV_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [ -n "$PREV_TAG" ]; then RANGE="${PREV_TAG}..HEAD"; else RANGE="HEAD"; warn "前のタグがない。直近 30 件のコミットを載せる"; fi
NOTES_LINES="$(git log "$RANGE" --max-count=30 --pretty='%s' | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/^/<li>/' -e 's/$/<\/li>/')"
[ -n "$NOTES_LINES" ] || NOTES_LINES="<li>軽微な修正</li>"

# ---- appcast.xml ----
APPCAST="${OUT_DIR}/appcast.xml"
URL="https://github.com/${REPO_SLUG}/releases/download/${TAG}/MovieCut-${VERSION_NEW}.zip"
PUBDATE="$(LC_ALL=C date '+%a, %d %b %Y %H:%M:%S %z')"
SIG_ATTR=""
[ -n "$ED_SIG" ] && SIG_ATTR=" sparkle:edSignature=\"${ED_SIG}\""
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Movie Cut</title>
    <item>
      <title>Version ${VERSION_NEW}</title>
      <pubDate>${PUBDATE}</pubDate>
      <sparkle:version>${VERSION_NEW}</sparkle:version>
      <sparkle:shortVersionString>${VERSION_NEW}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<ul>${NOTES_LINES}</ul>]]></description>
      <enclosure url="${URL}"${SIG_ATTR} length="${LENGTH}" type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
xmllint --noout "$APPCAST" || die "appcast.xml が XML として不正"

# ---- appcast の検査 ----
grep -q "enclosure url=\"${URL}\"" "$APPCAST" || die "appcast の enclosure URL が想定と違う"
grep -q "length=\"${LENGTH}\"" "$APPCAST" || die "appcast の length が zip と合わない"
grep -q "<sparkle:version>${VERSION_NEW}</sparkle:version>" "$APPCAST" || die "appcast の版が違う"
if [ "$MODE" = publish ]; then
  grep -q 'sparkle:edSignature="[^"]\{20,\}"' "$APPCAST" || die "appcast に edSignature がない"
  log "appcast 検査 OK(URL・署名・length)"
else
  grep -q 'sparkle:edSignature' "$APPCAST" && die "dry-run なのに署名欄がある"
  log "appcast 検査 OK(URL・length・版)。edSignature は dry-run のため未設定(publish で必須検査)"
fi

# ---- dry-run はここまで ----
if [ "$MODE" = dry-run ]; then
  log "dry-run 完了。成果物: ${ZIP} ${DMG} ${APPCAST}"
  log "コミット・タグ・push・gh release は行っていない"
  exit 0
fi

# ---- publish ----
git remote get-url origin >/dev/null 2>&1 || die "origin リモートがない"
git add "$MAKE_APP"
git commit -m "リリース ${TAG}: 版を ${VERSION_NEW} に更新

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
VERSION_COMMITTED=1
git tag "$TAG"
git push origin "$BRANCH"
git push origin "$TAG"
gh release create "$TAG" "$ZIP" "$DMG" "$APPCAST" --title "Movie Cut ${TAG}" --generate-notes
log "公開した: ${TAG}"
