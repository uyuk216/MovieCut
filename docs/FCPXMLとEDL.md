# FCP XML(XMEML)と EDL の書き出し・読み込み

Premiere Pro など他の編集ソフトとプロジェクト(タイムライン)を受け渡すための交換形式対応。
棚卸し表の「交換形式(FCP XML / EDL / AAF)」項目の第 1 段。

- FCP XML(XMEML):書き出し+読み込み
- EDL(CMX 3600):書き出しのみ
- AAF:対象外(規模が大きいため後段。やる場合は別途設計する)

## 形式の根拠(推測で書いていない)

- FCP XML は Apple 公式「Final Cut Pro XML Interchange Format」(2009-02-04)が正資料。
  本実装は同書の XMEML バージョン 4 に従う。Premiere Pro が読み書きする「Final Cut Pro XML」も
  この XMEML 系である。なお現在の Final Cut Pro の FCPXML(`<fcpxml>`)は**別形式**で、本実装の
  対象ではない(読み込み時に混同しないよう、fcpxml ははっきり断る)。
- EDL は CMX 3600(SMPTE 258M 系)の公開仕様に従う:TITLE / FCM ヘッダ、イベント行
  (番号 001〜999、リール名最大 8 文字、トラック V / A / A2 / A3 / A4、トランジション、
  素材イン/アウト、記録イン/アウト、タイムコード HH:MM:SS:FF)。

## 使い方

- アプリ:ファイル ▸ FCP XMLを読み込む… / 出力 ▸ FCP XML形式(.xml)で書き出す… /
  出力 ▸ EDL形式(.edl)で書き出す…
  - 読み込みは今のプロジェクトを読み込んだ内容に置き換える(1 回の Undo で戻せる)。
  - 書き出し・読み込みのどちらでも、変換できなかった要素は結果のアラートに
    理由つきで一覧表示する(黙って落とさない)。
- CLI:`moviecut-cli export-fcpxml <in.mcpjc> <out.xml>` /
  `moviecut-cli export-edl <in.mcpjc> <out.edl>` /
  `moviecut-cli import-fcpxml <in.xml> <out.mcpjc>`
  (レポートは stderr に出す)
- Core API:`FcpXmlExporter` / `FcpXmlImporter` / `EdlExporter`(いずれも Report を返す)

## FCP XML の変換対応

### 運ぶもの(書き出し・読み込み共通)

