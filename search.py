#!/usr/bin/env python3
"""Search the Navidrome library. One compact JSON line on stdout.

    search.py <query>

Read-only: never touches mpv. Invoked only by backend.sh.
"""

import json
import sys
import urllib.parse

import subsonic

RESULT_LIMIT = 8


def out(ok, **kw):
    print(json.dumps({"ok": ok, **kw}))
    sys.exit(0 if ok else 1)


def main():
    if len(sys.argv) != 2:
        out(False, error="usage: search.py <query>")
    query = sys.argv[1].strip()
    if not query:
        out(True, artists=[], albums=[], songs=[])

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
        extra = "query=%s&artistCount=%d&albumCount=%d&songCount=%d" % (
            urllib.parse.quote(query), RESULT_LIMIT, RESULT_LIMIT, RESULT_LIMIT,
        )
        body = subsonic.call(base, cfg, "search3", extra, timeout=timeout)
    except subsonic.AuthError:
        out(False, error="auth failed")
    except Exception as e:
        out(False, error=str(e))

    r = body.get("searchResult3") or {}

    artists = [
        {"id": a.get("id", ""), "name": a.get("name", ""), "albumCount": a.get("albumCount", 0)}
        for a in (r.get("artist") or [])
    ]
    albums = [
        {
            "id": a.get("id", ""),
            "name": a.get("name") or a.get("title", ""),
            "artist": a.get("artist", ""),
        }
        for a in (r.get("album") or [])
    ]
    songs = [
        {
            "id": s.get("id", ""),
            "title": s.get("title", ""),
            "artist": s.get("artist") or s.get("displayArtist", ""),
            "album": s.get("album", ""),
        }
        for s in (r.get("song") or [])
    ]

    out(True, artists=artists, albums=albums, songs=songs)


if __name__ == "__main__":
    main()
