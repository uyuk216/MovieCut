# UI 刷新プロトタイプ提案(feat/ui-refresh-proposal)

メイン画面まわりの見た目だけを刷新した試作。機能仕様・モデル・合成・書き出しのロジックは変えていない。採否は利用者が決める。

## 狙い

- ツールバーを macOS 標準のアイコン + ラベルに寄せ、ボタンの意味を一目で読めるようにする。
- 左パネル・インスペクタの縦長の節を開閉式にし、よく使う節だけが見える状態から始める。
- 色を意味トークンに集約し、外枠はシステムのセマンティック色、アクセントは `Color.accentColor` に統一する(タイムラインの機能色 `TimelinePalette` は対象外)。
- 状態表示をウィンドウ下部のステータスバーへ分け、ツールバーを操作だけにする。
- インスペクタの空状態(未選択・複数選択)を、何をすればよいかが分かる案内カードにする。

## 変更点一覧

### 項目1 ツールバーを SF Symbols へ
- `Sources/MovieCut/ContentView.swift` の `ToolbarBar` / `TransportBar`。
- 素材追加 `plus.rectangle.on.folder`、テキスト `textformat`、ぼかし `eye.slash`、分割 `scissors`、削除 `trash`。`.labelStyle(.titleAndIcon)` でアイコン + ラベル。
- 再生バーは `backward.end.fill` / `play.fill` / `pause.fill`(アイコンのみ。アクセシビリティ名は従来の題)。
- アクション・`.help`・`.disabled` の条件はそのまま。キーボードショートカットはツールバー側には元から無い(S / Delete / Home / Space は別系統)ため変更なし。`Title` 定数は試験が参照するため残した。

### 項目2 DisclosureGroup で節を開閉
- `Sources/MovieCut/InspectorView.swift`: 新部品 `MCDisclosure`(開閉状態を `@AppStorage` の `mc.disclosure.<key>` に保存)、環境値 `inspectorHidesSectionHeader`(外側の見出しと内側の `InspectorSection` 見出しの重複を消す)、`ClipInspector.disclose(...)`。
- `Sources/MovieCut/ContentView.swift` の `LeftPanel`(キャラクター)、`Sources/MovieCut/TachieSheets.swift` の `TachieListSection`(立ち絵素材)。
- 初期展開: タイミング / セリフ / 文字 / 文字のスタイル / 位置・変形 / ぼかし・ビジュアライザ・図形の各設定 / 音声(音量) / 左パネルのキャラクター。
- 初期折りたたみ: 注記 / グループ / 中身 / エフェクト / トランジション / 速度 / 手ぶれ補正 / 形のマスク / 立ち絵素材。
- 台本欄は高さが可変で常時使う主機能なので、開閉の対象にしていない。

### 項目3 配色トークン
- `Sources/MovieCut/DesignSystem.swift` の `MCDesign.Color` に `background` / `panelBackground` / `barBackground` / `divider` / `textSecondary` / `textTertiary` / `fieldBackground` / `accent` を追加(いずれもセマンティック色の別名)。
- `ContentView.swift`(背景・ツールバー背景・台本入力欄・ビジー表示)と `InspectorView.swift`(節見出し・案内カード)で直書きの色を置換。アクセントはもともと直書きの青が無く `Color.accentColor` 経由だったため、トークン名の統一のみ。
- `TimelinePalette`(`TimelineView.swift`)は触っていない。

### 項目4 ステータスバー
- `ContentView.swift` に `StatusBar` を新設し、`DockHost` の下に配置。左: `model.statusText`(従来ツールバー右端に出していた同じ値)、右: クリップ数(`project.allClips.count`)と解像度・fps(`TransportBar.chipText`)。
- ツールバーからは状態文を外し、`TransportBar` は `showsResolution: false` で呼ぶ(解像度・fps はステータスバーに常時出るため、従来の「狭い幅で省く」処理は不要になった)。`TransportBar` の既定値と `ToolbarBar.showsResolution(forWidth:)` は試験が参照するため残した。
- 挙動の差: 従来は状態文が空のときだけ「クリップ N 個」を左に出していた。刷新案では右に常時出す。

