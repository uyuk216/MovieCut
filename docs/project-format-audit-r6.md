# プロジェクト形式 仕様書 × 実装 突き合わせ監査(改善ラウンド6 キュー1)

- 監査日: 2026-11-20 / ブランチ: `audit/project-format-spec`(起点 f0d784c)
- 正: **実装**(実際に読み書きされる形式が真実)。仕様書側(`~/workspace/moviecut-specs/`)は本リポジトリ外のため編集していない。更新案は §3 に貼れる文面で置く。
- 実装側の挙動変更: **なし**(テスト追加とこの文書のみ)。
- 判定の分類: **A** = 仕様が古い/間違い(実装が正) / **B** = 仕様に無い実装 / **C** = 実装に無い仕様。
- 件数: **A 15 件 / B 33 件 / C 4 件**、懸念(実バグ候補)**9 件**(§5)。
- 実行検証: この VM には `swift` が無く、テストは**未実行**(括弧の釣り合いと型・API の目視確認のみ)。実行は統括側の Mac で。
- 未監査(本件の範囲外): 仕様 F-02(同期フォルダに特殊ファイルを作らない)・R-02/R-07(再リンク結果の一覧 UI・サムネイル付き不足素材一覧。`MissingMedia` を使う UI は `Sources/MovieCut/` にあるが画面の中身は見ていない)・§7 Y-01/Y-02。

---

## 1. 突き合わせ表

行 ID は `X-nn`。根拠は `ファイル:行`(行は f0d784c 時点)。判定は「一致」または A/B/C(§2 の ID)。

### 1.1 形式の基本形・保存

| ID | 仕様の記述 | 実装の実態(根拠) | 判定 |
|---|---|---|---|
| X-01 | F-01: プロジェクトは**フォルダ形式**、1 プロジェクト = 1 フォルダ | 通常保存は**単一の JSON ファイル**(`.mcpjc`)。`Project.save(to:)` は `encoded().write(to:, options: .atomic)`(`ProjectIO.swift:24`)。アプリは SwiftUI `FileDocument` で `FileWrapper(regularFileWithContents:)` を返す(`MovieCut/ProjectDocument.swift:71`)。フォルダになるのは「パッケージとして保存…」のときだけ(`<書類名> パッケージ/` に `<name>.mcpjc` と `media/`。`MediaPackage.swift:65-79`、`MovieCut/ProjectModel+Media.swift:111-141`) | A-01 |
| X-02 | §1 末尾: フォルダ内部のファイル名・レイアウトは未決定 | パッケージの中身は確定: `<name>.mcpjc` + `media/<素材>`(`MediaPackage.swift:41,76`)。それ以外のサブフォルダ・付属ファイルは無い | A-02 |
| X-03 | F-03: 保存はアトミック(一時ファイル→差し替え) | `Project.save` は `.atomic`(`ProjectIO.swift:25`)。世代バックアップも `.atomic`(`ProjectVersions.swift:158`)。アプリの保存は NSDocument の保存経路(OS 側の安全な保存)。パッケージの素材コピーは非アトミック(`MediaPackage.swift:69-74`、§5 N-9) | 一致(パッケージ素材のコピーを除く) |
| X-04 | F-04: クラウド退避ファイルの事前チェック・同時編集のロック目印 | `ubiquit` / `iCloud` / ロックファイルに関するコードは `Sources/` に見当たらない | C-01 |
| X-05 | 「プロジェクト本体」「キャラ定義・音声設定を内包」「素材参照情報」「プロキシ(資産)」「素材実体(任意)」の論理構成 | 本体・キャラ定義(`characters`)・素材参照(`src` / `mediaPool` / `mediaHints` / `mediaFingerprints` / `proxyLinks`)は同一 JSON に入る。プロキシは入らない(X-30)。素材実体はパッケージ時のみ `media/` | 一致(プロキシ以外)/ A-09 |
| X-06 | (記述なし)JSON のエンコード設定 | `sortedKeys`・`prettyPrinted`・`withoutEscapingSlashes`(`ProjectIO.swift:14-18`)。エンコーダ・デコーダとも `JSONEncoder`/`JSONDecoder` の標準(日付・Data 戦略なし。時刻は秒の Double) | B-22 |
| X-07 | (記述なし)読み込み時の上限と安全策 | 最大 64MiB(`InputLimits.swift:6`)、JSON 入れ子 64 超は拒否(`:17`、`jsonDepthWithinLimit`)、トラック 2,000・クリップ 100,000 超は拒否(`:18-19`)、通常ファイル以外・サイズ超過は `readFile` で拒否(`:34`)。`sanitizeLoaded` が常識外れの数値だけクランプ(`:86-`。幅高さ 1〜16384、秒 ±360,000、位置 ±1e5 など。正常値は不変) | B-25 |
| X-08 | (記述なし)世代バックアップ | `ProjectVersions`(アプリ側 `DataLocations` 配下に保存のたび世代を残す。既定の最小間隔・保持数あり)。形式そのものではなくプロジェクトファイル自体は触らない(`ProjectVersionsTests.testRecordNeverReadsOrWritesTheUserFile`) | B-24 |

### 1.2 拡張子

| ID | 仕様の記述 | 実装の実態(根拠) | 判定 |
|---|---|---|---|
| X-10 | E-01: 拡張子は実装内の**1 箇所の定数**。「現行実装は `ProjectFileExtension.swift` の定数 1 箇所」。ソース検索でリテラルが定数定義の 1 箇所以外に現れない | 定数: `ProjectFileExtension.current = "mcpjc"`(`ProjectFileExtension.swift:9`)。**他にも**: `ProjectTemplate.fileExtension = "mcpjc"`(`ProjectTemplate.swift:8`、別定数)、`MediaPackage.write` が `"\(projectName).mcpjc"` とリテラル(`MediaPackage.swift:76`)、`ProjectDocument` の UTType 宣言(`ProjectDocument.swift:6-10,20-21`)、`Scripts/make-app.sh:163,175`(Info.plist の拡張子宣言)。`ProjectFileExtension.current` を使っているのは `MovieCutIntents.swift:47`・`AutomationExport.swift:155`・`YmmpImport.swift:165` のみ | A-03(+懸念 N-8) |
| X-11 | E-02: 書き込みの拡張子は `mcpjc` | 一致(`ProjectFileExtension.swift:9`、`ProjectDocument.swift:21` `writableContentTypes = [.mcpjc]`) | 一致 |
| X-12 | E-03: 読み込み互換として `ymproj` を受け付ける | `readable = [current, "ymproj"]`(`ProjectFileExtension.swift:12`)、`readableContentTypes = [.mcpjc, .ymproj]`。補足: 旧形式を開いた書類は**拡張子を変えず `.ymproj` へ書き戻す**(`ProjectDocument.swift:15-16`)。世代バックアップも元の拡張子を保つ(`ProjectVersionsTests.testYmprojExtensionIsKept`) | 一致 / B-33 |
| X-13 | E-04: 正式拡張子は未決定、決定時は定数 1 行で移行できる | 定数 1 行では**移行できない**(X-10 のリテラル・UTType・plist)。ただし未決定という記述自体は現状どおり | 一致(「1 行で」は成立せず → A-03 / N-8) |

### 1.3 formatVersion と移行

| ID | 仕様の記述 | 実装の実態(根拠) | 判定 |
|---|---|---|---|
| X-20 | (記述なし)`formatVersion` | 無ければ 0、`ProjectFormat.current = 2`(`ProjectFormat.swift:12`)。書くときは `max(読んだ版, current)`(`Project.swift:136`)。`current` より新しい版も開く(読めた分だけ読み、未知キーは `extra`)。`sourceFormat` は `==` に入らない(`ProjectFormat.swift:41-45`) | B-01 |
| X-21 | (記述なし)版の厳密判定 | `version(in:)`: 最上位が JSON オブジェクトで `formatVersion` が数値(Bool 除く)・有限・0 以上・1e9 未満のとき整数化。それ以外(文字列・Bool・負・巨大数・非オブジェクト・壊れた JSON)は 0(`ProjectFormat.swift:21-27`)。`Project.decode` 内の読みは `max(0, l.int("formatVersion") ?? 0)`(`Project.swift:119`)で、数値文字列は 0 | B-01 |
| X-22 | (記述なし)v0/v1 → v2 の移行 | **フィールド変換の移行は無い**。0/1/2 は同じ読み方で、書くと 2 になるだけ(`ProjectFormatTests.testVersion1FileStillLoadsAndResavesAsCurrent`)。形式の移行は版と別に `TachieMigration`(旧キャラクターの立ち絵 → 立ち絵素材 + 立ち絵クリップ)が `decodeMigrating` で行う(`Tachie.swift:261,324`、`ProjectDocument.swift:39`) | B-01 / B-27 |
| X-23 | (記述なし)新しい版を開いたときの扱い | 利用者へ 1 度警告(`ProjectFormat.newerWarning`)、最初の保存の前に元の中身を世代バックアップへ残し、残せなければ保存を中止(`ProjectFormat.swift:47-` 、`ProjectDocument.swift:48-62`) | B-01 |

### 1.4 トップレベルのキー(`Project.knownKeys` 28 キー: `Project.swift:83`)

書く条件は `Project.encode`(`Project.swift:134-168`)による。「常時」= 空・既定でも書く。

