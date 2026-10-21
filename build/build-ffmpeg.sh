#!/usr/bin/env bash
# Build a lean, self-contained ffmpeg executable from source.
#
# Native builds only (no cross-compiling), in one of these environments:
#   * Linux:   musllinux_1_2 (Alpine) container -> fully static executable that
#              runs on any glibc or musl distro.
#   * macOS:   arm64 or x86_64 host; only system libraries/frameworks are linked
#              dynamically. MACOSX_DEPLOYMENT_TARGET defaults to 11.0 (arm64) /
#              10.15 (x86_64).
#   * Windows: MSYS2 shell: MINGW32 (i686), UCRT64 (x86_64) or CLANGARM64
#              (aarch64); only Windows system DLLs are imported.
#
# Usage: build/build-ffmpeg.sh [--install-tools]
#
# Environment variables (all optional):
#   FFMPEG_VERSION  build this ffmpeg release instead of the pinned one
#                   (its checksum cannot be verified then)
#   WORK_DIR        scratch directory (default: ./_build/<platform>)
#   OUT_DIR         where the final executable is written (default: ./_out)
#   SOURCES_CACHE   source tarball cache (default: ./_build/sources)
#   DISABLE         space-separated deps to leave out, e.g. "svtav1 x265"
#   JOBS            parallel jobs (default: number of CPUs)
#
# The output is named like the files in ffmpeg/ (and expected by
# imageio-ffmpeg): ffmpeg-<linux|macos|win>-<x86_64|aarch64|i686>-v<version>[.exe]

set -euo pipefail

# macOS ships bash 3.2, which lacks features used below (associative arrays,
# empty arrays with `set -u`); install a newer one, e.g. `brew install bash`.
# This check must stay bash 3.2 compatible.
if ((BASH_VERSINFO[0] < 4)); then
    echo "ERROR: bash >= 4 is required, this is bash $BASH_VERSION ($BASH)" >&2
    exit 1
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES_FILE="$ROOT_DIR/build/sources.txt"

PLATFORM=unknown

# --- Logging ----------------------------------------------------------------
# In GitHub Actions each stage is a collapsible log group, failures are
# reported as error annotations and a summary is added to the job summary.

GHA=false
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then GHA=true; fi
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-}"
if [[ -n "$SUMMARY_FILE" ]] && command -v cygpath >/dev/null; then
    SUMMARY_FILE="$(cygpath -u "$SUMMARY_FILE")"
fi

STAGE="" STAGE_TITLE="" STAGE_START=0 ERROR_MSG=""
declare -A STAGE_TIME

log() {
    if $GHA; then echo "$*"; else printf '\033[1;34m--> %s\033[0m\n' "$*"; fi
}

# begin_stage <key> <title>: starts a (collapsible) section of the log.
begin_stage() {
    end_stage
    STAGE=$1 STAGE_TITLE=$2 STAGE_START=$SECONDS
    if $GHA; then echo "::group::$2"; else printf '\n\033[1;34m==> %s\033[0m\n' "$2"; fi
}

end_stage() {
    if [[ -z "$STAGE" ]]; then return 0; fi
    if $GHA; then echo "::endgroup::"; fi
    STAGE_TIME[$STAGE]=$((SECONDS - STAGE_START))
    STAGE=""
}

die() {
    ERROR_MSG="$*"
    printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2
    exit 1
}

duration() { printf '%d:%02d' $(($1 / 60)) $(($1 % 60)); }

on_exit() {
    local rc=$?
    if ((rc == 0)); then return; fi
    local where="${STAGE_TITLE:-setup}" msg="${ERROR_MSG:-exit code $rc}"
    if [[ -n "$STAGE" ]] && $GHA; then echo "::endgroup::"; fi
    if $GHA; then
        echo "::error title=ffmpeg build failed ($PLATFORM)::$where: $msg (see the log group above)"
    fi
    if [[ -n "$SUMMARY_FILE" ]]; then
        printf '### ❌ ffmpeg build for %s failed\n\nStage: **%s**\n\n%s\n\n' \
            "$PLATFORM" "$where" "$msg" >> "$SUMMARY_FILE"
    fi
}
trap on_exit EXIT

# --- Platform detection -----------------------------------------------------

case "$(uname -s)" in
    Linux) OS=linux ;;
    Darwin) OS=macos ;;
    MINGW* | UCRT* | CLANG*) OS=win ;;
    *) die "unsupported build environment: $(uname -s) (use an MSYS2 MINGW shell on Windows)" ;;
