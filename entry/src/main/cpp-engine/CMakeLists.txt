cmake_minimum_required(VERSION 3.16)
project(MuseScoreOHEngine)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC OFF)
set(CMAKE_AUTORCC OFF)
set(CMAKE_AUTOUIC OFF)

# ═══════════════════════════════════════════════════════════════════════════
# Pure CMake auto-setup. A fresh clone + `devecocli build` is enough:
#   .deps/            MuseScore source, 3rd-party, Qt kits (gitignored)
#   build-engraving/  engraving_cross static lib per ABI   (gitignored)
#   entry/libs/<abi>/ Qt .so shipped in the hap            (gitignored)
#   generated/        rcc resource cpps                    (gitignored)
# First build: downloads ~500MB, builds Qt x86_64 (~60 min, emulator only)
# and engraving (~15 min per ABI). Subsequent builds skip all of it.
# ═══════════════════════════════════════════════════════════════════════════

# ─── 1. Dependency root: <repo>/.deps (override with MSOH_DEPS_ROOT env) ───
get_filename_component(MSOH_REPO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../.." ABSOLUTE)
if(DEFINED ENV{MSOH_DEPS_ROOT})
    set(MSOH_DEPS_ROOT "$ENV{MSOH_DEPS_ROOT}")
else()
    set(MSOH_DEPS_ROOT "${MSOH_REPO_ROOT}/.deps")
endif()
string(REPLACE "\\" "/" MSOH_DEPS_ROOT "${MSOH_DEPS_ROOT}")
message(STATUS "[msoh] deps root: ${MSOH_DEPS_ROOT}")

# ─── 2. OHOS NDK toolchain + ninja (used by the Qt-x64 and engraving builds) ───
if(NOT OHOS_SDK_NATIVE)
    if(DEFINED ENV{OHOS_SDK_NATIVE})
        set(OHOS_SDK_NATIVE "$ENV{OHOS_SDK_NATIVE}")
    elseif(DEFINED ENV{DEVECO_SDK})
        set(OHOS_SDK_NATIVE "$ENV{DEVECO_SDK}/native")
    else()
        set(OHOS_SDK_NATIVE "C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native")
    endif()
endif()
string(REPLACE "\\" "/" OHOS_SDK_NATIVE "${OHOS_SDK_NATIVE}")
set(MSOH_TOOLCHAIN "${OHOS_SDK_NATIVE}/build/cmake/ohos.toolchain.cmake")
if(NOT EXISTS "${MSOH_TOOLCHAIN}")
    message(FATAL_ERROR "ohos.toolchain.cmake not found at: ${MSOH_TOOLCHAIN}")
endif()
if(NOT CMAKE_MAKE_PROGRAM)
    set(CMAKE_MAKE_PROGRAM "${OHOS_SDK_NATIVE}/build-tools/cmake/bin/ninja.exe")
endif()

# ─── 3. Helpers ───
# Downloads go through curl with resume (-C -): the GitHub links are slow
# from CN networks and file(DOWNLOAD) restarts from zero on every failure.
set(MSOH_CURL "")
foreach(_c "C:/Windows/System32/curl.exe" "/usr/bin/curl" "curl")
    if(MSOH_CURL STREQUAL "" AND EXISTS "${_c}")
        set(MSOH_CURL "${_c}")
    endif()
endforeach()

function(msoh_download URL DEST_FILE)
    if(EXISTS "${DEST_FILE}")
        return()
    endif()
    message(STATUS "  ↓ ${URL}")
    if(NOT MSOH_CURL STREQUAL "")
        set(_try 0)
        while(NOT EXISTS "${DEST_FILE}" AND _try LESS 15)
            math(EXPR _try "${_try} + 1")
            execute_process(
                COMMAND "${MSOH_CURL}" -L --fail -sS -C -
                    --connect-timeout 20 --speed-limit 1024 --speed-time 60
                    -o "${DEST_FILE}.part" "${URL}"
                RESULT_VARIABLE _rc)
            if(_rc EQUAL 0)
                file(RENAME "${DEST_FILE}.part" "${DEST_FILE}")
            else()
                message(STATUS "  download retry ${_try}/15 (curl rc=${_rc})")
                execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 3)
            endif()
        endwhile()
        if(NOT EXISTS "${DEST_FILE}")
            file(REMOVE "${DEST_FILE}.part")
            message(FATAL_ERROR "download failed after 15 tries: ${URL}")
        endif()
    else()
        set(_try 0)
        while(NOT EXISTS "${DEST_FILE}" AND _try LESS 5)
            math(EXPR _try "${_try} + 1")
            file(DOWNLOAD "${URL}" "${DEST_FILE}"
                INACTIVITY_TIMEOUT 120 TIMEOUT 900 STATUS _st)
            if(NOT _st EQUAL 0)
                message(STATUS "  download failed (${_try}/5): ${_st}")
                file(REMOVE "${DEST_FILE}")
                execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 3)
            endif()
        endwhile()
        if(NOT EXISTS "${DEST_FILE}")
            message(FATAL_ERROR "download failed after 5 tries: ${URL}")
        endif()
    endif()
endfunction()

