// MovieCutVST3Bridge.cpp
//
// VST3 C++ ブリッジの実装(W6-1)。ABI の正は
// `docs/vst3-bridge/MovieCutVST3Bridge.h` で、このファイルはその実体。
//
// 方針(ヘッダの約束どおり):
// - プラグインの生成・破棄はすべてここ。外へ出すのは不透明ハンドルだけ。
// - 失敗はすべて MCVST3Status で返し、例外は境界を越えない(全関数を try/catch で包む)。
// - 処理はオフライン前提。バッファは Float32、チャンネル配列(ポインタの配列)。
// - ロードは自前 dlopen(macOS はバンドル内の実行ファイル + bundleEntry/bundleExit、
//   Linux は .so + ModuleEntry/ModuleExit、Windows は LoadLibrary + InitDll/ExitDll)。
//   SDK の Hosting::Module を使わないのは、リンクする SDK ソースを最小に保ち、
//   このライブラリ単体でビルド・検証できるようにするため。
// - バス/setup の交渉規則の正は Swift 側 `VST3ProcessingContract`。ここでは
//   渡された確定内容をプラグインへ適用し、プラグインが別構成へ化けたら
//   MCVST3_RESULT_FALSE で返す(黙った変換はしない)。
//
// ビルド: 同フォルダの CMakeLists.txt(SDK_ROOT に VST3 SDK 3.8+ のルートを指定)。
// SDK は MIT ライセンス(3.8〜)。このファイル自体は MovieCut のコード。

#include "../../docs/vst3-bridge/MovieCutVST3Bridge.h"

#include "pluginterfaces/base/funknown.h"
#include "pluginterfaces/base/funknownimpl.h"
#include "pluginterfaces/base/ipluginbase.h"
#include "pluginterfaces/base/ibstream.h"
#include "pluginterfaces/gui/iplugview.h"   // IPlugView / IPlugFrame / ViewRect / kPlatformTypeNSView
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/ivstcomponent.h"
#include "pluginterfaces/vst/ivsteditcontroller.h"
#include "pluginterfaces/vst/ivstevents.h"
#include "pluginterfaces/vst/ivsthostapplication.h"
#include "pluginterfaces/vst/ivstparameterchanges.h"
#include "pluginterfaces/vst/ivstplugview.h"   // ViewType::kEditor
#include "pluginterfaces/vst/vstspeaker.h"

#include "public.sdk/source/common/memorystream.h"
#include "public.sdk/source/vst/hosting/eventlist.h"
#include "public.sdk/source/vst/hosting/hostclasses.h"
#include "public.sdk/source/vst/hosting/parameterchanges.h"
#include "public.sdk/source/vst/utility/stringconvert.h"
#include "public.sdk/source/vst/utility/uid.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>

#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#elif defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

// MARK: - ABI レイアウトの固定(Swift 側 VST3CABI の定数と一致させる)

static_assert(sizeof(MCVST3Setup) == 32, "MCVST3Setup layout drift");
static_assert(offsetof(MCVST3Setup, sampleRate) == 8, "MCVST3Setup.sampleRate offset drift");
static_assert(offsetof(MCVST3Setup, maxSamplesPerBlock) == 16, "MCVST3Setup.maxSamples offset drift");
static_assert(sizeof(MCVST3ParameterInfo) == 56, "MCVST3ParameterInfo layout drift");
static_assert(offsetof(MCVST3ParameterInfo, title) == 8, "MCVST3ParameterInfo.title offset drift");
static_assert(offsetof(MCVST3ParameterInfo, defaultNormalizedValue) == 40, "MCVST3ParameterInfo.default offset drift");
static_assert(offsetof(MCVST3ParameterInfo, flags) == 48, "MCVST3ParameterInfo.flags offset drift");
static_assert(sizeof(MCVST3ParameterChange) == 16, "MCVST3ParameterChange layout drift");
static_assert(offsetof(MCVST3ParameterChange, normalizedValue) == 8, "MCVST3ParameterChange.value offset drift");
static_assert(sizeof(MCVST3ProcessRequest) == 48, "MCVST3ProcessRequest layout drift");
static_assert(offsetof(MCVST3ProcessRequest, inputs) == 8, "MCVST3ProcessRequest.inputs offset drift");
static_assert(offsetof(MCVST3ProcessRequest, outLatencySamples) == 40, "MCVST3ProcessRequest.latency offset drift");
static_assert(sizeof(MCVST3ClassInfo) == 72, "MCVST3ClassInfo layout drift");
static_assert(offsetof(MCVST3ClassInfo, cidHex) == 32, "MCVST3ClassInfo.cidHex offset drift");
static_assert(sizeof(MCVST3EditorSize) == 8, "MCVST3EditorSize layout drift");
static_assert(offsetof(MCVST3EditorSize, width) == 0, "MCVST3EditorSize.width offset drift");
static_assert(offsetof(MCVST3EditorSize, height) == 4, "MCVST3EditorSize.height offset drift");

