# Replaces the autotools build (awkward with MSVC). The source lists are read
# from the upstream Makefile.am files. Like the upstream default
# (--enable-compile-c), the .cpp sources are compiled as C, so linking needs no
# C++ runtime.
cmake_minimum_required(VERSION 3.20)
project(opencore-amr C)

set(AMR_BASE opencore/codecs_v2/audio/gsm_amr)

# am_sources(<out> <dir> VAR=path...): sources listed in <dir>/Makefile.am,
# with $(VAR) replaced by path.
function(am_sources out dir)
    file(READ "${dir}/Makefile.am" am)
    string(REGEX REPLACE "#[^\n]*" "" am "${am}")
    foreach(def IN LISTS ARGN)
        string(REPLACE "=" ";" def "${def}")
        list(GET def 0 var)
        list(GET def 1 path)
        string(REPLACE "$(${var})" "${path}" am "${am}")
    endforeach()
    string(REGEX MATCHALL "[A-Za-z0-9_/.-]+\\.cpp" sources "${am}")
    list(REMOVE_DUPLICATES sources)
    list(TRANSFORM sources REPLACE "^([^/]+\\.cpp)$" "${dir}/\\1")
    set_source_files_properties(${sources} PROPERTIES LANGUAGE C)
    set(${out} ${sources} PARENT_SCOPE)
endfunction()

am_sources(AMRNB_SOURCES amrnb
    DEC_SRC_DIR=${AMR_BASE}/amr_nb/dec/src
    ENC_SRC_DIR=${AMR_BASE}/amr_nb/enc/src
    COMMON_SRC_DIR=${AMR_BASE}/amr_nb/common/src)
add_library(opencore-amrnb ${AMRNB_SOURCES})
target_include_directories(opencore-amrnb PRIVATE oscl amrnb
    ${AMR_BASE}/amr_nb/dec/src ${AMR_BASE}/amr_nb/common/include
    ${AMR_BASE}/amr_nb/dec/include ${AMR_BASE}/common/dec/include
    ${AMR_BASE}/amr_nb/enc/src)

am_sources(AMRWB_SOURCES amrwb DEC_SRC_DIR=${AMR_BASE}/amr_wb/dec/src)
add_library(opencore-amrwb ${AMRWB_SOURCES})
target_include_directories(opencore-amrwb PRIVATE oscl amrwb
    ${AMR_BASE}/amr_wb/dec/src ${AMR_BASE}/amr_wb/dec/include
    ${AMR_BASE}/common/dec/include)

set_target_properties(opencore-amrnb opencore-amrwb PROPERTIES C_STANDARD 11)

install(TARGETS opencore-amrnb opencore-amrwb)
install(FILES amrnb/interf_dec.h amrnb/interf_enc.h DESTINATION include/opencore-amrnb)
install(FILES amrwb/dec_if.h amrwb/if_rom.h DESTINATION include/opencore-amrwb)
