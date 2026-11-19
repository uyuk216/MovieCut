import AppKit
import MovieCutCore

/// AIテキスト生成(W3-08)の設定画面。接続情報はユーザー自身がここで入れる。
/// APIキーはこの Mac のアプリ設定(UserDefaults)にだけ保存し、プロジェクトファイルには
/// 書かない。コード側にキーは一切持たない。未設定のあいだは機能が無効になる。
@MainActor
enum TextGenerationDialogs {
    static func editSettings() {
        var s = TextGenerationSettings.load()
        let a = NSAlert()
        a.messageText = "AIテキスト生成の設定"
        a.informativeText = "セリフ案の生成に使う、外部の生成サービスへの接続情報です。OpenAI 互換の chat completions 形式に対応します。APIキーはこの Mac のアプリ設定にだけ保存され、プロジェクトには入りません。未設定のあいだは、セリフ案の生成は使えません。http で送れるのはこの Mac 自身(localhost)宛てだけです。"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 120))
        func row(_ label: String, _ y: CGFloat, _ view: NSView) {
            let l = NSTextField(labelWithString: label)
            l.frame = NSRect(x: 0, y: y + 4, width: 110, height: 20)
            view.frame = NSRect(x: 115, y: y, width: 385, height: 26)
            box.addSubview(l); box.addSubview(view)
        }
        let endpoint = NSTextField(string: s.endpoint)
        endpoint.placeholderString = "https://…/v1/chat/completions"
        let model = NSTextField(string: s.model)
        model.placeholderString = "モデル名"
        let key = NSSecureTextField(string: s.apiKey)
        key.placeholderString = "APIキー(ローカルなサービスでは空で可)"
        let timeout = NSTextField(string: String(s.timeoutSeconds))
        row("エンドポイント", 90, endpoint)
        row("モデル", 60, model)
        row("APIキー", 30, key)
        row("待つ秒数", 0, timeout)
        a.accessoryView = box
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "キャンセル")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        s.endpoint = endpoint.stringValue.trimmingCharacters(in: .whitespaces)
        s.model = model.stringValue.trimmingCharacters(in: .whitespaces)
        s.apiKey = key.stringValue
        s.timeoutSeconds = min(max(Int(timeout.stringValue) ?? 120, TextGenerationSettings.timeoutRange.lowerBound), TextGenerationSettings.timeoutRange.upperBound)
        s.save()
    }
}
