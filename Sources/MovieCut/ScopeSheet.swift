import SwiftUI
import MovieCutCore

/// 表示 ▸ スコープ…: 今のプレビューのコマ(現在位置)から、ヒストグラムと波形、ベクトルスコープ、RGB パレードを出す。
struct ScopeSheet: View {
    @ObservedObject var model: ProjectModel
    @State private var result: VideoScope.Result?
    @State private var vectorResult: VectorScope.Result?
    @State private var paradeResult: RGBParade.Result?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("スコープ").font(.title3.bold())
                Spacer()
                Text(String(format: "%.2f 秒のコマ", model.currentTime)).foregroundStyle(.secondary).monospacedDigit()
            }
            if let r = result {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ヒストグラム(R・G・B・輝度)").font(.caption).foregroundStyle(.secondary)
                        HistogramView(result: r).frame(height: 130)
                        Text("波形(横: 画面の左→右 / 縦: 暗い→明るい)").font(.caption).foregroundStyle(.secondary)
                        WaveformView(result: r).frame(height: 200)
                        if let v = vectorResult {
                            Text(L10n.t("ベクトルスコープ(中心: 無彩色 / 向き: 色相 / 距離: 彩度)")).font(.caption).foregroundStyle(.secondary)
                            HStack(alignment: .top, spacing: 12) {
                                VectorScopeView(result: v).frame(width: 240, height: 240)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(L10n.t("スキントーンライン")).font(.caption).foregroundStyle(.orange)
                                    Text(L10n.t("肌色はこの線の付近に集まります。")).font(.caption).foregroundStyle(.secondary)
                                    Text(L10n.t("外周の印は純色(R・M・B・C・G・Y)の位置です。")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let p = paradeResult {
                            Text(L10n.t("RGBパレード(横: 画面の左→右 / 縦: 暗い→明るい)")).font(.caption).foregroundStyle(.secondary)
                            ParadeView(result: p).frame(height: 160)
                        }
                    }
                }
                .frame(maxHeight: 560)
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
            Text(L10n.t("ベクトルスコープとパレードは表示用に間引いて計算します。")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 560)
        .task { await refresh() }
    }

    private func refresh() async {
        loading = true
        let project = model.project, assets = model.assets, t = model.currentTime
        let scoped = await Task.detached(priority: .userInitiated) { () -> (VideoScope.Result?, VectorScope.Result?, RGBParade.Result?) in
            guard let img = Renderer(project: project, assets: assets).renderImage(t: t) else { return (nil, nil, nil) }
            return (VideoScope.analyze(img, columns: 256), VectorScope.analyze(img), RGBParade.analyze(img, columns: 256))
        }.value
        result = scoped.0
        vectorResult = scoped.1
        paradeResult = scoped.2
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

/// ベクトルスコープ: 正方形の面に色差の分布を点の濃さで描く。目安として外周円・純色の印・スキントーンラインを重ねる。
private struct VectorScopeView: View {
    let result: VectorScope.Result

    var body: some View {
        Canvas { ctx, size in
            let side = min(size.width, size.height)
            let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
            let center = CGPoint(x: origin.x + side / 2, y: origin.y + side / 2)
            // 目安の円(半径は正規化座標の 0.5 と 1.0)
            for frac in [0.5, 1.0] {
                let r = side / 2 * CGFloat(frac)
                let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.25)), lineWidth: 1)
            }
            // 中心の十字
            var cross = Path()
            cross.move(to: CGPoint(x: center.x - side / 2, y: center.y)); cross.addLine(to: CGPoint(x: center.x + side / 2, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: center.y - side / 2)); cross.addLine(to: CGPoint(x: center.x, y: center.y + side / 2))
            ctx.stroke(cross, with: .color(.white.opacity(0.15)), lineWidth: 1)
            // スキントーンライン(中心から目安の角度へ)
            let end = VectorScope.skinToneLineEnd
            var skin = Path()
            skin.move(to: center)
            skin.addLine(to: CGPoint(x: center.x + CGFloat(end.x) * side / 2, y: center.y - CGFloat(end.y) * side / 2))
            ctx.stroke(skin, with: .color(.orange.opacity(0.8)), lineWidth: 1)
            // 純色の印と名前
            for target in VectorScope.targets {
                let p = CGPoint(x: center.x + CGFloat(target.chroma.normalizedX) * side / 2,
                                y: center.y - CGFloat(target.chroma.normalizedY) * side / 2)
                let box = CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                ctx.stroke(Path(box), with: .color(.white.opacity(0.7)), lineWidth: 1)
                ctx.draw(Text(target.name).font(.system(size: 9)).foregroundColor(.white.opacity(0.8)),
                         at: CGPoint(x: p.x, y: p.y - 10))
            }
            // 分布(密度グリッド)
            let cell = side / CGFloat(result.size)
            let maxCount = result.maxCount
            for row in 0..<result.size {
                for col in 0..<result.size {
                    let n = result.grid[row * result.size + col]
                    guard n > 0 else { continue }
                    let a = VectorScope.intensity(n, max: maxCount)
                    let rect = CGRect(x: origin.x + CGFloat(col) * cell, y: origin.y + CGFloat(row) * cell,
                                      width: max(1, cell), height: max(1, cell))
                    ctx.fill(Path(rect), with: .color(.green.opacity(a)))
                }
            }
        }
        .background(Color.black.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// RGB パレード: R・G・B の波形を 3 枚横に並べる。各面はそのチャンネルの色で描く。
private struct ParadeView: View {
    let result: RGBParade.Result

    var body: some View {
        HStack(spacing: 8) {
            panel(result.red, color: .red, label: "R")
            panel(result.green, color: .green, label: "G")
            panel(result.blue, color: .blue, label: "B")
        }
    }

    private func panel(_ bins: [Int], color: Color, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.bold()).foregroundStyle(color)
            Canvas { ctx, size in
                let cols = result.columns
                let maxCount = bins.max() ?? 0
                let cw = size.width / CGFloat(cols), ch = size.height / 256
                for c in 0..<cols {
                    for level in 0..<256 {
                        let n = bins[c * 256 + level]
                        guard n > 0 else { continue }
                        let a = RGBParade.intensity(n, max: maxCount)
                        let rect = CGRect(x: CGFloat(c) * cw, y: size.height - CGFloat(level + 1) * ch, width: max(1, cw), height: max(1, ch))
                        ctx.fill(Path(rect), with: .color(color.opacity(a)))
                    }
                }
            }
            .background(Color.black.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
