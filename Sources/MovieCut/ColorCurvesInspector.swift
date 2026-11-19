import SwiftUI
import MovieCutCore

/// 固定 x の制御点を縦ドラッグで動かす汎用カーブエディタ(トーンカーブ・色相カーブ共用)。
/// 値の読み書きは呼び出し側(`begin` / `change` / `end`)。ここでは描画とドラッグの座標変換だけを持つ。
struct AnchorCurveEditor: View {
    /// 制御点の x(0...1)。
    let xs: [Double]
    /// 制御点の現在の y。
    let values: [Double]
    /// y の範囲(下端...上端)。
    let yRange: ClosedRange<Double>
    /// 恒等線の y(x の関数)。
    let identity: (Double) -> Double
    /// 曲線の評価(x 0...1 → y)。
    let curve: (Double) -> Double
    /// 値の刻み。
    let step: Double
    /// 背景に虹色の帯(色相の横軸)を薄く描くか。
    var rainbow: Bool = false
    let label: String
    let locked: Bool
    let begin: () -> Void
    let change: (Int, Double) -> Void
    let end: () -> Void

    @State private var dragging = false

    private static let height: CGFloat = 150
    private static let pad: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width - Self.pad * 2, 1)
            let h = Self.height - Self.pad * 2
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    draw(&ctx, w: w, h: h)
                }
                ForEach(0..<min(xs.count, values.count), id: \.self) { i in
                    handle(i, w: w, h: h)
                }
            }
            .coordinateSpace(name: "anchorCurve")
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func pt(_ x: Double, _ y: Double, w: CGFloat, h: CGFloat) -> CGPoint {
        let span = yRange.upperBound - yRange.lowerBound
        return CGPoint(x: Self.pad + CGFloat(x) * w,
                       y: Self.pad + CGFloat((yRange.upperBound - y) / span) * h)
    }

    private func draw(_ ctx: inout GraphicsContext, w: CGFloat, h: CGFloat) {
        let frame = CGRect(x: Self.pad, y: Self.pad, width: w, height: h)
        if rainbow {
            // 入力色相の帯(薄く)
            let n = 48
            for k in 0..<n {
                let r = CGRect(x: Self.pad + w * CGFloat(k) / CGFloat(n), y: Self.pad, width: w / CGFloat(n) + 0.5, height: h)
                ctx.fill(Path(r), with: .color(Color(hue: (Double(k) + 0.5) / Double(n), saturation: 0.8, brightness: 0.9).opacity(0.22)))
            }
        } else {
            ctx.fill(Path(frame), with: .color(Color.primary.opacity(0.05)))
        }
        // 格子(4 分割)
        var grid = Path()
        for k in 1..<4 {
            let f = Double(k) / 4
            grid.move(to: pt(f, yRange.lowerBound, w: w, h: h)); grid.addLine(to: pt(f, yRange.upperBound, w: w, h: h))
            grid.move(to: pt(0, yRange.lowerBound + (yRange.upperBound - yRange.lowerBound) * f, w: w, h: h))
            grid.addLine(to: pt(1, yRange.lowerBound + (yRange.upperBound - yRange.lowerBound) * f, w: w, h: h))
        }
        ctx.stroke(grid, with: .color(Color.secondary.opacity(0.2)), lineWidth: 1)
        ctx.stroke(Path(frame), with: .color(Color.secondary.opacity(0.5)), lineWidth: 1)
        // 恒等線(破線)
        var idp = Path()
        idp.move(to: pt(0, identity(0), w: w, h: h)); idp.addLine(to: pt(1, identity(1), w: w, h: h))
        ctx.stroke(idp, with: .color(Color.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        // 曲線
        var path = Path()
        let samples = 96
        for k in 0...samples {
            let x = Double(k) / Double(samples)
            let y = min(max(curve(x), yRange.lowerBound), yRange.upperBound)
            let q = pt(x, y, w: w, h: h)
            if k == 0 { path.move(to: q) } else { path.addLine(to: q) }
        }
        ctx.stroke(path, with: .color(Color.primary), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    private func handle(_ i: Int, w: CGFloat, h: CGFloat) -> some View {
        let q = pt(xs[i], min(max(values[i], yRange.lowerBound), yRange.upperBound), w: w, h: h)
        return Circle()
            .fill(MCDesign.Color.accent)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .frame(width: 12, height: 12)
            .position(q)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("anchorCurve"))
                .onChanged { v in
                    guard !locked else { return }
                    if !dragging { dragging = true; begin() }
                    let span = yRange.upperBound - yRange.lowerBound
                    var y = yRange.upperBound - Double((v.location.y - Self.pad) / h) * span
                    y = min(max(y, yRange.lowerBound), yRange.upperBound)
                    if step > 0 { y = (y / step).rounded() * step }
                    change(i, min(max(y, yRange.lowerBound), yRange.upperBound))
                }
                .onEnded { _ in
                    if dragging { dragging = false; end() }
                })
            .accessibilityLabel("\(label) 点\(i + 1)")
    }
}

/// カラーカーブのインスペクタ(トーンカーブ 4 チャンネル + 色相カーブ 3 本)。
/// 値は `fx.<番号>.<引数名>` のキーフレーム項目で、スライダと同じ経路(beginGesture / liveKeyed / commitGesture)で書く。
struct ColorCurvesInspector: View {
    @ObservedObject var model: ProjectModel
    let clip: Clip
    let index: Int
    let clipId: String

    private enum Channel: Int, CaseIterable {
        case master, red, green, blue
        var key: String { ["master", "red", "green", "blue"][rawValue] }
        var label: String { ["マスター", "赤", "緑", "青"][rawValue] }
    }
    @State private var channel: Channel = .master

    private func key(_ base: String, _ i: Int) -> String { EffectKey.make(index, "\(base)\(i)") }

    private func values(_ base: String, count: Int = 5) -> [Double] {
        (0..<count).map { model.animatedValue(key(base, $0), of: clip) }
    }

    private func reset(base: String, to defaults: [Double]) {
        model.beginGesture()
        for (i, v) in defaults.enumerated() { model.liveKeyed(key(base, i), v, clipId: clipId) }
        model.commitGesture("カーブの変更")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toneSection
            hueSection(title: "色相→色相", base: "hueHue", range: -180...180, ident: 0, step: 1, defaults: 0) { c, x in
                c.hueShift(at: x)
            }
            hueSection(title: "色相→彩度", base: "hueSat", range: 0...2, ident: 1, step: 0.01, defaults: 1) { c, x in
                c.satScale(at: x)
            }
            hueSection(title: "色相→輝度", base: "hueLum", range: -0.5...0.5, ident: 0, step: 0.01, defaults: 0) { c, x in
                c.lumOffset(at: x)
            }
        }
    }

    // MARK: トーンカーブ

    @ViewBuilder private var toneSection: some View {
        let ys = values(channel.key)
        VStack(alignment: .leading, spacing: 6) {
            Text("トーンカーブ").font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
            Picker("チャンネル", selection: $channel) {
                ForEach(Channel.allCases, id: \.rawValue) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            AnchorCurveEditor(
                xs: ColorCurves.anchorX, values: ys, yRange: 0...1,
                identity: { $0 },
                curve: { ColorCurves.eval(ColorCurves.Curve(y: ys), $0) },
                step: 0.01, label: "トーンカーブ(\(channel.label))", locked: model.isLocked,
                begin: { model.beginGesture() },
                change: { i, v in model.liveKeyed(key(channel.key, i), v, clipId: clipId) },
                end: { model.commitGesture("カーブの変更") })
            HStack {
                Spacer()
                Button("リセット") { reset(base: channel.key, to: ColorCurves.anchorX) }
                    .controlSize(.small).disabled(model.isLocked || ys == ColorCurves.anchorX)
            }
        }
    }

    // MARK: 色相カーブ

    private func hueSection(title: String, base: String, range: ClosedRange<Double>, ident: Double, step: Double, defaults: Double,
                            eval: @escaping (ColorCurves.HueCurves, Double) -> Double) -> some View {
        let ys = values(base)
        let flat = Array(repeating: defaults, count: 5)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(MCDesign.Font.subheadline).foregroundStyle(MCDesign.Color.textSecondary)
                Spacer()
                Button("リセット") { reset(base: base, to: flat) }
                    .controlSize(.small).disabled(model.isLocked || ys == flat)
            }
            AnchorCurveEditor(
                xs: ColorCurves.hueAnchorX, values: ys, yRange: range,
                identity: { _ in ident },
                curve: { x in
                    // 種別ごとの配列だけ差し替えた色相カーブで評価する(他の 2 本は恒等)
                    var c = ColorCurves.HueCurves.identity
                    switch base {
                    case "hueHue": c.hueShiftY = ys
                    case "hueSat": c.satScaleY = ys
                    default: c.lumOffsetY = ys
                    }
                    return eval(c, x)
                },
                step: step, rainbow: true, label: title, locked: model.isLocked,
                begin: { model.beginGesture() },
                change: { i, v in model.liveKeyed(key(base, i), v, clipId: clipId) },
                end: { model.commitGesture("カーブの変更") })
        }
    }
}