esac

if [[ $OS == win ]]; then
    # The MSYS2 runtime itself is always x86_64, so use the environment's arch.
    ARCH="${MSYSTEM_CARCH:?MSYSTEM_CARCH not set, run from an MSYS2 MINGW32/UCRT64/CLANGARM64 shell}"
else
    ARCH="$(uname -m)"
fi
case "$ARCH" in
    x86_64 | amd64) ARCH=x86_64 ;;
    aarch64 | arm64) ARCH=aarch64 ;;
    i686 | i386) ARCH=i686 ;;
    *) die "unsupported architecture: $ARCH" ;;
esac
PLATFORM="$OS-$ARCH"
EXE=""
[[ $OS == win ]] && EXE=".exe"

if [[ $OS == linux && ! -f /etc/alpine-release ]]; then
    echo "WARNING: not running in a musllinux/Alpine container; the result may not be portable." >&2
fi

if [[ -z "${JOBS:-}" ]]; then
    JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
fi

# --- Build tools ------------------------------------------------------------

# zlib comes from the platform: Alpine's zlib-static, MSYS2's static libz.a, or
# the macOS system libz.
install_tools() {
    begin_stage tools "Installing build tools for $PLATFORM"
    case "$OS" in
        linux)
            apk add --no-cache autoconf automake bash bzip2 coreutils curl diffutils \
                libtool linux-headers make meson nasm perl pkgconf samurai tar xz \
                zlib-dev zlib-static
            ;;
        macos)
            brew install --quiet automake meson nasm ninja pkgconf
            ;;
        win)
            local p="${MINGW_PACKAGE_PREFIX:?}"
            local pkgs=(make diffutils automake autoconf libtool tar xz bzip2
                "$p-cc" "$p-binutils" "$p-cmake" "$p-meson" "$p-ninja" "$p-pkgconf" "$p-zlib")
            if [[ $ARCH != aarch64 ]]; then pkgs+=("$p-nasm"); fi
            pacman -S --needed --noconfirm "${pkgs[@]}"
            ;;
    esac
}

if [[ "${1:-}" == "--install-tools" ]]; then
    install_tools
    end_stage
    shift
fi

# --- Configuration ----------------------------------------------------------

declare -A SRC_VERSION SRC_SHA256 SRC_URL SRC_FILE
while read -r name version sha url file; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    SRC_VERSION[$name]=$version
    SRC_SHA256[$name]=$sha
    SRC_URL[$name]=$url
    SRC_FILE[$name]=${file:-$(basename "$url")}
done < <(tr -d '\r' < "$SOURCES_FILE")

if [[ -n "${FFMPEG_VERSION:-}" && "$FFMPEG_VERSION" != "${SRC_VERSION[ffmpeg]}" ]]; then
    echo "NOTE: building ffmpeg $FFMPEG_VERSION instead of pinned ${SRC_VERSION[ffmpeg]}; checksum not verified"
    SRC_VERSION[ffmpeg]=$FFMPEG_VERSION
    SRC_SHA256[ffmpeg]=SKIP
    SRC_URL[ffmpeg]="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
    SRC_FILE[ffmpeg]="ffmpeg-$FFMPEG_VERSION.tar.xz"
fi
FFMPEG_VERSION=${SRC_VERSION[ffmpeg]}

WORK_DIR="${WORK_DIR:-$ROOT_DIR/_build/$PLATFORM}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/_out}"
SOURCES_CACHE="${SOURCES_CACHE:-$ROOT_DIR/_build/sources}"
PREFIX="$WORK_DIR/prefix"
DISABLE=" ${DISABLE:-} "

# SVT-AV1 only supports 64-bit targets.
[[ $ARCH == i686 ]] && DISABLE+=" svtav1 "

enabled() { [[ "$DISABLE" != *" $1 "* ]]; }

mkdir -p "$WORK_DIR" "$OUT_DIR" "$SOURCES_CACHE" "$PREFIX/lib/pkgconfig"

# Paths handed to native Windows tools (cmake, meson) must be Windows paths.
if [[ $OS == win ]]; then
    PREFIX_NATIVE="$(cygpath -m "$PREFIX")"
else
    PREFIX_NATIVE="$PREFIX"
fi

# Only ever pick up the libraries built here.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH

CFLAGS="-O2"
LDFLAGS="-L$PREFIX/lib"
FF_EXTRA_LDFLAGS=""
FF_EXTRA_LIBS=""
FF_CONFIGURE=()
AUTOTOOLS_HOST=()
CMAKE_ARGS=(-G Ninja -DCMAKE_BUILD_TYPE=Release "-DCMAKE_INSTALL_PREFIX=$PREFIX_NATIVE"
    -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    "-DCMAKE_PREFIX_PATH=$PREFIX_NATIVE" -DCMAKE_FIND_USE_PACKAGE_REGISTRY=OFF)

case "$OS" in
    linux)
        # Hardened static-PIE like wader/static-ffmpeg. musl's default thread stack
        # (128 KiB) is too small for some encoders (e.g. SVT-AV1), so use glibc's 2 MiB.
        export CC=gcc CXX=g++
        CFLAGS+=" -fPIC -static-libgcc"
        FF_EXTRA_LDFLAGS="-Wl,-z,stack-size=2097152"
        FF_EXTRA_LIBS="-lstdc++ -lm -lpthread"
        FF_CONFIGURE+=(--toolchain=hardened)
        CXX_RUNTIME="-lstdc++"
        VPX_TARGET=$([[ $ARCH == x86_64 ]] && echo x86_64-linux-gcc || echo arm64-linux-gcc)
        CMAKE_ARGS+=(-DCMAKE_POSITION_INDEPENDENT_CODE=ON)
        ;;
    macos)
        export CC=clang CXX=clang++
        if [[ $ARCH == aarch64 ]]; then
            export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"
            VPX_TARGET=arm64-darwin20-gcc
        else
            export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.15}"
            VPX_TARGET=x86_64-darwin19-gcc
        fi
        CFLAGS+=" -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
        LDFLAGS+=" -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
        CXX_RUNTIME="-lc++"
        FF_EXTRA_LIBS="-lc++"
        FF_CONFIGURE+=(--enable-videotoolbox --enable-audiotoolbox --enable-avfoundation)
        CMAKE_ARGS+=("-DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET" -DCMAKE_FIND_FRAMEWORK=LAST)

        ;;
    win)
        AUTOTOOLS_HOST=(--build="$MINGW_CHOST" --host="$MINGW_CHOST")
        FF_CONFIGURE+=(--target-os=mingw32 "--arch=$ARCH")
        if [[ $MSYSTEM == CLANG* ]]; then
            export CC=clang CXX=clang++
            CXX_RUNTIME="-lc++"
            FF_EXTRA_LIBS="-lc++"
            FF_EXTRA_LDFLAGS="-static"
        else
            export CC=gcc CXX=g++
            CXX_RUNTIME="-lstdc++"
            FF_EXTRA_LIBS="-lstdc++"
            FF_EXTRA_LDFLAGS="-static -static-libgcc -static-libstdc++"
        fi
        case "$ARCH" in
            i686) VPX_TARGET=x86-win32-gcc ;;
            x86_64) VPX_TARGET=x86_64-win64-gcc ;;
            aarch64) VPX_TARGET=arm64-win64-gcc ;;
        esac
        ;;
esac
export CFLAGS CXXFLAGS="$CFLAGS" LDFLAGS CPPFLAGS="-I$PREFIX/include"

# --- Helpers ----------------------------------------------------------------

sha256() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# fetch <name>: download (cached), verify and extract into $WORK_DIR/src/<name>
fetch() {
    local name=$1 file="$SOURCES_CACHE/${SRC_FILE[$1]}" dir="$WORK_DIR/src/$1"
    if [[ ! -f "$file" ]]; then
        log "Downloading $name ${SRC_VERSION[$name]}"
        curl -fsSL --retry 5 --retry-delay 5 -o "$file.part" "${SRC_URL[$name]}" \
            || die "downloading ${SRC_URL[$name]} failed"
        mv "$file.part" "$file"
    fi
    local actual
    actual="$(sha256 "$file")"
    if [[ "${SRC_SHA256[$name]}" != SKIP && "$actual" != "${SRC_SHA256[$name]}" ]]; then
        die "checksum mismatch for $file: expected ${SRC_SHA256[$name]}, got $actual"
    fi
    rm -rf "$dir"
    mkdir -p "$dir"
    tar -xf "$file" -C "$dir" --strip-components=1
    cd "$dir"
}