| ID | キー | 仕様 | 実装: 型 / 既定 / 書く条件 | 判定 |
|---|---|---|---|---|
| X-40 | `formatVersion` | 無し | Int / 0 / 常時(`max(source, 2)`) | B-01 |
| X-41 | `width` `height` | C-01 は「解像度を本体に保持」 | Int / 1920・1080 / 常時。読みは Int・整数値の Double・欠落は既定、1〜16384 にクランプ | 一致 |
| X-42 | `fps` | C-01 は「FPS を保持」 | 読み: Double・数値文字列 `"29.97"`・分数 `"30000/1001"`、範囲 1〜240 に収める、読めなければ 60(`Project.swift:171-175`、`FrameRateInput.rawValue` `OutputSettings.swift:243`)。書き: `FrameRate.canonical` を適用し、整数なら整数、他は小数(放送用 23.976/29.97/59.94 は表示値、他は小数 3 桁丸め)。常時 | B-22 |
| X-43 | `bg` | 無し | String / `"#000000"` / 常時。`"transparent"` で透明(`Project.swift:34`) | B-19 |
| X-44 | `codec` | 無し | String / `"h264"` / 常時 | B-19 |
| X-45 | `voicevoxUrl` | 無し(S-02 のプラグイン境界関連) | String / `"http://127.0.0.1:50021"` / 常時 | B-19 |
| X-46 | `aquestalkCommand` | 無し | String / `defaultAquesTalkCommand`(`Project.swift:3`。macOS の AquesTalkPlayer パス入りのコマンド) / 常時。**Windows 移植では値の意味が OS 依存** | B-19 |
| X-47 | `characters` | S-01/S-02 | `[Character]` / `Character.defaults()`(3 人)/ 常時。**読みで欠落・空配列・型違いなら既定 3 人に戻る**(`Project.swift:100`) | A-14 / 懸念 N-5 |
| X-48 | `tracks` | C-01(クリップ配置) | `[Track]` / `Track.defaultLayers()`(「レイヤー1」〜「レイヤー5」)/ 常時。読みで欠落・空配列・型違いなら既定 5 層に戻る(`Project.swift:101`) | B-20 / 懸念 N-5 |
| X-49 | `markers` | 無し | `[Marker]` / 空 / 非空のときだけ | B-02 |
| X-50 | `reviewComments` | 無し | `[ReviewComment]` / 空 / 非空のときだけ。読みの型違いは `extra` へ退避 | B-03 |
| X-51 | `rangeIn` `rangeOut` | 無し | Double? / nil / 設定時のみ | B-12 |
| X-52 | `mediaHints` | 無し(M-01 の相対パス関連) | `[元src: MediaHint{relative?, size?}]` / 空 / 非空のときだけ。**パッケージ保存のときだけ入る**(`MediaPackage.swift:57`) | B-15 |
| X-53 | `mediaFingerprints` | §4.2「必須」 | `[元src: {fileName,size,sha256}]` / 空 / 非空のときだけ(任意)。通常保存で自動付与(`ProjectModel+Media.swift:101-110`) | A-05 / A-06 |
| X-54 | `proxyLinks` | M-06(プロキシ資産) | `[元src: 外部プロキシのパス]` / 空 / 非空のときだけ。プレビュー専用 | A-09 / B-16 |
| X-55 | `mediaPool` | 無し | `[String]` / 空 / 非空のときだけ(取り込んだ素材のパス。クリップを消しても残る) | B-14 |
| X-56 | `mediaMetadata` | 無し | `[src: MediaMetadata]` / 空 / 中身が全部空の要素を除いて非空のときだけ | B-07 |
| X-57 | `smartCollections` | 無し | `[SmartCollection]` / 空 / 非空のときだけ(読みの型違いは `extra` へ) | B-07 |
| X-58 | `targetTrackId` | 無し | String? / nil / 設定時のみ(型違いは `extra` へ) | B-13 |
| X-59 | `multicams` | 無し | `[MulticamGroup]` / 空 / 非空のときだけ。`MulticamGroup` は合成 Codable で厳格(1 要素でも型違いなら配列ごと `extra` へ) | B-05 |
| X-60 | `tachies` | 無し | `[Tachie]` / 空 / 非空のときだけ | B-06 |
| X-61 | `readingDictionary` | 無し | `[{word, reading}]` / 空 / 非空のときだけ | B-08 |
| X-62 | `scenes` | 無し | `[SceneDefinition{id,name,tracks}]` / 空 / 非空のときだけ | B-04 |
| X-63 | `subtitleY` | 無し | Double? / nil(使うときは 0.88)/ 設定時のみ | B-10 |
| X-64 | `camera` | 無し | `CameraSettings?` / nil / `isDefault` でないときだけ(x,y,targetX,targetY 0.5・orbit 0・fov 60 は既定。さらにキーごとにも既定なら書かない) | B-09 |
| X-65 | `scriptText` | 無し | String / `""` / 非空のときだけ | B-11 |

### 1.5 クリップ

| ID | 仕様の記述 | 実装の実態(根拠) | 判定 |
|---|---|---|---|
| X-70 | (記述なし)クリップ種別の一覧 | `ClipType.known` 12 種: image, video, audio, text, voice, blur, adjustment, visualizer, compound, scene, shape, tachie(`Project.swift:415`)。**仕様書 01 にクリップ種別の記述がそもそも無い** | B-18 |
| X-71 | C-02: 未知のものは保持して書き戻す | 未知の `type` 文字列は `ClipType(rawValue:)` でそのまま保持し書き戻す(`Project.swift:394-424`、`ProjectTests.testRichRoundTripKeepsEverything` の `hologram`)。**`type` が文字列でないときは `"unknown"` に置換**、欠落は `image`(`Project.swift:688`、懸念 N-6) | 一致 / 懸念 N-6 |
| X-72 | (記述なし)Clip のフィールドと既定値 | §3.3 の表。値は `*OrDefault`(`Project.swift:576-`): x,y = 0.5 / scale,opacity,volume = 1 / blur = 0 / w,h = 0.3 / strength = 24 / shape = "rect" / blurMode = "blur" / mosaicSize = 12 / font = `defaultFonts[0]` / color = "#ffffff" / outline = "#000000" / fontSize = voice 64・他 80 / rotation = 0 | B-19 |
| X-73 | (記述なし)true のときだけ書くフラグ | `locked` `muted` `disabled` `treatAsVoice` `speakingOnly` `followsProjectEnd` `playsAnimation` `frameBlend` `frameFlow` `stabilizeRoll`。false で読んでも書き戻さない(`true` 以外の値は `extra` に退避して書き戻す)。`ProjectGoldenRoundTripTests.testClipDefaultsAreOmittedAndFlagsAreWrittenOnlyWhenTrue` | B-19 |
| X-74 | (記述なし)既定なら書かない | `channelMode`(downmix)・`mouthDrive`(all)・`stabilize`(0 以下)・`note`(空)・`keyframes` の空配列・`effects` 空・`ruby` 空・`audioFx` 空・`figure` が正規化で空・`tracking`/`objectMask` の有効サンプル無し・`voicevoxAccent` 空・`camera.isDefault` | B-19 |

### 1.6 キャラクター・トラック

| ID | 仕様の記述 | 実装の実態(根拠) | 判定 |
|---|---|---|---|
| X-80 | S-01/S-02: キャラ定義・音声設定を内包。項目一覧は未決定 | `characters` はプロジェクトの JSON に丸ごと入る。全フィールドは §3.4 の表(25 キー。`Project.swift:225`)。engine は `"voicevox"`(既定)/`"aquestalk"`(文字列でそのまま保持。未知 engine も保持) | A-14 |
| X-81 | C-02: プラグイン由来の音声系(engine/speaker/速度等)を保持のみ | `Character` は `extra` を持ち未知キーも保持。ただし本体は engine/speaker/speed 等を**型付きで解釈**している(コア版実験とは別)。`speaker` は Int、`speed`/`pitch`/`intonation`/`pre/postPhonemeLength`/`pauseLengthScale` は Double? | 一致(保持は成立) |
| X-82 | (記述なし)`legacyKeys` の書き戻し | 旧立ち絵の 7 キー(imgClosed, imgOpen, x, y, scale, flip, alwaysShow)は、読んだファイルに**あったキーを同じだけ書き戻す**(未設定の imgClosed/imgOpen は `null` で)。新規 `Character()` は 7 キー全部。`TachieMigration` 後は空 = 既定でない値だけ書く(`Project.swift:231,280-`)。`testCharacterWritesLegacyPoseKeysOnlyWhenPresentOrNonDefault` | B-21 |
| X-83 | (記述なし)`Character.defaults()` | 3 人: 「キャラ1」#e8384f(x 0.18, 左右反転)、「キャラ2」#f2c53d(x 0.82)、「キャラ3」#7ac943(x 0.82)(`Project.swift:236-250`) | B-21 |
| X-84 | (記述なし)Track のフィールド | §3.5 の表。`hidden` `muted` は設定した値をそのまま(false でも書く)、`locked` `solo` `height` `volume` `pan` も設定値をそのまま書く(`encodeIfPresent`)。コメントは「オン以外は書かない」「標準は書かない」だが、`encode` 自体は `encodeIfPresent` で nil でなければ書く(標準値を nil に戻す責務が UI/編集側にあるかは未確認。`Project.swift:375-`) | B-20 |

### 1.7 未知フィールド・壊れたファイル

