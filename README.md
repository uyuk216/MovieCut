# Movie Cut

動画編集ソフト for Mac。台本を書くと、VOICEVOX やゆっくり音声(AquesTalk)の声でしゃべるキャラクター付きの動画を作れます。Swift 製のネイティブアプリです。

## 必要なもの
- macOS 14 以降、Apple Silicon (arm64)
- 音声エンジンは同梱していません。使うものを別にインストールしてください。
  - VOICEVOX(`/Applications/VOICEVOX.app`)
  - AquesTalkPlayer(`/Applications/AquesTalkPlayer.app`)。無いときは macOS の「Kyoko」で代用します。
- ビルドするには Swift 6 のツールチェーン(Xcode または Command Line Tools)

## ビルドと実行
```
swift build                      # 開発用ビルド
swift run MovieCut               # アプリを起動
Scripts/make-app.sh              # build/Movie Cut.app を作る(ad-hoc 署名)
Scripts/make-app.sh dmg          # build/MovieCut-0.2.0-arm64.dmg も作る
```

## テスト
```
swift test
```
VOICEVOX / AquesTalkPlayer が入っていれば、実エンジンのテストも動きます(無ければ skip)。
ヘッドレスの確認には `swift run moviecut-cli deps`、`moviecut-cli smoke --out x.mp4 --blur` などが使えます。

## 書き出し(コマンドライン)
```
moviecut-cli export in.mcpjc out.mp4                       # プロジェクトの設定のまま
moviecut-cli export in.mcpjc out.mp4 --size 2048x1080 --fps 29.97 [--codec hevc]  # 任意の幅x高さ(64〜8192)・fps(1〜240、23.976 や 30000/1001 も可)
moviecut-cli smoke --out out.mp4 --size 1280x720 --fps 23.976
moviecut-cli export in.mcpjc out.mp4 --preset youtube1080  # 1920×1080 H.264
moviecut-cli export in.mcpjc out.mp4 --preset youtube4k    # 3840×2160 HEVC
moviecut-cli export in.mcpjc out.mp4 --preset short        # 1080×1920 H.264
moviecut-cli export in.mcpjc out.mp4 --preset light        # 1280×720 H.264、fps は 30 まで
moviecut-cli export in.mcpjc out.m4a --preset audio        # 音声のみ(AAC 256 kbps・48 kHz)
```
アプリでは「出力 ▸ 書き出しプリセット ▸ …」の同じプリセットを使えます。プリセットはプロジェクトの写しに当てるので、元のプロジェクトは変わりません。

## 変形とキーフレーム
画像・動画・文字は、位置・拡大・回転・左右/上下反転・切り抜き・不透明度(と、ぼかし)を時間で動かせます。プロパティ欄の各項目の右の ◇ を押すと、再生ヘッドの位置にキーフレームを足します(◆ = ここにキーあり、半塗り = 動く項目)。◀ ▶ で前後のキーへ。選択クリップの下端の菱形はタイムラインで動かせ、プレビューの枠(角で拡大・上の丸で回転・本体で移動)でも変形できます。
メニュー: クリップ ▸ キーフレーム(追加/削除 ⌥⌘K・前へ ⌥⌘,・次へ ⌥⌘.・すべて消去)/ クリップ ▸ アニメーション(ズームイン・ズームアウト・左/右/上/下からスライド・回転しながら登場・ゆっくり拡大)。ファイル形式は `DESIGN.md` を見てください(古いファイルはそのまま開け、使わなければ書き足されません)。

## プロジェクトファイル
新しい形式は `.mcpjc` です。旧 `.ymproj` も開けます(「保存」は元のファイルへ同じ形式で書き戻し、「別名で保存…」は `.mcpjc` を提案します)。

## デバッグ用の環境変数
`MC_` で始まる環境変数で、画面の書き出しや状態のダンプができます(普段は何もしません)。詳しい説明は `Sources/MovieCut/DebugHooks.swift` の先頭のコメントにあります。
`MC_DEBUG_*` / `MC_SNAPSHOT_DIR` / `MC_OPEN` のどれかがあると**静かな起動**になります: Dock にもメニューバーにも出ず(`.accessory`)、前面にせず、ウィンドウは画面の外に置き、メニューバーの状態アイコンは作らず、`MC_DEBUG_MAXSEC`(既定 20)秒で自分で終了します。`MC_DEBUG_VISIBLE=1` で通常の表示に戻せます。

