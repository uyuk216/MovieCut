# Movie Cut Swift 版 設計メモ

Movie Cut は Swift のネイティブアプリ。かつての Electron 版からの移行は終わり、このリポジトリは Swift だけになった。
Electron 版のコードは git タグ `electron-final` に残してある(`git show electron-final:renderer.js` などで読める)。挙動の確認が必要なときはそこを見る。

## 方針
- Apple Silicon 専用、macOS 14 以降。Swift 6.x ツールチェーン、**Swift 5 言語モード**(Package.swift で `swiftLanguageModes: [.v5]`)で書く(並行性チェックで躓かないため)。
- ビルドは SwiftPM (`swift build` / `swift test`)。`.app` は `Scripts/make-app.sh` で組み立てる(Info.plist、ad-hoc 署名、dmg)。Xcode プロジェクトは作らない。
- 外部依存パッケージは使わない。ffmpeg は使わない(書き出しは AVFoundation + VideoToolbox)。
- VOICEVOX と AquesTalkPlayer は同梱せず、利用者がインストールしたものを呼ぶ(規約上の理由)。
- コード中のコメントは日本語。UI 文言は日本語。

## 構成 (リポジトリ直下が SwiftPM パッケージ)
- `Sources/MovieCutCore` (ライブラリ): Project モデル(Codable)、音声合成(VOICEVOX / AquesTalkPlayer / `say` フォールバック)、レンダラ(時刻 t のフレームを CGContext/CoreImage で描く)、書き出し(AVAssetWriter)、音声ミックス、依存チェック。UI に依存しない。
- `Sources/MovieCut` (アプリ, SwiftUI + AppKit): `DocumentGroup` の ReferenceFileDocument(`.mcpjc`。旧 `.ymproj` は読み込みだけ) で開く/保存/最近使った項目/未保存マーク/終了時確認を OS 標準に任せる。メニューは `.commands`。タイムラインは自前の View。
- `Sources/moviecut-cli` (実行ファイル): ヘッドレス検証用。`moviecut-cli export in.ymproj out.mp4`、`moviecut-cli smoke --out x.mp4 [--size WxH] [--codec h264|hevc] [--blur]`(台本→音声→テキスト→書き出しの通し確認)、`moviecut-cli frame in.ymproj --t 1.0 --out f.png`。
- `Tests/MovieCutCoreTests`: XCTest。

## ファイル形式 `.mcpjc` (旧 `.ymproj` と中身は同じ — 既存ファイルを開けること)
- 新しい形式は `.mcpjc`(UTType `jp.local.moviecut.project`、public.json に適合)。保存は必ずこれ。
- 旧 `.ymproj`(UTType `jp.local.yukkuri-editor.project`)は「インポートする型」として宣言し、新しい型に適合させてある。開けるが、書き込める型(writableContentTypes)は `.mcpjc` だけ。実機で確かめた SwiftUI の挙動: 旧ファイルを開いて「保存」(⌘S/自動保存)すると、元の `.ymproj` へ同じ JSON 形式で書き戻す(拡張子も型も変えない)。「別名で保存…」は `.mcpjc` を提案する。新規書類の保存は常に `.mcpjc`。
- ウィンドウのタブは使わない(`NSWindow.allowsAutomaticWindowTabbing = false`、書類ウィンドウは `tabbingMode = .disallowed`)。タブをドラッグしたときにビーチボールが出たため。
- キャッシュの置き場所は `~/Library/Application Support/MovieCut/voices`。旧名 `yukkuri-editor/voices` があれば、初回に移す。
JSON。主なキー: width, height, fps, bg("#rrggbb"), codec("h264"|"hevc"), voicevoxUrl, aquestalkCommand,
characters[{id,name,engine("voicevox"|"aquestalk"),speaker,voice,speed,pitch,intonation,color,imgClosed,imgOpen,x,y,scale,flip,alwaysShow}],
tracks[{id,name,hidden?,muted?,clips[...]}]。
clip 共通: id,type("image"|"video"|"audio"|"text"|"voice"|"blur"),start,duration,offset,
src,srcDuration,x,y,scale,opacity,volume,blur(px);
text: text,fontSize,color,outline,font; voice: charId,text,subtitle,fontSize,font; blur-region: w,h,strength,shape("rect"|"ellipse")。
**デコードは寛容に**: 欠けたキーは 旧 Electron 版 renderer.js の既定値で補い、知らないキーは捨てずに保持して書き戻す。座標 x,y,w,h は 0〜1(キャンバス比)。