### 項目5 空状態カード
- `InspectorView.swift` の新部品 `InspectorGuideCard`(アイコン + 見出し + 説明文)。未選択は `cursorarrow.click.2`、複数選択は `square.on.square`(見出しは従来の「N個のクリップを選択中」、説明は従来のヒント文)。操作ボタンは従来どおり下に並ぶ。

## 現行との比較表

| 項目 | 現行 | 刷新案 |
|---|---|---|
| 1 ツールバー | 文字だけのボタン、再生バーは ⏮ ▶ ⏸ の絵文字 | SF Symbols + ラベル、再生バーは SF Symbols |
| 2 節の開閉 | 全節が常に展開(縦長) | DisclosureGroup。主要節のみ初期展開、状態は保存 |
| 3 配色 | 直書きの `Color(nsColor:)` と `MCDesign.Color` が混在 | 意味トークンに集約、アクセントは `Color.accentColor` |
| 4 状態表示 | ツールバー右端に状態文、解像度・fps は再生バー横(幅が狭いと省略) | 下部ステータスバー(左: 状態文、右: クリップ数・解像度・fps) |
| 5 空状態 | 1 行の文字、または太字 1 行 + 説明 | アイコン + 見出し + 説明のカード |

## リスク

- 実機で目視していない。`swift build` と `swift test` が通ることだけ確認した(下記)。
- SF Symbols の差: `plus.rectangle.on.folder` は macOS 13 以降(SF Symbols 4)。本アプリの対象は macOS 14 なので問題は出ない想定だが、`eye.slash` はぼかしの意味が弱く、意匠として代案(`aqi.medium` など)の検討余地がある。
- DisclosureGroup の状態保持: 開閉は節の key ごとに全クリップ共通で保存される(クリップを替えても保たれる反面、クリップ種別ごとに別の既定へ戻すことはできない)。折りたたまれた節の中身(注記の入力済み文字など)が見えなくなるため、注記が入っていても閉じて見える。
- 見出しの二重表示を環境値で抑えている。新しい節を足したとき、`hideHeader` の指定を忘れると見出しが重複する。
- 既存テストへの影響: `ToolbarBar.Title` / `TransportBar.Title` / `showsResolution` などを参照する試験があるため、これらは残した。テストの変更は不要だった。折りたたみ中の節の中身を木から探す試験を今後足すと、見つからない可能性がある。
- ダークモード: 画面全体は従来どおりダーク固定。セマンティック色(`underPageBackgroundColor` 等)のダーク時の見え方、ステータスバーとドック境界の見た目は未確認。ライトモードは対象外。
- ステータスバー分だけ中央領域の縦が約 22pt 減る。最小サイズ(1100×700)でのドックの収まりは、レイアウト試験は通ったが目視はしていない。
- 台本欄・立ち絵素材以外の左パネル、ドックのタブ見出し、各種シートは未着手。

## 採用する場合の統合手順の叩き台(実行はしない)

1. 基盤ブランチの最新を取り込んだうえで、feat/ui-refresh-proposal をその先頭へリベースして衝突を確認する(特に `ContentView.swift` / `InspectorView.swift` は他ブランチも触りやすい)。
2. 項目ごとに独立したコミットなので、採否が分かれる場合は該当コミットだけ `cherry-pick` する。依存関係: 項目3(トークン)は他の項目の前提。項目4(ステータスバー)は項目1のコミットで `TransportBar` を呼ぶ側と関係する。
3. 取り込み後に `swift build` と `swift test` を通し、実機で次を目視する: ダーク表示、最小サイズ(1100×700)、折りたたみの開閉、複数選択・未選択の案内カード、ステータスバー。
4. 目視で出た調整(ぼかしのアイコン、既定の展開、カードの文言)を別コミットで足してから 基盤ブランチへマージする。
