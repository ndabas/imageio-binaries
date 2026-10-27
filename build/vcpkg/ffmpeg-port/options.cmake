# Configure options for the features in features.json. Included by vcpkg's
# ffmpeg portfile (see build/build-ffmpeg.py) after it has set up OPTIONS.
set(z_imageio_options
    gsm "--enable-libgsm"
    opencore-amr "--enable-libopencore-amrnb --enable-libopencore-amrwb"
    vo-amrwbenc "--enable-libvo-amrwbenc"
    zimg "--enable-libzimg"
    vidstab "--enable-libvidstab"
    v4l2m2m "--enable-v4l2-m2m"
    gmp "--enable-gmp"
)
while(z_imageio_options)
    list(POP_FRONT z_imageio_options z_feature z_option)
    if(z_feature IN_LIST FEATURES)
        string(APPEND OPTIONS " ${z_option}")
    endif()
endwhile()

# Some .pc files (e.g. zimg's) list -lstdc++, which only exists with GCC's
# C++ runtime: MSVC links its runtime implicitly, Apple's is libc++. Give
# configure a pkg-config wrapper that fixes that up.
if(VCPKG_DETECTED_MSVC OR VCPKG_TARGET_IS_OSX)
    set(z_cxx_lib "")
    if(VCPKG_TARGET_IS_OSX)
        set(z_cxx_lib "-lc++")
    endif()
    set(z_wrapper "${CURRENT_BUILDTREES_DIR}/imageio-pkg-config.sh")
    set(z_script [=[#!/bin/sh
out=$("@PKGCONFIG@" "$@") || exit $?
printf '%s\n' "$out" | sed 's/-lstdc++/@CXX_LIB@/g'
]=])
    string(REPLACE "@PKGCONFIG@" "${PKGCONFIG}" z_script "${z_script}")
    string(REPLACE "@CXX_LIB@" "${z_cxx_lib}" z_script "${z_script}")
    file(WRITE "${z_wrapper}" "${z_script}")
    file(CHMOD "${z_wrapper}" FILE_PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE
        GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)
    string(APPEND OPTIONS " --pkg-config=\"${z_wrapper}\"")
endif()
