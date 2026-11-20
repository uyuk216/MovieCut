# テストスイート衛生監査(ラウンド6 キュー2)

- 対象: `Tests/MovieCutCoreTests`(Core)・`Tests/MovieCutTests`(App)。ブランチ `audit/test-suite-hygiene`、起点 3f3b10d。
- 方法: grep による静的スイープ+コード読解。**Linux VM のためテストは実行していない**(干渉シナリオはコード読解で特定。実行での再現・確認は Mac 側で行う)。
- 制約の遵守: Sources/ は変更していない。内蔵音声合成(VOICEVOX/AquesTalk)まわりも触っていない。アサーションの削除・緩和はしていない。

## 結論(要約)

| 観点 | 候補(ヒット行) | 具体的な干渉あり | 修正 | 見送り |
|---|---|---|---|---|
| 1. UserDefaults / AppStorage | 35 + suite 24 + 本番ストア経由の書き込み約 60 | 1 | 1 | 他は退避・復元済み |
| 2. 一時ファイル | 229 行 / 193 ファイル | 0 | 0 | 衝突なし |
| 3. シングルトン/静的状態 | `.shared` 21 行・本番 static 約 40 | 0(1 件は本番側の疑い) | 0 | 数件 |
| 4. 時刻・順序・タイミング | Date() 78・sleep 系 55・wait/expectation 14 | 1 | 1 | 数件 |
| 5. 外部状態 | URL/http 145・環境変数 18・絶対パス 20 | 0 | 0 | 数件 |

修正は 1 ファイル(`Tests/MovieCutTests/MenuTests.swift`)の 2 テスト。質優先で、干渉相手を特定できたものだけを直した。

---

## 観点1: UserDefaults / AppStorage の残留

### スイープ
- `UserDefaults.standard` 直接参照: 35 行 / 9 ファイル。内訳は、退避・復元ありが 7 ファイル、`AppEditionTests` の識別比較(読み取りのみ)、`InspectorSectionCatalogTests` の「標準 defaults に触れないこと」の確認(読み取りのみ)。
- `UserDefaults(suiteName:)` で専用 suite を使うテスト: 24 ファイル(Core 側の設定系はほぼこの形)。
- `AppStorage`: 4 行 / 1 ファイル(`InspectorSectionDisclosureAppTests`)。`mc.disclosure.*` を全キー退避・復元している。
- `mc.disclosure`: 12 行 / 2 ファイル。Core 側は suite 分離、App 側は退避・復元(問題なし)。
- `previewGuide*` / `previewSnap*`: 20 行 / 4 ファイル。`PreviewGuideAppTests`・`PreviewSnapAppTests` は setUp/tearDown で退避・復元、`PreviewSnapAppTests.testGridGuideToggle…` は `defer` で復元(問題なし)。
- 本番ストアの既定引数は `DataLocations.current.defaults`(personal 版では `.standard`)。このためテストが引数なしで setter を呼ぶと実アプリの設定に届く。そこで、setter を引数なしで呼ぶテストを全件洗った。

### 退避・復元が確認できたもの(修正不要)
`TrimLoopAppTests`、`PreviewTierAppTests`、`PlaybackTests`(PreviewTier)、`UI2Tests`(PreviewBackground)、`PreviewGuideAppTests`、`PreviewSnapAppTests`、`InspectorSectionDisclosureAppTests`、`ProxyAIImageAppTests`・`ProxyWorkflowAppTests`(proxy・autoCreate)、`VoiceRippleAppTests`・`InspectorModelTests`(voiceAutoRipple。2026-11-19 の前例)、`GenerativeMediaAppTests`・`GenerativeMediaAVAppTests`(設定を load → tearDown で save)。
Core 側の `AITests`・`L10nTests`・`SecurityHardeningTests`・`WhisperTranscriptionTests`・`RecentProjectsTests`・`ProxyWorkflowTests`・`ProjectVersionsTests`・`FrameRateAndOutputTests` などは、専用 suite を渡している。

### 修正した(干渉シナリオが具体的)

