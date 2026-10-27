imageio-binaries
================

Repo to place the (relatively small) binary libraries 

The distribution of these precompiled binaries of the FreeImage library is
governed by the FreeImage license, included here as "license-fi.txt".

The original source code is available from http://freeimage.sourceforge.net/ 
No modifications to this code have been made beyond compilation for various
platforms / architectures.

Win32 version from Freeimage project.
Win64 version from http://imageresizing.net/plugins/freeimage


ffmpeg
------

The ffmpeg executables in ffmpeg/ are used by imageio-ffmpeg. New files are
named ffmpeg-<linux|macos|win>-<x86_64|aarch64|i686>-v<version>[.exe].
Two manually triggered GitHub workflows can produce them; both smoke-test the
binaries on each platform and check their platform baseline, and can then
either open a pull request adding them to ffmpeg/ (files must be < 100 MiB)
or create a draft release (assets may be larger, nothing is public until the
release is published).

* "Download ffmpeg" (.github/workflows/download-ffmpeg.yml) compares the
  files in ffmpeg/ with the latest upstream builds (summary in the run) and
  downloads the newer ones, verifying published checksums:
    linux-*      johnvansickle.com/ffmpeg   static glibc, kernel >= 3.2 (x86_64) / 3.7 (aarch64)
    macos-*      osxexperts.net             arm64 needs macOS 12, x86_64 needs macOS 11
    win-x86_64   gyan.dev (essentials)      msvcrt; 9.0.2 is 100.5 MiB, so draft release only
    win-aarch64  github.com/BtbN/FFmpeg-Builds (gpl, release branch); UCRT, no libvpx
  There is no maintained upstream build for win-i686 or linux-i686. The
  johnvansickle release builds have not been updated since 7.0.2. Larger
  Linux builds (BtbN, wader/static-ffmpeg) exceed GitHub's 100 MiB file limit.

* "Build ffmpeg" (.github/workflows/build-ffmpeg.yml) compiles a GPL ffmpeg
  with vcpkg (https://vcpkg.io), natively on each platform. It is GPLv3
  (opencore-amr, vo-amrwbenc and OpenSSL 3 require version 3) and includes:
    video      x264, x265, libvpx, libaom, dav1d, SVT-AV1 (not i686), Theora,
               WebP, HAP (snappy)
    audio      lame, opus, vorbis, Speex, GSM, AMR-NB/WB (opencore-amr,
               vo-amrwbenc)
    filters    zscale (zimg), vidstabdetect/vidstabtransform (vid.stab),
               drawtext (freetype/harfbuzz, no fontconfig: use fontfile=),
               soxr resampling
    other      zlib, bzip2, lzma, iconv, libxml2 (DASH/IMF)
    network    https via schannel (Windows, system certificate store) or
               OpenSSL; srt and sftp (libsrt/libssh, with OpenSSL);
               rtmpe/rtmpte (OpenSSL, or GMP on Windows); sctp (Linux)
    hardware   win-x86_64: NVIDIA (NVENC/CUVID), AMD (AMF), Intel (QSV),
               loaded at runtime if the drivers are present; Linux: V4L2
               mem2mem (e.g. Raspberry Pi)
  Platforms:
    linux-*      Alpine (musl) container, fully static PIE: any glibc/musl distro
    macos-*      macOS >= 11.0 (aarch64) / 10.15 (x86_64), system libraries only
    win-*        MSVC with static CRT: only Windows system DLLs
  https verifies server certificates. Windows uses the system store; the
  OpenSSL builds read /etc/ssl/cert.pem and /etc/ssl/certs, which covers
  common Linux distributions and macOS (elsewhere set SSL_CERT_FILE).
  vcpkg builds ffmpeg and every library from source using its "ports" (build
  recipes). The setup lives in build/vcpkg/:
    vcpkg.json   the ffmpeg features to enable; "builtin-baseline" pins the
                 microsoft/vcpkg commit, and with it the version of every port
    triplets/    one file per platform with the link settings (static
                 libraries, static CRT, macOS deployment target, static PIE)
    ports/       ports for libraries vcpkg does not have (libgsm,
                 opencore-amr, vo-amrwbenc, vidstab)
    ffmpeg-port/ features added to vcpkg's ffmpeg port (gsm, opencore-amr,
                 vo-amrwbenc, zimg, vidstab, v4l2m2m, gmp) and their configure
                 options; build-ffmpeg.py applies them to a copy of the port
                 from the pinned vcpkg commit, so the port still follows the
                 baseline
  build/build-ffmpeg.py clones vcpkg at the pinned commit into _build/vcpkg,
  runs `vcpkg install` and copies the executable to _out/, with a
  .source.txt file listing the versions of everything in it. vcpkg keeps
  built libraries in a binary cache, so later builds only rebuild what
  changed (the workflow caches it between runs).

The build can be run locally with Python 3 and git; on Windows with Visual
Studio (C++ workload), on macOS with
    python3 build/build-ffmpeg.py --install-tools      (uses Homebrew)
and for Linux in an Alpine container with Docker (or wslc):
    docker run --rm -v "$PWD:/work" -w /work -e WORK_DIR=/tmp/build \
        -e VCPKG_DIR=/tmp/vcpkg alpine:3.24 \
        sh -c 'apk add -q python3 && python3 build/build-ffmpeg.py --install-tools'
win-i686 is built on x86_64 Windows with `--platform win-i686`. Test and
inspect the result with:
    bash build/test-ffmpeg.sh _out/ffmpeg-...
    bash build/check-binary.sh _out/ffmpeg-...   (needs `file` and llvm-readobj)
To update the ports, the manually triggered "Update vcpkg baseline" workflow
(.github/workflows/update-vcpkg.yml) moves the baseline to the latest vcpkg
commit and opens (or updates) a pull request from the update-vcpkg branch
listing the version changes, if any port in the build changed. Before
merging, run "Build ffmpeg" on that branch. By hand:
    python3 build/update-vcpkg.py [--commit SHA] [--dry-run]