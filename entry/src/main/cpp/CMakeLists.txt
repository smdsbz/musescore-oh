cmake_minimum_required(VERSION 3.5.0)
project(MuseScoreOH)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(NOT DEFINED OHOS_STL)
    set(OHOS_STL c++_shared)
endif()

include_directories(${NATIVERENDER_ROOT_PATH})

add_library(msoh SHARED
    mscz_native.cpp
    zip_reader.cpp
    mscz_meta.cpp
    thirdparty/pugixml/pugixml.cpp
)

target_link_libraries(msoh PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    z
)