**F1. `MenuTests.testCustomFpsOpensSheetAndAppliesInOneUndoStep`** — 実アプリの「最近使ったカスタム fps」を書き換え、さらに末尾で消していた
- 干渉相手: 実アプリの `recentCustomFrameRates`(`RecentCustoms.frameRates()` の既定は `DataLocations.current.defaults` = `.standard`)。
- 経路: `m.applyCustomFps(29.97)` → `rememberCustomFps` → `RecentCustoms.frameRates().addRate(29.97)` が標準 defaults に書く。テスト末尾の `RecentCustoms.frameRates().clear()` はキーごと消す。
- 実害: 本人がアプリで入れた最近使ったカスタム fps(最大 3 件)が、テストを走らせるたびに消える。逆方向では、テストの開始時点で履歴が入っていると、履歴を読む `MenuState(model:)` / `recentFps` の状態がテスト実行前の実データに依存する(このテスト自身は先頭で履歴を空にしていなかった)。途中でアサーションが失敗すると末尾の `clear()` に到達せず、`29.97` が本人のメニューに残る。
- 修正: テスト冒頭でキーを退避 → `clear()` で空に → `defer` で元の値を復元(元が無ければ削除)。末尾の無条件 `clear()` は削除(`defer` に置き換え)。検証内容(fps の適用・Undo 1 回・500 fps の拒否)は一切変えていない。
- 備考: 同じ書き込み経路の `rememberCustomResolution`(`RecentCustoms.resolutions()`)を呼ぶテストは無いことを確認した(`applyVideoSize` は履歴に書かない)。

### 見送り
- `GenerativeMedia*AppTests`: 設定を load → tearDown で save する往復復元。元々キーが無かった場合は、空値のキーが残る(値としては空で、挙動の差は無い)。プロセスが途中で落ちると復元されない点は残るが、再現条件が弱いので直さない。API キーの保存先は `SecretStore.shared` で、往復で同値に戻る。
- `MenuTests.testMenuStateFromModelFollowsSelectionAndExport` ほか `MenuState(model:)` を比較するテスト: 実設定を読むが、期待値側も同じ実設定から組み立てているため、値が何であっても結果は変わらない。
- `PreviewSnap/Guide/Tier/BackgroundStore` の `memory`(静的キャッシュ): `DebugHooks.isQuiet`(環境変数 `MC_DEBUG_*` が立っているとき)だけ使われる。通常のテスト実行では `memory` は nil のまま。`MC_DEBUG_*` を立てたままテストを走らせる人がいなければ影響しない。

---

## 観点2: 一時ファイルの衝突

- スイープ: `temporaryDirectory` / `NSTemporaryDirectory()` が 229 行 / 193 ファイル。UUID を含まない行だけを抜き出して 1 件ずつ確認した(複数行に分かれた `appendingPathComponent("…-\(UUID())")` も確認)。
- 結果: **固定名の共用による衝突は見つからなかった。**
  - 固定名に見える箇所は、`AITests`(L191)・`VoiceDictionarySynthesisTests`・`InspectorModelTests`(L68)が `ToneVoiceProvider.synthesize(in: temporaryDirectory)` に渡す例で、出力ファイル名は `tone-<n>-<UUID 6 桁>.wav` なので衝突しない(後片付けはされず /tmp に溜まるだけ)。
  - `OpticalFlowTests` の `tmp` は `opticalflow-tests-<pid>` と pid 付きで、中のファイルは UUID 付き(同一プロセス内の共有のみ。後片付けはされない)。
  - `/tmp/rec`(`ScreenRecordingTests`)・`/tmp/mc-support-test`(`AppEditionTests`)は、パス計算だけで実ファイルを作らない。
