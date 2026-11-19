# MovieCutVST3Host — VST3 ホスト本体(W6-1)

VST3 プラグインを実際に鳴らすための部品一式。ABI の正は
`docs/vst3-bridge/MovieCutVST3Bridge.h`、到達範囲と判断の記録は
`docs/VST3プラグイン調査と到達範囲.md`(6.6 節)が正。

## 構成

| 置き場 | 内容 |
|---|---|
| `MovieCutVST3Bridge.cpp` | C++ ブリッジ実装。バンドルのロード(dlopen + bundleEntry/ModuleEntry)、クラス列挙、IComponent/IAudioProcessor/IEditController の生成・接続、バス/setup 交渉の適用、process、パラメータ取得/設定、状態チャンク、終了処理 |
| `CMakeLists.txt` | ブリッジを共有ライブラリとしてビルドする(アプリ本体にはリンクしない) |
| `Fixture/MovieCutGain/` | 検証用フィクスチャ(ゲインのみの最小 VST3、GUI 無し)+ 単独 CMake + Info.plist |
| `Tests/smoke_test.py` | ブリッジ ABI だけを使うスモークテスト(ctypes)。実音で往復を検証する |
| Swift 側 | `Sources/MovieCutCore/Plugins/VST3BridgeBackend.swift`(境界)、`VST3NativeBridge.swift`(dlopen + C ABI)、`VST3HostProcessor.swift`(処理器)、`PluginAudioEffect.swift`(プロバイダ)、`AudioDSP.swift`/`AudioMixer.swift`(チェーン接続) |

## 設計の要点

- **安全境界**: アプリはブリッジライブラリを dlopen で探す(環境変数
  `MOVIECUT_VST3_BRIDGE_LIBRARY` → アプリの Frameworks → 実行ファイルの隣 → dlopen 標準探索)。
  無い/版数が違う/プラグインが読み込めない場合は、そのプラグインはバイパスになり、
  音はバイト単位で原音のまま。音声経路が止まることはない。
- **デフォルト不変**: ブリッジを使わない経路(プロバイダを渡さないミックス、
  `AudioFx.isActive`/`hasChain`/`cacheToken`)は従来どおりで、VST3 スロットだけの
  クリップは従来とバイト一致する。実処理はプロバイダを渡した経路でのみ起きる。
- **フラグ変換**: SDK の ParameterInfo.flags は実値が bypass=1<<16 /
  programChange=1<<15 / hidden=1<<4。ブリッジが MovieCut ABI の割当
  (bit4=bypass, bit5=programChange)へ変換してから返す(hidden は readOnly も立てる)。
- **setProcessing の許容**: SDK の AudioEffect 既定実装は setProcessing で
  kNotImplemented を返す(公式サンプルも同様)。ブリッジはこれを失敗扱いしない。
- **検証済み(VM/Linux)**: SDK 3.8.1 相当のヘッダでブリッジとフィクスチャをビルドし、
  smoke_test.py が全項目 PASS(ゲイン 0.75 既定 / 変化点 0.5 / 状態往復で復元 /
  CID 指定生成)。**Mac 実機(macOS バンドル形式・実プラグイン・アプリ経由)は未検証**。
  手順は docs 6.6 節。

## ライセンス

VST3 SDK は 3.8 から MIT ライセンス(Steinberg Media Technologies GmbH)。
SDK 本体はこのリポジトリに同梱しない。ビルド時に `SDK_ROOT` で外から指す。
商標ガイドライン(VST ロゴ等)は SDK 同梱の VST3_Usage_Guidelines に従うこと。
