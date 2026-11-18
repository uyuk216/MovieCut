import Foundation
import MovieCutCore

/// 顔ぼかしの一括付与・一括解除(F-2)。Core の FaceBlurBulk(W2-08)へのメニュー到達経路。
/// どちらもプロジェクト全体への編集で、Undo は 1 回。対象が無いときは Undo を積まず、状態表示で知らせる。
extension ProjectModel {

    /// クリップ ▸ エフェクト ▸ すべてのクリップに顔ぼかしを付ける。
    /// 既定の設定(強さ 0.6・モザイク)で、映像・画像・複合クリップ(複合の中身も含む)へ付ける。
    /// すでに付いているクリップは新しい設定で置き換える(FaceBlurBulk の既定の規則)。
    @discardableResult
    func applyFaceBlurToAll() -> Int {
        guard !isLocked else { return 0 }
        var probe = project
        let changed = FaceBlurBulk.apply(to: &probe)
        guard changed > 0 else {
            statusText = "顔ぼかしを付けられるクリップがありませんでした(映像・画像・複合が対象です)"
            return 0
        }
        edit("顔ぼかしを一括で付ける") { _ = FaceBlurBulk.apply(to: &$0) }
        statusText = "\(changed) 個のクリップに顔ぼかしを付けました"
        return changed
    }

    /// クリップ ▸ エフェクト ▸ 顔ぼかしをすべて外す。プロジェクト全体(複合の中身も含む)から外す。
    @discardableResult
    func removeAllFaceBlur() -> Int {
        guard !isLocked else { return 0 }
        var probe = project
        let changed = FaceBlurBulk.removeAll(from: &probe)
        guard changed > 0 else {
            statusText = "顔ぼかしが付いているクリップがありませんでした"
            return 0
        }
        edit("顔ぼかしを一括で外す") { _ = FaceBlurBulk.removeAll(from: &$0) }
        statusText = "\(changed) 個のクリップから顔ぼかしを外しました"
        return changed
    }
}
