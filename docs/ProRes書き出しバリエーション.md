# ProRes 書き出しバリエーション（HQ / LT / Proxy 追加）

作成: 2026-11-19、ブランチ `feat/prores-variants`
起点資料: `~/workspace/moviecut-research/premiere-inventory.md` 書き出し節「ProRes 書き出し」（部分実装: 422 / 4444 のみ、HQ・LT・Proxy が不足）

## 対応バリエーションと実現経路

すべて **AVAssetWriter（AVFoundation）経由**で実現した。ffmpeg バックエンドは使っていない（使う必要が無かった）。

| バリエーション | コーデック文字列（`Project.codec` / CLI `--codec`） | AVVideoCodecType | FourCharCode / ffprobe の codec_tag_string | 状態 |
|---|---|---|---|---|
| ProRes 422（既存） | `prores422` | `.proRes422` | `apcn` | 従来どおり（変更なし） |
| ProRes 422 HQ（追加） | `prores422hq` | `.proRes422HQ` | `apch` | 追加 |
| ProRes 422 LT（追加） | `prores422lt` | `.proRes422LT` | `apcs` | 追加 |
| ProRes 422 Proxy（追加） | `prores422proxy` | `.proRes422Proxy` | `apco` | 追加 |
| ProRes 4444（既存） | `prores4444` | `.proRes4444` | `ap4h` | 従来どおり（透明保持の扱いも変更なし） |

- 定義は `OutputSettings.swift` の `OutputPlan`（`proRes422HQ` / `proRes422LT` / `proRes422Proxy` 定数と `proResCodecs` 一覧）。`isProRes` / `codecLabel` / 拡張子（.mov）判定はこの一覧に基づく。
- 映像コーデックの対応付けは `Exporter.proResCodecType(for:)`（未知の ProRes 文字列は従来どおり 422 に倒す保険付き）。音声は既存の ProRes 経路と同じく .mov に 24bit PCM で入る。
- 選択 UI: 設定画面の「書き出し形式」ピッカー、アプリメニュー（`AppMenuSpec.codecs`）、CLI の `--codec` に 3 種を追加。表示文言は日本語 + `L10nTable` に英訳を追加（新規キー 3 件、既存キーとの重複なしを確認済み）。
- 既存の 422 / 4444 の出力・挙動は変更していない（追加のみ）。DNx 書き出しの中間コーデック（422 / 4444）も従来どおり。

## 実機確認（AVAssetWriter で使えるか）

実装前に、この Mac（macOS 27.3 / Swift 6.4.2）で AVAssetWriter に各 `AVVideoCodecType` を直接渡す最小プローブ（320×180・10 コマ）を実行し、全種で書き出しが完了（status=completed）することと、ffprobe の `codec_tag_string` が想定どおり（HQ=`apch` / LT=`apcs` / Proxy=`apco`、参考: 422=`apcn` / 4444=`ap4h`）であることを確認した。使えないバリエーションは無かったため、ffmpeg 経由の代替や見送りは発生していない。

## テストと実書き出し確認

- 単体テスト（`Tests/MovieCutCoreTests/APNGProResTests.swift` に追加）:
  - `testOutputPlanKnowsNewProResVariants` — 各バリエーションの設定値（保持・ProRes 判定・.mov・表示名・大きなサイズでも HEVC へ切り替わらない）。
  - `testProResCodecTypeMapping` — コーデック文字列 → `AVVideoCodecType` の対応（既存 2 種含む全種）。
  - `testNewProResVariantsSurviveProjectRoundTrip` — プロジェクト JSON の保存・復元で形式が保持される。
  - `testExportProResVariantsOneSecond` — HQ / LT / Proxy それぞれ実書き出し（320×180・1 秒・30fps）し、開き直して FourCharCode とコマ数を照合する。
- アプリ側テスト（`Tests/MovieCutTests/APNGProResAppTests.swift`）: メニューのコーデック一覧（7 件）の期待値を更新し、`testSetCodecAcceptsNewProResVariants`（選択・解像度変更で保持・保存名が .mov・保存パネルが QuickTime）を追加。
- Core テスト全件: 2,937 件実行・失敗 0（スキップ 9）。起点ベースライン（失敗 0）から増えていない。対象を絞った実行では `APNGProResTests` 17 件・アプリ側 `APNGProResAppTests` 7 件も全て合格。
- CLI 実書き出し確認: `moviecut-cli genclips` で作ったプロジェクト（320×180 へ縮小指定、137 コマ）を各形式で書き出し、ffprobe で照合した。HQ=`apch`（1,135,655 バイト）/ LT=`apcs`（702,263 バイト）/ Proxy=`apco`（366,471 バイト）。参考として既存 422=`apcn`（875,063 バイト）/ 4444=`ap4h`（1,406,131 バイト）も従来どおり。ファイルサイズの序列（4444 > HQ > 422 > LT > Proxy）も想定どおりだった。

## 未検証事項・保留

- GUI 目視（設定ピッカー／メニューでの実際の表示・選択操作）は未実施。選択ロジックはアプリ側単体テストで確認している。
- 長尺・高解像度（4K 以上）での各バリエーションの実書き出しは未検証（単体テストは 320×180・1 秒。プローブも 320×180・10 コマ）。サイズ上限の判定は既存 ProRes と同じ経路（HEVC の面積上限）を通る。
- ProRes 4444 XQ / RAW は対象外（今回の依頼範囲は HQ / LT / Proxy）。
- カスタム書き出しプリセット（`CustomExportPreset`）は従来どおり H.264 / HEVC のみで、ProRes は保存対象に含めていない（既存 422 / 4444 と同じ扱い。プロジェクト自体の形式設定としては保存される）。
