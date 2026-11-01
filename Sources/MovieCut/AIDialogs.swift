import AppKit
import MovieCutCore

/// AI 連携の画面部品(NSAlert ベース)。送信前の確認・結果の確認・設定。薄く保つ(判断は ProjectModel+AI と Core)。
@MainActor
enum AIDialogs {
    /// 結果の確認で押されたボタンと、(編集可なら)直した文字。
    struct Review { var button: Int; var text: String }

    private static func textView(_ text: String, editable: Bool, height: CGFloat = 260) -> NSScrollView {
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: height))
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        let tv = NSTextView(frame: sv.bounds)
        tv.isEditable = editable
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 12)
        tv.string = text
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        sv.documentView = tv
        return sv
    }

    /// 送る前の確認。送り先と、送る文そのものを見せる。「送信」を押したときだけ true。
    static func confirmSend(destination: String, prompt: String) -> Bool {
        let a = NSAlert()
        a.messageText = "AI に次の内容を送ります"
        a.informativeText = "送信先: \(destination)\nこのウインドウで見えている内容だけが送られます。自動では送りません。"
        a.accessoryView = textView(prompt, editable: false)
        a.addButton(withTitle: "送信")
        a.addButton(withTitle: "キャンセル")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// 結果の確認。`buttons` の先頭が主ボタン、最後がキャンセル。
    static func review(title: String, message: String, text: String, editable: Bool, buttons: [String]) -> Review? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        let tv = textView(text, editable: editable)
        a.accessoryView = tv
        buttons.forEach { a.addButton(withTitle: $0) }
        let r = a.runModal()
        let idx = r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard idx >= 0, idx < buttons.count - 1 else { return nil }
        return Review(button: idx, text: (tv.documentView as? NSTextView)?.string ?? text)
    }

    /// 1 行ずつの入力欄(ラベル, 初期値)。OK のとき値を返す。
    static func form(title: String, message: String, fields: [(String, String)], okTitle: String) -> [String]? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        let rowH: CGFloat = 28
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: rowH * CGFloat(fields.count)))
        var inputs: [NSTextField] = []
        for (i, f) in fields.enumerated() {
            let y = box.frame.height - rowH * CGFloat(i + 1)
            let label = NSTextField(labelWithString: f.0)
            label.frame = NSRect(x: 0, y: y + 4, width: 110, height: 20)
            let field = NSTextField(string: f.1)
            field.frame = NSRect(x: 115, y: y + 2, width: 305, height: 24)
            box.addSubview(label); box.addSubview(field)
            inputs.append(field)
        }
        a.accessoryView = box
        a.addButton(withTitle: okTitle)
        a.addButton(withTitle: "キャンセル")
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return inputs.map(\.stringValue)
    }

    /// 言い換えの種類を選ぶ。
    /// 翻訳先の言語を選ぶ(字幕の数を見せる)。キャンセルなら nil。
    static func chooseTranslateLanguage(count: Int) -> AITranslatePrompt.Language? {
        let a = NSAlert()
        a.messageText = "字幕を翻訳して書き出す"
        a.informativeText = "字幕 \(count) 件を AI で訳し、SRT にします(時刻はそのまま)。次の画面で、送る内容を確認できます。"
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        pop.addItems(withTitles: AITranslatePrompt.Language.allCases.map(\.label))
        a.accessoryView = pop
        a.addButton(withTitle: "次へ")
        a.addButton(withTitle: "キャンセル")
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return AITranslatePrompt.Language.allCases[max(0, pop.indexOfSelectedItem)]
    }

    static func chooseRewriteMode(original: String) -> AIRewritePrompt.Mode? {
        let a = NSAlert()
        a.messageText = "セリフを AI で直す"
        a.informativeText = "元のセリフ: \(original)\n\nどう直しますか。(次の画面で、送る内容を確認できます)"
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        pop.addItems(withTitles: AIRewritePrompt.Mode.allCases.map(\.title))
        a.accessoryView = pop
        a.addButton(withTitle: "次へ")
        a.addButton(withTitle: "キャンセル")
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return AIRewritePrompt.Mode.allCases[max(0, pop.indexOfSelectedItem)]
    }

    /// ファイル ▸ AI の設定…。鍵は保存しない(コマンドか、このマシンのサーバーだけ)。
    static func editSettings() {
        var s = AISettings.load()
        let a = NSAlert()
        a.messageText = "AI の設定"
        a.informativeText = "クラウドの鍵はこのアプリに保存しません。ご自分のコマンド(例: claude -p)か、このマシン上のサーバー(Ollama など)を指定します。AI は、メニューから操作したときだけ呼ばれます。"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 150))
        func row(_ label: String, _ y: CGFloat, _ view: NSView) {
            let l = NSTextField(labelWithString: label); l.frame = NSRect(x: 0, y: y + 4, width: 120, height: 20)
            view.frame = NSRect(x: 125, y: y, width: 335, height: 26)
            box.addSubview(l); box.addSubview(view)
        }
        let kind = NSPopUpButton(frame: .zero, pullsDown: false)
        kind.addItems(withTitles: AIProviderKind.allCases.map(\.title))
        kind.selectItem(at: AIProviderKind.allCases.firstIndex(of: s.kind) ?? 0)
        let cmd = NSTextField(string: s.command); cmd.placeholderString = "claude -p"
        let url = NSTextField(string: s.url)
        let model = NSTextField(string: s.model); model.placeholderString = "例: gemma3"
        let timeout = NSTextField(string: String(s.timeoutSeconds))
        row("使い方", 120, kind); row("コマンド", 90, cmd); row("サーバー URL", 60, url); row("モデル名", 30, model); row("待つ秒数", 0, timeout)
        a.accessoryView = box
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "キャンセル")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        s.kind = AIProviderKind.allCases[max(0, kind.indexOfSelectedItem)]
        s.command = cmd.stringValue.trimmingCharacters(in: .whitespaces)
        s.url = url.stringValue.trimmingCharacters(in: .whitespaces)
        s.model = model.stringValue.trimmingCharacters(in: .whitespaces)
        s.timeoutSeconds = min(max(Int(timeout.stringValue) ?? 120, AISettings.timeoutRange.lowerBound), AISettings.timeoutRange.upperBound)
        s.save()
    }
}
