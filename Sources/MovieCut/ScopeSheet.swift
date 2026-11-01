import SwiftUI
import MovieCutCore

/// 表示 ▸ スコープ…: 今のプレビューのコマ(現在位置)から、ヒストグラムと波形を出す。
struct ScopeSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var result: VideoScope.Result?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("スコープ").font(.title3.bold())
                Spacer()
                Text(String(format: "%.2f 秒のコマ", model.currentTime)).foregroundStyle(.secondary).monospacedDigit()
            }
            if let r = result {
                Text("ヒストグラム(R・G・B・輝度)").font(.caption).foregroundStyle(.secondary)
                HistogramView(result: r).frame(height: 130)
                Text("波形(横: 画面の左→右 / 縦: 暗い→明るい)").font(.caption).foregroundStyle(.secondary)
                WaveformView(result: r).frame(height: 200)
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            } else {
                Text("このコマを読めませんでした。").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            HStack {
                Text("表示用の値(sRGB)で、書き出しには影響しません。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("更新") { Task { await refresh() } }
                Button("閉じる") { model.showScopeSheet = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await refresh() }
    }

    private func refresh() async {
        loading = true
        let project = model.project, assets = model.assets, t = model.currentTime
        let scoped = await Task.detached(priority: .userInitiated) { () -> VideoScope.Result? in
            guard let img = Renderer(project: project, assets: assets).renderImage(t: t) else { return nil }
            return VideoScope.analyze(img, columns: 256)
        }.value
        result = scoped
        loading = false
    }
}

private struct HistogramView: View {
    let result: VideoScope.Result

    var body: some View {
        Canvas { ctx, size in
            let series: [(bins: [Int], color: Color)] = [
                (result.red, .red), (result.green, .green), (result.blue, .blue), (result.luma, .gray),
            ]
            let peak = max(1, series.flatMap(\.bins).max() ?? 1)
            for s in series {
                var path = Path()
                for (i, v) in s.bins.enumerated() {
                    let x = CGFloat(i) / 255 * size.width
                    let y = size.height - CGFloat(Double(v) / Double(peak)) * size.height
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                ctx.stroke(path, with: .color(s.color.opacity(0.85)), lineWidth: 1)
            }
        }
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct WaveformView: View {
    let result: VideoScope.Result

    var body: some View {
        Canvas { ctx, size in
            let cols = result.columns
            let maxCount = result.waveform.max() ?? 0
            let cw = size.width / CGFloat(cols), ch = size.height / 256
            for c in 0..<cols {
                for level in 0..<256 {
                    let n = result.waveform[c * 256 + level]
                    guard n > 0 else { continue }
                    let a = VideoScope.intensity(n, max: maxCount)
                    let rect = CGRect(x: CGFloat(c) * cw, y: size.height - CGFloat(level + 1) * ch, width: max(1, cw), height: max(1, ch))
                    ctx.fill(Path(rect), with: .color(.green.opacity(a)))
                }
            }
        }
        .background(Color.black.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
