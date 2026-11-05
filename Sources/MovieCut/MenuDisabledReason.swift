import Foundation
import MovieCutCore

/// 使えないメニュー項目の理由(日本語)。項目表(AppMenuSpec)の enabled と対で使い、
/// 有効なら nil。メニュー項目の .help(ツールチップ)に出す。新しい無効条件は作らず、今ある条件を言葉にするだけ。
extension AppMenuSpec {
    static func disabledReason(for spec: MenuItemSpec, state s: MenuState) -> String? {
        if spec.enabled { return nil }
        // 書類がなくても動く項目は専用の理由
        switch spec.command {
        case .openRecent: return "ファイルが見つかりません"
        case .clearRecents: return "履歴はありません"
        default: break
        }
        if !s.hasDocument { return "プロジェクトを開いてから使えます" }
        if s.isLocked { return "書き出し中・音声生成中は使えません" }
        switch spec.command {
        case .export, .exportPreset, .exportCustomPreset, .saveCustomPreset, .exportStill, .exportSequence,
             .exportThumbnail, .exportThumbnailCandidates, .exportGIF, .exportAPNG, .queueExport, .measureLoudness:
            return "書き出せるクリップがありません"
        case .rangeIn, .rangeOut: return "書き出し範囲を指定できる状態ではありません"
        case .rangeClear: return "書き出し範囲が指定されていません"
        case .rangeFromSelection: return s.canMarkRange ? "クリップを選んでください" : "書き出し範囲を指定できる状態ではありません"
        case .prevGap, .nextGap: return "空白がありません(クリップが途切れていません)"
        case .selectClipAtPlayhead, .speechShare, .clipList: return "クリップがありません"
        case .noteList: return "注記のあるクリップがありません"
        case .cycleOverlapping: return "再生位置でクリップが 2 つ以上重なっていません"
        case .transferClips: return "複製するクリップを選んでください"
        case .candidateSwap: return "動画・音声・画像のクリップを選んでください(同じ種類の他の素材が必要です。ロック・フリーズは対象外)"
        case .compareTakes: return "同じセリフのボイスクリップが 2 つ以上ありません"
        case .mergeSplits: return "統合できる分割点がありません(同じ素材の続きで、つなぎ目に効果が無いクリップの組)"
        case .selectShortClips: return "6 コマ未満のクリップはありません"
        case .exportScript: return "声のクリップがありません"
        case .exportStoryboard: return "書き出せるクリップがありません"
        case .sourceUsage: return "動画・音声・画像のクリップを 1 つ選んでください(フリーズは対象外)"
        case .exportSubtitles, .translateSubtitles: return "字幕にできる文字・セリフがありません"
        case .generateSubtitles: return "字幕にできるセリフがありません"
        case .transcribeSubtitles: return "音のあるクリップを選んでください"
        case .relinkMedia: return "見つからない素材はありません"
        case .unusedMedia: return "未使用の素材はありません"
        case .restoreVersion: return "先にプロジェクトを保存してください（保存のたびに世代が残ります）"
        case .toggleRangeLoop: return "書き出し範囲が指定されていません"
        case .toggleTrimLoop: return "タイムラインが空です"
        case .toggleClipLoop: return "クリップを選んでください"
        case .toggleAudition: return "再生位置に音のあるクリップがありません"
        case .cycleAudition: return "再生位置で音が重なったクリップが 2 つ以上ありません"
        case .removeBackground, .imageChroma: return "静止画のクリップを選んでください"
        case .findReplace: return "文字・セリフのクリップがありません"
        case .textStyleApplyAll: return "文字クリップがありません"
        case .copyClips, .cutClips: return "クリップを選んでから実行します"
        case .pasteClips: return "貼り付けるクリップがありません"
        case .split: return "再生位置がクリップの上にありません"
        case .trimBefore, .trimAfter: return "再生位置がクリップの途中にありません"
        case .layerDelete: return s.hasLayerTarget ? (s.layerDeleteBlocked ?? "今の状態では使えません") : "レイヤーかクリップを選んでください"
        case .clipLock: return "クリップを選んでください"
        case .rollEdit: return "同じレイヤーでぴったり隣り合うクリップを 1 つ選んでください(ロックされたものは不可)"
        case .rippleTrimHead: return s.canRippleHead ? "今の状態では使えません" : "再生位置がクリップの途中にあるクリップを 1 つ選んでください(ロックされたものは不可)"
        case .rippleTrimTail: return s.canRippleTail ? "今の状態では使えません" : "再生位置がクリップの途中にあるクリップを 1 つ選んでください(ロックされたものは不可)"
        case .multicamCreate: return Multicam.selectionHint
        case .multicamSwitch: return "マルチカメラのグループがありません(先に「マルチカメラを作る…」)"
        case .multicamCut(let i): return s.hasMulticam ? (s.multicamAngleCount == 0 ? "再生位置にマルチカメラのグループがありません" : "このグループにはアングル \(i + 1) がありません") : "マルチカメラのグループがありません"
        case .slipEdit: return "動画・音声・ボイス・複合クリップを 1 つ選んでください(フリーズ・ロックは対象外)"
        case .layerLock, .layerSolo, .layerTarget: return "レイヤーかクリップを選んでください"
        case .moveLayerUp: return "いちばん上のレイヤーです"
        case .moveLayerDown: return "いちばん下のレイヤーです"
        case .prevClip: return "前にクリップがありません"
        case .nextClip: return "後ろにクリップがありません"
        case .prevEdit: return "前に編集点がありません"
        case .nextEdit: return "後ろに編集点がありません"
        case .prevLine: return "前にセリフがありません"
        case .nextLine: return "後ろにセリフがありません"
        case .prevMarker: return "前にマーカーがありません"
        case .nextMarker: return "後ろにマーカーがありません"
        case .renameMarker, .deleteMarker, .markerColor: return "再生位置にマーカーがありません"
        case .clearMarkers, .jumpToMarker: return "マーカーがありません"
        case .prevKeyframe: return "前にキーフレームがありません"
        case .nextKeyframe: return "後ろにキーフレームがありません"
        case .clearKeyframes: return "キーフレームがありません"
        case .toggleKeyframe: return "再生位置が選んだクリップの範囲内にありません"
        case .transitionIn, .transitionOut, .fadeBoth, .crossfade: return "映像のクリップを選んでください"
        case .clearTransitions: return "トランジションがありません"
        case .fadeInOut: return "映像か音のクリップを選んでください"
        case .effectAdd, .effectPreset, .lutLoad: return "エフェクトを付けられるクリップを選んでください"
        case .audioAutoSync: return AudioSyncEditing.selectionHint
        case .autoWhiteBalance: return "画像か動画のクリップを選んでください"
        case .copyChaptersColor: return "その色のマーカーがありません"
        case .effectClear, .effectCopy: return "エフェクトがありません"
        case .effectPaste: return "コピーしたエフェクトがないか、貼り付け先を選んでいません"
        case .toggleCounter: return "文字クリップを選んでください"
        case .textAnim(let k): return k.isScroll ? "文字クリップを選んでください（字幕はスクロールしません）" : "文字クリップか字幕を選んでください"
        case .toggleVertical: return "文字クリップか字幕を選んでください"
        case .togglePerChar: return "文字クリップか字幕を選び、先に文字アニメーション（スクロール以外）を付けてください"
        case .pip: return "画像か映像のクリップを選んでください"
        case .speed, .toggleReverse: return "速度を変えられるクリップを選んでください"
        case .freezeFrame: return "再生位置が映像クリップの上にありません"
        case .audioNormalize, .audioVolumeUp, .audioVolumeDown, .audioVoicePreset: return "音のあるクリップを選んでください"
        case .audioClear: return "音声エフェクトがありません"
        case .silenceCut: return "音のあるクリップを選んでください"
        case .scaleDuplicate: return "音のあるクリップを1つ選んでください（ロックされたレイヤー・フリーズは対象外）"
        case .beatPlace: return s.canPitchLayout ? "クリップの位置以降にマーカーがありません（先に「ビートにマーカーを打つ」かマーカーを置いてください）" : "音のあるクリップを1つ選んでください（ロックされたレイヤー・フリーズは対象外）"
        case .beatMarkers: return "音のクリップを選んでください"
        case .audioDuckToggle: return "ダッキングできる音のクリップを選んでください"
        case .stabilizeToggle: return "映像クリップを選んでください"
        case .autoReframe: return "映像か画像のクリップを選んでください"
        case .motionTrack: return "文字・図形・画像のクリップを選んでください"
        case .compoundGroup: return "2 つ以上のクリップを選んでください"
        case .compoundUngroup: return "複合クリップを選んでください"
        case .regenerateVoice, .makeVoices: return "ボイスのクリップを選んでください"
        case .makeProxies: return "映像の素材がありません"
        case .duplicate, .delete, .rippleDelete, .nudgeEarlier, .nudgeLater: return "クリップを選んでから実行します"
        default: return "今の状態では使えません"
        }
    }
}
