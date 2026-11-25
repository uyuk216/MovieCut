import SwiftUI
import AppKit

/// フォントスムージングを切って描く NSTextView(BUG-U01 対策)。
/// 標準のまま描くと、実画面では字幹を太らせるスムージングと LCD 向けの
/// サブピクセル描画が効き、漢字の線が潰れて重なって見える。周りの SwiftUI の
/// 文字はグレースケール描画で食い違うため、こちらも描画時にスムージングを
/// 切って見え方を揃える。
final class PlainRenderingTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setShouldSmoothFonts(false)
        super.draw(dirtyRect)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }
}

/// TextEditor の代わりに使う複数行エディタ(PlainRenderingTextView 経由)。
/// 背景は透明(scrollContentBackground(.hidden) 相当)。Undo 有効、変換中は外部からの差し替えをしない。
/// 枠・背景・frame は呼び出し側が .padding / .background / .frame で付ける。
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont = NSFont.systemFont(ofSize: MCDesign.FontSize.body)
    /// 増えたらこの欄にフォーカスを移す。
    var focusRequest = 0
    var onFocusChange: ((Bool) -> Void)? = nil

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor?
        var lastFocusRequest = 0

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView, let parent else { return }
            if parent.text != tv.string { parent.text = tv.string }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let tv = PlainRenderingTextView()
        tv.delegate = context.coordinator
        tv.onFocusChange = onFocusChange
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.font = font
        tv.textColor = .labelColor
        tv.textContainerInset = NSSize(width: 0, height: 0)
        tv.textContainer?.lineFragmentPadding = 5
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        scrollView.documentView = tv
        context.coordinator.parent = self
        if tv.string != text { tv.string = text }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scrollView.documentView as? PlainRenderingTextView else { return }
        tv.onFocusChange = onFocusChange
        if tv.font != font { tv.font = font }
        // 入力中(変換中)の文字を壊さないよう、変換中は外部からの差し替えをしない
        if tv.string != text, !tv.hasMarkedText() { tv.string = text }
        if focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            if let window = scrollView.window, window.firstResponder !== tv {
                window.makeFirstResponder(tv)
            }
        }
    }
}