| ID | 仕様の記述 | 実装の実態(根拠) | 判定 |
|---|---|---|---|
| X-90 | C-02: 未知のフィールドが含まれていても読み込みは失敗させず**保持して書き戻す**(前方互換) | **部分保持**。`extra: [String: JSONValue]` を持つ型だけが、その階層の未知キーを保持する。持たない型の未知キーは**黙って落ちる**(`ProjectFormatTests.testUnknownKeysInTypesWithoutExtraAreNotPreserved`)。型違いで読めなかった既知キーは、**項目ごとに**「`extra` へ退避」か「捨てる」かが違う(§3.6、N-1) | A-12 |
| X-91 | 保持する階層の詳細 | `extra` を持つ型: Project / Character / Track / Clip / Marker / ReviewComment / SceneDefinition / Tachie / CameraSettings / MediaMetadata / MediaFilterCriteria / SmartCollection / Effect / Transition / TextStyle / TextAnim / ClipMask / HSLMask / ObjectMask / Figure / Visualizer / Ducking / TextCounter / ValueRef / MeshWarp / PuppetWarp / AudioFx と AudioFx の各子 / CharacterRig とそのパーツ / Karaoke(`grep -n "var extra: \[String: JSONValue\]" Sources/MovieCutCore/*.swift`)。持たない型: MediaHint の値、MediaFingerprint、Crop、Keyframe、SpeedKey、Bubble、RubySpan、VoicevoxAccentPhrase、ReadingEntry、MulticamGroup / MulticamAngle、ObjectTrack(`tracking`) | A-12 |
| X-92 | C-03: 壊れたプロジェクト(本体が解析不能)は部分読み込みせずエラー | JSON 自体が壊れている・最上位がオブジェクトでない・サイズ/深さ/件数の上限超過 → throw(`ProjectIO.swift:5-11`、`testBrokenFilesThrowAndFieldLevelMismatchesDoNot`)。**フィールド単位の型違いは throw せず**既定値になるか `extra` に回る(`Lenient`: `try?` で nil。`JSONValue.swift`)。「解析可能だが一部の値の型が違う」ファイルは、**部分的に読んで開く** | A-13 |
| X-93 | (記述なし)`extra` の値の表現 | `JSONValue`(null/bool/number(Double)/string/array/object)。数値は Double のため 2^53 超の整数は精度が落ちる(懸念 N-7) | B-23 |

### 1.8 素材参照・識別・再リンク・パッケージ化

| ID | 仕様の記述 | 実装の実態(根拠) | 判定 |
|---|---|---|---|
| X-100 | M-01: 素材参照はプロジェクトフォルダからの**相対パスを基本** | `Clip.src` は**通常は絶対パス**(取り込んだパスのまま)。相対パス(`media/…`)になるのはパッケージ保存のときだけ(`MediaPackage.swift:53-59`)。読み込み側は相対も絶対も解釈する | A-07 |
| X-101 | M-01 検証: フォルダごと別パスへ移して開く → リンク切れなし | `MediaResolver.resolve`(`MediaResolver.swift:15`)の順: ①そのまま存在 → ②相対パスはプロジェクトフォルダ基準(`..` やシンボリックリンクでの脱出は `MediaPaths.contained` が拒否)→ ③絶対パスはプロジェクトフォルダ名をアンカーに、末尾側の同名要素以降を相対として再解決(移動した絶対パス)→ ④それでも無ければ再リンク(`MediaRelinker`)の責務 | B-31 |
| X-102 | M-02: 相対で表せない素材は未決定 | 別ボリューム等は絶対パスのまま。再リンクで救う設計 | 一致(未決定のまま) |
| X-103 | M-03/R-06: 素材が無くても編集データは失われない | `src` はそのまま保持される。`mediaFingerprints` は参照中なら欠けた素材の以前の記録を残す(`ProjectModel+Media.swift:103-107`) | 一致 |
| X-104 | §4.2: ファイル名・サイズ・ハッシュ「必須」。ハッシュアルゴリズムは未決定 | `MediaFingerprint{fileName, size, sha256}`。**SHA-256 の小文字 hex 64 文字で確定**(`MediaFingerprint.swift:5-21,33-45`)。キーは元の `src`。**任意**(空なら書かない)。通常保存の `encodeForSave` が、読める素材について収集して付与し、欠けた素材は以前の記録を残す(`ProjectModel+Media.swift:101-110`)。`MediaPackage.write` では付与しない(§5 N-3) | A-04 / A-05 |
| X-105 | M-04: 素材登録時にファイル名・サイズ・ハッシュを記録する | 記録するのは**保存時**(登録時ではない)。ハッシュはキャッシュ(`MediaFingerprintCache`)経由で、変わったものだけ計算し直す | A-06 |
| X-106 | M-05: 同一性は「ハッシュ一致」が正、ファイル名・サイズは候補絞り込みと補助 | `MediaRelinker.findReplacement`(`MediaResolver.swift:151-`): フィンガープリントがある素材は**サイズが同じ候補だけハッシュを読み、sha256 とサイズが一致したものだけ**つなぐ(読めない候補・同名同サイズでも違うハッシュはつながない)。フィンガープリントが無い素材だけ、ファイル名一致(+ `mediaHints[src].size` があればサイズ一致)でつなぐ後方互換 | A-08 |
| X-107 | R-01/R-03: ハッシュ一致で一括再リンク、同名異内容はつながない | `relink(missing:fingerprints:hints:candidateFolders:)` が候補フォルダを再帰走査(隠しファイル除く)して一括で対応表(旧→新)と `unresolved` を返す。`applying` が `src` と `mediaPool` を差し替える(`MediaResolver.swift:72-148`)。`ProjectPortabilityTests` が同名異内容・ハッシュ読めない場合を固定 | 一致 |
| X-108 | R-04: パッケージ化 → 外部素材をフォルダ内に集約し相対パス参照 | `MediaPackage.plan`: トップレベルのトラックのクリップの `src` だけを集め、`media/<名前>` へコピーする計画と、`src` の相対化、`mediaHints`(キー = 元のパス、値 = `{relative, size}`)の作成。元ファイルが無いものは `skipped` で `src` はそのまま。**複合クリップ・シーン内のクリップと `mediaPool` は対象外**(N-3) | 一致 / 懸念 N-3 |
| X-109 | R-05: 同名衝突の命名規則は未決定(上書きで取り違えない) | **確定**: 衝突判定は**小文字化した名前**で行い、2 つ目から `<stem>-2.<ext>`、`-3`…。拡張子なしは `<name>-2`。同じ元パスは 1 回だけコピーして同じ宛先(`MediaPackage.swift:29-45`)。`testMediaPackageNamingRule` が固定 | A-10 |
| X-110 | (記述なし)`mediaPool` と `mediaMetadata` のキー | どちらも素材の参照文字列(`Clip.src` と同じ)をキーにする | B-14 / B-07 |

### 1.9 プロキシ

| ID | 仕様の記述 | 実装の実態(根拠) | 判定 |
|---|---|---|---|
| X-120 | M-06/§4.3: プロジェクトフォルダ内のプロキシは**プロジェクト資産**でキャッシュではない。プロジェクトフォルダ内の明示的な場所に存在 | **生成プロキシ**(540p の `.mp4`)は `ProxyStore.defaultDirectory()` = `DataLocations.current.proxies`(Application Support/MovieCut/Proxies)に置く**アプリ側**。名前は「元のパス・更新日時・サイズ」の SHA-256 先頭 16 バイトの hex(`ProxyStore.swift:20-50`)。プロジェクトには入らず、パッケージにも入らない。**外部プロキシ**はユーザーが指定した別ファイルを `proxyLinks[元src] = プロキシのパス` で**参照**するだけ(`ProxyWorkflow.swift:61-93`)。プレビュー専用で書き出しは常に原本。解決は「外部リンク(実在すれば)→ 生成済み → なし」の順 | A-09 / C-02 |
| X-121 | M-07: 原本を同期対象外、プロキシをプロジェクト内 | 実装は逆に「プロキシ = アプリ側のローカル生成物、`proxyLinks` = 任意の場所のファイルへのパス」。プロジェクト内に置く運用の仕組み(置き場所の決まり・パッケージへの同梱)は無い | C-02 |

### 1.10 他形式

| ID | 仕様の記述 | 実装の実態(根拠) | 判定 |
|---|---|---|---|
| X-130 | §8.2: `feat/ymmp-import` ブランチでプロトタイプ完了、マージ待ち | 現ツリーに `Sources/MovieCutCore/YmmpImport.swift`(493 行)、`Tests/.../YmmpImportTests.swift`、フィクスチャ `ymmp-basic.ymmp` / `ymmp-beta.ymmp`、取り込み上限 `maxYmmpBytes`(`InputLimits.swift:13`)がある。`feat/ymmp-import` ブランチは存在しない(`git branch -a`)。さらに YMM4 書き出し `ProjectModel+YmmpExport.swift` と `YmmpExportTests.swift`、EXO 書き出し、FCPXML・Premiere(prproj) 取り込みもある | A-11 / B-28 |
| X-131 | I-03〜I-05(変換スコープ・読み飛ばしレポート・壊れたら全体エラー) | `YmmpImporter.Report.skipped`(理由つき)、`Failure.notJSON/notProject/noTimeline/invalidFPS/malformedItems`(`YmmpImport.swift:45-81`)。「ファイル全体の構造が壊れていれば部分変換せず throw」はコメントに明記。個別アイテムの変換内容が仕様 §8.2 の表と一致するかはサンプル確定待ちのため**本件では未検証** | 一致(方針) |

---

## 2. 不一致リスト(A / B / C 全件)

### A: 仕様が古い/間違い(15 件)

