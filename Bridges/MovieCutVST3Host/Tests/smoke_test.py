#!/usr/bin/env python3
"""VST3 ブリッジのスモークテスト(W6-1)。

使い方:
  python3 smoke_test.py <libMovieCutVST3Bridge.dylib|.so> <MovieCutGain.vst3>

ブリッジ ABI(docs/vst3-bridge/MovieCutVST3Bridge.h)だけを使って
handshake → open → class列挙 → create → param取得 → setup → active →
process(既定ゲイン0.75 / 変化点で0.5) → state往復 → dispose を検証する。
どれか失敗したら終了コード 1。
"""
import ctypes
import sys

OK = 0


class Setup(ctypes.Structure):
    _fields_ = [("mode", ctypes.c_int32), ("sampleRate", ctypes.c_double),
                ("maxBlock", ctypes.c_int32), ("inSpk", ctypes.c_int32), ("outSpk", ctypes.c_int32)]


class ParamInfo(ctypes.Structure):
    _fields_ = [("id", ctypes.c_uint32), ("title", ctypes.c_char_p), ("shortTitle", ctypes.c_char_p),
                ("units", ctypes.c_char_p), ("stepCount", ctypes.c_int32),
                ("defaultNormalized", ctypes.c_double), ("flags", ctypes.c_int32)]


class ClassInfo(ctypes.Structure):
    _fields_ = [("category", ctypes.c_char_p), ("name", ctypes.c_char_p),
                ("vendor", ctypes.c_char_p), ("version", ctypes.c_char_p),
                ("cidHex", ctypes.c_char * 33)]


class Change(ctypes.Structure):
    _fields_ = [("id", ctypes.c_uint32), ("offset", ctypes.c_int32), ("value", ctypes.c_double)]


class ProcessRequest(ctypes.Structure):
    _fields_ = [("numSamples", ctypes.c_int32), ("inputs", ctypes.POINTER(ctypes.POINTER(ctypes.c_float))),
                ("outputs", ctypes.POINTER(ctypes.POINTER(ctypes.c_float))),
                ("changes", ctypes.POINTER(Change)), ("changeCount", ctypes.c_int32),
                ("outLatency", ctypes.POINTER(ctypes.c_int32))]


def check(cond, label):
    print(("PASS" if cond else "FAIL"), label)
    if not cond:
        sys.exit(1)


