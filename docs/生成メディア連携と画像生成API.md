# 生成メディア共通連携口と画像生成 API 連携

Premiere の「生成メディア: 画像生成」(棚卸し表 AI04 / 実装候補 D-24)への対応。
生成メディア群(画像・動画・効果音・音楽・サウンドスケープ・生成延長)に共通する
連携口を先に作り、その最初の実装として画像生成 API の直接連携を入れた。

## 設計方針(ユーザー決定 2026-11-19・厳守)

- MovieCut 本体は連携口(プロバイダ境界と UI)だけを用意し、生成は
  **ユーザー自身の API キー/アカウント** で実行され、費用もユーザーのもの。
- **キーはユーザーのマシン内にのみ保存**し、開発側サーバには一切置かない・
  経由させない。保存方法は既存の AI テキスト生成(`TextGenerationSettings`)と
  同じ作法: この Mac のアプリ設定(UserDefaults)にだけ保存し、
  プロジェクトファイル・ログ・テストには含めない。送信時は Authorization
  ヘッダーにだけ使う。
- 生成前に、**送信内容・送信先・想定費用をユーザーが確認する流れを必須**とする
  (既存 `AIProvider` の送信前確認と同じ作法。確認表現は Core の
  `GenerativeMediaConfirmation` で、キー��含まないことをテストで担保)。
- 未設定時は機能を無効表示にする(メニュー項目が無効になり、実行しても
  `notConfigured` の案内が出る)。

## 共通連携口(Core: `GenerativeMedia.swift`)

流れ: 対象範囲/プロンプト指定 → 送信前確認 → 生成 → 結果をクリップとして配置。

- `GenerativeMediaKind`: image / video / audio / music / soundscape。
  種類ごとに配置先のクリップ種別(`clipType`)と既定の長さを持つ。
- `GenerativeMediaRequest`: 種類・プロンプト・配置時刻・尺・大きさ指定。
  `validate()` で空・長すぎるプロンプトを通信の前に止める
  (上限は既存の AI 画像フックと同じ 2000 文字)。
- `GenerativeMediaProvider`: 差し替え口。`supportedKinds` /
  `destinationDescription`(キーを含めない) / `generate(_:)`。
  将来の動画/音声生成は、このプロトコルを実装して同じ確認・配置に乗る。
- `GenerativeMediaConfirmation`: 確認画面に出す内容(種類・プロンプト・
  モデル・大きさ・費用の注意文)。費用は金額ではなく「あなたの API
  アカウントに課金され、MovieCut のサーバは経由しない」ことを明示する
  (単価はサービスごとに違うため)。
- `GenerativeMediaPlacement`: 結果ファイルを `ClipEditing.place` で
  クリップとして置く共通処理(Undo 登録は画面側)。
- `GenerativeMediaError`: 共通の失敗(未設定・HTTP・通信・解釈不能など)。
  どの文にもキーの値は含めない。
- `FakeGenerativeMediaProvider`: テスト用モック。

## 画像生成の API 直接連携(Core: `ImageGeneration.swift`)

- `OpenAICompatibleImageProvider`: OpenAI 互換の画像生成エンドポイント
  (images generations 形式)へ `model / prompt / size / n=1 /
  response_format=b64_json` を POST する汎用クライアント。
  **特定ベンダーに固定しない**: エンドポイント URL とモデル名はユーザーが
  設定で自由に指定する。
- 応答は `data[0].b64_json` を基本とし、無い場合は `data[0].url` から
  画像を取りに行く。受け取った内容が画像として読めるか
  (`AIImageStore.isReadableImage`)を確かめてから、既存フックと同じ置き場所
  (Application Support/MovieCut/AIImages)へ保存する。読めない内容は
  ファイルを残さず失敗する。
- 通信は `ImageGenerationTransport` 境界の後ろ(テストでは差し替え)。
- `ImageGenerationSettings`: エンドポイント・モデル・APIキー・大きさ・
  待つ秒数。エンドポイント検証は AI テキスト生成と共通(https は可、
  http は localhost 宛てだけ可)。大きさの候補は 1024x1024 /
  1792x1024 / 1024x1792 で、任意の文字列も送れる。
- `FakeImageGenerationProvider`: モック応答で生成 → 配置を通すための偽物。

## 画面側の導線

- ファイル ▸ 生成メディア(API)の設定…(`GenerativeMediaDialogs`)
- クリップ ▸ AIで画像を生成(API)…(`ProjectModel+GenerativeMedia`)
  - プロンプトと大きさを入力 → 送信前確認(送信先・プロンプト・モデル・
    大きさ・費用の注意) → 生成(キャンセル可) → 画像クリップを再生ヘッドへ
    配置(Undo 1 回)。
  - 未設定のあいだはメニュー項目が無効表示(ヒントは「未設定のため使えません」)。
- 既存のローカルコマンド方式(クリップ ▸ AIで画像を作る…)とは独立した追加で、
  その挙動は変えていない。

## 対応範囲と未検証事項

- 対応: OpenAI 互換 images generations 形式の画像生成(Basic な単発生成、
  1 枚)。大きさは文字列指定。
- **実 API への疎通は未検証**(ユーザーのキーが必要なため)。担保しているのは
  モック応答でのリクエスト組み立て・応答解釈・ファイル生成・クリップ配置と、
  未設定時の無効化、確認フローまで。
- 未対応(将来、共通口の上に足す): 動画生成・効果音/音楽生成・生成延長、
  画像の編集(インペインティング等)、複数枚生成、生成履歴の管理。
