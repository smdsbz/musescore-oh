cmake_minimum_required(VERSION 3.16)

# Read toolchain from the well-known file written by the parent build before
# invoking this sub-build. Runs before project() so the toolchain takes
# effect for compiler detection.
if(NOT DEFINED CMAKE_TOOLCHAIN_FILE)
    if(DEFINED ENV{MSOH_DEPS_ROOT})
        set(_msoh_dr "$ENV{MSOH_DEPS_ROOT}")
    else()
        get_filename_component(_msoh_dr "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)
        set(_msoh_dr "${_msoh_dr}/.deps")
    endif()
    if(EXISTS "${_msoh_dr}/.msoh-build-vars.cmake")
        include("${_msoh_dr}/.msoh-build-vars.cmake")
    endif()
endif()

project(engraving_cross LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC OFF)
set(CMAKE_AUTORCC OFF)
set(CMAKE_AUTOUIC OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# All paths from parent or env; no hardcoded absolute paths.
if(DEFINED ENV{MSOH_DEPS_ROOT})
    set(MSOH_DEPS_ROOT "$ENV{MSOH_DEPS_ROOT}")
else()
    get_filename_component(MSOH_DEPS_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)
    set(MSOH_DEPS_ROOT "${MSOH_DEPS_ROOT}/.deps")
endif()
string(REPLACE "\\" "/" MSOH_DEPS_ROOT "${MSOH_DEPS_ROOT}")

set(MU_ROOT "${MSOH_DEPS_ROOT}/MuseScore")
set(FW "${MU_ROOT}/muse/framework")
set(DEPS "${MSOH_DEPS_ROOT}/msoh-deps")

# Select Qt kit by ABI
if(OHOS_ARCH STREQUAL "arm64-v8a")
    set(QT_KIT "${MSOH_DEPS_ROOT}/qt-ohos-kit")
else()
    set(QT_KIT "${MSOH_DEPS_ROOT}/qt-x64-kit/build-x64")
endif()
set(QT_HOST_PATH "${MSOH_DEPS_ROOT}/qt-host-kit" CACHE PATH "" FORCE)
list(APPEND CMAKE_FIND_ROOT_PATH "${QT_KIT}")
list(PREPEND CMAKE_PREFIX_PATH "${QT_KIT}")

find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets Svg)

# --- generated headers ---
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
configure_file("${FW}/cmake/muse_framework_config.h.in" "${CMAKE_BINARY_DIR}/gen/muse_framework_config.h" @ONLY)
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

# --- sources ---
file(GLOB_RECURSE GLOBAL_SRC "${FW}/global/*.cpp")
list(FILTER GLOBAL_SRC EXCLUDE REGEX "/(tests?|examples?)/")
list(FILTER GLOBAL_SRC EXCLUDE REGEX "global/api/")
file(GLOB_RECURSE DRAW_SRC "${FW}/draw/*.cpp")
list(FILTER DRAW_SRC EXCLUDE REGEX "/(tests?)/")
file(GLOB_RECURSE MPE_SRC "${FW}/mpe/*.cpp")
list(FILTER MPE_SRC EXCLUDE REGEX "/(tests?|examples?|qml)/")
file(GLOB_RECURSE ENGRAVING_SRC "${MU_ROOT}/src/engraving/*.cpp")
list(FILTER ENGRAVING_SRC EXCLUDE REGEX "engraving/(api|qml|tests|devtools)/")
list(FILTER ENGRAVING_SRC EXCLUDE REGEX "_test\\.cpp$|/test_/|interval_tree_test")

# --- msdfgen subset ---
file(GLOB MSDFGEN_SRC
    "${DEPS}/msdfgen/core/*.cpp"
    "${DEPS}/msdfgen/ext/import-font.cpp"
    "${DEPS}/msdfgen/ext/resolve-shape-geometry.cpp")

# --- harfbuzz (raw sources, no meson) ---
file(GLOB HARFBUZZ_SRC "${DEPS}/harfbuzz/src/*.cc")
list(FILTER HARFBUZZ_SRC EXCLUDE REGEX "(-icu|-glib|-uniscribe|-directwrite|-coretext|-cairo|-chafa|-graphite2|-gdi)")
list(FILTER HARFBUZZ_SRC EXCLUDE REGEX "(test|main|perf|benchmark|subset-|font-collection)")

# --- FreeType (rasterizer only) ---
set(FT_DISABLE_ZLIB ON CACHE BOOL "" FORCE)
set(FT_DISABLE_BZIP2 ON CACHE BOOL "" FORCE)
set(FT_DISABLE_PNG ON CACHE BOOL "" FORCE)
set(FT_DISABLE_HARFBUZZ ON CACHE BOOL "" FORCE)
set(FT_DISABLE_BROTLI ON CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF)
add_subdirectory("${DEPS}/freetype" freetype-build EXCLUDE_FROM_ALL)

add_library(engraving_cross STATIC
    ${ENGRAVING_SRC}
    ${GLOBAL_SRC}
    ${DRAW_SRC}
    ${MPE_SRC}
    ${HARFBUZZ_SRC}
    ${MSDFGEN_SRC}
    "${DEPS}/pugixml/src/pugixml.cpp"
    "${DEPS}/lodepng/lodepng.cpp")

target_include_directories(engraving_cross PUBLIC
    "${DEPS}/picojson"
    "${DEPS}/pugixml/src"
    "${DEPS}/utfcpp/source"
    "${DEPS}/lodepng"
    "${DEPS}/harfbuzz/src"
    "${DEPS}/msdfgen"
    "${MU_ROOT}/src"
    "${MU_ROOT}/src/engraving"
    "${MU_ROOT}/src/engraving/infrastructure"
    "${MU_ROOT}/src/engraving/thirdparty/dtl"
    "${MU_ROOT}/src/engraving/thirdparty/intervaltree"
    "${FW}"
    "${FW}/global"
    "${FW}/global/thirdparty/kors_async"
    "${FW}/global/thirdparty/kors_logger"
    "${FW}/global/thirdparty/kors_modularity"
    "${FW}/global/thirdparty/kors_msgpack"
    "${FW}/global/thirdparty/kors_profiler"
    "${FW}/global/thirdparty/kors_rpcqueue"
    "${FW}/global/thirdparty/sg14"
    "${FW}/draw"
    "${FW}/mpe"
    "${CMAKE_BINARY_DIR}/gen")

target_compile_definitions(engraving_cross PUBLIC
    NDEBUG
    NO_ENGRAVING_INTERACTIVE
    NO_ENGRAVING_QSVGRENDER
    ENGRAVING_NO_API
    ENGRAVING_NO_INTERNAL
    KORS_LOGGER_QT_SUPPORT
    HAVE_FREETYPE=1
    MUSE_NO_QML_CONTEXT)

target_link_libraries(engraving_cross PUBLIC Qt6::Core Qt6::Gui Qt6::Widgets Qt6::Svg freetype)
