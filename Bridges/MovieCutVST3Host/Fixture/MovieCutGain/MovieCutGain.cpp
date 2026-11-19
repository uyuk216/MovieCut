// MovieCutGain 実装(ヘッダ参照)。検証専用なので処理は素直に書く。
#include "MovieCutGain.h"

#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/base/ustring.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"

#include <cmath>

namespace MovieCutFixture {

using namespace Steinberg;
using namespace Steinberg::Vst;

// "MCGN" 系の固定 UID(フィクスチャ専用。他のプラグインと衝突しないよう専用値を使う)
const FUID kMovieCutGainUID(0x4D434749, 0x4E000100, 0x46495854, 0x00010000);

MovieCutGain::MovieCutGain() = default;

tresult PLUGIN_API MovieCutGain::initialize(FUnknown* context) {
    tresult r = SingleComponentEffect::initialize(context);
    if (r != kResultOk) return r;
    addAudioInput(STR16("Stereo In"), SpeakerArr::kStereo);
    addAudioOutput(STR16("Stereo Out"), SpeakerArr::kStereo);
    addEventInput(STR16("Event In"), 1);
    // stepCount は SDK 3.8 の数値仕様(ParameterInfo.stepCount、ivsteditcontroller.h): 0=連続、1=トグル
    parameters.addParameter(USTRING("Gain"), USTRING(""), 0, 0.75,
                            ParameterInfo::kCanAutomate, kGainId);
    parameters.addParameter(USTRING("Bypass"), nullptr, 1, 0,
                            ParameterInfo::kCanAutomate | ParameterInfo::kIsBypass, kBypassId);
    parameters.addParameter(USTRING("VuPPM"), nullptr, 0, 0,
                            ParameterInfo::kIsReadOnly, kVuId);
    return kResultOk;
}

tresult PLUGIN_API MovieCutGain::setBusArrangements(SpeakerArrangement* inputs, int32 numIns,
                                                    SpeakerArrangement* outputs, int32 numOuts) {
    if (numIns == 1 && numOuts == 1 && inputs[0] == SpeakerArr::kStereo && outputs[0] == SpeakerArr::kStereo)
        return SingleComponentEffect::setBusArrangements(inputs, numIns, outputs, numOuts);
    return kResultFalse;  // ステレオ以外は受けない(ホスト側はバイパスに落とすのが正)
}

tresult PLUGIN_API MovieCutGain::canProcessSampleSize(int32 symbolicSampleSize) {
    return symbolicSampleSize == kSample32 ? kResultOk : kNotImplemented;
}

tresult PLUGIN_API MovieCutGain::setParamNormalized(ParamID tag, ParamValue value) {
    if (tag == kGainId) gain = value;
    if (tag == kBypassId) bypass = value > 0.5;
    return SingleComponentEffect::setParamNormalized(tag, value);
}

tresult PLUGIN_API MovieCutGain::process(ProcessData& data) {
    if (data.inputParameterChanges) {
        int32 n = data.inputParameterChanges->getParameterCount();
        for (int32 i = 0; i < n; i++) {
            if (auto* q = data.inputParameterChanges->getParameterData(i)) {
                int32 points = q->getPointCount();
                int32 offset = 0; ParamValue v = 0;
                if (points > 0 && q->getPoint(points - 1, offset, v) == kResultOk) {
                    if (q->getParameterId() == kGainId) gain = v;
                    if (q->getParameterId() == kBypassId) bypass = v > 0.5;
                }
            }
        }
    }
    if (data.numInputs < 1 || data.numOutputs < 1 || data.numSamples <= 0) return kResultOk;
    auto& in = data.inputs[0];
    auto& out = data.outputs[0];
    const float g = bypass ? 1.f : static_cast<float>(gain);
    int32 ch = std::min(in.numChannels, out.numChannels);
    for (int32 c = 0; c < ch; c++) {
        const float* src = in.channelBuffers32[c];
        float* dst = out.channelBuffers32[c];
        for (int32 s = 0; s < data.numSamples; s++) dst[s] = src[s] * g;
    }
    return kResultOk;
}

namespace {
tresult writeState(IBStream* state, double gain, bool bypass) {
    int32 written = 0;
    double values[2] = {gain, bypass ? 1.0 : 0.0};
    return state->write(values, sizeof(values), &written);
}
tresult readState(IBStream* state, double& gain, bool& bypass) {
    int32 read = 0;
    double values[2] = {0.75, 0.0};
    tresult r = state->read(values, sizeof(values), &read);
    if (r == kResultOk && read == static_cast<int32>(sizeof(values))) {
        gain = std::min(1.0, std::max(0.0, values[0]));
        bypass = values[1] > 0.5;
    }
    return r;
}
} // namespace

tresult PLUGIN_API MovieCutGain::setState(IBStream* state) { return readState(state, gain, bypass); }
tresult PLUGIN_API MovieCutGain::getState(IBStream* state) { return writeState(state, gain, bypass); }
tresult PLUGIN_API MovieCutGain::setEditorState(IBStream* state) { return readState(state, gain, bypass); }
tresult PLUGIN_API MovieCutGain::getEditorState(IBStream* state) { return writeState(state, gain, bypass); }

} // namespace MovieCutFixture
