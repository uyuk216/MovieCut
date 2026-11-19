/* MovieCutVST3Bridge.h
 *
 * VST3 C++ ブリッジの ABI 定義(R5-1 で「インターフェース定義まで」を前進させたもの)。
 *
 * W6-1 で実装を追加した: 実体は `Bridges/MovieCutVST3Host/MovieCutVST3Bridge.cpp`
 * (CMake で共有ライブラリ `libMovieCutVST3Bridge` としてビルドし、アプリ側は
 * dlopen で動的に読む。Package.swift には C++ ターゲットを足さない)。
 * Swift 側の対応定義(Sources/MovieCutCore/Plugins/VST3Bridge.swift /
 * VST3NativeBridge.swift)と番号・並び・構造体レイアウトを一致させ続けること
 * (単体テストが Swift 側の対応を固定し、C++ 側は static_assert でレイアウトを固定する)。
 * 既存の opcode / status / 構造体の番号・並びは変更しない。追加は末尾の
 * 「追加関数(W6-1)」だけ(opcode 表には載せない直接呼び出し)。
 *
 * 方針:
 * - プラグインの生成・破棄はすべてブリッジ側。Swift 側は不透明ハンドルだけを持つ。
 * - 失敗はすべて MCVST3Status で返し、例外は境界を越えない。
 * - 処理はオフライン前提(締切なし)。バッファは Float32、左右分離ではなく
 *   チャンネル配列(ポインタの配列)で渡す。
 */
#ifndef MOVIECUT_VST3_BRIDGE_H
#define MOVIECUT_VST3_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* プロトコルの版数。Swift 側 VST3Bridge.protocolVersion と一致させる。 */
#define MCVST3_PROTOCOL_VERSION 1

/* 操作コード。Swift 側 VST3BridgeOpcode と同順・同値。 */
typedef enum MCVST3Opcode {
    MCVST3_OP_HANDSHAKE = 0,
    MCVST3_OP_OPEN_BUNDLE = 1,
    MCVST3_OP_CREATE_PROCESSOR = 2,
    MCVST3_OP_SETUP_PROCESSING = 3,
    MCVST3_OP_SET_ACTIVE = 4,
    MCVST3_OP_PROCESS_BLOCK = 5,
    MCVST3_OP_GET_PARAMETER_INFOS = 6,
    MCVST3_OP_GET_STATE = 7,
    MCVST3_OP_SET_STATE = 8,
    MCVST3_OP_DISPOSE = 9
} MCVST3Opcode;

/* 結果コード。Swift 側 VST3BridgeStatus と同順・同値。0 以外は呼び出し側がバイパスに落とす。 */
typedef enum MCVST3Status {
    MCVST3_OK = 0,
    MCVST3_RESULT_FALSE = 1,
    MCVST3_INVALID_ARGUMENT = 2,
    MCVST3_NOT_IMPLEMENTED = 3,
    MCVST3_INTERNAL_ERROR = 4,
    MCVST3_NOT_FOUND = 5,
    MCVST3_WRONG_STATE = 6
} MCVST3Status;

/* スピーカー配置。Swift 側 VST3SpeakerArrangement のチャンネル数と対応する。 */
typedef enum MCVST3SpeakerArrangement {
    MCVST3_SPEAKERS_EMPTY = 0,
    MCVST3_SPEAKERS_MONO = 1,
    MCVST3_SPEAKERS_STEREO = 2,
    MCVST3_SPEAKERS_51 = 6,
    MCVST3_SPEAKERS_71 = 8
} MCVST3SpeakerArrangement;

/* setupProcessing の確定内容。Swift 側 VST3ProcessSetup と対応する。 */
typedef struct MCVST3Setup {
    int32_t processingMode;      /* 0 = realtime, 1 = prefetch, 2 = offline */
    double sampleRate;           /* MovieCut は 48000 */
    int32_t maxSamplesPerBlock;  /* この範囲内でブロックを切る */
    int32_t inputSpeakers;       /* MCVST3SpeakerArrangement */
    int32_t outputSpeakers;      /* MCVST3SpeakerArrangement */
} MCVST3Setup;

/* パラメータ記述 1 件。Swift 側 VST3ParameterDescriptor と対応する。
 * 文字列はブリッジ側のバッファへのポインタで、取得呼び出しの間だけ有効。 */
typedef struct MCVST3ParameterInfo {
    uint32_t parameterID;
    const char *title;
    const char *shortTitle;      /* 無ければ NULL */
    const char *units;           /* 無ければ NULL */
    int32_t stepCount;           /* 0 = 連続、1 = トグル */
    double defaultNormalizedValue;
    int32_t flags;               /* bit0 canAutomate, bit1 readOnly, bit2 wrapAround,
                                    bit3 list, bit4 bypass, bit5 programChange */
} MCVST3ParameterInfo;