# 7-Zip: required for Qt kit archives (.7z) and all tarball extraction.
# (DevEco's cmake -E tar does not support --strip-components and leaks into
# the msys tar on PATH, so everything goes through 7z instead.)
# NB: find_program is blocked by the toolchain's FIND_ROOT_PATH ONLY mode,
# so probe known install locations directly.
set(SEVENZIP "")
foreach(_c "$ENV{ProgramFiles}/7-Zip/7z.exe"
           "$ENV{ProgramW6432}/7-Zip/7z.exe"
           "C:/Program Files/7-Zip/7z.exe")
    if(SEVENZIP STREQUAL "" AND EXISTS "${_c}")
        set(SEVENZIP "${_c}")
    endif()
endforeach()

function(msoh_7z_extract ARCHIVE DEST_DIR)
    # extracts archive contents into DEST_DIR (which may already exist)
    if(NOT SEVENZIP)
        message(FATAL_ERROR "7-Zip not found (needed for ${ARCHIVE}). Install from https://www.7-zip.org/")
    endif()
    set(_tmp "${DEST_DIR}/.msoh-7z-tmp")
    file(REMOVE_RECURSE "${_tmp}")
    file(MAKE_DIRECTORY "${_tmp}")
    execute_process(COMMAND "${SEVENZIP}" x -y "-o${_tmp}" "${ARCHIVE}"
        RESULT_VARIABLE _rc OUTPUT_QUIET)
    if(NOT _rc EQUAL 0)
        file(REMOVE_RECURSE "${_tmp}")
        message(FATAL_ERROR "7z extract failed: ${ARCHIVE}")
    endif()
    file(COPY "${_tmp}/" DESTINATION "${DEST_DIR}")
    file(REMOVE_RECURSE "${_tmp}")
endfunction()

# Extract a tarball (single top-level dir) into DEST_DIR via two 7z passes.
function(msoh_extract ARCHIVE DEST_DIR)
    if(EXISTS "${DEST_DIR}")
        return()
    endif()
    if(NOT SEVENZIP)
        message(FATAL_ERROR "7-Zip not found (needed for ${ARCHIVE}). Install from https://www.7-zip.org/")
    endif()
    set(_tmp "${DEST_DIR}.staging")
    file(REMOVE_RECURSE "${_tmp}")
    file(MAKE_DIRECTORY "${_tmp}")
    get_filename_component(_ext "${ARCHIVE}" LAST_EXT)
    set(_inner_dir "${_tmp}")
    if(_ext MATCHES "^[.](xz|gz|tgz|bz2)$")
        execute_process(COMMAND "${SEVENZIP}" x -y "-o${_tmp}" "${ARCHIVE}"
            RESULT_VARIABLE _rc OUTPUT_QUIET)
        if(NOT _rc EQUAL 0)
            file(REMOVE_RECURSE "${_tmp}")
            message(FATAL_ERROR "Extract pass 1 failed: ${ARCHIVE}")
        endif()
        file(GLOB _tar "${_tmp}/*.tar")
        list(LENGTH _tar _ntar)
        if(NOT _ntar EQUAL 1)
            file(REMOVE_RECURSE "${_tmp}")
            message(FATAL_ERROR "Extract failed (expected 1 inner .tar): ${ARCHIVE}")
        endif()
        set(_inner_dir "${_tmp}/inner")
        file(MAKE_DIRECTORY "${_inner_dir}")
        set(_inner_arc "${_tar}")
    endif()
    if(DEFINED _inner_arc)
        execute_process(COMMAND "${SEVENZIP}" x -y "-o${_inner_dir}" "${_inner_arc}"
            RESULT_VARIABLE _rc OUTPUT_QUIET)
    else()
        execute_process(COMMAND "${SEVENZIP}" x -y "-o${_inner_dir}" "${ARCHIVE}"
            RESULT_VARIABLE _rc OUTPUT_QUIET)
    endif()
    if(NOT _rc EQUAL 0)
        file(REMOVE_RECURSE "${_tmp}")
        message(FATAL_ERROR "Extract pass 2 failed: ${ARCHIVE}")
    endif()
    file(GLOB _top "${_inner_dir}/*")
    list(LENGTH _top _ntop)
    if(NOT _ntop EQUAL 1)
        file(REMOVE_RECURSE "${_tmp}")
        message(FATAL_ERROR "Extract failed (expected 1 top-level entry, got ${_ntop}): ${ARCHIVE}")
    endif()
    file(RENAME "${_top}" "${DEST_DIR}")
    file(REMOVE_RECURSE "${_tmp}")
endfunction()

function(msoh_fetch URL FNAME DNAME)
    if(NOT IS_ABSOLUTE "${DNAME}")
        set(DNAME "${DEPS_DIR}/${DNAME}")
    endif()
    if(EXISTS "${DNAME}")
        return()
    endif()
    set(_a "${MSOH_DEPS_ROOT}/.dl-${FNAME}")
    msoh_download("${URL}" "${_a}")
    msoh_extract("${_a}" "${DNAME}")
    file(REMOVE "${_a}")
endfunction()

