#!/usr/bin/env python3
"""Check upstream ffmpeg builds for new releases and download them.

    download-ffmpeg.py check [--platforms LIST]
    download-ffmpeg.py fetch [--platforms LIST] [--out DIR]

LIST is "all", "outdated" (default: platforms whose upstream version is newer
than the newest file in ffmpeg/) or a comma-separated list of platforms.
Downloaded executables are named like the existing files in ffmpeg/:
ffmpeg-<linux|macos|win>-<arch>-v<version>[.exe]

Upstream sources (the same providers as the existing binaries where they are
still maintained):

    linux-*        https://johnvansickle.com/ffmpeg/ (static, glibc)
    macos-*        https://www.osxexperts.net/
    win-x86_64     https://www.gyan.dev/ffmpeg/builds/ (essentials)
    win-aarch64    https://github.com/BtbN/FFmpeg-Builds (gpl, release branch)

When run in GitHub Actions, results are also written to the job summary and
the platforms to process are set as the `platforms` step output (JSON).
"""

import argparse
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import zipfile
from pathlib import Path

from common import get, github_api, vkey

ROOT = Path(__file__).resolve().parent.parent
FFMPEG_DIR = ROOT / "ffmpeg"

# Older file names used in ffmpeg/, mapped to platform names.
LEGACY_NAMES = {
    "linux64": "linux-x86_64", "linuxaarch64": "linux-aarch64", "linux32": "linux-i686",
    "osx64": "macos-x86_64", "osx-x86": "macos-x86_64", "osx-arm64": "macos-aarch64",
    "win64": "win-x86_64", "win32": "win-i686",
}


# --- Upstream sources ---------------------------------------------------------
# Each latest_* function returns a dict with: version, url, checksum (algo, hex)
# or None, member (regex for the ffmpeg executable inside the archive), source.

def latest_johnvansickle(arch):
    readme = get("https://johnvansickle.com/ffmpeg/release-readme.txt").decode()
    version = re.search(r"version:\s*([\d.]+)", readme).group(1)
    url = f"https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-{arch}-static.tar.xz"
    md5 = get(url + ".md5").decode().split()[0]
    return dict(version=version, url=url, checksum=("md5", md5), member=r"[^/]+/ffmpeg$",
                source="johnvansickle.com")


def latest_osxexperts(kind):
    html = get("https://www.osxexperts.net/").decode("utf-8", "replace")
    label = "Apple Silicon" if kind == "arm" else "Intel"
    m = re.search(r'href="(https://www\.osxexperts\.net/ffmpeg\d+' + kind
                  + r'\.zip)"[^>]*>\s*Download ffmpeg ([\d.]+) \(' + label, html)
    if not m:
        raise RuntimeError(f"no ffmpeg ({label}) download found on osxexperts.net")
    return dict(version=m.group(2), url=m.group(1), checksum=None, member=r"(^|/)ffmpeg$",
                source="osxexperts.net")


def latest_gyan():
    version = get("https://www.gyan.dev/ffmpeg/builds/release-version").decode().strip()
    url = f"https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-{version}-essentials_build.zip"
    sha = get(url + ".sha256").decode().split()[0]
    return dict(version=version, url=url, checksum=("sha256", sha), member=r"/bin/ffmpeg\.exe$",
                source="gyan.dev (essentials)")


def latest_btbn(target):
    # Dated releases have immutable assets named after `git describe` of the
    # release branch, e.g. ffmpeg-n9.0.2-29-g6dfaba896f-winarm64-gpl-9.0.zip
    pattern = re.compile(r"ffmpeg-n(\d+\.\d+(?:\.\d+)?)-\d+-g[0-9a-f]+-" + target
                         + r"-gpl-\d+\.\d+\.zip$")
    for rel in github_api("repos/BtbN/FFmpeg-Builds/releases?per_page=5"):
        if rel["tag_name"] == "latest":
            continue
        assets = {a["name"]: a["browser_download_url"] for a in rel["assets"]}
        found = [(vkey(m.group(1)), m.group(1), name) for name in assets
                 if (m := pattern.match(name))]
        if not found:
            continue
        _, version, name = max(found)
        sums = get(assets["checksums.sha256"]).decode()
        sha = next(line.split()[0] for line in sums.splitlines() if line.endswith(name))
        return dict(version=version, url=assets[name], checksum=("sha256", sha),
                    member=r"/bin/ffmpeg\.exe$", source=f"BtbN/FFmpeg-Builds {rel['tag_name']}")
    raise RuntimeError(f"no BtbN {target} release found")


SOURCES = {
    "linux-x86_64": lambda: latest_johnvansickle("amd64"),
    "linux-aarch64": lambda: latest_johnvansickle("arm64"),
    "macos-x86_64": lambda: latest_osxexperts("intel"),
    "macos-aarch64": lambda: latest_osxexperts("arm"),
    "win-x86_64": latest_gyan,
    "win-aarch64": lambda: latest_btbn("winarm64"),
}


# --- Repository state ---------------------------------------------------------

