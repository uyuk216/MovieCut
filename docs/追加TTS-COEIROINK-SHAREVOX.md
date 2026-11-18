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
| COEIROINK v2 | `http://127.0.0.1:50032` | **独自 API**(GET /v1/speakers 等)。VOICEVOX 互換ではない |

- SHAREVOX が VOICEVOX 互換・ポート 50025 であること、COEIROINK v1 が VOICEVOX 互換・
  ポート 50032 であることは、VOICEVOX 系エンジンを横断対応する公開実装
  (voicevox-family-mcp、TTSController)の対応表で確認した。
- COEIROINK v2 は 2023 年の v2 化で独自 UI・独自 API に移行した(Wikipedia の COEIROINK 項で確認)。
  v2 でもローカルサーバはポート 50032 で、話者一覧は GET /v1/speakers
  (話者は UUID 識別、スタイルは数値 ID)であることは COEIROINK 連携ツール
  (coeiro-operator)の案内で確認した。ただし v2 の合成リクエスト形式は公開資料だけでは
  確定できなかったため、**推測で合成を組み立てることはせず、v2 は話者一覧の読み取りのみ対応**とした。

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
- **COEIROINK v2 の合成は未対応**(話者一覧の読み取りのみ)。v2 の合成形式が公開資料で
  確定できなかったため。実機で /docs(OpenAPI)を確認できれば追加実装できる。
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
4. COEIROINK v2 の場合: 現状は合成できない(接続できません、ではなく互換 API が無いため
   合成リクエストが失敗する)。`http://127.0.0.1:50032/docs` で v2 の合成エンドポイントの
   形式を確認し、結果をこのドキュメントへ追記してから v2 合成を追加実装する。

## テスト

`Tests/MovieCutCoreTests/CoeiroinkSharevoxPluginTests.swift`(18 件)と
`Tests/MovieCutTests/CoeiroinkSharevoxAppTests.swift`(1 件、アプリのプラグインホスト登録):
マニフェスト・既定 URL・話者一覧・VOICEVOX プラグインとのリクエスト等価性・
キャッシュ分離・パラメータ変換・プロバイダ経路・未起動時の案内・生存確認・
アクセント取得と差し替え・COEIROINK v2 話者一覧の解釈・ルーティング
(登録時 / 未登録時の従来一致 / 壊れたプラグインの fallback)・遅延読み込み・
エンジン切替・プリセット・読み辞書の適用。
