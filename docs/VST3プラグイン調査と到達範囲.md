# VST3 プラグイン調査と到達範囲(W3-07 / YMM4 監査 #67)

- 対象: バッチ U(W3-07 VST3 プラグイン対応)
- 実装ブランチ: `feat/vst3-feasibility`
- 結論を先に: **今回は「検出(スキャン)+ 境界(プロトコルと保存形式)+ 正直な UI 表示」までを実装し、
  音声処理ホストそのものは未達**とした。理由はライセンスではなく工学と検証の側にある(下記)。
  VST3 を指定したクリップの音は、従来とバイト単位で同じ(バイパスが仕様)。

## 到達範囲の一覧

| 項目 | 状態 | 置き場 |
|---|---|---|
| .vst3 バンドルの検出(標準フォルダ走査) | 実装済み | `VST3Scanner` |
| メタ情報の読み取り(Info.plist / moduleinfo.json / Mach-O 構成) | 実装済み | 同上 |
| プラグイン機構への音声エフェクト種別(`audioEffect` フック) | 実装済み | `PluginManifest` / `PluginHost` |
| 音声処理の境界プロトコル(未ロード時はバイパス) | 実装済み | `PluginAudioEffect.swift` |
| クリップへの VST3 指定の保存(`audioFx.vst3`) | 実装済み | `AudioFx.VST3Slot` |
| パラメータ記述モデルと検証/整形(R5-1) | 実装済み | `VST3Parameter.swift` |
| 処理契約の純粋ロジック(バス/setup交渉・ブロック検証・補償計算)(R5-1) | 実装済み | `VST3ProcessingContract.swift` |
| C++ ブリッジの ABI 定義(R5-1) | 定義済み | `docs/vst3-bridge/MovieCutVST3Bridge.h` / `VST3Bridge.swift` |
| C++ ブリッジの実装(W6-1) | 実装済み(Linux 環境で実音検証済み。Mac 実機では未確認) | `Bridges/MovieCutVST3Host/MovieCutVST3Bridge.cpp` |
| Swift 側バックエンド境界 + ネイティブ接続(W6-1) | 実装済み | `VST3BridgeBackend.swift` / `VST3NativeBridge.swift` / `VST3HostProcessor.swift` |
| チェーン接続(拡張の後・リミッターの前)(W6-1) | 実装済み(プロバイダを渡した経路のみ) | `AudioFxChain` / `AudioMixer.mixdown(vst3Provider:)` |
| 検証用フィクスチャ MovieCutGain(W6-1) | 実装済み(Linux でビルド・検証済み。Mac 未検証) | `Bridges/MovieCutVST3Host/Fixture/MovieCutGain/` |
| パラメータ簡易 UI(W6-1) | 実装済み(控えのある項目のスライダー) | `VST3Panel` |
| 状態チャンクの保存形式(W6-1) | 実装済み(`state` キー、値があるときだけ書く) | `AudioFx.VST3Slot.state` |
| インスペクタでの一覧・追加・削除・状態表示 | 実装済み | `VST3Panel` |
| **実際の音声処理(プラグインを鳴らす)** | **実装済み・Mac 実機検証待ち** | ブリッジ経由の経路のみ。ブリッジが無い環境では従来どおりバイパス(「未達の範囲」節) |
| パラメータ UI(プラグイン純正 GUI / 自動生成) | 部分実装(自動生成側の簡易スライダー。純正 GUI は土台実装済み・実プラグイン目視未確認) | 同上 |
| 純正 GUI の土台(ABI・セッション・App の専用ウィンドウ導線) | 土台実装済み・実プラグイン目視未確認(フェイク/スモークまで) | 6.7 節 |
| プラグイン状態(プリセット/チャンク)の保存と復元 | 保存形式と往復は実装済み(取得はブリッジ経由、Mac 検証待ち) | 同上 |

## 1. MovieCut の現在の音声基盤(調査結果)

