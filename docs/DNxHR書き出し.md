# DNxHR 書き出し(ffmpeg バックエンド)

Premiere 棚卸し表(`premiere-inventory.md` 書き出し節 X03「DNxHR / DNxHD 書き出し」)への対応。
既存の任意 ffmpeg バックエンド(`FFmpegExport.swift`、WebM / AV1 / アニメーション WebP で実績)に
DNxHR を追加形式として足した。既存形式の挙動・出力は変えていない(追加のみ)。

## 使い方

- アプリ: 出力 ▸「WebM / AV1 / WebP / DNxHR で書き出す…」の保存パネルで形式から
  `DNxHR LB / SQ / HQ / HQX / 444` を選ぶ。選ぶとプロファイルの説明(用途・ビット深度・色差)が出る。
  ラウドネス正規化の指定も従来の Web 形式と同じく中間ファイルへ引き継がれる。
- CLI: `moviecut-cli export-web <in.ymproj> <out.mov> --format dnxhr-lb|dnxhr-sq|dnxhr-hq|dnxhr-hqx|dnxhr-444`
  (`--crf` は DNxHR では無視される。下記「引数」参照)
- 出力は MOV コンテナ、音声は無圧縮 PCM(8ビット系プロファイルは 16 ビット `pcm_s16le`、
  10ビット系は 24 ビット `pcm_s24le`)。
- ffmpeg が無い環境では従来どおり「ffmpeg が見つかりません」の理由つきで書けない
  (MP4 / MOV(ProRes) / GIF / APNG 等の既存書き出しには影響しない)。
  ffmpeg があっても `dnxhd` エンコーダが無い場合はその旨の理由を出す。

## 対応プロファイル

| プロファイル | ffmpeg `-profile:v` | ビット深度 | 色差 | `-pix_fmt` | 用途の目安 |
|---|---|---|---|---|---|
| DNxHR LB | `dnxhr_lb` | 8 | 4:2:2 | `yuv422p` | 低帯域。オフライン編集・プロキシ向け |
| DNxHR SQ | `dnxhr_sq` | 8 | 4:2:2 | `yuv422p` | 標準品質 |
| DNxHR HQ | `dnxhr_hq` | 8 | 4:2:2 | `yuv422p` | 高画質。通常の編集・納品向け |
| DNxHR HQX | `dnxhr_hqx` | 10 | 4:2:2 | `yuv422p10le` | 高画質・10ビット。グレーディング向け |
| DNxHR 444 | `dnxhr_444` | 10 | 4:4:4 | `yuv444p10le` | 仕上げ用。VFX向け |

ffmpeg への引数は `[-c:v, dnxhd, -profile:v, <プロファイル>, -pix_fmt, <形式>, -c:a, <PCM>]`(+ `-f mov`)。
ビットレート指定(`-b:v`)と `-crf` は付けない: DNxHR のビットレートはプロファイルと
フレームサイズ・fps から ffmpeg が自動で決める(ASWF ガイドに「`-b:v` は効かない」と明記)。

## 対応範囲(解像度・fps)

- 解像度: 幅 256 以上・高さ 120 以上(ffmpeg の DNxHR エンコーダの下限)。
  上限は MovieCut の書き出し上限に合わせて 8192×4320 相当の面積まで。
  範囲外は書き出し前に日本語の理由で止める(`DNxHRProfile.validationError`)。
  奇数サイズは中間書き出し(既存 `Exporter`)が偶数へ切り下げるため、検証も偶数化後のサイズで行う。
  ffmpeg 自体は奇数も通るが、他アプリの受け入れが未確認のため偶数サイズを推奨する。
- フレームレート: DNxHR には DNxHD のような固定の組み合わせ表が無く可変。
  MovieCut の入力範囲 1〜240fps をそのまま受ける(23.976 / 29.97 / 59.94 等の NTSC レート含む)。
  インターレースは対象外(プログレッシブのみ)。

## 中間ファイル(ProRes)

他の ffmpeg 形式は中間に H.264 の MP4(40Mbps)を使うが、DNxHR では ProRes に変えている
(`DNxExport.intermediateCodec`): 444 は ProRes 4444、それ以外は ProRes 422。
H.264 中間だと 8ビット 4:2:0 のため、HQX(10ビット)・444(4:4:4)の情報が ffmpeg 変換前に落ちてしまう。
ProRes 中間では音声も 24 ビット PCM になる。

ただし MovieCut の描画パイプライン自体は sRGB・8ビット基準のため、HQX / 444 の
「10ビット」はコンテナとエンコード形式の話であり、描画段階で 10ビット精度の色が
生成されるわけではない。この点は利用者向けにも過大に謳わない。

