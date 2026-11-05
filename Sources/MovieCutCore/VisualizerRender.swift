import Foundation
import CoreGraphics

// MARK: - 音声ビジュアライザの描画(Renderer の拡張)
//
// 合成音声(書き出しと同じミックス。`source` があればその音声クリップだけ)の、時刻 t の 1/60 秒の RMS(音量モード)
// または 1/60 秒ごとの FFT の帯の値(スペクトルモード。`SpectrumAnalyzer`)だけで決まる(決定的。乱数・時間の揺れは無い)。
// 高さ = 最小の高さ + (1 − 最小) × 棒ごとの形 × 音量。無音は細い線、大きい音は枠いっぱい。

extension Renderer {
    /// 音量 0〜1 への倍率。RMS 0.4 で頭打ち(普通の話し声は 0.05〜0.2 くらい)。
    static let vizGain: Float = 2.5
    /// 無音でも見えるように残す高さ(枠の割合)。
    static let vizMinFraction: Double = 0.04

    /// 時刻 t の合成音声の音量(0〜1 に収めたもの)。エンベロープが無い・範囲外は 0。
    static func vizLoudness(_ env: [Float]?, t: Double) -> Double {
        guard let env else { return 0 }
        let i = Int(floor(t * 60))
        guard i >= 0, i < env.count else { return 0 }
        return min(1, max(0, Double(env[i] * vizGain)))
    }

    /// 棒 i の形(0.6〜1)。並びを単調にしないための決まった揺らぎ。
    static func vizShape(_ i: Int) -> Double {
        0.6 + 0.4 * (0.5 + 0.5 * sin(Double(i) * 1.7 + 0.8))
    }

    /// 棒の高さ(枠の高さに対する割合)。
    static func vizHeight(_ i: Int, loud: Double) -> Double {
        vizMinFraction + (1 - vizMinFraction) * vizShape(i) * loud
    }

    /// スペクトルモードの帯 b の高さ(枠の割合)。帯の値(0〜1)がそのまま高さ。
    static func vizSpectrumHeight(_ v: Float) -> Double {
        vizMinFraction + (1 - vizMinFraction) * min(1, max(0, Double(v)))
    }

    /// 時刻 t の各棒の高さ(枠に対する割合)。音量モードは全体の音量 × 棒ごとの形、スペクトルモードは帯ごとの値。
    /// 解析は `RenderAssets` が音の内容ごとに 1 回だけ作る(プレビューと書き出しで同じ配列)。
    func vizHeights(_ vz: Visualizer, t: Double) -> [Double] {
        let n = vz.countOrDefault
        if vz.isSpectrum {
            let spec = assets.vizSpectrum(for: project, source: vz.source, count: n)
            let k = Int(floor(t * SpectrumAnalyzer.frameRate))
            return (0..<n).map { b in
                guard let spec, k >= 0, (k + 1) * n <= spec.count else { return Self.vizMinFraction }
                return Self.vizSpectrumHeight(spec[k * n + b])
            }
        }
        let loud = Self.vizLoudness(assets.vizEnvelope(for: project, source: vz.source), t: t)
        return (0..<n).map { Self.vizHeight($0, loud: loud) }
    }

    /// 音声ビジュアライザを描く(左上原点の ctx)。枠は x・y(中心)と w・h(キャンバスに対する割合)。
    func drawVisualizer(_ c: Clip, t: Double, ctx: CGContext, W: Double, H: Double) {
        let r = t - c.start
        let cx = Animation.value(of: "x", in: c, at: r) * W, cy = Animation.value(of: "y", in: c, at: r) * H
        let bw = Animation.value(of: "w", in: c, at: r) * W, bh = Animation.value(of: "h", in: c, at: r) * H
        guard bw > 0, bh > 0 else { return }
        let vz = c.visualizerOrDefault
        let n = vz.countOrDefault
        let heights = vizHeights(vz, t: t)
        let left = cx - bw / 2, bottom = cy + bh / 2
        let color = parseHexColor(vz.colorOrDefault) ?? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setAlpha(CGFloat(c.opacityOrDefault))
        ctx.setFillColor(color)
        if vz.styleOrDefault == "wave" {
            // 上下対称の帯。点の列を上の縁・下の縁とつないで閉じる
            let path = CGMutablePath()
            let step = bw / Double(n - 1)
            for i in 0..<n {
                let a = heights[i] * bh / 2
                let p = CGPoint(x: left + step * Double(i), y: cy - a)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            for i in stride(from: n - 1, through: 0, by: -1) {
                let a = heights[i] * bh / 2
                path.addLine(to: CGPoint(x: left + step * Double(i), y: cy + a))
            }
            path.closeSubpath()
            ctx.addPath(path)
            ctx.fillPath()
        } else {
            // 棒: 下の縁から立つ。隙間は棒の幅の 2/3
            let slot = bw / Double(n)
            let barW = slot * 0.6
            for i in 0..<n {
                let h = heights[i] * bh
                let x = left + slot * (Double(i) + 0.5) - barW / 2
                ctx.fill(CGRect(x: x, y: bottom - h, width: barW, height: h))
            }
        }
    }
}
