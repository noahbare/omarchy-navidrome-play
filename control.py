#!/usr/bin/env python3
"""Transport control for the local mpv instance this plugin owns.

    control.py <playpause|next|previous|stop>

mpv is ours, spawned by play.py, so control is a direct IPC command rather
than a remote-control call to some other client.
"""

import json
import os
import sys

import mpvipc

SOCK_PATH = os.path.join(os.environ.get("XDG_RUNTIME_DIR") or "/tmp", "nbare-navidrome-play-mpv.sock")
ACTIONS = ("playpause", "next", "previous", "stop")


def out(ok, **kw):
    print(json.dumps({"ok": ok, **kw}))
    sys.exit(0 if ok else 1)


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ACTIONS:
        out(False, error="usage: control.py <%s>" % "|".join(ACTIONS))
    action = sys.argv[1]

    if not mpvipc.running(SOCK_PATH):
        out(False, error="nothing playing")

    try:
        if action == "playpause":
            mpvipc.command(SOCK_PATH, ["cycle", "pause"])
        elif action == "next":
            mpvipc.command(SOCK_PATH, ["playlist-next"])
        elif action == "previous":
            mpvipc.command(SOCK_PATH, ["playlist-prev"])
        elif action == "stop":
            mpvipc.command(SOCK_PATH, ["stop"])
    except mpvipc.MpvError as e:
        out(False, error=str(e))

    out(True, action=action)


if __name__ == "__main__":
    main()
