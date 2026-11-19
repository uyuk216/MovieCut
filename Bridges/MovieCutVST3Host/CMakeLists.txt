# MovieCutVST3Bridge — VST3 C++ ブリッジ(W6-1)
#
# ABI の正は `docs/vst3-bridge/MovieCutVST3Bridge.h`。この CMake はその実装を
# 共有ライブラリ(libMovieCutVST3Bridge.dylib / .so)としてビルドする。
# アプリ本体(Package.swift)には組み込まない: アプリは実行時にこのライブラリを
# dlopen で探し、無ければ VST3 は従来どおりバイパスになる(安全境界)。
#
# 使い方:
#   cmake -S Bridges/MovieCutVST3Host -B /tmp/vst3bridge-build \
#         -DSDK_ROOT=/path/to/vst3sdk -DCMAKE_BUILD_TYPE=Release
#   cmake --build /tmp/vst3bridge-build
#
# SDK_ROOT は VST3 SDK 3.8 以降のルート(pluginterfaces/ base/ public.sdk/ を含む)。
# 環境変数 VST3_SDK_ROOT でも指定できる。SDK は MIT ライセンス(3.8〜)。
cmake_minimum_required(VERSION 3.25)
project(MovieCutVST3Bridge CXX)

if(NOT SDK_ROOT)
    set(SDK_ROOT "$ENV{VST3_SDK_ROOT}")
endif()
if(NOT SDK_ROOT)
    message(FATAL_ERROR "SDK_ROOT (or env VST3_SDK_ROOT) must point to the VST3 SDK 3.8+ root")
endif()
if(NOT EXISTS "${SDK_ROOT}/pluginterfaces/vst/ivstaudioprocessor.h")
    message(FATAL_ERROR "SDK_ROOT does not look like a VST3 SDK root: ${SDK_ROOT}")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(SDK_BASE_SOURCES
    ${SDK_ROOT}/pluginterfaces/base/coreiids.cpp
    ${SDK_ROOT}/pluginterfaces/base/funknown.cpp
    ${SDK_ROOT}/pluginterfaces/base/ustring.cpp
    ${SDK_ROOT}/pluginterfaces/base/conststringtable.cpp
    ${SDK_ROOT}/base/source/baseiids.cpp
    ${SDK_ROOT}/base/source/fbuffer.cpp
    ${SDK_ROOT}/base/source/fdebug.cpp
    ${SDK_ROOT}/base/source/fobject.cpp
    ${SDK_ROOT}/base/source/fstring.cpp
    ${SDK_ROOT}/base/source/fstreamer.cpp
    ${SDK_ROOT}/base/source/updatehandler.cpp
    ${SDK_ROOT}/base/source/timer.cpp
    ${SDK_ROOT}/base/thread/source/flock.cpp
    ${SDK_ROOT}/base/thread/source/fcondition.cpp
)
set(SDK_HOSTING_SOURCES
    ${SDK_ROOT}/public.sdk/source/common/commoniids.cpp
    ${SDK_ROOT}/public.sdk/source/common/commonstringconvert.cpp
    ${SDK_ROOT}/public.sdk/source/common/memorystream.cpp
    ${SDK_ROOT}/public.sdk/source/vst/hosting/eventlist.cpp
    ${SDK_ROOT}/public.sdk/source/vst/hosting/hostclasses.cpp
    ${SDK_ROOT}/public.sdk/source/vst/hosting/parameterchanges.cpp
    ${SDK_ROOT}/public.sdk/source/vst/hosting/pluginterfacesupport.cpp
    ${SDK_ROOT}/public.sdk/source/vst/utility/stringconvert.cpp
    ${SDK_ROOT}/public.sdk/source/vst/vstinitiids.cpp
)

add_library(MovieCutVST3Bridge SHARED
    MovieCutVST3Bridge.cpp
    ${SDK_BASE_SOURCES}
    ${SDK_HOSTING_SOURCES}
)
target_include_directories(MovieCutVST3Bridge PRIVATE ${SDK_ROOT})
target_compile_features(MovieCutVST3Bridge PRIVATE cxx_std_17)
if(APPLE)
    target_link_libraries(MovieCutVST3Bridge PRIVATE "-framework CoreFoundation" dl)
elseif(UNIX)
    target_link_libraries(MovieCutVST3Bridge PRIVATE dl pthread)
endif()
