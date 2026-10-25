import SwiftUI
import AppKit
import QuartzCore
import MovieCutCore

// MARK: - 色

private func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

/// style.css の色(.clip.video など)。
enum TimelinePalette {
    static let video = rgb(0x3d6bb3), image = rgb(0x3f8f6b), audio = rgb(0x8a5ab0), text = rgb(0xb07a3a), blur = rgb(0xb0436a)
    static let unknown = rgb(0x3c4050)
    static let voiceBase: (r: CGFloat, g: CGFloat, b: CGFloat) = (0x16 / 255.0, 0x17 / 255.0, 0x1c / 255.0)
    static let areaBG = rgb(0x191a1e), panel = rgb(0x26282f), line = rgb(0x383b45), rowLine = rgb(0x2a2c33)
    static let rulerBG = rgb(0x22242a), tick = rgb(0x5a5d6a), tickText = rgb(0xcfd1da), label = rgb(0xb9bcc8), text0 = rgb(0xe6e6ea)
    static let playhead = rgb(0xff4f6a), selection = rgb(0xffd84f), accent = rgb(0x4f8cff)
    /// マーカーの旗と案内線の色。
    static let marker = rgb(0x3dd6c0)

    /// 種類ごとの色。ボイスはキャラの色を 42% だけ暗い下地に混ぜる。
    static func color(for type: ClipType) -> NSColor {
        switch type {
        case .video: return video
        case .image: return image
        case .audio: return audio
        case .text: return text
        case .blur: return blur
        default: return unknown
        }
    }

    static func voiceFill(character c: NSColor) -> NSColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        let k: CGFloat = 0.42
        return NSColor(srgbRed: s.redComponent * k + voiceBase.r * (1 - k), green: s.greenComponent * k + voiceBase.g * (1 - k),
                       blue: s.blueComponent * k + voiceBase.b * (1 - k), alpha: 1)
    }
}

private func nsColor(hex: String) -> NSColor? {
    guard let c = parseHexColor(hex) else { return nil }
    return NSColor(cgColor: c)
}

// MARK: - SwiftUI の外側(ツールバー + キャンバス)

struct TimelineSection: View {
    @ObservedObject var model: ProjectModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("＋レイヤー") { model.addTrack() }
                    .disabled(model.isLocked)
                Text("拡大")
                Slider(value: $model.pps, in: TimelineLayout.minPps...TimelineLayout.maxPps).frame(width: 140)
                Button("全体表示") { model.onFitTimeline() }
                Toggle("吸着", isOn: $model.snapEnabled)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            TimelineRepresentable(model: model)
        }
        .clipped()
    }
}

/// モデルの値をキャンバスへ渡す。
struct TimelineRepresentable: NSViewRepresentable {
    @ObservedObject var model: ProjectModel

    func makeNSView(context: Context) -> TimelineCanvas {
        let v = TimelineCanvas()
        v.model = model
        if ProcessInfo.processInfo.environment["MC_NOCANVAS"] != nil { v.isHidden = true }
        model.onFitTimeline = { [weak v] in v?.fitToWindow() }
        v.apply(state)
        return v
    }

    func updateNSView(_ v: TimelineCanvas, context: Context) {
        v.model = model
        v.apply(state)
    }

    private var state: TimelineState {
        TimelineState(project: model.project, revision: model.projectRevision, selectedId: model.selectedClipId,
                      time: model.currentTime, pps: model.pps, playing: model.isPlaying)
    }
}

struct TimelineState {
    var project: Project
    var revision: Int
    var selectedId: String?
    var time: Double
    var pps: Double
    var playing: Bool
}

// MARK: - 本体(自前描画)

/// タイムライン本体。スクロールも自前(スクロールバーなし・弾性なし)。見えている範囲だけ描く。
/// 座標は左上原点: 左 90pt がレイヤー名の列(横スクロールで動かない)、上 22pt がルーラー(縦スクロールで動かない)。
final class TimelineCanvas: NSView {
    weak var model: ProjectModel?
    private(set) var project = Project()
    private var revision = -1
    private(set) var geometry = TimelineGeometry()
    private var selectedId: String?
    private var time = 0.0
    private var playing = false
    private var isScrubbing = false
    private var charColors: [String: NSColor] = [:]
    private var charNames: [String: String] = [:]
    private var projectEnd = 0.0

    // ドラッグ編集(M4a)
    enum DragMode { case move, trimLeft, trimRight }
    struct ClipDrag {
        var clipId: String
        var mode: DragMode
        var downPoint: NSPoint
        var downTime: Double
        var active = false
        var base = Project()
        var lastTarget: Int
        var lastPoint: NSPoint
    }
    /// 押している最中のクリップ操作(3pt 動くまでは「クリック」で、active は false)。
    private(set) var drag: ClipDrag?
    /// ルーラーの旗(マーカー)を押している最中の操作(3pt 動くまでは「クリック」= その時刻へ移動)。
    struct MarkerDrag {
        var id: String
        var downPoint: NSPoint
        var downTime: Double
        var active = false
        var base = Project()
    }
    private(set) var markerDrag: MarkerDrag?
    /// 吸着の案内線の時刻(ドラッグ中だけ)。
    private(set) var snapGuides: [Double] = []
    /// ポインタが左右の端 30pt 以内にあるときの自動スクロールの向き(-1 左 / 0 なし / 1 右)。
    private(set) var autoScrollDirection = 0
    private var autoScrollTimer: Timer?
    private var mouseIsDown = false
    static let edgeZone: CGFloat = 8
    static let dragThreshold: CGFloat = 3
    static let autoScrollZone: CGFloat = 30

