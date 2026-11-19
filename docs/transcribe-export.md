# 文字起こしの書き出し(txt / srt)と Whisper 精度の改善

音声を文字にして、ファイルとして保存する機能の説明です。字幕のタイムライン投入(「音声から字幕を作る」)とは別に、保存だけもできます。

## 1. 使い方

### アプリ

音のあるクリップ(動画・音声。速度を変えたものと逆再生は対象外)を選び、メニューから選びます。

- **出力 ▸ 文字起こしを書き出す…** … Apple の音声認識(オンデバイス)で認識します。
- **出力 ▸ 文字起こしを書き出す（Whisper）…** … whisper.cpp で認識します(精度を上げたいとき。[Whisper文字起こし.md](Whisper文字起こし.md) の準備が必要)。

操作の流れ:

1. 保存先を決める(保存パネル)。拡張子で形式を決めます。`.txt` は本文だけ、`.srt` は時刻つきの字幕形式です。知らない拡張子は `.txt` として書きます。既定の名前は「書類名-文字起こし.txt」です。
2. 「タイムラインにも字幕を載せますか?」と聞かれます。
   - **載せて書き出す**: ファイルを書いたあと、字幕レイヤーに文字クリップを足します。Undo は 1 回で戻ります。
   - **ファイルだけ書き出す**: ファイルだけ書きます。タイムラインは変えません。
   - **キャンセル**: 何もしません。
3. 認識が始まります。進みを表示し、オーバーレイからキャンセルできます。

認識結果が空のときは、ファイルを作らずに状態欄で知らせます。認識中に編集で内容が変わったときは、字幕の追加だけ止めます(ファイルは書いたままにします)。

### CLI

```sh
moviecut-cli transcribe <media|project> --out x.txt [--clip 0] [--locale ja-JP] [--engine apple|whisper]
moviecut-cli transcribe <media|project> --out x.srt
```

- `--out` は `.srt` / `.vtt` / `.txt` から選びます。`.txt` は本文だけを 1 行ずつ書きます。
- `--engine whisper` で Whisper を使います。`--locale` を付けないときの Whisper は言語の自動判定です(`auto`)。Apple の既定は従来どおり `ja-JP` です。

## 2. 既存の部品を再利用した箇所

独自の形式は作らず、次の既存部品を使っています。

| 役割 | 既存の部品 |
| --- | --- |
| 音声の書き出し(48kHz モノラル WAV) | `TranscriptionAudio.writeWAV`(`Transcription.swift`) |
| 認識 | `Transcriber` protocol、`SpeechFrameworkTranscriber`、`WhisperTranscriber` |
| 認識結果の型 | `TranscriptSegment`、字幕の型 `SubtitleCue` |
| 認識結果 → タイムラインの時刻 | `TranscriptSubtitles.cues(from:clip:)` |
| SRT の整形 | `SubtitleFile.format(_:as:)`(`.srt` 部分は変えていません) |
| 字幕レイヤーへの配置 | `SubtitleGeneration.appendCues` / `SubtitleImport.appendLanes` |
| 音声認識の本体(WAV → 認識) | `SubtitleTranscription.run` を分割した `SubtitleTranscription.segments`(プロジェクトを変えない版) |
| 本文の整え | `SubtitleFile.cleanBody` |
| ノイズ除去 | `SpectralDenoise.process`(Core 内。前処理から呼ぶ) |
| テストの偽エンジン | `WhisperTranscriptionTests` の偽スクリプト方式、`TranscribeAppTests` の `StubTranscriber` 方式 |

## 3. 新規に実装した箇所

### Core(`Sources/MovieCutCore/`)

- **`TranscriptExport.swift`(新規)**
  - `TranscriptExportFormat`: `.txt` / `.srt` と拡張子の判定(大文字可、未知は nil)。`.srt` は既存の `SubtitleFormat` と対応します。
  - `TranscriptText`: セグメント・字幕から本文を作ります(1 件 1 行、空は捨てる、末尾に改行 1 つ)。言語は変えません。
  - `CharacterErrorRate`: 文字誤り率(評価用。空白を除き小文字にして、文字単位の編集距離 ÷ 正解の文字数)。