function(msoh_patch FILE_PATH OLD_TEXT NEW_TEXT)
    if(NOT EXISTS "${FILE_PATH}")
        return()
    endif()
    file(READ "${FILE_PATH}" _c)
    string(FIND "${_c}" "${NEW_TEXT}" _n)
    if(NOT _n EQUAL -1)
        return() # already patched
    endif()
    string(FIND "${_c}" "${OLD_TEXT}" _o)
    if(_o EQUAL -1)
        return() # anchor gone, skip
    endif()
    string(REPLACE "${OLD_TEXT}" "${NEW_TEXT}" _p "${_c}")
    file(WRITE "${FILE_PATH}" "${_p}")
endfunction()

# hvigor configures both ABIs in parallel; serialize every section that
# touches shared state (.deps downloads, source patching, generated/qrc).
# GUARD PROCESS = the OS releases the lock even if this cmake is killed.
set(MSOH_LOCK "${MSOH_DEPS_ROOT}/.setup.lock")
function(msoh_lock_acquire)
    file(LOCK "${MSOH_LOCK}" TIMEOUT 14400 RESULT_VARIABLE _lrc)
    if(NOT _lrc STREQUAL "0" AND NOT _lrc STREQUAL "")
        message(FATAL_ERROR "setup lock failed (${_lrc}): ${MSOH_LOCK}")
    endif()
endfunction()

# Toolchain hand-off file for the engraving sub-build (content is ABI-independent).
function(msoh_write_build_vars)
    file(WRITE "${MSOH_DEPS_ROOT}/.msoh-build-vars.cmake"
        "set(CMAKE_TOOLCHAIN_FILE \"${MSOH_TOOLCHAIN}\")\n"
        "set(MSOH_DEPS_ROOT \"${MSOH_DEPS_ROOT}\")\n"
        "set(CMAKE_MAKE_PROGRAM \"${CMAKE_MAKE_PROGRAM}\")\n")
endfunction()

msoh_lock_acquire()

# ─── 4. MuseScore source (git clone --depth 1) + muse framework ───
set(MS_DIR "${MSOH_DEPS_ROOT}/MuseScore")
if(NOT EXISTS "${MS_DIR}/src/engraving/CMakeLists.txt")
    message(STATUS "[setup] Cloning MuseScore (gitee mirror, ~100MB)...")
    find_package(Git REQUIRED)
    execute_process(
        COMMAND "${GIT_EXECUTABLE}" clone --depth 1
                https://gitee.com/mirrors/MuseScore.git "${MS_DIR}.cloning"
        RESULT_VARIABLE _rc TIMEOUT 1800)
    if(NOT _rc EQUAL 0)
        file(REMOVE_RECURSE "${MS_DIR}.cloning")
        message(FATAL_ERROR "MuseScore clone failed.")
    endif()
    file(RENAME "${MS_DIR}.cloning" "${MS_DIR}")
endif()

set(FW "${MS_DIR}/muse/framework")
# canary file distinguishes a full extraction from a submodule placeholder
# (git clone leaves an empty muse/ dir) or a partial one
if(NOT EXISTS "${FW}/global/CMakeLists.txt" OR NOT EXISTS "${FW}/global/modularity/ioc.h")
    if(EXISTS "${MS_DIR}/muse")
        file(REMOVE_RECURSE "${MS_DIR}/muse")
    endif()
    message(STATUS "[setup] Fetching muse framework (~10MB)...")
    set(_t "${MSOH_DEPS_ROOT}/.dl-muse.tar.gz")
    msoh_download("https://codeload.github.com/musescore/muse_framework/tar.gz/a7422db9322a7e461692e280c7aca2654082eb40" "${_t}")
    msoh_extract("${_t}" "${MS_DIR}/muse")
    file(REMOVE "${_t}")
    if(NOT EXISTS "${FW}/global/modularity/ioc.h")
        message(FATAL_ERROR "muse framework extraction incomplete")
    endif()
endif()

# ─── 5. Third-party libraries ───
set(DEPS_DIR "${MSOH_DEPS_ROOT}/msoh-deps")
file(MAKE_DIRECTORY "${DEPS_DIR}")
msoh_fetch("https://download.savannah.gnu.org/releases/freetype/freetype-2.14.1.tar.xz" ft.tar.xz freetype)
msoh_fetch("https://github.com/harfbuzz/harfbuzz/releases/download/12.3.0/harfbuzz-12.3.0.tar.xz" hb.tar.xz harfbuzz)
msoh_fetch("https://codeload.github.com/Chlumsky/msdfgen/tar.gz/v1.12" msdf.tgz msdfgen)
msoh_fetch("https://codeload.github.com/zeux/pugixml/tar.gz/v1.15" pugi.tgz pugixml)
msoh_fetch("https://codeload.github.com/nemtrif/utfcpp/tar.gz/v4.1.1" utf.tgz utfcpp)
msoh_fetch("https://codeload.github.com/lvandeve/lodepng/tar.gz/ed6fe5825c6a4fbb7f58ab35a4231c7543cd452a" lode.tgz lodepng)
msoh_fetch("https://codeload.github.com/kazuho/picojson/tar.gz/111c9be" pico.tgz picojson)
# header-only; needed by Qt-OHOS CorePrivate headers and the Qt x64 build
msoh_fetch("https://registry.npmmirror.com/node-addon-api/-/node-addon-api-8.9.2.tgz" naa.tgz node-addon-api)