## 引数・プロファイル対応の出典(推測で決めていない)

- 対象 Mac の ffmpeg 9.0.2(Homebrew)で `ffmpeg -h encoder=dnxhd` を実測(2026-11-19):
  エンコーダ名 `dnxhd`、対応ピクセル形式 `yuv422p / yuv422p10le / yuv444p10le / gbrp10le`、
  プロファイル値 `dnxhd(0) / dnxhr_lb(1) / dnxhr_sq(2) / dnxhr_hq(3) / dnxhr_hqx(4) / dnxhr_444(5)`。
  `ffmpeg -encoders` で `dnxhd / pcm_s16le / pcm_s24le` の存在も確認。
- Academy Software Foundation, Encoding Guidelines「DNxHD Encoding」(EncodeDNXHD.md):
  プロファイル表(ビット深度・色差・圧縮比)、「DNxHR は 256×120 以上の任意サイズを受け付け、
  ビットレートはサイズに比例して自動決定」、`-b:v` が効かないこと、奇数サイズの扱い、
  DNxHD(従来型)は 4 サイズ×固定ビットレートのみ、の各記述。
  https://github.com/AcademySoftwareFoundation/EncodingGuidelines
- ffmpeg 公式ドキュメント(ffmpeg.org の Codecs Documentation / 一般オプション):
  `-profile:v` / `-pix_fmt` / `-c:v` / `-c:a` の一般仕様。

## 従来型 DNxHD を見送った理由

DNxHD(プロファイル指定なしの `dnxhd`)は 1920×1080 / 1440×1080 / 1280×720 / 960×720 の
4 サイズと固定ビットレート・fps の組み合わせが一致したときだけ書ける(ASWF ガイド)。
プロジェクトの解像度・fps が表に無い場合はエラーになるため、利用者向けの形式としては
HD サイズも包含する DNxHR のほうが適している。Avid の厳密な DNxHD 納品が必要な場合は
DNxHR HQ(1920×1080 等)で代替できる場面が多い。

## 実装に伴う既存コードの修正(1件)

`FFmpegLocator.parseEncoders` のフラグ文字の許可集合に `F` を追加した。
ffmpeg のエンコーダ一覧で `dnxhd` 行はフラグが `VFS..D`(F=フレーム単位の並列化)であり、
従来の許可集合(`VASDIL.|=-`)では行ごと取りこぼして、DNxHR が常時「エンコーダが無い」に
なっていた。F を含む行が正しく読めるようになるだけで、従来形式の可否判定が
「書ける→書けない」に変わることはない(読めるエンコーダが増える方向のみ)。
回帰テストは `DNxExportTests.testParseEncodersIncludesDNxHD` と既存 `FFmpegExportTests`。

## 検証(2026-11-19、対象 Mac・ffmpeg 9.0.2)

- 単体テスト `DNxExportTests` 12件(プロファイル定義、引数生成の完全一致、可否判定、
  サイズ・fps 検証、中間コーデック選択、エンコーダ一覧パース、実書き出しスモーク)。
- 実 ffmpeg 書き出しを確認済み:
  - 単体テスト内スモーク(320×180・0.5秒): HQ / LB / HQX を書き出し、ffprobe で
    `codec_name=dnxhd`・プロファイル・`pix_fmt`・寸法を照合。
  - CLI `export-web`(1920×1080・生成クリップのプロジェクト): LB / SQ / HQ / 444 を書き出し、
    ffprobe で `profile=DNXHR LB / SQ / HQ / 444`、`pix_fmt=yuv422p / yuv444p10le` を照合。
- Core テスト全件と App テスト全件を実行し、起点(失敗 0)から失敗は増えていない(件数は報告参照)。

## 未検証・留保

- Avid Media Composer / DaVinci Resolve / Premiere Pro 等の他アプリでの読み込みは未検証
  (ffprobe での形式照合まで)。特に奇数サイズ・非標準サイズの受け入れは各アプリ依存。
- MXF(OP1a / OP-Atom)コンテナは対象外。Avid へ MXF で渡す運用が必要なら別途追加する。
- インターレース素材・インターレース書き出しは対象外。
- アルファ(透明)は保持しない。DNxHR 444 でも `yuv444p10le`(アルファなし)で書く
  (中間は ProRes 4444 だが、最終形式に透明は残らない)。
- アプリの保存パネルの実操作(形式切替時の説明ラベル・拡張子の追随)は自動テスト外。
  パネル配線は既存 Web 形式と同じハンドラを拡張しており、Core 側の判定はテストで担保している。
- 長尺素材での書き出し時間・ファイルサイズの実測は未実施(DNxHR は中間コーデックのため
  ファイルが非常に大きくなる。1080p・数秒でも数百 MB 級)。
