#!/usr/bin/env python3
"""Star or unstar a song. One compact JSON line on stdout.

    star.py star <songId>
    star.py unstar <songId>

Also patches the queue.json sidecar in place so status.py reflects the new
state on its very next poll, without an extra network round trip.
"""

import os
import sys
import urllib.parse

import subsonic

QUEUE_FILE = os.path.join(subsonic.STATE_DIR, "queue.json")


def out(ok, **kw):
    subsonic.emit(ok, **kw)
    sys.exit(0 if ok else 1)


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("star", "unstar"):
        out(False, error="usage: star.py <star|unstar> <songId>")
    action, song_id = sys.argv[1], sys.argv[2]

    try:
        cfg = subsonic.load_config()
    except FileNotFoundError:
        out(False, error="not configured")
    except ValueError:
        out(False, error="bad config")

    try:
        _which, base, timeout, _probe = subsonic.pick_endpoint(cfg)
        subsonic.call(base, cfg, action, "id=%s" % urllib.parse.quote(song_id), timeout=timeout)
    except subsonic.AuthError:
        out(False, error="auth failed")
    except Exception as e:
        out(False, error=str(e))

    queue = subsonic.load_json(QUEUE_FILE, [])
    for t in queue:
        if t.get("id") == song_id:
            t["starred"] = (action == "star")
    subsonic.save_json(QUEUE_FILE, queue)

    out(True, action=action, starred=(action == "star"))


if __name__ == "__main__":
    main()