# ─── 6. Qt host kit (mingw — provides rcc/moc/qmake) ───
set(QT_HOST "${MSOH_DEPS_ROOT}/qt-host-kit")
if(NOT EXISTS "${QT_HOST}/bin/rcc.exe")
    message(STATUS "[setup] Downloading Qt host kit (~250MB)...")
    set(_b "https://mirrors.tuna.tsinghua.edu.cn/qt/online/qtsdkrepository/windows_x86/desktop/qt6_6120/qt6_6120_mingw/qt.qt6.6120.win64_mingw")
    set(_f "${MSOH_DEPS_ROOT}/.dl-qthost.7z")
    msoh_download("${_b}/6.12.0-0-202609280346qtbase-Windows-Windows_11_24H2-Mingw-Windows-Windows_11_24H2-X86_64.7z" "${_f}")
    msoh_7z_extract("${_f}" "${QT_HOST}")
    file(REMOVE "${_f}")
    # MinGW runtime DLLs must sit next to rcc.exe/moc.exe for them to run
    set(_f "${MSOH_DEPS_ROOT}/.dl-mingwrt.7z")
    msoh_download("${_b}/6.12.0-0-202609280346MinGW-w64-x86_64-13.1.0-release-posix-seh-msvcrt-rt_v11-rev1-runtime.7z" "${_f}")
    msoh_7z_extract("${_f}" "${QT_HOST}/bin")
    file(REMOVE "${_f}")
endif()

# ─── 7. Qt arm64 kit (official prebuilt) ───
set(QT_ARM "${MSOH_DEPS_ROOT}/qt-ohos-kit")
if(NOT EXISTS "${QT_ARM}/lib/libQt6Core.so")
    message(STATUS "[setup] Downloading Qt HarmonyOS arm64 (~65MB)...")
    set(_b "https://mirror.sjtu.edu.cn/qt/online/qtsdkrepository/all_os/harmonyos/qt6_6120/qt6_6120_arm64_v8a/qt.qt6.6120.harmonyos_arm64_v8a")
    foreach(_comp qtbase qtdeclarative qtsvg)
        set(_f "${MSOH_DEPS_ROOT}/.dl-${_comp}.7z")
        msoh_download("${_b}/6.12.0-0-202609280346${_comp}-Linux-Ubuntu_24_04-Clang-Linux-HarmonyOS_ANY-ARM64.7z" "${_f}")
        msoh_7z_extract("${_f}" "${QT_ARM}")
        file(REMOVE "${_f}")
    endforeach()
endif()

# ─── 8. Patch muse framework (idempotent) ───
set(_pm "${MS_DIR}/.msoh-patched")
if(NOT EXISTS "${_pm}")
    if(NOT EXISTS "${FW}/global/modularity/ioc.h")
        message(FATAL_ERROR "muse framework incomplete; refusing to patch")
    endif()
    message(STATUS "[setup] Patching muse framework + engraving...")
    msoh_patch("${FW}/global/io/internal/filesystem.h"
        "#include <mutex>\n\n#include" "#include <mutex>\n\n#include <QFile>\n\n#include")
    msoh_patch("${FW}/global/types/mnemonicstring.cpp"
        "if (*c == '&') {" "if (*c == QChar(u'&')) {")
    msoh_patch("${FW}/global/types/mnemonicstring.cpp"
        "if (showUnderlines && *c != '&') {" "if (showUnderlines && *c != QChar(u'&')) {")
    # clang-15 cannot capture structured bindings in lambdas; the copy must
    # live OUTSIDE the lambda (first patch repairs the misplaced variant)
    msoh_patch("${MS_DIR}/src/engraving/rendering/score/stavesharinglayout.cpp"
        "auto makeSharedNotes = [&](Chord* originChord, Chord* sharedChord) {\n                const auto sharedTrackIdx = sharedTrack;"
        "const auto sharedTrackIdx = sharedTrack;\n            auto makeSharedNotes = [&](Chord* originChord, Chord* sharedChord) {")
    msoh_patch("${MS_DIR}/src/engraving/rendering/score/stavesharinglayout.cpp"
        "auto makeSharedNotes = [&](Chord* originChord, Chord* sharedChord) {"
        "const auto sharedTrackIdx = sharedTrack;\n            auto makeSharedNotes = [&](Chord* originChord, Chord* sharedChord) {")
    msoh_patch("${MS_DIR}/src/engraving/rendering/score/stavesharinglayout.cpp"
        "sharedNote->setTrack(sharedTrack);" "sharedNote->setTrack(sharedTrackIdx);")
    file(READ "${FW}/global/modularity/ioc.h" _ioc)
    string(REPLACE "#ifndef NO_QT_SUPPORT"
        "#if !defined(NO_QT_SUPPORT) && !defined(MUSE_NO_QML_CONTEXT)" _ioc "${_ioc}")
    file(WRITE "${FW}/global/modularity/ioc.h" "${_ioc}")
    file(READ "${FW}/global/modularity/ioccontext.cpp" _ictx)
    string(REPLACE "#ifndef NO_QT_SUPPORT\n#include <QQmlEngine>"
        "#if !defined(NO_QT_SUPPORT) && !defined(MUSE_NO_QML_CONTEXT)\n#include <QQmlEngine>" _ictx "${_ictx}")
    file(WRITE "${FW}/global/modularity/ioccontext.cpp" "${_ictx}")
    set(_gm "${MS_DIR}/muse/framework/global/globalmodule.cpp")
    msoh_patch("${_gm}"
        "#include \"api/internal/apiregister.h\""
        "#if !defined(NO_QT_SUPPORT) && !defined(MUSE_NO_QML_CONTEXT)\n#include \"api/internal/apiregister.h\"")
    msoh_patch("${_gm}"
        "#include \"api/processapi.h\""
        "#include \"api/processapi.h\"\n#endif")
    msoh_patch("${_gm}"
        "void GlobalModule::registerApi()\n{"
        "void GlobalModule::registerApi()\n{\n#if !defined(NO_QT_SUPPORT) && !defined(MUSE_NO_QML_CONTEXT)")
    msoh_patch("${_gm}"
        "        api->regApiCreator(moduleName(), \"api.filesystem\", new ApiCreator<FileSystemApi>());\n    }\n}"
        "        api->regApiCreator(moduleName(), \"api.filesystem\", new ApiCreator<FileSystemApi>());\n    }\n#endif\n}")
    msoh_patch("${_gm}"
        "    globalIoc()->registerExport<api::IApiRegister>(moduleName(), new api::ApiRegister());"
        "#if !defined(NO_QT_SUPPORT) && !defined(MUSE_NO_QML_CONTEXT)\n    globalIoc()->registerExport<api::IApiRegister>(moduleName(), new api::ApiRegister());\n#endif")
    file(WRITE "${_pm}" "ok")
