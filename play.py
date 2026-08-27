#!/usr/bin/env python3
"""Build a playback queue from Navidrome and hand it to mpv.

    play.py song <songId>
    play.py album <albumId>
    play.py mix <artistId> [count]      similar-artist radio via getSimilarSongs2

Always REPLACES whatever mpv is currently playing -- this plugin is a
search-and-play launcher, not a queue editor. mpv is spawned once, fully
detached, and left running idle between tracks; later calls (status.py,
control.py) find it again via its fixed IPC socket path.
"""

import json
import os
import subprocess
import sys
import time
import urllib.parse

import mpvipc
import subsonic

STATE_DIR = subsonic.STATE_DIR
QUEUE_FILE = os.path.join(STATE_DIR, "queue.json")
PLAYLIST_FILE = os.path.join(STATE_DIR, "queue.m3u8")
COVER_DIR = os.path.join(STATE_DIR, "covers")
COVER_CACHE_MAX = 100
SOCK_PATH = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "nbare-navidrome-play-mpv.sock")
MIX_DEFAULT_COUNT = 40

# subsonic.pick_endpoint() hands back a timeout sized for cheap polls (ping,
# getNowPlaying) -- fine for the probe itself, much too tight for the calls
# below. getSimilarSongs2 in particular has to compute a mix server-side and
# measured 4.5s against this Navidrome for a mid-catalog artist; getAlbum and
# getSong are normally fast DB lookups but get the same allowance for safety.
BUILD_TIMEOUT_LAN = 20
BUILD_TIMEOUT_PUBLIC = 30


def out(ok, **kw):
    print(json.dumps({"ok": ok, **kw}))
    sys.exit(0 if ok else 1)


def cover_path(base, cfg, cover_id, timeout):
    """Download cover art once and hand QML a local file path.

    Keeps Subsonic credentials out of QML entirely, and status.py (polled
    every couple seconds) never has to touch the network for it.
    """
    if not cover_id:
        return ""
    safe = "".join(c for c in cover_id if c.isalnum() or c in "-_")[:120]
    if not safe:
        return ""
    path = os.path.join(COVER_DIR, safe + ".img")
    if os.path.exists(path):
        return path
    try:
        os.makedirs(COVER_DIR, exist_ok=True)
        data = subsonic.raw(
            subsonic.build_url(base, cfg["user"], cfg["password"], "getCoverArt",
                               "id=%s&size=300" % urllib.parse.quote(cover_id)),
            timeout,
        )
        tmp = path + ".tmp"
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
        prune_covers()
        return path
    except Exception:
        return ""  # art is decoration; never let it sink playback


def prune_covers():
    try:
        files = [os.path.join(COVER_DIR, f) for f in os.listdir(COVER_DIR) if f.endswith(".img")]
        if len(files) <= COVER_CACHE_MAX:
            return
        files.sort(key=lambda p: os.path.getmtime(p))
        for p in files[: len(files) - COVER_CACHE_MAX]:
            os.unlink(p)
    except Exception:
        pass


def stream_url(base, cfg, song_id):
    return subsonic.build_url(base, cfg["user"], cfg["password"], "stream",
                               "id=%s" % urllib.parse.quote(song_id))


def song_brief(base, cfg, timeout, s):
    return {
        "id": s.get("id", ""),
        "title": s.get("title") or "Unknown",
        "artist": s.get("artist") or s.get("displayArtist") or "",
        "album": s.get("album") or "",
        "duration": int(s.get("duration") or 0),
        "cover": cover_path(base, cfg, s.get("coverArt"), timeout),
        # Subsonic includes this key (its value is a timestamp) only when the
        # song IS starred -- free, since we already fetched this song's full
        # metadata to build the queue. Saves status.py (polled every couple
        # of seconds) from ever having to touch the network for it.
        "starred": "starred" in s,
    }


