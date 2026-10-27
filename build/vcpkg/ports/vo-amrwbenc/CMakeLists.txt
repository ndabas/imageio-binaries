# Replaces the autotools build (awkward with MSVC); the source list is read
# from the upstream Makefile.am. The optional 32-bit ARM assembly is not used.
cmake_minimum_required(VERSION 3.20)
project(vo-amrwbenc C)

file(READ Makefile.am am)
string(REGEX REPLACE "#[^\n]*" "" am "${am}")
string(REPLACE "$(VO_COMMON)" common am "${am}")
string(REPLACE "$(ENC_SRC)" amrwbenc/src am "${am}")
string(REGEX MATCHALL "[A-Za-z0-9_/-]+\\.c[ \t\n]" SOURCES "${am} ")
list(TRANSFORM SOURCES STRIP)
list(FILTER SOURCES EXCLUDE REGEX "^(amrwb-enc|wavreader)\\.c$")
list(REMOVE_DUPLICATES SOURCES)

add_library(vo-amrwbenc ${SOURCES})
target_include_directories(vo-amrwbenc PRIVATE amrwbenc/inc common/include)

install(TARGETS vo-amrwbenc)
install(FILES enc_if.h DESTINATION include/vo-amrwbenc)
