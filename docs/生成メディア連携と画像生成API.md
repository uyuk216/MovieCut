# 生成メディア共通連携口と画像生成 API 連携

Premiere の「生成メディア: 画像生成」(棚卸し表 AI04 / 実装候補 D-24)への対応。
生成メディア群(画像・動画・効果音・音楽・サウンドスケープ・生成延長)に共通する
連携口を先に作り、その最初の実装として画像生成 API の直接連携を入れた。

W5-4 で残りを追加した: 動画生成プロバイダ(非同期ジョブのポーリング)、
音声/音楽生成プロバイダ(同期応答)、生成延長の口(Core 計画 + UI 導線)。
詳細は末尾の「W5-4: 動画 / 音声・音楽プロバイダと生成延長」を参照。

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
- 未対応(将来、共通口の上に足す): 画像の編集(インペインティング等)、
  複数枚生成、生成履歴の管理。動画生成・効果音/音楽生成・生成延長は
  W5-4 で追加した(次節)。

## W5-4: 動画 / 音声・音楽プロバイダと生成延長

Core は `GenerativeMediaProviders.swift`、画面側は既存の
`ProjectModel+GenerativeMedia.swift` / `GenerativeMediaDialogs.swift` /
`AppMenu.swift` へ足した(設定シートや確認・配置の流れは新設せず既存を拡張)。
方針は画像生成と完全に同じ: 生成はユーザーの API アカウントで実行され、
確認文には必ず「あなたの API アカウントに課金され、MovieCut のサーバは
経由しない」旨(共通の `GenerativeMediaConfirmation.costNote`)が入る。
キーは UserDefaults にだけ保存し、確認文・プロジェクト・ログには出ない
(テストで番兵文字列が混入しないことを担保)。

### 動画生成(`OpenAICompatibleVideoProvider` / `VideoGenerationSettings`)

- 設定(UserDefaults の `videogen.*`): エンドポイント・モデル・APIキー・
  大きさ(既定 1280x720、候補 1920x1080 / 720x1280 / 1024x1024、任意文字列も可)・
  既定の長さ(秒)・形式(既定 mp4)・ポーリング間隔(既定 5 秒)と上限回数(既定 60)。
- 作成リクエスト: エンドポイントへ POST で
  `model / prompt / size / seconds / duration / output_format` を送る。
- 対応する応答形式:
  - 同期完了: `data[0].b64_json`、または `data[0].url` / `url` / `video_url`
    / `audio_url` / `file_url`(URL は取りに行く。キーは同じホストのときだけ付ける)。
  - 非同期ジョブ: `id`(または `job_id`)と `status` が返る形式。
    `{エンドポイント}/{id}` を GET でポーリングし、状態が
    completed 系(completed / succeeded / success / done / finished)になったら
    上記の方法で本体を取り、どれも無ければ `{エンドポイント}/{id}/content`
    から取得する。failed 系(failed / error / cancelled / canceled)は
    `jobFailed`(応答の `error.message` 等を含む)、上限回数を超えたら
    `jobTimedOut` で失敗する。未知の状態は継続として扱う。
- 結果は `Application Support/MovieCut/GeneratedMedia/<UUID>.<形式>` に
  保存し(`DataLocations.generatedMedia`、画像の `AIImages` とは別)、
  共通の `GenerativeMediaPlacement` で動画クリップとして再生ヘッドに置く。
  ファイルの中身が動画として読めるかの検証はしていない(空でないことだけ確認)。

### 音声 / 音楽生成(`OpenAICompatibleAudioProvider` / `AudioGenerationSettings`)

- 対象は効果音(audio)・音楽(music)・サウンドスケープ(soundscape)で、
  設定は共通(UserDefaults の `audiogen.*`: エンドポイント・モデル・
  APIキー・既定の長さ・形式、既定 mp3)。
- リクエスト: POST で `model / prompt / input / kind / response_format /
  format / duration / seconds` を送る。読み上げ系が使う `input` と
  音楽・効果音系が使う `prompt` の両方に同じ文を入れるのは、汎用口として
  どちらの流儀のサービスにも渡るようにするため。
- 対応する応答形式(同期応答のみ):
  - 音声データそのもの(JSON でない応答はバイナリとしてそのまま保存)、
  - JSON の Base64(`data[0].b64_json` / `b64_json` / `audio` 等)、
  - JSON の URL(`data[0].url` / `url` / `audio_url` 等。取りに行く)。
  JSON なのにメディアが読み取れない場合は `unparsable`、空応答は
  `emptyResponse` で失敗する。音声として再生できるかの検証はしていない
  (空でないことだけ確認)。
- 保存先と配置は動画と同じ(音声クリップとして配置)。

### 生成延長の口(`GenerativeExtensionPlanner` / `GenerativeExtensionPlacement`)

- 対象は動画・音声クリップだけ。前/後ろのどちらかを 0 より大きく、
  片側 30 秒まで。前の延長がタイムラインの 0 秒より前に出る指定は止める。
- 計画(`GenerativeExtensionPlan`)は純粋な値で、元クリップは書き換えない。
  実生成は計画の `generationRequests(prompt:)` を動画/音声プロバイダへ
  渡し、結果を前後の区間にその計画どおりの長さで置く(配置は Undo 1 回)。
- 画面導線: クリップ ▸ 生成延長(API)…。選択クリップが対象外、または
  その種類の設定が未設定のあいだはメニュー項目が無効表示になる。
- **保留事項(重要)**: 汎用エンドポイントには元素材を送る標準形式が無いため、
  この口は「プロンプトから前後の区間を新規生成して隣に置く」もので、
  元素材の続きを解析してつなぐ本当の生成延長ではない。元の素材そのものは
  サービスへ送らない(送らないこと自体はプライバシー方針にも合う)。
  ベンダー固有の素材アップロード形式への対応は、実サービスが決まってから。

### 画面側の導線(W5-4 で追加)

- クリップ ▸ AIで動画を生成(API)… / AIで効果音を生成(API)… /
  AIで音楽を生成(API)… / AIでサウンドスケープを生成(API)… /
  生成延長(API)…(いずれも未設定のあいだは無効表示)。
- ファイル ▸ 生成メディア(API)の設定… の既存シートに、動画と
  音声/音楽のセクション(エンドポイント・モデル・APIキー、動画は
  大きさと形式も)を追加した。シート自体は新設していない。
- どの流れも、プロンプト/仕様の入力 → 送信前確認(送信先・プロンプト・
  モデル・仕様・費用の注意) → 生成(キャンセル可) → 配置(Undo 1 回)。

### W5-4 の対応範囲と未検証事項

- **実 API への疎通は未検証**(ユーザーのキーが必要なため)。担保しているのは
  モック応答でのリクエスト組み立て・ポーリング遷移(完了/失敗/時間切れ)・
  content フォールバック・同期応答(Base64/URL/バイナリ)の解釈・
  ファイル生成・クリップ配置・生成延長の計画と配置・キー非混入・
  未設定時の無効化まで。
- サービスごとに異なる形式(ベンダー固有のジョブ形式、署名付き URL の
  期限切れ、生成中の進捗表示、料金見積もりの表示)は未対応。
- 生成した動画/音声ファイルの再生可否の検証、生成履歴の管理は未対応。
