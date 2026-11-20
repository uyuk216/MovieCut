import SwiftUI
import AppKit
import MovieCutCore

/// プレビュー本体。時刻 t のフレームを背景スレッドで描き、設定した単色の背景の上に本当の縦横比で置く。
struct PreviewView: NSViewRepresentable {
    let project: Project
    let time: Double
    let assets: RenderAssets
    let model: ProjectModel
    /// 同じ時刻・同じ内容でも描き直したいときに増やす(再生を止めたとき、正確なフレームに戻す)。
    var epoch = 0

    func makeCoordinator() -> PreviewCoordinator { PreviewCoordinator(model: model) }

    func makeNSView(context: Context) -> PreviewCanvasView {
        let v = PreviewCanvasView()
        context.coordinator.view = v
        v.setPlaceholder(project: project)
        context.coordinator.request(project: project, time: time, assets: assets, epoch: epoch)
        v.model = model; v.updateOverlay(Self.overlayTarget(model: model, project: project, time: time, assets: assets))
        return v
    }

    func updateNSView(_ nsView: PreviewCanvasView, context: Context) {
        context.coordinator.request(project: project, time: time, assets: assets, epoch: epoch)
        nsView.model = model; nsView.updateOverlay(Self.overlayTarget(model: model, project: project, time: time, assets: assets))
    }

    /// 選択クリップの枠(直接操作の取っ手)。枠で選べる種類(画像・動画・文字・複合・立ち絵)を選んでいて、再生ヘッドがその中にあり、止まっているときだけ。
    @MainActor
    static func overlayTarget(model: ProjectModel, project: Project, time: Double, assets: RenderAssets) -> PreviewOverlayTarget? {
        guard !model.isPlaying, !model.isLocked, let c = model.selectedClip,
              PreviewPicking.isPickable(c.type), time >= c.start, time < c.start + c.duration,
              let size = Renderer(project: project, assets: assets).objectSize(of: c, at: time) else { return nil }
        let canvas = CGSize(width: project.width, height: project.height)
        var target = PreviewOverlayTarget(clipId: c.id, box: TransformBox.make(clip: c, objectSize: size, at: time - c.start, canvas: canvas), canvas: canvas)
        // メッシュ/パペット変形の取っ手(時刻で評価した位置)。変形が無いクリップでは空で、従来の表示と変わらない
        target.warpHandles = c.warpHandles(at: time - c.start)
        target.meshCols = c.meshWarp?.cols ?? 0
        target.meshRows = c.meshWarp?.rows ?? 0
        // ペンマスクの制御点(キャンバス割合・左上原点)。ペンでなければ空で、従来の表示と変わらない
        if let mask = c.mask, mask.shape == "pen" { target.penPoints = mask.points }
        return target
    }
}

/// プレビュー上の選択枠: どのクリップの、画面(キャンバスの画素)のどこにあるか。
struct PreviewOverlayTarget: Equatable {
    var clipId: String
    var box: TransformBox
    var canvas: CGSize
    /// 変形の取っ手(メッシュの制御点・パペットのピン)。空なら変形の表示は出ない。
    var warpHandles: [WarpHandle] = []
    var meshCols: Int = 0
    var meshRows: Int = 0
    /// ペンマスクの制御点(キャンバス割合・左上原点)。空ならペンの表示は出ない。
    var penPoints: [MaskPoint] = []
}

/// 描画要求をまとめる(古い要求は捨てて、最新だけ描く)。
final class PreviewCoordinator {
    weak var view: PreviewCanvasView?
    let model: ProjectModel
    private let queue = DispatchQueue(label: "moviecut.preview.render", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: (project: Project, time: Double, assets: RenderAssets, seq: Int)?
    private var running = false
    // 主スレッドだけで触る
    private var lastProject: Project?
    private var lastTime: Double?
    private var lastAssets: RenderAssets?
    private var lastEpoch = -1
    private var seq = 0

    init(model: ProjectModel) { self.model = model }

    /// 手ぶれ補正の解析が終わった: 同じ時刻をもう一度描く(補正なしで出していたコマを置き換える)。
    private func redrawAfterStabilization() {
        guard let p = lastProject, let t = lastTime, let a = lastAssets else { return }
        lastProject = nil
        request(project: p, time: t, assets: a, epoch: lastEpoch)
    }

    func request(project: Project, time: Double, assets: RenderAssets, epoch: Int = 0) {
        if lastEpoch == epoch && lastTime == time && lastProject == project { return }
        lastProject = project; lastTime = time; lastEpoch = epoch; lastAssets = assets
        seq += 1
        let mySeq = seq
        MainActor.assumeIsolated { model.previewRequested() }
        view?.setPlaceholder(project: project)
        lock.lock()
        // まだ描かれていない古い要求を上書きした = そのフレームは描かれずに落ちた
        if pending != nil { MainActor.assumeIsolated { model.previewDropped += 1 } }
        pending = (project, time, assets, mySeq)
        let start = !running
        running = true
        lock.unlock()
        if start { queue.async { [weak self] in self?.loop() } }
    }

    private func loop() {
        while true {
            lock.lock()
            guard let job = pending else { running = false; lock.unlock(); return }
            pending = nil
            lock.unlock()
            let img = Renderer(project: job.project, assets: job.assets, onStabilized: { [weak self] in
                // 解析は背景で終わる: 再描画は主スレッドで
                DispatchQueue.main.async { self?.redrawAfterStabilization() }
            }, missingMediaPlaceholder: true, pluginEffectProviders: AppServices.pluginEffectProviders).renderImage(t: job.time)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let img { self.view?.show(image: img) }
                MainActor.assumeIsolated { self.model.previewDisplayed(idle: job.seq == self.seq) }
            }
        }
    }
}

