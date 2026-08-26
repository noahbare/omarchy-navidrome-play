#!/usr/bin/env python3
"""Report what mpv is playing right now. One compact JSON line on stdout.

    status.py

Deliberately network-free: this is polled every couple of seconds by the
bar, so it only talks to the local mpv IPC socket and the queue.json sidecar
written by play.py -- never Navidrome. A track's title/artist/cover come
from that sidecar, joined in by playlist position.
"""

import json
import os

import mpvipc
import subsonic

QUEUE_FILE = os.path.join(subsonic.STATE_DIR, "queue.json")
SOCK_PATH = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "nbare-navidrome-play-mpv.sock")


def idle():
    print(json.dumps({"ok": True, "loaded": False}))


def main():
    if not mpvipc.running(SOCK_PATH):
        idle()
        return

    try:
        pos = mpvipc.get_property(SOCK_PATH, "playlist-pos")
        count = mpvipc.get_property(SOCK_PATH, "playlist-count")
        paused = mpvipc.get_property(SOCK_PATH, "pause")
        position = mpvipc.get_property(SOCK_PATH, "time-pos") or 0
        duration = mpvipc.get_property(SOCK_PATH, "duration") or 0
    except mpvipc.MpvError:
        idle()
        return

    if pos is None or pos < 0 or not count:
        idle()
        return

    queue = subsonic.load_json(QUEUE_FILE, [])
    track = queue[pos] if 0 <= pos < len(queue) else {}

    print(json.dumps({
        "ok": True,
        "loaded": True,
        "paused": bool(paused),
        "position": position,
        "duration": duration or track.get("duration", 0),
        "queue_pos": pos,
        "queue_count": count,
        "track": track,
    }))


if __name__ == "__main__":
    main()
