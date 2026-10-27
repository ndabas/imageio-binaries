# For a musl (Alpine) host: fully static, hardened PIE executables that run on
# any glibc or musl distro. musl's default thread stack (128 KiB) is too small
# for some encoders (e.g. SVT-AV1), so use glibc's 2 MiB.
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Linux)
set(VCPKG_BUILD_TYPE release)
set(VCPKG_C_FLAGS "-fstack-protector-strong")
set(VCPKG_CXX_FLAGS "-fstack-protector-strong")
# vcpkg's RPATH fix-up (patchelf) breaks static-PIE executables; they have no RPATH.
set(VCPKG_FIXUP_ELF_RPATH OFF)
set(VCPKG_LINKER_FLAGS "-static-pie -Wl,-z,relro,-z,now -Wl,-z,stack-size=2097152")
