#!/usr/bin/env python3
"""Build a lean, self-contained ffmpeg executable with vcpkg.

* build/vcpkg/vcpkg.json lists the ffmpeg features; its "builtin-baseline" pins
  the vcpkg commit and with it the version of every port.
* build/vcpkg/ports/ has ports for libraries vcpkg does not have, and
  build/vcpkg/ffmpeg-port/ extra features for vcpkg's ffmpeg port (e.g. gsm),
  which this script adds to a copy of that port.
* build/vcpkg/triplets/ has one triplet per platform with the link settings:
    linux-*    run inside an Alpine (musl) container -> fully static PIE
    macos-*    macOS >= 11.0 (aarch64) / 10.15 (x86_64), system libraries only
    win-*      MSVC with static CRT, only Windows system DLLs
  Builds are native (no cross-compiling), except win-i686 on an x86_64 host.

vcpkg is cloned at the baseline commit into _build/vcpkg (or $VCPKG_DIR) and
bootstrapped on first use. The executable is written to _out/ as
ffmpeg-<linux|macos|win>-<x86_64|aarch64|i686>-v<version>[.exe], with a
.source.txt file listing the versions of everything in it.

Usage: python3 build/build-ffmpeg.py [--platform PLATFORM] [--install-tools]

Environment variables (optional): WORK_DIR (default _build/<platform>),
OUT_DIR (default _out), VCPKG_DIR (vcpkg clone, default _build/vcpkg),
VCPKG_DEFAULT_BINARY_CACHE / VCPKG_BINARY_SOURCES (vcpkg's binary cache, by
default in the user's cache directory).
"""

import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import time
from pathlib import Path

from common import write_summary

ROOT = Path(__file__).resolve().parent.parent
MANIFEST_DIR = ROOT / "build" / "vcpkg"
VCPKG_DIR = Path(os.environ.get("VCPKG_DIR") or ROOT / "_build" / "vcpkg").resolve()
VCPKG_REPO = "https://github.com/microsoft/vcpkg"

OS_NAMES = {"linux": "linux", "darwin": "macos", "win32": "win"}
ARCH_NAMES = {"x86_64": "x86_64", "amd64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64",
              "i686": "i686", "i386": "i686", "x86": "i686"}
TRIPLET_OS = {"linux": "linux", "macos": "osx", "win": "windows"}
TRIPLET_ARCH = {"x86_64": "x64", "aarch64": "arm64", "i686": "x86"}
# Host-only ports (besides vcpkg-*) that are not part of the executable.
BUILD_TOOLS = {"ffmpeg-bin2c", "pkgconf"}

GHA = os.environ.get("GITHUB_ACTIONS") == "true"


def log(msg):
    print(msg if GHA else f"\033[1;34m--> {msg}\033[0m", flush=True)


def group(title):
    print(f"::group::{title}" if GHA else f"\n\033[1;34m==> {title}\033[0m", flush=True)


def endgroup():
    if GHA:
        print("::endgroup::", flush=True)


class BuildError(Exception):
    pass


def run(*cmd, **kwargs):
    log(" ".join(str(c) for c in cmd))
    subprocess.run([str(c) for c in cmd], check=True, **kwargs)


def detect_platform():
    os_name = OS_NAMES.get(sys.platform)
    arch = ARCH_NAMES.get(platform.machine().lower())
    if not os_name or not arch:
        raise BuildError(f"unsupported host {sys.platform}/{platform.machine()}, use --platform")
    return f"{os_name}-{arch}"


def install_tools(os_name):
    """Install the build tools vcpkg does not download itself."""
    group("Installing build tools")
    if os_name == "linux":
        if not Path("/etc/alpine-release").exists():
            raise BuildError("--install-tools on Linux expects an Alpine container")
        # Real ninja: samurai rejects options after targets (`ninja install -v`).
        # lksctp-tools-dev: only the header for ffmpeg's sctp protocol.
        run("apk", "add", "--no-cache", "autoconf", "autoconf-archive", "automake", "bash",
            "build-base", "cmake", "coreutils", "curl", "git", "libtool", "linux-headers",
            "lksctp-tools-dev", "nasm", "ninja-is-really-ninja", "perl", "pkgconf", "python3",
            "tar", "unzip", "xz", "zip")
    elif os_name == "macos":
        run("brew", "install", "--quiet", "autoconf", "autoconf-archive", "automake",
            "libtool", "nasm", "pkgconf")
    endgroup()


