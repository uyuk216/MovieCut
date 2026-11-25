#!/bin/bash
# SUFeedURL(Sparkle の appcast URL)を決める関数。make-app.sh から source して使う。
# 優先順: 環境変数 MOVIECUT_SUFEED_URL > Scripts/local.env(未追跡)の MOVIECUT_SUFEED_URL > 既定値。
# 実URLは git に入れない。ローカルだけに置く(Scripts/local.env.example を参照)。
MOVIECUT_DEFAULT_SUFEED_URL="https://github.com/uyuk216/MovieCut/releases/latest/download/appcast.xml"

# 使い方: resolve_feed_url [ローカル設定ファイルのパス]  → XMLエスケープ済みURLを標準出力へ。不正なら 1 を返す。
resolve_feed_url() {
  local file="${1:-$(dirname "${BASH_SOURCE[0]}")/local.env}" url="${MOVIECUT_SUFEED_URL:-}"
  if [ -z "$url" ] && [ -f "$file" ]; then
    # source はせず、該当行だけを読む(設定ファイル経由のコード実行を避ける)
    url="$(sed -n 's/^MOVIECUT_SUFEED_URL=//p' "$file" | tail -n 1)"
    url="${url%\"}"; url="${url#\"}"
  fi
  [ -n "$url" ] || url="$MOVIECUT_DEFAULT_SUFEED_URL"
  case "$url" in
    http://*|https://*) ;;
    *) echo "失敗: SUFeedURL は http(s):// で始まる必要があります" >&2; return 1 ;;
  esac
  if [[ "$url" =~ [[:space:][:cntrl:]] ]]; then
    echo "失敗: SUFeedURL に空白・改行・制御文字は使えません" >&2; return 1
  fi
  url="${url//&/&amp;}"; url="${url//</&lt;}"; url="${url//>/&gt;}"; url="${url//\"/&quot;}"
  printf '%s\n' "$url"
}
