import Foundation

/// 作業メモリの上限を決める純粋な規則(画面・実機に依存しないので単体テストできる)。
///
/// 予算表(総 RAM → 作業メモリ上限):
///   32GB → 16GB / 24GB → 12GB / 16GB → 6GB / 8GB → 2GB / 4GB → 0.5GB
/// 表に無い容量は「直近下位の階級」を適用する(例: 20GB は 16GB 階級 → 6GB)。
/// 表より小さい容量(4GB 未満)は最小階級(0.5GB)を適用する。
///
/// プラットフォーム例外(引数で切り替え可能):
///   - Mac: 24GB 以上で上限なし
///   - Windows: 32GB 以上で上限なし
/// この実装は Mac 版だが、規則自体はプラットフォームを引数で受けるので
/// Windows 版でも同じ表・同じ例外規則を再利用できる。
public enum MemoryBudgetPlatform: String, Equatable, Sendable {
    case mac
    case windows
    /// 例外なし(表どおり)。
    case generic
}

public enum MemoryBudget {
    /// 1 GiB(予算表の「GB」は GiB として扱う)。
    public static let gib: Int64 = 1_024 * 1_024 * 1_024

    /// 予算表: (総 RAM の下限, 上限)。総 RAM の降順。
    public static let table: [(minimumTotal: Int64, limit: Int64)] = [
        (32 * gib, 16 * gib),
        (24 * gib, 12 * gib),
        (16 * gib, 6 * gib),
        (8 * gib, 2 * gib),
        (4 * gib, gib / 2),
    ]

    /// プラットフォーム例外: この総 RAM 以上なら上限なしにする閾値。例外が無いプラットフォームは nil。
    public static func unlimitedThreshold(for platform: MemoryBudgetPlatform) -> Int64? {
        switch platform {
        case .mac: return 24 * gib
        case .windows: return 32 * gib
        case .generic: return nil
        }
    }

    /// 総 RAM(バイト)から作業メモリ上限(バイト)を返す。上限なしのときは nil。
    /// 純粋関数: 同じ入力には常に同じ結果を返す。
    public static func limitBytes(totalRAMBytes: Int64, platform: MemoryBudgetPlatform = .mac) -> Int64? {
        guard totalRAMBytes > 0 else { return table.last?.limit }
        if let threshold = unlimitedThreshold(for: platform), totalRAMBytes >= threshold {
            return nil
        }
        // 直近下位の階級: minimumTotal <= totalRAMBytes を満たす最大の階級。
        for row in table where totalRAMBytes >= row.minimumTotal {
            return row.limit
        }
        // 表より小さい場合は最小階級。
        return table.last?.limit
    }

    /// Double(GB)で受ける便利版。テストや設定画面からの利用を想定。
    public static func limitBytes(totalRAMGB: Double, platform: MemoryBudgetPlatform = .mac) -> Int64? {
        limitBytes(totalRAMBytes: Int64(totalRAMGB * Double(gib)), platform: platform)
    }

    /// このマシンの総 RAM から上限を求める(実機用。テストでは使わない)。
    public static func currentLimitBytes(platform: MemoryBudgetPlatform = .mac) -> Int64? {
        limitBytes(totalRAMBytes: Int64(ProcessInfo.processInfo.physicalMemory), platform: platform)
    }
}