/* パラメータ変化点 1 件。Swift 側 VST3ParameterChangePoint と対応する。 */
typedef struct MCVST3ParameterChange {
    uint32_t parameterID;
    int32_t sampleOffset;
    double normalizedValue;
} MCVST3ParameterChange;

/* 1 ブロックの処理要求。Swift 側で検証済みの形状だけが渡される前提。 */
typedef struct MCVST3ProcessRequest {
    int32_t numSamples;
    float **inputs;              /* [inputChannels][numSamples] */
    float **outputs;             /* [outputChannels][numSamples] */
    const MCVST3ParameterChange *changes;
    int32_t changeCount;
    int32_t *outLatencySamples;  /* 処理後に申告レイテンシを返す(不要なら NULL) */
} MCVST3ProcessRequest;

/* 不透明ハンドル。実体はブリッジ側だけが知る。 */
typedef struct MCVST3Instance MCVST3Instance;

/* --- 関数宣言(実装は実ホスト工程。ここには宣言だけを置く) --- */

/* 版数の照合。*outVersion に MCVST3_PROTOCOL_VERSION を返す。 */
MCVST3Status mcvst3_handshake(int32_t *outVersion);

/* バンドルを開く(クラス列挙まで。音声処理はまだしない)。 */
MCVST3Status mcvst3_open_bundle(const char *bundlePathUTF8, MCVST3Instance **outInstance);

/* 音声プロセッサを生成する。audioModuleCID は 32 桁 16 進文字列。 */
MCVST3Status mcvst3_create_processor(MCVST3Instance *instance, const char *audioModuleCID);

/* バス構成と setup を確定する。 */
MCVST3Status mcvst3_setup_processing(MCVST3Instance *instance, const MCVST3Setup *setup);

/* 有効化/無効化。active != 0 で有効化。 */
MCVST3Status mcvst3_set_active(MCVST3Instance *instance, int32_t active);

/* 1 ブロック処理する。 */
MCVST3Status mcvst3_process_block(MCVST3Instance *instance, const MCVST3ProcessRequest *request);

/* パラメータ記述の件数と内容を取得する(2 段階: まず件数、次に配列)。 */
MCVST3Status mcvst3_get_parameter_count(MCVST3Instance *instance, int32_t *outCount);
MCVST3Status mcvst3_get_parameter_info(MCVST3Instance *instance, int32_t index, MCVST3ParameterInfo *outInfo);

/* 状態チャンクの取得/復元(プロジェクト保存用。バイト列は呼び出し側バッファへ)。 */
MCVST3Status mcvst3_get_state(MCVST3Instance *instance, uint8_t *buffer, int32_t *ioLength);
MCVST3Status mcvst3_set_state(MCVST3Instance *instance, const uint8_t *buffer, int32_t length);

/* 後片付け(生成の逆順)。NULL は無視する。 */
void mcvst3_dispose(MCVST3Instance *instance);

/* --- 追加関数(W6-1。opcode 表には載せない直接呼び出し) --- */

/* クラス情報 1 件。文字列はブリッジ側のバッファへのポインタで、取得呼び出しの間だけ有効。
 * cidHex は 32 桁 16 進 + NUL の固定バッファ(moduleinfo.json の CID と同じ表記を狙う)。 */
typedef struct MCVST3ClassInfo {
    const char *category;        /* 例: "Audio Module Class" */
    const char *name;
    const char *vendor;          /* 無ければ NULL */
    const char *version;         /* 無ければ NULL */
    char cidHex[33];
} MCVST3ClassInfo;

/* バンドル内のクラス列挙(open_bundle の後、create_processor の前でも後でも可)。 */
MCVST3Status mcvst3_get_class_count(MCVST3Instance *instance, int32_t *outCount);
MCVST3Status mcvst3_get_class_info(MCVST3Instance *instance, int32_t index, MCVST3ClassInfo *outInfo);

/* パラメータの現在値の取得/設定(正規化値)。設定はコントローラ経由で、次回 process の
 * 変化点としても渡される想定。create_processor の後で有効。 */
MCVST3Status mcvst3_get_parameter_normalized(MCVST3Instance *instance, uint32_t parameterID, double *outValue);
MCVST3Status mcvst3_set_parameter_normalized(MCVST3Instance *instance, uint32_t parameterID, double value);

/* プラグイン申告のレイテンシ/テール(フレーム)。setup_processing の後で有効。 */
MCVST3Status mcvst3_get_latency_samples(MCVST3Instance *instance, int32_t *outLatency);
MCVST3Status mcvst3_get_tail_samples(MCVST3Instance *instance, int32_t *outTail);

#ifdef __cplusplus
}
#endif

#endif /* MOVIECUT_VST3_BRIDGE_H */
