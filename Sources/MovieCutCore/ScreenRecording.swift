import Foundation
import CoreGraphics

// MARK: - 画面収録の設定(フェーズ D-2 / X-3)
//
// 画面収録の「何を・どう撮るか」と状態遷移の純粋な部分。実物のキャプチャ(ScreenCaptureKit)は
// アプリ側の `ScreenCaptureKitEngine` が担い、ここは権限に依存しない検証・状態・名前付けだけを持つ。
// 収録を使わない限り、既存の読み込み・編集・書き出しの挙動は一切変わらない(追加のみ)。

/// 収録対象の種類。
public enum ScreenCaptureSourceKind: String, Equatable, Sendable, CaseIterable {
    case display   // 画面全体
    case window    // ウィンドウ 1 つ
    case region    // 画面の一部の矩形

    public var title: String {
        switch self {
        case .display: return "画面全体"
        case .window: return "ウィンドウ"
        case .region: return "範囲(矩形)"
        }
    }
}

/// 矩形の範囲(ディスプレイの左上を原点とするポイント単位)。
public struct ScreenRecordingRegion: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// これより小さい範囲は収録しない(幅・高さの下限)。
    public static let minSide: Double = 16

    /// 値が有限で、最小サイズ以上あるか。
    public var isValidSize: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite && width >= Self.minSide && height >= Self.minSide
    }

    /// ディスプレイの大きさに切り詰めた範囲。重なりが最小サイズ未満なら nil。
    public func clamped(toDisplayWidth displayWidth: Double, height displayHeight: Double) -> ScreenRecordingRegion? {
        guard isValidSize, displayWidth > 0, displayHeight > 0 else { return nil }
        // 画面との交差を取る(原点を寄せるだけだと、はみ出した分だけ幅が広がってしまう)
        let nx = max(0, x)
        let ny = max(0, y)
        let nw = min(x + width, displayWidth) - nx
        let nh = min(y + height, displayHeight) - ny
        guard nw >= Self.minSide, nh >= Self.minSide else { return nil }
        return ScreenRecordingRegion(x: nx, y: ny, width: nw, height: nh)
    }

    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// 収録対象(ディスプレイ / ウィンドウ / 矩形)。ID は ScreenCaptureKit の一覧と突き合わせるためのもの。
public struct ScreenCaptureTarget: Equatable, Sendable {
    public var kind: ScreenCaptureSourceKind
    /// 対象ディスプレイの ID(CGDirectDisplayID と同じ値)。window のときは、そのウィンドウがあるディスプレイ(不明なら 0)。
    public var displayID: UInt32
    /// window のときだけ使うウィンドウ ID(CGWindowID と同じ値)。
    public var windowID: UInt32
    /// 表示用の名前(ディスプレイ名・ウィンドウのタイトル)。
    public var title: String
    /// ディスプレイの大きさ(ポイント)。region の切り詰めと出力サイズの目安に使う。
    public var displayWidth: Double
    public var displayHeight: Double
    /// region のときの範囲(ディスプレイ座標)。
    public var region: ScreenRecordingRegion?

    public init(kind: ScreenCaptureSourceKind, displayID: UInt32, windowID: UInt32 = 0, title: String,
                displayWidth: Double = 0, displayHeight: Double = 0, region: ScreenRecordingRegion? = nil) {
        self.kind = kind; self.displayID = displayID; self.windowID = windowID; self.title = title
        self.displayWidth = displayWidth; self.displayHeight = displayHeight; self.region = region
    }

    /// 出力映像の大きさ(ピクセル数の目安。偶数に丸める)。決まらなければ nil。
    public var outputPixelSize: (width: Int, height: Int)? {
        let w: Double, h: Double
        switch kind {
        case .display:
            w = displayWidth; h = displayHeight
        case .window:
            return nil   // ウィンドウの大きさはエンジンが実物から決める
        case .region:
            guard let r = region else { return nil }
            w = r.width; h = r.height
        }
        guard w >= 2, h >= 2 else { return nil }
        return (Int(w) / 2 * 2, Int(h) / 2 * 2)
    }
}

/// 収録の設定一式。
public struct ScreenRecordingSettings: Equatable, Sendable {
    public var target: ScreenCaptureTarget
    /// システムの音(アプリの音など)を一緒に入れるか。マイクは使わない(許可も求めない)。
    public var includeSystemAudio: Bool
    /// 1 秒あたりのコマ数。
    public var fps: Int

    public static let fpsRange: ClosedRange<Int> = 1...60

    public init(target: ScreenCaptureTarget, includeSystemAudio: Bool = true, fps: Int = 30) {
        self.target = target
        self.includeSystemAudio = includeSystemAudio
        self.fps = min(max(Self.fpsRange.lowerBound, fps), Self.fpsRange.upperBound)
    }

    /// 収録を始める前の検証。問題があれば理由を返す(エンジンは呼ばない)。
    public func validate() -> ScreenRecordingError? {
        guard Self.fpsRange.contains(fps) else { return .invalidSettings("フレームレートは \(Self.fpsRange.lowerBound)〜\(Self.fpsRange.upperBound) fps で指定してください") }
        switch target.kind {
        case .display:
            guard target.displayID != 0 else { return .noTargetAvailable }
            guard target.displayWidth >= 2, target.displayHeight >= 2 else { return .invalidSettings("ディスプレイの大きさが分かりませんでした") }
        case .window:
            guard target.windowID != 0 else { return .noTargetAvailable }
        case .region:
            guard target.displayID != 0 else { return .noTargetAvailable }
            guard let r = target.region, r.isValidSize else {
                return .invalidRegion("範囲の幅と高さは \(Int(ScreenRecordingRegion.minSide)) 以上で指定してください")
            }
            if target.displayWidth > 0, target.displayHeight > 0,
               r.clamped(toDisplayWidth: target.displayWidth, height: target.displayHeight) == nil {
                return .invalidRegion("範囲がディスプレイの外に出ています")
            }
        }
        return nil
    }