| ID | 仕様の箇所 | 仕様の記述 | 実装の実態 | 表の行 |
|---|---|---|---|---|
| A-01 | F-01、§1 論理構成、I-06 | プロジェクトはフォルダ形式(1 プロジェクト = 1 フォルダ) | 通常は単一 JSON ファイル。フォルダはパッケージ保存のときだけ | X-01 |
| A-02 | §1 末尾「内部レイアウトは未決定」 | 本体ファイル名・サブフォルダ名は未決定 | パッケージ: `<name>.mcpjc` + `media/`。確定可能 | X-02 |
| A-03 | E-01、E-04 | 拡張子は定数 1 箇所、リテラルは 1 箇所以外に現れない / 定数 1 行で移行できる | 少なくとも 5 箇所(`ProjectTemplate.fileExtension`、`MediaPackage.swift:76`、`ProjectDocument` の UTType、`make-app.sh` の plist 2 か所)に拡張子が散在 | X-10, X-13 |
| A-04 | §4.2 表、§9 | ハッシュアルゴリズムは未決定 | SHA-256(小文字 hex 64 文字)で確定 | X-104 |
| A-05 | §4.2 表(必須列) | ファイル名・サイズ・ハッシュは「必須」 | `mediaFingerprints` は任意(空なら書かない)。無くても読める。通常保存で自動付与、パッケージ書き出しでは付与されない | X-53, X-104 |
| A-06 | M-04 | 素材登録時に 3 項目を記録 | 保存時(`encodeForSave`)に収集して付与 | X-105 |
| A-07 | M-01 | 素材参照は相対パスを基本 | `src` は通常は絶対パス。相対にするのはパッケージ保存時のみ。読みでは相対・移動した絶対パスも解決 | X-100 |
| A-08 | M-05 | ハッシュ一致が正、ファイル名・サイズは候補絞り込みと補助判定 | フィンガープリントがある素材はハッシュ+サイズ一致だけ(補助判定は使わない)。無い素材だけ名前 + サイズ(目印)で一致 | X-106 |
| A-09 | M-06、§1 論理構成表、§4.3、README §5 用語「プロキシ」、`03` B-05 | プロジェクトフォルダ内のプロキシはプロジェクト資産。キャッシュ領域には無い | 生成プロキシはアプリ側ディレクトリ(Application Support/MovieCut/Proxies)の生成物。プロジェクトが持つのは外部プロキシへのパス参照 `proxyLinks` だけ | X-120 |
| A-10 | R-05、§9 | 同名衝突の命名規則は未決定 | `<stem>-2.<ext>`、`-3`…、小文字で衝突判定で確定 | X-109 |
| A-11 | §8.2 現状、§9 | `feat/ymmp-import` ブランチのプロトタイプで、マージ待ち | 現ツリーに取り込み済み(+ 書き出し・他形式の取り込み/書き出し) | X-130 |
| A-12 | C-02 | 未知のフィールドは保持して書き戻す(前方互換) | `extra` を持つ型の階層だけ保持。持たない型は落ちる。型違いの既知キーの退避も項目ごとに異なる | X-90, X-91 |
| A-13 | C-03 | 壊れたプロジェクトは部分読み込みをせずエラー | JSON が壊れている・上限超過だけ throw。値の型違いなどフィールド単位の破損は既定値/`extra` で救って開く | X-92 |
| A-14 | S-01、S-02、§5.1 末尾 | 内包するキャラ定義・音声設定の項目一覧は未決定 | `Character` の全フィールドで確定可能(§3.4)。さらに「`characters` が空・欠落なら既定 3 人に戻る」読み規則がある | X-47, X-80 |
| A-15 | README §1(`01` の主な対象に「移行」)・§5 用語「プロジェクトフォルダ」 | `01` が「移行」を扱う / 「プロジェクトフォルダ = 01 で定義するフォルダ形式のプロジェクト一式」 | 01 に移行の節が無い(formatVersion の説明も無い)。「フォルダ形式」は存在しない(A-01) | §4 |

### B: 仕様に無い実装(33 件)

| ID | 実装 | 根拠 |
|---|---|---|
| B-01 | `formatVersion`(無し = 0、current = 2、書くとき `max(source, current)`、新しい版も開く、`version(in:)` の厳密判定、新しい版の警告と初回保存前の世代バックアップ) | X-20〜X-23 |
| B-02 | `markers`(`id, time, name, color?`。色 teal は既定 = 書かない) | X-49 |
| B-03 | `reviewComments` | X-50 |
| B-04 | `scenes`(`SceneDefinition`)と `Clip.sceneId`(type `scene`) | X-62 |
| B-05 | `multicams`(`MulticamGroup`) | X-59 |
| B-06 | `tachies`(立ち絵素材)と `Clip.tachieId`(type `tachie`) | X-60 |
| B-07 | `mediaMetadata` / `smartCollections` | X-56, X-57 |
| B-08 | `readingDictionary` | X-61 |
| B-09 | `camera` | X-64 |
| B-10 | `subtitleY` | X-63 |
| B-11 | `scriptText` | X-65 |
| B-12 | `rangeIn` / `rangeOut` | X-51 |
| B-13 | `targetTrackId` | X-58 |
| B-14 | `mediaPool` | X-55 |
| B-15 | `mediaHints`(`{relative?, size?}`。パッケージ時のみ) | X-52 |
| B-16 | `proxyLinks`(外部プロキシの参照。A-09 の実体側) | X-54 |
| B-17 | `mediaFingerprints` のキー規約(キー = 元の `src`)と JSON 形(`fileName`/`size`/`sha256`) | X-53 |
| B-18 | クリップ種別 12 種 + 未知 type の保持 | X-70, X-71 |
| B-19 | Clip の約 80 キー(`Clip.knownKeys` 82 件)と既定値・「true のときだけ書く」「既定なら書かない」規則、`bg`/`codec`/`voicevoxUrl`/`aquestalkCommand` の既定値 | X-43〜X-46, X-72〜X-74 |
| B-20 | Track のフィールド(hidden/muted/locked/solo/height/volume/pan)とレイヤー 5 層の既定 | X-48, X-84 |
| B-21 | Character の全フィールド、`legacyKeys` の書き戻し規則、既定 3 人 | X-82, X-83 |
| B-22 | `fps` の表現(整数なら整数・小数可・読みは文字列/分数可・1〜240・放送用レートの表示値)と JSON エンコード設定 | X-06, X-42 |
| B-23 | `extra`(`JSONValue`)の仕組みと型違い既知キーの退避 | X-93 |
| B-24 | 世代バックアップ(`ProjectVersions`) | X-08 |
| B-25 | `InputLimits` / `sanitizeLoaded`(上限・クランプ) | X-07 |
| B-26 | 読み込みの欠落補完: 欠落キー = 既定値、`characters`/`tracks` は空でも既定に戻る | X-47, X-48 |
| B-27 | `TachieMigration` / `decodeMigrating`(旧キャラの立ち絵 → 立ち絵素材 + 立ち絵クリップ) | X-22 |
| B-28 | 他形式の入出力: YMM4 書き出し、EXO 書き出し、FCPXML・Premiere(prproj)取り込み、字幕 CSV/台本 CSV 等(`InputLimits.swift:9-15`) | X-130 |
| B-29 | テンプレート(`ProjectTemplate`。`.mcpjc` と同じ JSON でクリップを外したもの。拡張子は別定数) | `ProjectTemplate.swift:4-8` |
| B-30 | 自動保存・復元(`RecoveryInbox`、`maxRecoveryBytes` = 96MiB の復元ファイル) | `InputLimits.swift:7`、`ProjectDocument.swift:27` |
| B-31 | `MediaResolver` の解決順(そのまま → 相対 → 移動した絶対パス)と脱出防止 | X-101 |
| B-32 | `MediaPackage` の計画(`skipped`・同じ元パスは 1 回コピー・素材のコピーに失敗したら例外で途中の成果物は残す) | X-108 |
| B-33 | `.ymproj` を開いた書類は拡張子を変えずに書き戻す(保存先の拡張子規則) | X-12 |

### C: 実装に無い仕様(4 件)

| ID | 仕様 | 状況 |
|---|---|---|
| C-01 | F-04: クラウド退避ファイル(未ダウンロードのプレースホルダ)の事前チェックと案内、同時編集のロック目印 | `Sources/` にコード見当たらず(仕様側もロック方式は未決定) |
| C-02 | M-06/M-07: プロジェクトフォルダ内にプロキシを資産として置く仕組み | 無い(A-09 の裏返し。置き場所の決まりも同梱もない) |
| C-03 | S-03/S-04: 設定の 1 ファイル集約と書き出し/読み込み(設定の引っ越し) | 該当機能を `Sources/` で見つけられなかった(プロジェクト形式の範囲外のため深追いしていない。要確認) |
| C-04 | README G-01〜G-03: バージョン識別子つきのゴールデンデータ一式 | 無い。`Tests/MovieCutCoreTests/Fixtures/` に `golden-rich.json` / `golden-electron-made.json` があるが版の識別・一式の運用は無く、`golden-*.json` は `OpticalFlowTests.swift:301` が走査で触る程度(`ProjectGoldenRoundTripTests` が最初のプロジェクト形式専用のゴールデン) |

---

## 3. 仕様書 01 への更新案(貼れる文面ドラフト)

仕様書の作法(ID 付き表 + 検証条件)に合わせた。ID は既存 ID を壊さないため、既存 ID は書き換え、新規は枝番または新ブロックにした。

### 3.1 §1 形式の基本形(F-01、F-03、論理構成)

> **F-01(改)** プロジェクトの本体は **1 つの JSON ファイル**(UTF-8、拡張子は §2)である。素材実体を集約する「パッケージ」だけは**フォルダ**(本体ファイル + `media/`)となる。本体ファイル単体でコピー・同期・共有できる。
> 検証条件: 本体ファイルを別パスへコピーして開く → エラーなく開け、タイムライン内容がコピー元と一致する(素材が絶対パス参照のときは、リンク切れ素材はプレースホルダとして残る。R-06)。

> **F-01a(新)** パッケージは `<フォルダ>/<名前>.mcpjc` と `<フォルダ>/media/<素材>` から成る。パッケージ内の素材参照(`src`)は `media/<名前>` の相対パスで、本体ファイルのあるフォルダを基準に解決する。
> 検証条件: パッケージフォルダを別パスへ移動して開く → 全素材が再生できる。

