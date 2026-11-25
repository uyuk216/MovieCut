import SwiftUI
import AppKit
import MovieCutCore

// MARK: - 部品

/// 小さい見出し(タイミング / セリフ / …)。
struct InspectorSection: View {
    let title: String
    @Environment(\.inspectorHidesSectionHeader) private var hidden
    var body: some View {
        if hidden { EmptyView() } else { header }
    }
    private var header: some View {
        HStack(spacing: 8) {
            Text(L10n.t(title))
                .font(MCDesign.Font.calloutSemibold)
                .foregroundStyle(MCDesign.Color.textSecondary)
            Rectangle().fill(MCDesign.Color.divider).frame(height: 1)
        }
        .padding(.top, 5)
    }
}

private struct InspectorHidesSectionHeaderKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// true のとき InspectorSection は見出しを描かない(外側の DisclosureGroup が見出しを担うとき)。
    var inspectorHidesSectionHeader: Bool {
        get { self[InspectorHidesSectionHeaderKey.self] }
        set { self[InspectorHidesSectionHeaderKey.self] = newValue }
    }
}

/// 開閉できる節。開閉は key ごとに UserDefaults へ残る(クリップを替えても、再起動しても保たれる)。
struct MCDisclosure<Label: View, Content: View>: View {
    @AppStorage private var isOpen: Bool
    private let label: Label
    private let content: Content

    init(_ key: String, defaultOpen: Bool, @ViewBuilder label: () -> Label, @ViewBuilder content: () -> Content) {
        _isOpen = AppStorage(wrappedValue: defaultOpen, "mc.disclosure.\(key)")
        self.label = label()
        self.content = content()
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isOpen) {
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(.top, MCDesign.Spacing.xs)
        } label: { label }
    }
}

extension MCDisclosure where Label == Text {
    init(_ key: String, title: String, defaultOpen: Bool, @ViewBuilder content: () -> Content) {
        self.init(key, defaultOpen: defaultOpen, label: {
            Text(L10n.t(title)).font(.system(size: 12, weight: .semibold)).foregroundStyle(MCDesign.Color.textSecondary)
        }, content: content)
    }
}

/// 開閉できる内側の節(見出しクリックで開閉・状態は `mc.disclosure.<id>` に保存)。
/// 従来の `InspectorSection`(見出し+罫線だけで、中身は兄弟要素)の置き換え。中身はクロージャで包む。
/// id・既定の開閉・見出しは `InspectorSectionCatalog` から引く(title は動的な見出しのときだけ渡す)。
struct InspectorSubsection<Content: View>: View {
    private let def: InspectorSectionDefinition
    private let title: String?
    private let content: Content

    init(_ id: String, title: String? = nil, @ViewBuilder content: () -> Content) {
        self.def = InspectorSectionCatalog.require(id)
        self.title = title
        self.content = content()
    }

    var body: some View {
        MCDisclosure(def.id, defaultOpen: def.defaultOpen, label: {
            Text(L10n.t(title ?? def.title))
                .font(MCDesign.Font.calloutSemibold)
                .foregroundStyle(MCDesign.Color.textSecondary)
        }, content: { content })
    }
}

/// 最上位の開閉できる節(InspectorView の `disclose` と同じ作法: `MCDisclosure` + カタログの id)。
/// 他ファイルの節ビュー(トラッキング・マスク・カメラ等)が自前で使う。見出し・既定の開閉・保存キーはカタログから引く。
/// ロック中でも見出しは開閉できるよう、`.disabled` は中身の側に付けること。
struct InspectorTopSection<Content: View>: View {
    private let def: InspectorSectionDefinition
    private let content: Content

    init(_ id: String, @ViewBuilder content: () -> Content) {
        self.def = InspectorSectionCatalog.require(id)
        self.content = content()
    }

    var body: some View {
        MCDisclosure(def.id, title: def.title, defaultOpen: def.defaultOpen) { content }
    }
}

/// 空状態の案内カード(アイコン + 見出し + 説明文)。未選択・複数選択のインスペクタで使う。
struct InspectorGuideCard: View {
    let symbol: String
    let heading: String
    let message: String
    var body: some View {
        VStack(spacing: MCDesign.Spacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(MCDesign.Color.accent)
            Text(L10n.t(heading)).font(MCDesign.Font.headline)
            Text(L10n.t(message))
                .font(MCDesign.Font.callout)
                .foregroundStyle(MCDesign.Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(MCDesign.Spacing.l)
        .frame(maxWidth: .infinity)
        .background(MCDesign.Color.control, in: RoundedRectangle(cornerRadius: MCDesign.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: MCDesign.Radius.panel).stroke(MCDesign.Color.divider))
        .accessibilityElement(children: .combine)
    }
}

/// 項目のキーフレームの操作(◇ と ◀ ▶)に必要なもの。
struct KeyframeControl {
    var state: KeyframeEditing.KeyState
    var canPrev: Bool
    var canNext: Bool
    var toggle: () -> Void
    var prev: () -> Void
    var next: () -> Void
    /// ここのキーから次のキーまでのイージング(ここにキーがあり、次のキーもあるときだけ)。曲線エディタを出す。
    var ease: Ease? = nil
    var setEase: (Ease) -> Void = { _ in }
}

/// ◇(キーなし)/ ◆(ここにキーがある)/ 半塗り(動く項目だが、ここにキーは無い)。
struct KeyframeDiamond: View {
    let state: KeyframeEditing.KeyState
    let action: () -> Void

    static func symbol(_ s: KeyframeEditing.KeyState) -> String {
        switch s {
        case .none: return "diamond"
        case .between: return "diamond.lefthalf.filled"
        case .onKey: return "diamond.fill"
        }
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: Self.symbol(state))
                .font(MCDesign.Font.body)
                .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t(state == .onKey ? "ここのキーフレームを消す" : "ここにキーフレームを足す"))
        .accessibilityLabel(L10n.t(state == .onKey ? "キーフレームを消す" : "キーフレームを追加"))
    }
}

/// ラベルを上に置いた項目。`key` があれば、ラベルの横に ◀ ▶(動く項目のとき)、コントロールの右に ◇ を出す。
struct InspectorField<Content: View>: View {
    let label: String
    var trailing: String?
    var key: KeyframeControl?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Text(L10n.t(label)).font(MCDesign.Font.callout).foregroundStyle(.secondary)
                if let key, key.state != .none {
                    Button(action: key.prev) { Image(systemName: "chevron.left").font(MCDesign.Font.badge).frame(width: 16, height: 16).contentShape(Rectangle()) }
                        .buttonStyle(.plain).disabled(!key.canPrev).help(L10n.t("前のキーフレームへ"))
                    Button(action: key.next) { Image(systemName: "chevron.right").font(MCDesign.Font.badge).frame(width: 16, height: 16).contentShape(Rectangle()) }
                        .buttonStyle(.plain).disabled(!key.canNext).help(L10n.t("次のキーフレームへ"))
                }
                Spacer(minLength: 4)
                if let trailing { Text(trailing).font(.system(size: 12).monospacedDigit()).foregroundStyle(.primary) }
            }
            if let key {
                HStack(spacing: 2) {
                    content
                    if let ease = key.ease { EaseCurveButton(ease: ease, onCommit: key.setEase) }
                    KeyframeDiamond(state: key.state, action: key.toggle)
                }
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 数値の入力欄(Return・フォーカスが外れたときに確定、右のステッパーは連続編集)。
/// ステッパーは長押しで連続ステップする共通部品(PressHoldStepper)を使う:
/// 短押し 1 回、0.4 秒押し続けると 0.05 秒間隔で繰り返し、離すと即止まる。
/// 発火はすべて従来と同じ onStep を通るので、クランプ・ステップ幅・Undo の
/// まとめ方(coalesced 系は 1 回の長押しが 1 回の Undo)は従来どおり。
struct NumField: View {
    let value: Double
    var step: Double = 0.01
    var decimals: Int = 2
    let clamp: (Double) -> Double
    let onCommit: (Double) -> Void
    let onStep: (Double) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    static func format(_ v: Double, decimals: Int) -> String {
        var s = String(format: "%.\(decimals)f", v)
        if s.contains(".") { while s.hasSuffix("0") { s.removeLast() }; if s.hasSuffix(".") { s.removeLast() } }
        return s == "-0" ? "0" : s
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let v = Double(t), v.isFinite {
            // 受け渡すのは範囲に収めた値だけ(巨大値・NaN が変換先で落ちないように)
            onCommit(clamp(v))
            text = Self.format(clamp(v), decimals: decimals)
        } else {
            text = Self.format(value, decimals: decimals)
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 13).monospacedDigit())
                .focused($focused)
                .onSubmit { commit(); focused = false }     // Return で確定したら入力を終える(Space・Delete がまた効く)
                .onChange(of: focused) { _, now in if !now { commit() } }
            PressHoldStepper(onIncrement: { onStep(value + step) }, onDecrement: { onStep(value - step) })
        }
        .onAppear { text = Self.format(value, decimals: decimals) }
        .onChange(of: value) { _, v in if !focused { text = Self.format(v, decimals: decimals) } }
    }
}

/// スライダー(ラベルの右に現在の値)。ドラッグの間は Undo に積まず、離したときに 1 回だけ登録する。
struct LiveSlider: View {
    let label: String
    var key: KeyframeControl?
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let begin: () -> Void
    let change: (Double) -> Void
    let end: () -> Void

    var body: some View {
        InspectorField(label: label, trailing: format(value), key: key) {
            // step を渡すと目盛りが並んで見づらいので、丸めは自分でやる
            Slider(value: Binding(get: { value }, set: { change(step > 0 ? (($0 / step).rounded() * step) : $0) }), in: range) { editing in
                if editing { begin() } else { end() }
            }
            .controlSize(.small)
        }
    }
}

/// 色の欄(見本 + 16 進の表示)。
struct ColorField: View {
    let label: String
    let hex: String
    let onChange: (String) -> Void
    var body: some View {
        InspectorField(label: label) {
            HStack(spacing: 8) {
                ColorPicker("", selection: Binding(get: { Color(hex: hex) }, set: { onChange($0.hexString) }), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 56, height: 28)
                Text(hex.uppercased()).font(MCDesign.Font.monospaced(11)).foregroundStyle(.secondary)
            }
        }
    }
}

/// 複数行の入力欄。外れたとき(または Cmd+Return)に確定する。`live` のときは打つたびに反映する(Undo は 1 回にまとまる)。
struct MultilineField: View {
    let label: String
    let value: String
    var live = false
    var height: CGFloat = 72
    /// 増えたらこの欄にフォーカスを移す(タイムラインのダブルクリック)。
    var focusRequest = 0
    let onLive: (String) -> Void
    let onCommit: (String) -> Void

    @State private var draft = ""
    @State private var focused = false

