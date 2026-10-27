# Replaces the upstream CMakeLists.txt, which hard-codes GCC flags and libm.
# Built without OpenMP (ffmpeg's filters drive it frame by frame).
cmake_minimum_required(VERSION 3.20)
project(vidstab C)

add_library(vidstab src/frameinfo.c src/transformtype.c src/libvidstab.c
    src/transform.c src/transformfixedpoint.c src/motiondetect.c
    src/motiondetect_opt.c src/serialize.c src/localmotion2transform.c
    src/boxblur.c src/vsvector.c src/orc/motiondetectorc.c)
set_target_properties(vidstab PROPERTIES C_STANDARD 99)
target_compile_definitions(vidstab PRIVATE DISABLE_ORC)
if(MSVC)
    # M_PI; and serialize.c only detects byte order from GCC macros (all
    # Windows targets are little-endian).
    target_compile_definitions(vidstab PRIVATE _USE_MATH_DEFINES __LITTLE_ENDIAN__)
endif()
if(CMAKE_SYSTEM_PROCESSOR MATCHES "^(x86_64|AMD64|amd64|i.86|x86|X86)$")
    target_compile_definitions(vidstab PRIVATE USE_SSE2)
    if(NOT MSVC)
        target_compile_options(vidstab PRIVATE -msse2)
    endif()
endif()

set(LIBM "")
if(NOT WIN32)
    target_link_libraries(vidstab PRIVATE m)
    set(LIBM "-lm")
endif()

file(GLOB HEADERS src/*.h)
install(FILES ${HEADERS} DESTINATION include/vid.stab)
install(TARGETS vidstab)
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/vidstab.pc"
"prefix=${CMAKE_INSTALL_PREFIX}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: vidstab
Description: Vid.Stab, a library for stabilizing video clips
Version: ${VIDSTAB_VERSION}
Libs: -L\${libdir} -lvidstab
Libs.private: ${LIBM}
Cflags: -I\${includedir}
")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/vidstab.pc" DESTINATION lib/pkgconfig)