> **F-03(改)** 本体ファイルの保存はアトミックに行う(一時ファイルへ書いてから差し替える。現行実装は `Data.write(options: .atomic)` および OS の文書保存)。パッケージの素材コピーはこの対象外とし、途中で失敗した場合は成果物が部分的に残りうる(F-03a)。
> **F-03a(新)** パッケージ書き出しは、素材コピー → 本体ファイルの順に行う。素材のコピーに失敗したら書き出しは失敗し、既存の元プロジェクトは変えない。

> 論理構成表の「プロキシ」行を次に差し替え: 「プロキシ — 生成プロキシはアプリ側ディレクトリ(プロジェクト外)に置く。プロジェクトが持つのは、外部プロキシへのパス参照 `proxyLinks` のみ(§4.3)」。「内部ファイル名・レイアウトは未決定」の段落は削除し、F-01a に置き換える。

### 3.2 §2 拡張子

> **E-01(改)** 保存に使う拡張子は定数で管理し、読み込み可否の判定・保存名の生成は定数を参照する。現行実装は `ProjectFileExtension.swift`(`current` と `readable`)を正とするが、テンプレート(`ProjectTemplate.fileExtension`)・パッケージ書き出し・OS への型宣言(UTType / Info.plist)に拡張子が別に書かれている(実装上の課題。懸念 N-8)。
> 検証条件: 拡張子文字列を検索し、定数以外の出現箇所が「OS への型宣言」(UTType、Info.plist)に限られること(**現行は満たさない**。是正は別件)。
> **E-03(改)** `ymproj` は読み込み互換とし、**旧拡張子で開いた書類は同じ拡張子のまま保存する**(新規保存・別名で保存は `mcpjc`)。中身は同じ JSON。
> **E-04(補)** 「定数 1 行の差し替えで移行」は、E-01 が満たされるまで成立しない。

### 3.3 §3 編集データの互換: 新設ブロック

**3.1 formatVersion**

| ID | 要件 | 検証条件 |
|---|---|---|
| V-01 | 本体の最上位に整数 `formatVersion` を書く。現在の版は **2**。書くときは `max(読んだ版, 2)` | 新規保存 → `formatVersion` = 2。版 7 のファイルを開いて保存 → 7 のまま |
| V-02 | 読み込み時の版: 無い = 0。数値(整数相当、有限、0 以上 1e9 未満)以外 — 文字列・Bool・負・巨大数・非オブジェクト — は 0 とする | `"2"`(文字列)・`true`・`-1`・`1e300` → 版 0 |
| V-03 | 版 0・1・2 は同一に読む(フィールドの変換はしない)。版は「このファイルを書いたアプリが知っていた形式の世代」の印である | 版 1 のファイルを読んで保存 → 内容は同じで `formatVersion` だけ 2 |
| V-04 | 現在の版より新しい版のファイルも開く(知らないキーは §3.6 の範囲で保持する)。利用者へ「保存すると一部の情報が失われることがある」と 1 度知らせ、最初の保存の前に元の中身を世代バックアップへ残す。残せなかった場合は保存を中止する | 版 9 のファイルを開いて保存 → 元の中身が世代バックアップに残る |
| V-05 | 旧キャラクター立ち絵(キャラクターが `imgClosed` 等を持つ形)は、開くときに立ち絵素材(`tachies`)と立ち絵クリップへ変換する(この変換は版とは独立) | 旧形式のファイルを開く → `tachies` が生成され、保存すると新形式になる |

**3.2 トップレベルのキー(28 キー)**

| ID | キー | 型 | 既定 | 書く条件 |
|---|---|---|---|---|
| T-01 | `formatVersion` | 整数 | 0(読み) | 常時 |
| T-02 | `width` / `height` | 整数 | 1920 / 1080 | 常時(読みで 1〜16384 に収める) |
| T-03 | `fps` | 数 | 60 | 常時。整数値は整数で、それ以外は小数で書く。読みは数・数値文字列(`"29.97"`)・分数文字列(`"30000/1001"`)を受け、1〜240 に収める。読めなければ 60 |
| T-04 | `bg` | 文字列 | `"#000000"` | 常時。`"transparent"` は透明背景 |
| T-05 | `codec` | 文字列 | `"h264"` | 常時 |
| T-06 | `voicevoxUrl` | 文字列 | `"http://127.0.0.1:50021"` | 常時 |
| T-07 | `aquestalkCommand` | 文字列 | macOS の AquesTalkPlayer 呼び出し(OS 依存の文字列) | 常時 |
| T-08 | `characters` | 配列 | 3 人(§3.4) | 常時。読みで欠落・空・型違いなら既定 3 人 |
| T-09 | `tracks` | 配列 | レイヤー 1〜5(空のトラック) | 常時。読みで欠落・空・型違いなら既定 5 層 |
| T-10 | `markers` | 配列 | 空 | 非空のとき |
| T-11 | `reviewComments` | 配列 | 空 | 非空のとき |
| T-12 | `rangeIn` / `rangeOut` | 数(秒) | なし | 設定時のみ |
| T-13 | `mediaHints` | 辞書(元 `src` → `{relative?, size?}`) | 空 | 非空のとき(パッケージ保存のときだけ入る) |
| T-14 | `mediaFingerprints` | 辞書(元 `src` → `{fileName, size, sha256}`) | 空 | 非空のとき(任意。通常保存で自動付与) |
| T-15 | `proxyLinks` | 辞書(元 `src` → 外部プロキシのパス) | 空 | 非空のとき |
| T-16 | `mediaPool` | 文字列の配列 | 空 | 非空のとき |
| T-17 | `mediaMetadata` | 辞書(素材の参照 → メタデータ) | 空 | 中身のある要素が 1 つでもあるとき |
| T-18 | `smartCollections` | 配列 | 空 | 非空のとき |
| T-19 | `targetTrackId` | 文字列 | なし | 設定時のみ |
| T-20 | `multicams` | 配列 | 空 | 非空のとき |
| T-21 | `tachies` | 配列 | 空 | 非空のとき |
| T-22 | `readingDictionary` | 配列(`{word, reading}`) | 空 | 非空のとき |
| T-23 | `subtitleY` | 数 | なし(使うときは 0.88) | 設定時のみ |
| T-24 | `scenes` | 配列 | 空 | 非空のとき |
| T-25 | `camera` | オブジェクト | なし(x,y,targetX,targetY = 0.5、orbit = 0、fov = 60) | 既定値と異なるとき |
| T-26 | `scriptText` | 文字列 | 空 | 非空のとき |

> 検証条件(T-01〜T-26): 既定のプロジェクトを保存 → 最上位キーは T-01〜T-09 の 10 個だけ。T-10〜T-26 の各値を設定して保存 → 該当キーが現れる(ゴールデン: `ProjectGoldenRoundTripTests.testDefaultProjectOmitsOptionalTopLevelKeys` / `testSettingOptionalTopLevelFieldsWritesTheirKeys`)。

**3.3 エンコード規則**

| ID | 要件 | 検証条件 |
|---|---|---|
| J-01 | 文字コードは UTF-8、キーは昇順、整形(2 スペース字下げ)、`/` をエスケープしない。時刻は秒の数値(実数) | 同じ内容を保存 → 同じバイト列。encode → decode → encode でバイトが変わらない |
| J-02 | 色は `"#rrggbb"` 文字列(`bg` のみ `"transparent"` も可) | — |
| J-03 | 型が違う値・欠落は、項目ごとに既定値で読む。JSON が壊れている・最上位がオブジェクトでない・上限超過(下記)のときだけ読み込みを失敗とする | `{"width":"x"}` → 幅 1920 で開く。`{broken` → エラー |
| J-04 | 読み込みの上限: ファイル 64MiB、入れ子 64 段、トラック 2,000、クリップ 100,000(複合クリップの中も数える)。値の範囲(幅高 1〜16384、秒 ±360,000 など)は読み込み時に収める(正常値は変えない) | 上限超過 → エラー |

**3.4 クリップ種別(T-30)**

| ID | `type` | 素材 | 備考 |
|---|---|---|---|
| K-01 | `image` | `src` | 既定の type(欠落時) |
| K-02 | `video` | `src` | `offset`・`srcDuration`・速度/逆再生/フリーズ等 |
| K-03 | `audio` | `src` | |
| K-04 | `text` | なし | `text`、`fontSize`(既定 80) |
| K-05 | `voice` | なし | `charId`、`text`(読み上げ)、`subtitleText`、`subtitle`、`fontSize`(既定 64) |
| K-06 | `blur` | なし | `x,y,w,h,strength,shape,blurMode`(ぼかし範囲) |
| K-07 | `adjustment` | なし | 調整レイヤー(下の合成結果にエフェクト) |
| K-08 | `visualizer` | なし | 音声ビジュアライザ(`visualizer`) |
| K-09 | `compound` | なし | 中のレイヤーを `tracks` に持つ |
| K-10 | `scene` | なし | `sceneId` で `scenes` を参照 |
| K-11 | `shape` | なし | 図形(`figure`) |
| K-12 | `tachie` | なし | `tachieId` で `tachies` を参照 |
| K-13 | (未知の文字列) | — | **文字列のまま保持して書き戻す**。type が文字列でない場合は `"unknown"` として読む |

> 検証条件: K-01〜K-12 と未知 type `hologram` を含むプロジェクトを保存 → 読み直し → 保存して type の文字列が全て保たれる(`testAllClipTypesRoundTripKeepingTypeStrings`)。

**3.5 クリップの主なフィールドと既定値(C-10 系)**

