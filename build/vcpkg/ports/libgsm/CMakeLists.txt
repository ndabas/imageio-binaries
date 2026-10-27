# Builds only the library (not the toast tool), as ffmpeg's --enable-libgsm expects it.
cmake_minimum_required(VERSION 3.20)
project(libgsm C)

set(SOURCES add code decode gsm_create gsm_decode gsm_destroy gsm_encode gsm_explode
    gsm_implode gsm_option long_term lpc preprocess rpe short_term table)
list(TRANSFORM SOURCES PREPEND src/)
list(TRANSFORM SOURCES APPEND .c)

add_library(gsm ${SOURCES})
target_include_directories(gsm PRIVATE inc)
# The same options as the upstream Makefile.
target_compile_definitions(gsm PRIVATE SASR WAV49 NeedFunctionPrototypes=1)

install(TARGETS gsm)
install(FILES inc/gsm.h DESTINATION include/gsm)
