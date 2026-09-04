#!/usr/bin/env python3
"""Search the Navidrome library. One compact JSON line on stdout.

    search.py <query>

Read-only: never touches mpv. Invoked only by backend.sh.
"""

import sys
import urllib.parse

import subsonic

RESULT_LIMIT = 8


def out(ok, **kw):
    subsonic.emit(ok, **kw)
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
        {
            "id": subsonic.clip_str(a.get("id", ""), 120),
            "name": subsonic.clip_str(a.get("name", "")),
            "albumCount": int(a.get("albumCount") or 0),
        }
        for a in subsonic.clip_list(r.get("artist") or [], RESULT_LIMIT)
    ]
    albums = [
        {
            "id": subsonic.clip_str(a.get("id", ""), 120),
            "name": subsonic.clip_str(a.get("name") or a.get("title", "")),
            "artist": subsonic.clip_str(a.get("artist", "")),
        }
        for a in subsonic.clip_list(r.get("album") or [], RESULT_LIMIT)
    ]
    songs = [
        {
            "id": subsonic.clip_str(s.get("id", ""), 120),
            "title": subsonic.clip_str(s.get("title", "")),
            "artist": subsonic.clip_str(s.get("artist") or s.get("displayArtist", "")),
            "album": subsonic.clip_str(s.get("album", "")),
        }
        for s in subsonic.clip_list(r.get("song") or [], RESULT_LIMIT)
    ]

    out(True, artists=artists, albums=albums, songs=songs)


if __name__ == "__main__":
    main()
