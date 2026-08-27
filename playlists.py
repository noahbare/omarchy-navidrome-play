#!/usr/bin/env python3
"""Saved playlists -- one of the default 'home screen' sections.

    playlists.py
"""

import json
import sys

import subsonic


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
        body = subsonic.call(base, cfg, "getPlaylists", timeout=timeout)
    except subsonic.AuthError:
        out(False, error="auth failed")
    except Exception as e:
        out(False, error=str(e))

    playlists = (body.get("playlists") or {}).get("playlist") or []
    out(True, playlists=[
        {"id": p.get("id", ""), "name": p.get("name", ""), "songCount": int(p.get("songCount") or 0)}
        for p in playlists
    ])


if __name__ == "__main__":
    main()
