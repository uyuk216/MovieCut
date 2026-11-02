import Foundation

/// 使えないメニュー項目の理由(日本語)。項目表(AppMenuSpec)の enabled と対で使い、
/// 有効なら nil。メニュー項目の .help(ツールチップ)に出す。新しい無効条件は作らず、今ある条件を言葉にするだけ。
extension AppMenuSpec {
    static func disabledReason(for spec: MenuItemSpec, state s: MenuState) -> String? {
        if spec.enabled { return nil }
        // 書類がなくても動く項目(ファンの設定)は専用の理由
        switch spec.command {
        case .fanMaxToggle: return s.fanReason ?? "この Mac では使えません"
        case .fanInstall: return "すでに有効か、この Mac は対象外です"
        case .fanUninstall: return "ファン制御は有効になっていません"
        case .openRecent: return "ファイルが見つかりません"
        case .clearRecents: return "履歴はありません"
        default: break
        }
        if !s.hasDocument { return "プロジェクトを開いてから使えます" }
        if s.isLocked { return "書き出し中・音声生成中は使えません" }
        switch spec.command {
        case .export, .exportPreset, .exportCustomPreset, .saveCustomPreset, .exportStill, .exportSequence,
             .exportThumbnail, .exportGIF, .queueExport, .measureLoudness:
            return "書き出せるクリップがありません"
        case .rangeIn, .rangeOut: return "書き出し範囲を指定できる状態ではありません"
        case .rangeClear: return "書き出し範囲が指定されていません"
        case .rangeFromSelection: return s.canMarkRange ? "クリップを選んでください" : "書き出し範囲を指定できる状態ではありません"
        case .prevGap, .nextGap: return "空白がありません(クリップが途切れていません)"
        case .selectClipAtPlayhead, .speechShare, .clipList: return "クリップがありません"
        case .noteList: return "注記のあるクリップがありません"
        case .selectShortClips: return "6 コマ未満のクリップはありません"
        case .exportScript: return "声のクリップがありません"
        case .exportStoryboard: return "書き出せるクリップがありません"
        case .sourceUsage: return "動画・音声・画像のクリップを 1 つ選んでください(フリーズは対象外)"
        case .exportSubtitles, .translateSubtitles: return "字幕にできる文字・セリフがありません"
        case .generateSubtitles: return "字幕にできるセリフがありません"
        case .transcribeSubtitles: return "音のあるクリップを選んでください"
        case .relinkMedia: return "見つからない素材はありません"
        case .unusedMedia: return "未使用の素材はありません"
        case .toggleRangeLoop: return "書き出し範囲が指定されていません"
        case .toggleTrimLoop: return "タイムラインが空です"
        case .toggleClipLoop: return "クリップを選んでください"
        case .removeBackground, .imageChroma: return "静止画のクリップを選んでください"
        case .findReplace: return "文字・セリフのクリップがありません"
        case .textStyleApplyAll: return "文字クリップがありません"
        case .copyClips, .cutClips: return "クリップを選んでから実行します"
        case .pasteClips: return "貼り付けるクリップがありません"
        case .split: return "再生位置がクリップの上にありません"
        case .trimBefore, .trimAfter: return "再生位置がクリップの途中にありません"
        case .layerDelete: return s.hasLayerTarget ? (s.layerDeleteBlocked ?? "今の状態では使えません") : "レイヤーかクリップを選んでください"
        case .clipLock: return "クリップを選んでください"
        case .layerLock, .layerSolo: return "レイヤーかクリップを選んでください"
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
        case .autoWhiteBalance: return "画像か動画のクリップを選んでください"
        case .copyChaptersColor: return "その色のマーカーがありません"
        case .effectClear, .effectCopy: return "エフェクトがありません"
        case .effectPaste: return "コピーしたエフェクトがないか、貼り付け先を選んでいません"
        case .textAnim, .toggleCounter: return "文字クリップを選んでください"
        case .pip: return "画像か映像のクリップを選んでください"
        case .speed, .toggleReverse: return "速度を変えられるクリップを選んでください"
        case .freezeFrame: return "再生位置が映像クリップの上にありません"
        case .audioNormalize, .audioVolumeUp, .audioVolumeDown, .audioVoicePreset: return "音のあるクリップを選んでください"
        case .audioClear: return "音声エフェクトがありません"
        case .silenceCut: return "音のあるクリップを選んでください"
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
