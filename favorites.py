#!/usr/bin/env python3
"""Starred (favourited) songs -- one of the default 'home screen' sections.

    favorites.py

Songs, not albums: the star button in this plugin favourites individual
tracks (Subsonic has no "star this whole album" concept from here), so an
album-shaped favourites list would never show anything starred through this
plugin itself. Same shape as search.py's "songs" list.
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
        body = subsonic.call(base, cfg, "getStarred2", timeout=timeout)
    except subsonic.AuthError:
        out(False, error="auth failed")
    except Exception as e:
        out(False, error=str(e))

    songs = (body.get("starred2") or {}).get("song") or []
    out(True, songs=[
        {
            "id": s.get("id", ""),
            "title": s.get("title", ""),
            "artist": s.get("artist") or s.get("displayArtist", ""),
            "album": s.get("album", ""),
            # Carried through so the QML side can derive a "Favorite Artists"
            # section by deduping this list, with no extra network call.
            "artistId": s.get("artistId", ""),
        }
        for s in songs
    ])


if __name__ == "__main__":
    main()
