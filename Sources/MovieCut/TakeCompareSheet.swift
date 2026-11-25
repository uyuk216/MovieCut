import SwiftUI
import MovieCutCore

/// クリップ ▸ 同じセリフのテイクを比較…: 同じセリフのボイスクリップを時刻順に並べ、長さ・声の長さ・音量・頭と終わりの無音を比べる。
/// 「試聴」で順に聞き比べ、「これだけ残す」で他のテイクを取り除く(1 回の Undo)。数字は開いたとき背景で測る。
struct TakeCompareSheet: View {
    @ObservedObject var model: ProjectModel
    /// 測定結果は clip.id だけでなく内容(長さ・素材・開始位置など)の鍵で覚える(再合成・トリム後に古い数値を出さない)。
    @State private var metrics: [String: TakeCompare.Metrics] = [:]
    /// 測定が終わったが結果が得られなかった鍵(「測定中…」のままにしない)。
    @State private var unmeasurable: Set<String> = []

    /// クリップ内容を表す測定結果の鍵。
    static func metricsKey(_ c: Clip) -> String {
        "\(c.id)|\(c.src ?? "")|\(c.start)|\(c.duration)|\(c.offset)|\(c.srcDuration ?? -1)|\(c.speed ?? 1)"
    }

    private var groups: [TakeCompare.Group] { model.takeGroups }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.t("同じセリフのテイクを比較")).font(.title3.bold())
                Spacer()
                Text(String(format: L10n.t("%d 組"), groups.count)).foregroundStyle(.secondary).monospacedDigit()
            }
            if groups.isEmpty {
                InspectorGuideCard(symbol: "waveform.badge.magnifyingglass", heading: "同じセリフのボイスクリップがありません", message: "同じセリフのテイクが複数あると、ここで聞き比べられます。")
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { g in groupView(g) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 260, maxHeight: 460)
            }
            HStack {
                Text(L10n.t("セリフの表情タグ・空白・全角半角の違いは同じ扱いです。")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.t("閉じる")) { model.stopTakePlayback(); model.showTakeSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 760)
        .task(id: groups.flatMap { $0.takes.compactMap { model.clip($0.clipId).map(Self.metricsKey) } }) { await measure() }
        .onDisappear { model.stopTakePlayback() }
    }

    @ViewBuilder private func groupView(_ g: TakeCompare.Group) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("「\(g.text)」").font(.headline).lineLimit(2)
            let shortest = g.takes.map(\.duration).min() ?? 0
            ForEach(g.takes) { t in
                HStack(spacing: 10) {
                    Button { if model.takePlayingId == t.clipId { model.stopTakePlayback() } else { model.playTake(clipId: t.clipId) } } label: {
                        Image(systemName: model.takePlayingId == t.clipId ? "stop.fill" : "play.fill")
                    }
                    .help(L10n.t("このテイクを試聴"))
                    Text(t.trackName).frame(width: 74, alignment: .leading).lineLimit(1)
                    Text(String(format: L10n.t("%.2f 秒"), t.start)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                    Text(String(format: L10n.t("長さ %.2f"), t.duration)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        .foregroundStyle(abs(t.duration - shortest) < 1e-6 ? Color.green : Color.primary)
                    let key = model.clip(t.clipId).map(Self.metricsKey)
                    if let key, let m = metrics[key] {
                        Text(Self.metricText(m)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
                    } else if let key, unmeasurable.contains(key) {
                        Text(L10n.t("測れませんでした")).font(.caption).foregroundStyle(.tertiary)
                    } else {
                        Text(L10n.t("測定中…")).font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button(L10n.t("移動")) { model.focusTake(t) }.controlSize(.small)
                    Button(L10n.t("これだけ残す")) { model.keepOnlyTake(t.clipId) }.controlSize(.small)
                        .help(L10n.t("同じセリフの他のテイクを取り除きます(1 回で元に戻せます)"))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    static func metricText(_ m: TakeCompare.Metrics) -> String {
        guard let avg = m.averageDb, let peak = m.peakDb else { return "声なし" }
        return String(format: L10n.t("平均 %.1f dB  ピーク %.1f dB  頭 %.2f 秒  終わり %.2f 秒"), avg, peak, m.leadSilence, m.trailSilence)
    }

    private func measure() async {
        let clips = groups.flatMap(\.takes).compactMap { model.clip($0.clipId) }
        for c in clips {
            let key = Self.metricsKey(c)
            if metrics[key] != nil || unmeasurable.contains(key) { continue }
            let m = await Task.detached(priority: .utility) { TakeCompare.metrics(of: c) }.value
            if Task.isCancelled { return }   // シートを閉じた/対象が変わったら反映しない
            if let m { metrics[key] = m } else { unmeasurable.insert(key) }
        }
    }
}
