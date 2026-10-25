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

## プロジェクトファイル
新しい形式は `.mcpjc` です。旧 `.ymproj` も開けます(「保存」は元のファイルへ同じ形式で書き戻し、「別名で保存…」は `.mcpjc` を提案します)。

## デバッグ用の環境変数
`MC_` で始まる環境変数(`MC_OPEN`、`MC_SNAPSHOT_DIR`、`MC_DEBUG_MENU` など)で、画面の書き出しや状態のダンプができます。一覧は `Sources/MovieCut/DebugHooks.swift` の先頭のコメントにあります。

## 設計
`DESIGN.md` を見てください。以前の Electron 版は git タグ `electron-final` に残っています。

## ライセンス
`LICENSE.md`(英語)/ `LICENSE.ja.md`(日本語)を見てください。外部エンジンの規約は `docs/第三者の規約.md` に案内があります。