namespace {

using namespace Steinberg;
using namespace Steinberg::Vst;

// MARK: - 小物

// SDK の ParameterInfo.flags(実値: bypass=1<<16, programChange=1<<15, hidden=1<<4)を
// MovieCut ABI のビット割当(ヘッダ参照: bit4=bypass, bit5=programChange)へ変換する。
// hidden は自動生成 UI に出さないため readOnly ビットも立てる。
int32_t abiFlags(int32 sdkFlags) {
    int32_t out = 0;
    if (sdkFlags & ParameterInfo::kCanAutomate) out |= (1 << 0);
    if (sdkFlags & ParameterInfo::kIsReadOnly) out |= (1 << 1);
    if (sdkFlags & ParameterInfo::kIsWrapAround) out |= (1 << 2);
    if (sdkFlags & ParameterInfo::kIsList) out |= (1 << 3);
    if (sdkFlags & ParameterInfo::kIsBypass) out |= (1 << 4);
    if (sdkFlags & ParameterInfo::kIsProgramChange) out |= (1 << 5);
    if (sdkFlags & ParameterInfo::kIsHidden) out |= (1 << 1);
    return out;
}

MCVST3Status mapResult(tresult r) {
    if (r == kResultOk || r == kResultTrue) return MCVST3_OK;
    if (r == kNotImplemented) return MCVST3_NOT_IMPLEMENTED;
    if (r == kInvalidArgument) return MCVST3_INVALID_ARGUMENT;
    if (r == kResultFalse) return MCVST3_RESULT_FALSE;
    return MCVST3_INTERNAL_ERROR;
}

std::string utf8(const TChar* s) {
    if (!s) return {};
    return StringConvert::convert(s);
}

std::string cidHexOf(const TUID& cid) {
    // moduleinfo.json の CID 表記に合わせ、SDK 既定形式(プラットフォーム既定)で出す。
    return ::VST3::UID(cid).toString();
}

bool cidMatches(const TUID& cid, const char* wanted) {
    if (!wanted || !*wanted) return false;
    std::string want(wanted);
    auto eqFold = [](std::string a, std::string b) {
        auto up = [](std::string s) {
            for (auto& c : s) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
            return s;
        };
        return up(std::move(a)) == up(std::move(b));
    };
    if (eqFold(cidHexOf(cid), want)) return true;
    if (eqFold(::VST3::UID(cid).toString(false), want)) return true;
    if (eqFold(::VST3::UID(cid).toString(true), want)) return true;
    if (auto parsed = ::VST3::UID::fromString(want)) {
        if (std::memcmp(parsed->data(), cid, sizeof(TUID)) == 0) return true;
    }
    // 素の 16 バイトをそのまま 16 進にした表記
    if (want.size() == 32) {
        std::string raw;
        raw.reserve(32);
        char buf[3];
        for (int i = 0; i < 16; i++) {
            std::snprintf(buf, sizeof(buf), "%02X", static_cast<unsigned char>(cid[i]));
            raw += buf;
        }
        if (eqFold(raw, want)) return true;
    }
    return false;
}

SpeakerArrangement speakersOf(int32_t v) {
    switch (v) {
        case MCVST3_SPEAKERS_MONO: return SpeakerArr::kMono;
        case MCVST3_SPEAKERS_STEREO: return SpeakerArr::kStereo;
        case MCVST3_SPEAKERS_51: return SpeakerArr::k51;
        case MCVST3_SPEAKERS_71: return SpeakerArr::k71Cine;
        default: return SpeakerArr::kEmpty;
    }
}

// MARK: - IComponentHandler(最小実装: 編集通知は受け取るだけ)

class ComponentHandler final : public IComponentHandler {
public:
    ComponentHandler() { FUNKNOWN_CTOR }
    ~ComponentHandler() { FUNKNOWN_DTOR }
    tresult PLUGIN_API beginEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API performEdit(ParamID, ParamValue) override { return kResultOk; }
    tresult PLUGIN_API endEdit(ParamID) override { return kResultOk; }
    tresult PLUGIN_API restartComponent(int32) override { return kResultOk; }
    DECLARE_FUNKNOWN_METHODS
};
IMPLEMENT_FUNKNOWN_METHODS(ComponentHandler, IComponentHandler, IComponentHandler::iid)

// MARK: - IPlugFrame(エディタのリサイズ要求の受け口。インスタンスごとに 1 個)
//
// プラグインの resizeView をホストのコールバックへ橋渡しする。判定に必要な状態
// (editorView / コールバック)は MCVST3Instance 側にあるため、resizeView の本体は
// インスタンス定義の後ろで定義する。

class PlugFrameImpl final : public IPlugFrame {
public:
    explicit PlugFrameImpl(MCVST3Instance* o) : owner(o) { FUNKNOWN_CTOR }
    ~PlugFrameImpl() { FUNKNOWN_DTOR }
    tresult PLUGIN_API resizeView(IPlugView* view, ViewRect* newSize) override;
    DECLARE_FUNKNOWN_METHODS
    MCVST3Instance* owner;
};
IMPLEMENT_FUNKNOWN_METHODS(PlugFrameImpl, IPlugFrame, IPlugFrame::iid)

// MARK: - モジュール(バイナリ)のロード

struct ModuleHandle {
    void* lib = nullptr;               // dlopen ハンドル(Windows は HMODULE を格納)
    using FactoryProc = IPluginFactory* (PLUGIN_API*) ();
    FactoryProc factoryProc = nullptr;
#if defined(__APPLE__)
    CFBundleRef bundleRef = nullptr;
    bool bundleEntered = false;
    using BundleEntryProc = bool (*)(CFBundleRef);
    using BundleExitProc = void (*)();
    BundleEntryProc bundleEntry = nullptr;
    BundleExitProc bundleExit = nullptr;
#elif defined(_WIN32)
    using BoolProc = bool (*)();
    BoolProc initDll = nullptr;
    BoolProc exitDll = nullptr;
#else
    using ModuleEntryProc = bool (*)(void*);
    using ModuleExitProc = bool (*)();
    ModuleEntryProc moduleEntry = nullptr;
    ModuleExitProc moduleExit = nullptr;
#endif
    ~ModuleHandle() { unload(); }
    void unload() {
        if (!lib) return;
#if defined(__APPLE__)
        if (bundleExit) bundleExit();
        bundleExit = nullptr; bundleEntry = nullptr; bundleEntered = false;
        dlclose(lib);
        if (bundleRef) { CFRelease(bundleRef); bundleRef = nullptr; }
#elif defined(_WIN32)
        if (exitDll) exitDll();
        exitDll = nullptr; initDll = nullptr;
        FreeLibrary(static_cast<HMODULE>(lib));
#else
        if (moduleExit) moduleExit();
        moduleExit = nullptr; moduleEntry = nullptr;
        dlclose(lib);
#endif
        lib = nullptr; factoryProc = nullptr;
    }
};

// バンドルディレクトリから実行ファイルの場所を決める。ファイルパスならそのまま。
std::string resolveExecutable(const std::string& path, bool& isBundle) {
    std::error_code ec;
    isBundle = false;
    if (!std::filesystem::is_directory(path, ec)) return path;
    isBundle = true;
    namespace fs = std::filesystem;
#if defined(__APPLE__)
    fs::path dir = fs::path(path) / "Contents" / "MacOS";
#else
    // Linux の .vst3 は Contents/<arch>-linux/*.so、Windows は Contents/<arch>-win/*.vst3
    fs::path contents = fs::path(path) / "Contents";
    fs::path dir;
    if (fs::is_directory(contents, ec)) {
        for (auto& e : fs::directory_iterator(contents, ec)) {
            if (e.is_directory()) { dir = e.path(); break; }
        }
    }
#endif
    if (!dir.empty() && fs::is_directory(dir, ec)) {
        for (auto& e : fs::directory_iterator(dir, ec)) {
            if (e.is_regular_file()) return e.path().string();
        }
    }
    return {};
}

bool loadModule(const std::string& path, ModuleHandle& out) {
    bool isBundle = false;
    std::string exe = resolveExecutable(path, isBundle);
    if (exe.empty()) return false;
#if defined(_WIN32)
    HMODULE h = LoadLibraryExA(exe.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!h) return false;
    out.lib = h;
    out.factoryProc = reinterpret_cast<ModuleHandle::FactoryProc>(GetProcAddress(h, "GetPluginFactory"));
    out.initDll = reinterpret_cast<ModuleHandle::BoolProc>(GetProcAddress(h, "InitDll"));
    out.exitDll = reinterpret_cast<ModuleHandle::BoolProc>(GetProcAddress(h, "ExitDll"));
    if (out.initDll && !out.initDll()) { out.unload(); return false; }
#else
    void* h = dlopen(exe.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!h) return false;
    out.lib = h;
    out.factoryProc = reinterpret_cast<ModuleHandle::FactoryProc>(dlsym(h, "GetPluginFactory"));
#if defined(__APPLE__)
    out.bundleEntry = reinterpret_cast<ModuleHandle::BundleEntryProc>(dlsym(h, "bundleEntry"));
    out.bundleExit = reinterpret_cast<ModuleHandle::BundleExitProc>(dlsym(h, "bundleExit"));
    if (isBundle && out.bundleEntry) {
        CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
                                                     CFStringCreateWithCString(kCFAllocatorDefault, path.c_str(), kCFStringEncodingUTF8),
                                                     kCFURLPOSIXPathStyle, true);
        if (url) {
            out.bundleRef = CFBundleCreate(kCFAllocatorDefault, url);
            CFRelease(url);
        }
        if (!out.bundleEntry(out.bundleRef)) { out.unload(); return false; }
        out.bundleEntered = true;
    }
#else
    out.moduleEntry = reinterpret_cast<ModuleHandle::ModuleEntryProc>(dlsym(h, "ModuleEntry"));
    out.moduleExit = reinterpret_cast<ModuleHandle::ModuleExitProc>(dlsym(h, "ModuleExit"));
    if (out.moduleEntry && !out.moduleEntry(h)) { out.unload(); return false; }
#endif
#endif
    if (!out.factoryProc) { out.unload(); return false; }
    return true;
}