| ID | フィールド | 型 | 未設定のときの扱い(既定) | 書く条件 |
|---|---|---|---|---|
| CL-01 | `id` `type` `start` `duration` `offset` | 文字列・文字列・秒・秒・秒 | id は自動、type は `image`、start/duration/offset は 0 | 常時 |
| CL-02 | `src` `srcDuration` | 文字列・秒 | なし | 設定時のみ |
| CL-03 | `x` `y` | 数(0〜1 の割合) | 0.5 | 設定時のみ |
| CL-04 | `scale` `opacity` `volume` | 数 | 1 | 設定時のみ |
| CL-05 | `blur` | 数 | 0 | 設定時のみ |
| CL-06 | `w` `h` | 数 | 0.3 | 設定時のみ |
| CL-07 | `strength` `shape` `blurMode` `mosaicSize` | 数・文字列・文字列・数 | 24 / `"rect"` / `"blur"` / 12 | 設定時のみ |
| CL-08 | `text` `fontSize` `color` `outline` `font` | 文字列等 | fontSize = voice 64・他 80 / color `#ffffff` / outline `#000000` / font = 既定フォント一覧の先頭 | 設定時のみ |
| CL-09 | `rotation` `flipH` `flipV` `crop` | 数・Bool・Bool・`{l,t,r,b}` | 0 / false / false / なし | 既定でないときだけ |
| CL-10 | `keyframes` `transitionIn` `transitionOut` `effects` | 辞書・オブジェクト・配列 | なし | 空でないとき |
| CL-11 | `fadeIn` `fadeOut` `fadeCurve` `speed` `reverse` `keepPitch` `freeze` `speedRamp` `pan` `audioFx` | — | なし(等倍・フェードなし) | 設定時のみ(`audioFx` は空なら書かない) |
| CL-12 | `channelMode` `mouthDrive` | 文字列 | `downmix` / `all` | 既定と異なるときだけ |
| CL-13 | `locked` `muted` `disabled` `treatAsVoice` `speakingOnly` `followsProjectEnd` `playsAnimation` `frameBlend` `frameFlow` `stabilizeRoll` | Bool | false | **true のときだけ**書く |
| CL-14 | `stabilize` | 数(0〜1) | 0 | 0 を超えるときだけ(上限 1) |
| CL-15 | その他: `textStyle` `textAnim` `bubble` `counter` `valueRef` `duck` `visualizer` `figure` `mask` `meshWarp` `puppetWarp` `objectMask` `hslMask` `tracking` `blendMode` `group` `ruby` `note` `audioCategory` `subtitleText` `tachieId` `sceneId` `tracks` `voicevoxAccent` `charId` `subtitle` | — | なし | 設定時のみ |

> 検証条件: 既定のクリップは `id/type/start/duration/offset` の 5 キーだけを書く。CL-13 を true にすると各キーが現れ、false/既定値に戻すと消える(`testClipDefaultsAreOmittedAndFlagsAreWrittenOnlyWhenTrue`、`testClipOrDefaultValuesMatchTheDocumentedTable`)。

**3.6 Track(T-40 系)**

| ID | キー | 型 | 既定 | 書く条件 |
|---|---|---|---|---|
| TR-01 | `id` `name` `clips` | 文字列・文字列・配列 | 自動・空・空 | 常時 |
| TR-02 | `hidden` `muted` `locked` `solo` | Bool | なし | 設定されているとき(false でも設定値は書く。UI は標準に戻すとき nil にする) |
| TR-03 | `height` | `"small"` / `"large"` | なし(標準) | 設定時のみ。知らない値は標準として扱うが値は書き戻す |
| TR-04 | `volume` `pan` | 数 | 1(0〜2)/ 0(-1〜1) | 設定時のみ |

> 既定のレイヤーは「レイヤー1」〜「レイヤー5」の 5 つ。

**3.7 Character(§5.1 の項目一覧。「未決定」から外す)**

| ID | キー | 型 | 既定 | 書く条件 |
|---|---|---|---|---|
| CH-01 | `id` `name` `engine` `color` | 文字列 | 自動・空・`"voicevox"`・`"#4f8cff"` | 常時 |
| CH-02 | `speaker` | 整数 | なし | 設定時のみ |
| CH-03 | `voice` | 文字列 | なし | 設定時のみ(旧名の AquesTalk 声名は読み込み時に現行名へ置き換える) |
| CH-04 | `speed` `pitch` `intonation` | 数 | なし | 設定時のみ |
| CH-05 | `prePhonemeLength` `postPhonemeLength` `pauseLengthScale` | 数 | なし(0.03 / 0.03 / 0.65 として扱う) | 設定時のみ |
| CH-06 | `subtitleColor` | `#rrggbb` | なし | 設定時のみ |
| CH-07 | `imgBlink` `imgVowels` `expressions` `bounce` `rig` | — | なし | 設定時のみ(`imgVowels`/`expressions` は空なら書かない、`bounce` は true のときだけ) |
| CH-08 | 旧立ち絵の 7 キー(`imgClosed` `imgOpen` `x` `y` `scale` `flip` `alwaysShow`) | — | x 0.5(キャラ既定は 0.18/0.82/0.82)・y 0.72・scale 1・flip false(キャラ 1 は true)・alwaysShow true | **読んだファイルにあったキーを同じだけ書き戻す**。新規は全部書く。立ち絵素材への移行後は既定でないものだけ |

> 既定の 3 キャラ: 「キャラ1」`#e8384f`、「キャラ2」`#f2c53d`、「キャラ3」`#7ac943`。
> 検証条件: `testCharacterWritesLegacyPoseKeysOnlyWhenPresentOrNonDefault`。

**3.8 C-02(改)/ C-03(改)**

> **C-02(改)** 読み込みは、知らないキーがあっても失敗しない。**未知キーを書き戻す(保持する)のは、次の階層に限る**: 最上位、キャラクター、レイヤー(Track)、クリップ、マーカー、レビューコメント、シーン定義、立ち絵素材、カメラ、メディアメタデータ/スマートコレクション、エフェクト、トランジション、文字スタイル/アニメーション、各種マスク、図形、ビジュアライザ、ダッキング、メッシュ/パペット変形、音声エフェクト、キャラクターのリグ。**保持しない(読んで書くと未知キーが落ちる)階層**: 切り抜き(`crop`)、キーフレーム、速度ランプ、吹き出し(`bubble`)、`mediaHints` の値、`mediaFingerprints` の値、`multicams` の中身、ルビ、VOICEVOX アクセント、読み辞書、`tracking`。
> 型が違って読めなかった**既知キー**は、(a) `extra` へ退避して元の値のまま書き戻す項目(最上位の `targetTrackId` `multicams` `tachies` `camera` `mediaMetadata` `smartCollections` `readingDictionary` `scenes` `reviewComments` `scriptText`、レイヤーの `locked` `solo` `height` `volume` `pan`、クリップの速度まわり・装飾・マスク・変形・トランジション・エフェクト・キーフレーム・立ち絵系ほか)と、(b) 捨てて既定値に戻る項目(最上位の `rangeIn` `rangeOut` `subtitleY` `mediaPool` `mediaHints` `mediaFingerprints` `proxyLinks`、レイヤーの `hidden` `muted`、キャラクターの全項目、クリップの `text` `src` `x` `y` など基本項目)に分かれる。
> プラグイン由来の音声系フィールド(engine / speaker / 速度等)は、本体が型付きで読み書きする(コア版の実験の確定挙動とは別に、現行実装では保持だけでなく利用もする)。
> 検証条件: `testUnknownKeyPreservationBoundary`、`testWrongTypedKnownKeysAreSalvagedWhereDocumented`(いずれも現状の固定)。

> **C-03(改)** 本体が **JSON として解析できない**、最上位がオブジェクトでない、または上限(J-04)を超える場合は、部分読み込みをせずエラーとして提示する。値の**型違い・欠落**は破損とは扱わず、項目ごとに既定値(または保持)で読み、開く。
> 検証条件: `{broken` / `[]` / 空データ → エラー。`{"width":"wide"}` → 開ける(幅は既定)。

### 3.4 §4 素材参照

> **M-01(改)** 素材参照(`Clip.src`)は、取り込んだ**絶対パスのまま**でもよい。パッケージ保存したものは、本体ファイルのあるフォルダからの相対パス(`media/…`)とする。読み込み側は絶対・相対の両方を扱う。
> **M-01a(新)** 解決順: ①そのパスが存在する → ②相対パスならプロジェクトフォルダ基準(`..` やシンボリックリンクでフォルダ外に出る解決は拒否) → ③絶対パスで、プロジェクトのフォルダ名を含む場合は、その名前以降の相対部分を現在のプロジェクトフォルダ基準で解決(プロジェクトごと移動した場合の救済) → ④見つからなければ再リンク(§6.1)の対象。
> 検証条件: `testResolverRelativeAndEscapingPaths`、`ProjectPortabilityTests.testRelativeResolutionAfterMovingProjectFolder`。

> **§4.2(改)**: 「素材の識別情報」は次の JSON(キーは元の `src`)で、**任意**項目とする。

| 項目 | 必須 | 備考 |
|---|---|---|
| `fileName` | 任意 | 再リンクの候補絞り込み・表示用 |
| `size`(バイト数) | 任意 | ハッシュと併せて同一性判定に使う |
| `sha256` | 任意 | **SHA-256 の小文字 hex(64 文字)で確定**。ゴールデン: `"abc"` → `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad` |

> **M-04(改)** 識別情報(`mediaFingerprints`)は、**プロジェクトを保存するとき**に、読める素材について収集して記録する(欠けた素材は以前の記録を残す)。記録が無いプロジェクトも読める(無ければ空で書かない)。
> **M-05(改)** フィンガープリントがある素材は、「サイズが同じ候補のうち SHA-256 が一致するもの」だけを同一とみなす(ハッシュを読めない候補は同一としない)。フィンガープリントが無い素材だけ、ファイル名の一致(目印 `mediaHints[src].size` があればサイズも一致)で再リンクする。
> **§4.3(改)** プロキシ: 生成プロキシ(540p `.mp4`)は**アプリ側のローカルディレクトリ**に置かれ、名前は元ファイルのパス・更新日時・サイズから決まる。プロジェクトは外部プロキシへのパス参照 `proxyLinks`(プレビュー専用、書き出しは常に原本)だけを持つ。M-06/M-07 は「プロキシをプロジェクト内に資産として持つ運用」の将来要件として**未実装**と明記し、検証条件を「未実装のため検証条件なし」に差し替える(`03` B-05 の線引きも同様に見直す)。