    /// region をディスプレイ内に切り詰めた設定(開始直前にエンジンが使う)。
    public var clampedToDisplay: ScreenRecordingSettings {
        var s = self
        if target.kind == .region, let r = target.region, target.displayWidth > 0, target.displayHeight > 0,
           let c = r.clamped(toDisplayWidth: target.displayWidth, height: target.displayHeight) {
            s.target.region = c
        }
        return s
    }
}

// MARK: - エラー

/// 画面収録の失敗理由。どれもアプリを落とさず、案内文と一緒に画面へ出すためのもの。
public enum ScreenRecordingError: Error, Equatable, Sendable {
    /// 画面収録の許可が無い(システム設定で許可が要る)。
    case permissionDenied
    /// 対象(ディスプレイ・ウィンドウ)が無い・選ばれていない。
    case noTargetAvailable
    /// 範囲の指定が不正。
    case invalidRegion(String)
    /// 設定が不正。
    case invalidSettings(String)
    /// 書き込み(ファイル)に失敗した。
    case writerFailed(String)
    /// キャプチャ側(ScreenCaptureKit)に失敗した。
    case captureFailed(String)
    /// すでに収録中。
    case alreadyRunning
    /// 収録していないのに停止しようとした。
    case notRecording

    /// 利用者向けの短い説明。
    public var message: String {
        switch self {
        case .permissionDenied: return "画面収録の許可がありません"
        case .noTargetAvailable: return "収録できる画面やウィンドウがありません"
        case .invalidRegion(let m), .invalidSettings(let m), .writerFailed(let m), .captureFailed(let m): return m
        case .alreadyRunning: return "すでに収録中です"
        case .notRecording: return "収録していません"
        }
    }

    /// 次に何をすればよいかの案内(許可が無いときだけ具体的な手順を出す)。
    public var guidance: String? {
        switch self {
        case .permissionDenied:
            return "システム設定 ▸ プライバシーとセキュリティ ▸ 画面収録 で「Movie Cut」を許可してから、もう一度お試しください。許可のあとアプリの再起動が必要なことがあります。"
        case .noTargetAvailable:
            return "対象の一覧を更新して、ディスプレイまたはウィンドウを選んでください。"
        default:
            return nil
        }
    }
}

extension ScreenRecordingError: LocalizedError {
    public var errorDescription: String? { message }
}

// MARK: - 状態遷移

/// 収録の段階。
public enum ScreenRecordingPhase: String, Equatable, Sendable {
    case idle        // 止まっている(開始できる)
    case preparing   // 対象の確認・書き込みの準備中
    case recording   // 収録中
    case stopping    // 停止してファイルを閉じている最中
    case finished    // 終わった(ファイルができた)
    case failed      // 失敗した(理由は別に持つ)
}

/// 収録の状態遷移(純粋な判定)。あり得ない遷移は false を返して状態を変えない。
public struct ScreenRecordingStateMachine: Equatable, Sendable {
    public private(set) var phase: ScreenRecordingPhase = .idle

    public init() {}

    public var isActive: Bool { phase == .preparing || phase == .recording || phase == .stopping }
    public var canStart: Bool { phase == .idle || phase == .finished || phase == .failed }
    public var canStop: Bool { phase == .recording }

    /// 遷移できるかどうか(状態は変えない)。
    public func canTransition(to next: ScreenRecordingPhase) -> Bool {
        switch (phase, next) {
        case (.idle, .preparing),
             (.preparing, .recording), (.preparing, .failed), (.preparing, .idle),
             (.recording, .stopping), (.recording, .failed),
             (.stopping, .finished), (.stopping, .failed),
             (.finished, .idle), (.finished, .preparing),
             (.failed, .idle), (.failed, .preparing):
            return true
        default:
            return false
        }
    }

    /// 遷移する。できない遷移は false を返し、状態は変えない。
    @discardableResult
    public mutating func transition(to next: ScreenRecordingPhase) -> Bool {
        guard canTransition(to: next) else { return false }
        phase = next
        return true
    }

    /// どの段階からでも止まった状態へ戻す(シートを閉じるときなどの後片付け用)。
    public mutating func reset() { phase = .idle }
}

// MARK: - 保存先の名前付け

/// 収録ファイルの名前と保存先(純粋な計算)。
public enum ScreenRecordingFileNaming {
    /// 拡張子は .mov(H.264 + AAC。既存の素材の取り込みがそのまま読める)。
    public static let fileExtension = "mov"

    /// 「画面収録 2026-11-19 12.03.04」の形の基本名。
    public static func baseName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "画面収録 " + f.string(from: date)
    }

    /// 保存先フォルダの中の出力 URL。同名があれば「-2」「-3」を付けてぶつからないようにする。
    public static func outputURL(in directory: URL, date: Date, fileExists: (URL) -> Bool) -> URL {
        let base = baseName(for: date)
        var candidate = directory.appendingPathComponent(base).appendingPathExtension(fileExtension)
        var n = 2
        while fileExists(candidate) {
            candidate = directory.appendingPathComponent("\(base)-\(n)").appendingPathExtension(fileExtension)
            n += 1
        }
        return candidate
    }

    /// 経過時間の表示(0:07 / 1:02:03)。
    public static func elapsedText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
