import AppKit

/// NSDockTile のうち使う部分(テストで差し替えられるように切り出した)。
protocol DockTiling: AnyObject {
    var contentView: NSView? { get set }
    var size: NSSize { get }
    func display()
}
extension NSDockTile: DockTiling {}

/// アプリのアイコンの上に重ねる進行バー。
final class DockProgressView: NSView {
    let indicator = NSProgressIndicator()
    private let icon = NSImageView()

    init(size: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: size))
        icon.image = NSApp?.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.frame = bounds
        icon.autoresizingMask = [.width, .height]
        addSubview(icon)
        indicator.style = .bar
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.controlSize = .regular
        let margin = size.width * 0.08
        indicator.frame = NSRect(x: margin, y: size.height * 0.06, width: size.width - margin * 2, height: 14)
        addSubview(indicator)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) は使いません") }
}

/// 書き出し中の Dock の進行バーと、終わったときの知らせ(main.js の setProgressBar / dock.bounce 相当)。
@MainActor
final class DockProgressController {
    /// 0〜1。nil なら進行バーは出ていない。
    private(set) var fraction: Double?
    private let tile: DockTiling?
    private var view: DockProgressView?
    /// アプリが前面か(テストで差し替える)。
    var isAppActive: () -> Bool = { NSApp?.isActive ?? true }
    /// Dock のアイコンを 1 回はねさせる(informational)。
    var requestAttention: () -> Void = { NSApp?.requestUserAttention(.informationalRequest) }

    init(tile: DockTiling?) { self.tile = tile }

    /// 進み具合を 0〜1 に収める(NaN は 0)。
    static func clamp(_ v: Double) -> Double { v.isNaN ? 0 : min(1, max(0, v)) }

    func update(_ v: Double) {
        let f = Self.clamp(v)
        fraction = f
        guard let tile else { return }
        if view == nil {
            let pv = DockProgressView(size: tile.size)
            view = pv
            tile.contentView = pv
        }
        view?.indicator.doubleValue = f
        tile.display()
    }

    /// 進行バーを消してアイコンを元に戻す。
    func reset() {
        fraction = nil
        view = nil
        guard let tile else { return }
        tile.contentView = nil
        tile.display()
    }

    /// 書き出しが終わった。アプリが前面でなければ Dock のアイコンをはねさせる。
    func finish(notify: Bool) {
        reset()
        if notify && !isAppActive() { requestAttention() }
    }
}
