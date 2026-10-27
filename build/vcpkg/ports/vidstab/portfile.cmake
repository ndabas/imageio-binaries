vcpkg_from_github(
    OUT_SOURCE_PATH SOURCE_PATH
    REPO georgmartius/vid.stab
    REF "v${VERSION}"
    SHA512 b27ac95ab5302e9500af5a52cb09f557b9dacbdc4dc57a9781e2f9ae65a6ffea396f9819bca1f6a103f9d1896bf3061f1cb647166b14b8de8e89a1b15f010e5c
    HEAD_REF master
)
file(COPY "${CMAKE_CURRENT_LIST_DIR}/CMakeLists.txt" DESTINATION "${SOURCE_PATH}")

# MSVC: use standard variadic macros instead of GNU named ones, and drop
# <libgen.h> (nothing from it is used).
file(READ "${SOURCE_PATH}/src/vidstabdefines.h" defines)
string(REGEX REPLACE "\\(tag, format, args\\.\\.\\.\\) \\\\\n +vs_log\\(([A-Z_]+), tag, format , ## args\\)"
    "(...) vs_log(\\1, __VA_ARGS__)" defines "${defines}")
file(WRITE "${SOURCE_PATH}/src/vidstabdefines.h" "${defines}")
foreach(f IN ITEMS src/transform.h src/transform.c)
    vcpkg_replace_string("${SOURCE_PATH}/${f}" "#include <libgen.h>" "")
endforeach()
# These are called through pointers from transform.c; MSVC emits no external
# definition for C `inline` functions.
vcpkg_replace_string("${SOURCE_PATH}/src/transformfixedpoint.c" "inline void interpolate" "void interpolate")

vcpkg_cmake_configure(SOURCE_PATH "${SOURCE_PATH}" OPTIONS "-DVIDSTAB_VERSION=${VERSION}")
vcpkg_cmake_install()
vcpkg_fixup_pkgconfig()

file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/include")
vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/LICENSE")
