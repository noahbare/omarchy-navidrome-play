#!/usr/bin/env python3
"""Minimal client for mpv's JSON IPC socket.

One connection per call: every script here is a fresh process invoked by
QML per action, so there is no long-lived Python side to hold the socket
open. mpv itself is the only thing that stays running between calls.
"""

import json
import os
import socket
import stat
import time

import subsonic

SOCK_NAME = "nbare-navidrome-play-mpv.sock"

# The receive loop accumulates bytes until it sees a newline; without a
# ceiling, a wedged mpv or a socket impersonated by another local user could
# grow that buffer without bound.
MAX_TOTAL_BYTES = 2 * 1024 * 1024


class MpvError(Exception):
    pass


def _runtime_dir():
    """A verified-private per-user directory to put the IPC socket in.

    XDG_RUNTIME_DIR is used only if it actually is private to us; otherwise
    fall back to a directory we create and own under our own state dir,
    rather than a globally-writable path like /tmp where another local user
    could pre-create or impersonate the socket name.
    """
    d = os.environ.get("XDG_RUNTIME_DIR")
    if d:
        try:
            st = os.lstat(d)
            if stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid() and not (
                st.st_mode & (stat.S_IRWXG | stat.S_IRWXO)
            ):
                return d
        except OSError:
            pass
    fallback = os.path.join(subsonic.STATE_DIR, "run")
    subsonic.ensure_private_dir(fallback)
    return fallback


def sock_path():
    return os.path.join(_runtime_dir(), SOCK_NAME)


def _verify_socket(path):
    """Refuse to connect to anything but a genuine AF_UNIX socket we own, so
    another local user can't pre-create or impersonate the endpoint."""
    try:
        st = os.lstat(path)
    except OSError as e:
        raise MpvError(str(e))
    if not stat.S_ISSOCK(st.st_mode):
        raise MpvError("not a socket: %s" % path)
    if st.st_uid != os.getuid():
        raise MpvError("socket not owned by current user: %s" % path)


def command(sock_path, cmd, timeout=2.0):
    """Send one mpv IPC command and return its `data` field.

    Raises MpvError if the socket is unreachable, mpv rejects the command,
    or no matching response arrives before `timeout`.
    """
    _verify_socket(sock_path)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(sock_path)
        req_id = int(time.time() * 1000) % 1000000
        s.sendall((json.dumps({"command": cmd, "request_id": req_id}) + "\n").encode())

        buf = b""
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                chunk = s.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            buf += chunk
            if len(buf) > MAX_TOTAL_BYTES:
                raise MpvError("mpv response exceeded size ceiling")
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                # Ignore event lines and responses to other requests -- mpv
                # can interleave both on the same connection.
                if obj.get("request_id") == req_id:
                    if obj.get("error") != "success":
                        raise MpvError(obj.get("error") or "mpv command failed")
                    return obj.get("data")
        raise MpvError("timeout waiting for mpv")
    except (ConnectionRefusedError, FileNotFoundError, OSError) as e:
        raise MpvError(str(e))
    finally:
        s.close()


def get_property(sock_path, name, timeout=2.0):
    return command(sock_path, ["get_property", name], timeout)


def running(sock_path):
    try:
        get_property(sock_path, "pid", timeout=1.0)
        return True
    except MpvError:
        return False