    var body: some View {
        InspectorField(label: label) {
            PlainTextEditor(text: $draft, font: NSFont.systemFont(ofSize: MCDesign.FontSize.body), focusRequest: focusRequest, onFocusChange: { focused = $0 })
                .padding(4)
                .frame(height: height)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: focused ? 1.5 : 1))
                .onChange(of: draft) { _, d in if live && focused { onLive(d) } }
                .onChange(of: focused) { _, now in if !now { onCommit(draft) } }
                .background(
                    // Cmd+Return で確定(入力欄の外へはフォーカスを動かさない)
                    Button("") { if focused { onCommit(draft) } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .opacity(0).frame(width: 0, height: 0)
                )
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, v in if !focused { draft = v } }
    }
}

/// 立ち絵のサムネイル(大きな画像でも軽いよう、縮小して読む)。
struct PortraitThumb: View {
    let path: String?
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor))
            if let image {
                Image(nsImage: image).resizable().scaledToFit().padding(2)
            } else {
                Text(path == nil ? "なし" : "…").font(MCDesign.Font.subheadline).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 64, height: 64)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        .task(id: path) {
            guard let path else { image = nil; return }
            image = await Task.detached(priority: .utility) { Self.thumbnail(path) }.value
        }
    }

    nonisolated static func thumbnail(_ path: String) -> NSImage? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 192]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }
}

/// 縦スクロールバーを(オーバーレイではなく)いつも見える細いものにする。
struct ScrollerStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            var s: NSView? = v
            while let cur = s, !(cur is NSScrollView) { s = cur.superview }
            guard let sv = s as? NSScrollView else { return }
            sv.hasVerticalScroller = true
            sv.autohidesScrollers = false
            sv.scrollerStyle = .legacy
            sv.verticalScroller?.controlSize = .small
        }
    }
}

// MARK: - 右パネル