// ホストアプリケーションはプロセス内で 1 個(SDK の HostApplication は参照数が固定)。
HostApplication& hostApp() {
    static HostApplication app;
    return app;
}
ComponentHandler& componentHandler() {
    static ComponentHandler handler;
    return handler;
}

} // namespace

// MARK: - インスタンス実体

struct MCVST3Instance {
    ModuleHandle module;
    IPtr<IPluginFactory> factory;
    struct ClassEntry {
        TUID cid {};
        std::string category, name, vendor, version;
    };
    std::vector<ClassEntry> classes;

    IPtr<IComponent> component;
    IPtr<IAudioProcessor> processor;
    IPtr<IEditController> controller;
    IPtr<IConnectionPoint> componentCP, controllerCP;
    bool controllerSeparate = false;
    bool initialized = false;
    bool configured = false;
    bool active = false;
    bool processing = false;

    MCVST3Setup setup {0, 48000, 4096, MCVST3_SPEAKERS_STEREO, MCVST3_SPEAKERS_STEREO};
    int32 numInputBuses = 0, numOutputBuses = 0;
    std::vector<int32> inputChannels, outputChannels;  // バスごとのチャンネル数
    int64 framePosition = 0;

    // 取得呼び出しの間だけ有効な文字列の置き場
    std::string scratchA, scratchB, scratchC, scratchD;
    ParameterChanges paramChanges {64};
    EventList inputEvents {64}, outputEvents {64};
    ProcessContext context {};

    // エディタ(純正 GUI)状態(R5 キュー3)
    IPtr<IPlugView> editorView;
    void* editorParent = nullptr;                          // 親ビュー(NSView*。所有しない)
    MCVST3EditorResizeCallback resizeCallback = nullptr;   // ホストへのリサイズ橋渡し
    void* resizeContext = nullptr;
    PlugFrameImpl frame {this};
};