- ミックスは **オフライン・決定的** が前提。`AudioMixer.mixdown` が 48 kHz ステレオ Float32 を
  10 秒塊で読み、`AudioFxChain`(純粋な Swift DSP。乱数なし)がクリップごとに
  ノイズ除去 → ゲート → EQ → コンプレッサー → リバーブ → ディレイ → 拡張エフェクト → リミッター
  の固定順で処理する。プレビュー・書き出し・試聴・ラウドネス測定はすべて同じミックスを通る。
  → VST3 を入れるなら、このチェーンの 1 段として「オフラインでブロック処理する部品」にするのが
  自然で、リアルタイム再生の設計(オーディオスレッドの締切・無割り当て)は **不要** な分だけ楽。
  逆に、決定的であること(同じ入力 → 同じ出力)が内蔵 DSP の不文律で、プラグインは一般に
  状態を持ち決定的とは限らない。その差は「書き出しの再現性」の注記として残る。
- プラグイン機構(W2-13)は `PluginHost` / `PluginManifest` / `PluginDiscovery` で、
  フックは音声合成(voice)・映像エフェクト(effect)・書き出し(exporter)の 3 種だった。
  本体の動的ロードは意図的に行っていない(ローダはプロトコルの裏側に閉じ込め、
  今は組み込みプラグインだけ)。署名・公証・配布形式が未確定なため、という判断が
  `PluginLoader` のコメントに明記されている。VST3 はこの判断の延長線上にある。
- 配布前提: **App Store 外配布・SwiftPM ビルド**(Package.swift は Swift のみ、C++ ターゲットなし)。
  配布版の署名・ノータライズも未実施(ROADMAP の「守ること」参照)。同梱素材・外部ライブラリは
  使わない方針(ROADMAP 冒頭)。

## 2. VST3 ホスティングに必要なもの(技術要素)

VST3 プラグイン(.vst3 バンドル = Mach-O バイナリ)を鳴らすには、最低限:

1. **VST3 SDK(C++)の組み込み**: バンドルを `dlopen` し、`GetPluginFactory` から
   `IPluginFactory` を得て、クラス CID で `IAudioProcessor`(音の処理)と
   `IComponent` / `IEditController`(パラメータと状態)を作る。インターフェースは COM 風の
   C++ で、Swift からは直接呼べない。**C++ ブリッジモジュール + SwiftPM の C++ ターゲット追加**
   が必要(Package.swift の変更、ビルド時間と保守の増加)。
2. **処理の接続**: `setupProcessing`(サンプルレート/ブロック長/入出力バス構成)→
   `setActive` → ブロックごとに `process`(入力/出力バッファ、パラメータ変化点、処理コンテキスト)。
   MovieCut はオフラインなので締切は緩いが、レイテンシ報告(`getLatencySamples`)の補償、
   テール(リバーブ等の余韻)の扱い、ステレオ以外のバス構成への対応が要る。
3. **パラメータと状態**: パラメータ一覧の取得・正規化値の往復、状態チャンク
   (`getState`/`setState` のバイナリ)のプロジェクトへの保存。純正 GUI(`IPlugView`)は
   NSView を返す別窓方式で、インスペクタへの埋め込みとは相性が悪い。自動生成 UI なら
   パラメータ定義から組み立てられるが、数百パラメータ級のプラグインでは実用設計が要る。
4. **堅牢性**: 第三者バイナリはクラッシュ・ハング・メモリ破壊があり得る。インプロセスだと
   アプリごと落ちる。DAW の多くはこのために外部プロセス分離(プラグインホストプロセス)を採る。

## 3. ライセンス(2025 年に状況が変わった)

- VST3 SDK は長く **Steinberg 独自ライセンス(書面契約)か GPLv3 の二択** で、
  独自ライセンスでは SDK の再配布が禁止され、GPLv3 ではアプリ側のソース公開が必要だった。
  MovieCut の配布形態では **どちらも同梱に適さず**、これが従来「VST3 は対象外」とされてきた
  理由の 1 つ(出典: Steinberg VST 3 Developer Portal の Licensing ページ、SDK の LICENSE.txt)。
