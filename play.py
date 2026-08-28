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
import tempfile
import time
import urllib.parse

import mpvipc
import subsonic

STATE_DIR = subsonic.STATE_DIR
QUEUE_FILE = os.path.join(STATE_DIR, "queue.json")
COVER_DIR = os.path.join(STATE_DIR, "covers")
# The mpv playlist is written here, fed to mpv, and deleted immediately --
# never at a durable path -- because each entry is a stream URL carrying a
# live Subsonic auth token and salt. See ensure_mpv()/main() below.
EPHEMERAL_DIR = os.path.join(STATE_DIR, "ephemeral")
COVER_CACHE_MAX = 100
COVER_MAX_BYTES = 3 * 1024 * 1024
SOCK_PATH = mpvipc.sock_path()
MIX_DEFAULT_COUNT = 40

# Fanout/size ceilings: the "artist" kind fires one getAlbum call per album,
# and any kind can otherwise be handed an enormous song list by a hostile or
# compromised server. Bound both the request fanout and the resulting queue.
MAX_ARTIST_ALBUMS = 60
MAX_QUEUE_SONGS = 500

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


def _looks_like_image(data):
    """Cheap magic-byte sniff so a hostile/compromised server can't hand
    QML's Image element something other than an actual image to decode."""
    if data[:3] == b"\xff\xd8\xff":
        return True  # JPEG
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return True  # PNG
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return True  # GIF
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return True  # WEBP
    return False


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
    fd = None
    tmp = None
    try:
        subsonic.ensure_private_dir(COVER_DIR)
        data = subsonic.raw(
            subsonic.build_url(base, cfg["user"], cfg["password"], "getCoverArt",
                               "id=%s&size=300" % urllib.parse.quote(cover_id)),
            timeout,
            max_bytes=COVER_MAX_BYTES,
        )
        if not _looks_like_image(data):
            return ""
        fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=COVER_DIR)
        with os.fdopen(fd, "wb", closefd=True) as f:
            fd = None
            f.write(data)
        os.replace(tmp, path)
        tmp = None
        prune_covers()
        return path
    except Exception:
        return ""  # art is decoration; never let it sink playback
    finally:
        if fd is not None:
            os.close(fd)
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass


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
        "id": subsonic.clip_str(s.get("id", ""), 120),
        "title": subsonic.clip_str(s.get("title") or "Unknown"),
        "artist": subsonic.clip_str(s.get("artist") or s.get("displayArtist") or ""),
        "album": subsonic.clip_str(s.get("album") or ""),
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
        out(False, error="usage: play.py <song|album|mix|artist|playlist> <id> [count]")
    kind, item_id = sys.argv[1], sys.argv[2]
    if kind not in ("song", "album", "mix", "artist", "playlist"):
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
        elif kind == "artist":  # every song across every album, in album order
            artist_body = subsonic.call(base, cfg, "getArtist", "id=%s" % urllib.parse.quote(item_id),
                                        timeout=timeout)
            albums = (artist_body.get("artist") or {}).get("album") or []
            if not albums:
                out(False, error="artist has no albums")
            songs = []
            for alb in albums[:MAX_ARTIST_ALBUMS]:
                if len(songs) >= MAX_QUEUE_SONGS:
                    break
                alb_id = alb.get("id")
                if not alb_id:
                    continue
                album_body = subsonic.call(base, cfg, "getAlbum", "id=%s" % urllib.parse.quote(alb_id),
                                           timeout=timeout)
                songs.extend((album_body.get("album") or {}).get("song") or [])
            if not songs:
                out(False, error="no songs found across this artist's albums")
        else:  # playlist
            body = subsonic.call(base, cfg, "getPlaylist", "id=%s" % urllib.parse.quote(item_id),
                                 timeout=timeout)
            songs = (body.get("playlist") or {}).get("entry") or []
            if not songs:
                out(False, error="playlist is empty")
    except subsonic.AuthError:
        out(False, error="auth failed")
    except Exception as e:
        out(False, error=str(e))

    songs = subsonic.clip_list(songs, MAX_QUEUE_SONGS)
    briefs = [song_brief(base, cfg, timeout, s) for s in songs]
    urls = [stream_url(base, cfg, b["id"]) for b in briefs]

    try:
        ensure_mpv()
        subsonic.ensure_private_dir(EPHEMERAL_DIR)
        # Ephemeral, 0600, randomly named, and unlinked the instant mpv has
        # consumed it -- these URLs carry a live Subsonic auth token+salt and
        # must never sit at a durable, predictable path.
        fd, tmp_playlist = tempfile.mkstemp(prefix=".queue-", suffix=".m3u8", dir=EPHEMERAL_DIR)
        try:
            with os.fdopen(fd, "w", closefd=True) as f:
                fd = None
                f.write("#EXTM3U\n")
                for u in urls:
                    f.write(u + "\n")
            mpvipc.command(SOCK_PATH, ["loadlist", tmp_playlist, "replace"])
            mpvipc.command(SOCK_PATH, ["set_property", "pause", False])
        finally:
            if fd is not None:
                os.close(fd)
            try:
                os.unlink(tmp_playlist)
            except OSError:
                pass
    except Exception as e:
        out(False, error="player: %s" % e)

    subsonic.save_json(QUEUE_FILE, briefs)
    out(True, count=len(briefs))


if __name__ == "__main__":
    main()
