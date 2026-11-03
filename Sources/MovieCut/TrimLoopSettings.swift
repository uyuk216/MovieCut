import Foundation
import MovieCutCore

/// 反復再生の前後の幅(秒)。アプリの設定として保存する(プロジェクトには入れない)。
enum TrimLoopSettings {
    static let key = "trimLoopHalfWidth"
    static var halfWidth: Double {
        get { UserDefaults.standard.object(forKey: key) == nil ? TrimLoop.defaultHalfWidth : TrimLoop.normalizedHalfWidth(UserDefaults.standard.double(forKey: key)) }
        set { UserDefaults.standard.set(TrimLoop.normalizedHalfWidth(newValue), forKey: key) }
    }
}

/// 合成音声を作り直して尺が変わったとき、同じレイヤーの後ろのクリップをずらして詰めるか(アプリの設定。プロジェクトには入れない。既定はオフ)。
enum VoiceRippleSettings {
    static let key = "voiceAutoRipple"
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
