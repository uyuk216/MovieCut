# 書き出し形式の追加: 連番PNG+WAV / exo / WebVideo ラウドネス引き継ぎ

第3波バッチN(W3-25 / W3-26 / F-3、YMM4 監査 #70 / #71)の実装メモ。

## W3-25 連番PNG+WAV出力(監査 #70)

- Core: `PngWavExporter`(`Sources/MovieCutCore/PngWavExporter.swift`)。
  - 映像: 既存 `Renderer` で 1 コマずつ描き、`<base>_000001.png` 形式(最低 6 桁、コマ数に応じて増加)で指定フォルダへ。fps はプロジェクト設定(`Project.frameRate`)に従う。1 コマずつ書くので長尺でもメモリは 1 コマ分。
  - 音声: 既存ミックス経路(`AudioMixer`)→ WAV 1 本(`<base>.wav`、48 kHz・ステレオ・16 ビット PCM)。音声が無いプロジェクトでも尺いっぱいの無音 WAV を書く(NLE 側の同期用)。
  - ラウドネス正規化は任意引数(既定は無効)。有効時は WAV にだけ効く(通常書き出しと同じ `LoudnessNormalizationSettings`)。
  - キャンセル・失敗時は、その回に書いたファイルをすべて消す(既存の書き出しと同じ作法)。
- 既存の連番画像書き出し(`ImageSequenceExporter`: PNG/JPEG・最低 5 桁・音声なし)とは別形式として追加した。既存形式の挙動は変えていない。
- 到達経路: アプリ(出力 ▸ 連番PNG+WAVで書き出す…)/ CLI(`export-pngwav`)。

## W3-26 exo出力(監査 #71)

- Core: `ExoExporter`(`Sources/MovieCutCore/ExoExporter.swift`)。`.exo` は AviUtl 拡張編集プラグイン用の INI 風テキスト(Shift_JIS で書き出す)。テキスト本文は UTF-16LE の 16 進文字列。
- 対応要素:
  - 画像: `画像ファイル`(file)+ `標準描画`(X / Y / 拡大率 / 透明度 / 回転)
  - 動画: `動画ファイル`(file / 再生位置 / 再生速度)+ `標準描画`
  - 音声・ボイス(素材ファイルがあるもの): `音声ファイル`(file / 再生位置 / 再生速度)+ `標準再生`(音量 / 左右)
  - テキスト: `テキスト`(本文 / サイズ / 色 / フォント名 / 太字・斜体)+ `標準描画`
  - 配置: start / end は 1 始まりのフレーム番号(プロジェクト fps で換算)、layer はトラック順(1 始まり)。位置は中心基準ピクセルへ換算(Y は上向き正として反転)。
- 非対応要素(スキップ + 理由をレポートに必ず残す。ymmp 書き戻しと同じ流儀):
  - クリップ種類: 立ち絵 / 図形 / 複合 / ぼかし / 調整レイヤー / ビジュアライザ / 未知の種類、素材ファイルの無いボイス、長さ 0 以下、無効化クリップ
  - 一部機能のみ落ちるもの: キーフレーム、映像・音声エフェクト、トランジション、文字装飾(太字・斜体以外)、文字アニメーション、ルビ、逆再生、速度ランプ、クロップ、反転、マスク、ブレンドモード、クリップ消音、音声フェード、マーカー、立ち絵素材
- **実 AviUtl での読み込み検証は未実施**(検証環境が無いため)。保証範囲は形式の構造と自前パーサ(`ExoParser`)での往復まで。座標の Y 方向の符号や、エフェクト項目名・単位の細部は AviUtl 実機での確認が取れていない近似を含む。この旨は書き出しレポートの注記にも常時入る。
- 到達経路: アプリ(出力 ▸ exo形式(.exo)で書き出す…、レポートをアラート表示)/ CLI(`export-exo`、レポートを stderr 表示)。

## F-3 WebVideo 書き出しへのラウドネス設定引き継ぎ

- 所見: `FFmpegVideoExporter` は中間 MP4 を作る際に `Exporter` へラウドネス設定を渡しておらず、WebM / AV1 / WebP の書き出しでは通常書き出しのラウドネス正規化が効かなかった。
- 修正: `FFmpegVideoExporter.export` に `loudness: LoudnessNormalizationSettings = .disabled` を追加し、中間 `Exporter` へそのまま渡す。既定値(無効)では従来挙動と一致する。
- 配線: アプリの WebVideo 保存パネルに通常書き出しと同じ「ラウドネス正規化」チェック + 目標値(-11 / -14 / -16 / -18 / -20 LUFS、上限は Core 既定 -1 dBTP)を追加。CLI `export-web` に `--loudness [--loudness-target <LUFS>]` を追加(`export` と同じ指定方法)。
- アニメーション WebP は音声を持たないため、正規化は実質無効(中間ファイルの音声にだけ効き、最終形式には残らない)。

## 検証

- Core テスト `PngWavExoExportTests`(8 件): 連番の計画・命名・桁数、実書き出しの枚数・画素サイズ・背景色、無音 WAV の長さ、音声つき WAV の長さと正規化の有無による出力差(実測 LUFS)、キャンセル時の後片付け、exo のフレーム換算・テキスト 16 進往復・構造パース往復(Shift_JIS バイト列含む)・非対応要素のレポート、WebVideo のラウドネス引き継ぎ(ffmpeg がある環境で実書き出し→音声を戻して実測)。


## 実機検証 R4-1(2026-11-19、検証ブランチ feat/verification-r4、起点 feat/muse-access 05f762b)

検証用クローンで CLI(`moviecut-cli`)と Core API の両経路から書き出し→再取り込みの往復を確認した。コードは変更していない。

### ymmp 往復

- フィクスチャ `ymmp-basic.ymmp`(1920×1080 / 60fps / キャラ 2)を取り込み → 書き出し → 再取り込み:
  - 取り込み: 変換 7 件、スキップ 3 件(TachieItem・ShapeItem・Serif の無い VoiceItem)、落ちたエフェクト 1 件。いずれもレポートに理由つきで残る。
  - 書き出し: 2,853 バイト、変換 7 件、unsupported 0、dropped 0。構造は Timelines 1 件・Items 7 件で、全アイテムに Frame / Length / Layer / $type があり、$type は `YukkuriMovieMaker.Project.Items.*`(アセンブリ名 YukkuriMovieMaker)形式。VideoInfo・Characters(2 件)も保持。
  - 再取り込み: 7 クリップで、種類・開始・長さ・本文・字幕文・素材パスの集合が往復前と**完全一致**。解像度・fps・キャラ数も一致。
- MovieCut ネイティブの `rich.ymproj`(1920×1080 / 30fps / 8 クリップ)を CLI `export-ymmp` で書き出し → 再取り込み:
  - 変換 5 件、unsupported 3 件(ぼかし×2、hologram)はレポートに理由つき。再取り込みは 5 件で、差分は「レポート済みの unsupported が落ちる」以外では、ボイスクリップの素材パス(`/a/v.wav`)が戻らない 1 点のみ。これは VoiceItem にファイル項目が無い YMM4 側の仕様(音声は TTS で再生成される)によるもので、書き出し注記にもあるとおり音量も再取り込みでは引き継がれない。
  - CLI と Core API の書き出し結果は同一サイズ(ymmp 2,427 バイト)で、二重実装の乖離は無かった。
- 単体テスト: `YmmpExportTests` 9 件・`YmmpImportTests` 10 件、全て成功。
- **実 YMM4 での読み込みは未検証**(従来どおり)。理由: 到達可能な Windows 環境が winlinux のみで、Smart App Control 強制モードのため YMM4 を起動できない(判明済み。SAC の変更はしていない)。未検証範囲: YMM4 実機での表示・再生、キャラ音声設定の細部の解釈。

### exo 往復

- `rich.ymproj` を CLI `export-exo` で書き出し(変換 5 件、unsupported 3 件=ぼかし×2・hologram、レポートに理由つき):
  - バイト列は Shift_JIS で復号でき、CRLF 改行。[exedit] ヘッダは width=1920 / height=1080 / rate=30 / scale=1 / length=60 / audio_rate=48000 / audio_ch=2。
  - 自前 `ExoParser` での再パース: オブジェクト 5 件全てで start / end(1 始まりフレーム換算)・layer が期待値と一致(5/5)。テキスト本文の UTF-16LE 16 進は「こんにちは」に正しく復号できた。種類ごとのエフェクト構成(画像ファイル+標準描画、動画ファイル+標準描画、音声ファイル+標準再生、テキスト+標準描画)も仕様どおり。
  - CLI と Core API の出力は同一サイズ(1,044 バイト)。
- 単体テスト: `PngWavExoExportTests` 8 件、全て成功。
- **実 AviUtl での読み込みは未検証**(従来どおり)。理由: YMM4 と同じく、到達可能な Windows 環境(winlinux)では Smart App Control 強制モードのため AviUtl を起動できず、他に到達可能な Windows 環境が無い。座標の Y 方向の符号やエフェクト項目の細部は引き続き近似を含む。
