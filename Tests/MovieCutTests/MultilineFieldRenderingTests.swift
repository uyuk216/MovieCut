import XCTest
import SwiftUI
import AppKit
@testable import MovieCut

/// BUG-U01: 台本・セリフ系の入力欄(MultilineField)で文字が重なって見える問題の回帰テスト。
///
/// 実画面では、入力欄の NSTextView だけがフォントスムージング(字幹を太らせる描画+
/// LCD サブピクセル AA)で描かれ、周りの SwiftUI の文字(グレースケール AA)と
/// 見え方が食い違って、漢字の線が潰れて重なって見える。入力欄の文字は
/// スムージングを切った描画(周りと同じ見え方)でなければならない。
///
/// ここでは、部品の中の NSTextView を取り出してビットマップへ描き、
/// 「スムージング有りの描画」と「スムージング無しの描画」の中間より
/// 無し側に寄っている(≒スムージングが効いていない)ことを、墨の被覆率で確かめる。
@MainActor
final class MultilineFieldRenderingTests: XCTestCase {
    private let sentence = "言語の「バージョンが上がる」と、何が壊れるのか。"

    private func findTextView(in root: NSView) -> NSTextView? {
        if let tv = root as? NSTextView { return tv }
        for s in root.subviews { if let tv = findTextView(in: s) { return tv } }
        return nil
    }

    /// ビットマップ(背景 0.12 灰へ合成済みとみなす)の中で、文字の墨が占める割合。
    private func inkCoverage(_ rep: NSBitmapImageRep) -> Double {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0 else { return 0 }
        var ink = 0, total = 0
        for y in 0..<h {
            for x in 0..<w {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                total += 1
                // 透明な画素は背景(0.12)として合成してから明るさを見る
                let a = c.alphaComponent
                let lum = (c.redComponent * a + 0.12 * (1 - a)
                           + c.greenComponent * a + 0.12 * (1 - a)
                           + c.blueComponent * a + 0.12 * (1 - a)) / 3
                if lum > 0.30 { ink += 1 }
            }
        }
        return total == 0 ? 0 : Double(ink) / Double(total)
    }

    /// NSLayoutManager で直接描く(スムージングの有無を選べる基準描画)。
    /// ビットマップの大きさは部品の NSTextView と同じにして、被覆率の分母を揃える。
    private func layoutDrawCoverage(font: NSFont, size: NSSize, textWidth: CGFloat, smoothingOff: Bool) -> Double {
        let W = Int(size.width), H = Int(size.height)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: W, height: H)
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: W, height: H).fill()
        let storage = NSTextStorage(string: sentence)
        storage.addAttributes([.font: font, .foregroundColor: NSColor.white],
                              range: NSRange(location: 0, length: (sentence as NSString).length))
        let lm = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: textWidth, height: CGFloat(H)))
        container.lineFragmentPadding = 5
        storage.addLayoutManager(lm)
        lm.addTextContainer(container)
        lm.ensureLayout(for: container)
        if smoothingOff { ctx.cgContext.setShouldSmoothFonts(false) }
        lm.drawGlyphs(forGlyphRange: lm.glyphRange(for: container), at: NSPoint(x: 5, y: 4))
        NSGraphicsContext.restoreGraphicsState()
        return inkCoverage(rep)
    }

    func testMultilineFieldDrawsWithoutFontSmoothing() throws {
        let view = VStack(alignment: .leading, spacing: 0) {
            MultilineField(label: "読み上げ文", value: sentence, onLive: { _ in }, onCommit: { _ in })
        }
        .padding(12)
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()

        let tv = try XCTUnwrap(findTextView(in: host), "MultilineField の中に NSTextView が無い")
        XCTAssertEqual(tv.string, sentence, "入力欄に値が入っていない")

        // 部品の NSTextView をそのまま描く
        let bounds = tv.bounds
        let rep = try XCTUnwrap(tv.bitmapImageRepForCachingDisplay(in: bounds))
        tv.cacheDisplay(in: bounds, to: rep)
        let fieldCoverage = inkCoverage(rep)
        XCTAssertGreaterThan(fieldCoverage, 0.02, "文字が描かれていない(被覆率が低すぎる)")

        // 基準: 同じフォント・同じ幅で、スムージング有り/無し
        let font = try XCTUnwrap(tv.font)
        let textWidth = (tv.textContainer?.containerSize.width ?? bounds.width)
        let onCoverage = layoutDrawCoverage(font: font, size: bounds.size, textWidth: textWidth, smoothingOff: false)
        let offCoverage = layoutDrawCoverage(font: font, size: bounds.size, textWidth: textWidth, smoothingOff: true)
        XCTAssertGreaterThan(onCoverage, offCoverage, "基準描画でスムージングの差が出ていない(検証の前提が崩れている)")

        // 入力欄の描画は、スムージング有り側ではなく無し側でなければならない
        let mid = (onCoverage + offCoverage) / 2
        XCTAssertLessThan(fieldCoverage, mid,
                          "入力欄の文字がフォントスムージングで描かれている(被覆率 \(fieldCoverage)、有り \(onCoverage) / 無し \(offCoverage))")
    }
}