    // 検証用
    private(set) var lastDrawMs = 0.0
    private(set) var lastDrawClipCount = 0
    private(set) var drawCount = 0

    private static let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private static let tickFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private static let headFont = NSFont.systemFont(ofSize: 11)
    private static let chipFont = NSFont.systemFont(ofSize: 10)
    private static let truncStyle: NSMutableParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([.fileURL])
    }

    // MARK: マーカー(ルーラーの旗)

    static let flagWidth: CGFloat = 10
    static let flagFont = NSFont.systemFont(ofSize: 10, weight: .medium)

    /// 旗に反応する範囲(ルーラーの上。旗の竿の左右に少し余裕を持たせる)。
    func flagHitRect(_ m: Marker) -> NSRect {
        NSRect(x: geometry.x(forTime: m.time) - 4, y: 0, width: Self.flagWidth + 8, height: TimelineLayout.rulerHeight)
    }

    /// ルーラー上の点の下にある旗(重なっていたら後ろ = 時刻の遅い方)。
    func markerHit(at p: NSPoint) -> Marker? {
        guard p.y < TimelineLayout.rulerHeight, p.x >= TimelineLayout.headerWidth else { return nil }
        return project.markers.last { flagHitRect($0).contains(p) }
    }

    /// 旗の名前を出せるだけの幅(次の旗または右端まで)があるか。あれば名前の描画幅を返す。
    func flagLabelWidth(_ m: Marker, next: Marker?) -> CGFloat? {
        guard !m.name.isEmpty else { return nil }
        let x = geometry.x(forTime: m.time) + Self.flagWidth + 3
        let limit = (next.map { geometry.x(forTime: $0.time) - 4 } ?? bounds.width) - x
        let full = (m.name as NSString).size(withAttributes: [.font: Self.flagFont]).width + 8
        return limit >= min(full, 40) ? min(full, limit) : nil
    }

    private func drawMarkerFlags(ctx: CGContext) {
        let rh = TimelineLayout.rulerHeight
        let ms = project.markers
        for (i, m) in ms.enumerated() {
            let x = geometry.x(forTime: m.time)
            if x < TimelineLayout.headerWidth - 12 || x > bounds.width + 4 { continue }
            TimelinePalette.marker.setFill()
            NSRect(x: x - 0.5, y: 2, width: 1.5, height: rh - 2).fill()
            let flag = NSBezierPath()
            flag.move(to: NSPoint(x: x + 1, y: 2))
            flag.line(to: NSPoint(x: x + Self.flagWidth, y: 6))
            flag.line(to: NSPoint(x: x + 1, y: 10))
            flag.close()
            flag.fill()
            if let w = flagLabelWidth(m, next: i + 1 < ms.count ? ms[i + 1] : nil) {
                let r = NSRect(x: x + Self.flagWidth + 2, y: 6, width: w, height: 14)
                TimelinePalette.rulerBG.withAlphaComponent(0.94).setFill()
                NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
                (m.name as NSString).draw(in: r.insetBy(dx: 4, dy: 1), withAttributes: [.font: Self.flagFont, .foregroundColor: TimelinePalette.marker, .paragraphStyle: Self.truncStyle])
            }
        }
    }

    /// 行の上を縦に通る、点線のヒント(マーカーの時刻)。
    private func drawMarkerLines(ctx: CGContext, contentRect: NSRect) {
        guard !project.markers.isEmpty else { return }
        let rh = TimelineLayout.rulerHeight
        let bottom = min(bounds.height, max(rh, geometry.rowTop(project.tracks.count)))
        ctx.saveGState()
        ctx.clip(to: NSRect(x: contentRect.minX, y: rh, width: contentRect.width, height: max(0, bottom - rh)))
        TimelinePalette.marker.withAlphaComponent(0.6).setStroke()
        for m in project.markers {
            let x = geometry.x(forTime: m.time)
            if x < contentRect.minX - 2 || x > bounds.width + 2 { continue }
            let path = NSBezierPath()
            path.lineWidth = 1
            path.setLineDash([3, 3], count: 2, phase: 0)
            path.move(to: NSPoint(x: x + 0.5, y: rh))
            path.line(to: NSPoint(x: x + 0.5, y: bottom))
            path.stroke()
        }
        ctx.restoreGState()
    }

    override func layout() {
        super.layout()
        removeAllToolTips()
        addToolTip(NSRect(x: TimelineLayout.headerWidth, y: 0, width: max(0, bounds.width - TimelineLayout.headerWidth), height: TimelineLayout.rulerHeight), owner: self, userData: nil)
    }

    /// 旗の上にポインタがあるとき、名前と時刻を出す。
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let m = markerHit(at: point) else { return "" }
        return "\(m.name)  \(timecode(m.time))"
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isOpaque: Bool { true }

    override func keyDown(with event: NSEvent) {}   // 受けないキーでビープ音を鳴らさない(操作は KeyRouter が受ける)

    override func resetCursorRects() {
        let hw = TimelineLayout.headerWidth
        addCursorRect(NSRect(x: hw, y: 0, width: max(0, bounds.width - hw), height: TimelineLayout.rulerHeight), cursor: .pointingHand)
        let content = NSRect(x: hw, y: TimelineLayout.rulerHeight, width: max(0, bounds.width - hw), height: max(0, bounds.height - TimelineLayout.rulerHeight))
        if let d = drag, d.active {
            // ドラッグ中は、どこにいても同じカーソル
            addCursorRect(content, cursor: d.mode == .move ? .closedHand : .resizeLeftRight)
            return
        }
        for (i, tr) in project.tracks.enumerated() {
            for c in tr.clips {
                let r = geometry.clipRect(start: c.start, duration: c.duration, track: i).intersection(content)
                if r.isNull || r.isEmpty { continue }
                let z = min(Self.edgeZone, r.width / 3)
                addCursorRect(NSRect(x: r.minX, y: r.minY, width: z, height: r.height), cursor: .resizeLeftRight)
                addCursorRect(NSRect(x: r.maxX - z, y: r.minY, width: z, height: r.height), cursor: .resizeLeftRight)
                addCursorRect(NSRect(x: r.minX + z, y: r.minY, width: max(0, r.width - 2 * z), height: r.height), cursor: .openHand)
            }
        }
    }

    // MARK: モデルからの反映

    func apply(_ s: TimelineState) {
        var full = false
        if s.revision != revision {
            let grew = s.project.tracks.count > project.tracks.count && revision >= 0
            project = s.project
            revision = s.revision
            projectEnd = project.endTime
            charColors = [:]; charNames = [:]
            for c in project.characters { charColors[c.id] = nsColor(hex: c.color) ?? .gray; charNames[c.id] = c.name }
            if grew { geometry.scrollY = maxScrollY }   // ＋レイヤーで足した行が見えるように
            full = true
        }
        if s.selectedId != selectedId {
            selectedId = s.selectedId; full = true
            // メニューやボタンで追加・選択されたクリップの行が画面外なら、見える所までスクロールする(マウスで押したときは動かさない)
            if !mouseIsDown, let id = selectedId, let loc = ClipEditing.locate(id, in: project) {
                revealRow(loc.track)
                revealClipHorizontally(project.tracks[loc.track].clips[loc.index])   // 「前/次のクリップを選択」で画面の外のクリップへ
            }
        }
        if abs(s.pps - geometry.pps) > 1e-9 {
            // 外から(スライダー)変えたときは、再生ヘッドが見えていればその時刻、見えなければ真ん中の時刻を動かさない
            let centerX = TimelineLayout.headerWidth + (bounds.width - TimelineLayout.headerWidth) / 2
            let hx = geometry.x(forTime: s.time)
            let anchor = (hx >= TimelineLayout.headerWidth && hx <= bounds.width) ? hx : centerX
            setPps(s.pps, anchorX: anchor, updateModel: false)
            full = true
        }
        playing = s.playing
        if s.time != time {
            let old = time
            time = s.time
            if !isScrubbing, followPlayhead() { full = true }
            if !full { invalidatePlayhead(at: old); invalidatePlayhead(at: time) }
        }
        if clampScroll() { full = true }
        if full { needsDisplay = true; window?.invalidateCursorRects(for: self) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if clampScroll() { needsDisplay = true }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    private var maxScrollX: CGFloat { TimelineGeometry.maxScrollX(projectEnd: projectEnd, pps: geometry.pps, viewWidth: bounds.width) }
    private var maxScrollY: CGFloat { TimelineGeometry.maxScrollY(rowCount: project.tracks.count, viewHeight: bounds.height) }

    /// スクロール位置を範囲内に収める。動いたら true。
    @discardableResult
    private func clampScroll() -> Bool {
        let nx = min(max(0, geometry.scrollX), maxScrollX), ny = min(max(0, geometry.scrollY), maxScrollY)
        let moved = nx != geometry.scrollX || ny != geometry.scrollY
        geometry.scrollX = nx; geometry.scrollY = ny
        return moved
    }

    /// 再生中は再生ヘッドが見える範囲に入るよう、右へ出たらページ送りする。止まっているときは、見えない所へ動いたら戻して見せる。
    private func followPlayhead() -> Bool {
        let visibleW = bounds.width - TimelineLayout.headerWidth
        guard visibleW > 20 else { return false }
        let px = CGFloat(time * geometry.pps)             // コンテンツ座標
        let margin: CGFloat = 12
        let old = geometry.scrollX
        if px > geometry.scrollX + visibleW - margin {
            geometry.scrollX = playing ? px - margin : px - visibleW / 2
        } else if px < geometry.scrollX {
            geometry.scrollX = max(0, px - (playing ? margin : visibleW / 2))
        }
        clampScroll()
        return geometry.scrollX != old
    }

    private func invalidatePlayhead(at t: Double) {
        let x = geometry.x(forTime: t)
        setNeedsDisplay(NSRect(x: x - 3, y: 0, width: 8, height: bounds.height))
    }

    /// 拡大率を変える。anchorX の下の時刻を動かさない。
    func setPps(_ newValue: Double, anchorX: CGFloat, updateModel: Bool) {
        let np = TimelineLayout.clampPps(newValue)
        guard np != geometry.pps else { return }
        let ax = max(anchorX, TimelineLayout.headerWidth)
        let tAt = geometry.time(forX: ax)
        geometry.pps = np
        geometry.scrollX = CGFloat(tAt * np) - (ax - TimelineLayout.headerWidth)
        clampScroll()
        if updateModel { model?.pps = np }
        needsDisplay = true
    }

    /// 全体表示: max(10 秒, 終わり) を見える幅に。
    func fitToWindow() {
        let end = model?.project.endTime ?? projectEnd   // 編集の直後は、まだ apply されていないのでモデルから読む
        let np = TimelineLayout.fitPps(visibleWidth: bounds.width - TimelineLayout.headerWidth, projectEnd: end)
        geometry.scrollX = 0
        if abs(np - geometry.pps) > 1e-9 { geometry.pps = np; model?.pps = np }
        clampScroll()
        needsDisplay = true
    }

    /// クリップの頭が見える所まで横にスクロールする(短いクリップは全体が入るように)。すでに見えていれば動かさない。
    func revealClipHorizontally(_ c: Clip) {
        let visibleW = bounds.width - TimelineLayout.headerWidth
        guard visibleW > 40 else { return }
        let l = CGFloat(c.start * geometry.pps), r = CGFloat((c.start + c.duration) * geometry.pps)
        let margin: CGFloat = 24
        if l < geometry.scrollX {
            geometry.scrollX = l - margin
        } else if r > geometry.scrollX + visibleW {
            geometry.scrollX = (r - l) + 2 * margin <= visibleW ? r - visibleW + margin : l - margin
        }
        clampScroll()
    }

    /// その行が縦に全部見えるようにスクロールする。
    private func revealRow(_ i: Int) {
        let top = geometry.rowTop(i), bottom = top + TimelineLayout.rowHeight
        if top < TimelineLayout.rulerHeight { geometry.scrollY -= TimelineLayout.rulerHeight - top }
        else if bottom > bounds.height { geometry.scrollY += bottom - bounds.height }
        clampScroll()
    }

    /// 検証用: スクロール位置を直接指定。
    func debugSetScroll(x: CGFloat, y: CGFloat) { geometry.scrollX = x; geometry.scrollY = y; clampScroll(); needsDisplay = true }

    // MARK: 描画

    override func draw(_ rawDirty: NSRect) {
        let dirtyRect = rawDirty.intersection(bounds)
        guard !dirtyRect.isEmpty else { return }
        let t0 = CACurrentMediaTime()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let g = geometry
        let W = bounds.width, H = bounds.height
        let hw = TimelineLayout.headerWidth, rh = TimelineLayout.rulerHeight, rowH = TimelineLayout.rowHeight
        let rows = project.tracks.count

        ctx.saveGState()
        ctx.clip(to: dirtyRect)
        TimelinePalette.areaBG.setFill()
        dirtyRect.fill()

        // 見えている行の範囲
        let firstRow = max(0, Int(((dirtyRect.minY - rh + g.scrollY) / rowH).rounded(.down)))
        let lastRow = min(rows - 1, Int(((dirtyRect.maxY - rh + g.scrollY) / rowH).rounded(.down)))

        // 行の背景と下線
        let contentRect = NSRect(x: hw, y: rh, width: max(0, W - hw), height: max(0, H - rh))
        if firstRow <= lastRow {
            for i in firstRow...lastRow {
                let top = g.rowTop(i)
                let row = NSRect(x: hw, y: top, width: W - hw, height: rowH)
                if i % 2 == 1 { rgbaWhite(0.035).setFill(); row.fill() }
                if project.tracks[i].isHidden { NSColor(white: 0, alpha: 0.28).setFill(); row.fill() }
                TimelinePalette.rowLine.setFill()
                NSRect(x: hw, y: top + rowH - 1, width: W - hw, height: 1).fill()
            }
        }

        // クリップ(見えている範囲だけ)
        var drawn = 0
        ctx.saveGState()
        ctx.clip(to: contentRect.intersection(dirtyRect))
        var selectedDraw: (Clip, CGRect, Int)?
        let visibleL = hw - 8, visibleR = W + 8
        if firstRow <= lastRow {
            for i in firstRow...lastRow {
                let tr = project.tracks[i]
                for c in tr.clips {
                    let r = g.clipRect(start: c.start, duration: c.duration, track: i)
                    if r.maxX < visibleL || r.minX > visibleR || !r.intersects(dirtyRect) { continue }
                    if c.id == selectedId { selectedDraw = (c, r, i); continue }
                    drawClip(c, rect: r, track: tr, selected: false, ctx: ctx)
                    drawn += 1
                }
            }
        }
        if let (c, r, i) = selectedDraw {
            drawClip(c, rect: r, track: project.tracks[i], selected: true, ctx: ctx)
            drawn += 1
        }
        ctx.restoreGState()
        lastDrawClipCount = drawn
        drawMarkerLines(ctx: ctx, contentRect: contentRect)

        // レイヤー名の列(横スクロールしない)
        if NSRect(x: 0, y: 0, width: hw, height: H).intersects(dirtyRect) {
            TimelinePalette.panel.setFill()
            NSRect(x: 0, y: rh, width: hw, height: max(0, H - rh)).fill()
            if firstRow <= lastRow {
                for i in firstRow...lastRow { drawHeader(row: i, top: g.rowTop(i), ctx: ctx) }
            }
            TimelinePalette.line.setFill()
            NSRect(x: hw - 1, y: rh, width: 1, height: max(0, H - rh)).fill()
        }

        // ルーラー
        if dirtyRect.minY < rh { drawRuler(dirty: dirtyRect, ctx: ctx) }

        // 吸着の案内線(ドラッグ中)
        if !snapGuides.isEmpty {
            let bottom = min(H, max(rh, g.rowTop(rows)))
            ctx.saveGState()
            ctx.clip(to: NSRect(x: hw, y: rh, width: max(0, W - hw), height: max(0, bottom - rh)))
            TimelinePalette.accent.setFill()
            for t in snapGuides {
                let gx = g.x(forTime: t)
                NSRect(x: gx - 0.5, y: rh, width: 1.5, height: max(0, bottom - rh)).fill()
            }
            ctx.restoreGState()
        }

        // 再生ヘッド(ルーラーからレイヤーの下端まで)
        let px = g.x(forTime: time)
        if px >= hw - 2, px <= W + 2 {
            let bottom = min(H, max(rh, g.rowTop(rows)))
            ctx.saveGState()
            ctx.clip(to: NSRect(x: hw, y: 0, width: max(0, W - hw), height: H))
            TimelinePalette.playhead.setFill()
            NSRect(x: px, y: 0, width: 2, height: bottom).fill()
            ctx.restoreGState()
        }
        ctx.restoreGState()

        lastDrawMs = (CACurrentMediaTime() - t0) * 1000
        drawCount += 1
    }

    private func rgbaWhite(_ a: CGFloat) -> NSColor { NSColor(white: 1, alpha: a) }

    private func clipLabel(_ c: Clip) -> String {
        switch c.type {
        case .voice: return "\(charNames[c.charId ?? ""] ?? "?"): \(c.text ?? "")"
        case .text: return "T \(c.text ?? "")"
        case .blur: return "ぼかし範囲"
        default: return (c.src as NSString?)?.lastPathComponent ?? ""
        }
    }

    private func drawClip(_ c: Clip, rect r: CGRect, track: Track, selected: Bool, ctx: CGContext) {
        var fill: NSColor
        var leftBorder: NSColor?
        if c.type == .voice {
            let col = charColors[c.charId ?? ""] ?? rgb(0x999999)
            fill = TimelinePalette.voiceFill(character: col)
            leftBorder = col
        } else {
            fill = TimelinePalette.color(for: c.type)
        }
        if selected { fill = fill.blended(withFraction: 0.12, of: .white) ?? fill }   // filter: brightness(1.12) ぶん
        let alpha: CGFloat = track.isHidden ? 0.4 : (track.isMuted && c.type != .blur && c.type != .image && c.type != .text ? 0.78 : 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)

        ctx.saveGState()
        ctx.setAlpha(alpha)
        if selected {
            // 光彩(box-shadow 0 0 12px) + 3pt の薄い輪 + 2pt の枠線
            ctx.saveGState()
            let sh = NSShadow()
            sh.shadowColor = NSColor(srgbRed: 1, green: 216 / 255, blue: 79 / 255, alpha: 0.55)
            sh.shadowBlurRadius = 12
            sh.shadowOffset = .zero
            sh.set()
            fill.setFill(); path.fill()
            ctx.restoreGState()
            let ring = NSBezierPath(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), xRadius: 5.5, yRadius: 5.5)
            ring.lineWidth = 3
            NSColor(srgbRed: 1, green: 216 / 255, blue: 79 / 255, alpha: 0.28).setStroke(); ring.stroke()
        }
        fill.setFill(); path.fill()
        // 1pt の淡い縁
        let edge = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
        edge.lineWidth = 1
        NSColor(white: 1, alpha: 0.25).setStroke(); edge.stroke()
        var textLeft = r.minX + 7
        if let lb = leftBorder {
            // 左端の 3pt の線(キャラの色そのまま)
            ctx.saveGState()
            path.addClip()
            lb.setFill()
            NSRect(x: r.minX, y: r.minY, width: min(3, r.width), height: r.height).fill()
            ctx.restoreGState()
            textLeft += 3
        }
        if selected {
            let o = NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), xRadius: 5, yRadius: 5)
            o.lineWidth = 2
            TimelinePalette.selection.setStroke(); o.stroke()
            // 左右のトリム用のつまみ(幅 3pt)
            if r.width >= 14 {
                NSColor(white: 1, alpha: 0.9).setFill()
                for hx in [r.minX + 2.5, r.maxX - 5.5] {
                    NSBezierPath(roundedRect: NSRect(x: hx, y: r.midY - 7, width: 3, height: 14), xRadius: 1.5, yRadius: 1.5).fill()
                }
            }
        }
        // ラベル
        let labelRect = NSRect(x: textLeft, y: r.minY + 4, width: r.maxX - textLeft - 4, height: 15)
        if labelRect.width > 10 {
            ctx.saveGState()
            ctx.clip(to: r.insetBy(dx: 1, dy: 1))
            (clipLabel(c) as NSString).draw(in: labelRect, withAttributes: [.font: Self.labelFont, .foregroundColor: NSColor.white, .paragraphStyle: Self.truncStyle])
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    private func drawHeader(row i: Int, top: CGFloat, ctx: CGContext) {
        let tr = project.tracks[i]
        let hw = TimelineLayout.headerWidth
        TimelinePalette.rowLine.setFill()
        NSRect(x: 0, y: top + TimelineLayout.rowHeight - 1, width: hw, height: 1).fill()
        let nameRect = NSRect(x: 5, y: top + 4, width: hw - 10, height: 14)
        (tr.name as NSString).draw(in: nameRect, withAttributes: [.font: Self.headFont, .foregroundColor: TimelinePalette.label, .paragraphStyle: Self.truncStyle])
        let chips = TimelineLayout.chipRects(rowTop: top)
        drawChip("隠す", rect: chips.hide, on: tr.isHidden)
        drawChip("消音", rect: chips.mute, on: tr.isMuted)
    }

    private func drawChip(_ title: String, rect r: CGRect, on: Bool) {
        let box = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        if on { rgb(0x4a3a3f).setFill(); box.fill() }
        (on ? rgb(0xff4f6a) : TimelinePalette.line).setStroke()
        box.lineWidth = 1
        box.stroke()
        // チェックボックス(10pt)
        let cb = NSRect(x: r.minX + 4, y: r.midY - 5, width: 10, height: 10)
        let cbPath = NSBezierPath(roundedRect: cb, xRadius: 2, yRadius: 2)
        if on {
            TimelinePalette.accent.setFill(); cbPath.fill()
            let ck = NSBezierPath()
            ck.move(to: NSPoint(x: cb.minX + 2.2, y: cb.midY + 0.2))
            ck.line(to: NSPoint(x: cb.minX + 4.3, y: cb.maxY - 2.6))
            ck.line(to: NSPoint(x: cb.maxX - 2, y: cb.minY + 2.4))
            ck.lineWidth = 1.5; ck.lineCapStyle = .round; ck.lineJoinStyle = .round
            NSColor.white.setStroke(); ck.stroke()
        } else {
            rgb(0x15161a).setFill(); cbPath.fill()
            NSColor(white: 1, alpha: 0.4).setStroke(); cbPath.lineWidth = 1; cbPath.stroke()
        }
        (title as NSString).draw(at: NSPoint(x: cb.maxX + 3, y: r.minY + 1.5), withAttributes: [.font: Self.chipFont, .foregroundColor: on ? TimelinePalette.text0 : TimelinePalette.label])
    }

    private func drawRuler(dirty: NSRect, ctx: CGContext) {
        let hw = TimelineLayout.headerWidth, rh = TimelineLayout.rulerHeight
        let g = geometry
        TimelinePalette.rulerBG.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: rh).fill()
        ctx.saveGState()
        ctx.clip(to: NSRect(x: hw, y: 0, width: max(0, bounds.width - hw), height: rh))
        let step = TimelineLayout.tickStep(pps: g.pps)
        let t0 = max(0, g.time(forX: hw) - step), t1 = g.time(forX: bounds.width) + step
        let end = TimelineLayout.contentSeconds(projectEnd: projectEnd)
        var k = Int((t0 / step).rounded(.down))
        while true {
            let s = Double(k) * step
            if s > t1 || s > end + 1e-9 { break }
            if s >= 0 {
                let x = g.x(forTime: s)
                TimelinePalette.tick.setFill()
                NSRect(x: x, y: 0, width: 1, height: rh).fill()
                (TimelineLayout.tickLabel(seconds: s, step: step) as NSString).draw(at: NSPoint(x: x + 4, y: 4), withAttributes: [.font: Self.tickFont, .foregroundColor: TimelinePalette.tickText])
            }
            k += 1
        }
        drawMarkerFlags(ctx: ctx)
        ctx.restoreGState()
        // 左上の角と下線
        TimelinePalette.rulerBG.setFill()
        NSRect(x: 0, y: 0, width: hw, height: rh).fill()
        TimelinePalette.line.setFill()
        NSRect(x: 0, y: rh - 1, width: bounds.width, height: 1).fill()
        NSRect(x: hw - 1, y: 0, width: 1, height: rh).fill()
    }

    // MARK: マウス

    private func point(_ e: NSEvent) -> NSPoint { convert(e.locationInWindow, from: nil) }

    /// 点の下で一番手前のクリップ(後から描くもの、選択中のものが前)。
    func clipId(at p: NSPoint) -> String? {
        guard let i = geometry.rowIndex(forY: p.y, rowCount: project.tracks.count), p.x >= TimelineLayout.headerWidth else { return nil }
        var hit: String?
        for c in project.tracks[i].clips {
            if geometry.clipRect(start: c.start, duration: c.duration, track: i).contains(p) {
                if c.id == selectedId { return c.id }
                hit = c.id
            }
        }
        return hit
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        mouseDown(at: point(e))
    }

    /// テストからも呼べるよう、イベントから切り離した入口。
    func mouseDown(at p: NSPoint) {
        mouseIsDown = true
        let hw = TimelineLayout.headerWidth
        if p.y < TimelineLayout.rulerHeight {
            if let m = markerHit(at: p) {
                markerDrag = MarkerDrag(id: m.id, downPoint: p, downTime: m.time)    // 旗: クリックで移動、ドラッグで動かす
            } else if p.x >= hw {
                beginScrub(at: p)
            }
            return
        }
        if p.x < hw {
            if let i = geometry.rowIndex(forY: p.y, rowCount: project.tracks.count) {
                let chips = TimelineLayout.chipRects(rowTop: geometry.rowTop(i))
                if chips.hide.contains(p) { model?.toggleTrack(i, .hidden) }
                else if chips.mute.contains(p) { model?.toggleTrack(i, .muted) }
            }
            return
        }
        if let id = clipId(at: p) {
            model?.selectedClipId = id
            guard let m = model, !m.isLocked, let loc = ClipEditing.locate(id, in: project) else { return }
            let c = project.tracks[loc.track].clips[loc.index]
            let r = geometry.clipRect(start: c.start, duration: c.duration, track: loc.track)
            let z = min(Self.edgeZone, r.width / 3)
            let mode: DragMode = p.x - r.minX < z ? .trimLeft : (r.maxX - p.x < z ? .trimRight : .move)
            drag = ClipDrag(clipId: id, mode: mode, downPoint: p, downTime: geometry.time(forX: p.x), lastTarget: loc.track, lastPoint: p)
        } else {
            model?.selectedClipId = nil     // 何もない所: 選択を外して、その時刻へ(シーク)
            beginScrub(at: p)
        }
    }

    override func mouseDragged(with e: NSEvent) { mouseDragged(to: point(e)) }

    func mouseDragged(to p: NSPoint) {
        if isScrubbing { scrub(to: p); return }
        if var md = markerDrag {
            if !md.active {
                guard hypot(p.x - md.downPoint.x, p.y - md.downPoint.y) >= Self.dragThreshold, let m = model else { return }
                m.beginGesture()
                md.active = true
                md.base = m.project
                markerDrag = md
            }
            let t = max(0, md.downTime + geometry.time(forX: p.x) - geometry.time(forX: md.downPoint.x))
            if let moved = MarkerEditing.move(in: md.base, id: md.id, to: t) {
                model?.updateGesture(moved)
                syncFromModel()
                needsDisplay = true
            }
            return
        }
        guard var d = drag else { return }
        if !d.active {
            // 3pt 動くまではクリック扱い
            guard hypot(p.x - d.downPoint.x, p.y - d.downPoint.y) >= Self.dragThreshold, let m = model else { return }
            m.beginGesture()                       // 再生を止め、元の状態を覚える
            d.active = true
            d.base = m.project
            d.lastTarget = ClipEditing.locate(d.clipId, in: d.base)?.track ?? d.lastTarget
            drag = d
            window?.invalidateCursorRects(for: self)
        }
        d.lastPoint = p
        drag = d
        updateAutoScrollDirection(p)
        applyDrag(at: p)
    }

    override func mouseUp(with e: NSEvent) { mouseUp() }

    func mouseUp() {
        mouseIsDown = false
        if let md = markerDrag {
            markerDrag = nil
            if md.active {
                model?.commitGesture("マーカーの移動")     // 変わっていれば 1 回の Undo
                syncFromModel()
            } else {
                model?.jumpToMarker(id: md.id)
            }
            needsDisplay = true
            return
        }
        if isScrubbing {
            isScrubbing = false
            model?.playback.endScrub()
            return
        }
        guard let d = drag else { return }
        drag = nil
        stopAutoScroll()
        if d.active {
            snapGuides = []
            let name: String
            switch d.mode {
            case .move: name = "クリップの移動"
            case .trimLeft: name = "クリップの左端トリム"
            case .trimRight: name = "クリップの右端トリム"
            }
            model?.commitGesture(name)             // 変わっていれば 1 回の Undo
            syncFromModel()
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }

    /// ポインタの位置から、いまのドラッグ(モード・行)を計算してモデルへ反映する。
    private func applyDrag(at p: NSPoint) {
        guard var d = drag, d.active, let m = model else { return }
        let dt = debugFixedDelta ?? (geometry.time(forX: p.x) - d.downTime)
        let result: ClipEditing.Result
        switch d.mode {
        case .move:
            if let row = geometry.rowIndex(forY: p.y, rowCount: d.base.tracks.count) { d.lastTarget = row; drag = d }
            result = ClipEditing.move(in: d.base, clipId: d.clipId, deltaT: dt, targetTrackIndex: d.lastTarget, playhead: m.currentTime, pps: geometry.pps, snapEnabled: m.snapEnabled)
        case .trimLeft:
            result = ClipEditing.trimLeft(in: d.base, clipId: d.clipId, deltaT: dt, playhead: m.currentTime, pps: geometry.pps, snapEnabled: m.snapEnabled)
        case .trimRight:
            result = ClipEditing.trimRight(in: d.base, clipId: d.clipId, deltaT: dt, playhead: m.currentTime, pps: geometry.pps, snapEnabled: m.snapEnabled)
        }
        snapGuides = result.guides
        m.updateGesture(result.project)
        syncFromModel()
        needsDisplay = true
    }

    // MARK: 自動スクロール(ドラッグ中にポインタが左右の端 30pt 以内)

    private func updateAutoScrollDirection(_ p: NSPoint) {
        let hw = TimelineLayout.headerWidth
        let dir: Int
        if p.x < hw + Self.autoScrollZone { dir = -1 }
        else if p.x > bounds.width - Self.autoScrollZone { dir = 1 }
        else { dir = 0 }
        autoScrollDirection = dir
        if dir != 0 {
            if autoScrollTimer == nil {
                let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.autoScrollStep() }
                }
                RunLoop.main.add(t, forMode: .common)
                autoScrollTimer = t
            }
        } else {
            stopAutoScroll()
        }
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate(); autoScrollTimer = nil
        autoScrollDirection = 0
    }

    /// 端に近いほど速く(4〜18pt/コマ)。スクロールしたら、ポインタの下の時刻に合わせてドラッグを計算し直す。
    func autoScrollStep() {
        guard let d = drag, d.active, autoScrollDirection != 0 else { return }
        let hw = TimelineLayout.headerWidth
        let depth: CGFloat = autoScrollDirection < 0
            ? max(0, min(1, (hw + Self.autoScrollZone - d.lastPoint.x) / Self.autoScrollZone))
            : max(0, min(1, (d.lastPoint.x - (bounds.width - Self.autoScrollZone)) / Self.autoScrollZone))
        let speed = 4 + 14 * depth
        let old = geometry.scrollX
        geometry.scrollX += CGFloat(autoScrollDirection) * speed
        clampScroll()
        if geometry.scrollX != old { applyDrag(at: d.lastPoint) }
    }

    /// 検証用 / テスト用: タイムラインの外から同じ手順でドラッグを組み立てる。
    /// `hold` なら離さずに止める(途中の絵を撮る用)。dt は秒、`targetTrack` は移動先のレイヤー。
    func debugDrag(clipId: String, mode: DragMode, deltaT: Double, targetTrack: Int? = nil, hold: Bool = false) {
        guard let m = model, let loc = ClipEditing.locate(clipId, in: m.project) else { return }
        m.selectedClipId = clipId
        m.beginGesture()
        var d = ClipDrag(clipId: clipId, mode: mode, downPoint: .zero, downTime: 0, lastTarget: targetTrack ?? loc.track, lastPoint: .zero)
        d.active = true
        d.base = m.project
        drag = d
        // dt をそのまま使うため、downTime をポインタ位置と無関係にする
        debugFixedDelta = deltaT
        applyDrag(at: .zero)
        if !hold { mouseUp() }
        debugFixedDelta = nil
    }

    private var debugFixedDelta: Double?

    /// モデルの現在の値をそのままキャンバスへ反映する(SwiftUI を待たずに描き直したいとき)。
    func syncFromModel() {
        guard let m = model else { return }
        apply(TimelineState(project: m.project, revision: m.projectRevision, selectedId: m.selectedClipId,
                            time: m.currentTime, pps: m.pps, playing: m.isPlaying))
    }

    // MARK: ドラッグ&ドロップ(Finder から素材)

    private func droppedMediaURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { ClipEditing.isSupportedMedia(path: $0.path) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedMediaURLs(sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedMediaURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedMediaURLs(sender)
        guard !urls.isEmpty, let m = model else { return false }
        let p = convert(sender.draggingLocation, from: nil)
        let t = dropTime(at: p)
        Task { @MainActor in await m.addMedia(urls: urls, at: t) }
        return true
    }

    /// 行の上に落としたなら、その位置の時刻。それ以外(ヘッダー・ルーラー・行の外)は nil = 再生ヘッダー位置。
    func dropTime(at p: NSPoint) -> Double? {
        guard p.x >= TimelineLayout.headerWidth, geometry.rowIndex(forY: p.y, rowCount: project.tracks.count) != nil else { return nil }
        return max(0, geometry.time(forX: p.x))
    }

    private func beginScrub(at p: NSPoint) {
        isScrubbing = true
        model?.playback.beginScrub()
        scrub(to: p)
    }

    private func scrub(to p: NSPoint) {
        model?.playback.seek(to: max(0, geometry.time(forX: p.x)))
    }

    // MARK: スクロールと拡大

    override func scrollWheel(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let precise = e.hasPreciseScrollingDeltas
        let unit: CGFloat = precise ? 1 : 12
        // Cmd + スクロール: ポインタの下の時刻を動かさず拡大・縮小
        if e.modifierFlags.contains(.command) {
            let d = (abs(e.scrollingDeltaY) >= abs(e.scrollingDeltaX) ? e.scrollingDeltaY : e.scrollingDeltaX) * unit
            if d != 0 { setPps(geometry.pps * exp(Double(d) * 0.01), anchorX: p.x, updateModel: true) }
            return
        }
        var dx = e.scrollingDeltaX * unit, dy = e.scrollingDeltaY * unit
        let isWheel = e.phase.isEmpty && e.momentumPhase.isEmpty     // トラックパッドには指の段階(phase)がある
        if e.modifierFlags.contains(.shift) || (isWheel && dx == 0 && maxScrollY <= 0) {
            // マウスホイールは、縦にあふれないとき(または Shift)横スクロール
            if dx == 0 { dx = dy }
            dy = 0
        }
        geometry.scrollX -= dx
        geometry.scrollY -= dy
        if maxScrollY <= 0 { geometry.scrollY = 0 }
        clampScroll()
        needsDisplay = true
    }

    override func magnify(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        setPps(geometry.pps * Double(1 + e.magnification), anchorX: p.x, updateModel: true)
    }
}