/// レイヤーで描く NSView。背景は単色(表示 ▸ プレビューの背景。既定は暗い灰色)、中央にフレーム(1pt の枠 + 影)。
final class PreviewCanvasView: NSView {
    private let frameLayer = CALayer()
    private var aspect = CGSize(width: 16, height: 9)
    private var hasImage = false

    weak var model: ProjectModel?

    // 直接操作(選択枠 + 4 つの角 + 回転の取っ手)
    private let outlineLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    /// 変形の取っ手(格子の線・ピンの元の位置は線レイヤー、動かせる取っ手は塗りレイヤー)。
    private let warpLineLayer = CAShapeLayer()
    private let warpHandleLayer = CAShapeLayer()
    /// ペンマスクの輪郭と取っ手(線レイヤーと塗りレイヤー)。
    private let penLineLayer = CAShapeLayer()
    private let penHandleLayer = CAShapeLayer()
    private(set) var overlay: PreviewOverlayTarget?
    struct ManipulationDrag {
        var kind: DirectManipulation.Kind
        var clipId: String
        var start: CGPoint          // キャンバスの画素
        var base: Clip
        var relTime: Double
        var name: String
        /// 変形の取っ手のドラッグのとき、その取っ手の種類(通常の変形ドラッグでは nil)。
        var warp: WarpKey.Kind? = nil
        /// ペンマスクの取っ手のドラッグのとき、どの点のどの部分か(それ以外では nil)。
        var pen: PenRef? = nil
    }
    /// ペンマスクの取っ手: 点の番号と、アンカー/入るハンドル/出るハンドルの区別。
    struct PenRef: Equatable {
        var index: Int
        var part: Part
        enum Part: Equatable { case anchor, inHandle, outHandle }
    }
    private(set) var manipulation: ManipulationDrag?
    /// ガイド線(表示 ▸ ガイド線)。プレビューの上に重ねるだけで、書き出しには入らない。
    private let guideLayer = CAShapeLayer()
    /// 分割グリッドのガイド線(点線・控えめな濃さで、実線のガイドとは別レイヤー)。
    private let gridGuideLayer = CAShapeLayer()
    /// スナップ(吸着)した線をドラッグ中だけ出す専用レイヤー。
    private let snapLineLayer = CAShapeLayer()
    /// ドラッグ開始時に集めたスナップ先(ドラッグ中は固定し、再計算しない)。
    private var snapTargets: PreviewSnap.Targets?
    /// ドラッグ開始時の枠(スナップの移動計算の基準)。
    private var snapBaseBox: TransformBox?
    /// いま吸着している線(キャンバスの画素。縦線は x、横線は y)。
    private var snappedVertical: Double?
    private var snappedHorizontal: Double?
    /// 吸着の閾値(画面の pt)。キャンバス画素へはビューの縮尺で換算する。
    static let snapThresholdPoints: CGFloat = 8

