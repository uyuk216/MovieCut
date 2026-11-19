# 追加 TTS: COEIROINK / SHAREVOX(W3-09、YMM4 監査 #37)

2026-11-19、第3波バッチR。プラグイン追加方式(VOICEVOX プラグイン / AquesTalk プラグインの前例)で、
COEIROINK と SHAREVOX を音声合成エンジンとして追加した。内蔵の音声合成スタック
(`RealVoiceProvider` / `VoicevoxClient` / `AquesTalkSynthesizer` 等)は無変更で、
プラグイン未登録の状態では従来の挙動と完全一致する(テストで担保)。

## API 仕様の確認結果(実仕様)

| エンジン | 既定の接続先 | API |
|---|---|---|
| VOICEVOX(既存) | `http://127.0.0.1:50021` | GET /speakers、POST /audio_query、POST /synthesis、GET /version |
| SHAREVOX | `http://127.0.0.1:50025` | VOICEVOX のフォークで、VOICEVOX 互換 API(同上) |
| COEIROINK v1 | `http://127.0.0.1:50032` | VOICEVOX 互換 API(同上) |
| COEIROINK v2 | `http://127.0.0.1:50032` | **独自 API**(GET /v1/speakers、GET /v1/engine_info、POST /v1/synthesis)。VOICEVOX 互換ではない |

- SHAREVOX が VOICEVOX 互換・ポート 50025 であること、COEIROINK v1 が VOICEVOX 互換・
  ポート 50032 であることは、VOICEVOX 系エンジンを横断対応する公開実装
  (voicevox-family-mcp、TTSController)の対応表で確認した。
- COEIROINK v2 は 2023 年の v2 化で独自 UI・独自 API に移行した(Wikipedia の COEIROINK 項で確認)。
  v2 でもローカルサーバはポート 50032 で、話者一覧は GET /v1/speakers
  (話者は UUID 識別、スタイルは数値 ID)であることは COEIROINK 連携ツール
  (coeiro-operator)の案内で確認した。当初は v2 の合成リクエスト形式が公開資料だけでは
  確定できなかったため話者一覧の読み取りのみ対応としたが、**R3-1(2026-11-19)で合成形式を
  確定し、合成まで実装した**(次節「COEIROINK v2 合成(R3-1)」)。

## 実装

- `Sources/MovieCutCore/Plugins/VoicevoxFamilyPlugin.swift`(共通実装)
  - `VoicevoxFamilyEngineSpec`: エンジン差分(識別子・表示名・既定 URL・キャッシュタグ・プラグイン id)。
  - `VoicevoxFamilyPluginClient`: VOICEVOX プラグインと同じ手順の共通クライアント。
    GET /speakers、POST /audio_query → パラメータ設定 → POST /synthesis → キャッシュ保存。
    パラメータ変換(speedScale / pitchScale / intonationScale / volumeScale /
    prePhonemeLength 既定 0.03 / postPhonemeLength 既定 0.03 / pauseLengthScale 既定 0.65)は
    VOICEVOX プラグインと同一。キャッシュキーの先頭タグだけエンジン別
    (`coeiroink` / `sharevox`)にして VOICEVOX のキャッシュと分けた。
  - `VoicevoxFamilyPluginProvider`: `VoicevoxAccentProviding` 実装。アクセント句の差し替え合成にも対応。
  - `VoicevoxFamilyAvailability`: GET /version での生存確認のみ。**自動起動はしない**
    (COEIROINK / SHAREVOX は単体アプリで、同梱エンジンを決まった引数で起動する公式手順が
    確認できないため。VOICEVOX プラグインとの差分はこの点だけ)。
  - 送信先の検査は VOICEVOX と同じ `VoiceEndpointPolicy` を使う(ローカル以外は設定で許可したホストのみ)。
    認証は無い(ローカル API の仕様どおり)。
- `Sources/MovieCutCore/Plugins/CoeiroinkPlugin.swift`
  - マニフェスト(id `jp.local.moviecut.plugin.coeiroink`、engine `coeiroink`)。
  - `CoeiroinkV2Client`: v2 の GET /v1/speakers 読み取り専用(camelCase / snake_case 両対応で解釈)。