/// 共通部品 PlainTextEditor(台本・サブクリップ一括・字幕クイック・読み辞書の取り込み欄)の回帰。
@MainActor
final class PlainTextEditorRenderingTests: XCTestCase {
    func testPlainTextEditorUsesPlainRenderingTextViewWithGivenFont() throws {
        for font in [NSFont.systemFont(ofSize: 13), NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)] {
            var text = "台本\nabc"
            let binding = Binding(get: { text }, set: { text = $0 })
            let host = NSHostingView(rootView: PlainTextEditor(text: binding, font: font).frame(width: 300, height: 100))
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            func find(_ v: NSView) -> PlainRenderingTextView? {
                if let t = v as? PlainRenderingTextView { return t }
                for s in v.subviews { if let t = find(s) { return t } }
                return nil
            }
            let tv = try XCTUnwrap(find(host))
            XCTAssertEqual(tv.string, "台本\nabc")
            // 先頭が日本語だと tv.font は代替フォントになるため、英数字の位置の属性で見る
            let used = tv.textStorage?.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
            XCTAssertEqual(used?.fontName, font.fontName)
            XCTAssertEqual(used?.pointSize, font.pointSize)
            XCTAssertTrue(tv.allowsUndo)
            XCTAssertFalse(tv.drawsBackground)
        }
    }

    /// Sources に素の TextEditor(複数行入力欄)が残っていないこと(スムージング描画へ統一済み)。
    func testNoPlainTextEditorLeftInSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources")
        let en = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
        var hits: [String] = []
        for case let url as URL in en where url.pathExtension == "swift" {
            let src = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") || t.hasPrefix("///") { continue }
                if t.contains("TextEditor(") && !t.contains("PlainTextEditor(") { hits.append("\(url.lastPathComponent):\(i + 1)") }
            }
        }
        XCTAssertEqual(hits, [], "TextEditor が残っている")
    }

    /// Sources に素の NSTextView の生成が残っていないこと(PlainRenderingTextView 経由へ統一済み)。
    func testNoPlainNSTextViewCreationLeftInSources() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources")
        let en = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
        var hits: [String] = []
        for case let url as URL in en where url.pathExtension == "swift" {
            if url.lastPathComponent == "PlainTextEditor.swift" { continue }
            let src = try String(contentsOf: url, encoding: .utf8)
            for (i, line) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") { continue }
                if t.contains("NSTextView(") || t.contains("NSTextView.init") { hits.append("\(url.lastPathComponent):\(i + 1)") }
            }
        }
        XCTAssertEqual(hits, [], "素の NSTextView の生成が残っている")
    }
}
