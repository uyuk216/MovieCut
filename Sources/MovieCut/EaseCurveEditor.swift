import SwiftUI
import MovieCutCore

/// インスペクタの ◇ の横の小さなボタン。押すと曲線エディタのポップオーバーを開く。
struct EaseCurveButton: View {
    let ease: Ease
    let onCommit: (Ease) -> Void
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 12))
                .foregroundStyle(ease == .linear ? Color.secondary : Color.accentColor)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("次のキーフレームまでの動き方（イージング曲線）")
        .accessibilityLabel("イージング曲線を編集")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            EaseCurveEditor(ease: ease, onCommit: onCommit)
        }
    }
}

/// イージング曲線エディタ: 2 つの制御点をドラッグ、プリセット、数値欄、リセット。
/// ドラッグ中は手元の下書きで描き、離したとき・プリセット・数値確定・リセットで 1 回だけ `onCommit`(= 1 回の Undo)。
struct EaseCurveEditor: View {
    let ease: Ease
    let onCommit: (Ease) -> Void

    @State private var p: (x1: Double, y1: Double, x2: Double, y2: Double)
    @State private var dragging = false

    static let side: CGFloat = 200
    static let pad: CGFloat = 24

    init(ease: Ease, onCommit: @escaping (Ease) -> Void) {
        self.ease = ease
        self.onCommit = onCommit
        _p = State(initialValue: EaseCurve.controlPoints(ease))
    }

    private var draft: Ease { EaseCurve.ease(x1: p.x1, y1: p.y1, x2: p.x2, y2: p.y2) }

    private func commit() { onCommit(draft) }

    private func apply(_ e: Ease) {
        p = EaseCurve.controlPoints(e)
        onCommit(e)
    }

    // 座標変換(0〜1 ↔ 画面、y は上向きが大きい。y の範囲は yRange だが、見える枠は -0.5〜1.5)
    private static let viewY: ClosedRange<Double> = -0.5...1.5
    private func pt(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: Self.pad + CGFloat(x) * Self.side,
                y: Self.pad + CGFloat((Self.viewY.upperBound - y) / (Self.viewY.upperBound - Self.viewY.lowerBound)) * Self.side)
    }
    private func unpt(_ q: CGPoint) -> (Double, Double) {
        let x = Double((q.x - Self.pad) / Self.side)
        let y = Self.viewY.upperBound - Double((q.y - Self.pad) / Self.side) * (Self.viewY.upperBound - Self.viewY.lowerBound)
        return (x, y)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("イージング曲線").font(.headline)
            canvas
                .frame(width: Self.side + Self.pad * 2, height: Self.side + Self.pad * 2)
            presetButtons
            HStack(spacing: 6) {
                field("x1", \.x1, x: true); field("y1", \.y1, x: false)
                field("x2", \.x2, x: true); field("y2", \.y2, x: false)
            }
            HStack {
                if let name = EaseCurve.presetLabel(of: draft) { Text(name).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("リセット") { apply(EaseCurve.reset) }
                    .disabled(draft == EaseCurve.reset)
            }
        }
        .padding(14)
        .frame(width: Self.side + Self.pad * 2 + 28)
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                let frame = Path(CGRect(origin: pt(0, 1), size: CGSize(width: Self.side, height: pt(0, 0).y - pt(0, 1).y)))
                ctx.fill(frame, with: .color(Color.primary.opacity(0.05)))
                ctx.stroke(frame, with: .color(Color.secondary.opacity(0.5)), lineWidth: 1)
                var diag = Path(); diag.move(to: pt(0, 0)); diag.addLine(to: pt(1, 1))
                ctx.stroke(diag, with: .color(Color.secondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                // 制御点への線
                var h = Path()
                h.move(to: pt(0, 0)); h.addLine(to: pt(p.x1, p.y1))
                h.move(to: pt(1, 1)); h.addLine(to: pt(p.x2, p.y2))
                ctx.stroke(h, with: .color(Color.accentColor.opacity(0.7)), lineWidth: 1.5)
                // 曲線(プレビュー)
                var curve = Path()
                for (i, s) in EaseCurve.samples(draft).enumerated() {
                    let q = pt(s.u, s.v)
                    if i == 0 { curve.move(to: q) } else { curve.addLine(to: q) }
                }
                ctx.stroke(curve, with: .color(Color.primary), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                for e in [pt(0, 0), pt(1, 1)] {
                    ctx.fill(Path(ellipseIn: CGRect(x: e.x - 3, y: e.y - 3, width: 6, height: 6)), with: .color(Color.primary))
                }
            }
            handle(first: true)
            handle(first: false)
        }
        .coordinateSpace(name: "curve")
        .accessibilityElement(children: .contain)
    }

    private func handle(first: Bool) -> some View {
        let q = first ? pt(p.x1, p.y1) : pt(p.x2, p.y2)
        return Circle()
            .fill(Color.accentColor)
            .overlay(Circle().stroke(Color.white, lineWidth: 2))
            .frame(width: 14, height: 14)
            .position(q)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("curve"))
                .onChanged { v in
                    dragging = true
                    let (x, y) = unpt(v.location)
                    let c = EaseCurve.clampedPoints(first ? x : p.x1, first ? y : p.y1, first ? p.x2 : x, first ? p.y2 : y)
                    p = c
                }
                .onEnded { _ in dragging = false; commit() })
            .accessibilityLabel(first ? "制御点 1" : "制御点 2")
    }

    private var presetButtons: some View {
        let cols = [GridItem(.adaptive(minimum: 80), spacing: 6)]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 6) {
            ForEach(EaseCurve.presets, id: \.label) { pr in
                Button(pr.label) { apply(pr.ease) }
                    .controlSize(.small)
                    .font(.system(size: 11))
            }
        }
    }

    private func field(_ label: String, _ kp: WritableKeyPath<(x1: Double, y1: Double, x2: Double, y2: Double), Double>, x: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            CurveNumField(value: p[keyPath: kp]) { v in
                var q = p
                q[keyPath: kp] = v
                p = EaseCurve.clampedPoints(q.x1, q.y1, q.x2, q.y2)
                commit()
            }
        }
    }
}

/// 曲線の数値欄(Return・フォーカスが外れたときに確定)。
private struct CurveNumField: View {
    let value: Double
    let onCommit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .font(.system(size: 12).monospacedDigit())
            .focused($focused)
            .onSubmit { commit(); focused = false }
            .onChange(of: focused) { _, now in if !now { commit() } }
            .onChange(of: value) { _, v in if !focused { text = NumField.format(v, decimals: 3) } }
            .onAppear { text = NumField.format(value, decimals: 3) }
    }

    private func commit() {
        if let v = Double(text.trimmingCharacters(in: .whitespaces)), v.isFinite { onCommit(v) }
        text = NumField.format(value, decimals: 3)
    }
}