| 変数 | 内容 |
| --- | --- |
| `MC_OPEN=<file>` | 起動時にそのプロジェクトを開く(以下のフックはその書類が対象) |
| `MC_SNAPSHOT_DIR=<dir>` / `MC_SNAPSHOT_DELAY=<sec>` | ウィンドウを `window.png`(シートは `sheet.png`)に書いて終了 / 撮るまでの待ち |
| `MC_DEBUG_WINDOW=WxH` / `MC_DEBUG_ZOOM=<pps>` / `MC_DEBUG_SIZE=WxH` / `MC_DEBUG_TIME=<sec>` / `MC_DEBUG_SELECT_CLIP=<i>` | ウィンドウの大きさ・タイムラインの拡大・解像度・再生位置・選択を指定 |
| `MC_DEBUG_SHEET=settings\|jump\|rename-marker` | シートを開いた状態にする |
| `MC_DEBUG_SCRIPT=<台本>` / `MC_DEBUG_EDIT=<操作列>` / `MC_DEBUG_HOLD_DRAG=<ドラッグ>` | 台本・タイムライン編集・ドラッグ途中の状態を作る |
| `MC_DEBUG_EXPORT=<out.mp4>` | 保存パネルなしで書き出し(`runExport`) |
| `MC_DEBUG_MENU=1\|export\|1,export` | メニューバーの全項目を標準出力へ(`export` は書き出し中の状態) |
| `MC_DEBUG_MENU_CLICK=<項目列>` / `MC_DEBUG_MENU_SCRIPT` / `MC_DEBUG_JUMP_VALUE` | メニュー項目を本当に押す(`;` 区切り、`クリップ/クリップを複製` の形。`@time=` `@select=` `@clips` `@export=<preset>:<out>` も使える) |
| `MC_DEBUG_MENU_KEYS=<キー列>` / `MC_DEBUG_MENU_TWICE=1` | キーイベントをメニューへ渡す / 4 秒後にもう一度ダンプ |
| `MC_DEBUG_STATUS=1` | 状態アイコンのメニューの中身を出す |
| `MC_DEBUG_PLAY=<sec>` / `MC_DEBUG_PLAY_FROM=<sec>` / `MC_DEBUG_SEEK_TEST=1` / `MC_DEBUG_DRAWTIME=<N>` | 再生・シーク・描画時間の計測 |
| `MC_DEBUG_SELECT_CHAR` / `MC_DEBUG_DELETE_CHAR` / `MC_DEBUG_VOICE_EDIT` / `MC_DEBUG_INSPECTOR_SCROLL` | キャラ・プロパティ欄の確認 |
| `MC_DEBUG_SECOND=1` | 別画面を開く(`second.png`) |
| `MC_DEBUG_DEPS=missing\|missing-voicevox\|missing-aquestalk` | 依存チェックの結果を固定 |
| `MC_DEBUG_EDITED=1` / `MC_DEBUG_SAVEAS=1` / `MC_DEBUG_ABOUT=1` / `MC_DEBUG_FRAME=…` | 未保存の点・保存パネル・About・ウィンドウ位置の確認 |
| `MC_DEBUG_QUIT=1\|engine\|dirty` / `MC_DEBUG_ENGINE_URL=<url>` | 終了の経路(エンジンの停止・未保存確認)の確認 |
| `MC_DEBUG_DOCS=1` / `MC_DEBUG_DOCS_WAIT=<sec>` | 開いている書類の一覧 |
| `MC_DEBUG_WINDOWS=1` + `MC_DEBUG_CLOSEALL=1` / `MC_DEBUG_REOPEN=1` / `MC_DEBUG_TERMINATE=1` | ウィンドウ一覧 / 全部閉じて終了 / Dock のクリック(reopen)の再現 / 普通の終了 |
| `MC_DEBUG_KEEP_STATE=1` | 検証の起動でもウィンドウの復元状態を読み書きする |
| `MC_DEBUG_HANGWATCH=1` / `MC_DEBUG_HANGWATCH_SAMPLE=<dir>` | 主スレッドの固まりを記録(300ms 超で `sample` を取る) |
| `MC_DEBUG_SWEEP=1` / `MC_DEBUG_SWEEP_EXPORT=<out.mp4>` | 重い作業を一通り行い、局面ごとの固まりを数える(書き出しも) |
| `MC_DEBUG_TREE=1` / `MC_DEBUG_TRACE=1` / `MC_NOCANVAS=1` | ビュー階層・起動の経路のトレース・タイムラインを隠す |
| `MC_DEBUG_MAXSEC=<sec>` / `MC_DEBUG_VISIBLE=1` | 静かな起動の自動終了までの秒数 / 静かな起動をやめる |

## 設計
`DESIGN.md` を見てください。以前の Electron 版は git タグ `electron-final` に残っています。

## ライセンス
`LICENSE.md`(英語)/ `LICENSE.ja.md`(日本語)を見てください。外部エンジンの規約は `docs/第三者の規約.md` に案内があります。
