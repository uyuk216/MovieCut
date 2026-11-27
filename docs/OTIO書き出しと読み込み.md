# OTIO(OpenTimelineIO)の書き出しと読み込み

MovieCut のタイムラインを `.otio`(JSON)でやり取りする。Premiere / DaVinci Resolve 等と OTIO 経由で受け渡す用途。
実装は `Sources/MovieCutCore/OtioInterchange.swift`(`OtioExporter` / `OtioImporter`)。OpenTimelineIO 本体は使わず、JSON として自前で読み書きする。

## 入口
- メニュー: 出力 ▸「OTIO で書き出す…」、ファイル ▸「OTIO を読み込む…」(読み込みは 1 回の取り消しで戻せる)
- CLI: `moviecut-cli export-otio <in.mcpjc> <out.otio>` / `moviecut-cli import-otio <in.otio> <out.mcpjc>`
- どちらも、落ちた要素はレポート(アラート / stderr)に必ず出す。

## 対応要素
| OTIO | 書き出し | 読み込み |
|---|---|---|
| Timeline.1 / Stack.1 | ○ | ○(Stack 単体も可) |
| Track.1(kind Video / Audio) | ○ 映像・音声クリップごとに分ける | ○ 他の kind は映像扱い+注記 |
| Clip.1 | ○ 名前・source_range・enabled | ○ |
| ExternalReference.1 | ○ target_url(file URL、パーセントエンコード)・available_range | ○ |
| Gap.1 | ○ クリップ間の空き | ○ |
| TimeRange.1 / RationalTime.1 | ○ rate は fps の分数どおり(29.97 は 30000/1001) | ○ 要素ごとの rate で秒に換算 |
| LinearTimeWarp.1 | ○ 一定速度(0.25〜4) | ○ 範囲外は等倍+レポート |
| Marker.2(Stack 上) | ○ プロジェクトのマーカー(色は既定) | ○ |
| Transition.1 | ×(MovieCut のトランジションは入/出の形で意味が違う) | レポートに出して読み飛ばす(前後クリップの位置は保つ) |

## 落ちる要素(黙って落とさない)
- 書き出し: テキスト・ボイス・ぼかし・調整レイヤー・図形・立ち絵・複合・シーン等の非メディアクリップ(クリップ単位で「書き出せませんでした」。位置は前後の Gap で保たれる)。
- 書き出し: クリップに付いたエフェクト・キーフレーム・トランジション・音声フェード・速度ランプ/逆再生/フリーズは件数をレポートに出す。
- 読み込み: Transition、MissingReference / GeneratorReference / ImageSequenceReference のクリップ、LinearTimeWarp 以外のエフェクト、クリップ上のマーカー、ネストした Stack / Track は「読み込めませんでした」として一覧に出す(ネスト分は長さだけ空きとして扱う)。
- 重なるクリップは OTIO の直列トラックに収まらないため別トラックに分け、読み込み時に元のトラックへ戻す。

## メタデータ方針
- MovieCut 独自の値は各オブジェクトの `metadata["moviecut"]` に入れる(他ソフトは無視して素通しする)。
  - Timeline: `width` `height` `fps` `bg` `exporter`、落ちたクリップ種別の件数 `droppedClips`、落ちた機能 `droppedFeatures`
  - Track: `trackIndex`(同じ MovieCut トラックから分かれたものを元に戻す)`trackName` `lane`
  - Clip: `id` `volume` `opacity` `x` `y` `scale` `muted`、落ちた機能の名前 `droppedFeatures`
- OTIO にない画面サイズは、メタデータがなければ 1920×1080 として読む(注記を出す)。フレームレートは メタデータ → 最初に見つかった rate の順。
- 時刻はフレーム単位に丸める(フレームに揃った編集は往復で一致する)。

## AAF を今回見送る理由と、やる場合の前提
見送った理由:
- AAF は Microsoft Structured Storage(複合ファイル)ベースのバイナリ形式で、MobID / SourceMob / CompositionMob など Avid 由来の大きなオブジェクトモデルを正しく組む必要があり、読み書きとも規模が大きい。
- 実用上は埋め込み/リンク音声・メタデータ・タイムコードの流儀が製品ごとに違い、実物の相互運用確認(Avid / Pro Tools / Resolve)が要る。仕様だけでは正しさを担保できない。
- 外部ライブラリ導入禁止の方針のため、OTIO のようにテキストで自前実装できない。
- OTIO は Resolve / Premiere 経由(各ソフトの OTIO 入出力やアダプタ)で受け渡せるため、まず OTIO を優先した。

やる場合の前提:
- Structured Storage と AAF オブジェクトモデルの読み書きを自前実装するか、依存導入を例外として許可するかを先に決める。
- 対象を絞る(音声ポストプロダクション向けのクリップ+フェード+ボリュームのみ等)。
- 検証用に実機の AAF サンプル(Pro Tools / Avid / Resolve 書き出し)を用意する。
- 他ソフトのバイナリを MovieCut 側で再エンコードせず、リンク(外部参照)で扱う前提で始める。
