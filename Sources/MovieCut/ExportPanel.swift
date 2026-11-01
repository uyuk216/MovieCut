import AppKit
import MovieCutCore

/// 保存パネルで選べる書き出しの種類(現在の設定 / 組み込みのプリセット / 保存したプリセット)。
enum ExportChoice {
    case current
    case builtin(ExportPreset)
    case custom(ExportSpec)

    var preset: ExportPreset? { if case .builtin(let p) = self { return p }; return nil }
    var spec: ExportSpec? {
        switch self {
        case .current: return nil
        case .builtin(let p): return p.spec
        case .custom(let s): return s
        }
    }
    var title: String { spec?.name ?? "現在の設定" }
    var audioOnly: Bool { spec?.audioOnly == true }
}

/// 保存パネルのアクセサリ: 書き出しの種類(ポップアップ)とビットレート(ポップアップ)。
/// 種類を変えると、提案名と保存先の種類(mp4 / m4a)も合わせて変える。
final class ExportPanelOptions: NSObject {
    /// ビットレートの選択肢(nil は「プリセットの既定」)。
    static let bitrateChoices: [Double?] = [nil, 4, 8, 16, 25, 50]

    let choices: [ExportChoice]
    private let documentName: String
    private let kindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let ratePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    weak var panel: NSSavePanel?

    init(documentName: String, initial: ExportChoice, custom: [ExportSpec]) {
        self.documentName = documentName
        var list: [ExportChoice] = [.current] + ExportPreset.allCases.map { .builtin($0) } + custom.map { .custom($0) }
        if initial.preset == nil, initial.spec != nil, !list.contains(where: { $0.spec == initial.spec }) { list.append(initial) }
        choices = list
        super.init()
        for c in list { kindPopup.addItem(withTitle: c.title) }
        if let i = list.firstIndex(where: { $0.spec == initial.spec && ($0.preset == initial.preset) }) { kindPopup.selectItem(at: i) }
        kindPopup.target = self
        kindPopup.action = #selector(kindChanged(_:))
        for r in Self.bitrateChoices {
            ratePopup.addItem(withTitle: r.map { String(format: "%g Mbps", $0) } ?? "プリセットの既定")
        }
        ratePopup.selectItem(at: 0)
    }

    var selectedChoice: ExportChoice { choices[max(0, min(kindPopup.indexOfSelectedItem, choices.count - 1))] }
    var selectedBitrate: Double? {
        let i = ratePopup.indexOfSelectedItem
        return i >= 0 && i < Self.bitrateChoices.count ? Self.bitrateChoices[i] : nil
    }

    /// 種類が変わったら、保存パネルの提案名と保存先の種類を合わせる。
    @objc func kindChanged(_ sender: Any?) {
        let c = selectedChoice
        guard let panel else { return }
        panel.allowedContentTypes = [c.audioOnly ? .mpeg4Audio : .mpeg4Movie]
        panel.nameFieldStringValue = c.spec?.suggestedFileName(documentName: documentName) ?? documentName + ".mp4"
        panel.title = c.spec.map { "書き出し — \($0.name)" } ?? "MP4 書き出し"
    }

    /// 保存パネルのアクセサリ(範囲のチェックがあれば上に置く)。
    func accessoryView(rangeBox: NSButton?) -> NSView {
        let rows: [(String, NSView)] = [("書き出しの種類", kindPopup), ("ビットレート", ratePopup)]
        let h: CGFloat = CGFloat(rows.count + (rangeBox == nil ? 0 : 1)) * 30 + 8
        let wrap = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: h))
        var y = h - 30
        if let box = rangeBox {
            box.frame = NSRect(x: 12, y: y, width: 360, height: 22)
            wrap.addSubview(box)
            y -= 30
        }
        for (label, control) in rows {
            let l = NSTextField(labelWithString: label)
            l.frame = NSRect(x: 12, y: y + 2, width: 96, height: 20)
            control.frame = NSRect(x: 112, y: y, width: 250, height: 24)
            control.setAccessibilityIdentifier(label == "ビットレート" ? "export-bitrate" : "export-kind")
            wrap.addSubview(l)
            wrap.addSubview(control)
            y -= 30
        }
        return wrap
    }
}