# Replace outdated config.guess/config.sub (e.g. lame 3.100 predates arm64 macOS).
refresh_config_scripts() {
    local d
    d="$(automake --print-libdir 2>/dev/null || true)"
    if [[ -n "$d" && -f "$d/config.sub" ]]; then
        find . -maxdepth 2 \( -name config.sub -o -name config.guess \) | while read -r f; do
            cp "$d/$(basename "$f")" "$f"
        done
    fi
}

autotools_build() {
    refresh_config_scripts
    ./configure --prefix="$PREFIX" --disable-shared --enable-static "${AUTOTOOLS_HOST[@]}" "$@"
    make -j"$JOBS"
    make install
}

cmake_build() {
    local src=$1
    shift
    cmake -S "$src" -B _cmake "${CMAKE_ARGS[@]}" "$@"
    cmake --build _cmake -j "$JOBS"
    cmake --install _cmake
}

# --- Dependencies -----------------------------------------------------------

build_libogg() {
    fetch libogg
    autotools_build
}

build_libvorbis() {
    fetch libvorbis
    # Flag rejected by modern Apple linkers.
    sed -i.bak 's/-force_cpusubtype_ALL//g' configure
    autotools_build --disable-docs --disable-examples --disable-oggtest --with-ogg="$PREFIX"
}

build_opus() {
    fetch opus
    local extra=()
    # No runtime CPU detection for Windows on ARM; NEON is always available on AArch64.
    if [[ $PLATFORM == win-aarch64 ]]; then extra+=(--disable-rtcd); fi
    autotools_build --disable-doc --disable-extra-programs "${extra[@]}"
}

build_lame() {
    fetch lame
    # The exported symbol list is only relevant for shared builds and breaks some linkers.
    sed -i.bak '/lame_init_old/d' include/libmp3lame.sym
    autotools_build --disable-frontend --disable-gtktest --disable-decoder
}

build_x264() {
    fetch x264
    local host=()
    [[ $OS == win ]] && host=(--host="$MINGW_CHOST")
    ./configure --prefix="$PREFIX" --enable-static --enable-pic --disable-cli \
        --disable-opencl "${host[@]}"
    make -j"$JOBS"
    make install-lib-static
}

build_x265() {
    fetch x265
    local asm=ON
    # x265's assembly does not build for Windows on ARM, and 32-bit x86 asm is unmaintained.
    [[ $PLATFORM == win-aarch64 || $ARCH == i686 ]] && asm=OFF
    cmake_build source -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_ASSEMBLY=$asm \
        -DENABLE_PIC=ON -DENABLE_LIBNUMA=OFF
    # x265.pc lists the compiler's implicit link libraries (e.g. -lgcc_s), which
    # break fully static links. Replace them with just the C++ runtime.
    sed -i.bak "s|^Libs.private:.*|Libs.private: $CXX_RUNTIME|" "$PREFIX/lib/pkgconfig/x265.pc"
}

build_libvpx() {
    fetch libvpx
    log "libvpx target: $VPX_TARGET"
    ./configure --prefix="$PREFIX" --target="$VPX_TARGET" --enable-static --disable-shared \
        --enable-pic --enable-vp9-highbitdepth --disable-examples --disable-tools \
        --disable-docs --disable-unit-tests
    make -j"$JOBS"
    make install
}

build_dav1d() {
    fetch dav1d
    meson setup _meson --prefix="$PREFIX_NATIVE" --libdir=lib --buildtype=release \
        --default-library=static -Denable_tools=false -Denable_tests=false
    meson install -C _meson
}

build_svtav1() {
    fetch svtav1
    cmake_build . -DBUILD_APPS=OFF -DBUILD_TESTING=OFF
}

# --- FFmpeg -----------------------------------------------------------------

