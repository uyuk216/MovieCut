import SwiftUI
import MovieCutCore

/// クリップ ▸ 同じセリフのテイクを比較…: 同じセリフのボイスクリップを時刻順に並べ、長さ・声の長さ・音量・頭と終わりの無音を比べる。
/// 「試聴」で順に聞き比べ、「これだけ残す」で他のテイクを取り除く(1 回の Undo)。数字は開いたとき背景で測る。
struct TakeCompareSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var metrics: [String: TakeCompare.Metrics] = [:]

    private var groups: [TakeCompare.Group] { model.takeGroups }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("同じセリフのテイクを比較").font(.title3.bold())
                Spacer()
                Text("\(groups.count) 組").foregroundStyle(.secondary).monospacedDigit()
            }
            if groups.isEmpty {
                Text("同じセリフのボイスクリップがありません").foregroundStyle(.secondary)
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
                Text("セリフの表情タグ・空白・全角半角の違いは同じ扱いです。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("閉じる") { model.stopTakePlayback(); model.showTakeSheet = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 760)
        .task(id: groups.flatMap { $0.takes.map(\.clipId) }) { await measure() }
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
                    .help("このテイクを試聴")
                    Text(t.trackName).frame(width: 74, alignment: .leading).lineLimit(1)
                    Text(String(format: "%.2f 秒", t.start)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                    Text(String(format: "長さ %.2f", t.duration)).monospacedDigit().frame(width: 80, alignment: .trailing)
                        .foregroundStyle(abs(t.duration - shortest) < 1e-6 ? Color.green : Color.primary)
                    if let m = metrics[t.clipId] {
                        Text(Self.metricText(m)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("測定中…").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("移動") { model.focusTake(t) }.controlSize(.small)
                    Button("これだけ残す") { model.keepOnlyTake(t.clipId) }.controlSize(.small)
                        .help("同じセリフの他のテイクを取り除きます(1 回で元に戻せます)")
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    static func metricText(_ m: TakeCompare.Metrics) -> String {
        guard let avg = m.averageDb, let peak = m.peakDb else { return "声なし" }
        return String(format: "平均 %.1f dB  ピーク %.1f dB  頭 %.2f 秒  終わり %.2f 秒", avg, peak, m.leadSilence, m.trailSilence)
    }

    private func measure() async {
        let clips = groups.flatMap(\.takes).compactMap { model.clip($0.clipId) }
        for c in clips where metrics[c.id] == nil {
            let m = await Task.detached(priority: .utility) { TakeCompare.metrics(of: c) }.value
            if Task.isCancelled { return }
            if let m { metrics[c.id] = m }
        }
    }
}
