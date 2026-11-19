# MovieCutGain — 検証用フィクスチャ VST3(W6-1)
#
# SDK のビルドシステム(smtg_add_vst3plugin)を使わず、SDK ソースを直接リンクする
# 単独 CMake。理由: SDK 本体のフルビルド無しで、フィクスチャだけを再現可能に作るため。
# 出力は .vst3 バンドル(macOS: Contents/MacOS + Info.plist、Linux: Contents/x86_64-linux)。
#
# 使い方:
#   cmake -S Bridges/MovieCutVST3Host/Fixture/MovieCutGain -B /tmp/gain-build \
#         -DSDK_ROOT=/path/to/vst3sdk -DCMAKE_BUILD_TYPE=Release
#   cmake --build /tmp/gain-build
#   # → /tmp/gain-build/MovieCutGain.vst3 ができる
cmake_minimum_required(VERSION 3.25)
project(MovieCutGain CXX)

if(NOT SDK_ROOT)
    set(SDK_ROOT "$ENV{VST3_SDK_ROOT}")
endif()
if(NOT SDK_ROOT)
    message(FATAL_ERROR "SDK_ROOT (or env VST3_SDK_ROOT) must point to the VST3 SDK 3.8+ root")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(SDK_SOURCES
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
    ${SDK_ROOT}/public.sdk/source/common/commoniids.cpp
    ${SDK_ROOT}/public.sdk/source/main/pluginfactory.cpp
    ${SDK_ROOT}/public.sdk/source/vst/vstinitiids.cpp
    # SDK の sdk ターゲットと同じ組み合わせ(vsteditcontroller は
    # vstsinglecomponenteffect.cpp が内部で include するので二重に入れない)
    ${SDK_ROOT}/public.sdk/source/common/pluginview.cpp
    ${SDK_ROOT}/public.sdk/source/main/moduleinit.cpp
    ${SDK_ROOT}/public.sdk/source/vst/vstaudioeffect.cpp
    ${SDK_ROOT}/public.sdk/source/vst/vstbus.cpp
    ${SDK_ROOT}/public.sdk/source/vst/vstcomponent.cpp
    ${SDK_ROOT}/public.sdk/source/vst/vstcomponentbase.cpp
    ${SDK_ROOT}/public.sdk/source/vst/vstparameters.cpp
    ${SDK_ROOT}/public.sdk/source/vst/vstsinglecomponenteffect.cpp
)
if(APPLE)
    list(APPEND SDK_SOURCES ${SDK_ROOT}/public.sdk/source/main/macmain.cpp)
elseif(UNIX)
    list(APPEND SDK_SOURCES ${SDK_ROOT}/public.sdk/source/main/linuxmain.cpp)
else()
    list(APPEND SDK_SOURCES ${SDK_ROOT}/public.sdk/source/main/dllmain.cpp)
endif()

add_library(MovieCutGain MODULE MovieCutGain.cpp MovieCutGainEntry.cpp ${SDK_SOURCES})
target_include_directories(MovieCutGain PRIVATE ${SDK_ROOT} ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_features(MovieCutGain PRIVATE cxx_std_17)
set_target_properties(MovieCutGain PROPERTIES PREFIX "" OUTPUT_NAME "MovieCutGain")
if(APPLE)
    set_target_properties(MovieCutGain PROPERTIES SUFFIX "")
    target_link_libraries(MovieCutGain PRIVATE "-framework CoreFoundation" "-framework CoreGraphics")
elseif(UNIX)
    set_target_properties(MovieCutGain PROPERTIES SUFFIX ".so")
    target_link_libraries(MovieCutGain PRIVATE dl pthread)
endif()

# .vst3 バンドルとして並べる
set(BUNDLE_DIR "${CMAKE_BINARY_DIR}/MovieCutGain.vst3")
if(APPLE)
    set(BIN_DIR "${BUNDLE_DIR}/Contents/MacOS")
else()
    set(BIN_DIR "${BUNDLE_DIR}/Contents/x86_64-linux")
endif()
add_custom_command(TARGET MovieCutGain POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${BIN_DIR}"
    COMMAND ${CMAKE_COMMAND} -E copy "$<TARGET_FILE:MovieCutGain>" "${BIN_DIR}/"
    COMMENT "Assembling MovieCutGain.vst3")
if(APPLE)
    add_custom_command(TARGET MovieCutGain POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist" "${BUNDLE_DIR}/Contents/Info.plist"
        COMMAND ${CMAKE_COMMAND} -E echo "APPL" > "${BUNDLE_DIR}/Contents/PkgInfo")
endif()