- `Sources/MovieCutCore/Plugins/SharevoxPlugin.swift`
  - マニフェスト(id `jp.local.moviecut.plugin.sharevox`、engine `sharevox`)。
- アプリ側の配線
  - `AppServices.makePluginHost` に両プラグインを登録(遅延読み込みは従来どおり)。
  - キャラのインスペクタ: 音声エンジン Picker に COEIROINK / SHAREVOX を追加。
    話者は数値 ID の直接入力(下記「留保」参照)+ 話す速さ / 高さ / 抑揚(VOICEVOX と同じ項目・範囲)。
  - `CharacterEditing.switchEngine`: 新エンジンは VOICEVOX と同じ単位(速さは倍率、話者は数値 ID、
    未設定なら話者 3・速さ 1・高さ 0・抑揚 1 で埋める)。従来エンジン同士の切替は無変更。
  - `Character.hasVoiceChosen` / キャラ行サブタイトル / おすすめ音声設定(プリセット)も新エンジンに対応。
  - アクセント編集: ボイスクリップの「アクセント編集…」を新エンジンでも出し、
    取得は各エンジンの /audio_query から、再合成はプラグイン経路で行う。
  - 読み辞書: 合成直前に適用する従来の仕組み(`DictionaryVoiceProvider`)がそのまま効く
    (辞書で読みが変わった場合は、従来どおり保存済みアクセントを使わず通常合成に落とす)。

## COEIROINK v2 合成(R3-1、2026-11-19)

### API 形式の確定根拠

v2 の合成は **POST /v1/synthesis への 1 リクエストで完結**し、WAV がそのまま返る
(VOICEVOX 系の audio_query → synthesis の 2 段階ではない)。確定に使った公開情報:

- COEIROINK 2.13.0 の `/openapi.json` と照合済みと明記する実装(kein5/astarot の
  coeiroink_tts.py): POST /v1/synthesis は SynthesisParam を受けて audio/wav を返す、
  スケール類は全て必須、既定値はエンジン UI の既定、話者は「speakerUuid:styleId」で識別。
- coeiro-operator(otolab、COEIROINK 連携の代表的ツール)の audio-synthesizer.ts /
  add-character.ts: 同じエンドポイントへ同じフィールドで POST し WAV を受けている。
- CoeiroClip(led-mirage)、potalk-cli の COEIROINK v2 案内、OpenAPI 生成クライアント
  (vyuma/nemurichat-v2)など、独立した複数実装が同一形式で一致した。
- 併せて確認した関連エンドポイント: GET /v1/engine_info({version, device}。生存確認用。
  v2 に /version は無い)、POST /v1/estimate_prosody、POST /v1/predict(WavMakingParam で
  WAV を返す別経路)、POST /v1/predict_with_duration → POST /v1/process(プロソディ編集
  まで扱う詳細経路)。本実装は 1 リクエストで完結する /v1/synthesis を採用した。

### 合成リクエスト形式(確定)

`POST http://127.0.0.1:50032/v1/synthesis`、Content-Type: application/json、応答は WAV。

| キー | 値 | 備考 |
|---|---|---|
| speakerUuid | 話者の UUID(文字列) | /v1/speakers の speakerUuid |
| styleId | スタイル ID(数値) | /v1/speakers の styles[].styleId |
| text | 読み上げ文 | |
| speedScale | 速さ(既定 1) | 必須 |
| volumeScale | 音量(既定 1) | 必須 |
| pitchScale | 高さ(既定 0) | 必須 |
| intonationScale | 抑揚(既定 1) | 必須 |
| prePhonemeLength | 文頭の無音・秒(既定 0.1) | 必須。v1 系の 0.03 とは異なる |
| postPhonemeLength | 文末の無音・秒(既定 0.1) | 必須 |
| outputSamplingRate | 出力サンプルレート(既定 24000) | 必須 |

- prosodyDetail は省略可能(省略時はエンジン側がプロソディを推定する。上記の公開実装は
  いずれも省略している)。本実装も省略する。
- スタイル ID は話者をまたいで一意(VOICEVOX 系と同じ採番。公開クライアントもスタイル ID
  単独で話者を引いている)ため、話者 UUID はスタイル ID から話者一覧で解決できる。

