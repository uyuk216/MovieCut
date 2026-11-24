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

    private var angles: [Clip] { Multicam.candidates(in: model.project, ids: model.multicamCreateIds) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("マルチカメラを作る")).font(.headline)
            Text(L10n.t("選んだ映像を、いちばん先頭のクリップ(カメラ1)の音に合わせます。音はカメラ1のものを使い、ほかのカメラの元のクリップは無音になります。"))
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
        _ = model.createMulticam(ids: model.multicamCreateIds, localLags: lags)
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
