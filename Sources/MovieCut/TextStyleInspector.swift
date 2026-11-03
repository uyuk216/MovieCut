import SwiftUI
import MovieCutCore

/// 文字クリップ(と字幕)の装飾・保存したスタイル・文字アニメーションの欄。計算は MovieCutCore、Undo はモデルに任せる。
/// 数値のスライダーは、ドラッグの間は Undo に積まず、離したときに 1 回だけ登録する。
struct TextStyleInspector: View {
    @ObservedObject var model: ProjectModel
    @ObservedObject var store: TextStyleStore
    let clipId: String
    /// 撮影・試験用: 折りたたまずに全部開く。
    static var expandAll = false

    @State private var showSave = false
    @State private var draftName = ""
    @State private var renamingId: String?

    private var clip: Clip? { model.clip(clipId) }
    private static let pct: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
    private static let px: (Double) -> String = { "\(Int($0.rounded()))px" }

    var body: some View {
        if let c = clip {
            if c.type == .text { styleSection(c) }
            decorationSections(c)
            if c.type == .text { bubbleSection(c); animationSection(c); counterSection(c); valueRefSection(c) }
        }
    }

    // MARK: 吹き出し(B-2)

    @ViewBuilder private func bubbleSection(_ c: Clip) -> some View {
        InspectorSection(title: "吹き出し")
        Toggle("吹き出しを付ける", isOn: Binding(get: { c.bubble != nil }, set: { on in
            model.setBubble(on ? Bubble() : nil, name: on ? "吹き出しを付ける" : "吹き出しを外す", clipId: clipId)
        }))
        .toggleStyle(.checkbox).font(.system(size: 12)).disabled(model.isLocked)
        if let b = c.bubble {
            VStack(alignment: .leading, spacing: 6) {
                InspectorField(label: "形") {
                    Picker("", selection: Binding(get: { b.shape }, set: { v in model.editBubble({ $0.shape = v }, name: "吹き出しの形の変更", clipId: clipId) })) {
                        Text("丸角").tag("rounded"); Text("雲").tag("cloud"); Text("四角").tag("rect")
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                ColorField(label: "塗り", hex: b.fill) { h in model.coalescedBubble({ $0.fill = h }, name: "吹き出しの塗りの変更", clipId: clipId) }
                ColorField(label: "縁の色", hex: b.stroke) { h in model.coalescedBubble({ $0.stroke = h }, name: "吹き出しの縁の色の変更", clipId: clipId) }
                LiveSlider(label: "縁の太さ（px）", key: nil, value: b.strokeWidth, range: 0...40, step: 1,
                           format: Self.px,
                           begin: { model.beginGesture() },
                           change: { v in model.liveClipProperty({ if $0.bubble != nil { $0.bubble?.strokeWidth = v } }, name: "吹き出しの縁の変更", clipId: clipId) },
                           end: { model.commitGesture("吹き出しの縁の変更") })
                Toggle("尾を付ける", isOn: Binding(get: { b.tail }, set: { on in model.editBubble({ $0.tail = on }, name: "尾の切り替え", clipId: clipId) }))
                    .toggleStyle(.checkbox).font(.system(size: 12))
                if b.tail { bubbleTailControls(b) }
            }
            .padding(.leading, 10)
            .disabled(model.isLocked)
        }
    }

    /// 尾の先: 画面上の点(正規化した x・y)か、キャラの位置(＋ずれ)。
    @ViewBuilder private func bubbleTailControls(_ b: Bubble) -> some View {
        InspectorField(label: "尾の先") {
            Picker("", selection: Binding(get: { b.tailChar == nil ? "point" : "char" }, set: { v in
                model.editBubble({ $0.tailChar = v == "char" ? model.project.characters.first?.id : nil }, name: "尾の先の変更", clipId: clipId)
            })) {
                Text("画面上の点").tag("point"); Text("キャラ").tag("char")
            }
            .pickerStyle(.segmented).labelsHidden()
        }
        if let cid = b.tailChar {
            InspectorField(label: "キャラ") {
                Picker("", selection: Binding(get: { cid }, set: { v in model.editBubble({ $0.tailChar = v }, name: "尾の先の変更", clipId: clipId) })) {
                    ForEach(model.project.characters, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
            }
            HStack(spacing: 10) {
                bubbleNum("ずれ・横", b.tailDX) { v in model.coalescedBubble({ $0.tailDX = v }, name: "尾の先のずれの変更", clipId: clipId) }
                bubbleNum("ずれ・縦", b.tailDY) { v in model.coalescedBubble({ $0.tailDY = v }, name: "尾の先のずれの変更", clipId: clipId) }
            }
        } else {
            HStack(spacing: 10) {
                bubbleNum("点・横", b.tailX) { v in model.coalescedBubble({ $0.tailX = v }, name: "尾の先の変更", clipId: clipId) }
                bubbleNum("点・縦", b.tailY) { v in model.coalescedBubble({ $0.tailY = v }, name: "尾の先の変更", clipId: clipId) }
            }
        }
    }

    private func bubbleNum(_ label: String, _ value: Double, _ set: @escaping (Double) -> Void) -> some View {
        InspectorField(label: label) {
            NumField(value: value, step: 0.01, decimals: 2, clamp: { min(2, max(-1, $0)) }, onCommit: set, onStep: set)
        }
    }

    // MARK: スタイル

    @ViewBuilder private func styleSection(_ c: Clip) -> some View {
        InspectorSection(title: "スタイル")
        HStack(spacing: 8) {
            Menu {
                ForEach(TextStyleLibrary.builtins.filter { !$0.id.hasPrefix(TextStyleLibrary.titlePrefix) }) { s in Button(s.name) { model.applyTextStyle(id: s.id, clipId: clipId) } }
                Divider()
                Menu("アニメ付きタイトル") {
                    ForEach(TextStyleLibrary.animatedTitles) { s in Button(s.name) { model.applyTextStyle(id: s.id, clipId: clipId) } }
                }
                if !store.user.isEmpty {
                    Divider()
                    ForEach(store.user) { s in Button(s.name) { model.applyTextStyle(id: s.id, clipId: clipId) } }
                }
            } label: { Text("スタイルを適用") }
                .menuStyle(.button).fixedSize().disabled(model.isLocked)
            Button("現在の見た目を保存…") { draftName = ""; showSave = true }
                .disabled(model.isLocked)
            Spacer()
        }
        .controlSize(.small)
        if !store.user.isEmpty {
            HStack(spacing: 8) {
                Menu {
                    ForEach(store.user) { s in
                        Menu(s.name) {
                            Button("名前を変更…") { draftName = s.name; renamingId = s.id }
                            Button("削除", role: .destructive) { model.deleteTextStyle(id: s.id) }
                        }
                    }
                } label: { Text("保存したスタイルの管理") }
                    .menuStyle(.button).fixedSize()
                Spacer()
            }
            .controlSize(.small)
        }
        Color.clear.frame(height: 0)
            .alert("スタイルの名前", isPresented: $showSave) {
                TextField("名前", text: $draftName)
                Button("保存") { model.saveCurrentTextStyle(named: draftName, clipId: clipId) }
                Button("キャンセル", role: .cancel) {}
            } message: { Text("色・縁・書体と、影や箱などの装飾を保存します。") }
            .alert("名前を変更", isPresented: Binding(get: { renamingId != nil }, set: { if !$0 { renamingId = nil } })) {
                TextField("名前", text: $draftName)
                Button("変更") { if let id = renamingId { model.renameTextStyle(id: id, to: draftName) }; renamingId = nil }
                Button("キャンセル", role: .cancel) { renamingId = nil }
            }
    }

    // MARK: 装飾

    private func edit(_ name: String, _ f: @escaping (inout TextStyle) -> Void) {
        model.setTextStyle(f, name: name, clipId: clipId)
    }

    private func slider(_ label: String, value: Double, range: ClosedRange<Double>, step: Double, format: @escaping (Double) -> String, name: String,
                        _ f: @escaping (inout TextStyle, Double) -> Void) -> some View {
        LiveSlider(label: label, key: nil, value: value, range: range, step: step, format: format,
                   begin: { model.beginGesture() },
                   change: { v in model.liveClipProperty({ _ = TextStyleEditing.update(&$0) { s in f(&s, v) } }, name: name, clipId: clipId) },
                   end: { model.commitGesture(name) })
    }

    private func color(_ label: String, hex: String, name: String, _ f: @escaping (inout TextStyle, String) -> Void) -> some View {
        ColorField(label: label, hex: hex) { h in model.coalescedTextStyle({ f(&$0, h) }, name: name, clipId: clipId) }
    }

    private func toggle(_ label: String, isOn: Bool, name: String, _ f: @escaping (inout TextStyle, Bool) -> Void) -> some View {
        Toggle(label, isOn: Binding(get: { isOn }, set: { on in edit(name) { f(&$0, on) } }))
            .toggleStyle(.checkbox).font(.system(size: 12)).disabled(model.isLocked)
    }

    @ViewBuilder private func decorationSections(_ c: Clip) -> some View {
        let st = c.textStyle ?? TextStyle()
        InspectorSection(title: c.type == .voice ? "字幕の装飾" : "装飾")
        // 影
        toggle("影", isOn: st.shadow != nil, name: "影の変更") { $0.shadow = $1 ? TextStyle.Shadow() : nil }
        if let sh = st.shadow {
            VStack(alignment: .leading, spacing: 6) {
                color("影の色", hex: sh.color, name: "影の色の変更") { $0.shadow?.color = $1 }
                slider("横のずれ（px）", value: sh.dx, range: -100...100, step: 1, format: Self.px, name: "影の変更") { $0.shadow?.dx = $1 }
                slider("縦のずれ（px）", value: sh.dy, range: -100...100, step: 1, format: Self.px, name: "影の変更") { $0.shadow?.dy = $1 }
                slider("ぼかし（px）", value: sh.blur, range: 0...50, step: 1, format: Self.px, name: "影の変更") { $0.shadow?.blur = $1 }
                slider("濃さ", value: sh.opacity, range: 0...1, step: 0.01, format: Self.pct, name: "影の変更") { $0.shadow?.opacity = $1 }
            }
            .padding(.leading, 10)
        }
        // カラオケ字幕(文字クリップだけ。話している部分の色を、クリップの時間で増やす)
        if c.type == .text {
            toggle("カラオケ字幕（話した部分の色を変える）", isOn: st.highlight != nil, name: "カラオケ字幕の変更") { $0.highlight = $1 ? Highlight() : nil }
            if let h = st.highlight {
                VStack(alignment: .leading, spacing: 6) {
                    color("色", hex: h.colorOrDefault, name: "カラオケの色の変更") { $0.highlight?.color = $1 }
                    InspectorField(label: "単位") {
                        Picker("", selection: Binding(get: { h.isWordMode ? "word" : "char" }, set: { v in edit("カラオケの単位の変更") { $0.highlight?.mode = v } })) {
                            Text("1 文字").tag("char"); Text("単語").tag("word")
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                }
                .padding(.leading, 10)
                .disabled(model.isLocked)
            }
        }
        // 箱
        toggle("文字の後ろに箱", isOn: st.box != nil, name: "箱の変更") { $0.box = $1 ? TextStyle.Box() : nil }
        if let b = st.box {
            VStack(alignment: .leading, spacing: 6) {
                color("箱の色", hex: b.color, name: "箱の色の変更") { $0.box?.color = $1 }
                slider("濃さ", value: b.opacity, range: 0...1, step: 0.01, format: Self.pct, name: "箱の変更") { $0.box?.opacity = $1 }
                slider("左右の余白（px）", value: b.paddingX, range: 0...200, step: 1, format: Self.px, name: "箱の変更") { $0.box?.paddingX = $1 }
                slider("上下の余白（px）", value: b.paddingY, range: 0...200, step: 1, format: Self.px, name: "箱の変更") { $0.box?.paddingY = $1 }
                slider("角の丸み（px）", value: b.cornerRadius, range: 0...100, step: 1, format: Self.px, name: "箱の変更") { $0.box?.cornerRadius = $1 }
            }
            .padding(.leading, 10)
        }
        // グラデーション
        toggle("グラデーションの塗り", isOn: st.gradient != nil, name: "グラデーションの変更") { $0.gradient = $1 ? TextStyle.Gradient() : nil }
        if let g = st.gradient {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 10) {
                    color("色 1", hex: g.color1, name: "グラデーションの色の変更") { $0.gradient?.color1 = $1 }
                    color("色 2", hex: g.color2, name: "グラデーションの色の変更") { $0.gradient?.color2 = $1 }
                }
                slider("角度（°）", value: g.angle, range: -180...180, step: 1, format: { "\(Int($0.rounded()))°" }, name: "グラデーションの変更") { $0.gradient?.angle = $1 }
            }
            .padding(.leading, 10)
        }
        // 字間・行間・揃え・太字・斜体
        slider("字間（px）", value: st.letterSpacingOrDefault, range: -20...60, step: 1, format: Self.px, name: "字間の変更") { $0.letterSpacing = $1 == 0 ? nil : $1 }
        slider("行間（倍）", value: st.lineHeightOrDefault, range: 0.8...2.5, step: 0.05, format: { String(format: "%.2f", $0) }, name: "行間の変更") {
            $0.lineHeight = abs($1 - TextStyle.defaultLineHeight) < 0.001 ? nil : $1
        }
        InspectorField(label: "揃え") {
            Picker("", selection: Binding(get: { st.alignOrDefault }, set: { a in edit("文字の揃えの変更") { $0.align = a == .center ? nil : a.rawValue } })) {
                ForEach(TextStyle.Align.allCases, id: \.rawValue) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
        }
        HStack(spacing: 14) {
            toggle("太字", isOn: st.boldOrDefault, name: "太字の変更") { $0.bold = $1 ? nil : false }
            toggle("斜体", isOn: st.italicOrDefault, name: "斜体の変更") { $0.italic = $1 ? true : nil }
            Spacer()
        }
        Button { model.setTextStyle({ $0 = TextStyle() }, name: "装飾をリセット", clipId: clipId) } label: { Text("装飾をリセット").frame(maxWidth: .infinity) }
            .controlSize(.small)
            .disabled(model.isLocked || c.textStyle == nil)
    }

    // MARK: カウントダウン(文字クリップ)

    @ViewBuilder private func counterSection(_ c: Clip) -> some View {
        InspectorSection(title: "カウントダウン")
        Toggle("カウントダウンを付ける", isOn: Binding(get: { c.counter != nil }, set: { on in
            model.setCounter(on ? TextCounter() : nil, name: on ? "カウントダウンにする" : "カウントダウンを外す", clipId: clipId)
        }))
        .toggleStyle(.checkbox).font(.system(size: 12)).disabled(model.isLocked)
        if let k = c.counter {
            VStack(alignment: .leading, spacing: 6) {
                InspectorField(label: "開始（秒）") {
                    NumField(value: k.from, step: 1, decimals: 0, clamp: { min(max($0.rounded(), 0), 3600) },
                             onCommit: { v in model.editCounter({ $0.from = v }, name: "カウントダウンの開始の変更", clipId: clipId) },
                             onStep: { v in model.coalescedCounter({ $0.from = v }, name: "カウントダウンの開始の変更", clipId: clipId) })
                }
                InspectorField(label: "終わり（秒）") {
                    NumField(value: k.to, step: 1, decimals: 0, clamp: { min(max($0.rounded(), 0), 3600) },
                             onCommit: { v in model.editCounter({ $0.to = v }, name: "カウントダウンの終わりの変更", clipId: clipId) },
                             onStep: { v in model.coalescedCounter({ $0.to = v }, name: "カウントダウンの終わりの変更", clipId: clipId) })
                }
                InspectorField(label: "表示") {
                    Picker("", selection: Binding(get: { k.format }, set: { v in model.editCounter({ $0.format = v }, name: "カウントダウンの表示の変更", clipId: clipId) })) {
                        Text("分:秒").tag("mm:ss"); Text("秒だけ").tag("ss")
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
            }
            .padding(.leading, 10)
            .disabled(model.isLocked)
            Text("クリップの頭から終わりまで、開始から終わりへ直線に変わります。文字は「テキスト」の後ろに続きます。").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: 他のクリップの値(文字クリップ)

    @ViewBuilder private func valueRefSection(_ c: Clip) -> some View {
        let cands = model.valueRefCandidates(for: c.id)
        InspectorSection(title: "他のクリップの値")
        Toggle("他のクリップの値を表示", isOn: Binding(get: { c.valueRef != nil }, set: { on in
            guard let first = cands.first else { return }
            model.setValueRef(on ? ValueRef(clipId: first.id) : nil, name: on ? "他のクリップの値を表示" : "値の表示を外す", clipId: clipId)
        }))
        .toggleStyle(.checkbox).font(.system(size: 12)).disabled(model.isLocked || (c.valueRef == nil && cands.isEmpty))
        if let r = c.valueRef {
            VStack(alignment: .leading, spacing: 6) {
                InspectorField(label: "クリップ") {
                    Picker("", selection: Binding(get: { r.clipId }, set: { v in model.editValueRef({ $0.clipId = v }, name: "参照クリップの変更", clipId: clipId) })) {
                        ForEach(cands, id: \.id) { Text(Self.candidateLabel($0)).tag($0.id) }
                        if !cands.contains(where: { $0.id == r.clipId }) { Text("（見つかりません）").tag(r.clipId) }
                    }
                    .labelsHidden()
                }
                InspectorField(label: "項目") {
                    Picker("", selection: Binding(get: { r.param }, set: { v in model.editValueRef({ $0.param = v }, name: "参照する項目の変更", clipId: clipId) })) {
                        ForEach(ValueRef.params, id: \.self) { Text(ValueRef.label(of: $0)).tag($0) }
                    }
                    .labelsHidden()
                }
                InspectorField(label: "表示") {
                    Picker("", selection: Binding(get: { r.format }, set: { v in model.editValueRef({ $0.format = v }, name: "値の表示形式の変更", clipId: clipId) })) {
                        ForEach(ValueRef.formats, id: \.self) { Text(ValueRef.formatLabel($0)).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                InspectorField(label: "小数の桁") {
                    NumField(value: Double(r.decimals), step: 1, decimals: 0, clamp: { min(max($0.rounded(), 0), 4) },
                             onCommit: { v in model.editValueRef({ $0.decimals = Int(v) }, name: "値の桁数の変更", clipId: clipId) },
                             onStep: { v in model.editValueRef({ $0.decimals = Int(v) }, name: "値の桁数の変更", clipId: clipId) })
                }
            }
            .padding(.leading, 10)
            .disabled(model.isLocked)
            Text("再生位置での値(キーフレーム反映)が「テキスト」の後ろに続きます。参照先が無いときは「—」。カウントダウンがあるときはそちらが先です。").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private static func candidateLabel(_ k: Clip) -> String {
        let name: String
        switch k.type {
        case .text, .voice: name = (k.text ?? "").prefix(12).description
        default: name = k.src.map { ($0 as NSString).lastPathComponent } ?? k.type.rawValue
        }
        return "\(k.type.rawValue) \(name) @\(String(format: "%.1f", k.start))s"
    }

    // MARK: アニメーション

    @ViewBuilder private func animationSection(_ c: Clip) -> some View {
        let kind = c.textAnim?.known ?? .none
        InspectorSection(title: "文字アニメーション")
        InspectorField(label: "種類") {
            Picker("", selection: Binding(get: { c.textAnim == nil ? TextAnimKind.none.rawValue : c.textAnim!.kind },
                                          set: { v in model.setTextAnim(TextAnimKind(rawValue: v) ?? .none, clipId: clipId) })) {
                ForEach(TextAnimKind.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                if let a = c.textAnim, a.known == nil { Text("（未対応: \(a.kind)）").tag(a.kind) }
            }
            .labelsHidden()
        }
        if kind.isScroll {
            InspectorField(label: "速さ（/秒）") {
                NumField(value: c.textAnim?.speedOrDefault ?? TextAnim.defaultSpeed, step: 0.01, decimals: 2, clamp: { TextAnim.clampSpeed($0) },
                         onCommit: { model.setTextAnim(kind, speed: $0, clipId: clipId) },
                         onStep: { model.coalescedTextAnimSpeed($0, clipId: clipId) })
            }
            Text("画面の高さ（上へ）・幅（左へ）に対する割合。クリップの終わりまで流れます。位置は基準の位置から、下端（右端）の外へ入ります。").font(.system(size: 11)).foregroundStyle(.secondary)
        } else if kind != .none {
            InspectorField(label: "長さ（秒）") {
                NumField(value: c.textAnim?.durationOrDefault ?? 1, step: 0.1, decimals: 2, clamp: { TextAnim.clampDuration($0) },
                         onCommit: { model.setTextAnim(kind, duration: $0, clipId: clipId) },
                         onStep: { model.coalescedTextAnimDuration($0, clipId: clipId) })
            }
            Text("クリップの頭からこの長さだけ動きます。").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