| MovieCut | XMEML |
|---|---|
| プロジェクトの幅・高さ | sequence の video format(samplecharacteristics) |
| fps | rate(timebase + ntsc)。NTSC 系(29.97 等)は公称 timebase + ntsc TRUE、フレーム数は実レート(30000/1001 等)で数える |
| レイヤー(トラック) | 映像クリップを含むレイヤーは video track、音声クリップを含むレイヤーは audio track に分ける(それぞれ元の順序を保つ。混在レイヤーは両方に分かれる) |
| クリップの配置 | clipitem の start / end(フレーム) |
| 素材の使用範囲 | clipitem の in / out(フレーム)。file の pathurl(file://localhost + パーセントエンコード)、同じ素材は最初の 1 回だけ完全な file を書き、以降は id 参照 |
| 素材の長さ | file の duration(clip の srcDuration から。無い素材は使用範囲の終わりで代用し、レポートに注記) |
| 位置(x / y) | Basic Motion の center(horiz = x - 0.5、vert = y - 0.5。画面中心を 0 とする割合) |
| スケール | Basic Motion の scale(パーセント = scale × 100) |
| 回転 | Basic Motion の rotation(度) |
| 不透明度 | Opacity フィルタ(0〜100) |
| 音量(音声クリップ) | Audio Levels フィルタの Level(線形ゲイン) |
| 無効化したクリップ | clipitem の enabled FALSE |
| 隠した/ミュートしたレイヤー | track の enabled FALSE |
| マーカー | sequence の marker(in / out = フレーム) |

読み込み側の作法:

- `<project><children>` の中の sequence、素 sequence のどちらでも読む。
- トランジションを挟んだ clipitem の start / end = -1 は、前後のトランジションと
  直前のクリップから補って解決する(仕様 Listing 3-17 の形)。
- `<file id="..."/>` の参照だけの clipitem も、定義済みの file から素材を解決する。
- キーフレーム付きの引数は、先頭の値を静止値として読み、レポートに注記する。
- 拡張子で静止画(png / jpg 等)を判別し、画像クリップとして取り込む。

### 落ちる要素(すべてレポートに理由つきで出す)

書き出し:

- 文字・ボイス・ぼかし・調整・ビジュアライザ・複合・シーン・図形・立ち絵クリップ
  (XMEML で表せる素材クリップではないため、クリップごと書き出さない)
- キーフレーム(静止値だけを書き出す)
- 入/出トランジション(XMEML の transitionitem はクリップ間の重なりを前提とし、
  MovieCut の入/出とは形が違うため)
- エフェクト、音声エフェクト、音声フェード
- 速度変更・逆再生・フリーズ・速度ランプ(等倍の使用範囲として書き出す)
- 切り抜き、反転、ブレンドモード、形のマスク、メッシュ/パペット変形、音声のパン
- 動画クリップの音量(音声を分けた linked な音声 clipitem は第 1 段では出さない。
  動画の音は映像クリップに付随するものとして書き出す旨をレポートに注記する)
- マーカーの色(表す場所がない)

読み込み:

- transitionitem(カットとして扱う)
- generatoritem(文字などの生成物)
- 入れ子シーケンス(clipitem の中の sequence)
- Basic Motion / Opacity / Audio Levels 以外のフィルタ・エフェクト

### 近似・前提

- スケールの基準:MovieCut の scale は「画面に収まる大きさを 1」とする前提で
  パーセントに換算する。素材の実寸がプロジェクトに記録されていないため、
  素材のピクセル寸法基準のソフトでは見た目の大きさがずれる場合がある。
- Basic Motion の center は、仕様書の Listing の実例(小数値)に倣い割合で書く。
  受け側の解釈(割合かピクセルか)はソフトにより異なる可能性があり、実機未検証。
- 素材のタイムコード開始点は常に 00:00:00:00 とする(MovieCut に素材側タイムコードの
  記録がないため)。in / out は素材の頭からのフレーム数。
- 12.5fps のような整数 timebase で表せないレートは、最も近い整数の timebase で書き、
  レポートに注記する(フレーム数自体は実レートで数えるので MovieCut 往復では保たれる)。
- 音声の format は 48kHz / 16bit 固定で書く(素材の実フォーマットは記録していないため)。

## EDL の変換対応

- 書き出しのみ。映像は「映像クリップを含む最初のレイヤー」を代表の 1 トラックとし、
  音声は音声クリップを含むレイヤーを順に A / A2 / A3 / A4(最大 4)とする。
  代表以外の映像トラック、5 本目以降の音声、文字等のクリップはレポートに理由つきで出す。
- イベントは記録イン順に並べ、001〜999 で番号を振る(999 件を超えた分は切って注記)。
- すべてのイベントはカット(C)で書く。MovieCut のトランジションはクリップの入/出に
  付く形で、CMX のクリップ間トランジションとは意味が違うため D には変換しない
  (該当クリップはレポートに注記)。
- 速度変更のあるクリップは、素材側の長さ(記録の長さ × 速度)で書き、速度が伝わる形にする
  (モーション行 M2 は書かない。レポートに注記)。
- リール名は素材ファイル名から作る(ASCII 英数字のみ・最大 8 文字・衝突時は末尾に連番)。
  作れない素材は AX。イベント後に `* FROM CLIP NAME:` / `* SOURCE FILE:` のコメント行を付け、
  受け側での再リンクを助ける。
- 29.97 / 59.94 は FCM: DROP FRAME とし、ドロップフレームの数え方でタイムコードを書く。
  それ以外は NON-DROP FRAME。

## 未検証事項

- **他社ソフト実機での読み込みは未検証**:Premiere Pro / Final Cut Pro 7 /
  DaVinci Resolve の実機で本実装の書き出しを開いた確認はしていない。
  保証範囲は「仕様どおりの構造であること」と「MovieCut への往復でカット位置・
  素材・基本変換が一致すること」(単体テストで検証)まで。
  特に Basic Motion の center の解釈とスケールの基準は、受け側で実機確認が必要。
- Premiere 独自の拡張要素(Adobe 固有タグ)は書いていない。Premiere 書き出しの
  XMEML を読み込む分には標準要素の範囲で対応するが、拡張要素は読み飛ばす。
- AAF は未対応(後段)。