endif()
msoh_write_build_vars()
file(LOCK "${MSOH_LOCK}" RELEASE) # ── setup lock released ──

# ─── 9. Qt kit for this ABI ───
if(OHOS_ARCH STREQUAL "arm64-v8a")
    set(QT_KIT "${QT_ARM}")
else()
    # Qt ships no x86_64 HarmonyOS binaries (emulator needs a self-built kit)
    set(QT_X64 "${MSOH_DEPS_ROOT}/qt-x64-kit")
    set(QT_KIT "${QT_X64}/build-x64")
    # minimal platform plugin must expose a real font database when
    # fontconfig is off, else QFontDatabase stays empty and
    # addApplicationFont fails on device (QFreeTypeFontDatabase is already
    # included by qminimalintegration.cpp)
    set(_mi "${QT_X64}/qtbase/src/plugins/platforms/minimal/qminimalintegration.cpp")
    if(EXISTS "${_mi}")
        file(READ "${_mi}" _mic)
        string(FIND "${_mic}" "new QFreeTypeFontDatabase" _fq)
        if(_fq EQUAL -1)
            string(REPLACE "m_fontDatabase = QPlatformIntegration::fontDatabase();"
                "m_fontDatabase = new QFreeTypeFontDatabase;" _mic2 "${_mic}")
            if(NOT "${_mic2}" STREQUAL "${_mic}")
                file(WRITE "${_mi}" "${_mic2}")
                message(STATUS "[setup] patched minimal plugin font db")
                if(EXISTS "${QT_KIT}/build.ninja")
                    execute_process(COMMAND "${CMAKE_COMMAND}" --build "${QT_KIT}" --parallel 14
                        RESULT_VARIABLE _rc TIMEOUT 1800)
                endif()
            endif()
        endif()
    endif()
    # completeness: qtsvg is the last step, so its presence implies the whole
    # pipeline finished (a killed partial build leaves libQt6Core.so behind)
    if(NOT EXISTS "${QT_KIT}/lib/libQt6Svg.so" OR NOT EXISTS "${QT_KIT}/lib/cmake/Qt6/Qt6Config.cmake")
        message(STATUS "[setup] Building Qt x86_64 kit from source (~60 min, first time)...")
        set(QT_SRC_T "https://mirrors.tuna.tsinghua.edu.cn/qt/official_releases/qt/6.12/6.12.0/submodules")
        msoh_fetch("${QT_SRC_T}/qtbase-everywhere-src-6.12.0.tar.xz" qtb.tar.xz "${QT_X64}/qtbase")
        msoh_fetch("${QT_SRC_T}/qtsvg-everywhere-src-6.12.0.tar.xz" qts.tar.xz "${QT_X64}/qtsvg")
        # headless kit: skip the ohos platform plugin (hard fontconfig dep),
        # keep qminimal which the engine uses at runtime
        msoh_patch("${QT_X64}/qtbase/src/plugins/platforms/CMakeLists.txt"
            "if(OHOS)\n    add_subdirectory(ohos)"
            "if(OHOS AND QT_FEATURE_fontconfig)\n    add_subdirectory(ohos)")
        msoh_patch("${QT_X64}/qtbase/src/plugins/platforms/ohos/CMakeLists.txt"
            "WrapFontconfig::WrapFontconfig\n" "")
        set(_qtb_args -G Ninja -B "${QT_KIT}" -S "${QT_X64}/qtbase"
            -D "CMAKE_TOOLCHAIN_FILE=${MSOH_TOOLCHAIN}"
            -D "CMAKE_MAKE_PROGRAM=${CMAKE_MAKE_PROGRAM}"
            -D "OHOS_ARCH=x86_64" -D "OHOS_PLATFORM=OHOS" -D "OHOS_STL=c++_shared"
            -D "QT_HOST_PATH=${QT_HOST}"
            -D "NODE_ADDON_API_ROOT=${DEPS_DIR}/node-addon-api"
            -D "CMAKE_FIND_ROOT_PATH=${DEPS_DIR}/node-addon-api"
            -D "CMAKE_PREFIX_PATH=${DEPS_DIR}/node-addon-api"
            -DQT_BUILD_EXAMPLES=OFF -DQT_BUILD_TESTS=OFF
            -DFEATURE_sql=OFF -DFEATURE_network=OFF -DFEATURE_dbus=OFF
            -DFEATURE_glib=OFF -DFEATURE_icu=OFF -DFEATURE_test=OFF
            -DFEATURE_printsupport=OFF -DFEATURE_fontconfig=OFF)
        execute_process(COMMAND "${CMAKE_COMMAND}" ${_qtb_args}
            RESULT_VARIABLE _rc TIMEOUT 1200)
        if(NOT _rc EQUAL 0)
            message(STATUS "Qt x86_64 configure rc=${_rc}; wiping and retrying once")
            file(REMOVE_RECURSE "${QT_KIT}")
            execute_process(COMMAND "${CMAKE_COMMAND}" ${_qtb_args}
                RESULT_VARIABLE _rc TIMEOUT 1200)
        endif()
        if(NOT _rc EQUAL 0)
            message(FATAL_ERROR "Qt x86_64 configure failed")
        endif()
        execute_process(
            COMMAND "${CMAKE_COMMAND}" --build "${QT_KIT}" --parallel 14
            RESULT_VARIABLE _rc TIMEOUT 5400)
        if(NOT _rc EQUAL 0)
            # transient ninja .ninja_log recompaction errors (Defender scan
            # locks on freshly written files) — resume once
            execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 3)
            execute_process(
                COMMAND "${CMAKE_COMMAND}" --build "${QT_KIT}" --parallel 14
                RESULT_VARIABLE _rc TIMEOUT 5400)
        endif()
        if(NOT _rc EQUAL 0)
            message(FATAL_ERROR "Qt x86_64 build failed")
        endif()
        set(_qts_args -G Ninja -B "${QT_X64}/build-svg" -S "${QT_X64}/qtsvg"
            -D "CMAKE_TOOLCHAIN_FILE=${MSOH_TOOLCHAIN}"
            -D "CMAKE_MAKE_PROGRAM=${CMAKE_MAKE_PROGRAM}"
            -D "OHOS_ARCH=x86_64" -D "OHOS_PLATFORM=OHOS" -D "OHOS_STL=c++_shared"
            -D "QT_HOST_PATH=${QT_HOST}"
            -D "CMAKE_FIND_ROOT_PATH=${QT_KIT}"
            -D "CMAKE_PREFIX_PATH=${QT_KIT}")
        set(_svg_try 0)
        while(NOT _svg_try GREATER 2)
            execute_process(COMMAND "${CMAKE_COMMAND}" ${_qts_args}
                RESULT_VARIABLE _rc TIMEOUT 1200)
            if(_rc EQUAL 0)
                break()
            endif()
            math(EXPR _svg_try "${_svg_try} + 1")
            message(STATUS "qtsvg configure retry ${_svg_try} (rc=${_rc})")
            execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 3)
        endwhile()
        if(NOT _rc EQUAL 0)
            message(FATAL_ERROR "qtsvg configure failed")
        endif()
        execute_process(
            COMMAND "${CMAKE_COMMAND}" --build "${QT_X64}/build-svg" --parallel 14
            RESULT_VARIABLE _rc TIMEOUT 1800)
        if(NOT _rc EQUAL 0)
            execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 3)
            execute_process(
                COMMAND "${CMAKE_COMMAND}" --build "${QT_X64}/build-svg" --parallel 14
                RESULT_VARIABLE _rc TIMEOUT 1800)
        endif()
        if(NOT _rc EQUAL 0)
            message(FATAL_ERROR "qtsvg build failed")
        endif()
        file(GLOB _svgcm "${QT_X64}/build-svg/lib/cmake/Qt6Svg*")
        if(_svgcm)
            file(COPY ${_svgcm} DESTINATION "${QT_KIT}/lib/cmake")
        endif()
        file(COPY "${QT_X64}/build-svg/lib/" DESTINATION "${QT_KIT}/lib"
            FILES_MATCHING PATTERN "*.so")
        file(COPY "${QT_X64}/build-svg/include/QtSvg" DESTINATION "${QT_KIT}/include")
        if(EXISTS "${QT_X64}/build-svg/metatypes")
            file(COPY "${QT_X64}/build-svg/metatypes" DESTINATION "${QT_KIT}")
        endif()
    endif()
    # qtsvg's lib dir uses a .so -> .so.6 -> .so.6.12.0 symlink chain; on
    # Windows copies become dangling links. msohengine's DT_NEEDED is the
    # soname libQt6Svg.so.6 — flatten the chain into real files.
    set(_svg_real "${QT_X64}/build-svg/lib/libQt6Svg.so.6.12.0")
    if(EXISTS "${_svg_real}")
        foreach(_n libQt6Svg.so libQt6Svg.so.6 libQt6Svg.so.6.12.0)
            file(REMOVE "${QT_KIT}/lib/${_n}")
            execute_process(COMMAND "${CMAKE_COMMAND}" -E copy "${_svg_real}" "${QT_KIT}/lib/${_n}")
        endforeach()
    endif()