namespace {

// エディタを畳む。順序は removed() → setFrame(nullptr) → 解放(controller terminate より前に呼ぶこと)。
void destroyEditorInternal(MCVST3Instance* inst) {
    if (!inst) return;
    if (inst->editorView) {
        inst->editorView->removed();
        inst->editorView->setFrame(nullptr);
        inst->editorView = nullptr;
    }
    inst->editorParent = nullptr;
    inst->resizeCallback = nullptr;
    inst->resizeContext = nullptr;
}

tresult PLUGIN_API PlugFrameImpl::resizeView(IPlugView* view, ViewRect* newSize) {
    // 自分の view 以外・コールバック未登録・サイズ不明は断る(黙って受理しない)
    if (!owner || !newSize || !view || view != owner->editorView.get() || !owner->resizeCallback)
        return kResultFalse;
    int32_t accepted = owner->resizeCallback(owner->resizeContext, newSize->getWidth(), newSize->getHeight());
    return accepted == 1 ? kResultTrue : kResultFalse;
}

void teardownProcessor(MCVST3Instance* inst) {
    if (!inst) return;
    destroyEditorInternal(inst);  // view が残っていれば controller terminate より前に畳む
    if (inst->processing && inst->processor) inst->processor->setProcessing(false);
    inst->processing = false;
    if (inst->active && inst->component) inst->component->setActive(false);
    inst->active = false;
    if (inst->componentCP && inst->controllerCP) {
        inst->componentCP->disconnect(inst->controllerCP);
        inst->controllerCP->disconnect(inst->componentCP);
    }
    inst->componentCP = nullptr; inst->controllerCP = nullptr;
    if (inst->controllerSeparate && inst->controller) inst->controller->terminate();
    if (inst->initialized && inst->component) inst->component->terminate();
    inst->controller = nullptr; inst->processor = nullptr; inst->component = nullptr;
    inst->controllerSeparate = false; inst->initialized = false; inst->configured = false;
}

} // namespace