- **2025 年 10 月、SDK 3.8.0 から MIT ライセンスに変更** された(同 Portal の
  「VST 3 License」ページ: "Since version 3.8, VST 3 is licensed under MIT license"、
  GPLv3 と独自ライセンスは新規には選べない)。MIT なら著作権表示とライセンス文の同梱で
  商用・クローズドでも利用でき、**ライセンスはもはや障壁ではない**。
- ただし本バッチでは SDK を **取得・同梱していない**。理由は次の節の工学側の判断で、
  取得手順は「次にやるなら」に書く。VST の商標・利用ガイドライン(SDK 同梱)は別途従う必要がある。

## 4. macOS 固有の制約(App Store 外配布・SwiftPM ビルド前提)

- **ライブラリ検証**: 公証済み(Hardened Runtime)アプリは、原則として自社 Team ID か Apple の
  署名コードしか読み込めない。第三者の .vst3 を読むには
  `com.apple.security.cs.disable-library-validation` エンタイトルメントが必要で、
  これはセキュリティ姿勢を下げる配布判断(利用者の判断が要る)。現状の MovieCut は
  署名・公証自体が未実施なので、この判断は「配布を整える工程」とセットになる。
- **プラグイン側の署名ばらつき**: 無料プラグイン等には未署名・公証なしのものも多く、
  読み込み可否はプラグインごとに変わる。スキャン段階では署名の検証まで行っていない
  (検出とメタ情報のみ。`codesign` 検証は将来の拡張点)。
- **アーキテクチャ**: Apple Silicon では arm64(または arm64e)ビルドが必要。Intel 専用
  プラグインは Rosetta の外では動かない。スキャンでは Mach-O ヘッダから構成を読んで
  「この Mac 向けのビルドなし」を表示できるようにした。
- **サンドボックス**: 現行の MovieCut はサンドボックス無し。将来サンドボックス化する場合は
  プラグイン読み込みにさらに制約が増える(この項目の判断には含めていない)。

## 5. 選択肢の比較と、採用しなかった案

