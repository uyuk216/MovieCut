import SwiftUI
import MovieCutCore

/// 口を動かす声の選択(立ち絵クリップごと)。「すべての声」「動かさない」「キャラクターの声」「特定の声クリップ」。
struct MouthDrivePicker: View {
    @ObservedObject var model: ProjectModel
    let clip: Clip

    /// 声クリップの選択肢の上限(多すぎるとメニューが長くなる。選んでいるものは必ず含める)。
    static let maxVoiceChoices = 40

    static func voiceLabel(_ v: Clip) -> String {
        let body = ExpressionTag.body(v.text ?? "")
        let head = body.count > 14 ? String(body.prefix(14)) + "…" : body
        return "\(timecode(v.start)) \(head.isEmpty ? "(空のセリフ)" : head)"
    }

    var body: some View {
        let cur = clip.mouthDriveOrDefault
        let voices = model.project.allClips.filter { $0.type == .voice }.sorted { $0.start < $1.start }
        let shown: [Clip] = {
            var list = Array(voices.prefix(Self.maxVoiceChoices))
            if case .voiceClip(let id) = cur, !list.contains(where: { $0.id == id }), let v = voices.first(where: { $0.id == id }) { list.append(v) }
            return list
        }()
        InspectorField(label: "口を動かす声") {
            Picker("", selection: Binding(get: { cur.raw }, set: { raw in
                if let d = MouthDrive(raw: raw) { model.setTachieMouthDrive(clipId: clip.id, drive: d) }
            })) {
                Text("すべての声").tag(MouthDrive.all.raw)
                Text("動かさない").tag(MouthDrive.none.raw)
                Divider()
                ForEach(model.project.characters) { ch in
                    Text("キャラクター「\(ch.name)」の声").tag(MouthDrive.character(ch.id).raw)
                }
                if case .character(let id) = cur, !model.project.characters.contains(where: { $0.id == id }) {
                    Text("(消えたキャラの声)").tag(cur.raw)
                }
                if !shown.isEmpty { Divider() }
                ForEach(shown) { v in Text("声クリップ: " + Self.voiceLabel(v)).tag(MouthDrive.voiceClip(v.id).raw) }
                if case .voiceClip(let id) = cur, !voices.contains(where: { $0.id == id }) {
                    Text("(消えた声クリップ)").tag(cur.raw)
                }
            }
            .labelsHidden()
        }
        .disabled(model.isLocked)
    }
}

/// 立ち絵クリップのプロパティ(素材・口の連動・声に合わせる)と、素材のパーツ欄。
struct TachieClipSection: View {
    @ObservedObject var model: ProjectModel
    let clip: Clip