extern "C" {

// MARK: - 関数実装

MCVST3Status mcvst3_handshake(int32_t* outVersion) {
    if (!outVersion) return MCVST3_INVALID_ARGUMENT;
    *outVersion = MCVST3_PROTOCOL_VERSION;
    return MCVST3_OK;
}

MCVST3Status mcvst3_open_bundle(const char* bundlePathUTF8, MCVST3Instance** outInstance) {
    if (!bundlePathUTF8 || !*bundlePathUTF8 || !outInstance) return MCVST3_INVALID_ARGUMENT;
    *outInstance = nullptr;
    try {
        auto inst = std::make_unique<MCVST3Instance>();
        if (!loadModule(bundlePathUTF8, inst->module)) return MCVST3_NOT_FOUND;
        IPluginFactory* raw = inst->module.factoryProc();
        if (!raw) return MCVST3_INTERNAL_ERROR;
        inst->factory = owned(raw);
        if (auto f3 = U::cast<IPluginFactory3>(inst->factory)) f3->setHostContext(&hostApp());
        int32 count = inst->factory->countClasses();
        for (int32 i = 0; i < count; i++) {
            MCVST3Instance::ClassEntry e;
            PClassInfo info {};
            if (inst->factory->getClassInfo(i, &info) == kResultOk) {
                std::memcpy(e.cid, info.cid, sizeof(TUID));
                e.category = info.category;
                e.name = StringConvert::convert(info.name, 128);
            }
            PClassInfo2 info2 {};
            auto factory2 = U::cast<IPluginFactory2>(inst->factory);
            if (factory2 && factory2->getClassInfo2(i, &info2) == kResultOk) {
                if (e.name.empty()) e.name = StringConvert::convert(info2.name, 128);
                e.vendor = StringConvert::convert(info2.vendor, 128);
                e.version = StringConvert::convert(info2.version, 128);
            }
            inst->classes.push_back(std::move(e));
        }
        *outInstance = inst.release();
        return MCVST3_OK;
    } catch (...) {
        return MCVST3_INTERNAL_ERROR;
    }
}

MCVST3Status mcvst3_get_class_count(MCVST3Instance* instance, int32_t* outCount) {
    if (!instance || !outCount) return MCVST3_INVALID_ARGUMENT;
    *outCount = static_cast<int32_t>(instance->classes.size());
    return MCVST3_OK;
}

MCVST3Status mcvst3_get_class_info(MCVST3Instance* instance, int32_t index, MCVST3ClassInfo* outInfo) {
    if (!instance || !outInfo || index < 0 || index >= static_cast<int32_t>(instance->classes.size()))
        return MCVST3_INVALID_ARGUMENT;
    const auto& e = instance->classes[static_cast<size_t>(index)];
    instance->scratchA = e.category; instance->scratchB = e.name; instance->scratchC = e.vendor;
    instance->scratchD = e.version;
    outInfo->category = instance->scratchA.c_str();
    outInfo->name = instance->scratchB.c_str();
    outInfo->vendor = e.vendor.empty() ? nullptr : instance->scratchC.c_str();
    outInfo->version = e.version.empty() ? nullptr : instance->scratchD.c_str();
    std::string hex = cidHexOf(e.cid);
    std::memset(outInfo->cidHex, 0, sizeof(outInfo->cidHex));
    std::memcpy(outInfo->cidHex, hex.data(), std::min(hex.size(), sizeof(outInfo->cidHex) - 1));
    return MCVST3_OK;
}

MCVST3Status mcvst3_create_processor(MCVST3Instance* instance, const char* audioModuleCID) {
    if (!instance || !instance->factory) return MCVST3_INVALID_ARGUMENT;
    if (instance->component) return MCVST3_WRONG_STATE;
    try {
        // 対象クラス: CID 指定があれば一致する Audio Module Class、無ければ最初の Audio Module Class
        const MCVST3Instance::ClassEntry* target = nullptr;
        for (const auto& e : instance->classes) {
            if (e.category != kVstAudioEffectClass) continue;
            if (!audioModuleCID || !*audioModuleCID) { target = &e; break; }
            if (cidMatches(e.cid, audioModuleCID)) { target = &e; break; }
        }
        if (!target) return MCVST3_NOT_FOUND;

        void* obj = nullptr;
        tresult r = instance->factory->createInstance(target->cid, IComponent::iid, &obj);
        if (r != kResultOk || !obj) return mapResult(r);
        instance->component = owned(static_cast<IComponent*>(obj));
        instance->processor = U::cast<IAudioProcessor>(instance->component);
        if (!instance->processor) { teardownProcessor(instance); return MCVST3_NOT_IMPLEMENTED; }

        r = instance->component->initialize(&hostApp());
        if (r != kResultOk) { teardownProcessor(instance); return mapResult(r); }
        instance->initialized = true;
        instance->component->setIoMode(kOfflineProcessing);

        // コントローラ: 同一オブジェクトの場合と、別クラスの場合の両方に対応する
        instance->controller = U::cast<IEditController>(instance->component);
        if (!instance->controller) {
            TUID controllerCID {};
            if (instance->component->getControllerClassId(controllerCID) == kResultOk) {
                void* cobj = nullptr;
                if (instance->factory->createInstance(controllerCID, IEditController::iid, &cobj) == kResultOk && cobj) {
                    instance->controller = owned(static_cast<IEditController*>(cobj));
                    instance->controllerSeparate = true;
                    if (instance->controller->initialize(&hostApp()) != kResultOk) {
                        instance->controller = nullptr; instance->controllerSeparate = false;
                    }
                }
            }
        }
        if (instance->controller) {
            instance->controller->setComponentHandler(&componentHandler());
            // 状態の同期: コンポーネントの状態をコントローラへ渡す(接続点があればそちらも繋ぐ)
            MemoryStream stream;
            if (instance->component->getState(&stream) == kResultOk) {
                stream.seek(0, IBStream::kIBSeekSet, nullptr);
                instance->controller->setComponentState(&stream);
            }
            instance->componentCP = U::cast<IConnectionPoint>(instance->component);
            instance->controllerCP = U::cast<IConnectionPoint>(instance->controller);
            if (instance->componentCP && instance->controllerCP) {
                instance->componentCP->connect(instance->controllerCP);
                instance->controllerCP->connect(instance->componentCP);
            }
        }
        return MCVST3_OK;
    } catch (...) {
        teardownProcessor(instance);
        return MCVST3_INTERNAL_ERROR;
    }
}

MCVST3Status mcvst3_setup_processing(MCVST3Instance* instance, const MCVST3Setup* setup) {
    if (!instance || !setup || !instance->component || !instance->processor) return MCVST3_INVALID_ARGUMENT;
    if (instance->active) return MCVST3_WRONG_STATE;
    try {
        SpeakerArrangement wantIn = speakersOf(setup->inputSpeakers);
        SpeakerArrangement wantOut = speakersOf(setup->outputSpeakers);
        instance->numInputBuses = instance->component->getBusCount(kAudio, kInput);
        instance->numOutputBuses = instance->component->getBusCount(kAudio, kOutput);
        if (instance->numInputBuses < 1 || instance->numOutputBuses < 1) return MCVST3_RESULT_FALSE;

        std::vector<SpeakerArrangement> ins(static_cast<size_t>(instance->numInputBuses), SpeakerArr::kEmpty);
        std::vector<SpeakerArrangement> outs(static_cast<size_t>(instance->numOutputBuses), SpeakerArr::kEmpty);
        ins[0] = wantIn; outs[0] = wantOut;
        tresult r = instance->processor->setBusArrangements(ins.data(), instance->numInputBuses,
                                                             outs.data(), instance->numOutputBuses);
        // 受け入れられなかった場合、実際に確定した構成が要求と一致するときだけ続行する
        SpeakerArrangement gotIn = 0, gotOut = 0;
        instance->processor->getBusArrangement(kInput, 0, gotIn);
        instance->processor->getBusArrangement(kOutput, 0, gotOut);
        if (gotIn != wantIn || gotOut != wantOut) return MCVST3_RESULT_FALSE;
        if (r != kResultOk && r != kResultTrue) return mapResult(r);

        instance->inputChannels.assign(static_cast<size_t>(instance->numInputBuses), 0);
        instance->outputChannels.assign(static_cast<size_t>(instance->numOutputBuses), 0);
        for (int32 i = 0; i < instance->numInputBuses; i++) {
            BusInfo bi {};
            if (instance->component->getBusInfo(kAudio, kInput, i, bi) == kResultOk) instance->inputChannels[static_cast<size_t>(i)] = bi.channelCount;
        }
        for (int32 i = 0; i < instance->numOutputBuses; i++) {
            BusInfo bi {};
            if (instance->component->getBusInfo(kAudio, kOutput, i, bi) == kResultOk) instance->outputChannels[static_cast<size_t>(i)] = bi.channelCount;
        }
        instance->component->activateBus(kAudio, kInput, 0, true);
        instance->component->activateBus(kAudio, kOutput, 0, true);

        if (instance->processor->canProcessSampleSize(kSample32) != kResultOk) return MCVST3_NOT_IMPLEMENTED;
        ProcessSetup ps {};
        ps.processMode = setup->processingMode == 2 ? kOffline : (setup->processingMode == 1 ? kPrefetch : kRealtime);
        ps.symbolicSampleSize = kSample32;
        ps.maxSamplesPerBlock = setup->maxSamplesPerBlock;
        ps.sampleRate = setup->sampleRate;
        r = instance->processor->setupProcessing(ps);
        if (r != kResultOk) return mapResult(r);
        instance->setup = *setup;
        instance->configured = true;
        instance->framePosition = 0;
        return MCVST3_OK;
    } catch (...) {
        return MCVST3_INTERNAL_ERROR;
    }
}

MCVST3Status mcvst3_set_active(MCVST3Instance* instance, int32_t active) {
    if (!instance || !instance->component || !instance->processor) return MCVST3_INVALID_ARGUMENT;
    if (!instance->configured) return MCVST3_WRONG_STATE;
    try {
        if (active) {
            if (instance->active) return MCVST3_OK;
            tresult r = instance->component->setActive(true);
            if (std::getenv("MCVST3_BRIDGE_DEBUG")) std::fprintf(stderr, "[mcvst3] setActive -> %d\n", static_cast<int>(r));
            if (r != kResultOk) return mapResult(r);
            instance->active = true;
            r = instance->processor->setProcessing(true);
            if (std::getenv("MCVST3_BRIDGE_DEBUG")) std::fprintf(stderr, "[mcvst3] setProcessing -> %d\n", static_cast<int>(r));
            // SDK の AudioEffect 既定実装は setProcessing で kNotImplemented を返す
            // (AGain 等の公式サンプルも未実装)。ホストはこれを許容するのが通例。
            if (r != kResultOk && r != kNotImplemented) { instance->component->setActive(false); instance->active = false; return mapResult(r); }
            instance->processing = true;
            instance->framePosition = 0;
            return MCVST3_OK;
        }
        if (instance->processing) instance->processor->setProcessing(false);
        instance->processing = false;
        if (instance->active) instance->component->setActive(false);
        instance->active = false;
        return MCVST3_OK;
    } catch (...) {
        return MCVST3_INTERNAL_ERROR;
    }
}

MCVST3Status mcvst3_process_block(MCVST3Instance* instance, const MCVST3ProcessRequest* request) {
    if (!instance || !request || !instance->processor) return MCVST3_INVALID_ARGUMENT;
    if (!instance->active || !instance->processing) return MCVST3_WRONG_STATE;
    if (request->numSamples <= 0 || !request->inputs || !request->outputs) return MCVST3_INVALID_ARGUMENT;
    try {
        const int32 frames = request->numSamples;
        // バスバッファ: メインは呼び出し側、その他のバスは無音入力/捨て出力で満たす
        std::vector<AudioBusBuffers> inBuses(static_cast<size_t>(instance->numInputBuses));
        std::vector<AudioBusBuffers> outBuses(static_cast<size_t>(instance->numOutputBuses));
        std::vector<std::vector<float>> silentIn, discardOut;
        std::vector<std::vector<float*>> inPtrs(static_cast<size_t>(instance->numInputBuses));
        std::vector<std::vector<float*>> outPtrs(static_cast<size_t>(instance->numOutputBuses));
        for (int32 b = 0; b < instance->numInputBuses; b++) {
            int32 ch = instance->inputChannels[static_cast<size_t>(b)];
            inBuses[static_cast<size_t>(b)].numChannels = ch;
            inPtrs[static_cast<size_t>(b)].assign(static_cast<size_t>(std::max(0, ch)), nullptr);
            if (b == 0) {
                for (int32 c = 0; c < ch; c++) inPtrs[0][static_cast<size_t>(c)] = request->inputs[c];
            } else if (ch > 0) {
                size_t idx = silentIn.size();
                silentIn.emplace_back(static_cast<size_t>(ch) * static_cast<size_t>(frames), 0.f);
                for (int32 c = 0; c < ch; c++) inPtrs[static_cast<size_t>(b)][static_cast<size_t>(c)] = silentIn[idx].data() + static_cast<size_t>(c) * frames;
            }
            inBuses[static_cast<size_t>(b)].channelBuffers32 = inPtrs[static_cast<size_t>(b)].data();
            inBuses[static_cast<size_t>(b)].silenceFlags = (b == 0) ? 0 : ~static_cast<uint64>(0);
        }
        for (int32 b = 0; b < instance->numOutputBuses; b++) {
            int32 ch = instance->outputChannels[static_cast<size_t>(b)];
            outBuses[static_cast<size_t>(b)].numChannels = ch;
            outPtrs[static_cast<size_t>(b)].assign(static_cast<size_t>(std::max(0, ch)), nullptr);
            if (b == 0) {
                for (int32 c = 0; c < ch; c++) outPtrs[0][static_cast<size_t>(c)] = request->outputs[c];
            } else if (ch > 0) {
                size_t idx = discardOut.size();
                discardOut.emplace_back(static_cast<size_t>(ch) * static_cast<size_t>(frames), 0.f);
                for (int32 c = 0; c < ch; c++) outPtrs[static_cast<size_t>(b)][static_cast<size_t>(c)] = discardOut[idx].data() + static_cast<size_t>(c) * frames;
            }
            outBuses[static_cast<size_t>(b)].channelBuffers32 = outPtrs[static_cast<size_t>(b)].data();
        }

        // パラメータ変化点
        instance->paramChanges.clearQueue();
        if (request->changes && request->changeCount > 0) {
            for (int32 i = 0; i < request->changeCount; i++) {
                const auto& ch = request->changes[i];
                int32 idx = -1;
                if (auto* q = instance->paramChanges.addParameterData(ch.parameterID, idx)) {
                    int32 pidx = -1;
                    q->addPoint(ch.sampleOffset, ch.normalizedValue, pidx);
                }
                if (instance->controller) instance->controller->setParamNormalized(ch.parameterID, ch.normalizedValue);
            }
        }

        instance->inputEvents.clear();
        instance->outputEvents.clear();
        std::memset(&instance->context, 0, sizeof(instance->context));
        instance->context.sampleRate = instance->setup.sampleRate;
        instance->context.projectTimeSamples = instance->framePosition;
        instance->context.tempo = 120.0;
        instance->context.timeSigNumerator = 4;
        instance->context.timeSigDenominator = 4;
        instance->context.state = ProcessContext::kPlaying | ProcessContext::kRecording;

        ProcessData data {};
        data.processMode = instance->setup.processingMode == 2 ? kOffline : (instance->setup.processingMode == 1 ? kPrefetch : kRealtime);
        data.symbolicSampleSize = kSample32;
        data.numSamples = frames;
        data.numInputs = instance->numInputBuses;
        data.numOutputs = instance->numOutputBuses;
        data.inputs = inBuses.data();
        data.outputs = outBuses.data();
        data.inputParameterChanges = &instance->paramChanges;
        data.outputParameterChanges = nullptr;
        data.inputEvents = &instance->inputEvents;
        data.outputEvents = &instance->outputEvents;
        data.processContext = &instance->context;

        tresult r = instance->processor->process(data);
        if (r != kResultOk) return mapResult(r);
        instance->framePosition += frames;
        if (request->outLatencySamples) *request->outLatencySamples = static_cast<int32_t>(instance->processor->getLatencySamples());
        return MCVST3_OK;
    } catch (...) {
        return MCVST3_INTERNAL_ERROR;
    }
}

MCVST3Status mcvst3_get_parameter_count(MCVST3Instance* instance, int32_t* outCount) {
    if (!instance || !outCount) return MCVST3_INVALID_ARGUMENT;
    if (!instance->controller) { *outCount = 0; return MCVST3_NOT_IMPLEMENTED; }
    *outCount = instance->controller->getParameterCount();
    return MCVST3_OK;
}

MCVST3Status mcvst3_get_parameter_info(MCVST3Instance* instance, int32_t index, MCVST3ParameterInfo* outInfo) {
    if (!instance || !outInfo || !instance->controller) return MCVST3_INVALID_ARGUMENT;
    ParameterInfo pi {};
    tresult r = instance->controller->getParameterInfo(index, pi);
    if (r != kResultOk) return mapResult(r);
    instance->scratchA = utf8(pi.title);
    instance->scratchB = utf8(pi.shortTitle);
    instance->scratchC = utf8(pi.units);
    outInfo->parameterID = pi.id;
    outInfo->title = instance->scratchA.c_str();
    outInfo->shortTitle = instance->scratchB.empty() ? nullptr : instance->scratchB.c_str();
    outInfo->units = instance->scratchC.empty() ? nullptr : instance->scratchC.c_str();
    outInfo->stepCount = pi.stepCount;
    outInfo->defaultNormalizedValue = pi.defaultNormalizedValue;
    outInfo->flags = abiFlags(pi.flags);
    return MCVST3_OK;
}

MCVST3Status mcvst3_get_parameter_normalized(MCVST3Instance* instance, uint32_t parameterID, double* outValue) {
    if (!instance || !outValue || !instance->controller) return MCVST3_INVALID_ARGUMENT;
    *outValue = instance->controller->getParamNormalized(parameterID);
    return MCVST3_OK;
}

MCVST3Status mcvst3_set_parameter_normalized(MCVST3Instance* instance, uint32_t parameterID, double value) {
    if (!instance || !instance->controller) return MCVST3_INVALID_ARGUMENT;
    double v = std::min(1.0, std::max(0.0, value));
    return mapResult(instance->controller->setParamNormalized(parameterID, v));
}

MCVST3Status mcvst3_get_latency_samples(MCVST3Instance* instance, int32_t* outLatency) {
    if (!instance || !outLatency || !instance->processor) return MCVST3_INVALID_ARGUMENT;
    *outLatency = static_cast<int32_t>(instance->processor->getLatencySamples());
    return MCVST3_OK;
}

MCVST3Status mcvst3_get_tail_samples(MCVST3Instance* instance, int32_t* outTail) {
    if (!instance || !outTail || !instance->processor) return MCVST3_INVALID_ARGUMENT;
    uint32 tail = instance->processor->getTailSamples();
    *outTail = tail == kInfiniteTail ? INT32_MAX : static_cast<int32_t>(tail);
    return MCVST3_OK;
}

MCVST3Status mcvst3_get_state(MCVST3Instance* instance, uint8_t* buffer, int32_t* ioLength) {
    if (!instance || !ioLength || !instance->component) return MCVST3_INVALID_ARGUMENT;
    try {
        MemoryStream stream;
        tresult r = instance->component->getState(&stream);
        if (r != kResultOk) return mapResult(r);
        int32_t size = static_cast<int32_t>(stream.getSize());
        if (!buffer || *ioLength < size) { *ioLength = size; return MCVST3_RESULT_FALSE; }
        std::memcpy(buffer, stream.getData(), static_cast<size_t>(size));
        *ioLength = size;
        return MCVST3_OK;
    } catch (...) {
        return MCVST3_INTERNAL_ERROR;
    }
}

MCVST3Status mcvst3_set_state(MCVST3Instance* instance, const uint8_t* buffer, int32_t length) {
    if (!instance || !buffer || length < 0 || !instance->component) return MCVST3_INVALID_ARGUMENT;
    if (instance->active) return MCVST3_WRONG_STATE;
    try {
        MemoryStream stream(const_cast<uint8_t*>(buffer), length);
        tresult r = instance->component->setState(&stream);
        if (r != kResultOk) return mapResult(r);
        if (instance->controller) {
            MemoryStream compStream;
            if (instance->component->getState(&compStream) == kResultOk) {
                compStream.seek(0, IBStream::kIBSeekSet, nullptr);
                instance->controller->setComponentState(&compStream);
            }
        }
        return MCVST3_OK;
    } catch (...) {
        return MCVST3_INTERNAL_ERROR;
    }
}

// MARK: - エディタ(純正 GUI。R5 キュー3)
//
// macOS の NSView 親だけを実装する。それ以外は NOT_IMPLEMENTED(Linux スモークを壊さない)。
// NSView の生成・ウィンドウ管理はホスト(アプリ)側。ここは IPlugView の橋渡しだけ。

#ifdef __APPLE__

MCVST3Status mcvst3_create_editor_view(MCVST3Instance* instance, void* parentView, void** outViewHandle) {
    if (outViewHandle) *outViewHandle = nullptr;
    if (!instance || !instance->controller || !parentView) return MCVST3_INVALID_ARGUMENT;
    if (instance->editorView) return MCVST3_WRONG_STATE;
    try {
        IPlugView* raw = instance->controller->createView(ViewType::kEditor);
        if (!raw) return MCVST3_NO_EDITOR;  // エディタを持たない(一般の失敗と区別)
        IPtr<IPlugView> view = owned(raw);
        if (view->isPlatformTypeSupported(kPlatformTypeNSView) != kResultTrue) return MCVST3_NOT_IMPLEMENTED;
        view->setFrame(&instance->frame);
        tresult r = view->attached(parentView, kPlatformTypeNSView);
        if (r != kResultOk && r != kResultTrue) {
            view->setFrame(nullptr);
            return mapResult(r);
        }
        instance->editorView = view;
        instance->editorParent = parentView;
        if (outViewHandle) *outViewHandle = static_cast<void*>(view.get());
        return MCVST3_OK;
    } catch (...) {
        return MCVST3_INTERNAL_ERROR;
    }
}

MCVST3Status mcvst3_get_editor_size(MCVST3Instance* instance, MCVST3EditorSize* outSize) {
    if (!instance || !outSize) return MCVST3_INVALID_ARGUMENT;
    if (!instance->editorView) return MCVST3_WRONG_STATE;
    try {
        ViewRect rect {};
        tresult r = instance->editorView->getSize(&rect);
        if (r != kResultOk && r != kResultTrue) return mapResult(r);
        outSize->width = rect.getWidth();
        outSize->height = rect.getHeight();
        return MCVST3_OK;
    } catch (...) {
        return MCVST3_INTERNAL_ERROR;
    }
}

MCVST3Status mcvst3_set_editor_size(MCVST3Instance* instance, const MCVST3EditorSize* size) {
    if (!instance || !size) return MCVST3_INVALID_ARGUMENT;
    if (!instance->editorView) return MCVST3_WRONG_STATE;
    if (size->width <= 0 || size->height <= 0) return MCVST3_INVALID_ARGUMENT;
    try {
        ViewRect rect(0, 0, size->width, size->height);
        // 確定サイズが丸められることがあるため、再取得は呼び出し側(get_editor_size)に委ねる
        return mapResult(instance->editorView->onSize(&rect));
    } catch (...) {
        return MCVST3_INTERNAL_ERROR;
    }
}

MCVST3Status mcvst3_destroy_editor_view(MCVST3Instance* instance) {
    if (!instance) return MCVST3_OK;  // 冪等
    try {
        destroyEditorInternal(instance);
        return MCVST3_OK;
    } catch (...) {
        return MCVST3_INTERNAL_ERROR;
    }
}

#else  // !__APPLE__

MCVST3Status mcvst3_create_editor_view(MCVST3Instance*, void*, void** outViewHandle) {
    if (outViewHandle) *outViewHandle = nullptr;
    return MCVST3_NOT_IMPLEMENTED;
}
MCVST3Status mcvst3_get_editor_size(MCVST3Instance*, MCVST3EditorSize*) { return MCVST3_NOT_IMPLEMENTED; }
MCVST3Status mcvst3_set_editor_size(MCVST3Instance*, const MCVST3EditorSize*) { return MCVST3_NOT_IMPLEMENTED; }
MCVST3Status mcvst3_destroy_editor_view(MCVST3Instance*) { return MCVST3_NOT_IMPLEMENTED; }

#endif

MCVST3Status mcvst3_set_editor_resize_callback(MCVST3Instance* instance, MCVST3EditorResizeCallback callback, void* context) {
#ifdef __APPLE__
    if (!instance) return MCVST3_INVALID_ARGUMENT;
    instance->resizeCallback = callback;
    instance->resizeContext = callback ? context : nullptr;
    return MCVST3_OK;
#else
    (void)instance; (void)callback; (void)context;
    return MCVST3_NOT_IMPLEMENTED;
#endif
}

void mcvst3_dispose(MCVST3Instance* instance) {
    if (!instance) return;
    try {
        teardownProcessor(instance);
        instance->factory = nullptr;
        delete instance;  // ModuleHandle のデストラクタでアンロードする
    } catch (...) {
        // 後片付けで例外を外へ出さない
    }
}

} // extern "C"