def ensure_mpv():
    if mpvipc.running(SOCK_PATH):
        return
    try:
        os.unlink(SOCK_PATH)
    except FileNotFoundError:
        pass
    # start_new_session detaches mpv from this (short-lived) process's
    # session so it keeps running after we exit.
    subprocess.Popen(
        ["mpv", "--idle=yes", "--no-video", "--no-terminal", "--really-quiet",
         "--input-ipc-server=" + SOCK_PATH],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    deadline = time.time() + 3
    while time.time() < deadline:
        if mpvipc.running(SOCK_PATH):
            return
        time.sleep(0.1)
    raise RuntimeError("mpv did not start")


def main():
    if len(sys.argv) not in (3, 4):
        out(False, error="usage: play.py <song|album|mix> <id> [count]")
    kind, item_id = sys.argv[1], sys.argv[2]
    if kind not in ("song", "album", "mix", "artist"):
        out(False, error="unknown kind %r" % kind)

    try:
        cfg = subsonic.load_config()
    except FileNotFoundError:
        out(False, error="not configured")
    except ValueError:
        out(False, error="bad config")

    try:
        which, base, _probe_timeout, _probe = subsonic.pick_endpoint(cfg)
    except subsonic.AuthError:
        out(False, error="auth failed")
    except Exception:
        out(False, error="unreachable")

    timeout = BUILD_TIMEOUT_PUBLIC if which == "public" else BUILD_TIMEOUT_LAN

    try:
        if kind == "song":
            song = subsonic.call(base, cfg, "getSong", "id=%s" % urllib.parse.quote(item_id),
                                 timeout=timeout).get("song")
            if not song:
                out(False, error="song not found")
            songs = [song]
        elif kind == "album":
            album = subsonic.call(base, cfg, "getAlbum", "id=%s" % urllib.parse.quote(item_id),
                                  timeout=timeout).get("album", {})
            songs = album.get("song") or []
            if not songs:
                out(False, error="album is empty")
        elif kind == "mix":
            count = MIX_DEFAULT_COUNT
            if len(sys.argv) == 4:
                try:
                    count = max(1, int(sys.argv[3]))
                except ValueError:
                    pass
            body = subsonic.call(base, cfg, "getSimilarSongs2",
                                 "id=%s&count=%d" % (urllib.parse.quote(item_id), count),
                                 timeout=timeout)
            songs = (body.get("similarSongs2") or {}).get("song") or []
            if not songs:
                out(False, error="no similar songs found for this artist")
        else:  # artist: every song across every album, in album order
            artist_body = subsonic.call(base, cfg, "getArtist", "id=%s" % urllib.parse.quote(item_id),
                                        timeout=timeout)
            albums = (artist_body.get("artist") or {}).get("album") or []
            if not albums:
                out(False, error="artist has no albums")
            songs = []
            for alb in albums:
                alb_id = alb.get("id")
                if not alb_id:
                    continue
                album_body = subsonic.call(base, cfg, "getAlbum", "id=%s" % urllib.parse.quote(alb_id),
                                           timeout=timeout)
                songs.extend((album_body.get("album") or {}).get("song") or [])
            if not songs:
                out(False, error="no songs found across this artist's albums")
    except subsonic.AuthError:
        out(False, error="auth failed")
    except Exception as e:
        out(False, error=str(e))

    briefs = [song_brief(base, cfg, timeout, s) for s in songs]
    urls = [stream_url(base, cfg, b["id"]) for b in briefs]

    try:
        ensure_mpv()
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(PLAYLIST_FILE, "w") as f:
            f.write("#EXTM3U\n")
            for u in urls:
                f.write(u + "\n")
        mpvipc.command(SOCK_PATH, ["loadlist", PLAYLIST_FILE, "replace"])
        mpvipc.command(SOCK_PATH, ["set_property", "pause", False])
    except Exception as e:
        out(False, error="player: %s" % e)

    subsonic.save_json(QUEUE_FILE, briefs)
    out(True, count=len(briefs))


if __name__ == "__main__":
    main()
