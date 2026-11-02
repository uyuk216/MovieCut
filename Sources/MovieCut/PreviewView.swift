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

    /// 選択クリップの枠(直接操作の取っ手)。画像・動画・文字を選んでいて、再生ヘッドがその中にあり、止まっているときだけ。
    @MainActor
    static func overlayTarget(model: ProjectModel, project: Project, time: Double, assets: RenderAssets) -> PreviewOverlayTarget? {
        guard !model.isPlaying, !model.isLocked, let c = model.selectedClip,
              [ClipType.image, .video, .text].contains(c.type), time >= c.start, time < c.start + c.duration,
              let size = Renderer(project: project, assets: assets).objectSize(of: c, at: time) else { return nil }
        let canvas = CGSize(width: project.width, height: project.height)
        return PreviewOverlayTarget(clipId: c.id, box: TransformBox.make(clip: c, objectSize: size, at: time - c.start, canvas: canvas), canvas: canvas)
    }
}

/// プレビュー上の選択枠: どのクリップの、画面(キャンバスの画素)のどこにあるか。
struct PreviewOverlayTarget: Equatable {
    var clipId: String
    var box: TransformBox
    var canvas: CGSize
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
            }).renderImage(t: job.time)
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
    private(set) var overlay: PreviewOverlayTarget?
    struct ManipulationDrag {
        var kind: DirectManipulation.Kind
        var clipId: String
        var start: CGPoint          // キャンバスの画素
        var base: Clip
        var relTime: Double
        var name: String
    }
    private(set) var manipulation: ManipulationDrag?
    /// ガイド線(表示 ▸ ガイド線)。プレビューの上に重ねるだけで、書き出しには入らない。
    private let guideLayer = CAShapeLayer()
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
        root.addSublayer(guideLayer)
        root.addSublayer(outlineLayer)
        root.addSublayer(handleLayer)
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
    private func redrawGuides() {
        let guides = PreviewGuideStore.current
        let canvas = aspect
        let path = CGMutablePath()
        guard !guides.isEmpty, frameLayer.frame.width > 0 else {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            guideLayer.isHidden = true
            CATransaction.commit()
            return
        }
        for r in GuideGeometry.safeRects(guides, canvas: canvas) {
            let a = viewPoint(CGPoint(x: r.minX, y: r.minY), canvas: canvas), b = viewPoint(CGPoint(x: r.maxX, y: r.maxY), canvas: canvas)
            path.addRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        }
        for l in GuideGeometry.lines(guides, canvas: canvas) {
            path.move(to: viewPoint(l.from, canvas: canvas))
            path.addLine(to: viewPoint(l.to, canvas: canvas))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        guideLayer.path = path
        guideLayer.isHidden = false
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
            return
        }
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
        beginManipulation(atViewPoint: convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) { dragManipulation(toViewPoint: convert(event.locationInWindow, from: nil), snapRotation: event.modifierFlags.contains(.shift)) }
    override func mouseUp(with event: NSEvent) { endManipulation() }

    /// 押した: 枠の本体・角・回転の取っ手に当たれば、ドラッグを始める(元のクリップを覚える)。当たらなければ false。
    @discardableResult
    func beginManipulation(atViewPoint v: CGPoint) -> Bool {
        guard let o = overlay, let m = model, !m.isLocked, let c = m.clip(o.clipId) else { return false }
        let p = canvasPoint(v, canvas: o.canvas)
        let kind: DirectManipulation.Kind, name: String
        switch o.box.hitTest(p, radius: hitRadius(canvas: o.canvas)) {
        case .body: kind = .move; name = "プレビューで移動"
        case .corner: kind = .scale; name = "プレビューで拡大"
        case .rotation: kind = .rotate; name = "プレビューで回転"
        case .none: return false
        }
        m.beginGesture()           // 再生を止め、元の状態を覚える
        manipulation = ManipulationDrag(kind: kind, clipId: c.id, start: p, base: c, relTime: min(max(m.currentTime - c.start, 0), c.duration), name: name)
        return true
    }

    func dragManipulation(toViewPoint v: CGPoint, snapRotation: Bool = false) {
        guard let d = manipulation, let o = overlay, let m = model, let base = m.gestureBase,
              let loc = ClipEditing.locate(d.clipId, in: base) else { return }
        let p = canvasPoint(v, canvas: o.canvas)
        let c = DirectManipulation.apply(d.kind, to: d.base, at: d.relTime, tolerance: m.keyTolerance, from: d.start, to: p, canvas: o.canvas, snapRotation: snapRotation)
        var pr = base
        pr.tracks[loc.track].clips[loc.index] = c
        m.updateGesture(pr)
    }

    func endManipulation() {
        guard let d = manipulation else { return }
        manipulation = nil
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
