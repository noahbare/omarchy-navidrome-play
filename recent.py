#!/usr/bin/env python3
"""Recently played albums -- the default view before you type a search.

    recent.py

Read-only, same shape as search.py's "albums" list.
"""

import json
import sys

import subsonic

RESULT_LIMIT = 12


def out(ok, **kw):
    print(json.dumps({"ok": ok, **kw}))
    sys.exit(0 if ok else 1)


def main():
    try:
        cfg = subsonic.load_config()
    except FileNotFoundError:
        out(False, error="not configured")
    except ValueError:
        out(False, error="bad config")

    try:
        _which, base, timeout, _probe = subsonic.pick_endpoint(cfg)
    except subsonic.AuthError:
        out(False, error="auth failed")
    except Exception:
        out(False, error="unreachable")

    try:
        body = subsonic.call(base, cfg, "getAlbumList2", "type=recent&size=%d" % RESULT_LIMIT,
                             timeout=timeout)
    except subsonic.AuthError:
        out(False, error="auth failed")
    except Exception as e:
        out(False, error=str(e))

    albums = (body.get("albumList2") or {}).get("album") or []
    out(True, albums=[
        {"id": a.get("id", ""), "name": a.get("name") or a.get("title", ""), "artist": a.get("artist", "")}
        for a in albums
    ])


if __name__ == "__main__":
    main()