build_ffmpeg() {
    fetch ffmpeg
    if [[ $OS == linux ]]; then
        # --toolchain=hardened links with -pie; make that a static PIE.
        sed -i 's/add_ldexeflags -fPIE -pie/add_ldexeflags -fPIE -static-pie/' configure
    fi
    local libs=(--enable-zlib) dep
    declare -A flag=([lame]=libmp3lame [opus]=libopus [libvorbis]=libvorbis [x264]=libx264
        [x265]=libx265 [libvpx]=libvpx [dav1d]=libdav1d [svtav1]=libsvtav1)
    for dep in "${!flag[@]}"; do
        if enabled "$dep"; then libs+=("--enable-${flag[$dep]}"); fi
    done

    ./configure --prefix="$PREFIX" \
        --pkg-config=pkg-config --pkg-config-flags=--static \
        --extra-cflags="-I$PREFIX/include" \
        --extra-ldflags="-L$PREFIX/lib $FF_EXTRA_LDFLAGS" \
        --extra-libs="$FF_EXTRA_LIBS" \
        --extra-version=imageio \
        --disable-autodetect --enable-static --disable-shared \
        --disable-debug --disable-doc --disable-ffplay --disable-ffprobe \
        --enable-gpl \
        "${libs[@]}" "${FF_CONFIGURE[@]}" \
        || { tail -n 50 ffbuild/config.log; die "ffmpeg configure failed (end of config.log above)"; }
    make -j"$JOBS"

    OUT_FILE="$OUT_DIR/ffmpeg-$PLATFORM-v$FFMPEG_VERSION$EXE"
    cp "ffmpeg$EXE" "$OUT_FILE"
    chmod +x "$OUT_FILE"
    {
        echo "Built from source by build/build-ffmpeg.sh on $PLATFORM"
        for dep in "${COMPONENTS[@]}"; do
            if enabled "$dep"; then echo "$dep ${SRC_VERSION[$dep]} ${SRC_URL[$dep]}"; fi
        done
        "$OUT_FILE" -hide_banner -version | grep -E '^(built with|configuration)'
    } > "$OUT_FILE.source.txt"
}

write_summary() {
    [[ -n "$SUMMARY_FILE" ]] || return 0
    local size sha compiler config dep time
    size=$(wc -c < "$OUT_FILE")
    sha="$(sha256 "$OUT_FILE")"
    compiler="$(sed -n 's/^built with //p' "$OUT_FILE.source.txt")"
    config="$(sed -n 's/^configuration: //p' "$OUT_FILE.source.txt")"
    {
        echo "### ✅ ffmpeg $FFMPEG_VERSION for $PLATFORM"
        echo
        echo "| | |"
        echo "|---|---|"
        echo "| File | \`$(basename "$OUT_FILE")\` |"
        echo "| Size | $(awk -v s="$size" 'BEGIN { printf "%.1f MiB", s / 1048576 }') |"
        echo "| SHA-256 | \`$sha\` |"
        echo "| Compiler | $compiler |"
        echo "| Build time | $(duration "$SECONDS") |"
        echo
        echo "| Component | Version | Build time |"
        echo "|---|---|---|"
        for dep in "${COMPONENTS[@]}"; do
            enabled "$dep" || continue
            time="${STAGE_TIME[$dep]:-}"
            if [[ -n "$time" ]]; then time="$(duration "$time")"; else time="cached"; fi
            echo "| $dep | ${SRC_VERSION[$dep]} | $time |"
        done
        if [[ -n "${DISABLE// /}" ]]; then
            echo
            echo "Not included:$(printf ' %s' $DISABLE)"
        fi
        echo
        echo "<details><summary>ffmpeg configuration</summary>"
        echo
        echo '```'
        echo "$config"
        echo '```'
        echo
        echo "</details>"
        echo
    } >> "$SUMMARY_FILE"
}

# --- Main -------------------------------------------------------------------

COMPONENTS=(ffmpeg libogg libvorbis opus lame x264 x265 libvpx dav1d svtav1)
if ! enabled libvorbis && enabled libogg; then DISABLE+=" libogg "; fi
log "Building for $PLATFORM in $WORK_DIR (jobs: $JOBS, disabled:$(printf ' %s' $DISABLE))"
for dep in "${COMPONENTS[@]:1}"; do
    enabled "$dep" || continue
    # Stamps let interrupted local builds resume; delete WORK_DIR for a clean build.
    stamp="$WORK_DIR/.done-$dep-${SRC_VERSION[$dep]}"
    if [[ -f "$stamp" ]]; then
        log "Skipping $dep (already built, $stamp)"
        continue
    fi
    begin_stage "$dep" "Building $dep ${SRC_VERSION[$dep]}"
    "build_$dep"
    end_stage
    touch "$stamp"
done
begin_stage ffmpeg "Building ffmpeg $FFMPEG_VERSION for $PLATFORM"
build_ffmpeg
end_stage

log "Built $OUT_FILE in $(duration "$SECONDS")"
cat "$OUT_FILE.source.txt"
write_summary