| 案 | 内容 | 判断 |
|---|---|---|
| A. インプロセス C++ ホスト | SDK を組み込みアプリ内で直接ホスト | 将来の本命。ただし C++ ブリッジ・状態保存・GUI・堅牢性まで含めると本バッチの規模を超える。検証用の実プラグインもこの Mac に無い(下記)ため、作っても正しさを確認できない |
| B. 外部プロセス分離ホスト | 専用ヘルパープロセスでプラグインを読み、オフライン処理だけ IPC で渡す | 堅牢性とライブラリ検証の切り分けで最も筋が良い。MovieCut はオフライン処理なので IPC のコピー費用も許容範囲。ただしヘルパー自体が新規アプリ開発で、A と同等以上に大きい |
| C. AU(Audio Unit)経由 | OS 標準の AU を `AVAudioUnit` 等でホスト。追加 SDK 不要 | 多くの市販プラグインは AU 版も出すが、VST3 専用は見えない(= #67 の要求を満たさない)。さらに AVAudioUnit はリアルタイムグラフ前提で、決定的オフライン・ミックスへの組み込みは状態管理が難しい。将来「AU 対応」として別項目で検討する価値はある |
| D. JUCE 等のフレームワーク導入 | ホスト実装をフレームワークに任せる | 巨大な外部依存 + 独自ライセンス/GPL の検討が必要で、ROADMAP の「外部ライブラリは使わない」方針に反する。不採用 |
| E. 検出 + 境界のみ(今回) | スキャン、保存形式、解決プロトコル、バイパス仕様、UI の正直な表示まで | **採用**。A/B のどちらに進んでも土台がそのまま使え、誤解のない形で「ここまで」を製品に残せる |

## 6. 今回実装したもの(詳細)

- **`VST3Scanner`(Core)**: `/Library/Audio/Plug-Ins/VST3` と
  `~/Library/Audio/Plug-Ins/VST3` の直下の `.vst3` を走査。読むのは Info.plist、
  moduleinfo.json、実行ファイル先頭の Mach-O ヘッダだけ。**バイナリはロードしない**。
  壊れたバンドルは失敗にせず `issues` 付きで返し、他の検出を止めない。
- **音声エフェクト種別(W2-13 拡張)**: `PluginHook.audioEffect` と
  マニフェストの `audioEffectIDs` を追加(旧マニフェストは空として読む = 互換)。
  `PluginHost.audioEffectProvider(forAudioEffectID:)` 等の解決は映像版と同形。
- **境界プロトコル**: `AudioEffectProviding`(記述子 + 処理器の生成)と
  `AudioEffectProcessing`(ブロック処理)。未ロード・未対応の受け皿として
  `BypassAudioEffectProcessor`(バッファに触らない = バイト単位で原音)を用意し、
  バイパスしたフレーム数を数えて検証できるようにした。
  到達状態は `VST3HostAvailability` に一元化し、UI 文言もここから取る。
- **保存形式**: `AudioFx` に任意キー `vst3`(スロット配列: バンドル ID・名前の控え・
  有効フラグ・パラメータ控え)を追加。スロットが無ければ従来と完全一致。
  スロットがあっても音には一切効かせない(`isActive` / `hasChain` / `cacheToken` に
  含めない)ことで、**「指定したのに勝手に音が変わる/変わったように見える」を防ぐ**。
  将来ホストを接続する位置は「拡張エフェクトの後・リミッターの前」と決めてコードに明記した。
- **UI**: インスペクタ「音声」に「VST3 プラグイン(検出のみ)」節を追加。
  先頭に未対応である旨を常時表示し、検出結果の一覧、スロットごとの
  検出済み/未検出・アーキテクチャ不適合の表示、追加・削除・有効切替(1 操作 = 1 Undo)ができる。
- **テスト**: `VST3Tests`(Core 16 件: スキャンのフィクスチャ検証、Mach-O 解釈、保存往復、
  未知キー保持、編集、バイパスのバイト一致、ミックス経由のバイト一致、ホスト解決)と
  `VST3AppTests`(App 3 件: Undo 歩数、パネル生成、到達状態の文言)。

## 6.5 R5-1 で前進させた範囲(単体テスト可能な範囲のみ)

2026-11-19、ブランチ `feat/vst3-next`で、
「次にやるなら」のうち **実プラグイン無しで単体テストで検証できる部分だけ** を前進させた。
範囲の判断理由: 実ホスト本体は、この Mac に検証用プラグインが 1 つも無い以上、
作っても正しさを確認できない(従来の線引きと同じ)。一方で、ホストが将来必要とする
「情報の形・交渉の規則・境界の番号」は今のうちに純粋ロジックとして固定でき、
実ホストを書くときに判断がブレない。逆に検証不能な部分(実ロード・実音声処理・
パラメータの実取得)には手を出していない。到達状態(`VST3HostAvailability`)は
未実装のままで、未ロード時バイパス=音がバイト単位で変わらない性質も従来どおり。

- **パラメータ記述モデル**(`VST3Parameter.swift`): `IEditController` が返す
  パラメータ情報の MovieCut 側モデル(ID/名称/単位/stepCount/既定値/フラグ)。
  正規化値(0...1)の整形(範囲丸め・離散段スナップ・非有限は既定値)、線形範囲を
  持つものだけ plain(表示値)との往復、一覧の検証(重複 ID・不正な既定値等)、
  自動生成 UI の入力である `EffectParamSpec` への変換(読専・バイパスは除外)。
  スロットの `params` 控えを記述に照らして整形/診断する関数も用意した
  (記述が無い=未検出のときは従来どおり保持する約束は維持)。
  `VST3EffectProvider` はパラメータ記述を受け取れるようになり(任意・既定は空)、
  記述子の `params` に反映される。ただし処理器は相変わらずバイパス。
- **処理契約の純粋ロジック**(`VST3ProcessingContract.swift`): スピーカー配置と
  バス構成の交渉(完全一致のみ受理し、黙った変換はしない)、setup の交渉
  (48 kHz 固定・ブロック長はプラグイン上限へ小さい方に寄せる)、1 ブロックの
  形状検証(フレーム上限・チャンネル一致・パラメータ変化点の範囲と昇順)、
  ブロック分割計画、レイテンシ/テールの補償計算(先頭トリム量・末尾の無音足し・
  補償後の長さ=入力長)。音声バッファには一切触らない。
- **C++ ブリッジの ABI 定義**(`docs/vst3-bridge/MovieCutVST3Bridge.h` と
  `VST3Bridge.swift`): 版数、操作コード(opcode 0〜9)、結果コード、setup/
  パラメータ/変化点の構造体、関数宣言だけを置いた。Swift 側には同じ番号の
  列挙と、呼び出し順序の状態機械(setup 前の process 等を弾く規則)、
  実ホスト前提チェック(`VST3HostPrerequisites`: SDK 取得・ブリッジ組込・
  フィクスチャ・配布判断の 4 点が揃うまで未達)を置き、テストで固定した。
  **ヘッダは宣言のみで、Package.swift には何も足していない**(C++ ターゲットなし)。
- **テスト**: `VST3NextTests`(Core 15 件)を追加。上記モデルの整形・交渉・検証・
  補償・順序契約と、「前提が揃っていない間は到達状態が未実装のまま」を確認。
  既存の VST3 テスト(ミックス経由のバイト一致を含む)も従来どおり通る。

## 6.6 W6-1 で実装した範囲(ホスト本体)

2026-11-20、ブランチ `feat/vst3-host`で、
「次にやるなら」の 1〜3 を実装した。作業は Linux 環境のみで行い、Mac 実機では未確認。
VST3 SDK は GitHub の steinbergmedia/vst3sdk 3.8.1 相当(pluginterfaces / base /
public.sdk の各リポジトリ)を Linux 環境に clone して参照した(SDK は MIT)。

- **C++ ブリッジ実装**(`Bridges/MovieCutVST3Host/MovieCutVST3Bridge.cpp`、CMake 同梱):
  ABI ヘッダの全関数 + 追加関数(クラス列挙・パラメータ現在値・レイテンシ/テール)。
  ロードは自前 dlopen(macOS は Contents/MacOS の実行ファイル + bundleEntry/bundleExit、
  Linux は .so + ModuleEntry/ModuleExit)。IComponent と IEditController は
  同一オブジェクト/別クラスの両対応で、IConnectionPoint で接続し、状態も同期する。
  バスはメイン 1 組を要求どおりに確定し、プラグインが別構成へ化けたら RESULT_FALSE
  (黙った変換はしない)。補助バスは無音入力/捨て出力で満たす。ProcessContext
  (サンプルレート・再生位置・テンポ)も渡す。SDK の ParameterInfo.flags の実値
  (bypass=1<<16 等)は ABI の割当へ変換する。setProcessing の kNotImplemented は
  SDK 既定実装の正常応答として許容する。
- **Swift 側**: バックエンド境界 `VST3BridgeBackend` と、dlopen で C ABI を直接呼ぶ
  `VST3NativeBridgeBackend`(構造体はバイトバッファ + オフセットで読み書きし、
  レイアウトは C++ 側 static_assert と Swift 側 `VST3CABI` 定数で二重に固定)。
  処理器 `VST3HostProcessor` は `VST3BridgeSession` の順序契約どおりに接続し、
  失敗したらその場でバイパス化する。出力は作業バッファ経由で、成功したときだけ
  入力へ戻す。`VST3EffectProvider.makeProcessor` はブリッジが使える環境
  (`VST3HostAvailability.bridgeAvailable`)でのみ実処理器を返し、それ以外は従来どおり
  バイパス処理器を返す。到達状態の `current` は実行時のブリッジ有無で決まる。
- **チェーン接続**: `AudioFxChain` に VST3 段(拡張エフェクトの後・リミッターの前)を追加。
  `AudioMixer.mixdown(..., vst3Provider:)` を渡したときだけ、VST3 スロットだけの
  クリップも処理対象になる。**プロバイダを渡さない既定経路は従来とバイト一致**で、
  `AudioFx.isActive` / `hasChain` / `cacheToken` も従来どおり(含めない)。
  アプリ本体の再生/書き出し経路へのプロバイダ受け渡しは Mac 検証とセットで次段にする
  (現状はテストと明示呼び出しからのみ実処理が起きる)。将来キャッシュ鍵へ足す材料として
  `AudioFx.vst3CacheToken` を用意した。
- **保存形式**: スロットに `state`(Base64 の状態チャンク)を追加。値があるときだけ書き、
  未知キー保持・未使用時のバイト一致は従来どおり。パラメータ/状態の編集 API
  (`setVST3SlotParam` / `removeVST3SlotParam` / `setVST3SlotState`)も追加。
- **UI**: パネル題をブリッジ有無で切替。スロットのパラメータ控えを正規化スライダーで
  操作できる(ドラッグ = 1 Undo)。状態データの有無も表示する。新規文言は L10nTable に
  日英 4 件追加(重複なし)。
- **フィクスチャ**: `Fixture/MovieCutGain`(SingleComponentEffect 継承、ゲイン id=0 /
  バイパス id=1 / Vu id=2、状態はゲイン+バイパスの往復)。SDK のビルドシステムに
  依存しない単独 CMake で .vst3 バンドルを組み立てる。
- **Linux 環境での実検証(2026-11-20)**: ブリッジとフィクスチャを Linux でビルドし、
  `Bridges/MovieCutVST3Host/Tests/smoke_test.py`(ctypes で ABI のみ使用)が **全項目 PASS**:
  handshake / open / クラス列挙(CID 取得)/ create(CID 指定も)/ パラメータ 3 件取得 /
  setup / active / process(既定ゲイン 0.75 で 0.5→0.375、変化点 0.5 で →0.25)/
  状態取得→別インスタンスへ復元して同じゲイン / dispose。
- **テスト**: Swift 側に Core 19 件(`VST3HostTests`: フェイクバックエンドでの接続・
  ブロック分割・パラメータ往復・状態往復・途中失敗時のバイパス切替・チェーン順序・
  ミックス経由のゲイン・探索順・ABI 定数・スロット編集)と App 2 件(パラメータ編集の
  Undo 歩数・パネル生成)を追加。**Swift テストは Linux 環境で実行できないため未実行**(Mac で実行する)。

### Mac で統括が行う検証手順(実機検証待ちの範囲)

1. SDK 取得: Mac の `(ローカルの作業フォルダ)` にある SDK 一式のルートを確認
   (無ければ `git clone --recursive https://github.com/steinbergmedia/vst3sdk`、3.8 以降、MIT)。
2. ブリッジビルド: `cmake -S Bridges/MovieCutVST3Host -B /tmp/vst3bridge-build -DSDK_ROOT=<SDKルート> -DCMAKE_BUILD_TYPE=Release && cmake --build /tmp/vst3bridge-build`
   → `libMovieCutVST3Bridge.dylib` ができること、static_assert が通ること。
3. フィクスチャビルド: 同様に `Fixture/MovieCutGain` をビルドし、出てきた
   `MovieCutGain.vst3` を `~/Library/Audio/Plug-Ins/VST3/` へ置く。
4. スモーク: `python3 Bridges/MovieCutVST3Host/Tests/smoke_test.py /tmp/vst3bridge-build/libMovieCutVST3Bridge.dylib ~/Library/Audio/Plug-Ins/VST3/MovieCutGain.vst3`
   が ALL PASS になること(macOS バンドル形式でのロード確認)。
5. Swift テスト: `swift test --filter VST3` を直列で実行(既存 34 件 + 新規 21 件)。
   注意: テスト実行環境にブリッジを置かないこと(探索候補に `/usr/local/lib` は入れていないが、
   環境変数 `MOVIECUT_VST3_BRIDGE_LIBRARY` や xctest の実行ファイル隣に置くと
   到達状態が変わり、既存の「検出のみ」を固定したテストが落ちる)。
6. アプリ経由: 環境変数 `MOVIECUT_VST3_BRIDGE_LIBRARY=<2 の dylib>` を付けてアプリを起動し、
   クリップに MovieCutGain を追加 → パラメータ 0 を 0.5 にして書き出し、音量が半分になること。
   実プラグイン(手持ちの市販/フリー VST3)でもロード可否と音を確認する。
   確認できたら、再生/書き出し経路(`PlaybackController` / `RenderAssets`)へ
   `vst3Provider` を渡す配線と、`cacheToken` への `vst3CacheToken` 組み込みを次段で行う。
7. 配布判断: ブリッジをアプリの Frameworks へ同梱するか、公証と
   `disable-library-validation` の要否(従来どおり未決)。

## 6.7 R5 キュー3 で実装した範囲(VST3 純正 GUI の土台)

- **ブリッジ ABI の末尾追加**(既存 0〜9 / status 0〜6 は不変): opcode 10〜14
  (createEditorView / getEditorSize / setEditorSize / destroyEditorView / setEditorResizeCallback)、
  status 7 = `noEditor`(エディタを持たないプラグイン専用)、構造体 `MCVST3EditorSize`(8 バイト)、
  リサイズコールバック型(1 = 受理 / 0 = 拒否。未登録なら `resizeView` は kResultFalse)。
  C++ 実装は macOS のみ(NSView 親)。それ以外は 5 関数とも NOT_IMPLEMENTED で、Linux スモークは従来どおり。
  Swift 側のエディタ系シンボルは任意解決で、旧ブリッジでも読み込みは成功しエディタ操作だけ未実装になる。
- **セッション契約**(`VST3EditorSession`): open は handshake → openBundle → createProcessor →
  リサイズコールバック登録 → createEditorView → getEditorSize。close は destroyEditorView → dispose。
  失敗時は作った分を逆順に全部畳む。エディタ無しは `.noEditor` として一般失敗と区別。
  resize は view 生成後のみ可で、setSize 後に getSize で確定サイズを再取得する(プラグインの丸めに追従)。
  プラグイン発のリサイズ要求は、ハンドラ未設定なら拒否。
  Core は GUI ライブラリを使わず、親/ビューは不透明な UInt64。
- **App 導線**(`VST3Panel`): スロット行の「純正 GUI を開く」(ブリッジが使える環境のみ有効)から
  専用 NSWindow を開く。ウィンドウのリサイズ(ライブリサイズ終了時)はプラグインへ、
  プラグインの要求はウィンドウのコンテンツサイズへ反映。閉じるとセッションを確実に畳む。
  エディタ無し/開けない場合は穏やかな通知を出し、パラメータ一覧などの従来表示は変えない。
- **到達状態の文言**: `VST3HostAvailability.editorUserFacingNote` 等を追加(既存の文言は不変)。
- **検証範囲**: フェイクバックエンドによる単体テスト、ABI 固定テスト、スモークまで。
  フィクスチャ MovieCutGain に最小エディタ(320×200・親 NSView を保持するだけで子ビューは作らない)を足した。
  **Mac 実機検証(2026-11-21、検証クローン)**: ブリッジ/フィクスチャとも CMake ビルド成功、
  既存スモークは **ALL PASS**(エディタ系の macOS 項目含む)、Swift テストは VST3 系 **73 件全 PASS**
  (新規 VST3EditorTests 15 件含む)。さらに親 NSView を実生成する追加スモークで、フィクスチャの
  エディタ生成 → サイズ取得(320×200)→ リサイズ(400×300)→ 破棄まで実地に **PASS**。
  ただしこれは自作フィクスチャでの配線確認であり、**市販等の実プラグインでの表示の目視は未実施**。

## 7. 未達の範囲と理由

- **Mac 実機での音声処理の検証**(W6-1 で更新): ホスト本体・処理接続・状態保存・
  簡易パラメータ UI は実装し、Linux 環境ではフィクスチャで実音検証まで済んだ。
  残るのは Mac 実機での確認(macOS バンドル形式のロード、実プラグイン、アプリ経由の
  書き出し)で、手順は 6.6 節に置いた。検証が済むまでは、アプリ本体の再生/書き出し経路へは
  プロバイダを渡していない(= 既定では音は従来どおり)。SwiftPM への C++ ターゲット追加は
  採らず、ブリッジは独立 CMake + dlopen とした(既存ビルドへの影響をゼロにするため)。
- **プラグイン純正 GUI**(R5 キュー3 で更新): 土台(ビュー生成・サイズ交渉・開閉
  ライフサイクル・App の専用ウィンドウ導線)は実装済み(6.7 節)。残る未達は
  **実プラグインでの表示の目視確認**(macOS 実機でのみ可能。フェイクとスモークまでしか通していない)。
  確認が済むまで、UI の説明文は「土台のみ実装済み・開けない場合がある」と正直に出す。
- **パラメータ UI**(2026-11-21 ドキュメント整合 R6 で現況に合わせて修正):
  パラメータの「控え」を正規化スライダーで操作する簡易 UI は W6-1 で実装済み(6.6 節)。
  純正 GUI は埋め込みではなく専用ウィンドウ方式で土台実装済み(6.7 節。実プラグインでの
  目視は未確認)。未実装なのは、R5-1 の記述モデル(`VST3Parameter` / `EffectParamSpec` 変換)から
  自動生成する UI で、実プラグインから記述を取得して画面へ繋ぐ配線がまだ無い。
- **署名の検証**: スキャンでは `codesign` の検証をしていない(検出 ≠ 安全性の保証。
  UI でもそのような表現はしていない)。
- **AU / VST2**: 対象外(VST2 は SDK 配布終了・ライセンス上も不可)。

## 8. 次にやるなら(手順の置き場)

1. VST3 SDK 3.8 以降を Steinberg の開発者ポータル/GitHub から取得し、MIT ライセンス文を
   `docs/同梱素材のライセンス.md` の流儀で記録してから vendor フォルダへ置く(本バッチでは未取得)。
2. SwiftPM に C++ ブリッジモジュール(例: `MovieCutVST3Host`)を足し,
   `docs/vst3-bridge/MovieCutVST3Bridge.h` の宣言を実装して
   `GetPluginFactory` → クラス列挙 → `IAudioProcessor` のオフライン処理だけを通す。
   交渉・検証は R5-1 の `VST3ProcessingContract` を正とし、ブリッジ側はそれを
   渡された結果に従うだけにする。最初の検証には、SDK 同梱のサンプルプラグイン
   (または自作の最小プラグイン)をフィクスチャとして使う。
3. `VST3EffectProvider.makeProcessor` の中身を実ホストの処理器に差し替え,
   `AudioFxChain` の「拡張エフェクトの後・リミッターの前」に接続する。
   その時点で初めて `AudioFx.hasChain` / `cacheToken` にスロットを含め、
   `VST3HostPrerequisites` の 4 点が揃ったことを確認してから到達状態を切り替える。
4. 配布判断: 公証工程とセットで `disable-library-validation` の要否を決める。
   外部プロセス分離(案 B)にするなら、この判断はヘルパー側だけに閉じ込められる。
5. 状態チャンクの保存先(プロジェクト内のバイナリ置き場)を設計する。パラメータ自動生成 UI は
   R5-1 の記述モデル(`EffectParamSpec` 変換)を使うので、残るは実取得と画面への接続だけ。

### 8.1 W6-1 での進み具合(上の手順との対応)

- 手順 1: SDK は vendor 同梱せず、ビルド時に `SDK_ROOT` で外から指す方式にした
  (ライセンス記録は `Bridges/MovieCutVST3Host/README.md`)。取得自体は Mac 側の検証手順に残る。
- 手順 2: SwiftPM への C++ ターゲット追加は採らず、独立 CMake + dlopen に変更
  (理由は 6.6 節)。オフライン処理・交渉・検証の接続まで実装済み。
- 手順 3: `makeProcessor` の差し替えとチェーン接続は実装済み。ただし
  `hasChain` / `cacheToken` への組み込みと、アプリ本体の再生/書き出し経路への
  プロバイダ受け渡しは Mac 実機検証とセットで次段(6.6 節の判断メモ参照)。
- 手順 4(配布判断・公証)と 5(状態チャンクの置き場設計: 現状はスロットの
  `state` に Base64 で内包する方式を実装済み。バイナリ置き場への分離は未検討)は残り。
