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
    /// 複合クリップ(中身をまとめた 1 本)。
    static let compound = rgb(0x4f8f8f)
    static let voiceBase: (r: CGFloat, g: CGFloat, b: CGFloat) = (0x16 / 255.0, 0x17 / 255.0, 0x1c / 255.0)
    static let areaBG = rgb(0x191a1e), panel = rgb(0x26282f), line = rgb(0x383b45), rowLine = rgb(0x2a2c33)
    static let rulerBG = rgb(0x22242a), tick = rgb(0x5a5d6a), tickText = rgb(0xcfd1da), label = rgb(0xb9bcc8), text0 = rgb(0xe6e6ea)
    static let playhead = rgb(0xff4f6a), selection = rgb(0xffd84f), accent = rgb(0x4f8cff)
    /// マーカーの旗と案内線の色(既定。マーカーごとの色は markerColor(_:) で決める)。
    static let marker = rgb(0x3dd6c0)
    static func markerColor(_ m: Marker) -> NSColor { rgb(MarkerColor.resolved(m.color).hex) }
    /// 書き出し範囲の印の色。
    static let rangeMark = rgb(0xffa13d)

    /// 種類ごとの色。ボイスはキャラの色を 42% だけ暗い下地に混ぜる。
    static func color(for type: ClipType) -> NSColor {
        switch type {
        case .video: return video
        case .image: return image
        case .audio: return audio
        case .text: return text
        case .blur: return blur
        case .compound: return compound
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
                Toggle("ぴったり揃える", isOn: $model.snapEnabled)
                    .help("クリップを動かすとき、ほかのクリップの端・再生ヘッド・0秒に自動で揃えます")
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            Divider()
            TimelineRepresentable(model: model)
                .overlay {
                    // 空の書類: 素材の入れ方を出す(ドロップは下のキャンバスが受ける。文字は操作を奪わない)
                    if model.project.allClips.isEmpty {
                        Text("ここに素材をドラッグ、またはファイル ▸ 素材を追加…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                }
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
        model.onZoomSelection = { [weak v] in v?.zoomToSelection() }
        v.apply(state)
        return v
    }

    func updateNSView(_ v: TimelineCanvas, context: Context) {
        v.model = model
        v.apply(state)
    }

    private var state: TimelineState {
        TimelineState(project: model.project, revision: model.projectRevision, selectedId: model.selectedClipId,
                      time: model.currentTime, pps: model.pps, playing: model.isPlaying,
                      selectedIds: model.selectedClipIDs, selectedLayer: model.selectedLayerIndex)
    }
}

struct TimelineState {
    var project: Project
    var revision: Int
    var selectedId: String?
    var time: Double
    var pps: Double
    var playing: Bool
    /// A6: 選んでいるクリップの全部(主を含む)と、ヘッダーで選んだレイヤー
    var selectedIds: Set<String> = []
    var selectedLayer: Int? = nil
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
    /// A6: 選んでいるクリップの全部と、ヘッダーで選んだレイヤー
    private var selectedIds: Set<String> = []
    private var selectedLayer: Int?
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
        /// 押した時点の選択(複数選択のドラッグ移動はこの全員を動かす)
        var ids: Set<String> = []
        /// 複数選択の中のクリップを、動かさずに離したとき単一選択に戻す先
        var collapseTo: String?
    }
    /// 何もない所を押している最中の操作。3pt 動くまでは「クリック」(離したら選択を外して、その時刻へ移動)、動かしたらラバーバンド。
    struct Rubber {
        var origin: NSPoint
        var current: NSPoint
        var base: ClipSelection
        var additive: Bool
        var active = false
    }
    private(set) var rubber: Rubber?
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
    /// 書き出し範囲の印(イン点・アウト点)のドラッグ。ルーラー上の印を掴んで動かす。
    struct RangeDrag {
        var isIn: Bool
        var downPoint: NSPoint
        var active = false
        var base = Project()
    }
    private(set) var rangeDrag: RangeDrag?
    /// 印の掴める幅(pt)。
    static let rangeGrab: CGFloat = 5
    /// 選択クリップの下端の菱形(キーフレーム)を押している最中の操作。動かさずに離せばその時刻へ移動、動かせば全項目のキーをまとめて動かす。
    struct KeyDrag {
        var clipId: String
        /// 押した菱形のキーの時刻(クリップの頭からの秒)
        var time: Double
        var downPoint: NSPoint
        var downTime: Double
        var active = false
        var base = Project()
    }
    private(set) var keyDrag: KeyDrag?
    /// 選択クリップの頭・終わりのトランジション(音声フェード)の三角の先端を押している最中の操作。動かすと長さが変わる。
    struct WedgeDrag {
        var clipId: String
        var edge: TransitionEdge
        var audio: Bool
        var downX: CGFloat
        var startSeconds: Double
        var active = false
        var base = Project()
    }
    private(set) var wedgeDrag: WedgeDrag?
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
        mediaObserver = NotificationCenter.default.addObserver(forName: TimelineMediaCache.didLoad, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    private var mediaObserver: Any?
    deinit { if let o = mediaObserver { NotificationCenter.default.removeObserver(o) } }

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

    /// ルーラー上で書き出し範囲の印を掴めるか(true = イン点、false = アウト点。近いほうを取る)。
    func rangeEdgeHit(at p: NSPoint) -> Bool? {
        guard p.y < TimelineLayout.rulerHeight, p.x >= TimelineLayout.headerWidth else { return nil }
        var best: (isIn: Bool, d: CGFloat)?
        for (isIn, t) in [(true, project.rangeIn), (false, project.rangeOut)] {
            guard let t else { continue }
            let d = abs(p.x - geometry.x(forTime: t))
            if d <= Self.rangeGrab, best == nil || d < best!.d { best = (isIn, d) }
        }
        return best?.isIn
    }

    /// 旗の名前を出せるだけの幅(次の旗または右端まで)があるか。あれば名前の描画幅を返す。
    func flagLabelWidth(_ m: Marker, next: Marker?) -> CGFloat? {
        guard !m.name.isEmpty else { return nil }
        let x = geometry.x(forTime: m.time) + Self.flagWidth + 3
        let limit = (next.map { geometry.x(forTime: $0.time) - 4 } ?? bounds.width) - x
        let full = (m.name as NSString).size(withAttributes: [.font: Self.flagFont]).width + 8
        return limit >= min(full, 40) ? min(full, limit) : nil
    }

    /// 書き出し範囲: ルーラーの下端に帯を引き、イン点・アウト点に「[」「]」の印を付ける。片方だけの設定もそのまま見せる。
    private func drawExportRange() {
        guard project.rangeIn != nil || project.rangeOut != nil else { return }
        let rh = TimelineLayout.rulerHeight
        let end = project.endTime
        let a = project.rangeIn ?? 0, b = project.rangeOut ?? end
        let xa = geometry.x(forTime: a), xb = geometry.x(forTime: b)
        let band = NSRect(x: min(xa, xb), y: rh - 6, width: abs(xb - xa), height: 6)
        TimelinePalette.rangeMark.withAlphaComponent(0.55).setFill()
        band.fill()
        TimelinePalette.rangeMark.setFill()
        if project.rangeIn != nil {
            NSRect(x: xa, y: 2, width: 2, height: rh - 2).fill()
            NSRect(x: xa, y: 2, width: 6, height: 2).fill()
            NSRect(x: xa, y: rh - 8, width: 6, height: 2).fill()
        }
        if project.rangeOut != nil {
            NSRect(x: xb - 2, y: 2, width: 2, height: rh - 2).fill()
            NSRect(x: xb - 6, y: 2, width: 6, height: 2).fill()
            NSRect(x: xb - 6, y: rh - 8, width: 6, height: 2).fill()
        }
    }

    private func drawMarkerFlags(ctx: CGContext) {
        let rh = TimelineLayout.rulerHeight
        let ms = project.markers
        for (i, m) in ms.enumerated() {
            let x = geometry.x(forTime: m.time)
            if x < TimelineLayout.headerWidth - 12 || x > bounds.width + 4 { continue }
            let color = TimelinePalette.markerColor(m)
            color.setFill()
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
                (m.name as NSString).draw(in: r.insetBy(dx: 4, dy: 1), withAttributes: [.font: Self.flagFont, .foregroundColor: color, .paragraphStyle: Self.truncStyle])
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
        for m in project.markers {
            let x = geometry.x(forTime: m.time)
            if x < contentRect.minX - 2 || x > bounds.width + 2 { continue }
            TimelinePalette.markerColor(m).withAlphaComponent(0.6).setStroke()
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
            geometry.setRowHeights(LayerEditing.rowHeights(project).map { CGFloat($0) })
            if grew { geometry.scrollY = maxScrollY }   // ＋レイヤーで足した行が見えるように
            full = true
        }
        if s.selectedIds != selectedIds { selectedIds = s.selectedIds; full = true }
        if s.selectedLayer != selectedLayer { selectedLayer = s.selectedLayer; full = true }
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
    private var maxScrollY: CGFloat { geometry.maxScrollY(rowCount: project.tracks.count, viewHeight: bounds.height) }

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

    /// 表示 ▸ 選択クリップにズーム: 選んだクリップの全体が見える拡大率にして、その頭へ横スクロールする。
    func zoomToSelection() {
        guard let m = model else { return }
        let ids = m.selectedClipIDs
        let clips = m.project.allClips.filter { ids.contains($0.id) }
        guard let lo = clips.map(\.start).min(), let hi = clips.map({ $0.start + $0.duration }).max() else { return }
        let np = TimelineLayout.zoomPps(visibleWidth: bounds.width - TimelineLayout.headerWidth, span: hi - lo)
        geometry.pps = np; m.pps = np
        geometry.scrollX = CGFloat(lo * np) - 24
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
        let top = geometry.rowTop(i), bottom = top + geometry.rowHeight(i)
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
        let hw = TimelineLayout.headerWidth, rh = TimelineLayout.rulerHeight
        let rows = project.tracks.count

        ctx.saveGState()
        ctx.clip(to: dirtyRect)
        TimelinePalette.areaBG.setFill()
        dirtyRect.fill()

        // 見えている行の範囲(行の高さはレイヤーごとに違う)
        var firstRow = rows, lastRow = -1
        for i in 0..<rows {
            let t = g.rowTop(i)
            if t + g.rowHeight(i) <= max(dirtyRect.minY, rh) { continue }
            if t >= dirtyRect.maxY { break }
            firstRow = min(firstRow, i); lastRow = i
        }

        // 行の背景と下線
        let contentRect = NSRect(x: hw, y: rh, width: max(0, W - hw), height: max(0, H - rh))
        if firstRow <= lastRow {
            for i in firstRow...lastRow {
                let top = g.rowTop(i)
                let rowH = g.rowHeight(i)
                let row = NSRect(x: hw, y: top, width: W - hw, height: rowH)
                if i % 2 == 1 { rgbaWhite(0.035).setFill(); row.fill() }
                if project.tracks[i].isHidden { NSColor(white: 0, alpha: 0.28).setFill(); row.fill() }
                if project.tracks[i].isLocked { NSColor(white: 0, alpha: 0.2).setFill(); row.fill() }
                TimelinePalette.rowLine.setFill()
                NSRect(x: hw, y: top + rowH - 1, width: W - hw, height: 1).fill()
            }
        }

        // クリップ(見えている範囲だけ)
        var drawn = 0
        ctx.saveGState()
        ctx.clip(to: contentRect.intersection(dirtyRect))
        var selectedDraw: [(Clip, CGRect, Int)] = []
        let visibleL = hw - 8, visibleR = W + 8
        if firstRow <= lastRow {
            for i in firstRow...lastRow {
                let tr = project.tracks[i]
                for c in tr.clips {
                    let r = g.clipRect(start: c.start, duration: c.duration, track: i)
                    if r.maxX < visibleL || r.minX > visibleR || !r.intersects(dirtyRect) { continue }
                    if c.id == selectedId || selectedIds.contains(c.id) { selectedDraw.append((c, r, i)); continue }
                    drawClip(c, rect: r, track: tr, selected: false, ctx: ctx)
                    drawn += 1
                }
            }
        }
        // 選択中のものは最後(手前)。主のクリップが一番手前
        for (c, r, i) in selectedDraw.sorted(by: { ($0.0.id == selectedId ? 1 : 0) < ($1.0.id == selectedId ? 1 : 0) }) {
            let primary = c.id == selectedId
            drawClip(c, rect: r, track: project.tracks[i], selected: primary, secondary: !primary, ctx: ctx)
            drawn += 1
        }
        if let rb = rubber, rb.active { drawRubberBand(rb) }
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
        case .compound: return "複合 (\(c.tracks?.reduce(0) { $0 + $1.clips.count } ?? 0)クリップ)"
        default: return (c.src as NSString?)?.lastPathComponent ?? ""
        }
    }

    /// ラバーバンドの四角(押した点と今の点)。
    func rubberRect(_ rb: Rubber) -> NSRect {
        NSRect(x: min(rb.origin.x, rb.current.x), y: min(rb.origin.y, rb.current.y), width: abs(rb.origin.x - rb.current.x), height: abs(rb.origin.y - rb.current.y))
    }

    private func drawRubberBand(_ rb: Rubber) {
        let r = rubberRect(rb)
        TimelinePalette.accent.withAlphaComponent(0.14).setFill(); r.fill()
        let b = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
        b.lineWidth = 1
        TimelinePalette.accent.withAlphaComponent(0.9).setStroke(); b.stroke()
    }

    private func drawClip(_ c: Clip, rect r: CGRect, track: Track, selected: Bool, secondary: Bool = false, ctx: CGContext) {
        var fill: NSColor
        var leftBorder: NSColor?
        if c.type == .voice {
            let col = charColors[c.charId ?? ""] ?? rgb(0x999999)
            fill = TimelinePalette.voiceFill(character: col)
            leftBorder = col
        } else {
            fill = TimelinePalette.color(for: c.type)
        }
        if selected || secondary { fill = fill.blended(withFraction: 0.12, of: .white) ?? fill }   // filter: brightness(1.12) ぶん
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
        let hasMedia = drawMedia(c, rect: r, path: path, ctx: ctx)
        drawTransitionWedges(c, rect: r, selected: selected, path: path, ctx: ctx)
        if secondary {
            // 複数選択の主でないクリップ: 枠線だけ(つまみや光彩は主のものだけ)
            let o = NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: -1), xRadius: 5, yRadius: 5)
            o.lineWidth = 2
            TimelinePalette.selection.withAlphaComponent(0.85).setStroke(); o.stroke()
        }
        if selected && c.hasKeyframes { drawKeyframeDiamonds(c, rect: r, ctx: ctx) }
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
        // 速度・逆再生・静止の印(右上の小さな札)。狭いクリップには出さない
        var labelRight = r.maxX - 4
        if let badge = ClipTiming.badge(for: c), r.width >= 52 {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white]
            let size = (badge as NSString).size(withAttributes: attrs)
            let box = NSRect(x: r.maxX - size.width - 12, y: r.minY + 4, width: size.width + 8, height: 15)
            ctx.saveGState()
            ctx.clip(to: r.insetBy(dx: 1, dy: 1))
            NSColor(white: 0, alpha: 0.55).setFill()
            NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
            (badge as NSString).draw(at: NSPoint(x: box.minX + 4, y: box.minY + (box.height - size.height) / 2), withAttributes: attrs)
            ctx.restoreGState()
            labelRight = box.minX - 3
        }
        // ラベル
        let labelRect = NSRect(x: textLeft, y: r.minY + 4, width: labelRight - textLeft, height: 15)
        if labelRect.width > 10 {
            ctx.saveGState()
            ctx.clip(to: r.insetBy(dx: 1, dy: 1))
            let label = clipLabel(c) as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: NSColor.white, .paragraphStyle: Self.truncStyle]
            if hasMedia {
                // サムネイルや波形の上でも読めるよう、文字の下に暗い下地を敷く
                let tw = min(labelRect.width, ceil(label.size(withAttributes: attrs).width) + 2)
                NSColor(white: 0, alpha: 0.5).setFill()
                NSBezierPath(roundedRect: NSRect(x: labelRect.minX - 3, y: labelRect.minY - 1, width: tw + 6, height: 17), xRadius: 3, yRadius: 3).fill()
            }
            label.draw(in: labelRect, withAttributes: attrs)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    // MARK: サムネイルと波形(A6)

    /// 画像を、タイルいっぱいに(はみ出す分は切って)描く。
    private func drawAspectFill(_ img: CGImage, in tile: NSRect) {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        guard iw > 0, ih > 0, tile.width > 0, tile.height > 0 else { return }
        var src = NSRect(x: 0, y: 0, width: iw, height: ih)
        let ia = iw / ih, ta = tile.width / tile.height
        if ia > ta { let w = ih * ta; src.origin.x = (iw - w) / 2; src.size.width = w }
        else { let h = iw / ta; src.origin.y = (ih - h) / 2; src.size.height = h }
        NSImage(cgImage: img, size: NSSize(width: iw, height: ih))
            .draw(in: tile, from: src, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.low.rawValue])
    }

    /// 動画・画像のサムネイルの帯と、音のあるクリップの波形を、クリップの中に描く(見えている部分だけ)。
    /// まだできていないものは何も描かない(クリップの色のまま)。作るのは裏で、できたら描き直される。
    /// 何か描いたら true(ラベルの下に暗い下地を敷くため)。
    private func drawMedia(_ c: Clip, rect r: CGRect, path: NSBezierPath, ctx: CGContext) -> Bool {
        guard r.width >= 16, let src = c.src, !src.isEmpty else { return false }
        let cache = TimelineMediaCache.shared
        let hw = TimelineLayout.headerWidth
        let visL = max(r.minX, hw), visR = min(r.maxX, bounds.width)
        guard visR > visL else { return false }
        var drew = false
        ctx.saveGState()
        path.addClip()
        if c.type == .video || c.type == .image {
            let tileW = max(24, r.height * 16 / 9)
            let n = ThumbnailPlan.tileCount(width: Double(r.width), tileWidth: Double(tileW))
            if n > 0 {
                let w = r.width / CGFloat(n)
                let i0 = max(0, Int(((visL - r.minX) / w).rounded(.down))), i1 = min(n - 1, Int(((visR - r.minX) / w).rounded(.down)))
                if i0 <= i1 {
                    for i in i0...i1 {
                        let t = c.type == .image ? 0 : ThumbnailPlan.time(for: c, tile: i, of: n)
                        if let img = cache.thumbnail(path: src, time: t, isImage: c.type == .image) {
                            drawAspectFill(img, in: NSRect(x: r.minX + w * CGFloat(i), y: r.minY, width: w + 0.5, height: r.height))
                            drew = true
                        }
                    }
                }
            }
        }
        if (c.type == .audio || c.type == .voice || c.type == .video), !c.isFreeze, let peaks = cache.waveform(path: src) {
            let span = r.width
            let f0 = Double((visL - r.minX) / span), f1 = Double((visR - r.minX) / span)
            let range = WaveformPeaks.sourceRange(for: c)
            let a = range.from + (range.to - range.from) * f0, b = range.from + (range.to - range.from) * f1
            let barW: CGFloat = 2
            let count = max(1, Int(((visR - visL) / barW).rounded(.up)))
            let cols = peaks.columns(from: a, to: b, count: count)
            let isVideo = c.type == .video
            var bars: [CGRect] = []
            bars.reserveCapacity(cols.count)
            let maxH = isVideo ? r.height * 0.4 : r.height - 8
            for (k, v) in cols.enumerated() {
                let h = max(0.8, CGFloat(pow(Double(min(1, v)), 0.7)) * maxH)
                let x = visL + CGFloat(k) * barW
                bars.append(isVideo ? CGRect(x: x, y: r.maxY - 2 - h, width: barW - 0.5, height: h)
                                    : CGRect(x: x, y: r.midY - h / 2, width: barW - 0.5, height: h))
            }
            if isVideo {
                NSColor(white: 0, alpha: 0.3).setFill()
                NSRect(x: visL, y: r.maxY - 2 - maxH - 2, width: visR - visL, height: maxH + 4).fill()
            }
            ctx.setFillColor(NSColor(white: 1, alpha: isVideo ? 0.8 : 0.6).cgColor)
            ctx.addRects(bars)
            ctx.fillPath()
            drew = true
        }
        ctx.restoreGState()
        return drew
    }

    private func drawHeader(row i: Int, top: CGFloat, ctx: CGContext) {
        let tr = project.tracks[i]
        let hw = TimelineLayout.headerWidth
        let rowH = geometry.rowHeight(i)
        if selectedLayer == i {
            TimelinePalette.accent.withAlphaComponent(0.18).setFill()
            NSRect(x: 0, y: top, width: hw - 1, height: rowH - 1).fill()
            TimelinePalette.accent.setFill()
            NSRect(x: 0, y: top, width: 2.5, height: rowH - 1).fill()
        }
        TimelinePalette.rowLine.setFill()
        NSRect(x: 0, y: top + rowH - 1, width: hw, height: 1).fill()
        if renamingRow != i {
            let nameRect = NSRect(x: 6, y: top + (rowH < 40 ? 2 : 4), width: hw - 48, height: 14)
            (tr.name as NSString).draw(in: nameRect, withAttributes: [.font: Self.headFont, .foregroundColor: TimelinePalette.label, .paragraphStyle: Self.truncStyle])
        }
        drawLockButton(rect: TimelineLayout.lockRect(rowTop: top), on: tr.isLocked)
        drawSoloButton(rect: TimelineLayout.soloRect(rowTop: top), on: tr.isSolo)
        let chips = TimelineLayout.chipRects(rowTop: top, rowHeight: rowH)
        drawChip("隠す", rect: chips.hide, on: tr.isHidden)
        drawChip("消音", rect: chips.mute, on: tr.isMuted)
        drawDeleteButton(rect: TimelineLayout.deleteRect(rowTop: top, rowHeight: rowH))
    }

    /// レイヤーを削除する × (控えめな灰色。押すと確認のうえ消す。メニューと同じ経路)。
    private func drawDeleteButton(rect r: CGRect) {
        let c = r.insetBy(dx: 4.5, dy: 4.5)
        let x = NSBezierPath()
        x.move(to: NSPoint(x: c.minX, y: c.minY)); x.line(to: NSPoint(x: c.maxX, y: c.maxY))
        x.move(to: NSPoint(x: c.minX, y: c.maxY)); x.line(to: NSPoint(x: c.maxX, y: c.minY))
        x.lineWidth = 1.4
        NSColor(white: 1, alpha: 0.5).setStroke()
        x.stroke()
    }

    /// ロックの錠前(オンは赤の塗りつぶしで掛け金が閉じ、オフは薄い輪郭で掛け金が開く)。パスで描く(描画のたびに画像を作らない)。
    private func drawLockButton(rect r: CGRect, on: Bool) {
        let color = on ? rgb(0xff4f6a) : NSColor(white: 1, alpha: 0.4)
        let body = NSRect(x: r.midX - 5, y: r.midY - 1, width: 10, height: 7.5)
        let shackle = NSBezierPath()
        let top = body.minY - 4.5
        shackle.move(to: NSPoint(x: body.minX + 2, y: body.minY))
        shackle.line(to: NSPoint(x: body.minX + 2, y: top + 2.5))
        shackle.appendArc(withCenter: NSPoint(x: body.midX, y: top + 2.5), radius: 3, startAngle: 180, endAngle: 0, clockwise: false)
        // 開いているときは右側の脚を短くする
        shackle.line(to: NSPoint(x: body.maxX - 2, y: on ? body.minY : body.minY - 2.5))
        shackle.lineWidth = 1.5
        color.setStroke(); shackle.stroke()
        let b = NSBezierPath(roundedRect: body, xRadius: 1.5, yRadius: 1.5)
        if on { color.setFill(); b.fill() } else { b.lineWidth = 1.2; color.setStroke(); b.stroke() }
    }

    /// ソロの「S」(オンは黄色の地)。
    private func drawSoloButton(rect r: CGRect, on: Bool) {
        let box = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
        if on { TimelinePalette.selection.setFill(); box.fill() }
        else { NSColor(white: 1, alpha: 0.3).setStroke(); box.lineWidth = 1; box.stroke() }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: on ? NSColor.black : NSColor(white: 1, alpha: 0.6)]
        let sz = ("S" as NSString).size(withAttributes: attrs)
        ("S" as NSString).draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
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
        drawExportRange()
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

    // MARK: トランジション / フェードの三角(クリップの頭と終わり)

    static let wedgeHandleRadius: CGFloat = 4
    static let wedgeHit: CGFloat = 7

    /// 頭(終わり)に描く三角の長さ(秒)。映像のクリップはトランジションの長さ、無ければ音声のフェード。音声だけのときは `audio` が true。
    func wedgeInfo(_ c: Clip, _ edge: TransitionEdge) -> (seconds: Double, audio: Bool)? {
        if TransitionEditing.supportsVideo(c.type), let tr = TransitionEditing.transition(c, edge) {
            return (tr.effectiveDuration(clipDuration: c.duration), false)
        }
        if TransitionEditing.supportsAudio(c.type) {
            let a = edge == .in ? c.fadeInOrDefault : c.fadeOutOrDefault
            if a > 0 { return (min(a, c.duration), true) }
        }
        return nil
    }

    /// 三角の幅(pt)。クリップの幅の半分まで。
    func wedgeWidth(_ seconds: Double, rect r: CGRect) -> CGFloat {
        min(CGFloat(seconds * geometry.pps), r.width / 2)
    }

    /// 三角の先端(つまみ)の位置。
    func wedgeHandle(_ c: Clip, _ edge: TransitionEdge, rect r: CGRect) -> NSPoint? {
        guard let info = wedgeInfo(c, edge) else { return nil }
        let w = wedgeWidth(info.seconds, rect: r)
        return NSPoint(x: edge == .in ? r.minX + w : r.maxX - w, y: r.minY + 7)
    }

    private func drawTransitionWedges(_ c: Clip, rect r: CGRect, selected: Bool, path: NSBezierPath, ctx: CGContext) {
        guard c.hasTransition || c.hasAudioFade else { return }
        ctx.saveGState()
        path.addClip()
        for edge in [TransitionEdge.in, .out] {
            guard let info = wedgeInfo(c, edge) else { continue }
            let w = wedgeWidth(info.seconds, rect: r)
            guard w >= 1 else { continue }
            let tri = NSBezierPath()
            if edge == .in {
                tri.move(to: NSPoint(x: r.minX, y: r.maxY)); tri.line(to: NSPoint(x: r.minX + w, y: r.minY)); tri.line(to: NSPoint(x: r.minX + w, y: r.maxY))
            } else {
                tri.move(to: NSPoint(x: r.maxX - w, y: r.minY)); tri.line(to: NSPoint(x: r.maxX, y: r.maxY)); tri.line(to: NSPoint(x: r.maxX - w, y: r.maxY))
            }
            tri.close()
            NSColor(white: 1, alpha: info.audio ? 0.2 : 0.3).setFill(); tri.fill()
            let edgeLine = NSBezierPath()
            if edge == .in { edgeLine.move(to: NSPoint(x: r.minX, y: r.maxY)); edgeLine.line(to: NSPoint(x: r.minX + w, y: r.minY)) }
            else { edgeLine.move(to: NSPoint(x: r.maxX - w, y: r.minY)); edgeLine.line(to: NSPoint(x: r.maxX, y: r.maxY)) }
            edgeLine.lineWidth = 1
            NSColor(white: 1, alpha: 0.75).setStroke(); edgeLine.stroke()
        }
        ctx.restoreGState()
        if selected {
            for edge in [TransitionEdge.in, .out] {
                guard let pt = wedgeHandle(c, edge, rect: r) else { continue }
                let rad = Self.wedgeHandleRadius
                let dot = NSBezierPath(ovalIn: NSRect(x: pt.x - rad, y: pt.y - rad, width: rad * 2, height: rad * 2))
                NSColor.white.setFill(); dot.fill()
                dot.lineWidth = 1
                NSColor(white: 0, alpha: 0.65).setStroke(); dot.stroke()
            }
        }
    }

    /// 点の下にある、選択クリップの三角のつまみ。
    func wedgeHit(at p: NSPoint) -> (clipId: String, edge: TransitionEdge, audio: Bool, seconds: Double)? {
        guard let id = selectedId, let loc = ClipEditing.locate(id, in: project) else { return nil }
        let c = project.tracks[loc.track].clips[loc.index]
        let r = geometry.clipRect(start: c.start, duration: c.duration, track: loc.track)
        var best: (edge: TransitionEdge, audio: Bool, seconds: Double, d: CGFloat)?
        for edge in [TransitionEdge.in, .out] {
            guard let info = wedgeInfo(c, edge), let pt = wedgeHandle(c, edge, rect: r),
                  abs(p.x - pt.x) <= Self.wedgeHit, abs(p.y - pt.y) <= Self.wedgeHit else { continue }
            let d = abs(p.x - pt.x)
            if best == nil || d < best!.d { best = (edge, info.audio, info.seconds, d) }
        }
        return best.map { (id, $0.edge, $0.audio, $0.seconds) }
    }

    // MARK: キーフレームの菱形(選択クリップの下端)

    static let diamondHalf: CGFloat = 4
    static let diamondHit: CGFloat = 7

    /// 選択クリップのキー(時刻ごと)の菱形の中心。クリップの外に出たキーは出さない。
    func keyframeDiamondCenters(_ c: Clip, rect r: CGRect) -> [(time: Double, point: NSPoint)] {
        guard c.hasKeyframes else { return [] }
        return KeyframeEditing.keyTimes(c).filter { $0 >= -1e-9 && $0 <= c.duration + 1e-9 }.map { t in
            (t, NSPoint(x: r.minX + CGFloat(t * geometry.pps), y: r.maxY - 7))
        }
    }

    private func drawKeyframeDiamonds(_ c: Clip, rect r: CGRect, ctx: CGContext) {
        let h = Self.diamondHalf
        ctx.saveGState()
        ctx.clip(to: r.insetBy(dx: 0, dy: 0))
        for (_, pt) in keyframeDiamondCenters(c, rect: r) {
            let d = NSBezierPath()
            d.move(to: NSPoint(x: pt.x, y: pt.y - h)); d.line(to: NSPoint(x: pt.x + h, y: pt.y))
            d.line(to: NSPoint(x: pt.x, y: pt.y + h)); d.line(to: NSPoint(x: pt.x - h, y: pt.y)); d.close()
            NSColor.white.setFill(); d.fill()
            d.lineWidth = 1
            NSColor(white: 0, alpha: 0.65).setStroke(); d.stroke()
        }
        ctx.restoreGState()
    }

    /// 点の下にある、選択クリップのキーの菱形(時刻はクリップの頭からの秒)。
    func keyframeHit(at p: NSPoint) -> (clipId: String, time: Double)? {
        guard let id = selectedId, let loc = ClipEditing.locate(id, in: project) else { return nil }
        let c = project.tracks[loc.track].clips[loc.index]
        let r = geometry.clipRect(start: c.start, duration: c.duration, track: loc.track)
        var best: (Double, Double)?
        for (t, pt) in keyframeDiamondCenters(c, rect: r) where abs(p.x - pt.x) <= Self.diamondHit && abs(p.y - pt.y) <= Self.diamondHit + 1 {
            let d = abs(p.x - pt.x)
            if best == nil || d < best!.1 { best = (t, d) }
        }
        return best.map { (id, $0.0) }
    }

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
        endRename(commit: true)
        mouseDown(at: point(e), modifiers: e.modifierFlags, clickCount: e.clickCount)
    }

    /// テストからも呼べるよう、イベントから切り離した入口。⌘ はトグル、⇧ は範囲(同じレイヤー)を足す。
    func mouseDown(at p: NSPoint, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) {
        mouseIsDown = true
        let hw = TimelineLayout.headerWidth
        if p.y < TimelineLayout.rulerHeight {
            if let isIn = rangeEdgeHit(at: p), let m = model, !m.isLocked {
                rangeDrag = RangeDrag(isIn: isIn, downPoint: p)     // 範囲の印: ドラッグで動かす(離したときに 1 回の Undo)
            } else if let m = markerHit(at: p) {
                markerDrag = MarkerDrag(id: m.id, downPoint: p, downTime: m.time)    // 旗: クリックで移動、ドラッグで動かす
            } else if p.x >= hw {
                beginScrub(at: p)
            }
            return
        }
        if p.x < hw {
            if let i = geometry.rowIndex(forY: p.y, rowCount: project.tracks.count) {
                let top = geometry.rowTop(i)
                let chips = TimelineLayout.chipRects(rowTop: top, rowHeight: geometry.rowHeight(i))
                if chips.hide.contains(p) { model?.toggleTrack(i, .hidden) }
                else if chips.mute.contains(p) { model?.toggleTrack(i, .muted) }
                else if TimelineLayout.lockRect(rowTop: top).contains(p) { model?.toggleLayerLock(i) }
                else if TimelineLayout.soloRect(rowTop: top).contains(p) { model?.toggleLayerSolo(i) }
                else if TimelineLayout.deleteRect(rowTop: top, rowHeight: geometry.rowHeight(i)).contains(p) { model?.requestDeleteLayer(i) }   // ×: 確認のうえ削除
                else if clickCount >= 2 { beginRenameLayer(i) }       // 名前のダブルクリック: その場で名前を変える
                else { model?.selectLayer(i) }                        // ヘッダー: レイヤーを選ぶ(貼り付けの行き先)
            }
            return
        }
        if let hit = wedgeHit(at: p), let m = model, !m.isLocked {
            wedgeDrag = WedgeDrag(clipId: hit.clipId, edge: hit.edge, audio: hit.audio, downX: p.x, startSeconds: hit.seconds)
            return
        }
        if let hit = keyframeHit(at: p), let m = model, !m.isLocked {
            keyDrag = KeyDrag(clipId: hit.clipId, time: hit.time, downPoint: p, downTime: geometry.time(forX: p.x))
            return
        }
        let mod: SelectionModifier = modifiers.contains(.command) ? .command : (modifiers.contains(.shift) ? .shift : .none)
        if let id = clipId(at: p) {
            guard let m = model else { return }
            if mod != .none {
                // ⌘-クリック = トグル、⇧-クリック = 足す。ドラッグは始めない
                m.setSelection(TimelineSelection.click(m.selection, on: id, modifier: mod, in: project))
                return
            }
            var collapse: String?
            if m.selectedClipIDs.count > 1, m.selectedClipIDs.contains(id) {
                // 選択の中のクリップを押した: 選択はそのまま、これを主にして、まとめてドラッグできるようにする(動かさずに離せば、これだけの選択に戻す)
                m.setSelection(ClipSelection(ids: m.selectedClipIDs, primary: id))
                collapse = id
            } else {
                m.selectOnly(id)
            }
            guard !m.isLocked, let loc = ClipEditing.locate(id, in: project), !project.tracks[loc.track].isLocked else { return }   // ロックされたレイヤーのクリップは動かさない
            let c = project.tracks[loc.track].clips[loc.index]
            let r = geometry.clipRect(start: c.start, duration: c.duration, track: loc.track)
            let zone = TimelineHit.zone(x: p.x, minX: r.minX, maxX: r.maxX, edgeZone: Self.edgeZone)
            let mode: DragMode = zone == .left ? .trimLeft : (zone == .right ? .trimRight : .move)
            if clickCount >= 2, zone == .body, TimelineHit.editsTextOnDoubleClick(c.type) { m.textFocusRequest += 1 }   // ダブルクリック: 文字の入力欄へ
            if mode != .move && collapse != nil { m.selectOnly(id); collapse = nil }     // 端のトリムは 1 つのクリップだけ
            drag = ClipDrag(clipId: id, mode: mode, downPoint: p, downTime: geometry.time(forX: p.x), lastTarget: loc.track, lastPoint: p,
                            ids: m.selectedClipIDs, collapseTo: collapse)
        } else {
            // 何もない所: 動かさずに離せば「選択を外して、その時刻へ(シーク)」、3pt 以上動かせばラバーバンド
            rubber = Rubber(origin: p, current: p, base: model?.selection ?? .empty, additive: mod != .none)
        }
    }

    override func mouseDragged(with e: NSEvent) { mouseDragged(to: point(e)) }

    func mouseDragged(to p: NSPoint) {
        if isScrubbing { scrub(to: p); return }
        if var rd = rangeDrag {
            if !rd.active {
                guard abs(p.x - rd.downPoint.x) >= Self.dragThreshold, let m = model else { return }
                m.beginGesture()
                rd.active = true
                rd.base = m.project
                rangeDrag = rd
            }
            let t = geometry.time(forX: p.x)
            let next = rd.isIn ? ExportRangeEditing.settingIn(rd.base, at: t) : ExportRangeEditing.settingOut(rd.base, at: t)
            if let next {
                model?.updateGesture(next)
                syncFromModel()
                needsDisplay = true
            }
            return
        }
        if var wd = wedgeDrag {
            if !wd.active {
                guard abs(p.x - wd.downX) >= Self.dragThreshold, let m = model else { return }
                m.beginGesture()
                wd.active = true
                wd.base = m.project
                wedgeDrag = wd
            }
            let dt = Double(p.x - wd.downX) / geometry.pps
            let secs = max(MovieCutCore.Transition.minDuration, wd.startSeconds + (wd.edge == .in ? dt : -dt))
            if let moved = model?.projectSettingFadeLength(base: wd.base, clipId: wd.clipId, edge: wd.edge, seconds: secs, audio: wd.audio) {
                model?.updateGesture(moved)
            }
            syncFromModel()
            needsDisplay = true
            return
        }
        if var kd = keyDrag {
            if !kd.active {
                guard abs(p.x - kd.downPoint.x) >= Self.dragThreshold, let m = model else { return }
                m.beginGesture()
                kd.active = true
                kd.base = m.project
                keyDrag = kd
            }
            let target = kd.time + geometry.time(forX: p.x) - kd.downTime
            if let moved = model?.projectMovingKeys(base: kd.base, clipId: kd.clipId, from: kd.time, to: target) {
                model?.updateGesture(moved)
            } else if let m = model {
                m.updateGesture(kd.base)       // 動かせない(元の位置に戻した)
            }
            syncFromModel()
            needsDisplay = true
            return
        }
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
        if var rb = rubber {
            if !rb.active {
                guard hypot(p.x - rb.origin.x, p.y - rb.origin.y) >= Self.dragThreshold else { return }
                rb.active = true
            }
            rb.current = p
            rubber = rb
            updateRubberSelection(rb)
            needsDisplay = true
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
        if let rd = rangeDrag {
            rangeDrag = nil
            if rd.active {
                model?.commitGesture("書き出し範囲の移動")     // 変わっていれば 1 回の Undo
                syncFromModel()
            }
            needsDisplay = true
            return
        }
        if let wd = wedgeDrag {
            wedgeDrag = nil
            if wd.active {
                model?.commitGesture(wd.audio ? "フェードの長さの変更" : "トランジションの長さの変更")     // 変わっていれば 1 回の Undo
                syncFromModel()
            }
            needsDisplay = true
            return
        }
        if let kd = keyDrag {
            keyDrag = nil
            if kd.active {
                model?.commitGesture("キーフレームの移動")     // 変わっていれば 1 回の Undo
                syncFromModel()
            } else if let start = ClipEditing.locate(kd.clipId, in: project).map({ project.tracks[$0.track].clips[$0.index].start }) {
                model?.playback.seek(to: start + kd.time)       // 菱形のクリック: その時刻へ
            }
            needsDisplay = true
            return
        }
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
        if let rb = rubber {
            rubber = nil
            if !rb.active, !rb.additive, let m = model {
                m.selectOnly(nil)                                  // 何もない所: 選択を外して、その時刻へ
                if let row = geometry.rowIndex(forY: rb.origin.y, rowCount: project.tracks.count), rb.origin.x >= TimelineLayout.headerWidth {
                    m.selectLayer(row)                             // 押した行を貼り付けの行き先にする
                } else {
                    m.selectedLayerIndex = nil
                }
                beginScrub(at: rb.origin)
                isScrubbing = false
                m.playback.endScrub()
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
        if !d.active, let id = d.collapseTo { model?.selectOnly(id) }   // 動かさずに離した: 複数選択の中の 1 つだけにする
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
            result = m.projectMoving(base: d.base, ids: d.ids, primary: d.clipId, deltaT: dt, targetTrack: d.lastTarget)
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
        if !m.selectedClipIDs.contains(clipId) { m.selectOnly(clipId) } else if m.selectedClipId != clipId { m.setSelection(ClipSelection(ids: m.selectedClipIDs, primary: clipId)) }
        m.beginGesture()
        var d = ClipDrag(clipId: clipId, mode: mode, downPoint: .zero, downTime: 0, lastTarget: targetTrack ?? loc.track, lastPoint: .zero,
                         ids: m.selectedClipIDs.contains(clipId) ? m.selectedClipIDs : [clipId])
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
                            time: m.currentTime, pps: m.pps, playing: m.isPlaying,
                            selectedIds: m.selectedClipIDs, selectedLayer: m.selectedLayerIndex))
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

    // MARK: 複数選択(ラバーバンド)

    /// ラバーバンドの四角に(少しでも)かかるクリップを選ぶ。⇧/⌘ で始めたなら、押す前の選択に足す。
    func updateRubberSelection(_ rb: Rubber) {
        guard let m = model else { return }
        let r = rubberRect(rb)
        let t0 = max(0, geometry.time(forX: r.minX)), t1 = geometry.time(forX: r.maxX)
        var first: Int?, last: Int?
        for i in project.tracks.indices {
            let top = geometry.rowTop(i), bottom = top + geometry.rowHeight(i)
            if bottom > r.minY && top < r.maxY && bottom > TimelineLayout.rulerHeight {
                if first == nil { first = i }
                last = i
            }
        }
        var hits: [String] = []
        if let f = first, let l = last, t1 >= t0 {
            hits = TimelineSelection.clips(in: project, timeRange: t0...t1, rows: f...l)
        }
        let new = TimelineSelection.rubberBand(base: rb.base, hits: hits, additive: rb.additive, in: project)
        if new != m.selection { m.setSelection(new) }
    }

    // MARK: レイヤー名のその場編集

    private(set) var renamingRow: Int?
    private var renameField: NSTextField?

    /// ヘッダーの名前をその場で書き換える欄を出す(Enter か他を押すと確定、Esc でやめる)。ロックの有無に関係なく変えられる。
    func beginRenameLayer(_ i: Int) {
        guard project.tracks.indices.contains(i), model?.isLocked != true else { return }
        endRename(commit: true)
        let top = geometry.rowTop(i)
        let f = NSTextField(frame: NSRect(x: 4, y: top + (geometry.rowHeight(i) < 40 ? 1 : 3), width: TimelineLayout.headerWidth - 44, height: 17))
        f.stringValue = project.tracks[i].name
        f.font = Self.headFont
        f.isBordered = false
        f.focusRingType = .none
        f.drawsBackground = true
        f.backgroundColor = rgb(0x15161a)
        f.textColor = TimelinePalette.text0
        f.delegate = self
        f.cell?.isScrollable = true
        renameField = f
        renamingRow = i
        addSubview(f)
        window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
        needsDisplay = true
    }

    /// 名前の編集を終える。`commit` なら入力した名前に変える(空・同じなら何もしない)。
    func endRename(commit: Bool) {
        guard let f = renameField, let row = renamingRow else { return }
        let text = f.stringValue
        renameField = nil; renamingRow = nil
        f.delegate = nil
        f.removeFromSuperview()
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        if commit { model?.renameLayer(row, to: text) }
        needsDisplay = true
    }

    /// 検証用: 名前の欄に文字を入れて確定する。
    func debugCommitRename(_ text: String) {
        renameField?.stringValue = text
        endRename(commit: true)
    }

    // MARK: 右クリックのメニュー(ヘッダー = レイヤー、クリップ = コピー・貼り付けなど)

    /// ヘッダーの右クリックのメニュー(検証用に行から作れる)。
    func layerContextMenu(row i: Int) -> NSMenu? {
        guard let m = model, m.project.tracks.indices.contains(i) else { return nil }
        let tr = m.project.tracks[i]
        let menu = NSMenu()
        func add(_ title: String, checked: Bool = false, enabled: Bool = true, _ run: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
            let a = MenuAction(run)
            item.target = a
            item.representedObject = a      // メニューが生きている間、実行する側を保つ
            item.isEnabled = enabled
            item.state = checked ? .on : .off
            menu.addItem(item)
        }
        add("名前を変更…") { [weak self] in self?.beginRenameLayer(i) }
        menu.addItem(.separator())
        add("ロック", checked: tr.isLocked) { m.toggleLayerLock(i) }
        add("ソロ", checked: tr.isSolo) { m.toggleLayerSolo(i) }
        menu.addItem(.separator())
        add("レイヤーを削除…", enabled: LayerEditing.deleteBlockedReason(in: m.project, index: i) == nil) { m.requestDeleteLayer(i) }
        menu.addItem(.separator())
        for h in LayerHeight.allCases { add("高さ: \(h.title)", checked: LayerHeight.of(tr) == h) { m.setLayerHeight(i, h) } }
        return menu
    }

    /// クリップの右クリックのメニュー。
    func clipContextMenu() -> NSMenu? {
        guard let m = model else { return nil }
        let menu = NSMenu()
        func add(_ title: String, enabled: Bool = true, _ run: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
            let a = MenuAction(run)
            item.target = a
            item.representedObject = a
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add("コピー", enabled: !m.selectedClipIDs.isEmpty) { m.copySelection() }
        add("切り取り", enabled: !m.selectedClipIDs.isEmpty) { m.cutSelection() }
        add("貼り付け", enabled: m.canPasteClips) { m.pasteClips() }
        menu.addItem(.separator())
        add("再生位置で分割", enabled: m.canSplit) { m.splitSelected() }
        add("複製", enabled: !m.selectedClipIDs.isEmpty) { m.duplicateSelected() }
        add("削除", enabled: !m.selectedClipIDs.isEmpty) { m.deleteSelected() }
        add("すき間を詰めて削除", enabled: !m.selectedClipIDs.isEmpty) { m.rippleDeleteSelected() }
        return menu
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let p = point(event)
        guard p.y >= TimelineLayout.rulerHeight, let m = model else { return nil }
        if p.x < TimelineLayout.headerWidth {
            guard let i = geometry.rowIndex(forY: p.y, rowCount: project.tracks.count) else { return nil }
            m.selectLayer(i)
            return layerContextMenu(row: i)
        }
        if let id = clipId(at: p) {
            if !m.selectedClipIDs.contains(id) { m.selectOnly(id) }      // 選択の外を右クリックしたら、それだけを選ぶ
            return clipContextMenu()
        }
        return nil
    }

    // MARK: 標準の編集コマンド(responder chain)

    /// ⌘C ⌘X ⌘V ⌘A はメニューの標準項目から、先頭の responder へ届く。タイムラインにフォーカスがあるときだけ、クリップに対して働く
    /// (入力欄にフォーカスがあれば、入力欄がコピー・貼り付けを受ける)。
    @objc func copy(_ sender: Any?) { model?.copySelection() }
    @objc func cut(_ sender: Any?) { model?.cutSelection() }
    @objc func paste(_ sender: Any?) { model?.pasteClips() }
    @objc override func selectAll(_ sender: Any?) { model?.selectAllClips() }
}

/// メニュー項目から呼ばれる処理の入れ物。
final class MenuAction: NSObject {
    let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func run() { body() }
}

extension TimelineCanvas: NSTextFieldDelegate, NSUserInterfaceValidations {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { endRename(commit: true); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { endRename(commit: false); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) { endRename(commit: true) }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let m = model, !m.isLocked else { return false }
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)): return !m.selectedClipIDs.isEmpty
        case #selector(paste(_:)): return m.canPasteClips
        case #selector(selectAll(_:)): return !m.project.allClips.isEmpty
        default: return true
        }
    }
}