### 3.5 §6.2 パッケージ化(R-05 確定)

> **R-05(改)** 同名ファイルの命名: コピー先は `media/<元のファイル名>`。**小文字化した名前で衝突判定**し、衝突したら 2 つ目から `<幹>-2.<拡張子>`、`<幹>-3.<拡張子>`、…(拡張子が無ければ `<名前>-2`)。同じ元パスは 1 回だけコピーして同じ宛先を使う。上書きによる取り違えは起きない。元ファイルが無いものはコピーせず、`src` はそのまま残す。
> 検証条件: `/a/x.mp4`・`/b/x.mp4`・`/c/X.MP4` → `media/x.mp4`・`media/x-2.mp4`・`media/X-3.MP4`(`testMediaPackageNamingRule`)。

### 3.6 §8.2 YMM4(A-11)

> 「現状」を次に差し替え: 「`Sources/MovieCutCore/YmmpImport.swift` として取り込み済み(上限 128MiB、構造が壊れていれば部分変換せずエラー、未対応アイテムは理由つきで読み飛ばしレポート)。変換スコープの表と I-03〜I-06 は据え置き。§8.3 の未確定事項(本文キー・ファイルパス・音量)は、実サンプルが得られるまで残す。」
> 追記候補(B-28): YMM4 書き出し、EXO 書き出し、FCPXML/Premiere の取り込みが現行実装にあることを §8 の見出し外の「他形式の入出力(参考)」として 1 段落。

### 3.7 §9 未決定事項一覧の整理

- **外してよい**: ハッシュアルゴリズム(SHA-256 で確定)/ フォルダ内部のファイル名・レイアウト詳細(F-01a で確定)/ プロジェクトが内包するキャラ定義・音声設定の項目一覧(§3.7 の表で確定)/ パッケージ化時の同名衝突の命名規則(R-05 で確定)。
- **残す**: 相対パスで表せない素材の扱い / アプリ側設定ファイルの形式・項目一覧(S-05)/ 再リンクの候補フォルダ指定方法 / 同時編集ロックの具体方式(C-01)/ 正式拡張子 / YMM4 読み込みの本文キー・ファイルパス・音量換算 / 同期サービス API の直接連携。
- **追加**: プロキシをプロジェクト内資産として持つか(現状は未実装、A-09/C-02)/ 拡張子の散在(E-01 の是正方針)/ 型違いの既知キーの退避方針の統一(N-1)/ `characters`・`tracks` が空のときの既定復活(N-5)を仕様として残すか。

---

## 4. README.md との矛盾と修正案

| 箇所 | 記述 | 矛盾 | 修正案 |
|---|---|---|---|
| §1 表(`01`) | 主な対象に「移行」 | `01` に移行(formatVersion)の節が無い | 3.3 の V-01〜V-05 を追加すれば解消。追加しないなら「移行」を外す |
| §3 P-03 | 「プロジェクト自己完結: キャラ定義・音声設定を内包」 | 矛盾なし(実装は内包) | 変更なし |
| §4.1 表「プロジェクト読み込み: プロジェクトフォルダ一式 + 期待される解釈結果」 | フォルダ一式を単位にする | 形式は単一ファイル(A-01)。素材を含める例以外はフォルダ不要 | 「プロジェクトファイル(必要なら素材を含むパッケージフォルダ)一式」に改める |
| §4.1 表「プロジェクト書き込み」 | 期待される書き出しファイル群(ハッシュ比較可能な正規形) | `encoded()` は sortedKeys+整形で決定的(J-01)。ただし Double の表記は Swift の `JSONEncoder` 依存 | G-04 への補足として「浮動小数の文字列表現は実装依存。比較は数値として行う(JSON を解析して比較)」を明記。本リポジトリのゴールデンもその方式 |
| §4.2 G-03 | ゴールデンデータにバージョンを付ける | 現状は版付きの一式が無い(C-04) | 現行テスト(`ProjectGoldenRoundTripTests`)をゴールデンの第一弾と位置づけ、版識別子の形式は引き続き未決定(README §6) |
| §5 用語「プロジェクトフォルダ」 | 「01 で定義するフォルダ形式のプロジェクト一式」 | A-01 | 「プロジェクトファイル(パッケージ化した場合は本体 + `media/` のフォルダ)」 |
| §5 用語「プロキシ」 | 「プロジェクトフォルダ内に置かれる低解像度代替素材。プロジェクト資産でありキャッシュではない(03)」 | A-09 | 「低解像度の代替素材。現行実装の生成プロキシはアプリ側ディレクトリに置く。プロジェクトは外部プロキシへのパス参照(`proxyLinks`)だけを持つ」 |
| §3 P-06 / §3.1 | 現行 Mac 版 footprint 90MB 等 | 範囲外 | — |

(関連: `03-memory-preview.md` B-05 は「プロジェクトフォルダ内のプロキシはプロジェクト資産」(`01` M-06)を前提にしている。`01` を更新したら `03` も追随が必要。)

---

## 5. 懸念(実装側の実バグ候補。修正はしていない)

| ID | 概要 | 再現条件 | 根拠 |
|---|---|---|---|
| N-1 | **型違いの既知キーの扱いが項目ごとに不揃い**。`extra` へ退避して書き戻す項目と、黙って捨てる項目が混在する。捨てる側: キャラクターの全項目、レイヤーの `hidden`/`muted`、クリップの `text`/`src`/`x` 等の基本項目、最上位の `rangeIn`/`rangeOut`/`subtitleY` | 例 `{"rangeIn":"x","mediaPool":5,"tracks":[{"hidden":"yes","clips":[{"type":"text","text":5}]}]}` を読んで保存 → 該当キーが消える。新しい版のアプリが別の型で書いた値を、古いアプリが読み書きすると失われる | `Project.swift:98-130,356-373,685-`、`testCharacterizationWrongTypedKeysWithoutSalvageAreDropped` |
| N-2 | **`mediaFingerprints`・`mediaHints`・`proxyLinks`・`mediaPool` は 1 要素の型違いで辞書/配列ごと消え、`extra` にも残らない**。再リンクの手がかり(フィンガープリント)が静かに失われる | `mediaFingerprints` の 1 件が `size` 欠落など → 全件が空で読まれ、保存で消える(ほかの素材の記録も失う)。素材が欠けた状態で保存すると、欠けた分は再収集もできない | `Project.swift:104-107`(`l.value(...) ?? [:]`)、`MediaFingerprint` は合成 Codable で厳格、`testCharacterizationBrokenFingerprintEntryDropsWholeDictionary` |
| N-3 | **`MediaPackage.plan` の取りこぼし**: ①`mediaHints` のキーは元の絶対パスのままで、クリップの `src` は相対(`media/…`)に書き換わる → 後で再リンクが `hints[src]`(`src` = 相対)を引いても当たらない。`mediaFingerprints` のキーも元の絶対パスのまま(書き換えなし、`MediaPackage.write` はフィンガープリントを付け直さない)。②トップレベルのトラックのクリップしか走査しない → 複合クリップ(`tracks`)・シーン(`scenes`)内の素材はコピーも相対化もされず、パッケージが自己完結しない。③`mediaPool` は書き換え・コピーなし(未使用素材が絶対パスのまま残る) | 複合クリップの中に動画を置き、パッケージ保存 → `media/` に入らず、パッケージを別マシンへ移すとリンク切れ | `MediaPackage.swift:48-60`(`for ti in p.tracks.indices { for ci in … }` のみ、`hints[src]` は元のパスをキーに作成)。動作は未実行(推定) |
| N-4 | **`MediaFingerprintCollector.referencedSources` が `project.allClips`(トップレベルのトラックのクリップのみ)を使う**。複合クリップ・シーン内の素材にはフィンガープリントが付かない(`ProjectModel+Proxy.swift` のコメントは「複合・シーンの中も含めて」集める設計) | 複合クリップ内の素材を使うプロジェクトを保存 → その素材の `mediaFingerprints` が無く、移動後は名前+サイズの後方互換でしか再リンクできない | `MediaFingerprint.swift:62-73`、`Project.swift:177`。未実行(推定。`MissingMedia.find` が入れ子を見るかは未確認) |
| N-5 | **`characters` / `tracks` が空だと読み込みで既定に戻る**。往復が恒等でない(キャラクターを全部消した/トラックを全部消した状態を保存しても、開くと既定の 3 人/5 層になる)。Electron 版との互換のための仕様だが、書いた内容と読んだ内容が違う | 全キャラクター削除 → 保存 → 開く → 「キャラ1〜3」が復活 | `Project.swift:99-101`、コメント「Electron 版: 空配列・欠落のときは既定に戻す」。仕様として残すなら明文化(§3.7 の「追加」) |
| N-6 | **クリップの `type` が文字列でないと `"unknown"` に置き換わって書き戻る**(元の値が失われる)。欠落は `image` に置き換わる | `{"type":5}` を読んで保存 → `"type":"unknown"`。`{}` → `"type":"image"` | `Project.swift:419,688`、`testMissingOrNonStringClipTypeFallsBack` |
| N-7 | **`extra` の数値は Double(`JSONValue.number`)**。2^53 を超える整数の未知キーは精度が落ちて書き戻る。キーフレーム・ルビ等の `extra` 無しの型は、そもそも正規化(クランプ)をかけて書き戻す(`Crop.normalized`、`Bubble` の `normalized`、`Marker.color` の既定色の省略、マーカー時刻の 0 以上へのクランプ など) | 範囲外の `crop` 値を読んで保存 → 範囲内に変わる。`marker.color: "teal"` → 消える | `JSONValue.swift:3-30`、`Project.swift:958-`、`Markers.swift:60-72`。「読んだものを書くと変わる」例。`ProjectFuzzTests` は 2 回目以降の書き換えの安定性だけを見ている |
| N-8 | **拡張子の取り残し**: `MediaPackage.write` が `".mcpjc"` をリテラル、`ProjectTemplate.fileExtension` が別定数。E-04 が想定する「定数 1 行の差し替え」で拡張子を変えても、パッケージ内の本体ファイルとテンプレートの拡張子だけ旧のままになる | `ProjectFileExtension.current` を変更してビルド → パッケージ書き出しは `.mcpjc` のまま | `MediaPackage.swift:76`、`ProjectTemplate.swift:8,102,137` |
| N-9 | **パッケージ書き出しは途中失敗でアトミックでない**: 素材を 1 つずつコピー(既存の宛先は削除してからコピー)し、そのあとに本体ファイルを書く。途中で失敗すると素材だけ書かれ本体が無い成果物が残る(コメントにも「途中の成果物は残す」とある)。F-03 は本体ファイルの保存のみを対象と読めば満たす | 容量不足などで途中失敗 | `MediaPackage.swift:66-79` |