- 見送り: `ToneVoiceProvider` の出力や `OpticalFlowTests` の `tmp` が /tmp に溜まる件(衝突ではなく容量の話。実害が小さいので直さない)。
- スナップショット系 13 ファイルは、`MC_SNAPSHOT_OUT_DIR*` が未指定のとき、固定の絶対パス `/private/tmp/claude-501/…/scratchpad/<名前>` に固定名の PNG を書く(`UI2Tests`・`LayoutQASnapshotTests`・`DockAppTests`・`KeyframeAppTests`・`SpeedAppTests`・`TextStyleAppTests`・`TransitionAppTests`・`AudioFxAppTests`・`EffectAppTests`・`TimelineMediaTests`・`OutputSheetSnapshotTests`・`WindowSnapshotTests`・`TachieUIAppTests`)。目視確認用の出力で、読み戻して検証する用途ではない。**同じパスに並列で書く 2 つの実行がない限り衝突しない**ので、見送り(13 ファイルの機械的な書き換えは避けた)。ただし開発者固有のセッションパスが既定値として埋まっている点は、公開に向けて整理する価値がある(下の推奨事項)。

---

## 観点3: シングルトン / グローバル状態

- スイープ: `.shared` が 21 行 / 7 ファイル。`LUTCache.shared`・`ReferenceColorCache.shared`・`TimelineMediaCache.shared`・`SpectrogramCache.shared`・`RenderContextProvider.shared` は、キャッシュや読み取り専用の共有で、状態を書き換える使い方ではない(`TimelineMediaCache.shared.removeAll()` は先頭で空にする方向なので順序に依存しない)。`FaceDetectionCache.shared` は `defer` で復元済み。`FontChoices.userFamilies` も `defer` で復元済み。`L10n.force(nil)` は `tearDown` で復元済み。
- `PanelPresentationGate`: テストは `PanelPresentationGate()` を都度生成し、静的な状態を共有していない(問題なし)。
- ロケール/タイムゾーン/カレンダー: `Locale.current` / `TimeZone.current` / `Calendar.current` の使用は 0 件。`ProjectVersionsTests`・`ScreenRecordingTests`・`WelcomePolicyTests` は固定のタイムゾーンか形だけの確認。

### 本番コード側の疑い(切り分け。Sources/ は変更していない)

**S1. `L10n.current` が実アプリの保存済み言語設定を見る(`Sources/MovieCutCore/L10n.swift` の `current`)**
- 経路: `NSClassFromString("XCTestCase") != nil` かつ `storedOverride() == .system` のときだけ日本語に固定し、保存済みの上書きが `en`/`ja` なら、それ(= 本人の実アプリ設定)に従う。`storedOverride()` の既定引数は `DataLocations.current.defaults`(`.standard`)。
- 干渉シナリオ: 本人が実アプリで言語を英語にしたまま Mac で `swift test` / Xcode のテストを走らせると、`L10n.current` が `.en` になり、日本語のメニュー題・ステータス文言を比較する多数の App/Core テスト(`AppMenuSpec` の題など)が、実行順に関係なく一斉に落ちる可能性がある。公開版(別ドメイン)の動作確認で言語を切り替える作業をすると起きやすい。
- 扱い: **今回は直していない。** テスト側で全クラスに `L10n.force(.ja)` を入れる方法は、441 ファイルへの機械的な変更になる。直すなら、テスト実行中は保存済み設定を無視する、あるいは XCTest の principal class で `L10n.force(.ja)` を既定にする、といった一括の入口が妥当(統括判断)。
- Mac での確認方法: 実アプリで言語を「English」にした状態で `swift test --filter MenuTests` を実行し、落ちるかを見る。

### 見送り
- `FastBlendTests`(L39–41): `FastBlend.disabled` を `true` → `false` と書き、元の値を復元しない。元の値は環境変数 `MC_NO_FASTBLEND` の有無で決まる。同じプロセスのテストは順次実行で、現状 `MC_NO_FASTBLEND` を立てて走らせる運用がないので、理論上のみ。
- `ActiveDocument.shared`: テストはほぼ `ActiveDocument()` を都度生成している(静的な共有は触っていない)。
- `PreviewBackgroundStore.memory` ほかの静的 `memory`: 観点1の見送りを参照。

---

## 観点4: 時刻・順序・タイミング依存

