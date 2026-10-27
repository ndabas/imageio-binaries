vcpkg_download_distfile(ARCHIVE
    URLS
        "https://www.quut.com/gsm/gsm-${VERSION}.tar.gz"
        "https://src.fedoraproject.org/repo/pkgs/gsm/gsm-${VERSION}.tar.gz/sha512/96a477f7f4a2ad8319d97c4010e3e2ddb453fa6eda44dac83a62f060a3e6790cc0298d3f402eab52e1a7c0f5c001ab793baefd1fc876ff6432efeb506981bdd8/gsm-${VERSION}.tar.gz"
    FILENAME "gsm-${VERSION}.tar.gz"
    SHA512 96a477f7f4a2ad8319d97c4010e3e2ddb453fa6eda44dac83a62f060a3e6790cc0298d3f402eab52e1a7c0f5c001ab793baefd1fc876ff6432efeb506981bdd8
)
vcpkg_extract_source_archive(SOURCE_PATH ARCHIVE "${ARCHIVE}")
file(COPY "${CMAKE_CURRENT_LIST_DIR}/CMakeLists.txt" DESTINATION "${SOURCE_PATH}")

vcpkg_cmake_configure(SOURCE_PATH "${SOURCE_PATH}")
vcpkg_cmake_install()

file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/include")
vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/COPYRIGHT")
