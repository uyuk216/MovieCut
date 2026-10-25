import SwiftUI
import AppKit
import YukkuriCore

/// プレビュー本体。時刻 t のフレームを背景スレッドで描き、灰色の市松の上に本当の縦横比で置く。
struct PreviewView: NSViewRepresentable {
    let project: Project
    let time: Double
    let assets: RenderAssets
    let model: ProjectModel
    /// 別画面(全画面・黒背景・余白なし)用。
    var fullscreen = false
    /// 同じ時刻・同じ内容でも描き直したいときに増やす(再生を止めたとき、正確なフレームに戻す)。
    var epoch = 0

    func makeCoordinator() -> PreviewCoordinator { PreviewCoordinator(model: model, isPrimary: !fullscreen) }

    func makeNSView(context: Context) -> PreviewCanvasView {
        let v = PreviewCanvasView(fullscreen: fullscreen)
        context.coordinator.view = v
        v.setPlaceholder(project: project)
        context.coordinator.request(project: project, time: time, assets: assets, epoch: epoch)
        return v
    }

    func updateNSView(_ nsView: PreviewCanvasView, context: Context) {
        context.coordinator.request(project: project, time: time, assets: assets, epoch: epoch)
    }
}

/// 描画要求をまとめる(古い要求は捨てて、最新だけ描く)。
final class PreviewCoordinator {
    weak var view: PreviewCanvasView?
    let model: ProjectModel
    /// 検証用の数え上げ(落としたフレームなど)は主画面のぶんだけ。
    let isPrimary: Bool
    private let queue = DispatchQueue(label: "yukkuri.preview.render", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: (project: Project, time: Double, assets: RenderAssets, seq: Int)?
    private var running = false
    // 主スレッドだけで触る
    private var lastProject: Project?
    private var lastTime: Double?
    private var lastEpoch = -1
    private var seq = 0

    init(model: ProjectModel, isPrimary: Bool = true) { self.model = model; self.isPrimary = isPrimary }

    func request(project: Project, time: Double, assets: RenderAssets, epoch: Int = 0) {
        if lastEpoch == epoch && lastTime == time && lastProject == project { return }
        lastProject = project; lastTime = time; lastEpoch = epoch
        seq += 1
        let mySeq = seq
        MainActor.assumeIsolated { model.previewRequested() }
        view?.setPlaceholder(project: project)
        lock.lock()
        // まだ描かれていない古い要求を上書きした = そのフレームは描かれずに落ちた
        if pending != nil, isPrimary { MainActor.assumeIsolated { model.previewDropped += 1 } }
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
            let img = Renderer(project: job.project, assets: job.assets).renderImage(t: job.time)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let img { self.view?.show(image: img) }
                MainActor.assumeIsolated { self.model.previewDisplayed(idle: job.seq == self.seq) }
            }
        }
    }
}

/// レイヤーで描く NSView。背景は市松、中央にフレーム(1pt の枠 + 影)。
final class PreviewCanvasView: NSView {
    private let frameLayer = CALayer()
    private var aspect = CGSize(width: 16, height: 9)
    private var hasImage = false

    private let fullscreen: Bool

    init(fullscreen: Bool = false) {
        self.fullscreen = fullscreen
        super.init(frame: .zero)
        wantsLayer = true
        let root = CALayer()
        root.cornerRadius = fullscreen ? 0 : 8
        root.masksToBounds = true
        root.backgroundColor = fullscreen ? NSColor.black.cgColor : Self.checkerColor()
        layer = root
        frameLayer.contentsGravity = .resize
        frameLayer.magnificationFilter = .linear
        frameLayer.minificationFilter = .trilinear
        frameLayer.borderWidth = fullscreen ? 0 : 1
        frameLayer.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
        frameLayer.shadowColor = NSColor.black.cgColor
        frameLayer.shadowOpacity = fullscreen ? 0 : 0.45
        frameLayer.shadowRadius = 8
        frameLayer.shadowOffset = CGSize(width: 0, height: -2)
        frameLayer.masksToBounds = false
        root.addSublayer(frameLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// 市松模様(16pt のマスを 2 色の灰色で)。
    private static func checkerColor() -> CGColor {
        let s = 16
        let img = NSImage(size: NSSize(width: s * 2, height: s * 2), flipped: false) { _ in
            NSColor(white: 0.17, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: s * 2, height: s * 2).fill()
            NSColor(white: 0.21, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: s, height: s).fill()
            NSRect(x: s, y: s, width: s, height: s).fill()
            return true
        }
        return NSColor(patternImage: img).cgColor
    }

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

    private func relayout() {
        let avail = fullscreen ? bounds : bounds.insetBy(dx: 12, dy: 12)
        guard avail.width > 4, avail.height > 4, aspect.width > 0, aspect.height > 0 else { return }
        let k = min(avail.width / aspect.width, avail.height / aspect.height)
        let w = (aspect.width * k).rounded(), h = (aspect.height * k).rounded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        CATransaction.commit()
    }
}
