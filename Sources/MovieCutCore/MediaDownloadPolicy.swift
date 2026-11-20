import Foundation

/// 生成サービスが返した URL からメディアを取るときの安全な決まり。
/// - 取れる URL は https、または http のループバック(127.0.0.1 / localhost / ::1)だけ。file: / data: などは断る。
/// - 認証(Authorization)を付けてよいのは、設定したエンドポイントと scheme・host・port が完全に一致するときだけ。
/// - 大きさの上限(Content-Length と実際のバイト数の両方)。
public enum MediaDownloadPolicy {
    public static let maxBytes = 512 * 1024 * 1024
    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    public static func isLoopback(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return loopbackHosts.contains(h)
    }

    /// 取りに行ってよい URL か。
    public static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else { return false }
        switch scheme {
        case "https": return true
        case "http": return isLoopback(host)
        default: return false
        }
    }

    private static func normalizedPort(_ url: URL) -> Int? {
        if let p = url.port { return p }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    /// scheme・host・port が完全に一致するか(host は大文字小文字を区別しない)。
    public static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let sa = a.scheme?.lowercased(), let sb = b.scheme?.lowercased(), sa == sb,
              let ha = a.host?.lowercased(), let hb = b.host?.lowercased(), ha == hb else { return false }
        return normalizedPort(a) == normalizedPort(b)
    }

    /// ダウンロード用のリクエストを作る。許されない URL は throw。キーは同じ送り先のときだけ付ける。
    public static func downloadRequest(url: URL, endpoint: URL, apiKey: String, timeout: TimeInterval) throws -> URLRequest {
        guard isAllowedDownloadURL(url) else {
            throw GenerativeMediaError.downloadRejected("取得先の URL(\(url.scheme ?? "不明")形式)は安全のため使えません。https の URL だけ取得できます")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        if !apiKey.isEmpty, sameOrigin(url, endpoint) {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    public static func checkSize(_ data: Data) throws {
        if data.count > maxBytes { throw GenerativeMediaError.downloadTooLarge(limit: maxBytes) }
    }
}
