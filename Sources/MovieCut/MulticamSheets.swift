import SwiftUI
import MovieCutCore

/// マルチカメラの 2 つのシート(作る / 切り替える)をまとめて付ける。
struct MulticamSheets: ViewModifier {
    @ObservedObject var model: ProjectModel
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $model.showMulticamCreateSheet) { MulticamCreateSheet(model: model) }
            .sheet(isPresented: $model.showMulticamSwitchSheet) { MulticamSwitchSheet(model: model) }
    }
}

/// クリップ ▸ マルチカメラを作る…: 選んだ映像クリップの音を基準(いちばん先頭のクリップ)に合わせ、ずれを確かめて(手で直して)グループを作る。
struct MulticamCreateSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var measuring = true
    @State private var measured: [String: Double?] = [:]
    @State private var texts: [String: String] = [:]
    @State private var failed = false
    /// 手で書き換えた欄(測定結果で上書きしない)
    @State private var edited: Set<String> = []
    /// true = マルチカムクリップとして 1 つのクリップに置く(既定)。false = 従来のグループ方式。
    @State private var placeAsClip = true

    private var angles: [Clip] { Multicam.candidates(in: model.project, ids: model.multicamCreateIds) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("マルチカメラを作る")).font(.headline)
            Text(L10n.t("選んだ映像を、いちばん先頭のクリップ(カメラ1)の音に合わせます。音は既定でカメラ1のものを使います。"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 440, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            Picker(L10n.t("置き方"), selection: $placeAsClip) {
                Text(L10n.t("マルチカムクリップとして配置")).tag(true)
                Text(L10n.t("グループ(従来の切り替え方式)")).tag(false)
            }.pickerStyle(.radioGroup)
            Text(placeAsClip
                 ? L10n.t("カメラ1の位置に 1 つのクリップとして置きます。ほかの元クリップはタイムラインから外れ、アングルとしてクリップの中に入ります。インスペクタや 1〜9 キーでアングルを切り替えられます。")
                 : L10n.t("新しいレイヤーに切り替えの結果を置きます。元のクリップはそのまま残り、カメラ1以外は無音になります。「マルチカメラ切替…」で切り替えます。"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 440, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            if measuring { HStack { ProgressView().controlSize(.small); Text(L10n.t("音を比べています…")).font(.caption) } }
            ForEach(Array(angles.enumerated()), id: \.element.id) { i, c in
                HStack {
                    Text(String(format: L10n.t("カメラ%d"), i + 1)).frame(width: 64, alignment: .leading)
                    Text(((c.src ?? "") as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle).frame(width: 150, alignment: .leading)
                    if i == 0 {
                        Text(L10n.t("基準")).foregroundStyle(.secondary)
                    } else {
                        TextField("0", text: Binding(get: { texts[c.id] ?? "0" }, set: { texts[c.id] = $0; edited.insert(c.id) })).textFieldStyle(.roundedBorder).frame(width: 70)
                        Text(L10n.t("秒")).foregroundStyle(.secondary)
                        status(c.id)
                    }
                }
            }
            Text(L10n.t("ずれ: 基準より何秒遅れて同じ出来事が写っているか(負なら早い)。音が合わなかったときは、ここで手で入れます。"))
                .font(.caption).foregroundStyle(.secondary)
            if failed { Text(L10n.t("ずれは数字で入れてください")).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L10n.t("キャンセル")) { model.showMulticamCreateSheet = false }.keyboardShortcut(.cancelAction)
                Button(L10n.t("作成")) { commit() }.keyboardShortcut(.defaultAction).disabled(measuring)
            }
        }
        .padding(16)
        .task { await measure() }
    }

    @ViewBuilder private func status(_ id: String) -> some View {
        if measuring { EmptyView() }
        else if let v = measured[id], v != nil { Text(L10n.t("音で合わせました")).font(.caption).foregroundStyle(.green) }
        else { Text(L10n.t("合わせられませんでした")).font(.caption).foregroundStyle(.orange) }
    }

    private func measure() async {
        let result = await model.measureMulticamLags(ids: model.multicamCreateIds)
        measured = result
        for (id, v) in result {
            // 手入力済みの欄、測定失敗(nil)の欄は変えない
            if edited.contains(id) { continue }
            if let v { texts[id] = Self.format(v) }
        }
        measuring = false
    }

    static func format(_ v: Double) -> String { String(format: "%g", (v * 100).rounded() / 100) }

    /// ずれの上限(秒)。Core 側に上限が無いので ±1 時間に収める。
    static let maxLag: Double = 3600
    static func clampLag(_ v: Double) -> Double { min(max(v, -maxLag), maxLag) }

    private func commit() {
        var lags: [String: Double] = [:]
        for c in angles.dropFirst() {
            let raw = (texts[c.id] ?? "0").replacingOccurrences(of: "−", with: "-").trimmingCharacters(in: .whitespaces)
            guard let v = Double(raw), v.isFinite else { failed = true; return }
            // 測れた値はそのまま(丸めない)、手で直したときだけ入力の値を使う
            if let m = measured[c.id], let mv = m, texts[c.id] == Self.format(mv) { lags[c.id] = Self.clampLag(mv) } else { lags[c.id] = Self.clampLag(v) }
        }
        failed = false
        if placeAsClip { _ = model.createMulticamClip(ids: model.multicamCreateIds, localLags: lags) }
        else { _ = model.createMulticam(ids: model.multicamCreateIds, localLags: lags) }
        model.showMulticamCreateSheet = false
    }
}

/// クリップ ▸ マルチカメラ切替…: 再生しながら 1〜9 のキー(またはボタン)でアングルを切り替える。切り替えは普通の分割クリップになる。
/// 1〜9 のキーはこのシートが開いている間だけ有効(アプリ全体のショートカットにはしない)。
struct MulticamSwitchSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var groupId: String?

    private var group: MulticamGroup? {
        let gs = model.project.multicams
        return gs.first { $0.id == groupId } ?? model.activeMulticam ?? gs.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("マルチカメラ切替")).font(.headline)
            if model.project.multicams.count > 1 {
                Picker(L10n.t("グループ"), selection: Binding(get: { group?.id ?? "" }, set: { groupId = $0 })) {
                    ForEach(model.project.multicams) { Text($0.name).tag($0.id) }
                }.frame(width: 300)
            }
            Text(L10n.t("再生しながら、1〜9 のキーかボタンで、その時刻からそのカメラに切り替えます。切り替えは 1 回ずつ元に戻せます。"))
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 420, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(model.isPlaying ? "一時停止" : "再生") { model.playback.togglePlay() }
                Text(String(format: L10n.t("%.2f 秒"), model.currentTime)).monospacedDigit().foregroundStyle(.secondary)
            }
            if let g = group {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(62), spacing: 6), count: 5), alignment: .leading, spacing: 6) {
                    ForEach(Array(g.angles.enumerated()), id: \.offset) { i, a in
                        Button { _ = model.multicamCut(angle: i, groupId: g.id) } label: {
                            VStack { Text("\(i + 1)").font(.title2.bold()); Text(a.name).font(.caption2) }.frame(width: 62, height: 44)
                        }
                        .modifier(AngleKeyModifier(index: i))
                    }
                }
                if let r = g.range, model.currentTime < r.lowerBound || model.currentTime >= r.upperBound {
                    Text(L10n.t("再生位置が基準のカメラの範囲の外です")).font(.caption).foregroundStyle(.orange)
                }
            }
            Text(model.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(width: 420, alignment: .leading)
            HStack { Spacer(); Button(L10n.t("閉じる")) { model.showMulticamSwitchSheet = false }.keyboardShortcut(.cancelAction) }
        }
        .padding(16)
    }
}