### 実装(R3-1)

- `CoeiroinkV2Client`(CoeiroinkPlugin.swift、従来は話者一覧のみ)を拡張:
  GET /v1/engine_info(エンジン情報・生存確認)、スタイル ID → 話者 UUID の解決
  (見つからない・複数一致の場合は推測で選ばず日本語の理由で停止)、
  POST /v1/synthesis での合成(UUID 指定 / スタイル ID のみ指定の両方)。
  キャッシュキーの先頭タグは `coeiroink-v2` で v1 経路と分離。
- `CoeiroinkV2Provider`: キャラの話者(数値)をスタイル ID として合成する VoiceProvider。
  速さ・高さ・抑揚・間(pre/post)はキャラの値をそのまま渡す。音量は既定 1。
- `CoeiroinkAutoProvider`: GET /v1/engine_info が応答すれば v2、しなければ従来の
  v1 互換プロバイダへ委譲する自動判定。用意はしたが**アプリの標準配線は切り替えていない**
  (下記「留保」参照)。
- v2 で扱わないもの: 間の倍率(pauseLengthScale。/v1/synthesis に対応項目が無い)、
  アクセント句(VOICEVOX 形式)の取得・差し替え(v2 に相当 API が無い)、エンジン自動起動
  (v1 系と同じくしない)。

## パラメータ対応(VOICEVOX プラグインとの比較)

| 項目 | VOICEVOX プラグイン | COEIROINK(v1) / SHAREVOX |
|---|---|---|
| 話者(数値 ID) | ○ | ○ |
| 話す速さ speedScale | ○ | ○(同じ変換) |
| 高さ pitchScale | ○ | ○ |
| 抑揚 intonationScale | ○ | ○ |
| 音量 volumeScale | ○(キャラに音量項目が無いため既定 1) | ○(同左) |
| 間(pre/post/pause) | ○ | ○(同じ既定値) |
| アクセント句の取得・差し替え | ○ | ○(v1 / SHAREVOX) |
| 読み辞書 | ○ | ○ |
| エンジン自動起動 | ○(同梱バイナリ) | ×(手動起動。理由は上記) |
| 話者一覧 Picker | ○(アプリ共有カタログ) | ×(数値 ID 直接入力。理由は下記) |

## 留保・未達

- **実エンジンでの確認は未実施**。作業時点の Mac には VOICEVOX.app しかなく、
  COEIROINK / SHAREVOX 本体は未導入だった。検証はモックサーバ(URLProtocol)での
  疎通・リクエスト等価性・パラメータ変換まで(テスト参照)。
- **COEIROINK v2 の合成は R3-1 で実装済み**(モック検証まで。実エンジン確認は未実施)。
  ただしアプリの標準配線は従来どおり v1 互換プロバイダのままにしてある。理由:
  エンジン ID(coeiroink)が v1 / v2 で共通で、自動判定に切り替えると v1 経路でも
  判定用の GET /v1/engine_info が 1 回増え、「v1 の経路の挙動を変えない」条件に触れるため。
  自動判定プロバイダ(`CoeiroinkPlugin.makeAutoProvider`)は実装・テスト済みで、
  配線の切替は AppServices の 1 行で済む。切替の可否は統括・ユーザーの判断に委ねる。
  また v2 の話者 UUID はキャラに保存する項目が無いため、プロバイダ経路ではスタイル ID
  から都度解決する(UUID をキャラに保持する設計は未実施)。
- 話者一覧 Picker は未対応: アプリの話者カタログ(`SpeakerCatalog`)は VOICEVOX の接続先
  (プロジェクトの voicevoxUrl)に紐づく単一の仕組みのため、新エンジンでは数値 ID の
  直接入力にした。ID はエンジン起動中に `curl <既定URL>/speakers` で確認できる(下記手順)。
- 接続先 URL は既定値固定(プロジェクト設定の voicevoxUrl は VOICEVOX 専用のため流用しない)。
  変える必要が出たら、プラグイン生成時の引数(`makeProvider(baseURL:)`)は用意してあるので配線だけ足す。

