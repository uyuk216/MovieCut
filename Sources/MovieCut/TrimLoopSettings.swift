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