struct InspectorView: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var speakers: SpeakerCatalog

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.t("プロパティ")).font(.headline).padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    switch model.inspectorMode {
                    case .clip(let id):
                        ClipInspector(model: model, clipId: id).id(id)
                    case .multi(let n):
                        MultiSelectionInspector(model: model, count: n)
                    case .tachie(let id):
                        TachieInspector(model: model, tachieId: id).id(id)
                    case .character(let id):
                        CharacterInspector(model: model, speakers: speakers, charId: id).id(id)
                    case .none:
                        VStack(alignment: .leading, spacing: 10) {
                            InspectorGuideCard(symbol: "cursorarrow.click.2", heading: "クリップが選ばれていません", message: "クリップを選ぶと設定が出ます。")
                            CameraSection(model: model)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(ScrollerStyler())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - 複数選択(A6)

/// 複数のクリップを選んでいるときのプロパティ欄: 個数と、まとめてできる操作だけ(項目ごとの編集は 1 つ選んだときに)。
struct MultiSelectionInspector: View {
    @ObservedObject var model: ProjectModel
    let count: Int

    enum Title {
        static func selected(_ n: Int) -> String { String(format: L10n.t("%d個のクリップを選択中"), n) }
        static let duplicate = "複製"
        static let delete = "削除"
        static let rippleDelete = "すき間を詰めて削除"
        static let copy = "コピー"
        static let hint = "項目を編集するには、クリップを 1 つだけ選びます。移動・削除・コピーは選んだ全部にかかります。"
        static let all = [duplicate, delete, rippleDelete, copy]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            InspectorGuideCard(symbol: "square.on.square", heading: Title.selected(count), message: Title.hint)
            HStack(spacing: 8) {
                Button(Title.duplicate) { model.duplicateSelected() }
                Button(Title.delete) { model.deleteSelected() }
            }
            HStack(spacing: 8) {
                Button(Title.rippleDelete) { model.rippleDeleteSelected() }
                Button(Title.copy) { model.copySelection() }
            }
            HStack(spacing: 8) {
                Button(L10n.t("グループにする")) { model.groupSelectedClips() }
                Button(L10n.t("グループを解除")) { model.ungroupSelectedClips() }.disabled(!model.selectionHasGroup)
            }
            HStack(spacing: 8) {
                Button(model.selectionGroupAllDisabled ? "グループを有効にする" : "グループを無効にする") { model.toggleGroupDisabledSelected() }
                    .disabled(!model.selectionHasGroup)
            }
        }
        .disabled(model.isLocked)
    }
}

// MARK: - クリップのプロパティ

struct ClipInspector: View {
    @ObservedObject var model: ProjectModel
    let clipId: String
    @State private var showAccentSheet = false

    private var clip: Clip? { model.clip(clipId) }

    /// ◇ ◀ ▶ の操作(その種類のクリップで動かせない項目には出さない)。
    private func keyControl(_ key: String?) -> KeyframeControl? {
        guard let key, let c = clip, Animation.keys(for: c).contains(key) else { return nil }
        let rel = model.currentTime - c.start, tol = model.keyTolerance
        return KeyframeControl(
            state: model.keyState(key, of: c),
            canPrev: KeyframeEditing.previousKeyTime(c, key: key, before: rel, tolerance: tol) != nil,
            canNext: KeyframeEditing.nextKeyTime(c, key: key, after: rel, tolerance: tol) != nil,
            toggle: { model.toggleKeyframe(key, clipId: clipId) },
            prev: { model.seekKeyframe(forward: false, key: key) },
            next: { model.seekKeyframe(forward: true, key: key) },
            ease: KeyframeEditing.segmentEase(c, key: key, at: rel, tolerance: tol),
            setEase: { model.setKeyEase(key, $0, clipId: clipId) })
    }

    /// 項目の、再生ヘッドでの値(キーがあれば補間後)。
    private func shown(_ key: String?, _ f: ClipField?) -> Double {
        guard let c = clip else { return 0 }
        if let key { return model.animatedValue(key, of: c) }
        return f.map { $0.value(of: c) } ?? 0
    }

    // 数値欄 / スライダー(キーフレームで動かせる項目は、キーがあればここのキーを編集する)
    private func num(_ label: String, _ f: ClipField, step: Double = 0.01, decimals: Int = 2) -> some View {
        let key = f.animationKey
        return InspectorField(label: label, key: keyControl(key)) {
            NumField(value: shown(key, f), step: step, decimals: decimals,
                     clamp: { v in
                         if let key, let c = clip, Animation.isAnimated(key, in: c) { return Animation.clamp(key, v, type: c.type) }
                         return f.clamp(v)
                     },
                     onCommit: { key != nil ? model.setKeyed(key!, $0, clipId: clipId) : model.setClipField(f, $0, clipId: clipId) },
                     onStep: { key != nil ? model.coalescedKeyed(key!, $0, clipId: clipId) : model.coalescedClipField(f, $0, clipId: clipId) })
        }
    }

    private func slider(_ label: String, _ f: ClipField, step: Double, format: @escaping (Double) -> String) -> some View {
        let key = f.animationKey
        return LiveSlider(label: label, key: keyControl(key), value: shown(key, f), range: f.range, step: step, format: format,
                          begin: { model.beginGesture() },
                          change: { key != nil ? model.liveKeyed(key!, $0, clipId: clipId) : model.liveClipField(f, $0, clipId: clipId) },
                          end: { model.commitGesture(f.undoName) })
    }

    private func rotationField() -> some View {
        InspectorField(label: L10n.t("回転（°）"), key: keyControl("rotation")) {
            NumField(value: shown("rotation", nil), step: 1, decimals: 1,
                     clamp: { Animation.clamp("rotation", $0, type: clip?.type ?? .image) },
                     onCommit: { model.setKeyed("rotation", $0, clipId: clipId) },
                     onStep: { model.coalescedKeyed("rotation", $0, clipId: clipId) })
        }
    }

    private func flipToggles(_ c: Clip) -> some View {
        HStack(spacing: 14) {
            Toggle(L10n.t("左右反転"), isOn: Binding(get: { c.flipHOrDefault }, set: { model.setFlip(horizontal: true, $0, clipId: clipId) }))
            Toggle(L10n.t("上下反転"), isOn: Binding(get: { c.flipVOrDefault }, set: { model.setFlip(horizontal: false, $0, clipId: clipId) }))
        }
        .toggleStyle(.checkbox)
    }

    private func cropField(_ edge: CropEdge, _ c: Clip) -> some View {
        InspectorField(label: "\(edge.label)（%）") {
            NumField(value: edge.value(of: c.cropOrDefault) * 100, step: 1, decimals: 0, clamp: { min(max($0, 0), Crop.maxEdge * 100) },
                     onCommit: { model.setCropEdge(edge, $0 / 100, clipId: clipId) },
                     onStep: { model.coalescedCropEdge(edge, $0 / 100, clipId: clipId) })
        }
    }

    private func fontPicker(_ c: Clip) -> some View {
        InspectorField(label: L10n.t("フォント")) {
            Picker("", selection: Binding(get: { c.fontOrDefault }, set: { v in model.setClipProperty({ $0.font = v }, name: "フォントの変更", clipId: clipId) })) {
                ForEach(FontChoices.options(including: c.font), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
        }
    }

    private func colorField(_ label: String, _ c: Clip, outline: Bool) -> some View {
        ColorField(label: label, hex: outline ? c.outlineOrDefault : c.colorOrDefault) { hex in
            model.coalescedClipProperty({ if outline { $0.outline = hex } else { $0.color = hex } }, name: outline ? "縁の色の変更" : "色の変更", clipId: clipId)
        }
    }

    /// 撮影・試験用: 音声エフェクトの節を全部開く。
    static var expandAudioFx = false

    private static let pct: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    private static let px: (Double) -> String = { "\(Int($0.rounded()))px" }

    private func kindName(_ t: ClipType) -> String {
        switch t {
        case .image: return "画像"
        case .video: return "動画"
        case .audio: return "音声"
        case .text: return "テキスト"
        case .voice: return "ボイス"
        case .blur: return "ぼかし範囲"
        case .adjustment: return "調整レイヤー"
        case .visualizer: return "音声ビジュアライザ"
        case .shape: return "図形"
        case .compound: return "複合クリップ"
        case .scene: return "シーンクリップ"
        case .tachie: return "立ち絵"
        default: return t.rawValue
        }
    }

    var body: some View {
        if let c = clip {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(kindName(c.type)).font(MCDesign.Font.calloutSemibold)
                    if let src = c.src, c.type != .voice {
                        Text(URL(fileURLWithPath: src).lastPathComponent)
                            .font(MCDesign.Font.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                disclose("timing", "タイミング", hideHeader: true) {
                    HStack(alignment: .top, spacing: 10) {
                        num("開始（秒）", .start, step: 0.1, decimals: 3)
                        num("長さ（秒）", .duration, step: 0.1, decimals: 3)
                    }
                    if let usage = SourceUsage.label(of: c) {
                        HStack(spacing: 8) {
                            Text(usage).font(MCDesign.Font.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button(L10n.t("この区間へ")) { model.showSourceUsage() }
                                .controlSize(.small)
                                .help(L10n.t("再生位置をクリップの頭へ移し、元素材の使用範囲を状態欄に出す"))
                        }
                    }
                }
                disclose("note", "注記", hideHeader: true) {
                    ClipNoteField(model: model, clipId: clipId, note: c.note ?? "").id(clipId)
                }
                disclose("group", "グループ", hideHeader: true) { groupSection(c) }
                TrackingSection(model: model, clip: c)
                if c.type == .voice { disclose("voice", "セリフ") { voiceSections(c) } }
                if c.type == .text { disclose("text", "文字", hideHeader: true) { textSections(c) } }
                if c.type == .tachie { TachieClipSection(model: model, clip: c) }
                if TextStyleEditing.supports(c.type) { disclose("textStyle", "文字のスタイル") { TextStyleInspector(model: model, store: model.textStyles, clipId: clipId) } }
                if [ClipType.image, .video, .text, .compound, .scene, .tachie].contains(c.type) { disclose("place", "位置・変形") { placeSections(c) } }
                if c.type == .compound { disclose("compound", "中身", hideHeader: true) { compoundSection(c) } }
                if c.type == .scene { disclose("scene", "シーン", hideHeader: true) { sceneSection(c) } }
                if EffectEditing.supports(c.type) { disclose("effect", "エフェクト", hideHeader: true) { effectSections(c) } }
                if TransitionEditing.supportsVideo(c.type) { disclose("transition", "トランジション", hideHeader: true) { transitionSections(c) } }
                if c.type == .blur { disclose("blur", "ぼかし") { blurSections(c) } }
                if c.type == .visualizer { disclose("visualizer", "ビジュアライザ") { visualizerSections(c) } }
                if c.type == .shape { disclose("shape", "図形") { shapeSections(c) } }
                if Clip.supportsSpeed(c.type) { disclose("speed", c.isFreeze ? "フリーズフレーム" : "速度", hideHeader: true) { speedSections(c) } }
                if StabilizeEditing.supports(c) { disclose("stabilize", "手ぶれ補正", hideHeader: true) { stabilizeSections(c) } }
                if Clip.supportsEffects(c.type) { disclose("mask", "形のマスク", hideHeader: true) { maskSections(c) } }
                ObjectMaskSection(model: model, clip: c)
                HSLMaskSection(model: model, clip: c)
                if Clip.supportsWarp(c.type) { warpSections(c) }
                if (c.type == .video || c.type == .audio) && !c.isFreeze {
                    disclose("audio", "音声", hideHeader: true) {
                        InspectorSection(title: L10n.t("音声"))
                        slider("音量", .volume, step: 0.05, format: Self.pct)
                        audioFadeFields(c)
                        AudioFxPanel(model: model, clipId: clipId, forceExpanded: Self.expandAudioFx)
                    }
                }
                CameraSection(model: model)
            }
            .onDisappear { model.flushCoalesced() }
        }
    }

    /// 節を DisclosureGroup で包む。hideHeader が true なら、中の InspectorSection の見出しは出さない(外側の見出しと重なるため)。
    @ViewBuilder private func disclose<C: View>(_ key: String, _ title: String, hideHeader: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        let def = InspectorSectionCatalog.require("inspector.\(key)")  // 既定の開閉と保存キーはカタログが持つ
        MCDisclosure(def.id, title: title, defaultOpen: def.defaultOpen) {
            content().environment(\.inspectorHidesSectionHeader, hideHeader)
        }
    }

    /// グループの状態と付け外し。グループのクリップは、タイムラインで押すと全員が選ばれる。
    @ViewBuilder private func groupSection(_ c: Clip) -> some View {
        InspectorSection(title: L10n.t("グループ"))
        if let g = c.group {
            Text(String(format: L10n.t("グループのメンバー（%d 個）"), ClipGrouping.members(of: g, in: model.project).count))
                .font(MCDesign.Font.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(L10n.t("全員を選択")) { model.selectGroupMembers(of: clipId) }
                Button(L10n.t("このクリップを外す")) { model.setClipProperty(\.group, to: nil, name: "グループから外す", clipId: clipId) }
            }
            HStack(spacing: 8) {
                Button(model.groupAllDisabled(g) ? "グループを有効にする" : "グループを無効にする") {
                    model.selectGroupMembers(of: clipId)
                    model.toggleGroupDisabledSelected()
                }
            }
            .controlSize(.small)
            .disabled(model.isLocked)
        } else {
            Text(L10n.t("グループに入っていません。2 つ以上選んで「グループにする」と、押したときに全員が選ばれ、ドラッグでまとめて動かせます。"))
                .font(MCDesign.Font.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func voiceSections(_ c: Clip) -> some View {
        InspectorSection(title: "セリフ")
        InspectorField(label: "キャラクター") {
            Picker("", selection: Binding(get: { c.charId ?? "" }, set: { v in Task { await model.setVoiceCharacter(v, clipId: clipId) } })) {
                if !model.project.characters.contains(where: { $0.id == c.charId }) { Text("（消えたキャラ）").tag(c.charId ?? "") }
                ForEach(model.project.characters) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
        }
        MultilineField(label: "読み上げ文", value: c.text ?? "", focusRequest: model.textFocusRequest, onLive: { _ in }, onCommit: { t in Task { await model.setVoiceText(t, clipId: clipId) } })
        Text("入力欄を離れるか Cmd+Return で、音声を作り直します。口パクは読み上げ文の音に合わせます。")
            .font(MCDesign.Font.subheadline).foregroundStyle(.secondary)
        // アクセントは VOICEVOX 系のキャラだけ(AquesTalk では出さない)
        if let engine = model.project.characters.first(where: { $0.id == c.charId })?.engine, VoicevoxFamily.isVoicevoxStyleEngine(engine) {
            Button(c.voicevoxAccent == nil ? "アクセント編集…" : "アクセント編集…（保存済み）") { showAccentSheet = true }
                .controlSize(.small)
                .disabled(model.isLocked)
                .sheet(isPresented: $showAccentSheet) { VoicevoxAccentSheet(model: model, clipId: clipId) }
        }
        let noSubtitle = c.subtitleText == ""
        Toggle("字幕なし", isOn: Binding(get: { noSubtitle }, set: { v in model.setVoiceSubtitleText(clipId: clipId, text: v ? "" : nil) }))
            .toggleStyle(.checkbox)
            .disabled(model.isLocked)
            .help("このセリフには字幕を出しません（読み上げだけ）")
        MultilineField(label: "字幕文（空なら読み上げ文と同じ）", value: noSubtitle ? "" : (c.subtitleText ?? ""), focusRequest: 0, onLive: { _ in },
                       onCommit: { t in model.setVoiceSubtitleText(clipId: clipId, text: t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : t) })
            .disabled(noSubtitle || model.isLocked)
        InspectorSubsection("inspector.voice.subtitle") {
        Toggle("字幕を出す", isOn: Binding(get: { c.subtitleOrDefault }, set: { v in model.setClipProperty({ $0.subtitle = v }, name: "字幕の切り替え", clipId: clipId) }))
            .toggleStyle(.checkbox)
        num("字幕の大きさ（px）", .fontSize, step: 1, decimals: 0)
        fontPicker(c)
        }
        InspectorSubsection("inspector.voice.audio") {
        slider("音量", .volume, step: 0.05, format: Self.pct)
        audioFadeFields(c)
        AudioFxPanel(model: model, clipId: clipId, forceExpanded: Self.expandAudioFx)
        }
    }

    // MARK: 速度

    /// 速度の Picker の選択肢の値(0 = プリセット以外)。
    private static func speedPresetTag(_ v: Double) -> Double { ClipTiming.presets.first { abs($0 - v) < 1e-9 } ?? 0 }

    @ViewBuilder private func speedSections(_ c: Clip) -> some View {
        InspectorSection(title: c.isFreeze ? "フリーズフレーム" : "速度")
        if c.isFreeze {
            Text(String(format: L10n.t("素材の %.3f 秒のコマを止めています。長さは「長さ（秒）」で変えられます。"), c.offset))
                .font(MCDesign.Font.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            let sp = c.effectiveSpeed
            InspectorField(label: L10n.t("速度（倍）")) {
                HStack(spacing: 6) {
                    Picker("", selection: Binding(get: { Self.speedPresetTag(sp) }, set: { v in if v > 0 { model.setSpeed(v, clipId: clipId) } })) {
                        ForEach(ClipTiming.presets, id: \.self) { Text("×" + ClipTiming.formatSpeed($0)).tag($0) }
                        if Self.speedPresetTag(sp) == 0 { Text(L10n.t("その他")).tag(0.0) }
                    }
                    .labelsHidden()
                    .frame(width: 84)
                    NumField(value: sp, step: 0.05, decimals: 2,
                             clamp: { ClipTiming.clampSpeed($0) },
                             onCommit: { model.setSpeed($0, clipId: clipId) },
                             onStep: { model.coalescedSpeed($0, clipId: clipId) })
                }
            }
            LiveSlider(label: "つまみで調整", value: sp, range: ClipTiming.minSpeed...ClipTiming.maxSpeed, step: 0.05, format: { "×" + ClipTiming.formatSpeed($0) },
                       begin: { model.beginGesture() },
                       change: { model.liveSpeed($0, clipId: clipId) },
                       end: { model.commitGesture(ProjectModel.speedUndoName) })
            Toggle(L10n.t("逆再生"), isOn: Binding(get: { c.effectiveReverse }, set: { model.setReverse($0, clipId: clipId) }))
                .toggleStyle(.checkbox)
                .disabled(c.rampPoints != nil)
                .help(L10n.t("速度ランプがあるあいだは使えません"))
            Toggle(L10n.t("音程を保つ"), isOn: Binding(get: { c.keepPitchOrDefault }, set: { model.setKeepPitch($0, clipId: clipId) }))
                .toggleStyle(.checkbox)
                .disabled(sp == 1 || c.rampPoints != nil)
                .help(L10n.t("オフにすると、速くしたぶん音が高く、遅くしたぶん低くなります（速度ランプの音は音程が速度に従います）"))
            HStack(spacing: 6) {
                Text(L10n.t("元の長さ → 新しい長さ")).font(MCDesign.Font.callout).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(ClipTiming.lengthReadout(for: c)).font(.system(size: 12).monospacedDigit())
            }
            rampSection(c)
            if c.type == .video {
                HStack(spacing: 6) {
                    Text(L10n.t("コマの補間（速度が 1 未満のとき）")).font(MCDesign.Font.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Picker("", selection: Binding(get: { c.frameInterpolation }, set: { model.setFrameInterpolation($0, clipId: clipId) })) {
                        ForEach(FrameInterpolation.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 230)
                    .disabled(c.effectiveReverse)
                }
                .help(L10n.t("スローモーションのコマ落ちを滑らかにします。ブレンドは前後のコマの重ね合わせ、オプティカルフローは動きを推定して動きに沿った中間のコマを作ります（重い処理なので、最初のコマは少し待ちます）"))
            }
        }
    }

    /// シーンクリップ専用表示(R2-3): 参照先シーンの名前と中身の概要(レイヤー・クリップ・尺・参照数)。
    /// 中身の編集は「シーンを開く」から(この場では直さない。複合クリップの節と同じ流儀)。
    @ViewBuilder private func sceneSection(_ c: Clip) -> some View {
        InspectorSection(title: L10n.t("シーン"))
        if let sid = c.sceneId, let scene = model.rootProject.scene(withId: sid) {
            Text(String(format: L10n.t("シーン「%@」を参照しています。シーンの中身を直すと、参照しているすべてのクリップに反映されます。"), scene.name))
                .font(MCDesign.Font.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let summary = SceneClipDisplay.summary(for: c, in: model.rootProject) {
                Text(summary)
                    .font(MCDesign.Font.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(L10n.t("シーンを開く")) { _ = model.enterScene(sid) }
                    .disabled(model.isLocked || model.isInsideScene || model.isInsideCompound)
                Button(L10n.t("シーン一覧…")) { model.openSceneList() }
                    .disabled(model.isLocked)
            }
            .controlSize(.small)
        } else {
            Text(L10n.t("参照先のシーンが見つかりません。このクリップは描画も音声も出ません。"))
                .font(MCDesign.Font.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 複合クリップの中身の概要(編集は、まとめを解除して子のクリップを直す)。
    @ViewBuilder private func compoundSection(_ c: Clip) -> some View {
        InspectorSection(title: L10n.t("中身"))
        let kids = c.tracks ?? []
        let n = kids.reduce(0) { $0 + $1.clips.count }
        Text(String(format: L10n.t("レイヤー %d・クリップ %d。位置・効果・トランジションは、この複合クリップ全体にかかります。中身を直すには「複合クリップを解除」します。"), kids.count, n))
            .font(MCDesign.Font.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// 手ぶれ補正(映像クリップ)。オンオフは強さ 0 と同じ(0 はファイルに書かない)。つまみは 1 回の Undo。
    @ViewBuilder private func stabilizeSections(_ c: Clip) -> some View {
        InspectorSection(title: L10n.t("手ぶれ補正"))
        Toggle(L10n.t("映像を滑らかにする（縁は少し拡大して隠す）"), isOn: Binding(get: { c.stabilizeStrength > 0 }, set: { on in
            model.setStabilizeStrength(on ? StabilizeEditing.defaultStrength : 0, clipId: clipId)
        }))
        .toggleStyle(.checkbox)
        .help(L10n.t("解析は初回の表示のあいだに背景で行い、終わるまでは補正なしで表示します"))
        if c.stabilizeStrength > 0 {
            Toggle(L10n.t("傾きと拡大縮小も補正する"), isOn: Binding(get: { c.stabilizeRollOn }, set: { on in
                model.setStabilizeRotationZoom(on, clipId: clipId)
            }))
            .toggleStyle(.checkbox)
            .help(L10n.t("回転とズームのぶれも直します。オフのときは平行移動だけ直します(解析は軽くなります)"))
            LiveSlider(label: "強さ", value: c.stabilizeStrength, range: 0...1, step: 0.05, format: Self.pct,
                       begin: { model.beginGesture() },
                       change: { model.liveStabilizeStrength($0, clipId: clipId) },
                       end: { model.commitGesture(ProjectModel.stabilizeStrengthUndoName) })
        }
    }

    /// 形のマスク(矩形・楕円・ペン・反転・羽根)。オフは nil(ファイルに書かない)。ドラッグは 1 回の Undo。
    @ViewBuilder private func maskSections(_ c: Clip) -> some View {
        InspectorSection(title: L10n.t("形のマスク"))
        Toggle(L10n.t("形で切り抜く（外は透明）"), isOn: Binding(get: { c.mask != nil }, set: { on in
            model.setClipMask(on ? ClipMask() : nil, clipId: clipId)
        }))
        .toggleStyle(.checkbox)
        if let m = c.mask {
            Picker(L10n.t("形"), selection: Binding(get: { m.shape }, set: { s in
                model.setMaskShape(s, clipId: clipId)
            })) {
                Text(L10n.t("矩形")).tag("rect")
                Text(L10n.t("楕円")).tag("ellipse")
                Text(L10n.t("ペン")).tag("pen")
            }
            .pickerStyle(.segmented)
            .disabled(model.isLocked)
            if m.shape == "pen" {
                penMaskSections(m)
            } else {
                maskSlider("横位置", m.x, \.x, range: 0...1)
                maskSlider("縦位置", m.y, \.y, range: 0...1)
                maskSlider("幅", m.w, \.w, range: 0.01...1)
                maskSlider("高さ", m.h, \.h, range: 0.01...1)
            }
            maskSlider("羽根（ぼかし）", m.feather, \.feather, range: 0...1)
            Toggle(L10n.t("反転（中を透明にする）"), isOn: Binding(get: { m.invert }, set: { on in
                model.setMaskField(clipId: clipId) { $0.invert = on }
            }))
            .toggleStyle(.checkbox)
        }
    }

    /// ペンマスクの点の編集: 追加・削除、各点のアンカーと入る/出るハンドルの位置。
    /// 点の移動はプレビュー上でもドラッグできる(アンカーはハンドルごと動く)。
    @ViewBuilder private func penMaskSections(_ m: ClipMask) -> some View {
        Text(L10n.t("プレビューで点をドラッグして形を作ります。点の追加・削除とハンドルの調整は下で行えます。"))
            .font(MCDesign.Font.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Button(L10n.t("点を追加")) { model.addPenPoint(clipId: clipId) }
            .controlSize(.small)
            .disabled(model.isLocked || m.points.count >= ClipMask.maxPoints)
        ForEach(Array(m.points.enumerated()), id: \.offset) { i, pt in
            HStack(spacing: 6) {
                Text(String(format: L10n.t("点%d"), i + 1)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                Button(L10n.t("ハンドルをまっすぐにする")) { model.resetPenHandles(index: i, clipId: clipId) }
                    .controlSize(.mini)
                    .disabled(model.isLocked || pt.isCorner)
                Button(L10n.t("削除")) { model.removePenPoint(index: i, clipId: clipId) }
                    .controlSize(.mini)
                    .disabled(model.isLocked || m.points.count <= 3)
            }
            penSlider(L10n.t("点の横"), pt.x, index: i) { p, v in p.x = v }
            penSlider(L10n.t("点の縦"), pt.y, index: i) { p, v in p.y = v }
            penSlider(L10n.t("入るハンドルの横"), pt.inX, index: i) { p, v in p.inX = v }
            penSlider(L10n.t("入るハンドルの縦"), pt.inY, index: i) { p, v in p.inY = v }
            penSlider(L10n.t("出るハンドルの横"), pt.outX, index: i) { p, v in p.outX = v }
            penSlider(L10n.t("出るハンドルの縦"), pt.outY, index: i) { p, v in p.outY = v }
        }
    }

    /// ペンの点・ハンドル 1 座標のスライダー(ドラッグは 1 回の Undo)。値は割合(0〜1)。
    private func penSlider(_ label: String, _ value: Double, index: Int, _ change: @escaping (inout MaskPoint, Double) -> Void) -> some View {
        LiveSlider(label: label, value: value, range: 0...1, step: 0.01, format: Self.pct,
                   begin: { model.beginGesture() },
                   change: { v in model.liveMaskField(clipId: clipId) { mask in
                       mask.ensurePenPoints()
                       guard mask.points.indices.contains(index) else { return }
                       change(&mask.points[index], v)
                   } },
                   end: { model.commitGesture(ProjectModel.maskUndoName) })
    }

    // MARK: メッシュ変形・パペット変形(数値編集 + プレビュー上のドラッグ + キーフレーム)

    @ViewBuilder private func warpSections(_ c: Clip) -> some View {
        InspectorTopSection("inspector.warpMesh") {
        Toggle(L10n.t("格子で変形する"), isOn: Binding(get: { c.meshWarp != nil }, set: { on in
            if on { model.ensureMeshWarp(clipId: clipId) } else { model.clearMeshWarp(clipId: clipId) }
        }))
        .toggleStyle(.checkbox)
        if let m = c.meshWarp {
            HStack(spacing: 12) {
                LabeledStepperRow(label: "列 \(m.cols)",
                                  onIncrement: { model.liveMeshGrid(cols: StepperValue.stepped(m.cols, by: 1, in: MeshWarp.minGrid...MeshWarp.maxGrid), rows: m.rows, clipId: clipId) },
                                  onDecrement: { model.liveMeshGrid(cols: StepperValue.stepped(m.cols, by: -1, in: MeshWarp.minGrid...MeshWarp.maxGrid), rows: m.rows, clipId: clipId) },
                                  onPressBegan: { model.beginStepperSession() },
                                  onPressEnded: { model.commitStepperSession(ProjectModel.warpUndoName) })
                LabeledStepperRow(label: "行 \(m.rows)",
                                  onIncrement: { model.liveMeshGrid(cols: m.cols, rows: StepperValue.stepped(m.rows, by: 1, in: MeshWarp.minGrid...MeshWarp.maxGrid), clipId: clipId) },
                                  onDecrement: { model.liveMeshGrid(cols: m.cols, rows: StepperValue.stepped(m.rows, by: -1, in: MeshWarp.minGrid...MeshWarp.maxGrid), clipId: clipId) },
                                  onPressBegan: { model.beginStepperSession() },
                                  onPressEnded: { model.commitStepperSession(ProjectModel.warpUndoName) })
            }
            .disabled(model.isLocked)
            ForEach(Array(m.points.enumerated()), id: \.offset) { i, pt in
                let home = m.home(index: i)
                HStack(spacing: 6) {
                    Text(String(format: L10n.t("点%d（%d,%d）"), i + 1, Int(home.x * Double(m.cols - 1)) + 1, Int(home.y * Double(m.rows - 1)) + 1))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    Button(L10n.t("元に戻す")) { model.resetMeshPoint(index: i, clipId: clipId) }
                        .controlSize(.mini)
                        .disabled(model.isLocked || (abs(pt.x - home.x) < 1e-9 && abs(pt.y - home.y) < 1e-9))
                }
                warpSlider("横", model.animatedValue(WarpKey.mesh(i, .x), of: c), key: WarpKey.mesh(i, .x)) { v in model.liveMeshAxis(clipId: clipId, index: i, axis: .x, v) }
                warpSlider("縦", model.animatedValue(WarpKey.mesh(i, .y), of: c), key: WarpKey.mesh(i, .y)) { v in model.liveMeshAxis(clipId: clipId, index: i, axis: .y, v) }
            }
            Text(L10n.t("制御点を元の位置からずらすと、その周りが引っ張られて変形します。全点が元の位置のときは変形しません。プレビュー上でも制御点をドラッグでき、◇ でキーフレームを付けると位置が時間で動きます。"))
                .font(MCDesign.Font.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        }
        InspectorTopSection("inspector.warpPuppet") {
        Toggle(L10n.t("ピンで変形する"), isOn: Binding(get: { c.puppetWarp != nil }, set: { on in
            if on { model.ensurePuppetWarp(clipId: clipId) } else { model.clearPuppetWarp(clipId: clipId) }
        }))
        .toggleStyle(.checkbox)
        if let pw = c.puppetWarp {
            HStack(spacing: 8) {
                Button(L10n.t("ピンを追加（中央）")) { model.addPuppetPin(fixed: false, clipId: clipId) }
                Button(L10n.t("固定ピンを追加")) { model.addPuppetPin(fixed: true, clipId: clipId) }
            }
            .controlSize(.small)
            .disabled(model.isLocked || pw.pins.count >= PuppetWarp.maxPins)
            warpSlider("影響半径", pw.radius, range: PuppetWarp.radiusRange) { v in model.livePuppetRadius(clipId: clipId, v) }
            ForEach(Array(pw.pins.enumerated()), id: \.offset) { i, pin in
                HStack(spacing: 6) {
                    Text(String(format: L10n.t("ピン%d"), i + 1)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    Toggle(L10n.t("固定"), isOn: Binding(get: { pin.fixed }, set: { model.setPuppetPinFixed(index: i, $0, clipId: clipId) }))
                        .toggleStyle(.checkbox)
                    Button(L10n.t("削除")) { model.removePuppetPin(index: i, clipId: clipId) }
                        .controlSize(.mini)
                }
                .disabled(model.isLocked)
                if pin.fixed {
                    Text(String(format: L10n.t("元の位置（%d%%, %d%%）に固定されています"), Int(pin.hx * 100), Int(pin.hy * 100)))
                        .font(MCDesign.Font.subheadline).foregroundStyle(.secondary)
                } else {
                    warpSlider("横", model.animatedValue(WarpKey.pin(i, .x), of: c), key: WarpKey.pin(i, .x)) { v in model.livePuppetAxis(clipId: clipId, index: i, axis: .x, v) }
                    warpSlider("縦", model.animatedValue(WarpKey.pin(i, .y), of: c), key: WarpKey.pin(i, .y)) { v in model.livePuppetAxis(clipId: clipId, index: i, axis: .y, v) }
                }
            }
            Text(L10n.t("ピンはプレビュー上でもドラッグでき、クリップの中をダブルクリックするとその場所にピンが増えます（Shift+ダブルクリックで固定ピン）。ピンを動かすと、影響半径の内側が滑らかに追従します。固定ピンの周りは動きません。◇ でキーフレームを付けると位置が時間で動きます。"))
                .font(MCDesign.Font.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        }
    }

    private func warpSlider(_ label: String, _ value: Double, range: ClosedRange<Double> = -0.5...1.5, key: String? = nil, change: @escaping (Double) -> Void) -> some View {
        LiveSlider(label: label, key: keyControl(key), value: value, range: range, step: 0.01, format: Self.pct,
                   begin: { model.beginGesture() },
                   change: change,
                   end: { model.commitGesture(ProjectModel.warpUndoName) })
    }

    private func maskSlider(_ label: String, _ value: Double, _ key: WritableKeyPath<ClipMask, Double>, range: ClosedRange<Double>) -> some View {
        LiveSlider(label: label, value: value, range: range, step: 0.01, format: Self.pct,
                   begin: { model.beginGesture() },
                   change: { v in model.liveMaskField(clipId: clipId) { $0[keyPath: key] = v } },
                   end: { model.commitGesture(ProjectModel.maskUndoName) })
    }

    /// 速度ランプ(時間で速さが変わる)の点の一覧。点ごとに時刻(クリップの頭から)と速度を直せる。どの操作も Undo は 1 回。
    @ViewBuilder private func rampSection(_ c: Clip) -> some View {
        if let pts = c.rampPoints {
            Text(L10n.t("速度ランプ（点のあいだは各点の進み方でつなぎます。音は音程が速度に従います）"))
                .font(MCDesign.Font.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(pts.enumerated()), id: \.offset) { i, p in
                HStack(spacing: 6) {
                    Text("\(i + 1)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 14)
                    NumField(value: p.t, step: 0.05, decimals: 2,
                             clamp: { min(max($0, 0), c.duration) },
                             onCommit: { v in model.setSpeedRampPoint(clipId: clipId, index: i, t: v) },
                             onStep: { v in model.setSpeedRampPoint(clipId: clipId, index: i, t: v) })
                    Text(L10n.t("秒 ×")).font(MCDesign.Font.subheadline).foregroundStyle(.secondary)
                    NumField(value: p.v, step: 0.05, decimals: 2,
                             clamp: { ClipTiming.clampSpeed($0) },
                             onCommit: { v in model.setSpeedRampPoint(clipId: clipId, index: i, v: v) },
                             onStep: { v in model.setSpeedRampPoint(clipId: clipId, index: i, v: v) })
                    if i < pts.count - 1 {
                        Picker("", selection: Binding(get: { p.ease }, set: { model.setSpeedRampEase(clipId: clipId, index: i, ease: $0) })) {
                            ForEach(Ease.presets, id: \.ease) { preset in Text(preset.label).tag(preset.ease) }
                            if !Ease.presets.contains(where: { $0.ease == p.ease }) { Text(L10n.t("カスタム")).tag(p.ease) }
                        }
                        .labelsHidden().fixedSize().help(L10n.t("この点から次の点までの進み方（イージング）"))
                    }
                    Button(L10n.t("削除")) { model.removeSpeedRampPoint(clipId: clipId, index: i) }
                        .disabled(pts.count <= 2)
                }
            }
            HStack(spacing: 6) {
                Button(L10n.t("点を追加")) { model.addSpeedRampPoint(clipId: clipId, at: c.duration / 2) }
                Button(L10n.t("ランプをやめる")) { model.clearSpeedRamp(clipId: clipId) }
            }
        } else if c.isFreeze == false, SpeedEditing.supports(c) {
            Button(L10n.t("速度ランプを作る（いまの速度のまま点を 2 つ置く）")) { model.makeSpeedRamp(clipId: clipId) }
        }
    }

    // MARK: エフェクト

    private static func effectFormat(_ s: EffectParamSpec) -> (Double) -> String {
        switch s.unit {
        case .percent: return { "\(Int(($0 * 100).rounded()))%" }
        case .px: return { "\(Int($0.rounded()))px" }
        case .degrees: return { "\(Int($0.rounded()))°" }
        case .mode: return { $0 >= 0.5 ? "ぼかし" : "モザイク" }
        case .toggle: return { $0 >= 0.5 ? "オン" : "オフ" }
        case .aperture: return { ApertureShape(value: $0).label }
        case .radialMode: return { $0 >= 0.5 ? "回転" : "ズーム" }
        case .plain: return { s.step >= 1 ? "\(Int($0.rounded()))" : String(format: "%.2f", $0) }
        }
    }

    private func effectSlider(_ c: Clip, _ i: Int, _ s: EffectParamSpec) -> some View {
        let key = EffectKey.make(i, s.key)
        return LiveSlider(label: s.label, key: keyControl(key), value: model.animatedValue(key, of: c), range: s.range, step: s.step, format: Self.effectFormat(s),
                          begin: { model.beginGesture() },
                          change: { model.liveKeyed(key, $0, clipId: clipId) },
                          end: { model.commitGesture("エフェクトの変更") })
    }

    private func iconButton(_ symbol: String, help: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.5))
        .disabled(!enabled || model.isLocked)
        .help(help)
        .accessibilityLabel(help)
    }

    /// LUT のファイル名と状態(見つからない・読めないときは赤字)。
    @ViewBuilder private func lutFileRow(_ e: Effect, index: Int) -> some View {
        let path = e.path ?? ""
        let status: LUTCache.Status? = path.isEmpty ? nil : LUTCache.shared.status(atPath: path)
        HStack(spacing: 6) {
            Text(path.isEmpty ? "ファイル未選択" : (path as NSString).lastPathComponent)
                .font(MCDesign.Font.subheadline).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(status == .ok ? Color.secondary : Color.red)
                .help(path)
            Spacer(minLength: 4)
            Button(L10n.t("選ぶ…")) { model.chooseAndLoadLUT(clipId: clipId, effectIndex: index) }
                .controlSize(.small).disabled(model.isLocked)
                .help(L10n.t("LUT の .cube ファイルを選ぶ"))
        }
        if status == .missing { Text(L10n.t("ファイルが見つかりません（何もかかりません）")).font(.system(size: 10)).foregroundStyle(.red) }
        if status == .invalid { Text(L10n.t(".cube として読めません（何もかかりません）")).font(.system(size: 10)).foregroundStyle(.red) }
    }

    /// 色調転写の参照画像の名前と状態(見つからない・読めないときは赤字)。
    @ViewBuilder private func colorTransferFileRow(_ e: Effect, index: Int) -> some View {
        let path = e.path ?? ""
        let status: ReferenceColorCache.Status? = path.isEmpty ? nil : ReferenceColorCache.shared.status(atPath: path)
        HStack(spacing: 6) {
            Text(path.isEmpty ? "参照画像未選択" : (path as NSString).lastPathComponent)
                .font(MCDesign.Font.subheadline).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(status == .ok ? Color.secondary : Color.red)
                .help(path)
            Spacer(minLength: 4)
            Button(L10n.t("選ぶ…")) { model.chooseColorTransferReference(clipId: clipId, effectIndex: index) }
                .controlSize(.small).disabled(model.isLocked)
                .help(L10n.t("色調の手本にする画像を選ぶ"))
        }
        if status == .missing { Text(L10n.t("ファイルが見つかりません（何もかかりません）")).font(.system(size: 10)).foregroundStyle(.red) }
        if status == .invalid { Text(L10n.t("画像として読めません（何もかかりません）")).font(.system(size: 10)).foregroundStyle(.red) }
    }

    @ViewBuilder private func effectCard(_ c: Clip, _ i: Int) -> some View {
        let e = c.effects[i]
        let kind = e.known
        // プラグインエフェクト(F-1): 内蔵の種類でなければ、プラグインの記述子で名前と引数を出す。
        let pluginDesc = kind == nil ? model.pluginEffectDescriptor(for: e.kind) : nil
        let canReset: Bool = {
            var p = c
            if EffectEditing.reset(&p, at: i) { return true }
            if let pluginDesc { var q = c; return EffectEditing.reset(&q, at: i, descriptor: pluginDesc) }
            return false
        }()
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                Toggle("", isOn: Binding(get: { e.enabled }, set: { model.setEffectEnabled($0, at: i, clipId: clipId) }))
                    .toggleStyle(.checkbox).labelsHidden().help(L10n.t("オン/オフ"))
                Text(kind?.label ?? pluginDesc?.label ?? "未対応: \(e.kind)")
                    .font(MCDesign.Font.calloutSemibold)
                    .foregroundStyle((kind == nil && pluginDesc == nil) || !e.enabled ? Color.secondary : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                iconButton("arrow.counterclockwise", help: "初期値に戻す", enabled: canReset) { model.resetEffect(at: i, clipId: clipId) }
                iconButton("chevron.up", help: "上へ（先にかかる）", enabled: i > 0) { model.moveEffect(at: i, by: -1, clipId: clipId) }
                iconButton("chevron.down", help: "下へ（後にかかる）", enabled: i < c.effects.count - 1) { model.moveEffect(at: i, by: 1, clipId: clipId) }
                iconButton("xmark", help: "このエフェクトを外す") { model.removeEffect(at: i, clipId: clipId) }
            }
            if let kind {
                VStack(alignment: .leading, spacing: 6) {
                    if kind == .colorCurves {
                        // カラーカーブは汎用スライダ列の代わりにカーブエディタを出す
                        ColorCurvesInspector(model: model, clip: c, index: i, clipId: clipId)
                    } else {
                        ForEach(kind.params, id: \.key) { effectSlider(c, i, $0) }
                    }
                    if kind.defaultColor != nil {
                        ColorField(label: kind == .chromaKey ? "抜く色" : "色", hex: e.colorOrDefault) { model.coalescedEffectColor($0, at: i, clipId: clipId) }
                    }
                    if kind == .lut { lutFileRow(e, index: i) }
                    if kind == .colorTransfer { colorTransferFileRow(e, index: i) }
                }
                .opacity(e.enabled ? 1 : 0.45)
            } else if let pluginDesc {
                // プラグインエフェクトの引数(記述子の仕様。編集の経路は内蔵と同じ fx.<番号>.<引数>)。
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pluginDesc.params, id: \.key) { effectSlider(c, i, $0) }
                }
                .opacity(e.enabled ? 1 : 0.45)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }

    @ViewBuilder private func effectSections(_ c: Clip) -> some View {
        InspectorSection(title: L10n.t("エフェクト"))
        if c.effects.isEmpty {
            Text(L10n.t("エフェクトはありません")).font(MCDesign.Font.callout).foregroundStyle(.secondary)
        }
        ForEach(0..<c.effects.count, id: \.self) { effectCard(c, $0) }
        HStack(spacing: 8) {
            Menu {
                ForEach(EffectKind.allCases, id: \.rawValue) { k in Button(k.label) { model.addEffect(k, clipId: clipId) } }
                if !AppServices.pluginEffectDescriptors.isEmpty {
                    Divider()
                    Section(L10n.t("プラグイン")) {
                        ForEach(AppServices.pluginEffectDescriptors, id: \.id) { d in Button(d.label) { model.addPluginEffect(d, clipId: clipId) } }
                    }
                }
            } label: { Text(L10n.t("＋ 追加")) }
                .menuStyle(.button)
                .fixedSize()
                .disabled(model.isLocked)
            Menu {
                ForEach(EffectPreset.allCases, id: \.rawValue) { p in Button(p.title) { model.applyEffectPreset(p) } }
            } label: { Text(L10n.t("プリセット")) }
                .menuStyle(.button)
                .fixedSize()
                .disabled(model.isLocked)
            Spacer()
        }
        .controlSize(.small)
    }

    // MARK: トランジションと音声フェード

    /// 種類の Picker の選択肢の値: "" = なし、それ以外は kind の文字列(知らない種類もそのまま選択中として出す)。
    /// 種類が多いので、グループ(フェード・移動/ワイプ/ルールワイプ/演出)ごとに見出しを付けて並べる。
    private func kindPicker(_ c: Clip, _ edge: TransitionEdge) -> some View {
        let cur = TransitionEditing.transition(c, edge)
        return Picker("", selection: Binding(
            get: { cur?.kind ?? "" },
            set: { v in model.setTransitionKind(v.isEmpty ? nil : TransitionKind(rawValue: v), edge: edge, clipId: clipId) })) {
            Text(L10n.t("なし")).tag("")
            ForEach(TransitionCategory.allCases, id: \.rawValue) { cat in
                Section(cat.label) {
                    ForEach(TransitionKind.allCases.filter { $0.category == cat }, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
            }
            if let cur, cur.known == nil { Text(String(format: L10n.t("（未対応: %@）"), cur.kind)).tag(cur.kind) }
        }
        .labelsHidden()
    }

    private func easePicker(_ tr: MovieCutCore.Transition, _ edge: TransitionEdge) -> some View {
        Picker("", selection: Binding(get: { tr.ease }, set: { model.setTransitionEase($0, edge: edge, clipId: clipId) })) {
            ForEach(TransitionEditing.easeChoices, id: \.label) { Text($0.label).tag($0.ease) }
            if !TransitionEditing.easeChoices.contains(where: { $0.ease == tr.ease }) { Text(L10n.t("（その他）")).tag(tr.ease) }
        }
        .labelsHidden()
    }

    @ViewBuilder private func transitionRow(_ c: Clip, _ edge: TransitionEdge) -> some View {
        let tr = TransitionEditing.transition(c, edge)
        HStack(alignment: .center, spacing: 8) {
            Text(edge.label).font(MCDesign.Font.callout).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
            kindPicker(c, edge)
        }
        if let tr {
            HStack(alignment: .top, spacing: 10) {
                InspectorField(label: L10n.t("長さ（秒）")) {
                    NumField(value: tr.effectiveDuration(clipDuration: c.duration), step: 0.1, decimals: 2,
                             clamp: { MovieCutCore.Transition.clampedDuration($0, clipDuration: c.duration) },
                             onCommit: { model.setTransitionDuration($0, edge: edge, clipId: clipId) },
                             onStep: { model.coalescedTransitionDuration($0, edge: edge, clipId: clipId) })
                }
                InspectorField(label: L10n.t("進み方")) { easePicker(tr, edge) }
            }
            if tr.known?.isRuleWipe == true {
                HStack(alignment: .top, spacing: 10) {
                    InspectorField(label: L10n.t("やわらかさ")) {
                        NumField(value: tr.ruleSoftness, step: 0.01, decimals: 2,
                                 clamp: { min(max($0, 0), MovieCutCore.RuleWipeMath.maxSoftness) },
                                 onCommit: { model.setTransitionRuleSoftness($0, edge: edge, clipId: clipId) },
                                 onStep: { model.coalescedTransitionRuleSoftness($0, edge: edge, clipId: clipId) })
                    }
                    if tr.known == .ruleCustom {
                        InspectorField(label: L10n.t("ルール画像")) {
                            TextField(L10n.t("素材の場所"), text: Binding(
                                get: { tr.ruleSource ?? "" },
                                set: { model.setTransitionRuleSource($0.isEmpty ? nil : $0, edge: edge, clipId: clipId) }))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
            if tr.known == .morphCut {
                InspectorField(label: L10n.t("モーフの強さ")) {
                    NumField(value: tr.morphParameters.strength, step: 0.05, decimals: 2,
                             clamp: { min(max($0, 0), 1) },
                             onCommit: { model.setTransitionMorphStrength($0, edge: edge, clipId: clipId) },
                             onStep: { model.coalescedTransitionMorphStrength($0, edge: edge, clipId: clipId) })
                }
                Toggle(L10n.t("顔の位置合わせを優先"), isOn: Binding(
                    get: { tr.morphParameters.facePriority },
                    set: { model.setTransitionMorphFacePriority($0, edge: edge, clipId: clipId) }))
                    .font(MCDesign.Font.callout)
            }
        }
    }

    @ViewBuilder private func transitionSections(_ c: Clip) -> some View {
        InspectorSection(title: L10n.t("トランジション"))
        transitionRow(c, .in)
        transitionRow(c, .out)
        if TransitionEditing.supportsAudio(c.type) {
            Toggle(L10n.t("映像のトランジションと同じ長さで音声もフェード"),
                   isOn: Binding(get: { TransitionEditing.isAudioLinked(c) }, set: { model.setAudioLinked($0, clipId: clipId) }))
                .toggleStyle(.checkbox)
                .font(MCDesign.Font.callout)
                .disabled(!c.hasTransition && !TransitionEditing.isAudioLinked(c))
        }
    }

    @ViewBuilder private func audioFadeFields(_ c: Clip) -> some View {
        HStack(alignment: .top, spacing: 10) {
            InspectorField(label: L10n.t("フェードイン（秒）")) {
                NumField(value: c.fadeInOrDefault, step: 0.1, decimals: 2, clamp: { min(max($0, 0), c.duration) },
                         onCommit: { model.setAudioFade($0, edge: .in, clipId: clipId) },
                         onStep: { model.coalescedAudioFade($0, edge: .in, clipId: clipId) })
            }
            InspectorField(label: L10n.t("フェードアウト（秒）")) {
                NumField(value: c.fadeOutOrDefault, step: 0.1, decimals: 2, clamp: { min(max($0, 0), c.duration) },
                         onCommit: { model.setAudioFade($0, edge: .out, clipId: clipId) },
                         onStep: { model.coalescedAudioFade($0, edge: .out, clipId: clipId) })
            }
        }
        if c.hasAudioFade {
            InspectorField(label: L10n.t("フェードの曲線")) {
                Picker("", selection: Binding(get: { c.fadeIsEqualPower }, set: { model.setFadeCurve(equalPower: $0, clipId: clipId) })) {
                    Text(L10n.t("直線")).tag(false)
                    Text(L10n.t("等パワー")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    @ViewBuilder private func textSections(_ c: Clip) -> some View {
        InspectorSection(title: L10n.t("文字"))
        MultilineField(label: "文字", value: c.text ?? "", live: true, focusRequest: model.textFocusRequest,
                       onLive: { t in model.coalescedClipProperty({ $0.text = t }, name: "文字の変更", clipId: clipId) },
                       onCommit: { t in model.flushCoalesced(); model.setClipProperty({ $0.text = t }, name: "文字の変更", clipId: clipId) })
        num("大きさ（px）", .fontSize, step: 1, decimals: 0)
        HStack(alignment: .top, spacing: 10) {
            colorField("色", c, outline: false)
            colorField("縁の色", c, outline: true)
        }
        fontPicker(c)
    }

    @ViewBuilder private func placeSections(_ c: Clip) -> some View {
        InspectorSubsection("inspector.place.position") {
        HStack(alignment: .top, spacing: 10) {
            num("横位置", .x)
            num("縦位置", .y)
        }
        }
        InspectorSubsection("inspector.place.transform") {
        HStack(alignment: .top, spacing: 10) {
            num("拡大", .scale, step: 0.05)
            rotationField()
        }
        flipToggles(c)
        }
        if c.type != .tachie {
            InspectorSubsection("inspector.place.crop") {
            HStack(alignment: .top, spacing: 10) {
                cropField(.left, c)
                cropField(.top, c)
            }
            HStack(alignment: .top, spacing: 10) {
                cropField(.right, c)
                cropField(.bottom, c)
            }
            }
        }
        Button { model.resetTransform(clipId: clipId) } label: { Text(L10n.t("変形をリセット")).frame(maxWidth: .infinity) }
            .controlSize(.small)
            .disabled(model.isLocked || !Self.hasTransform(c))
            .help(L10n.t("回転・反転・切り抜き・拡大を元に戻します"))
        InspectorSubsection("inspector.place.look") {
        slider("不透明度", .opacity, step: 0.01, format: Self.pct)
        slider("ぼかし（px）", .blur, step: 1, format: Self.px)
        InspectorField(label: L10n.t("合成方法")) { blendPicker(c) }
        }
    }

    /// 下のレイヤーとの合成方法(ブレンドモード)。未設定 = 通常。
    private func blendPicker(_ c: Clip) -> some View {
        Picker("", selection: Binding(get: { c.blendMode?.rawValue ?? "" },
                                      set: { v in model.setClipProperty(\.blendMode, to: ClipBlendMode(rawValue: v), name: "合成方法の変更", clipId: clipId) })) {
            Text(L10n.t("通常")).tag("")
            ForEach(ClipBlendMode.allCases, id: \.rawValue) { m in Text(m.label).tag(m.rawValue) }
        }
    }

    /// 「変形をリセット」で戻るものがあるか。
    static func hasTransform(_ c: Clip) -> Bool {
        var probe = c
        return KeyframeEditing.resetTransform(&probe)
    }

    @ViewBuilder private func blurSections(_ c: Clip) -> some View {
        InspectorSubsection("inspector.blur.range") {
        HStack(alignment: .top, spacing: 10) {
            num("中心 横", .x)
            num("中心 縦", .y)
        }
        HStack(alignment: .top, spacing: 10) {
            num("幅", .w)
            num("高さ", .h)
        }
        InspectorField(label: L10n.t("形")) {
            Picker("", selection: Binding(get: { c.shapeOrDefault }, set: { v in model.setClipProperty({ $0.shape = v }, name: "ぼかしの形の変更", clipId: clipId) })) {
                Text(L10n.t("四角")).tag("rect")
                Text(L10n.t("楕円")).tag("ellipse")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        }
        InspectorSubsection("inspector.blur.look") {
        InspectorField(label: L10n.t("方式")) {
            Picker("", selection: Binding(get: { c.blurModeOrDefault }, set: { v in model.setClipProperty({ $0.blurMode = v == "blur" ? nil : v }, name: "ぼかしの方式の変更", clipId: clipId) })) {
                Text(L10n.t("ぼかし")).tag("blur")
                Text(L10n.t("モザイク")).tag("mosaic")
                Text(L10n.t("絞り")).tag("bokeh")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        if c.blurModeOrDefault == "bokeh" {
            InspectorField(label: L10n.t("絞りの形")) {
                Picker("", selection: Binding(get: { c.bokehShapeOrDefault }, set: { v in model.setBokehShape(v, clipId: clipId) })) {
                    ForEach(ApertureShape.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .help(L10n.t("背景のボケが、この形の円盤になります（明るい光ほどはっきり見えます）"))
            }
        }
        if c.blurModeOrDefault == "mosaic" {
            slider("ブロックの大きさ（px）", .mosaicSize, step: 1, format: Self.px)
        } else {
            slider("強さ（px）", .strength, step: 1, format: Self.px)
        }
        }
    }
}

extension ClipInspector {
    /// 音声ビジュアライザ: 範囲(x・y・w・h は動かせる)と見た目(棒/波、色、本数)。
    @ViewBuilder func visualizerSections(_ c: Clip) -> some View {
        let vz = c.visualizerOrDefault
        InspectorSubsection("inspector.visualizer.range") {
        HStack(alignment: .top, spacing: 10) {
            num("中心 横", .x)
            num("中心 縦", .y)
        }
        HStack(alignment: .top, spacing: 10) {
            num("幅", .w)
            num("高さ", .h)
        }
        }
        InspectorSubsection("inspector.visualizer.input") {
        InspectorField(label: L10n.t("見方")) {
            Picker("", selection: Binding(get: { vz.modeOrDefault }, set: { v in model.setClipProperty({ $0.visualizer = Self.vizUpdated($0.visualizer) { $0.mode = v } }, name: "ビジュアライザの見方の変更", clipId: clipId) })) {
                Text(L10n.t("音量")).tag("level")
                Text(L10n.t("スペクトル")).tag("spectrum")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help(L10n.t("音量: 全体の大きさで動く。スペクトル: 左が低い音・右が高い音で、周波数ごとに動く"))
        }
        InspectorField(label: L10n.t("音声")) {
            let sources = model.project.allClips.filter { [ClipType.audio, .voice, .video].contains($0.type) && $0.src != nil }
            Picker("", selection: Binding(get: { vz.source ?? "" }, set: { v in model.setClipProperty({ $0.visualizer = Self.vizUpdated($0.visualizer) { $0.source = v.isEmpty ? nil : v } }, name: "ビジュアライザの入力音声の変更", clipId: clipId) })) {
                Text(L10n.t("全体のミックス")).tag("")
                ForEach(sources, id: \.id) { s in
                    Text(((s.src ?? "") as NSString).lastPathComponent).tag(s.id)
                }
                if let cur = vz.source, !sources.contains(where: { $0.id == cur }) {
                    Text(L10n.t("（見つからないクリップ）")).tag(cur)
                }
            }
            .labelsHidden()
            .help(L10n.t("選んだ音声クリップだけの音で動かします。「全体のミックス」は書き出しと同じ合成音声"))
        }
        }
        InspectorSubsection("inspector.visualizer.look") {
        InspectorField(label: L10n.t("形")) {
            Picker("", selection: Binding(get: { vz.styleOrDefault }, set: { v in model.setClipProperty({ $0.visualizer = Self.vizUpdated($0.visualizer) { $0.style = v } }, name: "ビジュアライザの形の変更", clipId: clipId) })) {
                Text(L10n.t("棒")).tag("bars")
                Text(L10n.t("波")).tag("wave")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        ColorField(label: "色", hex: vz.colorOrDefault) { hex in
            model.coalescedClipProperty({ $0.visualizer = Self.vizUpdated($0.visualizer) { $0.color = hex } }, name: "ビジュアライザの色の変更", clipId: clipId)
        }
        InspectorField(label: L10n.t("本数")) {
            LabeledStepperRow(label: String(format: L10n.t("%d 本"), vz.countOrDefault),
                              onIncrement: { model.liveClipProperty({ $0.visualizer = Self.vizUpdated($0.visualizer) { $0.count = StepperValue.stepped(vz.countOrDefault, by: 1, in: Visualizer.countRange) } }, name: "ビジュアライザの本数の変更", clipId: clipId) },
                              onDecrement: { model.liveClipProperty({ $0.visualizer = Self.vizUpdated($0.visualizer) { $0.count = StepperValue.stepped(vz.countOrDefault, by: -1, in: Visualizer.countRange) } }, name: "ビジュアライザの本数の変更", clipId: clipId) },
                              onPressBegan: { model.beginStepperSession() },
                              onPressEnded: { model.commitStepperSession("ビジュアライザの本数の変更") },
                              monospacedDigits: true)
        }
        }
    }

    /// 図形: 範囲(x・y・w・h は動かせる)と見た目(種類、塗り、線、太さ、角丸)。
    @ViewBuilder func shapeSections(_ c: Clip) -> some View {
        let f = c.figureOrDefault
        InspectorSubsection("inspector.shape.range") {
        HStack(alignment: .top, spacing: 10) {
            num("中心 横", .x)
            num("中心 縦", .y)
        }
        HStack(alignment: .top, spacing: 10) {
            num("幅", .w)
            num("高さ", .h)
        }
        }
        InspectorSubsection("inspector.shape.look") {
        InspectorField(label: L10n.t("種類")) {
            Picker("", selection: Binding(get: { f.figureKind }, set: { k in model.setClipProperty({ $0.figure = Self.figUpdated($0.figure) { $0.kind = k.rawValue } }, name: "図形の種類の変更", clipId: clipId) })) {
                ForEach(FigureKind.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
        }
        Toggle(L10n.t("塗る"), isOn: Binding(get: { f.fillOrDefault != Figure.noneColor }, set: { on in
            model.setClipProperty({ $0.figure = Self.figUpdated($0.figure) { $0.fill = on ? nil : Figure.noneColor } }, name: "図形の塗りの切り替え", clipId: clipId)
        })).toggleStyle(.checkbox)
        if f.fillOrDefault != Figure.noneColor {
            ColorField(label: "塗り", hex: f.fillOrDefault) { hex in
                model.coalescedClipProperty({ $0.figure = Self.figUpdated($0.figure) { $0.fill = hex } }, name: "図形の塗りの色の変更", clipId: clipId)
            }
        }
        Toggle(L10n.t("線を引く"), isOn: Binding(get: { f.strokeOrDefault != Figure.noneColor }, set: { on in
            model.setClipProperty({ $0.figure = Self.figUpdated($0.figure) { $0.stroke = on ? "#000000" : Figure.noneColor } }, name: "図形の線の切り替え", clipId: clipId)
        })).toggleStyle(.checkbox)
        if f.strokeOrDefault != Figure.noneColor {
            ColorField(label: "線の色", hex: f.strokeOrDefault) { hex in
                model.coalescedClipProperty({ $0.figure = Self.figUpdated($0.figure) { $0.stroke = hex } }, name: "図形の線の色の変更", clipId: clipId)
            }
        }
        InspectorField(label: L10n.t("線の太さ")) {
            LabeledStepperRow(label: "\(Int(f.strokeWidthOrDefault)) px",
                              onIncrement: { model.liveClipProperty({ $0.figure = Self.figUpdated($0.figure) { $0.strokeWidth = StepperValue.stepped(f.strokeWidthOrDefault, by: 1, in: Figure.strokeWidthRange) } }, name: "図形の線の太さの変更", clipId: clipId) },
                              onDecrement: { model.liveClipProperty({ $0.figure = Self.figUpdated($0.figure) { $0.strokeWidth = StepperValue.stepped(f.strokeWidthOrDefault, by: -1, in: Figure.strokeWidthRange) } }, name: "図形の線の太さの変更", clipId: clipId) },
                              onPressBegan: { model.beginStepperSession() },
                              onPressEnded: { model.commitStepperSession("図形の線の太さの変更") },
                              monospacedDigits: true)
        }
        if f.figureKind == .rect {
            InspectorField(label: L10n.t("角丸")) {
                LabeledStepperRow(label: "\(Int((f.cornerOrDefault * 100).rounded())) %",
                                  onIncrement: { model.liveClipProperty({ $0.figure = Self.figUpdated($0.figure) { $0.corner = StepperValue.stepped(f.cornerOrDefault, by: 0.05, in: Figure.cornerRange) } }, name: "図形の角丸の変更", clipId: clipId) },
                                  onDecrement: { model.liveClipProperty({ $0.figure = Self.figUpdated($0.figure) { $0.corner = StepperValue.stepped(f.cornerOrDefault, by: -0.05, in: Figure.cornerRange) } }, name: "図形の角丸の変更", clipId: clipId) },
                                  onPressBegan: { model.beginStepperSession() },
                                  onPressEnded: { model.commitStepperSession("図形の角丸の変更") },
                                  monospacedDigits: true)
            }
        }
        }
    }

    /// 図形の見た目を 1 項目書き換えた結果。既定と同じ項目は書かず、全部既定なら `figure` ごと外す。
    static func figUpdated(_ current: Figure?, _ change: (inout Figure) -> Void) -> Figure? {
        var f = current ?? Figure()
        change(&f)
        return f.normalized
    }

    /// 設定を 1 項目書き換えた結果。全部既定値に戻ったら `visualizer` ごと外す(ファイルに余計な項目を残さない)。
    static func vizUpdated(_ current: Visualizer?, _ change: (inout Visualizer) -> Void) -> Visualizer? {
        var v = current ?? Visualizer()
        change(&v)
        // 既定と同じ値は書かない(棒・白・32 本)
        if v.style == Visualizer.defaultStyle { v.style = nil }
        if v.color?.lowercased() == Visualizer.defaultColor { v.color = nil }
        if v.count == Visualizer.defaultCount { v.count = nil }
        if v.mode == Visualizer.defaultMode { v.mode = nil }
        if v.source?.isEmpty == true { v.source = nil }
        return (v.style == nil && v.color == nil && v.count == nil && v.mode == nil && v.source == nil) ? nil : v
    }
}

// MARK: - キャラクターのプロパティ

struct CharacterInspector: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var speakers: SpeakerCatalog
    let charId: String
    @State private var showPresets = false

    private var ch: Character? { model.character(charId) }

    private func num(_ label: String, _ f: CharacterField, step: Double, decimals: Int) -> some View {
        InspectorField(label: label) {
            NumField(value: ch.map { f.value(of: $0) } ?? 0, step: step, decimals: decimals,
                     clamp: { f.clamp($0, engine: ch?.engine ?? "voicevox") },
                     onCommit: { model.setCharacterField(f, $0, charId: charId) },
                     onStep: { model.coalescedCharacterField(f, $0, charId: charId) })
        }
    }

    var body: some View {
        if let c = ch {
            VStack(alignment: .leading, spacing: 8) {
                InspectorSubsection("inspector.character.basic") {
                    Text("キャラクターは声と字幕の設定だけを持ちます。立ち絵は「立ち絵素材」とタイムラインの立ち絵クリップで扱います。")
                        .font(MCDesign.Font.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    InspectorField(label: "名前") {
                        NameField(value: c.name) { n in model.setCharacterProperty({ $0.name = n }, name: "キャラの名前の変更", charId: charId) }
                    }
                    ColorField(label: "字幕の縁の色", hex: c.color) { hex in
                        model.coalescedCharacterProperty({ $0.color = hex }, name: "字幕の縁の色の変更", charId: charId)
                    }
                    InspectorField(label: "字幕の文字色") {
                        HStack(spacing: 8) {
                            ColorPicker("", selection: Binding(get: { Color(hex: c.subtitleColor ?? "#ffffff") }, set: { v in
                                model.coalescedCharacterProperty({ $0.subtitleColor = SpeakerSubtitleColor.normalized(v.hexString) }, name: "話し手の字幕の色の変更", charId: charId)
                            }), supportsOpacity: false)
                                .labelsHidden()
                                .frame(width: 56, height: 28)
                            Text(c.subtitleColor?.uppercased() ?? "文字スタイルの色").font(MCDesign.Font.monospaced(11)).foregroundStyle(.secondary)
                            Button("既定に戻す") { model.setCharacterProperty({ $0.subtitleColor = nil }, name: "話し手の字幕の色を外す", charId: charId) }
                                .controlSize(.small)
                                .disabled(c.subtitleColor == nil)
                        }
                    }
                    .disabled(model.isLocked)
                }
                InspectorSubsection("inspector.character.voice") {
                    InspectorField(label: "音声エンジン") {
                        Picker("", selection: Binding(get: { c.engine }, set: { model.characterEngineChanged(charId: charId, to: $0) })) {
                            Text("VOICEVOX").tag("voicevox")
                            Text("ゆっくり (AquesTalk)").tag("aquestalk")
                            Text("COEIROINK").tag("coeiroink")
                            Text("SHAREVOX").tag("sharevox")
                        }
                        .labelsHidden()
                    }
                    if c.engine == "voicevox" { voicevoxFields(c) } else if VoicevoxFamily.isAdditionalEngine(c.engine) { familyFields(c) } else { aquestalkFields(c) }
                    if !c.hasVoiceChosen {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                            Text(L10n.t("声がまだ選ばれていません")).font(MCDesign.Font.subheadline).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Button(L10n.t("おすすめ音声設定…")) { showPresets = true }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(model.isLocked)
                        }
                    } else {
                        Button("おすすめ音声設定…") { showPresets = true }
                            .controlSize(.small)
                            .disabled(model.isLocked)
                    }
                }
                InspectorSubsection("inspector.character.actions") {
                    Button { Task { await model.testSpeak(charId: charId) } } label: { Text("試しに読み上げる").frame(maxWidth: .infinity) }
                        .disabled(model.isLocked)
                    let n = CharacterEditing.voiceClips(of: charId, in: model.project).count
                    Button { Task { await model.regenerateAllVoices(charId: charId) } } label: { Text("このキャラの全セリフを作り直す\(n > 0 ? "（\(n)）" : "")").frame(maxWidth: .infinity) }
                        .disabled(model.isLocked || n == 0)
                    Button(role: .destructive) { model.requestDeleteCharacter(charId) } label: { Text("このキャラを消す").foregroundStyle(MCDesign.Color.destructive).frame(maxWidth: .infinity) }
                        .disabled(model.isLocked || model.project.characters.count <= 1)
                        .help(model.project.characters.count <= 1 ? "最後の1人は消せません" : "このキャラとセリフを消します")
                }
            }
            .controlSize(.regular)
            .sheet(isPresented: $showPresets) { VoicePresetSheet(model: model, charId: charId) }
            .onDisappear { model.flushCoalesced() }
            .task(id: model.project.voicevoxUrl) {
                if c.engine == "voicevox" { await speakers.load(baseURL: model.project.voicevoxUrl) }
            }
        }
    }

    @ViewBuilder private func voicevoxFields(_ c: Character) -> some View {
        let speaker = c.speaker ?? 3
        switch speakers.state {
        case .loaded:
            InspectorField(label: "話者") {
                Picker("", selection: Binding<Int?>(get: { c.speaker }, set: { v in if let v { model.setCharacterProperty({ $0.speaker = v }, name: "話者の変更", charId: charId) } })) {
                    if c.speaker == nil { Text(L10n.t("未選択")).tag(Int?.none) }
                    else if speakers.label(for: speaker) == nil { Text("話者 \(speaker)").tag(Int?.some(speaker)) }
                    ForEach(speakers.choices, id: \.id) { Text($0.label).tag(Int?.some($0.id)) }
                }
                .labelsHidden()
            }
        case .idle, .loading:
            InspectorField(label: "話者") {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("読み込み中…").font(MCDesign.Font.callout).foregroundStyle(.secondary)
                }
            }
        case .unavailable:
            InspectorField(label: "話者ID") {
                NumField(value: Double(speaker), step: 1, decimals: 0, clamp: { max(0, min(100000, $0.rounded())) },
                         onCommit: { v in model.setCharacterProperty({ $0.speaker = Int(max(0, min(100000, v.rounded()))) }, name: "話者の変更", charId: charId) },
                         onStep: { v in model.coalescedCharacterProperty({ $0.speaker = Int(max(0, min(100000, v.rounded()))) }, name: "話者の変更", charId: charId) })
            }
            Text("VOICEVOX につながらないため、話者の一覧を出せません。話者ID を直接入れてください(起動すると一覧になります)。")
                .font(MCDesign.Font.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("もう一度つなぐ") { Task { await speakers.load(baseURL: model.project.voicevoxUrl) } }
                .controlSize(.small)
        }
        num("話す速さ", .speed, step: 0.05, decimals: 2)
        HStack(alignment: .top, spacing: 10) {
            num("高さ", .pitch, step: 0.01, decimals: 2)
            num("抑揚", .intonation, step: 0.05, decimals: 2)
        }
    }

    /// COEIROINK / SHAREVOX の項目。話者カタログは VOICEVOX の接続先専用のため、話者は数値 ID の直接入力にする。
    @ViewBuilder private func familyFields(_ c: Character) -> some View {
        let speaker = c.speaker ?? 3
        let name = VoicevoxFamily.displayName(forEngine: c.engine) ?? c.engine
        let base = VoicevoxFamily.spec(forEngine: c.engine)?.defaultBaseURL ?? ""
        InspectorField(label: "話者ID") {
            NumField(value: Double(speaker), step: 1, decimals: 0, clamp: { max(0, min(100000, $0.rounded())) },
                     onCommit: { v in model.setCharacterProperty({ $0.speaker = Int(max(0, min(100000, v.rounded()))) }, name: "話者の変更", charId: charId) },
                     onStep: { v in model.coalescedCharacterProperty({ $0.speaker = Int(max(0, min(100000, v.rounded()))) }, name: "話者の変更", charId: charId) })
        }
        num("話す速さ", .speed, step: 0.05, decimals: 2)
        HStack(alignment: .top, spacing: 10) {
            num("高さ", .pitch, step: 0.01, decimals: 2)
            num("抑揚", .intonation, step: 0.05, decimals: 2)
        }
        Text("\(name) を起動してから合成します(自動起動はしません)。既定の接続先は \(base) です。話者IDはエンジンの話者一覧(/speakers)で確認できます。")
            .font(MCDesign.Font.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func aquestalkFields(_ c: Character) -> some View {
        InspectorField(label: "声") {
            Picker("", selection: Binding<String?>(get: { c.voice }, set: { v in if let v { model.setCharacterProperty({ $0.voice = v }, name: "声の変更", charId: charId) } })) {
                if let cur = c.voice { if !AquesTalkPresets.all.contains(cur) { Text(cur).tag(String?.some(cur)) } }
                else { Text(L10n.t("未選択")).tag(String?.none) }
                ForEach(AquesTalkPresets.all, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
        }
        num("話す速さ", .speed, step: 5, decimals: 0)
    }
}

/// 1 行の文字入力(Return・フォーカスが外れたときに確定)。
struct NameField: View {
    let value: String
    let onCommit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { onCommit(text); focused = false }
            .onChange(of: focused) { _, now in if !now { onCommit(text) } }
            .onAppear { text = value }
            .onChange(of: value) { _, v in if !focused { text = v } }
    }
}
