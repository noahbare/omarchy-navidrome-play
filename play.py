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

import os
import stat
import subprocess
import sys
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

# The "artist" kind fires one getAlbum call per album -- up to 60 of them,
# each individually allowed 20-30s -- with no cap on the total. Bound the
# whole fan-out loop's wall-clock time too, so a server that stalls (but
# doesn't outright fail) every request can't turn "play this artist" into a
# multi-minute hang; a partial queue from what came back in time is better
# than an unbounded one.
ARTIST_BUILD_DEADLINE_SEC = 45

# subsonic.pick_endpoint() hands back a timeout sized for cheap polls (ping,
# getNowPlaying) -- fine for the probe itself, much too tight for the calls
# below. getSimilarSongs2 in particular has to compute a mix server-side and
# measured 4.5s against this Navidrome for a mid-catalog artist; getAlbum and
# getSong are normally fast DB lookups but get the same allowance for safety.
BUILD_TIMEOUT_LAN = 20
BUILD_TIMEOUT_PUBLIC = 30


def out(ok, **kw):
    subsonic.emit(ok, **kw)
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


def _cached_cover_ok(dirfd, name):
    """Fast path for an already-downloaded cover: open it by name relative
    to the held, validated directory fd (no-follow, so a planted symlink is
    refused rather than followed), then re-check that it's still a regular,
    size-bounded, actual image before we trust it enough to hand its path
    to QML. Only reads the first few bytes -- this runs on every song in a
    queue that can be up to 500 entries long."""
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dirfd)
    except OSError:
        return False
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or not (0 < st.st_size <= COVER_MAX_BYTES):
            return False
        with os.fdopen(fd, "rb", closefd=True) as f:
            fd = None
            head = f.read(16)
        return _looks_like_image(head)
    finally:
        if fd is not None:
            os.close(fd)


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
    name = safe + ".img"
    dirfd = None
    tmp_fd = None
    tmp_name = None
    try:
        dirfd = subsonic.open_private_dir(COVER_DIR)
        if _cached_cover_ok(dirfd, name):
            return os.path.join(COVER_DIR, name)
        data = subsonic.raw(
            subsonic.build_url(base, cfg["user"], cfg["password"], "getCoverArt",
                               "id=%s&size=300" % urllib.parse.quote(cover_id)),
            timeout,
            max_bytes=COVER_MAX_BYTES,
        )
        if not _looks_like_image(data):
            return ""
        tmp_fd, tmp_name = subsonic.mkstemp_at(dirfd)
        with os.fdopen(tmp_fd, "wb", closefd=True) as f:
            tmp_fd = None
            f.write(data)
        os.replace(tmp_name, name, src_dir_fd=dirfd, dst_dir_fd=dirfd)
        tmp_name = None
        prune_covers(dirfd)
        return os.path.join(COVER_DIR, name)
    except Exception:
        return ""  # art is decoration; never let it sink playback
    finally:
        if tmp_fd is not None:
            os.close(tmp_fd)
        if tmp_name is not None:
            try:
                os.unlink(tmp_name, dir_fd=dirfd)
            except OSError:
                pass
        if dirfd is not None:
            os.close(dirfd)


def prune_covers(dirfd):
    try:
        names = [n for n in os.listdir(dirfd) if n.endswith(".img")]
        if len(names) <= COVER_CACHE_MAX:
            return
        entries = []
        for n in names:
            try:
                st = os.stat(n, dir_fd=dirfd, follow_symlinks=False)
            except OSError:
                continue
            if not stat.S_ISREG(st.st_mode):
                continue
            entries.append((st.st_mtime, n))
        entries.sort()
        for _, n in entries[: len(entries) - COVER_CACHE_MAX]:
            try:
                os.unlink(n, dir_fd=dirfd)
            except OSError:
                pass
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
            build_deadline = time.time() + ARTIST_BUILD_DEADLINE_SEC
            for alb in albums[:MAX_ARTIST_ALBUMS]:
                if len(songs) >= MAX_QUEUE_SONGS:
                    break
                if time.time() > build_deadline:
                    break  # partial queue beats an unbounded fan-out
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

    dirfd = None
    fd = None
    tmp_name = None
    try:
        ensure_mpv()
        # Ephemeral, 0600, randomly named, and unlinked the instant mpv has
        # consumed it -- these URLs carry a live Subsonic auth token+salt and
        # must never sit at a durable, predictable path. Created relative to
        # a held, validated directory fd so a directory swapped in after
        # validation can't redirect the write.
        dirfd = subsonic.open_private_dir(EPHEMERAL_DIR)
        fd, tmp_name = subsonic.mkstemp_at(dirfd, prefix=".queue-", suffix=".m3u8")
        with os.fdopen(fd, "w", closefd=True) as f:
            fd = None
            f.write("#EXTM3U\n")
            for u in urls:
                f.write(u + "\n")
        tmp_playlist = os.path.join(EPHEMERAL_DIR, tmp_name)
        mpvipc.command(SOCK_PATH, ["loadlist", tmp_playlist, "replace"])
        mpvipc.command(SOCK_PATH, ["set_property", "pause", False])
    except Exception as e:
        out(False, error="player: %s" % e)
    finally:
        if fd is not None:
            os.close(fd)
        if tmp_name is not None:
            try:
                os.unlink(tmp_name, dir_fd=dirfd)
            except OSError:
                pass
        if dirfd is not None:
            os.close(dirfd)

    subsonic.save_json(QUEUE_FILE, briefs)
    out(True, count=len(briefs))


if __name__ == "__main__":
    main()