## 実エンジンでの確認手順(未実施・要実施)

1. エンジン本体を入手して起動する。
   - COEIROINK: 公式サイト https://coeiroink.com/ からダウンロード(v1 系を使う場合は v1 を、
     v2 の場合は下記 4. の範囲だけ確認できる)。
   - SHAREVOX: https://www.sharevox.app/ または GitHub の SHAREVOX/sharevox からダウンロード。
2. 疎通確認(ターミナル):
   - `curl http://127.0.0.1:50032/version`(COEIROINK v1)
   - `curl http://127.0.0.1:50025/version`(SHAREVOX)
   - `curl http://127.0.0.1:50032/speakers` / `curl http://127.0.0.1:50025/speakers` で
     話者名とスタイル ID を控える。COEIROINK v2 は `curl http://127.0.0.1:50032/v1/speakers`。
3. MovieCut でキャラの音声エンジンを COEIROINK / SHAREVOX に切り替え、話者 ID に
   手順 2 で控えた ID を入れ、「試しに読み上げる」で声が出ることを確認する。
   話す速さ・高さ・抑揚を変えて作り直し、変化することも確認する。
4. COEIROINK v2 の場合(R3-1 で合成実装済み・実機未確認):
   - `curl http://127.0.0.1:50032/v1/engine_info` で {version, device} が返ること、
     `curl http://127.0.0.1:50032/v1/speakers` で speakerUuid と styleId を控える。
   - `curl -X POST http://127.0.0.1:50032/v1/synthesis -H 'Content-Type: application/json'
     -d '{"speakerUuid":"<控えたUUID>","styleId":0,"text":"テストです","speedScale":1,"volumeScale":1,"pitchScale":0,"intonationScale":1,"prePhonemeLength":0.1,"postPhonemeLength":0.1,"outputSamplingRate":24000}'
     -o /tmp/coeiro-v2-test.wav` で WAV が返り、再生できることを確認する。
   - アプリ配線を自動判定に切り替えた場合は、キャラの音声エンジン COEIROINK で
     話者 ID に styleId を入れて「試しに読み上げる」で声が出ることも確認する。
   - 形式の最終確認は `http://127.0.0.1:50032/docs`(OpenAPI)でも行える。

## テスト

R3-1 で追加: `Tests/MovieCutCoreTests/CoeiroinkV2SynthesisTests.swift`(13 件)。
モックサーバ(FakeCoeiroinkV2Server)は v2 の確定形式に忠実に作り、必須キーが欠けた
合成リクエストには 422 を返して形式崩れを検出できるようにした。内容: 合成リクエストの
キー集合と値・既定値・明示パラメータ・キャッシュヒット、話者一覧→解決→合成の一連、
スタイル ID 不在/曖昧時の停止、エンジン情報と生存確認、HTTP エラー、プロバイダ経路
(実プローブ込み)・未起動時の案内・既定スタイル ID、v1 とのキャッシュ分離、
自動判定プロバイダの v2 経路 / v1 委譲。
全テスト結果(R3-1 時点): Core 2,568 件(新規 13 件を含む)・スキップ 8・失敗 0。
アプリ 860 件は、土台コミット(865b04b)でも同一に失敗する既存の 5 件
(L10nAppTests のシーン作成メニュー英訳、MenuM7Tests のクリップメニュー構成、
MenuTests のプレビュー背景既定値。いずれも R2-3 統合由来)があり、R3-1 の変更による
新規失敗は無い。


`Tests/MovieCutCoreTests/CoeiroinkSharevoxPluginTests.swift`(18 件)と
`Tests/MovieCutTests/CoeiroinkSharevoxAppTests.swift`(1 件、アプリのプラグインホスト登録):
マニフェスト・既定 URL・話者一覧・VOICEVOX プラグインとのリクエスト等価性・
キャッシュ分離・パラメータ変換・プロバイダ経路・未起動時の案内・生存確認・
アクセント取得と差し替え・COEIROINK v2 話者一覧の解釈・ルーティング
(登録時 / 未登録時の従来一致 / 壊れたプラグインの fallback)・遅延読み込み・
エンジン切替・プリセット・読み辞書の適用。
