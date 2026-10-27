vcpkg_download_distfile(ARCHIVE
    URLS "https://downloads.sourceforge.net/project/opencore-amr/vo-amrwbenc/vo-amrwbenc-${VERSION}.tar.gz"
    FILENAME "vo-amrwbenc-${VERSION}.tar.gz"
    SHA512 5f132f798f00ec2c0619700ab1ce456897792b45631af4b538c866636af9c9de5600af5f79040c41c3dc69c17cf4be7032139a9518a46a4276431e091f3dd6a9
)
vcpkg_extract_source_archive(SOURCE_PATH ARCHIVE "${ARCHIVE}")
file(COPY "${CMAKE_CURRENT_LIST_DIR}/CMakeLists.txt" DESTINATION "${SOURCE_PATH}")

vcpkg_cmake_configure(SOURCE_PATH "${SOURCE_PATH}")
vcpkg_cmake_install()

file(REMOVE_RECURSE "${CURRENT_PACKAGES_DIR}/debug/include")
vcpkg_install_copyright(FILE_LIST "${SOURCE_PATH}/COPYING")