- **`Transcription.swift`**: `SubtitleTranscription.segments(clip:transcriber:...)` を追加し、`run` はこれを使うよう寄せました。外部の結果・キャンセル・一時ファイルの扱いは変えていません。
- **`WhisperTranscriber.swift`**
  - `WhisperOptions`(ビーム幅 5・候補 5・温度 0・記号抑止 `-sns`)と `WhisperVADOptions`(Silero VAD)を追加。引数は先頭 8 要素の並びを保ち、後ろに `-bs -bo -tp -sns` と VAD の `--vad -vm -vt -vspd -vsd -vp` を足します。
  - 言語の既定を `auto` に変更。
  - `WhisperLocator.resolveVADModel(supportRoot:)`: `Whisper/` フォルダから VAD モデルを探します。見つかれば自動で有効にします。
  - `WhisperPreprocessing`: ノイズ除去(強さ 0.5)とピーク正規化(-1 dBFS、増幅は最大 +24 dB)。サンプルレート・チャンネル数・フレーム数は変えません。30 分を超える素材はノイズ除去を省きます。
  - `WhisperModelCatalog`: 既知モデルの一覧(純粋データ)。推奨は large-v3。ダウンロードはしません。
- **`L10nTable.swift`**: 新規文言の英訳を追加。

### アプリ(`Sources/MovieCut/`)

- **`ProjectModel+TranscriptExport.swift`(新規)**: `exportTranscriptOfSelectedClip(transcriber:to:format:addToTimeline:)`(テスト可能な本体)、`chooseAndExportTranscript()`(Apple)、`chooseAndExportTranscriptWithWhisper()`(パネルと確認)。Undo 名は「文字起こしを書き出す」。
- **`AppMenu.swift` / `AppCommands.swift` / `MenuDisabledReason.swift`**: メニュー項目 2 件。無効条件は `canEdit && canTranscribe`、無効理由は「音のあるクリップを選んでください」。
- **`ContentView.swift`**: 設定の Whisper 欄に、large-v3 の案内と「large-v3 をダウンロード…」ボタン(`NSWorkspace` でカタログの URL を開く)、VAD の状態表示を追加。

### CLI(`Sources/moviecut-cli/main.swift`)

- `transcribe --out` が `.txt` を受け付けるように。
- Whisper の言語: `--locale` 未指定は `auto`。`ja-JP` は `ja`、`auto` はそのまま。

## 4. 精度の設定

| 項目 | 既定 | 理由 |
| --- | --- | --- |
| 言語 | 自動判定(`-l auto`) | 日英混在でも、各言語のまま出るように |
| モデル | 推奨 large-v3(設定画面で案内) | 日本語の精度を最優先に |
| ビーム幅・候補数 | 5・5 | 精度優先。時間は増える |
| 温度 | 0 | 揺らぎを抑える |
| 記号・音楽記号の抑止 | 入れる(`-sns`) | 不要な記号の混入を減らす |
| VAD | モデルがあれば自動で有効 | 無音区間の誤認識を減らすことを期待 |
| 前処理 | ノイズ除去 0.5 + ピーク正規化 -1 dBFS | 静かな録音・雑音の多い録音への対策 |

前処理は時刻を変えません。前処理そのものが失敗したときは、前処理なしの音声で続けます(認識は止めません)。

## 5. 日英混在の方針

- 言語は自動判定にして、認識結果は各言語のまま保持する方針です。日英混在の音声で、英単語がカタカナに直らないことは、JSON のパースとテストで確かめています。実機の音声での認識結果はまだ確認していません。
- 本文の整えでも言語は変えません。`TranscriptText` のテストで、日英混在の文が変わらないことを確かめています。
- 日英が混ざるときの判定の精度は、モデルに依存します。large-v3 を推奨しています。

## 6. テスト

- Core: `TranscriptExportTests`(整形・拡張子・文字誤り率)、`WhisperAccuracyTests`(引数・既定の言語・VAD の探索と自動有効化・日英混在の保持・前処理・カタログ)。
- Core(既存の変更 1 件): `WhisperTranscriptionTests.testTranscribeWithFakeExecutable` の `-f` の期待を更新しました。既定では前処理済みの一時ファイル(`…-pre.wav`)が渡されるため、「入力そのものが渡される」という期待を「前処理後のファイルが渡される」に変えています。他の既存テストは変えていません。
- App: `TranscriptExportAppTests`(txt / srt の中身、字幕レイヤーへの追加と Undo 1 回、空の結果でファイルを作らないこと、認識の失敗、メニュー項目)。

## 7. 未検証事項

- アプリの画面(保存パネル・確認アラート・設定欄の表示)は、ビルドと単体テストで確かめただけです。実際の操作での確認は未実施です。
- 30 分を超える長い素材での前処理(ノイズ除去を省く経路)は、テストしていません。
- VAD モデルを実際に置いたときの認識結果(幻覚の減少)は、実機で比べていません。
- large-v3 の実機での速度とメモリは、未計測です。
- 前処理の効果(精度が上がるかどうか)は、`CharacterErrorRate` を使った比較をまだ行っていません。