- スイープ: `Date()` 78 行、`sleep` 系 55 行、`wait(for:)`/`expectation` 14 行 / 7 ファイル。
- 分類:
  - 性能計測の表示用(`CFAbsoluteTimeGetCurrent`、`print` のみで判定に使わないもの): `BokehTests`・`OpticalFlowTests`・`StabilizerTests` ほか多数。判定に使っていないので問題なし。
  - 経過時間の上限を見るもの(`AITests` <10s/<5s、`AIImageTests` <10s、`WhisperTranscriptionTests` <10s、`SecurityHardeningTests` <5/30/60s、`SidecarSchedulingTests` <0.5s): 上限に対して実処理の時間が桁違いに短い(例: `SidecarSchedulingTests` は 1.5 秒の処理を待たずに返ることの確認で、関数呼び出し自体はマイクロ秒)。上限を緩めると検証が弱まるので触らない。Mac が高負荷でも通る余裕がある。
  - `RunLoop.current.run(until:)` 系: スナップショット描画のための固定待ち。判定には使っていない。
  - ポーリング待ち(`for _ in 0..<N where 条件 { sleep }`): `AudioSyncAppTests`・`AutoWhiteBalanceAppTests`・`ExportQueueAppTests`・`TextGenerationAppTests` ほか。上限付きで条件を待つ形で、問題なし。
  - 固定時間を待ってから「起きたこと」を判定するもの: 下記。

### 修正した

**F2. `MenuTests.testActiveDocumentTracksFrontModelState`(L396–)** — 固定 100ms 待ちの後に「反映された」ことを判定していた
- 経路: `ActiveDocument.activate` は `m.objectWillChange` を購読し、`DispatchQueue.main.async { … self?.refresh() }` で状態を更新する(`Sources/MovieCut/ActiveDocument.swift`)。テストは `m.setCodec("hevc")` の後に 100ms スリープして `a.state.codec == "hevc"` を判定していた。
- 不安定になる条件: main キューの周回が 100ms より遅れる高負荷時(Mac で別のビルド・テスト・動画処理が走っているとき)に、反映前の `"h264"` を見て落ちる。実行順ではなく負荷依存。
- 修正: 「100ms の固定待ち」を「反映されるまで 20ms 刻みで最大 2 秒」に置き換え。**判定(`XCTAssertEqual(a.state.codec, "hevc")`)は同じまま**で、待ち時間の上限だけを広げた(「反映される」ことの検証は弱まっていない。反映されなければ従来どおり落ちる)。

### 見送り
- `PlaybackTests.testEditStopsPlaybackAndTriggersRebuild`(L238/L242): 消音編集のあと固定 200ms 待って `b.loaded.count == 2` を判定する。同種の負荷依存はあり得るが、ポーリングに替えると「再構築がちょうど 1 回だけ」という現行の検証(2 回以上作り直す不具合を拾える点)が弱まるため、直していない。待ち対象が `c.preparation` のような明示的な Task なら `await` で決定的にできる可能性があるが、PlaybackController 側の仕様確認が必要で、今回は見送り。
- `AudioSyncAppTests.testWrongSelectionDoesNothing`(L89)・`AutoWhiteBalanceAppTests`(L98)・`ChromaLUTTests`(L248, `Thread.sleep(1.1)`): 「何も起きないこと」を固定時間待って確認する形(偽陽性にはなるが、不安定にはならない)、またはファイルの更新時刻の分解能を超えるための待ち。不安定要因ではないので見送り。
- 並列実行(`swift test --parallel`)で壊れそうなもの: 標準 defaults を共有する App テスト(上記の退避・復元は並列のプロセス間では保護しない)。ただし XCTest の App テストは同一プロセス内で順次実行されるので、現行運用(`swift test` / Xcode)では問題にならない。`--parallel` を使う場合は、実アプリの defaults と別プロセスが同じキーを書き合う可能性があるため、App テストは並列にしないこと。

---

## 観点5: 外部状態依存

