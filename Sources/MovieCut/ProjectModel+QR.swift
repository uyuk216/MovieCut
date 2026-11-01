import AppKit
import MovieCutCore

/// クリップ ▸ QRコードを追加…: 文字(URL など)を入れて QR の画像を作り、画像クリップとして再生ヘッドに置く。
/// 画像は Application Support の QRCodes フォルダに、文字から決まる名前で保存する(同じ文字なら作り直さない)。
extension ProjectModel {
    func openAddQRCode() {
        guard !isLocked, let text = QRCodeDialog.askText() else { return }
        addQRCode(text: text)
    }

    /// 画像を作って、画像クリップ(既定 5 秒)として置く。Undo は 1 回。置いたクリップの id を返す。
    @discardableResult
    func addQRCode(text: String, at time: Double? = nil) -> String? {
        guard !isLocked else { return nil }
        guard let url = QRCodeStore.imageURL(for: text) else { statusText = "QRコードを作れませんでした"; return nil }
        let t = max(0, time ?? currentTime)
        var ids: [String] = []
        edit("QRコードの追加") { p in ids = ClipEditing.place(media: [(url.path, .image, 5)], at: t, in: &p) }
        selectedClipId = ids.last
        statusText = "QRコードを追加しました"
        return ids.last
    }
}

/// QR コードの画像の置き場所(Application Support/MovieCut/QRCodes/<文字の FNV-1a ハッシュ>.png)。
enum QRCodeStore {
    static func imageURL(for text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        let dir = support.appendingPathComponent("MovieCut/QRCodes", isDirectory: true)
        let url = dir.appendingPathComponent(String(format: "%016llx.png", fnv1a(t)))
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let data = QRCode.pngData(text: t) else { return nil }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch { return nil }
    }

    /// 文字から決まる 64 ビットのハッシュ(起動をまたいでも同じ値)。
    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }
}

/// 文字を聞くダイアログ(入力欄 1 つ)。
enum QRCodeDialog {
    @MainActor
    static func askText() -> String? {
        let a = NSAlert()
        a.messageText = "QRコードを追加"
        a.informativeText = "QR コードにする文字(URL など)を入れてください。(\(QRCode.maxTextLength) 文字まで)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://"
        a.accessoryView = field
        a.addButton(withTitle: "追加")
        a.addButton(withTitle: "キャンセル")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