    /// テスト用: いま吸着している線(キャンバスの画素)。
    var snappedLinesForTest: (vertical: Double?, horizontal: Double?) { (snappedVertical, snappedHorizontal) }
    /// 取っ手に反応する半径(ビューの pt)。
    static let handleRadius: CGFloat = 9

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let root = CALayer()
        root.cornerRadius = 8
        root.masksToBounds = true
        root.backgroundColor = Self.cgColor(for: PreviewBackgroundStore.current)
        layer = root
        rootLayer = root
        NotificationCenter.default.addObserver(self, selector: #selector(backgroundChanged), name: PreviewBackgroundStore.didChange, object: nil)
        frameLayer.contentsGravity = .resize
        frameLayer.magnificationFilter = .linear
        frameLayer.minificationFilter = .trilinear
        frameLayer.borderWidth = 1
        frameLayer.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
        frameLayer.shadowColor = NSColor.black.cgColor
        frameLayer.shadowOpacity = 0.45
        frameLayer.shadowRadius = 8
        frameLayer.shadowOffset = CGSize(width: 0, height: -2)
        frameLayer.masksToBounds = false
        root.addSublayer(frameLayer)
        outlineLayer.fillColor = nil
        outlineLayer.strokeColor = NSColor(srgbRed: 1, green: 0.85, blue: 0.31, alpha: 1).cgColor
        outlineLayer.lineWidth = 1.5
        outlineLayer.isHidden = true
        handleLayer.fillColor = NSColor.white.cgColor
        handleLayer.strokeColor = NSColor(white: 0, alpha: 0.7).cgColor
        handleLayer.lineWidth = 1
        handleLayer.isHidden = true
        guideLayer.fillColor = nil
        guideLayer.strokeColor = NSColor(white: 1, alpha: 0.6).cgColor
        guideLayer.lineWidth = 1
        guideLayer.isHidden = true
        gridGuideLayer.fillColor = nil
        gridGuideLayer.strokeColor = NSColor(white: 1, alpha: 0.35).cgColor
        gridGuideLayer.lineWidth = 1
        gridGuideLayer.lineDashPattern = [4, 4]
        gridGuideLayer.isHidden = true
        snapLineLayer.fillColor = nil
        snapLineLayer.strokeColor = NSColor(srgbRed: 1, green: 0.6, blue: 0.2, alpha: 1).cgColor
        snapLineLayer.lineWidth = 1
        snapLineLayer.isHidden = true
        warpLineLayer.fillColor = nil
        warpLineLayer.strokeColor = NSColor(srgbRed: 0.35, green: 0.8, blue: 1, alpha: 0.9).cgColor
        warpLineLayer.lineWidth = 1
        warpLineLayer.isHidden = true
        warpHandleLayer.fillColor = NSColor.white.cgColor
        warpHandleLayer.strokeColor = NSColor(srgbRed: 0.1, green: 0.45, blue: 0.7, alpha: 1).cgColor
        warpHandleLayer.lineWidth = 1.25
        warpHandleLayer.isHidden = true
        penLineLayer.fillColor = nil
        penLineLayer.strokeColor = NSColor(srgbRed: 1, green: 0.45, blue: 0.75, alpha: 0.95).cgColor
        penLineLayer.lineWidth = 1.25
        penLineLayer.isHidden = true
        penHandleLayer.fillColor = NSColor.white.cgColor
        penHandleLayer.strokeColor = NSColor(srgbRed: 0.75, green: 0.15, blue: 0.45, alpha: 1).cgColor
        penHandleLayer.lineWidth = 1.25
        penHandleLayer.isHidden = true
        root.addSublayer(guideLayer)
        root.addSublayer(gridGuideLayer)
        root.addSublayer(snapLineLayer)
        root.addSublayer(outlineLayer)
        root.addSublayer(handleLayer)
        root.addSublayer(warpLineLayer)
        root.addSublayer(warpHandleLayer)
        root.addSublayer(penLineLayer)
        root.addSublayer(penHandleLayer)
        NotificationCenter.default.addObserver(self, selector: #selector(guidesChanged), name: PreviewGuideStore.didChange, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var rootLayer: CALayer?

    /// 背景色(単色)。
    static func cgColor(for b: PreviewBackground) -> CGColor {
        parseHexColor(b.hex) ?? NSColor(white: 0.12, alpha: 1).cgColor
    }

    /// 現在の背景色(試験用)。
    var backgroundColorForTest: CGColor? { rootLayer?.backgroundColor }

    @objc private func backgroundChanged() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootLayer?.backgroundColor = Self.cgColor(for: PreviewBackgroundStore.current)
        CATransaction.commit()
    }

    @objc private func guidesChanged() { redrawGuides() }

    /// ガイド線を描き直す(枠の位置・大きさ・設定が変わったとき)。ガイドが無ければ隠す。
    /// セーフ領域と中心線は実線(guideLayer)、分割グリッド線だけ点線・控えめな濃さの別レイヤー(gridGuideLayer)。
    private func redrawGuides() {
        let guides = PreviewGuideStore.current
        let canvas = aspect
        guard !guides.isEmpty, frameLayer.frame.width > 0 else {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            guideLayer.isHidden = true
            gridGuideLayer.isHidden = true
            CATransaction.commit()
            return
        }
        let solid = CGMutablePath()
        for r in GuideGeometry.safeRects(guides, canvas: canvas) {
            let a = viewPoint(CGPoint(x: r.minX, y: r.minY), canvas: canvas), b = viewPoint(CGPoint(x: r.maxX, y: r.maxY), canvas: canvas)
            solid.addRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        }
        for l in GuideGeometry.lines(guides.intersection([.center]), canvas: canvas) {
            solid.move(to: viewPoint(l.from, canvas: canvas))
            solid.addLine(to: viewPoint(l.to, canvas: canvas))
        }
        let grid = CGMutablePath()
        for l in GuideGeometry.gridLines(guides, canvas: canvas) {
            grid.move(to: viewPoint(l.from, canvas: canvas))
            grid.addLine(to: viewPoint(l.to, canvas: canvas))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        guideLayer.path = solid
        guideLayer.isHidden = solid.isEmpty
        gridGuideLayer.path = grid
        gridGuideLayer.isHidden = grid.isEmpty
        CATransaction.commit()
    }

    /// 吸着した線を描き直す(ドラッグ中だけ。吸着が無ければ隠す)。
    private func redrawSnapLines() {
        guard let o = overlay, snappedVertical != nil || snappedHorizontal != nil else {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            snapLineLayer.isHidden = true
            CATransaction.commit()
            return
        }
        let path = CGMutablePath()
        if let x = snappedVertical {
            path.move(to: viewPoint(CGPoint(x: x, y: 0), canvas: o.canvas))
            path.addLine(to: viewPoint(CGPoint(x: x, y: o.canvas.height), canvas: o.canvas))
        }
        if let y = snappedHorizontal {
            path.move(to: viewPoint(CGPoint(x: 0, y: y), canvas: o.canvas))
            path.addLine(to: viewPoint(CGPoint(x: o.canvas.width, y: y), canvas: o.canvas))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        snapLineLayer.path = path
        snapLineLayer.isHidden = false
        CATransaction.commit()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        frameLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// 最初のフレームが来るまで(と解像度が変わった直後)は、背景色の枠だけを出す。
    func setPlaceholder(project: Project) {
        if !hasImage {
            aspect = CGSize(width: max(1, project.width), height: max(1, project.height))
            frameLayer.backgroundColor = parseHexColor(project.bg) ?? NSColor.black.cgColor
            relayout()
        }
    }

    func show(image: CGImage) {
        hasImage = true
        aspect = CGSize(width: image.width, height: image.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.contents = image
        frameLayer.backgroundColor = nil
        CATransaction.commit()
        relayout()
    }

    override func layout() {
        super.layout()
        relayout()
    }

    // MARK: 選択枠と直接操作

    /// キャンバスの画素 → ビューの座標(ビューは y 上向き、キャンバスは y 下向き)。
    func viewPoint(_ p: CGPoint, canvas: CGSize) -> CGPoint {
        let f = frameLayer.frame
        return CGPoint(x: f.minX + p.x / canvas.width * f.width, y: f.maxY - p.y / canvas.height * f.height)
    }

    func canvasPoint(_ v: CGPoint, canvas: CGSize) -> CGPoint {
        let f = frameLayer.frame
        guard f.width > 0, f.height > 0 else { return .zero }
        return CGPoint(x: (v.x - f.minX) / f.width * canvas.width, y: (f.maxY - v.y) / f.height * canvas.height)
    }

    func updateOverlay(_ t: PreviewOverlayTarget?) {
        if manipulation != nil { overlay = t ?? overlay; redrawOverlay(); return }   // ドラッグ中は枠を作り直さない(動きに追従して描き直すだけ)
        overlay = t
        redrawOverlay()
    }

    private func redrawOverlay() {
        guard let o = overlay, o.canvas.width > 0, frameLayer.frame.width > 0 else {
            outlineLayer.isHidden = true; handleLayer.isHidden = true
            warpLineLayer.isHidden = true; warpHandleLayer.isHidden = true
            penLineLayer.isHidden = true; penHandleLayer.isHidden = true
            return
        }
        redrawWarpHandles(o)
        redrawPenHandles(o)
        let corners = o.box.corners.map { viewPoint($0, canvas: o.canvas) }
        let rot = viewPoint(o.box.rotationHandle, canvas: o.canvas)
        let top = viewPoint(CGPoint(x: (o.box.corners[0].x + o.box.corners[1].x) / 2, y: (o.box.corners[0].y + o.box.corners[1].y) / 2), canvas: o.canvas)
        let outline = CGMutablePath()
        outline.addLines(between: corners + [corners[0]])
        outline.move(to: top); outline.addLine(to: rot)
        let handles = CGMutablePath()
        for c in corners { handles.addRect(CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)) }
        handles.addEllipse(in: CGRect(x: rot.x - 5, y: rot.y - 5, width: 10, height: 10))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outlineLayer.path = outline
        handleLayer.path = handles
        outlineLayer.isHidden = false; handleLayer.isHidden = false
        CATransaction.commit()
    }

    /// 変形の取っ手を描く: 格子の線、ピンの元の位置(小さい丸)と現在位置への線、固定ピンの輪、
    /// 動かせる取っ手(メッシュは四角、ピンは丸)。変形が無ければ両レイヤーを隠す。
    private func redrawWarpHandles(_ o: PreviewOverlayTarget) {
        guard !o.warpHandles.isEmpty else {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            warpLineLayer.isHidden = true; warpHandleLayer.isHidden = true
            CATransaction.commit()
            return
        }
        func vp(_ p: WarpPoint) -> CGPoint { viewPoint(WarpDrag.canvasPoint(p, box: o.box), canvas: o.canvas) }
        let lines = CGMutablePath()
        if o.meshCols > 1, o.meshRows > 1 {
            func meshPt(_ i: Int) -> CGPoint? {
                o.warpHandles.first { $0.kind == .mesh(i) }.map { vp($0.position) }
            }
            for r in 0..<o.meshRows {
                for c in 0..<(o.meshCols - 1) {
                    if let a = meshPt(r * o.meshCols + c), let b = meshPt(r * o.meshCols + c + 1) { lines.move(to: a); lines.addLine(to: b) }
                }
            }
            for c in 0..<o.meshCols {
                for r in 0..<(o.meshRows - 1) {
                    if let a = meshPt(r * o.meshCols + c), let b = meshPt((r + 1) * o.meshCols + c) { lines.move(to: a); lines.addLine(to: b) }
                }
            }
        }
        for h in o.warpHandles {
            guard case .pin = h.kind else { continue }
            let cur = vp(h.position), home = vp(h.home)
            if cur != home { lines.move(to: home); lines.addLine(to: cur) }
            lines.addEllipse(in: CGRect(x: home.x - 3, y: home.y - 3, width: 6, height: 6))
            if h.fixed { lines.addEllipse(in: CGRect(x: cur.x - 6, y: cur.y - 6, width: 12, height: 12)) }
        }
        let handles = CGMutablePath()
        for h in o.warpHandles where !h.fixed {
            let c = vp(h.position)
            switch h.kind {
            case .mesh: handles.addRect(CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9))
            case .pin: handles.addEllipse(in: CGRect(x: c.x - 5.5, y: c.y - 5.5, width: 11, height: 11))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        warpLineLayer.path = lines
        warpHandleLayer.path = handles
        warpLineLayer.isHidden = false; warpHandleLayer.isHidden = false
        CATransaction.commit()
    }

    /// ペンマスクの輪郭と取っ手を描く: 曲線を平らにした輪郭、アンカー(四角)、
    /// ハンドル(丸。アンカーと違う所にあるときだけ、アンカーからの線と一緒に)。
    /// ペンでなければ両レイヤーを隠す。
    private func redrawPenHandles(_ o: PreviewOverlayTarget) {
        guard !o.penPoints.isEmpty else {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            penLineLayer.isHidden = true; penHandleLayer.isHidden = true
            CATransaction.commit()
            return
        }
        func vp(_ x: Double, _ y: Double) -> CGPoint { viewPoint(CGPoint(x: x * o.canvas.width, y: y * o.canvas.height), canvas: o.canvas) }
        let lines = CGMutablePath()
        let poly = ClipMask(shape: "pen", points: o.penPoints).sampledPolygon()
        if poly.count >= 3 {
            lines.move(to: vp(poly[0].x, poly[0].y))
            for p in poly.dropFirst() { lines.addLine(to: vp(p.x, p.y)) }
            lines.closeSubpath()
        }
        for pt in o.penPoints where !pt.isCorner {
            let a = vp(pt.x, pt.y)
            lines.move(to: a); lines.addLine(to: vp(pt.inX, pt.inY))
            lines.move(to: a); lines.addLine(to: vp(pt.outX, pt.outY))
            let ih = vp(pt.inX, pt.inY), oh = vp(pt.outX, pt.outY)
            lines.addEllipse(in: CGRect(x: ih.x - 3, y: ih.y - 3, width: 6, height: 6))
            lines.addEllipse(in: CGRect(x: oh.x - 3, y: oh.y - 3, width: 6, height: 6))
        }
        let handles = CGMutablePath()
        for pt in o.penPoints {
            let c = vp(pt.x, pt.y)
            handles.addRect(CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9))
            if !pt.isCorner {
                for h in [vp(pt.inX, pt.inY), vp(pt.outX, pt.outY)] {
                    handles.addEllipse(in: CGRect(x: h.x - 5, y: h.y - 5, width: 10, height: 10))
                }
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        penLineLayer.path = lines
        penHandleLayer.path = handles
        penLineLayer.isHidden = false; penHandleLayer.isHidden = false
        CATransaction.commit()
    }

    /// ペンの取っ手へのヒットテスト(キャンバスの画素)。ハンドルをアンカーより優先する。
    private func penHitTest(_ p: CGPoint, target o: PreviewOverlayTarget) -> PenRef? {
        guard !o.penPoints.isEmpty, o.canvas.width > 0, o.canvas.height > 0 else { return nil }
        let r = hitRadius(canvas: o.canvas)
        func cp(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * o.canvas.width, y: y * o.canvas.height) }
        func hit(_ q: CGPoint) -> Bool { hypot(p.x - q.x, p.y - q.y) <= r }
        for (i, pt) in o.penPoints.enumerated() where !pt.isCorner {
            if hit(cp(pt.inX, pt.inY)) { return PenRef(index: i, part: .inHandle) }
            if hit(cp(pt.outX, pt.outY)) { return PenRef(index: i, part: .outHandle) }
        }
        for (i, pt) in o.penPoints.enumerated() {
            if hit(cp(pt.x, pt.y)) { return PenRef(index: i, part: .anchor) }
        }
        return nil
    }

    /// 取っ手に反応する半径をキャンバスの画素に直したもの。
    private func hitRadius(canvas: CGSize) -> Double {
        let f = frameLayer.frame
        return f.width > 0 ? Double(Self.handleRadius) * canvas.width / f.width : Double(Self.handleRadius)
    }

    /// 試験用: 映像の枠(ビューの座標)。
    var frameForTest: CGRect { frameLayer.frame }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        // 入力欄にフォーカスが残っていると、Delete・Space がクリップに届かない。プレビューを押したら入力を終える
        if KeyRouter.isTextInput(window?.firstResponder) { window?.makeFirstResponder(nil) }
        let v = convert(event.locationInWindow, from: nil)
        // オブジェクトマスクのクリック指定待ち: 押した場所の対象を種にする(他の操作より優先)
        if let m = model, let pickId = m.objectMaskPickingClipId {
            m.cancelObjectMaskPicking()
            if frameLayer.frame.contains(v) {
                let canvas = CGSize(width: m.project.width, height: m.project.height)
                if canvas.width > 0, canvas.height > 0 {
                    let p = canvasPoint(v, canvas: canvas)
                    m.seedObjectMask(clipId: pickId, atNormalizedPoint: CGPoint(x: p.x / canvas.width, y: p.y / canvas.height))
                }
            }
            return
        }
        // ダブルクリック: 選択中のクリップの中なら、その場所にパペットのピンを打つ(Shift で固定ピン)
        if event.clickCount == 2, addPuppetPinAt(atViewPoint: v, fixed: event.modifierFlags.contains(.shift)) { return }
        // ⌥ クリック: その場所に重なったクリップを手前から奥へ巡回して選ぶ(ドラッグは始めない)
        if event.modifierFlags.contains(.option), pickOverlapping(atViewPoint: v) { return }
        // 選んでいる枠の上なら、そのままドラッグ(移動・拡大・回転)。外なら、押した場所のいちばん手前(枠で選べる種類)を選び、続けてドラッグできる
        if beginManipulation(atViewPoint: v) { return }
        selectTopmost(atViewPoint: v)
    }

    /// 押した場所のいちばん手前(枠で選べる種類: 画像・動画・文字・複合・立ち絵)を選び、その枠でドラッグを始める。
    /// 立ち絵の透明な所は当たらない(奥のクリップを選べる。当たり判定は PreviewPicking.hits が担保する)。何も無ければ選択は変えない。
    @discardableResult
    func selectTopmost(atViewPoint v: CGPoint) -> Bool {
        guard let m = model, !m.isLocked, frameLayer.frame.contains(v) else { return false }
        let canvas = CGSize(width: m.project.width, height: m.project.height)
        guard canvas.width > 0, canvas.height > 0,
              let id = PreviewPicking.hits(in: m.project, at: canvasPoint(v, canvas: canvas), time: m.currentTime, assets: m.assets).first else { return false }
        if m.selectedClipId != id || m.selectedClipIDs.count > 1 { m.selectOnly(id) }
        overlay = PreviewView.overlayTarget(model: m, project: m.project, time: m.currentTime, assets: m.assets)
        redrawOverlay()
        beginManipulation(atViewPoint: v)
        return true
    }

    /// ⌥ クリック: 押した場所(映像の枠の中)に重なるクリップを巡回して選ぶ。選べたら true(重なりが無ければ false で、通常のクリックに戻る)。
    @discardableResult
    func pickOverlapping(atViewPoint v: CGPoint) -> Bool {
        guard let m = model, !m.isLocked, frameLayer.frame.contains(v) else { return false }
        let canvas = CGSize(width: m.project.width, height: m.project.height)
        guard canvas.width > 0, canvas.height > 0 else { return false }
        return m.pickPreviewClip(atCanvasPoint: canvasPoint(v, canvas: canvas))
    }
    /// ダブルクリックした場所(選択中のクリップの中)にパペットのピンを打つ。打てたら true。Undo は 1 回。
    @discardableResult
    func addPuppetPinAt(atViewPoint v: CGPoint, fixed: Bool = false) -> Bool {
        guard let o = overlay, let m = model, !m.isLocked, let c = m.clip(o.clipId), Clip.supportsWarp(c.type) else { return false }
        let p = canvasPoint(v, canvas: o.canvas)
        guard o.box.hitTest(p, radius: 0) != .none else { return false }
        let wp = WarpDrag.warpPoint(canvas: p, box: o.box)
        guard wp.x >= -0.001, wp.x <= 1.001, wp.y >= -0.001, wp.y <= 1.001 else { return false }
        m.addPuppetPin(fixed: fixed, atX: wp.x, atY: wp.y, clipId: c.id)
        return m.clip(c.id)?.puppetWarp != nil
    }

    override func mouseDragged(with event: NSEvent) { dragManipulation(toViewPoint: convert(event.locationInWindow, from: nil), snapRotation: event.modifierFlags.contains(.shift), snapDisabled: event.modifierFlags.contains(.command)) }
    override func mouseUp(with event: NSEvent) { endManipulation() }

    /// 押した: 枠の本体・角・回転の取っ手に当たれば、ドラッグを始める(元のクリップを覚える)。当たらなければ false。
    @discardableResult
    func beginManipulation(atViewPoint v: CGPoint) -> Bool {
        guard let o = overlay, let m = model, !m.isLocked, let c = m.clip(o.clipId) else { return false }
        let p = canvasPoint(v, canvas: o.canvas)
        // ペンマスクの取っ手が一番手前(掴んだら、その点・ハンドルを動かす)
        if let ref = penHitTest(p, target: o) {
            m.beginGesture()
            manipulation = ManipulationDrag(kind: .move, clipId: c.id, start: p, base: c, relTime: min(max(m.currentTime - c.start, 0), c.duration), name: "プレビューでペンマスク", pen: ref)
            return true
        }
        // 変形の取っ手が次に手前(掴んだら、その点・ピンを動かす。通常の移動・拡大・回転より優先)
        if let h = WarpDrag.hitTest(p, handles: o.warpHandles, box: o.box, radius: hitRadius(canvas: o.canvas)) {
            m.beginGesture()
            manipulation = ManipulationDrag(kind: .move, clipId: c.id, start: p, base: c, relTime: min(max(m.currentTime - c.start, 0), c.duration), name: "プレビューで変形", warp: h.kind)
            return true
        }
        let kind: DirectManipulation.Kind, name: String
        switch o.box.hitTest(p, radius: hitRadius(canvas: o.canvas)) {
        case .body: kind = .move; name = "プレビューで移動"
        case .corner: kind = .scale; name = "プレビューで拡大"
        case .rotation: kind = .rotate; name = "プレビューで回転"
        case .none: return false
        }
        m.beginGesture()           // 再生を止め、元の状態を覚える
        manipulation = ManipulationDrag(kind: kind, clipId: c.id, start: p, base: c, relTime: min(max(m.currentTime - c.start, 0), c.duration), name: name)
        // スナップ先はドラッグ開始時に一度だけ集めて固定する(移動・拡縮のみ。回転は従来の Shift 15 度刻みだけ)
        if kind == .move || kind == .scale {
            snapTargets = collectSnapTargets(excluding: c.id, canvas: o.canvas)
            snapBaseBox = o.box
        } else {
            snapTargets = nil; snapBaseBox = nil
        }
        snappedVertical = nil; snappedHorizontal = nil; redrawSnapLines()
        return true
    }

    /// スナップ先を集める(ドラッグ開始時に一度だけ): キャンバスの端・中心、表示中のガイド線、
    /// 同じ時刻に見えている他のクリップ(枠で選べる種類で、不透明なもの)の枠。集める計算は Core の PreviewSnap。
    private func collectSnapTargets(excluding clipId: String, canvas: CGSize) -> PreviewSnap.Targets {
        guard let m = model else { return PreviewSnap.targets(canvas: canvas, guides: PreviewGuideStore.current) }
        let renderer = Renderer(project: m.project, assets: m.assets)
        var boxes: [TransformBox] = []
        for id in PreviewPicking.stack(in: m.project, at: m.currentTime) where id != clipId {
            guard let loc = ClipEditing.locate(id, in: m.project) else { continue }
            let c = m.project.tracks[loc.track].clips[loc.index]
            guard PreviewPicking.isPickable(c.type),
                  Animation.value(of: "opacity", in: c, at: m.currentTime - c.start) > 0.001,
                  let size = renderer.objectSize(of: c, at: m.currentTime) else { continue }
            boxes.append(TransformBox.make(clip: c, objectSize: size, at: m.currentTime - c.start, canvas: canvas))
        }
        return PreviewSnap.targets(canvas: canvas, guides: PreviewGuideStore.current, otherBoxes: boxes)
    }

    /// 吸着の閾値をキャンバスの画素に直したもの(画面の 8pt 相当)。
    private func snapThreshold(canvas: CGSize) -> Double {
        let f = frameLayer.frame
        return f.width > 0 ? Double(Self.snapThresholdPoints) * canvas.width / f.width : Double(Self.snapThresholdPoints)
    }

    func dragManipulation(toViewPoint v: CGPoint, snapRotation: Bool = false, snapDisabled: Bool = false) {
        guard let d = manipulation, let o = overlay, let m = model, let base = m.gestureBase,
              let loc = ClipEditing.locate(d.clipId, in: base) else { return }
        var p = canvasPoint(v, canvas: o.canvas)
        let c: Clip
        if let pref = d.pen {
            // ドラッグ開始時のクリップから毎回計算する(アンカーはハンドルごと、ハンドルは単独で動く)
            var cc = d.base
            if var mask = cc.mask, mask.shape == "pen", mask.points.indices.contains(pref.index), o.canvas.width > 0, o.canvas.height > 0 {
                let nx = min(max(p.x / o.canvas.width, 0), 1), ny = min(max(p.y / o.canvas.height, 0), 1)
                var pt = mask.points[pref.index]
                switch pref.part {
                case .anchor:
                    let dx = nx - pt.x, dy = ny - pt.y
                    pt.x = nx; pt.y = ny
                    pt.inX += dx; pt.inY += dy; pt.outX += dx; pt.outY += dy
                case .inHandle: pt.inX = nx; pt.inY = ny
                case .outHandle: pt.outX = nx; pt.outY = ny
                }
                mask.points[pref.index] = pt.normalized
                cc.mask = mask
            }
            c = cc
        } else if let wk = d.warp {
            c = WarpDrag.apply(wk, to: d.base, at: d.relTime, tolerance: m.keyTolerance, canvas: p, box: o.box)
        } else {
            // スナップ: ポインタ位置を補正してから DirectManipulation.apply に渡す(設定 ON のときだけ。⌘ 押下中は一時無効)
            var vLine: Double?, hLine: Double?
            if PreviewSnapStore.current, !snapDisabled, let targets = snapTargets, let baseBox = snapBaseBox {
                let threshold = snapThreshold(canvas: o.canvas)
                switch d.kind {
                case .move:
                    let r = PreviewSnap.snapMove(box: baseBox, delta: CGPoint(x: p.x - d.start.x, y: p.y - d.start.y), targets: targets, threshold: threshold)
                    p = CGPoint(x: d.start.x + r.delta.x, y: d.start.y + r.delta.y)
                    vLine = r.verticalLine; hLine = r.horizontalLine
                case .scale:
                    let r = PreviewSnap.snapPoint(p, targets: targets, threshold: threshold)
                    p = r.point
                    vLine = r.verticalLine; hLine = r.horizontalLine
                case .rotate:
                    break   // 回転は吸着しない(Shift の 15 度刻みだけ)
                }
            }
            snappedVertical = vLine; snappedHorizontal = hLine
            redrawSnapLines()
            c = DirectManipulation.apply(d.kind, to: d.base, at: d.relTime, tolerance: m.keyTolerance, from: d.start, to: p, canvas: o.canvas, snapRotation: snapRotation)
        }
        var pr = base
        pr.tracks[loc.track].clips[loc.index] = c
        m.updateGesture(pr)
    }

    func endManipulation() {
        guard let d = manipulation else { return }
        manipulation = nil
        snapTargets = nil; snapBaseBox = nil
        snappedVertical = nil; snappedHorizontal = nil; redrawSnapLines()   // 吸着の線はドラッグ終了で消す
        model?.commitGesture(d.name)       // 変わっていれば 1 回の Undo
    }

    private func relayout() {
        let avail = bounds.insetBy(dx: 12, dy: 12)
        guard avail.width > 4, avail.height > 4, aspect.width > 0, aspect.height > 0 else { return }
        let k = min(avail.width / aspect.width, avail.height / aspect.height)
        let w = (aspect.width * k).rounded(), h = (aspect.height * k).rounded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        CATransaction.commit()
        redrawOverlay()
        redrawGuides()
    }
}
