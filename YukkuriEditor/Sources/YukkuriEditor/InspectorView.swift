import SwiftUI
import AppKit
import YukkuriCore

// MARK: - 部品

/// 小さい見出し(タイミング / セリフ / …)。
struct InspectorSection: View {
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
        }
        .padding(.top, 8)
    }
}

/// ラベルを上に置いた項目。
struct InspectorField<Content: View>: View {
    let label: String
    var trailing: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let trailing { Text(trailing).font(.system(size: 12).monospacedDigit()).foregroundStyle(.primary) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 数値の入力欄(Return・フォーカスが外れたときに確定、右のステッパーは連続編集)。
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
        if let v = Double(t) {
            onCommit(v)
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
                .onSubmit(commit)
                .onChange(of: focused) { _, now in if !now { commit() } }
            Stepper("", onIncrement: { onStep(value + step) }, onDecrement: { onStep(value - step) })
                .labelsHidden()
        }
        .onAppear { text = Self.format(value, decimals: decimals) }
        .onChange(of: value) { _, v in if !focused { text = Self.format(v, decimals: decimals) } }
    }
}

/// スライダー(ラベルの右に現在の値)。ドラッグの間は Undo に積まず、離したときに 1 回だけ登録する。
struct LiveSlider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let begin: () -> Void
    let change: (Double) -> Void
    let end: () -> Void

    var body: some View {
        InspectorField(label: label, trailing: format(value)) {
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
                Text(hex.uppercased()).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
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
    let onLive: (String) -> Void
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        InspectorField(label: label) {
            TextEditor(text: $draft)
                .font(.system(size: 13))
                .focused($focused)
                .scrollContentBackground(.hidden)
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
                Text(path == nil ? "なし" : "…").font(.system(size: 11)).foregroundStyle(.tertiary)
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
            Text("プロパティ").font(.headline).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    switch model.inspectorMode {
                    case .clip(let id):
                        ClipInspector(model: model, clipId: id).id(id)
                    case .character(let id):
                        CharacterInspector(model: model, speakers: speakers, charId: id).id(id)
                    case .none:
                        Text("クリップを選ぶと設定が出ます。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(ScrollerStyler())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - クリップのプロパティ

struct ClipInspector: View {
    @ObservedObject var model: ProjectModel
    let clipId: String

    private var clip: Clip? { model.clip(clipId) }

    // 数値欄 / スライダー
    private func num(_ label: String, _ f: ClipField, step: Double = 0.01, decimals: Int = 2) -> some View {
        InspectorField(label: label) {
            NumField(value: clip.map { f.value(of: $0) } ?? 0, step: step, decimals: decimals, clamp: { f.clamp($0) },
                     onCommit: { model.setClipField(f, $0, clipId: clipId) },
                     onStep: { model.coalescedClipField(f, $0, clipId: clipId) })
        }
    }

    private func slider(_ label: String, _ f: ClipField, step: Double, format: @escaping (Double) -> String) -> some View {
        LiveSlider(label: label, value: clip.map { f.value(of: $0) } ?? 0, range: f.range, step: step, format: format,
                   begin: { model.beginGesture() },
                   change: { model.liveClipField(f, $0, clipId: clipId) },
                   end: { model.commitGesture(f.undoName) })
    }

    private func fontPicker(_ c: Clip) -> some View {
        InspectorField(label: "フォント") {
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
        default: return t.rawValue
        }
    }

    var body: some View {
        if let c = clip {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(kindName(c.type)).font(.system(size: 12, weight: .semibold))
                    if let src = c.src, c.type != .voice {
                        Text(URL(fileURLWithPath: src).lastPathComponent)
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                InspectorSection(title: "タイミング")
                HStack(alignment: .top, spacing: 10) {
                    num("開始（秒）", .start, step: 0.1, decimals: 3)
                    num("長さ（秒）", .duration, step: 0.1, decimals: 3)
                }
                if c.type == .voice { voiceSections(c) }
                if c.type == .text { textSections(c) }
                if [ClipType.image, .video, .text].contains(c.type) { placeSections(c) }
                if c.type == .blur { blurSections(c) }
                if c.type == .video || c.type == .audio {
                    InspectorSection(title: "音声")
                    slider("音量", .volume, step: 0.05, format: Self.pct)
                }
            }
            .onDisappear { model.flushCoalesced() }
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
        MultilineField(label: "セリフ", value: c.text ?? "", onLive: { _ in }, onCommit: { t in Task { await model.setVoiceText(t, clipId: clipId) } })
        Text("入力欄を離れるか Cmd+Return で、音声を作り直します。")
            .font(.system(size: 11)).foregroundStyle(.secondary)
        InspectorSection(title: "字幕")
        Toggle("字幕を出す", isOn: Binding(get: { c.subtitleOrDefault }, set: { v in model.setClipProperty({ $0.subtitle = v }, name: "字幕の切り替え", clipId: clipId) }))
            .toggleStyle(.checkbox)
        num("字幕の大きさ（px）", .fontSize, step: 1, decimals: 0)
        fontPicker(c)
        InspectorSection(title: "音声")
        slider("音量", .volume, step: 0.05, format: Self.pct)
    }

    @ViewBuilder private func textSections(_ c: Clip) -> some View {
        InspectorSection(title: "文字")
        MultilineField(label: "文字", value: c.text ?? "", live: true,
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
        InspectorSection(title: "位置")
        HStack(alignment: .top, spacing: 10) {
            num("横位置", .x)
            num("縦位置", .y)
        }
        if c.type == .image || c.type == .video { num("拡大", .scale, step: 0.05) }
        InspectorSection(title: "見た目")
        slider("不透明度", .opacity, step: 0.01, format: Self.pct)
        slider("ぼかし（px）", .blur, step: 1, format: Self.px)
    }

    @ViewBuilder private func blurSections(_ c: Clip) -> some View {
        InspectorSection(title: "範囲")
        HStack(alignment: .top, spacing: 10) {
            num("中心 横", .x)
            num("中心 縦", .y)
        }
        HStack(alignment: .top, spacing: 10) {
            num("幅", .w)
            num("高さ", .h)
        }
        InspectorField(label: "形") {
            Picker("", selection: Binding(get: { c.shapeOrDefault }, set: { v in model.setClipProperty({ $0.shape = v }, name: "ぼかしの形の変更", clipId: clipId) })) {
                Text("四角").tag("rect")
                Text("楕円").tag("ellipse")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        InspectorSection(title: "見た目")
        slider("強さ（px）", .strength, step: 1, format: Self.px)
    }
}

// MARK: - キャラクターのプロパティ

struct CharacterInspector: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var speakers: SpeakerCatalog
    let charId: String

    private var ch: Character? { model.character(charId) }

    private func num(_ label: String, _ f: CharacterField, step: Double, decimals: Int) -> some View {
        InspectorField(label: label) {
            NumField(value: ch.map { f.value(of: $0) } ?? 0, step: step, decimals: decimals,
                     clamp: { f.clamp($0, engine: ch?.engine ?? "voicevox") },
                     onCommit: { model.setCharacterField(f, $0, charId: charId) },
                     onStep: { model.coalescedCharacterField(f, $0, charId: charId) })
        }
    }

    private func check(_ title: String, _ c: Character, name: String, get: @escaping (Character) -> Bool, set: @escaping (inout Character, Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { get(c) }, set: { v in model.setCharacterProperty({ set(&$0, v) }, name: name, charId: charId) }))
            .toggleStyle(.checkbox)
    }

    private func fileName(_ p: String?) -> String { p.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "未設定" }

    private func portraitRow(_ c: Character, closed: Bool) -> some View {
        let path = closed ? c.imgClosed : c.imgOpen
        return HStack(alignment: .center, spacing: 10) {
            PortraitThumb(path: path)
            VStack(alignment: .leading, spacing: 4) {
                Text(closed ? "立ち絵（口閉じ）" : "立ち絵（口開き）").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(fileName(path)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Button("選択…") { model.choosePortrait(charId: charId, closed: closed) }
                    Button { model.setPortrait(charId: charId, closed: closed, url: nil) } label: { Image(systemName: "xmark") }
                        .disabled(path == nil)
                        .help("画像を外す")
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
    }

    var body: some View {
        if let c = ch {
            VStack(alignment: .leading, spacing: 8) {
                InspectorSection(title: "基本")
                InspectorField(label: "名前") {
                    NameField(value: c.name) { n in model.setCharacterProperty({ $0.name = n }, name: "キャラの名前の変更", charId: charId) }
                }
                ColorField(label: "字幕の縁の色", hex: c.color) { hex in
                    model.coalescedCharacterProperty({ $0.color = hex }, name: "字幕の縁の色の変更", charId: charId)
                }
                InspectorSection(title: "声")
                InspectorField(label: "音声エンジン") {
                    Picker("", selection: Binding(get: { c.engine }, set: { model.characterEngineChanged(charId: charId, to: $0) })) {
                        Text("VOICEVOX").tag("voicevox")
                        Text("ゆっくり (AquesTalk)").tag("aquestalk")
                    }
                    .labelsHidden()
                }
                if c.engine == "voicevox" { voicevoxFields(c) } else { aquestalkFields(c) }
                InspectorSection(title: "立ち絵")
                portraitRow(c, closed: true)
                portraitRow(c, closed: false)
                HStack(alignment: .top, spacing: 10) {
                    num("横位置", .x, step: 0.01, decimals: 2)
                    num("縦位置", .y, step: 0.01, decimals: 2)
                }
                num("大きさ", .scale, step: 0.05, decimals: 2)
                check("左右反転", c, name: "左右反転の切り替え", get: { $0.flip }, set: { $0.flip = $1 })
                check("いつも表示", c, name: "いつも表示の切り替え", get: { $0.alwaysShow }, set: { $0.alwaysShow = $1 })
                InspectorSection(title: "操作")
                Button { Task { await model.testSpeak(charId: charId) } } label: { Text("試しに読み上げる").frame(maxWidth: .infinity) }
                    .disabled(model.isLocked)
                let n = CharacterEditing.voiceClips(of: charId, in: model.project).count
                Button { Task { await model.regenerateAllVoices(charId: charId) } } label: { Text("このキャラの全セリフを作り直す\(n > 0 ? "（\(n)）" : "")").frame(maxWidth: .infinity) }
                    .disabled(model.isLocked || n == 0)
                Button(role: .destructive) { model.requestDeleteCharacter(charId) } label: { Text("このキャラを消す").foregroundStyle(Color(red: 1, green: 0.45, blue: 0.42)).frame(maxWidth: .infinity) }
                    .disabled(model.isLocked || model.project.characters.count <= 1)
                    .help(model.project.characters.count <= 1 ? "最後の1人は消せません" : "このキャラとセリフを消します")
            }
            .controlSize(.regular)
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
                Picker("", selection: Binding(get: { speaker }, set: { v in model.setCharacterProperty({ $0.speaker = v }, name: "話者の変更", charId: charId) })) {
                    if speakers.label(for: speaker) == nil { Text("話者 \(speaker)").tag(speaker) }
                    ForEach(speakers.choices, id: \.id) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
            }
        case .idle, .loading:
            InspectorField(label: "話者") {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("読み込み中…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        case .unavailable:
            InspectorField(label: "話者ID") {
                NumField(value: Double(speaker), step: 1, decimals: 0, clamp: { max(0, min(100000, $0.rounded())) },
                         onCommit: { v in model.setCharacterProperty({ $0.speaker = Int(max(0, min(100000, v.rounded()))) }, name: "話者の変更", charId: charId) },
                         onStep: { v in model.coalescedCharacterProperty({ $0.speaker = Int(max(0, min(100000, v.rounded()))) }, name: "話者の変更", charId: charId) })
            }
            Text("VOICEVOX につながらないため、話者の一覧を出せません。話者ID を直接入れてください(起動すると一覧になります)。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("もう一度つなぐ") { Task { await speakers.load(baseURL: model.project.voicevoxUrl) } }
                .controlSize(.small)
        }
        num("話す速さ", .speed, step: 0.05, decimals: 2)
        HStack(alignment: .top, spacing: 10) {
            num("高さ", .pitch, step: 0.01, decimals: 2)
            num("抑揚", .intonation, step: 0.05, decimals: 2)
        }
    }

    @ViewBuilder private func aquestalkFields(_ c: Character) -> some View {
        InspectorField(label: "声") {
            Picker("", selection: Binding(get: { c.voice ?? AquesTalkPresets.all[0] }, set: { v in model.setCharacterProperty({ $0.voice = v }, name: "声の変更", charId: charId) })) {
                let cur = c.voice ?? AquesTalkPresets.all[0]
                if !AquesTalkPresets.all.contains(cur) { Text(cur).tag(cur) }
                ForEach(AquesTalkPresets.all, id: \.self) { Text($0).tag($0) }
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
            .onSubmit { onCommit(text) }
            .onChange(of: focused) { _, now in if !now { onCommit(text) } }
            .onAppear { text = value }
            .onChange(of: value) { _, v in if !focused { text = v } }
    }
}