/// 1〜9 番目のアングルだけ数字キーを割り当てる(10 個目以降は付けない)。
private struct AngleKeyModifier: ViewModifier {
    let index: Int
    func body(content: Content) -> some View {
        if index < 9 { content.keyboardShortcut(KeyEquivalent(Swift.Character(String(index + 1))), modifiers: []) } else { content }
    }
}

/// インスペクタの「マルチカム」: マルチカムクリップの有効アングル(映像)と音声アングルを選ぶ。
/// 映像はクリップ全体のアングルを変える(再生位置で分けて切り替えるときは 1〜9 キー / クリップ ▸ アングルに切り替え)。
struct MulticamClipSection: View {
    @ObservedObject var model: ProjectModel
    let clip: Clip

    var body: some View {
        if let info = clip.multicam {
            VStack(alignment: .leading, spacing: 6) {
                InspectorSection(title: L10n.t("マルチカム"))
                Picker(L10n.t("映像のアングル"), selection: Binding(get: { info.activeAngle }, set: { i in
                    model.selectedClipId = clip.id
                    _ = model.multicamClipCut(angle: i, atPlayhead: false)
                })) {
                    ForEach(Array(info.angles.enumerated()), id: \.offset) { i, a in Text("\(i + 1). \(a.name)").tag(i) }
                }
                Picker(L10n.t("音声のアングル"), selection: Binding(get: { info.audioAngle }, set: { i in
                    model.selectedClipId = clip.id
                    _ = model.setMulticamAudioAngle(i)
                })) {
                    ForEach(Array(info.angles.enumerated()), id: \.offset) { i, a in
                        Text("\(i + 1). \(a.name)\(i == 0 ? L10n.t("(基準)") : "")").tag(i)
                    }
                }
                Text(L10n.t("再生位置から切り替えるには 1〜9 キー(再生中も効きます)。切り替えは再生位置で分割され、1 回ずつ元に戻せます。"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if info.angles.count > 0 { AngleGrid(info: info, clipId: clip.id, model: model) }
            }
        }
    }
}

/// 全アングルの一覧(ボタン): 押すとそのアングルに(再生位置から)切り替える。映像の同時プレビューではなく、番号つきの切り替えボタン。
private struct AngleGrid: View {
    let info: MulticamClipInfo
    let clipId: String
    @ObservedObject var model: ProjectModel
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(56), spacing: 6), count: 4), alignment: .leading, spacing: 6) {
            ForEach(Array(info.angles.enumerated()), id: \.offset) { i, a in
                Button {
                    model.selectedClipId = clipId
                    _ = model.multicamClipCut(angle: i, atPlayhead: true)
                } label: {
                    VStack { Text("\(i + 1)").font(.headline); Text(a.name).font(.caption2).lineLimit(1) }
                        .frame(width: 52, height: 38)
                        .background(i == info.activeAngle ? Color.accentColor.opacity(0.25) : Color.clear)
                }
            }
        }
    }
}
