"""Shared helpers for the build/*.py scripts (standard library only)."""

import json
import os
import re
import time
import urllib.error
import urllib.request

UA = {"User-Agent": "imageio-binaries-build"}


def get(url, headers=None, attempts=5):
    """GET url, retrying transient errors (connection, TLS, timeouts, 408/429/5xx)."""
    req = urllib.request.Request(url, headers={**UA, **(headers or {})})
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            # Client errors other than rate limiting will not go away.
            if (e.code < 500 and e.code not in (408, 429)) or attempt == attempts:
                raise
            error = e
        except (urllib.error.URLError, OSError) as e:
            if attempt == attempts:
                raise
            error = e
        print(f"  attempt {attempt} for {url} failed ({error}), retrying in {attempt * 10} s",
              flush=True)
        time.sleep(attempt * 10)


def github_api(path):
    headers = {"Accept": "application/vnd.github+json"}
    if os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GITHUB_TOKEN"]
    return json.loads(get("https://api.github.com/" + path, headers))


def vkey(version):
    """Sort key for dotted numeric versions."""
    return tuple(int(x) for x in re.findall(r"\d+", version))
