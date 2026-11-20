// MovieCutGain — 検証用フィクスチャ VST3(W6-1)
// SDK サンプルの AGain(単一コンポーネント版)を最小化した、GUI 無しのゲインプラグイン。
// 目的は「ブリッジ経由でロード→setup→process→パラメータ→状態往復」を実音で検証すること。
// パラメータ: Gain(id=0, 正規化 0...1 がそのまま線形ゲイン、既定 0.75)
//             Bypass(id=1, トグル)、VuPPM(id=2, 読み取り専用)
#pragma once

#include "public.sdk/source/common/pluginview.h"
#include "public.sdk/source/vst/vstsinglecomponenteffect.h"

namespace MovieCutFixture {

enum ParamIDs { kGainId = 0, kBypassId = 1, kVuId = 2 };

extern const Steinberg::FUID kMovieCutGainUID;

/// 最小の IPlugView。サイズ保持(getSize/onSize は内部の rect の読み書き)は SDK の CPluginView に任せる
/// ので、onSize で受けたサイズが getSize に反映される。ただし CPluginView の
/// isPlatformTypeSupported は既定で kNotImplemented を返すため、ここで override する
/// (macOS は NSView のみ対応。それ以外は kResultFalse)。
/// attached では子の NSView を作らず、親を保持するだけにしている: NSView の生成には
/// Objective-C++(.mm)が要り、フィクスチャの目的(ブリッジの attach/size/destroy の配線検証)には
/// 親ビューの受け渡しが確認できれば足りるため。実描画の確認は実プラグインで行う。
class MovieCutGainEditorView : public Steinberg::CPluginView {
public:
    MovieCutGainEditorView();
    Steinberg::tresult PLUGIN_API isPlatformTypeSupported(Steinberg::FIDString type) SMTG_OVERRIDE;
};

class MovieCutGain : public Steinberg::Vst::SingleComponentEffect {
public:
    MovieCutGain();
    static Steinberg::FUnknown* createInstance(void*) {
        return (Steinberg::Vst::IAudioProcessor*)new MovieCutGain;
    }

    Steinberg::tresult PLUGIN_API initialize(Steinberg::FUnknown* context) SMTG_OVERRIDE;
    Steinberg::tresult PLUGIN_API setBusArrangements(Steinberg::Vst::SpeakerArrangement* inputs, Steinberg::int32 numIns,
                                                      Steinberg::Vst::SpeakerArrangement* outputs, Steinberg::int32 numOuts) SMTG_OVERRIDE;
    Steinberg::tresult PLUGIN_API canProcessSampleSize(Steinberg::int32 symbolicSampleSize) SMTG_OVERRIDE;
    Steinberg::tresult PLUGIN_API process(Steinberg::Vst::ProcessData& data) SMTG_OVERRIDE;
    Steinberg::tresult PLUGIN_API setParamNormalized(Steinberg::Vst::ParamID tag, Steinberg::Vst::ParamValue value) SMTG_OVERRIDE;
    // IComponent の状態(ゲインとバイパスをそのまま書く)
    Steinberg::tresult PLUGIN_API setState(Steinberg::IBStream* state) SMTG_OVERRIDE;
    Steinberg::tresult PLUGIN_API getState(Steinberg::IBStream* state) SMTG_OVERRIDE;
    Steinberg::tresult PLUGIN_API setEditorState(Steinberg::IBStream* state) SMTG_OVERRIDE;
    Steinberg::tresult PLUGIN_API getEditorState(Steinberg::IBStream* state) SMTG_OVERRIDE;
    // 最小エディタ(R5 キュー3): "editor" のときだけ固定 320x200 のビューを返す。それ以外は基底へ。
    Steinberg::IPlugView* PLUGIN_API createView(Steinberg::FIDString name) SMTG_OVERRIDE;

private:
    double gain = 0.75;
    bool bypass = false;
};

} // namespace MovieCutFixture
