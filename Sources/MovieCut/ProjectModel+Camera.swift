import Foundation
import MovieCutCore

/// カメラ(W3-02 / 監査 #54)の編集。計算と保存形式は MovieCutCore(`CameraSettings`)、
/// ここは Undo(1 操作 = 1 回)・再生位置・ジェスチャだけ。
/// カメラのキーフレームの時刻はプロジェクト時刻(クリップのキーと違い、クリップ頭基準ではない)。
extension ProjectModel {
    static let cameraUndoName = "カメラの変更"

    /// いまの設定(未設定なら既定値)。
    var cameraSettings: CameraSettings { project.camera ?? CameraSettings() }

    /// 再生ヘッドでの項目の値(キーがあれば補間後)。
    func cameraValue(_ key: String) -> Double { cameraSettings.value(of: key, at: currentTime) }

    /// ◇ の状態(クリップのキーと同じ判定)。
    func cameraKeyState(_ key: String) -> KeyframeEditing.KeyState {
        let cam = cameraSettings
        guard cam.isAnimated(key) else { return .none }
        let tol = keyTolerance
        return (cam.keyframes[key] ?? []).contains { abs($0.t - currentTime) < tol } ? .onKey : .between
    }

    /// その項目のキーの時刻(昇順)。
    func cameraKeyTimes(_ key: String) -> [Double] {
        (cameraSettings.keyframes[key] ?? []).map(\.t).sorted()
    }

    /// 前後のキーへ再生ヘッドを動かす。
    @discardableResult
    func seekCameraKeyframe(_ key: String, forward: Bool) -> Bool {
        let tol = keyTolerance
        let times = cameraKeyTimes(key)
        let t = forward ? times.first { $0 > currentTime + tol } : times.last { $0 < currentTime - tol }
        guard let t else { return false }
        playback.seek(to: t)
        return true
    }

    /// キー列へ足す(同じ時刻は置き換え・時刻順)。
    private static func insertCameraKey(_ cam: inout CameraSettings, key: String, _ k: Keyframe) {
        var list = cam.keyframes[key] ?? []
        list.removeAll { abs($0.t - k.t) < 1e-9 }
        list.append(k)
        list.sort { $0.t < $1.t }
        cam.keyframes[key] = list
    }

    /// 変更をカメラへ適用する共通処理(既定値に戻ったらファイルから消えるよう nil にする)。
    private func applyCamera(_ name: String, _ change: (inout CameraSettings) -> Void) {
        edit(name) { p in
            var cam = p.camera ?? CameraSettings()
            change(&cam)
            p.camera = cam.isDefault ? nil : cam
        }
    }

    /// 項目の値を書く(1 回の Undo)。キーがあれば再生ヘッドのキーを更新/追加、無ければ静的な値。
    func setCameraValue(_ key: String, _ value: Double) {
        guard !isLocked else { return }
        flushCoalesced()
        let t = currentTime, tol = keyTolerance
        applyCamera(Self.cameraUndoName) { cam in
            let v = CameraSettings.clamp(key, value)
            if cam.isAnimated(key) {
                if let i = (cam.keyframes[key] ?? []).firstIndex(where: { abs($0.t - t) < tol }) {
                    cam.keyframes[key]![i].v = v
                } else {
                    Self.insertCameraKey(&cam, key: key, Keyframe(t: (t * 1e6).rounded() / 1e6, v: v))
                }
            } else {
                cam.setStaticValue(v, of: key)
            }
        }
    }

    /// スライダーのドラッグ中(beginGesture 〜 commitGesture の間は Undo に積まない)。
    func liveCameraValue(_ key: String, _ value: Double) {
        guard !isLocked else { return }
        var p = gestureBase ?? project
        var cam = p.camera ?? CameraSettings()
        let t = currentTime
        if cam.isAnimated(key) {
            if let i = (cam.keyframes[key] ?? []).firstIndex(where: { abs($0.t - t) < keyTolerance }) {
                cam.keyframes[key]![i].v = CameraSettings.clamp(key, value)
            } else {
                Self.insertCameraKey(&cam, key: key, Keyframe(t: (t * 1e6).rounded() / 1e6, v: CameraSettings.clamp(key, value)))
            }
        } else {
            cam.setStaticValue(value, of: key)
        }
        p.camera = cam.isDefault ? nil : cam
        if gestureBase != nil { updateGesture(p) } else if p != project { edit(Self.cameraUndoName) { $0 = p } }
    }

    /// ◇: 再生ヘッドにキーがあれば消し、無ければ「いまの値」で足す(1 回の Undo)。
    /// 最後の 1 つを消したときは、その値を静的な値にして見た目を保つ(クリップのキーと同じ)。
    @discardableResult
    func toggleCameraKeyframe(_ key: String) -> Bool {
        guard !isLocked else { return false }
        let t = currentTime, tol = keyTolerance
        var changed = false
        applyCamera("カメラのキーフレーム") { cam in
            if let i = (cam.keyframes[key] ?? []).firstIndex(where: { abs($0.t - t) < tol }) {
                let removed = cam.keyframes[key]!.remove(at: i)
                if cam.keyframes[key]!.isEmpty {
                    cam.keyframes[key] = nil
                    cam.setStaticValue(removed.v, of: key)
                }
                changed = true
            } else {
                let v = cam.value(of: key, at: t)
                Self.insertCameraKey(&cam, key: key, Keyframe(t: (t * 1e6).rounded() / 1e6, v: v))
                changed = true
            }
        }
        return changed
    }

    /// カメラを丸ごとリセットする(未設定に戻す。1 回の Undo)。
    @discardableResult
    func resetCamera() -> Bool {
        guard !isLocked, project.camera != nil else { return false }
        return edit("カメラをリセット") { $0.camera = nil }
    }
}