def current_versions():
    """Newest version of each platform's ffmpeg executable in ffmpeg/."""
    # Use the git index when possible so CI can use a blobless/sparse checkout.
    try:
        names = subprocess.run(["git", "ls-tree", "--name-only", "HEAD", "ffmpeg/"], cwd=ROOT,
                               capture_output=True, text=True, check=True).stdout.split()
        names = [n.split("/", 1)[1] for n in names]
    except (OSError, subprocess.CalledProcessError):
        names = [f.name for f in FFMPEG_DIR.glob("ffmpeg-*")]
    newest = {}
    for name in names:
        m = re.match(r"ffmpeg-(.+)-v([\d.]+?)(\.exe)?$", name)
        if not m:
            continue
        platform = LEGACY_NAMES.get(m.group(1), m.group(1))
        if platform not in newest or vkey(m.group(2)) > vkey(newest[platform]):
            newest[platform] = m.group(2)
    return newest


def output_name(platform, version):
    return f"ffmpeg-{platform}-v{version}" + (".exe" if platform.startswith("win") else "")


# --- Commands -----------------------------------------------------------------

def select(arg, upstream, current):
    if arg == "all":
        return list(upstream)
    if arg == "outdated":
        return [p for p, info in upstream.items()
                if p not in current or vkey(info["version"]) > vkey(current[p])]
    names = [p.strip() for p in arg.split(",") if p.strip()]
    unknown = set(names) - set(SOURCES)
    if unknown:
        sys.exit(f"unknown platform(s): {', '.join(sorted(unknown))}; known: {', '.join(SOURCES)}")
    return names


def check(args):
    current = current_versions()
    upstream = {}
    rows = ["| Platform | In repo | Upstream | Source |", "|---|---|---|---|"]
    for platform in sorted(set(SOURCES) | set(current)):
        if platform not in SOURCES:
            rows.append(f"| {platform} | {current[platform]} | - | no upstream build |")
            continue
        try:
            upstream[platform] = info = SOURCES[platform]()
        except Exception as e:  # report and continue with the other sources
            rows.append(f"| {platform} | {current.get(platform, '-')} | error | {e} |")
            continue
        newer = platform not in current or vkey(info["version"]) > vkey(current[platform])
        rows.append(f"| {platform} | {current.get(platform, '-')} | {info['version']}"
                    f"{' **(newer)**' if newer else ''} | [{info['source']}]({info['url']}) |")
    try:
        releases = get("https://ffmpeg.org/releases/").decode()
        latest = max(re.findall(r"ffmpeg-(\d+\.\d+(?:\.\d+)?)\.tar\.xz\"", releases), key=vkey)
        rows.append(f"\nLatest ffmpeg.org release: **{latest}**")
    except Exception as e:
        rows.append(f"\nCould not determine latest ffmpeg.org release: {e}")

    report = "\n".join(rows)
    print(report)
    selected = select(args.platforms, upstream, current)
    print("\nSelected:", ", ".join(selected) or "nothing")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("## Upstream ffmpeg builds\n\n" + report + "\n")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(f"platforms={json.dumps(selected)}\n")
    return upstream, selected


def extract(data, url, member_re):
    member_re = re.compile(member_re)
    if url.endswith(".zip"):
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            names = [n for n in z.namelist() if member_re.search(n) and "__MACOSX" not in n]
            if len(names) == 1:
                return z.read(names[0])
    else:
        with tarfile.open(fileobj=io.BytesIO(data)) as t:
            names = [m for m in t.getmembers() if m.isfile() and member_re.search(m.name)]
            if len(names) == 1:
                return t.extractfile(names[0]).read()
    raise RuntimeError(f"expected one ffmpeg executable in {url}, found {names}")


def fetch(args):
    upstream, selected = check(args)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    gha = os.environ.get("GITHUB_ACTIONS") == "true"
    rows = ["| File | Size | Upstream checksum | SHA-256 |", "|---|---|---|---|"]
    for platform in selected:
        info = upstream.get(platform) or sys.exit(f"no upstream info for {platform}")
        title = f"Downloading {platform} {info['version']}"
        print(f"::group::{title}" if gha else f"\n{title}", flush=True)
        print(info["url"])
        data = get(info["url"])
        if info["checksum"]:
            algo, expected = info["checksum"]
            actual = hashlib.new(algo, data).hexdigest()
            if actual.lower() != expected.lower():
                msg = f"{algo} mismatch for {info['url']}: {actual} != {expected}"
                sys.exit(f"::error title=Download failed ({platform})::{msg}" if gha else msg)
            checked = f"{algo} verified"
        else:
            checked = "none published"
        print(f"  {checked}")
        target = out / output_name(platform, info["version"])
        target.write_bytes(extract(data, info["url"], info["member"]))
        target.chmod(0o755)
        sha = hashlib.sha256(target.read_bytes()).hexdigest()
        (out / (target.name + ".source.txt")).write_text(f"{info['source']}\n{info['url']}\nsha256 {sha}\n")
        size = f"{target.stat().st_size / 2**20:.1f} MiB"
        print(f"  -> {target} ({size})")
        if gha:
            print("::endgroup::")
        rows.append(f"| [`{target.name}`]({info['url']}) | {size} | {checked} | `{sha}` |")
    if os.environ.get("GITHUB_STEP_SUMMARY") and selected:
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("\n## Downloaded\n\n" + "\n".join(rows) + "\n")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("command", choices=["check", "fetch"])
    p.add_argument("--platforms", default="outdated")
    p.add_argument("--out", default=str(ROOT / "_out"))
    args = p.parse_args()
    (check if args.command == "check" else fetch)(args)


if __name__ == "__main__":
    main()