endif()

# ─── 10. Build engraving_cross static lib (in-repo script) ───
set(EC_SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/engraving")
set(EC_OUT "${MSOH_REPO_ROOT}/build-engraving/${OHOS_ARCH}")
set(EC_LIB "${EC_OUT}/libengraving_cross.a")
set(EC_FT "${EC_OUT}/freetype-build/libfreetype.a")

if(NOT EXISTS "${EC_LIB}")
    message(STATUS "[setup] Building engraving for ${OHOS_ARCH} (~15 min, first time)...")
    # Toolchain via a well-known file read before project() in the sub-build;
    # avoids any cross-process -D/env quoting trouble with spaced paths.
    msoh_write_build_vars()
    set(_ec_args -G Ninja -B "${EC_OUT}" -S "${EC_SCRIPT}"
        -D "OHOS_ARCH=${OHOS_ARCH}" -D "OHOS_PLATFORM=OHOS" -D "OHOS_STL=c++_shared"
        -D "CMAKE_BUILD_TYPE=Release")
    execute_process(COMMAND "${CMAKE_COMMAND}" ${_ec_args}
        RESULT_VARIABLE _rc TIMEOUT 900)
    if(NOT _rc EQUAL 0)
        # a configure killed mid-run (e.g. ninja log recompaction errors) is
        # self-healed by wiping and retrying once from scratch
        message(STATUS "engraving configure rc=${_rc}; wiping and retrying once")
        file(REMOVE_RECURSE "${EC_OUT}")
        execute_process(COMMAND "${CMAKE_COMMAND}" ${_ec_args}
            RESULT_VARIABLE _rc TIMEOUT 900)
    endif()
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "engraving configure failed for ${OHOS_ARCH}")
    endif()
    execute_process(
        COMMAND "${CMAKE_COMMAND}" --build "${EC_OUT}" --parallel 14
        RESULT_VARIABLE _rc TIMEOUT 3600
    )
    if(NOT _rc EQUAL 0)
        execute_process(COMMAND "${CMAKE_COMMAND}" -E sleep 3)
        execute_process(
            COMMAND "${CMAKE_COMMAND}" --build "${EC_OUT}" --parallel 14
            RESULT_VARIABLE _rc TIMEOUT 3600
        )
    endif()
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "engraving build failed for ${OHOS_ARCH}")
    endif()