- ネットワーク: `URLSession(configuration:)` + `URLProtocol` 差し替えで偽サーバーを使っている(`fake.local` ドメイン)。実ネットワークに出るテストは見つからなかった。`WhisperAccuracyTests` の `huggingface.co` は URL 文字列の確認のみ。
- 実データ依存: `/Users/USER/動画素材/…` や `/Users/USER/Downloads/立ち絵素材.psd` を読むテストが 6 件ある(`CharacterRigTests`・`RigSizeGroupTests`・`RigHairAlignmentTests`・`TachieTests`・`RigPrewarmTests`)。すべて `XCTSkipUnless(fileExists)` で、読み取り専用。パスが `USER` というプレースホルダーのため、通常はスキップされる。本人の素材フォルダが存在する環境で走らせると、素材の中身に依存した結果(部品数 6/45/36 など)になる。見送り(読み取り専用でスキップ付き)。
- 環境変数: `MC_SNAPSHOT_OUT_DIR*`(出力先)、`MC_KITCHEN_SINK_DIR`(未指定なら `XCTSkip`)、`MC_TACHIE_BENCH_DIR`、`MC_DEBUG_DEPS`(`MenuTests` L460 は未設定のときだけ確認)、`MC_LANG`(`L10n`)、`PATH`(`DNxExportTests` が ffprobe を探す)。`MC_LANG` を立てたまま走らせると言語がそれに従う(S1 と同様、テスト実行時は未設定にしておくこと)。
- `~/Library` などユーザー実データ領域への書き込み: テストが `DataLocations.current` の実領域に書く例は無し(`AppEditionTests`・`GenerativeMediaProvidersTests` はパス比較のみ)。`FontLibrary.add`・各 Store はすべて一時ディレクトリを渡している。

---

## 修正コミットの対象

| ファイル | テスト | 内容 |
|---|---|---|
| `Tests/MovieCutTests/MenuTests.swift` | `testCustomFpsOpensSheetAndAppliesInOneUndoStep` | `recentCustomFrameRates` を退避・空にして開始、`defer` で復元(末尾の無条件 `clear()` を置換) |
| `Tests/MovieCutTests/MenuTests.swift` | `testActiveDocumentTracksFrontModelState` | 固定 100ms 待ちを、最大 2 秒のポーリング待ちに置換(判定は同一) |

アサーションの削除・緩和: なし。

## Mac で繰り返し実行すべき対象クラス(統括の検証用)

修正したテストを含むクラス:

```
swift test --filter MenuTests
```

> `MenuTests` の 2 テストを個別に回す場合:
> `swift test --filter MenuTests/testCustomFpsOpensSheetAndAppliesInOneUndoStep`
> `swift test --filter MenuTests/testActiveDocumentTracksFrontModelState`

確認の観点:
1. 実行前に実アプリで「最近使ったカスタム fps」を 1〜2 件入れておき、`MenuTests` を実行しても履歴が変わらないこと(`defaults read jp.local.moviecut recentCustomFrameRates` の前後比較)。
2. 同じクラスを `--repeat`(または数回の連続実行)して通ること。高負荷(別プロセスで動画処理を走らせた状態)でも `ActiveDocument` のテストが通ること。
3. S1 の確認: 実アプリの言語を English にした状態で `swift test --filter MenuTests` を実行し、日本語の題の比較で落ちるかどうかを確認(落ちれば、本番側の方針を決める材料)。

## 今後の推奨(今回は実施せず)
1. **S1(L10n の実設定参照)**: テスト実行中は保存済みの言語設定を無視する一括の入口を用意する(本番コード変更が絡むため統括判断)。
2. スナップショット系 13 ファイルの既定出力先: 開発者固有のセッションパス(`/private/tmp/claude-501/…`)を、`temporaryDirectory` 配下の UUID 付きフォルダか `XCTSkip` に整理する(公開リリースに向けた衛生。出力は目視用で検証に使っていない)。
3. `PlaybackTests` の固定待ち 2 か所: `PlaybackController.preparation` を `await` できる形に揃えられるか確認(検証意図を保ったまま決定的にできる可能性)。
