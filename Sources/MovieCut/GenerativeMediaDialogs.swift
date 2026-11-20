import AppKit
import MovieCutCore

/// 生成メディア(API)の設定画面。接続情報はユーザー自身がここで入れる。
/// APIキーはこの Mac のアプリ設定(UserDefaults)にだけ保存し、プロジェクト
/// ファイルには書かない。コード側にキーは一切持たない。未設定のあいだは
/// 各生成(API)は無効になる。作法は `TextGenerationDialogs` と同じ。
/// 画像(W3-2 の既存セクション)に、動画と音声/音楽(W5-4)のセクションを
/// 同じシートへ足したもので、設定シートを別に作り直してはいない。
@MainActor
enum GenerativeMediaDialogs {
    static func editImageGenerationSettings() {
        var s = ImageGenerationSettings.load()
        var vs = VideoGenerationSettings.load()
        var aus = AudioGenerationSettings.load()
        let a = NSAlert()
        a.messageText = L10n.t("生成メディア(API)の設定")
        a.informativeText = L10n.t("画像・動画・音声/音楽の生成に使う、外部の生成サービスへの接続情報です。画像は OpenAI 互換の画像生成エンドポイント(images generations 形式)、動画と音声/音楽は OpenAI 互換スタイルの汎用エンドポイントに対応し、エンドポイントは種類ごとに自由に指定できます。生成はあなたの API アカウントで実行され、費用もあなたのアカウントに課金されます。APIキーはこの Mac のアプリ設定にだけ保存され、プロジェクトには入りません。MovieCut のサーバは経由しません。未設定のあいだは、その種類の生成(API)は使えません。http で送れるのはこの Mac 自身(localhost)宛てだけです。")
        // 13 行: 画像 5 + 動画 5 + 音声 3。
        let rowH: CGFloat = 28
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: rowH * 13))
        var rowIndex = 0
        func row(_ label: String, _ view: NSView) {
            let y = box.frame.height - rowH * CGFloat(rowIndex + 1)
            let l = NSTextField(labelWithString: L10n.t(label))
            l.frame = NSRect(x: 0, y: y + 4, width: 130, height: 20)
            view.frame = NSRect(x: 135, y: y, width: 365, height: 26)
            box.addSubview(l); box.addSubview(view)
            rowIndex += 1
        }
        // 画像(既存)
        let endpoint = NSTextField(string: s.endpoint)
        endpoint.placeholderString = "https://…/v1/images/generations"
        let model = NSTextField(string: s.model)
        model.placeholderString = L10n.t("モデル名")
        let key = NSSecureTextField(string: s.apiKey)
        key.placeholderString = L10n.t("APIキー(ローカルなサービスでは空で可)")
        let size = NSPopUpButton(frame: .zero, pullsDown: false)
        size.addItems(withTitles: ImageGenerationSize.allCases.map { L10n.t($0.title) })
        size.selectItem(at: ImageGenerationSize.allCases.firstIndex { $0.rawValue == s.size } ?? 0)
        let timeout = NSTextField(string: String(s.timeoutSeconds))
        row("画像エンドポイント", endpoint)
        row("画像モデル", model)
        row("画像APIキー", key)
        row("画像の大きさ", size)
        row("画像 待つ秒数", timeout)
        // 動画(W5-4)
        let vEndpoint = NSTextField(string: vs.endpoint)
        vEndpoint.placeholderString = "https://…/v1/videos"
        let vModel = NSTextField(string: vs.model)
        vModel.placeholderString = L10n.t("モデル名")
        let vKey = NSSecureTextField(string: vs.apiKey)
        vKey.placeholderString = L10n.t("APIキー(ローカルなサービスでは空で可)")
        let vSize = NSPopUpButton(frame: .zero, pullsDown: false)
        vSize.addItems(withTitles: VideoGenerationSize.allCases.map { L10n.t($0.title) })
        vSize.selectItem(at: VideoGenerationSize.allCases.firstIndex { $0.rawValue == vs.size } ?? 0)
        let vFormat = NSTextField(string: vs.outputFormat)
        vFormat.placeholderString = "mp4"
        row("動画エンドポイント", vEndpoint)
        row("動画モデル", vModel)
        row("動画APIキー", vKey)
        row("動画の大きさ", vSize)
        row("動画の形式", vFormat)
        // 音声 / 音楽(W5-4。効果音・音楽・サウンドスケープ共通)
        let aEndpoint = NSTextField(string: aus.endpoint)
        aEndpoint.placeholderString = "https://…/v1/audio/generations"
        let aModel = NSTextField(string: aus.model)
        aModel.placeholderString = L10n.t("モデル名")
        let aKey = NSSecureTextField(string: aus.apiKey)
        aKey.placeholderString = L10n.t("APIキー(ローカルなサービスでは空で可)")
        row("音声エンドポイント", aEndpoint)
        row("音声モデル", aModel)
        row("音声APIキー", aKey)
        a.accessoryView = box
        a.addButton(withTitle: L10n.t("保存"))
        a.addButton(withTitle: L10n.t("キャンセル"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        s.endpoint = endpoint.stringValue.trimmingCharacters(in: .whitespaces)
        s.model = model.stringValue.trimmingCharacters(in: .whitespaces)
        s.apiKey = key.stringValue
        s.size = ImageGenerationSize.allCases[max(0, size.indexOfSelectedItem)].rawValue
        s.timeoutSeconds = min(max(Int(timeout.stringValue) ?? 120, ImageGenerationSettings.timeoutRange.lowerBound), ImageGenerationSettings.timeoutRange.upperBound)
        s.save()
        vs.endpoint = vEndpoint.stringValue.trimmingCharacters(in: .whitespaces)
        vs.model = vModel.stringValue.trimmingCharacters(in: .whitespaces)
        vs.apiKey = vKey.stringValue
        vs.size = VideoGenerationSize.allCases[max(0, vSize.indexOfSelectedItem)].rawValue
        let vf = vFormat.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        vs.outputFormat = vf.isEmpty ? "mp4" : vf
        vs.save()
        aus.endpoint = aEndpoint.stringValue.trimmingCharacters(in: .whitespaces)
        aus.model = aModel.stringValue.trimmingCharacters(in: .whitespaces)
        aus.apiKey = aKey.stringValue
        aus.save()
    }
}
