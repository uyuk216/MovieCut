// MovieCutGain のファクトリ定義(検証用フィクスチャ)
#include "MovieCutGain.h"
#include "public.sdk/source/main/pluginfactory.h"

#define stringPluginName "MovieCutGain"

BEGIN_FACTORY_DEF("MovieCut Fixture", "", "")

    DEF_CLASS2(INLINE_UID_FROM_FUID(MovieCutFixture::kMovieCutGainUID),
               Steinberg::PClassInfo::kManyInstances,
               kVstAudioEffectClass,
               stringPluginName,
               Steinberg::Vst::kDistributable,
               "Fx",
               "1.0.0",
               kVstVersionString,
               MovieCutFixture::MovieCutGain::createInstance)

END_FACTORY