def main():
    lib = ctypes.CDLL(sys.argv[1])
    bundle = sys.argv[2].encode()

    def fn(name, restype, *argtypes):
        f = getattr(lib, name)
        f.restype = restype
        f.argtypes = list(argtypes)
        return f

    P = ctypes.c_void_p
    handshake = fn("mcvst3_handshake", ctypes.c_int32, ctypes.POINTER(ctypes.c_int32))
    open_bundle = fn("mcvst3_open_bundle", ctypes.c_int32, ctypes.c_char_p, ctypes.POINTER(P))
    class_count = fn("mcvst3_get_class_count", ctypes.c_int32, P, ctypes.POINTER(ctypes.c_int32))
    class_info = fn("mcvst3_get_class_info", ctypes.c_int32, P, ctypes.c_int32, ctypes.POINTER(ClassInfo))
    create = fn("mcvst3_create_processor", ctypes.c_int32, P, ctypes.c_char_p)
    setup_fn = fn("mcvst3_setup_processing", ctypes.c_int32, P, ctypes.POINTER(Setup))
    set_active = fn("mcvst3_set_active", ctypes.c_int32, P, ctypes.c_int32)
    process = fn("mcvst3_process_block", ctypes.c_int32, P, ctypes.POINTER(ProcessRequest))
    param_count = fn("mcvst3_get_parameter_count", ctypes.c_int32, P, ctypes.POINTER(ctypes.c_int32))
    param_info = fn("mcvst3_get_parameter_info", ctypes.c_int32, P, ctypes.c_int32, ctypes.POINTER(ParamInfo))
    get_state = fn("mcvst3_get_state", ctypes.c_int32, P, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int32))
    set_state = fn("mcvst3_set_state", ctypes.c_int32, P, ctypes.c_void_p, ctypes.c_int32)
    dispose = getattr(lib, "mcvst3_dispose")
    dispose.restype = None
    dispose.argtypes = [P]

    version = ctypes.c_int32(0)
    check(handshake(ctypes.byref(version)) == OK and version.value == 1, f"handshake version={version.value}")

    inst = P()
    check(open_bundle(bundle, ctypes.byref(inst)) == OK and inst, "open_bundle")

    n = ctypes.c_int32(0)
    check(class_count(inst, ctypes.byref(n)) == OK and n.value >= 1, f"class count={n.value}")
    ci = ClassInfo()
    check(class_info(inst, 0, ctypes.byref(ci)) == OK, "class info")
    print("  class:", ci.category, ci.name, ci.cidHex)
    check(ci.category == b"Audio Module Class", "audio module class")

    check(create(inst, None) == OK, "create_processor (first audio class)")

    pc = ctypes.c_int32(0)
    check(param_count(inst, ctypes.byref(pc)) == OK and pc.value == 3, f"parameter count={pc.value}")
    titles = []
    for i in range(pc.value):
        pi = ParamInfo()
        check(param_info(inst, i, ctypes.byref(pi)) == OK, f"parameter info {i}")
        titles.append((pi.id, pi.title, pi.defaultNormalized, pi.stepCount, pi.flags))
    print("  params:", titles)
    check(titles[0][1] == b"Gain" and abs(titles[0][2] - 0.75) < 1e-9, "gain descriptor")

    setup = Setup(2, 48000.0, 4096, 2, 2)  # offline, 48k, stereo->stereo
    check(setup_fn(inst, ctypes.byref(setup)) == OK, "setup_processing")
    check(set_active(inst, 1) == OK, "set_active(1)")

    frames = 256
    def run_block(changes):
        in_l = (ctypes.c_float * frames)(*[0.5] * frames)
        in_r = (ctypes.c_float * frames)(*[-0.25] * frames)
        out_l = (ctypes.c_float * frames)()
        out_r = (ctypes.c_float * frames)()
        ins = (ctypes.POINTER(ctypes.c_float) * 2)(ctypes.cast(in_l, ctypes.POINTER(ctypes.c_float)),
                                                   ctypes.cast(in_r, ctypes.POINTER(ctypes.c_float)))
        outs = (ctypes.POINTER(ctypes.c_float) * 2)(ctypes.cast(out_l, ctypes.POINTER(ctypes.c_float)),
                                                    ctypes.cast(out_r, ctypes.POINTER(ctypes.c_float)))
        carr = (Change * len(changes))(*changes) if changes else None
        latency = ctypes.c_int32(-1)
        req = ProcessRequest(frames, ins, outs, carr, len(changes), ctypes.pointer(latency))
        st = process(inst, ctypes.byref(req))
        return st, list(out_l), list(out_r), latency.value

    st, ol, orr, lat = run_block([])
    check(st == OK and all(abs(v - 0.375) < 1e-6 for v in ol) and all(abs(v + 0.1875) < 1e-6 for v in orr),
          f"process default gain 0.75 (latency={lat})")
    st, ol, orr, _ = run_block([Change(0, 0, 0.5)])
    check(st == OK and all(abs(v - 0.25) < 1e-6 for v in ol), "process with gain change point 0.5")

    # 状態往復: いまの状態を取り出し、別インスタンスへ入れて同じ音になるか
    length = ctypes.c_int32(0)
    st = get_state(inst, None, ctypes.byref(length))
    check(st != OK and length.value > 0, f"get_state size query ({length.value} bytes)")
    buf = ctypes.create_string_buffer(length.value)
    check(get_state(inst, buf, ctypes.byref(length)) == OK, "get_state")

    check(set_active(inst, 0) == OK, "set_active(0)")
    dispose(inst)

    inst2 = P()
    check(open_bundle(bundle, ctypes.byref(inst2)) == OK, "open_bundle #2")
    check(create(inst2, ci.cidHex) == OK, "create_processor by CID hex")
    check(set_state(inst2, buf, length) == OK, "set_state")
    check(setup_fn(inst2, ctypes.byref(setup)) == OK, "setup #2")
    check(set_active(inst2, 1) == OK, "set_active #2")
    # 状態で gain=0.5 が復元されているので、変化点なしでも 0.5 倍になる
    # (process は inst2 に対して行うため、run_block の対象を差し替える)
    frames2 = frames
    in_l = (ctypes.c_float * frames2)(*[0.5] * frames2)
    in_r = (ctypes.c_float * frames2)(*[0.5] * frames2)
    out_l = (ctypes.c_float * frames2)()
    out_r = (ctypes.c_float * frames2)()
    ins = (ctypes.POINTER(ctypes.c_float) * 2)(ctypes.cast(in_l, ctypes.POINTER(ctypes.c_float)),
                                               ctypes.cast(in_r, ctypes.POINTER(ctypes.c_float)))
    outs = (ctypes.POINTER(ctypes.c_float) * 2)(ctypes.cast(out_l, ctypes.POINTER(ctypes.c_float)),
                                                ctypes.cast(out_r, ctypes.POINTER(ctypes.c_float)))
    latency = ctypes.c_int32(-1)
    req = ProcessRequest(frames2, ins, outs, None, 0, ctypes.pointer(latency))
    check(process(inst2, ctypes.byref(req)) == OK and all(abs(v - 0.25) < 1e-6 for v in out_l),
          "state roundtrip restores gain 0.5")
    dispose(inst2)
    print("ALL PASS")


if __name__ == "__main__":
    main()
