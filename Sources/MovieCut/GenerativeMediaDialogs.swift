import AppKit
import MovieCutCore

/// 生成メディア(API)の設定画面。接続情報はユーザー自身がここで入れる。
/// APIキーはこの Mac のアプリ設定(UserDefaults)にだけ保存し、プロジェクト
/// ファイルには書かない。コード側にキーは一切持たない。未設定のあいだは
/// 画像生成(API)は無効になる。作法は `TextGenerationDialogs` と同じ。
@MainActor
enum GenerativeMediaDialogs {
    static func editImageGenerationSettings() {
        var s = ImageGenerationSettings.load()
        let a = NSAlert()
        a.messageText = "生成メディア(API)の設定"
        a.informativeText = "画像生成に使う、外部の生成サービスへの接続情報です。OpenAI 互換の画像生成エンドポイント(images generations 形式)に対応し、エンドポイントは自由に指定できます。生成はあなたの API アカウントで実行され、費用もあなたのアカウントに課金されます。APIキーはこの Mac のアプリ設定にだけ保存され、プロジェクトには入りません。MovieCut のサーバは経由しません。未設定のあいだは、画像生成(API)は使えません。http で送れるのはこの Mac 自身(localhost)宛てだけです。"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 150))
        func row(_ label: String, _ y: CGFloat, _ view: NSView) {
            let l = NSTextField(labelWithString: label)
            l.frame = NSRect(x: 0, y: y + 4, width: 110, height: 20)
            view.frame = NSRect(x: 115, y: y, width: 385, height: 26)
            box.addSubview(l); box.addSubview(view)
        }
        let endpoint = NSTextField(string: s.endpoint)
        endpoint.placeholderString = "https://…/v1/images/generations"
        let model = NSTextField(string: s.model)
        model.placeholderString = "モデル名"
        let key = NSSecureTextField(string: s.apiKey)
        key.placeholderString = "APIキー(ローカルなサービスでは空で可)"
        let size = NSPopUpButton(frame: .zero, pullsDown: false)
        size.addItems(withTitles: ImageGenerationSize.allCases.map(\.title))
        size.selectItem(at: ImageGenerationSize.allCases.firstIndex { $0.rawValue == s.size } ?? 0)
        let timeout = NSTextField(string: String(s.timeoutSeconds))
        row("エンドポイント", 120, endpoint)
        row("モデル", 90, model)
        row("APIキー", 60, key)
        row("大きさ", 30, size)
        row("待つ秒数", 0, timeout)
        a.accessoryView = box
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "キャンセル")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        s.endpoint = endpoint.stringValue.trimmingCharacters(in: .whitespaces)
        s.model = model.stringValue.trimmingCharacters(in: .whitespaces)
        s.apiKey = key.stringValue
        s.size = ImageGenerationSize.allCases[max(0, size.indexOfSelectedItem)].rawValue
        s.timeoutSeconds = min(max(Int(timeout.stringValue) ?? 120, ImageGenerationSettings.timeoutRange.lowerBound), ImageGenerationSettings.timeoutRange.upperBound)
        s.save()
    }
}
