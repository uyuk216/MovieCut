# MovieCut ゴールデンデータセット

## 目的
プロジェクト形式（`01-project-format.md`）の「decode → encode」結果の期待値を、言語に依存しない形で固定する。Mac 版（Swift）のテストが正として読み、Windows 版（C++ 等）など他言語実装も同じデータで機械的に検証できる。

## 構成
```
manifest.json   ケース一覧
inputs/         入力（.ymproj と固定 JSON）
expected/       期待値
```
ケースの種別（`kind`）:
- `roundtrip-canonical`: `input` を decode → encode し、canonical 化した文字列が `expected` と一致する。
- `roundtrip-byte-mac`: decode → encode のバイト列が `expected` と完全一致する（Mac 参照実装の字面。他言語は任意）。
- `fixed-json`: `roundtrip-canonical` と同じ検証。入力がテストコード由来の固定 JSON というだけの区別。

## 版の付け方
`datasetVersion` はセマンティックバージョン。ケース追加はマイナー、期待値の意味が変わる変更はメジャー、誤字修正等はパッチ。

## 正規化ダンプ（canonical）の規則
encode 結果の JSON を解析し、次の規則で再直列化する。
- オブジェクトのキーは Unicode コードポイント昇順。
- 字下げ2スペース、`"key": value`（コロンの前に空白なし）。配列・オブジェクトは要素ごとに改行。空オブジェクトは `{}`、空配列は `[]`。ファイル末尾に改行なし。
- 数値: 整数値（小数部なし）で絶対値が 2^53 未満なら整数表記（10進、指数なし）。それ以外は最短往復表現（Swift の Double の通常表記）。-0 は 0。
- 文字列: `"`、`\`、制御文字（U+0000〜U+001F）のみエスケープ。`\b \f \n \r \t` の短形があればそれを、無ければ `\u00XX`（16進は小文字）。それ以外（非 ASCII 含む）は生の UTF-8。`/` はエスケープしない。
- 真偽値・null はそのまま。

## 生成器の使い方（Mac）
canonical 系の expected は生成器で作る。
```
MOVIECUT_GENERATE_GOLDEN=1 swift test --filter GoldenDatasetTests/testGenerateExpected
```
リポジトリ内の `Tests/MovieCutCoreTests/GoldenDataset/expected/` に書き出す。byte 系は既存 golden のコピーが正で、生成対象外。生成後は差分を目視確認してからコミットすること。

## 他言語実装での使い方
1. `manifest.json` を読む。
2. 各ケースで `input` を自前の Project として decode → encode する。
3. 上記の canonical 規則で整形し、`expected` の内容と文字列一致を確認する（`roundtrip-byte-mac` は任意でバイト比較）。

## 決定性についての注意（ケース追加時の規則）
期待値は全プラットフォームで機械比較するため、入力は decode が決定的でなければならない。ランダムな ID 生成に依存する入力（例: `characters` が空で、既定キャラクターがランダム ID で生成される形）は、そのままではケースにできない。その場合は、生成される既定の内容を id 固定で入力に明示してからケース化すること（本データセットの roundtrip-canonical 7件がこの形。manifest の notes に明記してある）。既定値そのものの検証は Mac 版の単体テスト（ProjectGoldenRoundTripTests 等）の担当範囲とする。