(補足・懸念ではない観察: `Character.voice` は旧 AquesTalk 声名を読み込み時に現行名へ置き換えるため、旧名のファイルは読み書きでバイトが変わる(2 回目以降は安定)。`Lenient.int` は小数を四捨五入して Int にする(`speaker: 3.5` → 4)。)

---

## 6. ゴールデンテストの点検と追加

### 6.1 既存テストがカバーしている範囲

| ファイル | 固定している内容 |
|---|---|
| `ProjectFormatTests` | 版の書き込み(新規 = 2)、版 0/1/新しい版の読みと保存、`version(in:)` の厳密判定、`sourceFormat` が `==` に入らない、未知キーの保持(最上位・キャラ・マーカー・Track・Clip・Effect)、`extra` を持たない型で落ちること(`crop`・`bubble` の 2 つだけ)、新しい版の元の中身の世代バックアップ |
| `ProjectTests` | `rich.ymproj` の往復(全レベルの未知キーと未知 type `hologram`)、`{}` = 既定、型違いの寛容な読み(`fps:30.0`、`width:"bad"`)、Electron 版プロジェクトの読み、解像度のスケール、保存・読み込みのファイル往復 |
| `ProjectPortabilityTests` | フィンガープリントの同一/不同一、収集、相対解決・プロジェクト移動、`..` の拒否、再リンク(ハッシュ一致/同名異内容/読めない/名前+サイズ/一括)、フィンガープリント無しの後方互換、フィンガープリントの往復 |
| `ProjectVersionsTests` | 世代名・並び・保持数・間隔による置換・同一内容の重複なし・拡張子保持(`ymproj`)など(形式そのものではない) |
| `ProjectFuzzTests` | 固定シードの破壊で、クラッシュしない・読めたら書き直して同じバイト列・未知キー保持、深い入れ子(複合クリップ) |
| フィクスチャ | `Fixtures/*.ymproj` 一式、`golden-rich.json` / `golden-electron-made.json`(プロジェクト形式の期待値としては使われておらず、`OpticalFlowTests.swift:301` の走査にだけ現れる) |

### 6.2 不足(リスト)

1. 代表構成プロジェクトの **encode → decode → 再 encode のバイト一致**(冪等性)の明示テストが無い(ファジングは壊した入力のみ)。
2. **固定 JSON 文字列(ゴールデン)→ decode → encode の正規化比較**が無い。
3. **全クリップ種別(known 12 種 + 未知)の type 文字列の往復**の網羅が無い(`rich.ymproj` の 7 種 + hologram のみ)。
4. **既定値の省略**(トップレベル・クリップ・キャラクター・トラックの「書かない / 書く」)の網羅が無い。
5. **fps の整数/小数/文字列/分数の読みと書き**(クランプ含む)が無い(`ProjectTests` は `30.0` のみ)。
6. `formatVersion` の「0/1/2/新しい版/不正値」を**書き戻しの値まで**見るテストの追加(既存は一部)。
7. **型違いの既知キー**の「退避される/捨てられる」境界の固定が無い(N-1/N-2)。
8. **保持範囲**の固定が `crop` と `bubble` の 2 型だけ(`reviewComments`/`scenes`/`tachies`/`camera` の保持、`mediaHints` の値・`keyframes` の落ちる側が未固定)。
9. 壊れたファイル: 空データ・配列・文字列・深すぎる入れ子・クランプ(`sanitizeLoaded`)の固定が無い。
10. 拡張子の定数(`ProjectFileExtension`)のテストが無い。
11. **パッケージ命名規則**(R-05)のテストが無い。
12. SHA-256 の**既知ベクタ**(アルゴリズムの確定)が無い。
13. `MediaResolver.resolve` の解決順(相対・脱出拒否・欠落)の単体テストは `ProjectPortabilityTests` にあるが、`MediaPackage.plan` の出力との組み合わせは無し。

### 6.3 追加したテスト: `Tests/MovieCutCoreTests/ProjectGoldenRoundTripTests.swift`

XCTest + `@testable import MovieCutCore`。ID は全て固定文字列(`newId()` のランダム値に依存せず、`Project()` の既定キャラ・トラックの ID はそれが比較に入るテストでは固定または揃えて比較)。Date・辞書順に依存しない。JSON の比較は `JSONSerialization` 経由の `NSDictionary` 等価。バイト一致を見るのは同じ実装での encode→decode→encode のみ。**実行は未検証**(この VM に swift が無い)。

| テスト | 内容 | 不足リスト |
|---|---|---|
| `testRepresentativeProjectEncodeDecodeEncodeIsByteStable` | 3 トラック・5 種のクリップ・キャラ・マーカー・素材まわり入りの代表プロジェクトの冪等性 | 1 |
| `testEncodedFormatIsSortedPrettyAndDoesNotEscapeSlashes` | キー昇順・整形・`/` 非エスケープ | 1 |
| `testGoldenJSONDecodeEncodeKeepsEverything` | 固定 JSON → decode → encode を正規化比較(未知キー・未知 type・素材まわり含む) | 2 |
| `testEmptyObjectDecodesToDefaultsAndWritesRequiredKeys` | `{}` = 既定、書いたら必須 10 キー | 4 |
| `testDefaultProjectOmitsOptionalTopLevelKeys` / `testSettingOptionalTopLevelFieldsWritesTheirKeys` / `testDefaultCameraAndEmptyMediaMetadataAreNotWritten` | トップレベルの書く/書かない | 4 |
| `testClipDefaultsAreOmittedAndFlagsAreWrittenOnlyWhenTrue` / `testClipOrDefaultValuesMatchTheDocumentedTable` | クリップの既定値・true のときだけ書く | 4 |
| `testCharacterWritesLegacyPoseKeysOnlyWhenPresentOrNonDefault` / `testTrackWritesOptionalFlagsOnlyWhenSet` | キャラ・トラックの書く条件、既定 3 キャラ・5 層 | 4 |
| `testAllClipTypesRoundTripKeepingTypeStrings` / `testMissingOrNonStringClipTypeFallsBack` | 12 種 + `hologram` の往復、type 欠落/型違い | 3 |
| `testFpsIsWrittenAsIntegerWhenWholeAndDecimalOtherwise` / `testFpsInputFormsAndClamping` | fps の書き方・読み方・クランプ | 5 |
| `testFormatVersionRoundTrip` | 版の書き戻し(0/1/2/9/不正値) | 6 |
| `testWrongTypedKnownKeysAreSalvagedWhereDocumented` / `testCharacterizationWrongTypedKeysWithoutSalvageAreDropped` / `testCharacterizationBrokenFingerprintEntryDropsWholeDictionary` | 型違いの退避/脱落の境界(後 2 つは**現状の挙動の固定**。N-1/N-2 を直したら更新する) | 7 |
| `testUnknownKeyPreservationBoundary` | 保持される型・落ちる型の境界 | 8 |
| `testBrokenFilesThrowAndFieldLevelMismatchesDoNot` / `testDeepNestingIsRejected` / `testSanitizeClampsAbsurdValuesOnly` | 壊れたファイル・深さ・クランプ | 9 |
| `testProjectFileExtensionConstants` | 拡張子の定数 | 10 |
| `testSaveAndLoadSingleJSONFile` | 単一 JSON ファイルの保存・読み込み、保存後に一時ファイルが残らない | (基本形) |
| `testMediaPackageNamingRule` | 命名規則(大文字小文字・拡張子なし・重複・欠落) | 11 |
| `testFingerprintIsSHA256LowercaseHex` | SHA-256 既知ベクタ・小文字化・JSON キー | 12 |
| `testResolverRelativeAndEscapingPaths` | 相対解決・脱出拒否・欠落・空 | 13(一部) |

懸念 N-3/N-4(パッケージと入れ子クリップ)の再現テストは、実装挙動の固定になり修正を妨げるため**追加していない**(推定のため)。必要なら統括の判断で追加する。

---

## 7. 変更ファイル

- 追加: `docs/project-format-audit-r6.md`(本書)
- 追加: `Tests/MovieCutCoreTests/ProjectGoldenRoundTripTests.swift`
- 実装(`Sources/`)への変更: **なし**(コメント含め無し)
- 注: 指示書ファイルはコミット対象外として作業後に除去済み。本コミットに含まれるのは上記 2 ファイルのみ。