def baseline():
    return json.loads((MANIFEST_DIR / "vcpkg.json").read_text())["builtin-baseline"]


def setup_vcpkg(commit):
    """Clone vcpkg at the pinned commit (shallow) and bootstrap it."""
    group(f"Setting up vcpkg {commit[:12]}")
    git = ["git", "-C", VCPKG_DIR]
    if not (VCPKG_DIR / ".git").exists():
        VCPKG_DIR.mkdir(parents=True, exist_ok=True)
        run(*git, "init", "-q")
        run(*git, "remote", "add", "origin", VCPKG_REPO)
    head = subprocess.run([*map(str, git), "rev-parse", "HEAD"], capture_output=True,
                          text=True).stdout.strip()
    if head != commit:
        for attempt in range(1, 4):
            try:
                run(*git, "fetch", "-q", "--depth", "1", "origin", commit)
                break
            except subprocess.CalledProcessError:
                if attempt == 3:
                    raise
                time.sleep(attempt * 15)
        run(*git, "checkout", "-q", "--force", "FETCH_HEAD")
        # A new vcpkg commit may need a newer vcpkg tool.
        for exe in ("vcpkg", "vcpkg.exe"):
            (VCPKG_DIR / exe).unlink(missing_ok=True)
    exe = VCPKG_DIR / ("vcpkg.exe" if sys.platform == "win32" else "vcpkg")
    if not exe.exists():
        if sys.platform == "win32":
            run("cmd", "/c", VCPKG_DIR / "bootstrap-vcpkg.bat", "-disableMetrics")
        else:
            run("sh", VCPKG_DIR / "bootstrap-vcpkg.sh", "-disableMetrics")
    endgroup()
    return exe


def installed_packages(install_root, triplet):
    """Installed (package, version) pairs for the triplet, from vcpkg's status database.

    The host triplet is the target triplet, so build-only helper ports are
    installed for it too; they are left out.
    """
    pkgs = []
    text = (install_root / "vcpkg" / "status").read_text(encoding="utf-8")
    for block in text.split("\n\n"):
        fields = dict(line.split(": ", 1) for line in block.splitlines() if ": " in line)
        if (fields.get("Architecture") != triplet or "Feature" in fields
                or not fields.get("Status", "").endswith(" installed")
                or fields["Package"].startswith("vcpkg-") or fields["Package"] in BUILD_TOOLS):
            continue
        version = fields["Version"]
        if fields.get("Port-Version", "0") != "0":
            version += "#" + fields["Port-Version"]
        pkgs.append((fields["Package"], version))
    return sorted(pkgs)


def make_ffmpeg_port(dest):
    """Copy vcpkg's ffmpeg port to dest, adding the features in build/vcpkg/ffmpeg-port/.

    The port is not modified otherwise, so it follows the vcpkg baseline.
    """
    extra_dir = MANIFEST_DIR / "ffmpeg-port"
    shutil.rmtree(dest, ignore_errors=True)
    shutil.copytree(VCPKG_DIR / "ports" / "ffmpeg", dest)

    manifest_file = dest / "vcpkg.json"
    manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
    extra = json.loads((extra_dir / "features.json").read_text(encoding="utf-8"))
    for name, feature in extra.items():
        if name.startswith("$"):
            continue
        if name in manifest["features"]:
            raise BuildError(f"vcpkg's ffmpeg port now has a '{name}' feature; "
                             f"remove it from {extra_dir / 'features.json'}")
        manifest["features"][name] = feature
    manifest_file.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    anchor = 'message(STATUS "Building Options: ${OPTIONS}")'
    portfile = dest / "portfile.cmake"
    text = portfile.read_text(encoding="utf-8")
    if text.count(anchor) != 1:
        raise BuildError(f"cannot add options to {portfile}: '{anchor}' not found once")
    include = 'include("${CMAKE_CURRENT_LIST_DIR}/imageio-options.cmake")\n'
    portfile.write_text(text.replace(anchor, include + anchor), encoding="utf-8")
    shutil.copyfile(extra_dir / "options.cmake", dest / "imageio-options.cmake")


