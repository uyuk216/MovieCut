// MovieCutGain — 検証用フィクスチャ VST3(W6-1)
// SDK サンプルの AGain(単一コンポーネント版)を最小化した、GUI 無しのゲインプラグイン。
// 目的は「ブリッジ経由でロード→setup→process→パラメータ→状態往復」を実音で検証すること。
// パラメータ: Gain(id=0, 正規化 0...1 がそのまま線形ゲイン、既定 0.75)
//             Bypass(id=1, トグル)、VuPPM(id=2, 読み取り専用)
#pragma once

#include "public.sdk/source/vst/vstsinglecomponenteffect.h"

namespace MovieCutFixture {

enum ParamIDs { kGainId = 0, kBypassId = 1, kVuId = 2 };

extern const Steinberg::FUID kMovieCutGainUID;

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

private:
    double gain = 0.75;
    bool bypass = false;
};

} // namespace MovieCutFixture
