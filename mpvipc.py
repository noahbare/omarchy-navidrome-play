#!/usr/bin/env python3
"""Minimal client for mpv's JSON IPC socket.

One connection per call: every script here is a fresh process invoked by
QML per action, so there is no long-lived Python side to hold the socket
open. mpv itself is the only thing that stays running between calls.
"""

import json
import socket
import time

SOCK_PATH = None  # set by callers before use, or pass explicitly


class MpvError(Exception):
    pass


def command(sock_path, cmd, timeout=2.0):
    """Send one mpv IPC command and return its `data` field.

    Raises MpvError if the socket is unreachable, mpv rejects the command,
    or no matching response arrives before `timeout`.
    """
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