## 機能チェックリスト (旧 Electron 版にあった機能。全部 Swift 版に入っている)
プロジェクト: 新規/開く/保存/別名/最近/未保存確認/.mcpjc 関連付け(旧 .ymproj も開ける)。
動画設定: 解像度プリセット(1080p,1440p,4K,縦1080×1920,縦720×1280,正方形,自由)、FPS 24/30/60、背景 黒(既定)/白/緑/自由、書き出し形式 H.264/HEVC、解像度変更時に文字・字幕・ぼかしの大きさを sqrt(面積比) で調整(最小8)。
キャラ: 追加/削除(最後の1人は不可)/名前/字幕縁色/エンジン(VOICEVOX|ゆっくり)/話者/速さ・高さ・抑揚/プリセット(れいむ,まりさ,中性,機械,ロボット)/立ち絵(口閉じ・口開き)/位置・大きさ・左右反転・いつも表示/試し読み上げ。
台本: 「名前: セリフ」「名前：セリフ」行 → 音声クリップ(名前が不明なら選択中キャラ)、空いている音声レイヤーへ連続配置、並べた後は全体表示。
音声: VOICEVOX(/Applications/VOICEVOX.app/Contents/Resources/vv-engine/run を 127.0.0.1:50021 で自動起動、cpu_num_threads は perflevel0 のコア数、/speakers /audio_query /synthesis、結果は Application Support にキャッシュ)、AquesTalkPlayer(`/Applications/AquesTalkPlayer.app/Contents/MacOS/AquesTalkPlayer -P プリセット -T テキスト -W out.wav`)、無ければ `say -v Kyoko` で代用。
クリップ: 画像/動画/音声/テキスト/音声(ボイス)/ぼかし範囲。クリップごとのぼかし(画像・動画・文字)、不透明度、拡大、位置、音量、トリム(offset)、テキストの文字・大きさ・色・縁色・フォント。ボイスは字幕 ON/OFF・サイズ・フォント・音量、セリフやキャラを変えると音声を作り直す。
描画順: レイヤー順(隠したレイヤーは飛ばす)→ 立ち絵(音声の音量エンベロープ 1/60 秒単位 RMS>0.03 で口開き)→ 字幕(白文字 + キャラ色の縁)。ぼかし範囲は自分より前に描いたものだけを四角/楕円でぼかす。
タイムライン: レイヤー追加、隠す/消音、ドラッグ移動(レイヤー間も)、左右端トリム、分割(S)、削除、吸着(約8pt)、ルーラーでシーク、拡大スライダー、全体表示、Cmd+ホイール/ピンチで拡大、ホイール横スクロール(縦にあふれないとき)、再生ヘッド、ルーラー目盛、キャラ色のボイスクリップ、選択の強調、タイムライン高さのドラッグ変更(保存)、スクロールバーは出さない。
再生: 再生/停止(Space)、先頭(Home)、1コマ送り/戻し(←/→)、動画クリップ同期、途中からの音声再生、消音レイヤー、終端で停止、二重再生防止。
プレビュー: 本当の縦横比の枠(灰色の下地)、左上に「W×H · Nfps」、別画面(内蔵以外で最大の画面)に全画面表示。
書き出し: H.264/HEVC (VideoToolbox) + AAC 256k、再生を待たず高速に、進捗表示、Dock の進行バーと完了時バウンス、Finder で表示、失敗時のエラー表示、2回連続OK。
メニュー: 旧 menu.js と同じ構成(ファイル/編集/再生/表示/ウィンドウ/ヘルプ、設定… Cmd+,、解像度・書き出し形式・背景色のラジオ)。Space/S/Delete/矢印は入力欄で打てるよう通常キーのまま。
設定シート: VOICEVOX の URL、ゆっくり用の実行コマンド(任意)、動画設定。
依存チェック: VOICEVOX / AquesTalkPlayer が無いときの案内(ffmpeg は不要)。
ウィンドウ: 最小 1100×700、位置を記憶。パッケージ: arm64 の dmg、ad-hoc 署名、`.mcpjc` の関連付け、About、ヘルプのライセンス/第三者の規約。
ドラッグ&ドロップで素材追加、「素材を追加」ダイアログ(画像/動画/音声)。

## 確認の取り方 (エージェント共通)
- `swift build` と `swift test` が通ること。ヘッドレスは moviecut-cli で ffprobe / 画像を使って確かめる。
- UI の見た目は、アプリ内で `NSView.cacheDisplay` を使って PNG に書き出す(`MC_SNAPSHOT_DIR` 環境変数)。画面収録の許可に頼らない。PNG は Read ツールで実際に見る。
- コミットはしない(司令塔がする)。