    var body: some View {
        InspectorSection(title: "立ち絵")
        InspectorField(label: "素材") {
            Picker("", selection: Binding(get: { clip.tachieId ?? "" }, set: { model.setClipTachie(clipId: clip.id, tachieId: $0) })) {
                if model.tachie(clip.tachieId) == nil { Text("（消えた素材）").tag(clip.tachieId ?? "") }
                ForEach(model.project.tachies) { Text($0.name.isEmpty ? "立ち絵" : $0.name).tag($0.id) }
            }
            .labelsHidden()
        }
        .disabled(model.isLocked)
        MouthDrivePicker(model: model, clip: clip)
        Toggle("声が出ている間だけ表示", isOn: Binding(get: { clip.speakingOnly == true }, set: { v in
            model.setClipProperty({ $0.speakingOnly = v ? true : nil }, name: "声が出ている間だけ表示の切り替え", clipId: clip.id)
        }))
        .toggleStyle(.checkbox)
        .disabled(model.isLocked)
        Toggle("プロジェクトの長さに合わせる", isOn: Binding(get: { clip.followsProjectEnd == true }, set: { model.setTachieFollowsProjectEnd(clipId: clip.id, $0) }))
            .toggleStyle(.checkbox)
            .disabled(model.isLocked)
            .help("終わりをプロジェクトの終わりに合わせ続けます。あとから声を足しても届きます（クリップの長さを手で変えるとやめます）")
        HStack(spacing: 6) {
            Button("声の長さに合わせる") { model.fitTachieClipToVoice(clipId: clip.id) }
                .disabled(model.isLocked || TachieEditing.voiceSpan(model.project, clip: clip) == nil)
                .help("連動する声の最初の頭から最後の終わりまでに、クリップを合わせます")
            if let s = TachieEditing.voiceSpan(model.project, clip: clip) {
                Text("声 \(timecode(s.start))–\(timecode(s.end))").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("連動する声がありません").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        if let t = model.tachie(clip.tachieId) {
            TachieExpressionRow(model: model, clip: clip, tachie: t)
            TachieAssetBody(model: model, tachie: t)
        }
    }
}

/// 展開した立ち絵クリップの表情の切り替えを、再生位置で足す・外す(声のセリフの先頭の [表情名] を書き換える。Undo 1 回)。
struct TachieExpressionRow: View {
    @ObservedObject var model: ProjectModel
    let clip: Clip
    let tachie: Tachie
    @State private var pick = ""

    var body: some View {
        let names = TachieEditing.expressionNames(of: tachie)
        let voice = TachieEditing.driverVoice(model.project, clip: clip, at: model.currentTime)
        let current = voice.flatMap { ExpressionTag.split($0.text ?? "").tag }
        InspectorSection(title: "表情の切り替え（再生位置）")
        Text(voice == nil ? "再生位置に連動する声がありません"
             : "再生位置の声の表情: \(current ?? "通常")（切り替わるのは声の頭。声のセリフの先頭に [表情名] が付きます）")
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 6) {
            Picker("", selection: $pick) {
                Text("表情を選ぶ").tag("")
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(maxWidth: 160)
            Button("足す") { model.setTachieExpressionAtPlayhead(clipId: clip.id, tag: pick) }
                .disabled(pick.isEmpty || voice == nil)
                .help("再生位置の声の表情をこれにします")
            Button("外す") { model.setTachieExpressionAtPlayhead(clipId: clip.id, tag: nil) }
                .disabled(current == nil)
                .help("再生位置の声の表情を通常に戻します")
        }
        .controlSize(.small)
        .disabled(model.isLocked)
        .onAppear { if pick.isEmpty, let f = names.first { pick = f } }
    }
}

/// 立ち絵素材の中身の設定(バウンス・パーツ欄・画像式の読み取り表示)。クリップの欄とコレクションの欄の両方で使う。
struct TachieAssetBody: View {
    @ObservedObject var model: ProjectModel
    let tachie: Tachie

    private func fileName(_ p: String?) -> String { p.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "なし" }

    var body: some View {
        Toggle("バウンス（話し中に上下に揺れる）", isOn: Binding(get: { tachie.bounce == true }, set: { v in model.setTachieBounce(tachieId: tachie.id, v) }))
            .toggleStyle(.checkbox)
            .disabled(model.isLocked)
        if let rig = tachie.rig, rig.hasParts {
            RigInspectorSection(model: model, tachieId: tachie.id, rig: rig)
        } else {
            InspectorSection(title: "画像")
            ForEach([("口閉じ", tachie.imgClosed), ("口開き", tachie.imgOpen), ("まばたき", tachie.imgBlink)], id: \.0) { label, path in
                HStack(spacing: 8) {
                    PortraitThumb(path: path)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(fileName(path)).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
            }
            if !(tachie.imgVowels ?? [:]).isEmpty || !(tachie.expressions ?? [:]).isEmpty {
                Text("あいうえお \((tachie.imgVowels ?? [:]).count) 枚・表情 \((tachie.expressions ?? [:]).count) 枚").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

/// 立ち絵素材を左の一覧で選んだときのプロパティ(名前・パーツ・口の設定。クリップを置くボタン)。
struct TachieInspector: View {
    @ObservedObject var model: ProjectModel
    let tachieId: String

    var body: some View {
        if let t = model.tachie(tachieId) {
            VStack(alignment: .leading, spacing: 8) {
                InspectorSection(title: "立ち絵素材")
                InspectorField(label: "名前") {
                    NameField(value: t.name) { model.renameTachie(id: tachieId, to: $0) }
                }
                .disabled(model.isLocked)
                Button { _ = model.addTachieClip(tachieId: tachieId) } label: { Text("再生位置にクリップを置く").frame(maxWidth: .infinity) }
                    .disabled(model.isLocked)
                    .help("この立ち絵をタイムラインの再生位置に置きます（口は、すべての声に連動）")
                TachieAssetBody(model: model, tachie: t)
                Button(role: .destructive) { model.removeTachie(id: tachieId) } label: { Text("この立ち絵素材を消す").foregroundStyle(Color(red: 1, green: 0.45, blue: 0.42)).frame(maxWidth: .infinity) }
                    .disabled(model.isLocked)
                    .help("使っている立ち絵クリップも一緒に消えます")
            }
        }
    }
}