def build(plat, work_dir, out_dir):
    os_name, arch = plat.split("-")
    triplet = f"{TRIPLET_ARCH[arch]}-{TRIPLET_OS[os_name]}-imageio"
    # vcpkg (including its bootstrap script) requires these to exist.
    for var in ("VCPKG_DEFAULT_BINARY_CACHE", "VCPKG_DOWNLOADS"):
        if os.environ.get(var):
            Path(os.environ[var]).mkdir(parents=True, exist_ok=True)
    commit = baseline()
    vcpkg = setup_vcpkg(commit)

    env = dict(os.environ)
    # Only use our clone, not e.g. the one bundled with Visual Studio.
    env.pop("VCPKG_ROOT", None)
    env["VCPKG_DISABLE_METRICS"] = "1"
    if os_name == "linux":
        # Required on musl and on arm64 Linux: use the system cmake/ninja/etc.
        env["VCPKG_FORCE_SYSTEM_BINARIES"] = "1"

    overlay = work_dir / "ports"
    make_ffmpeg_port(overlay / "ffmpeg")

    install_root = work_dir / "installed"
    group(f"Building ffmpeg for {plat} (triplet {triplet})")
    start = time.monotonic()
    try:
        run(vcpkg, "install", "--vcpkg-root", VCPKG_DIR, "--x-manifest-root", MANIFEST_DIR,
            "--overlay-ports", overlay,
            "--x-install-root", install_root, "--x-buildtrees-root", work_dir / "buildtrees",
            "--x-packages-root", work_dir / "packages", "--triplet", triplet,
            "--host-triplet", triplet, "--clean-packages-after-build", "--no-print-usage",
            env=env)
    except subprocess.CalledProcessError:
        raise BuildError(f"vcpkg install failed; logs are in {work_dir / 'buildtrees'}")
    endgroup()
    elapsed = time.monotonic() - start

    pkgs = installed_packages(install_root, triplet)
    version = dict(pkgs)["ffmpeg"].split("#")[0]
    exe = ".exe" if os_name == "win" else ""
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"ffmpeg-{plat}-v{version}{exe}"
    shutil.copyfile(install_root / triplet / "tools" / "ffmpeg" / f"ffmpeg{exe}", out)
    out.chmod(0o755)

    info = subprocess.run([out, "-hide_banner", "-version"], capture_output=True, text=True,
                          check=True).stdout
    built_with = [line for line in info.splitlines()
                  if line.startswith(("built with", "configuration"))]
    source = [f"Built from source by build/build-ffmpeg.py on {plat} with vcpkg",
              f"({VCPKG_REPO}/tree/{commit}, triplet {triplet})"]
    source += [f"{name} {ver}" for name, ver in pkgs]
    source += built_with
    Path(f"{out}.source.txt").write_text("\n".join(source) + "\n", encoding="utf-8")
    log(f"Built {out} in {elapsed / 60:.0f} min")
    print("\n".join(source))

    data = out.read_bytes()
    rows = "\n".join(f"| {name} | {ver} |" for name, ver in pkgs)
    config = next((line.split(": ", 1)[1] for line in built_with
                   if line.startswith("configuration")), "")
    write_summary(
        f"### ✅ ffmpeg {version} for {plat}\n\n"
        f"- **File:** `{out.name}` ({len(data) / 1048576:.1f} MiB)\n"
        f"- **SHA-256:** `{hashlib.sha256(data).hexdigest()}`\n"
        f"- **vcpkg:** [{commit[:12]}]({VCPKG_REPO}/tree/{commit}), triplet `{triplet}`\n"
        f"- **Build time:** {elapsed / 60:.0f} min\n\n"
        f"| Package | Version |\n|---|---|\n{rows}\n\n"
        f"<details><summary>ffmpeg configuration</summary>\n\n```\n{config}\n```\n\n</details>\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--platform", help="e.g. win-i686 (default: the host platform)")
    parser.add_argument("--install-tools", action="store_true",
                        help="install build tools first (apk on Alpine, brew on macOS)")
    args = parser.parse_args()
    plat = args.platform
    try:
        plat = plat or detect_platform()
        os_name, _, arch = plat.partition("-")
        if os_name not in TRIPLET_OS or arch not in TRIPLET_ARCH:
            raise BuildError(f"unknown platform {plat}")
        if args.install_tools:
            install_tools(os_name)
        work_dir = Path(os.environ.get("WORK_DIR") or ROOT / "_build" / plat).resolve()
        out_dir = Path(os.environ.get("OUT_DIR") or ROOT / "_out").resolve()
        build(plat, work_dir, out_dir)
    except (BuildError, subprocess.CalledProcessError) as e:
        endgroup()
        print(f"ERROR: {e}", file=sys.stderr)
        if GHA:
            print(f"::error title=ffmpeg build failed ({plat})::{e}")
        write_summary(f"### ❌ ffmpeg build for {plat} failed\n\n{e}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
