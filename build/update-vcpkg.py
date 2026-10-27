#!/usr/bin/env python3
"""Update the vcpkg baseline that pins the ffmpeg build's port versions.

Moves "builtin-baseline" in build/vcpkg/vcpkg.json to the latest commit of
microsoft/vcpkg (or the given one) and reports which of the ports in the
build (ffmpeg and its enabled libraries, transitively) change version.

Usage:
    python3 build/update-vcpkg.py [--commit SHA] [--dry-run] [--body FILE]

Exit code 0 if the baseline was (or, with --dry-run, would be) updated
because ports in the build changed version, 3 if nothing relevant changed.
--body writes a Markdown description of the changes (for a pull request).
"""

import argparse
import json
import re
import subprocess
import sys
import urllib.error
from pathlib import Path

from common import get, write_summary

VCPKG_DIR = Path(__file__).resolve().parent / "vcpkg"
MANIFEST = VCPKG_DIR / "vcpkg.json"
REPO = "microsoft/vcpkg"
RAW = f"https://raw.githubusercontent.com/{REPO}"


def latest_commit():
    out = subprocess.run(["git", "ls-remote", f"https://github.com/{REPO}", "refs/heads/master"],
                         capture_output=True, text=True, check=True).stdout
    return out.split()[0]


def port_manifest(commit, port, cache={}):
    """A port's vcpkg.json: the local one from build/vcpkg/ports/ if there is one,
    otherwise vcpkg's at the given commit, plus our extra features for ffmpeg."""
    key = (commit, port)
    if key not in cache:
        local = VCPKG_DIR / "ports" / port / "vcpkg.json"
        if local.exists():
            m = json.loads(local.read_text(encoding="utf-8"))
        else:
            try:
                m = json.loads(get(f"{RAW}/{commit}/ports/{port}/vcpkg.json"))
            except urllib.error.HTTPError as e:
                if e.code != 404:
                    raise
                m = {}  # not in vcpkg at this commit
        if port == "ffmpeg":
            extra = json.loads((VCPKG_DIR / "ffmpeg-port" / "features.json")
                               .read_text(encoding="utf-8"))
            m.setdefault("features", {}).update(
                {k: v for k, v in extra.items() if not k.startswith("$")})
        cache[key] = m
    return cache[key]


def names(items):
    for i in items or []:
        yield i if isinstance(i, str) else i["name"]


def deps_of(deps):
    """(name, features) of non-host dependencies (platform qualifiers are ignored)."""
    for d in deps or []:
        if isinstance(d, str):
            yield d, []
        elif not d.get("host"):
            yield d["name"], list(names(d.get("features")))


def ports_in_build(commit, manifest):
    """All target ports the manifest pulls in at the given vcpkg commit."""
    todo = list(deps_of(manifest["dependencies"]))
    done = set()
    while todo:
        port, features = todo.pop()
        m = port_manifest(commit, port)
        if not any(p == port for p, _ in done):
            todo += deps_of(m.get("dependencies"))
            # Default features are enabled unless the top level turns them off.
            features = features + list(names(m.get("default-features")))
        for f in features:
            if (port, f) not in done:
                done.add((port, f))
                todo += deps_of(m.get("features", {}).get(f, {}).get("dependencies"))
        done.add((port, None))
    return sorted({p for p, _ in done})


def version_of(baseline, port):
    v = baseline["default"].get(port)
    if not v:
        return "-"
    return v["baseline"] + (f"#{v['port-version']}" if v.get("port-version") else "")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--commit", help="vcpkg commit (default: latest on master)")
    parser.add_argument("--dry-run", action="store_true", help="only report the changes")
    parser.add_argument("--body", type=Path, help="write a Markdown description to this file")
    args = parser.parse_args()

    text = MANIFEST.read_text(encoding="utf-8")
    manifest = json.loads(text)
    old = manifest["builtin-baseline"]
    new = args.commit or latest_commit()
    if new == old:
        print(f"Already at {old}")
        return 3

    old_base = json.loads(get(f"{RAW}/{old}/versions/baseline.json"))
    new_base = json.loads(get(f"{RAW}/{new}/versions/baseline.json"))
    ports = sorted(set(ports_in_build(old, manifest)) | set(ports_in_build(new, manifest)))
    changes = [(p, version_of(old_base, p), version_of(new_base, p)) for p in ports
               if version_of(old_base, p) != version_of(new_base, p)]

    compare = f"https://github.com/{REPO}/compare/{old[:12]}...{new[:12]}"
    if changes:
        rows = "\n".join(f"| {p} | {a} | {b} |" for p, a, b in changes)
        md = (f"Updates the vcpkg baseline from `{old[:12]}` to `{new[:12]}` ([diff]({compare})).\n\n"
              f"| Port | Old | New |\n|---|---|---|\n{rows}\n")
    else:
        md = f"No port in the build changes between `{old[:12]}` and `{new[:12]}`.\n"
    print(md)
    write_summary(md)
    if args.body:
        args.body.write_text(md, encoding="utf-8")
    if not changes:
        return 3
    if not args.dry_run:
        MANIFEST.write_text(re.sub(r'("builtin-baseline":\s*")[0-9a-f]+"', rf'\g<1>{new}"', text),
                            encoding="utf-8")
        print(f"Updated {MANIFEST}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