endif()

# ─── 11. Qt find_package ───
set(QT_HOST_PATH "${QT_HOST}" CACHE PATH "" FORCE)
list(APPEND CMAKE_FIND_ROOT_PATH "${QT_KIT}")
list(PREPEND CMAKE_PREFIX_PATH "${QT_KIT}")
find_package(Qt6 REQUIRED COMPONENTS Core CorePrivate Gui Widgets Svg)

# ─── 12. Generate qrc resource files (shared output dir → locked) ───
msoh_lock_acquire()
set(GEN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/generated")
file(MAKE_DIRECTORY "${GEN_DIR}")
set(RCC "${QT_HOST}/bin/rcc.exe")
function(msoh_qrc QRC_SRC QRC_NAME)
    set(_o "${GEN_DIR}/qrc_${QRC_NAME}.cpp")
    if(NOT EXISTS "${_o}")
        message(STATUS "  rcc: ${QRC_NAME}")
        execute_process(COMMAND "${RCC}" -o "${_o}" --name "${QRC_NAME}" "${QRC_SRC}"
            RESULT_VARIABLE _rc)
        if(NOT _rc EQUAL 0)
            message(FATAL_ERROR "rcc failed: ${QRC_NAME}")
        endif()
    endif()
endfunction()
msoh_qrc("${MS_DIR}/src/engraving/engraving.qrc" "engraving")
foreach(_f Leland Bravura Edwin MScore Gootville MuseJazz Petaluma
           FinaleMaestro FinaleBroadway FreeSans FreeSerif Campania Smufl)
    msoh_qrc("${MS_DIR}/src/engraving/data/fonts/fonts_${_f}.qrc" "fonts_${_f}")
endforeach()
if(NOT EXISTS "${GEN_DIR}/qrc_fonts_tabulature.cpp")
    file(WRITE "${GEN_DIR}/_tab.qrc"
        "<!DOCTYPE RCC><RCC version=\"1.0\"><qresource prefix=\"/\">"
        "<file alias=\"fonts/fonts_tablature.xml\">${MS_DIR}/fonts/fonts_tablature.xml</file>"
        "</qresource></RCC>")
    execute_process(COMMAND "${RCC}" -o "${GEN_DIR}/qrc_fonts_tabulature.cpp"
        --name fonts_Tabulature "${GEN_DIR}/_tab.qrc")
endif()
file(GLOB QRC_SOURCES "${GEN_DIR}/qrc_*.cpp")
file(LOCK "${MSOH_LOCK}" RELEASE) # ── qrc lock released ──

# ─── 13. Copy Qt .so into the hap packaging dir (entry/libs/<abi>) ───
set(LIBS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/${OHOS_ARCH}")
file(MAKE_DIRECTORY "${LIBS_DIR}")
foreach(_l Core Gui Widgets OpenGL Concurrent Svg)
    file(GLOB _qtlibs "${QT_KIT}/lib/libQt6${_l}.so*")
    foreach(_f ${_qtlibs})
        execute_process(COMMAND "${CMAKE_COMMAND}" -E copy "${_f}" "${LIBS_DIR}")
    endforeach()
endforeach()
if(EXISTS "${QT_KIT}/plugins/platforms/libqminimal.so")
    file(COPY "${QT_KIT}/plugins/platforms/libqminimal.so" DESTINATION "${LIBS_DIR}")
endif()

# ─── 14. Generated headers ───
set(MUSE_APP_NAME_HUMAN_READABLE "MuseScore OH")
set(MUSE_APP_NAME_MACHINE_READABLE "musescoreoh")
set(MUSE_APP_VERSION_MAJOR "4")
set(MUSE_APP_VERSION_MINOR "6")
set(MUSE_APP_VERSION_PATCH "0")
set(MUSE_APP_VERSION "4.6.0")
set(MUSE_APP_INSTALL_PREFIX "/")
set(MUSE_APP_INSTALL_RESOURCES_LOCATION "share")
set(MUSE_THREADS_SUPPORT ON)
set(QT_CONCURRENT_SUPPORTED ON)
set(MUSE_MODULE_GLOBAL ON)
set(MUSE_MODULE_DRAW ON)
set(MUSE_MODULE_MPE ON)
configure_file("${FW}/cmake/muse_framework_config.h.in"
               "${CMAKE_BINARY_DIR}/gen/muse_framework_config.h" @ONLY)
file(WRITE "${CMAKE_BINARY_DIR}/gen/msdfgen/msdfgen-config.h" [==[
#pragma once
#define MSDFGEN_PUBLIC
#define MSDFGEN_EXT_PUBLIC
#define MSDFGEN_VERSION "1.12.0"
#define MSDFGEN_VERSION_MAJOR 1
#define MSDFGEN_VERSION_MINOR 12
#define MSDFGEN_VERSION_REVISION 0
#define MSDFGEN_COPYRIGHT_YEAR 2024
]==])

# ═══════════════════════════════════════════════════════════════════════════
# Build targets
# ═══════════════════════════════════════════════════════════════════════════
set(OLD_CPP "${CMAKE_CURRENT_SOURCE_DIR}/../cpp")

add_library(msoh SHARED
    ${OLD_CPP}/mscz_native.cpp
    ${OLD_CPP}/zip_reader.cpp
    ${OLD_CPP}/mscz_meta.cpp
    ${OLD_CPP}/thirdparty/pugixml/pugixml.cpp)
target_include_directories(msoh PRIVATE ${OLD_CPP} ${OLD_CPP}/thirdparty/pugixml)
target_link_libraries(msoh PRIVATE libace_napi.z.so libhilog_ndk.z.so z)

add_library(msohengine SHARED
    mscore_engine.cpp
    ${QRC_SOURCES})
target_include_directories(msohengine PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${MS_DIR}/src
    ${MS_DIR}/src/engraving
    ${MS_DIR}/src/engraving/infrastructure
    ${MS_DIR}/src/engraving/thirdparty/dtl
    ${MS_DIR}/src/engraving/thirdparty/intervaltree
    ${FW}
    ${FW}/global
    ${FW}/global/thirdparty/kors_async
    ${FW}/global/thirdparty/kors_logger
    ${FW}/global/thirdparty/kors_modularity
    ${FW}/global/thirdparty/kors_msgpack
    ${FW}/global/thirdparty/kors_profiler
    ${FW}/global/thirdparty/kors_rpcqueue
    ${FW}/global/thirdparty/sg14
    ${FW}/draw
    ${FW}/mpe
    ${DEPS_DIR}/picojson
    ${DEPS_DIR}/pugixml/src
    ${DEPS_DIR}/utfcpp/source
    ${DEPS_DIR}/lodepng
    ${DEPS_DIR}/harfbuzz/src
    ${DEPS_DIR}/msdfgen
    ${DEPS_DIR}/node-addon-api
    ${CMAKE_BINARY_DIR}/gen)
target_compile_definitions(msohengine PRIVATE
    NDEBUG NO_ENGRAVING_INTERACTIVE NO_ENGRAVING_QSVGRENDER
    ENGRAVING_NO_API ENGRAVING_NO_INTERNAL KORS_LOGGER_QT_SUPPORT
    MUSE_NO_QML_CONTEXT HAVE_FREETYPE=1)
target_link_libraries(msohengine PRIVATE
    ${EC_LIB} ${EC_FT}
    Qt6::Core Qt6::CorePrivate Qt6::Gui Qt6::Widgets Qt6::Svg
    libace_napi.z.so libhilog_ndk.z.so z)
