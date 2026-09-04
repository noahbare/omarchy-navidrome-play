#!/usr/bin/env python3
"""Shared Subsonic plumbing: config, endpoint selection, authenticated calls."""

import hashlib
import json
import os
import random
import stat
import sys
import time
import urllib.parse
import urllib.request

CONFIG = os.environ.get("OMARCHY_NAVIDROME_CONFIG") or os.path.expanduser(
    "~/.config/omarchy-navidrome/config.json"
)
STATE_DIR = os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
    "nbare-navidrome-play",
)
ENDPOINT_FILE = os.path.join(STATE_DIR, "endpoint.json")

# Long enough that moving around the house does not thrash the endpoint choice,
# short enough that coming home restores the fast path without intervention.
PUBLIC_STICKY_SEC = 600
LAN_TIMEOUT = 2.5
PUBLIC_TIMEOUT = 10

# Byte ceilings: nothing here needs to be large, and an unbounded read is a
# free memory/disk exhaustion vector against a hostile or compromised server,
# or against a local file planted at one of our predictable state paths.
MAX_CONFIG_BYTES = 64 * 1024
MAX_STATE_BYTES = 4 * 1024 * 1024
MAX_RESPONSE_BYTES = 8 * 1024 * 1024

MAX_STR = 300  # generous for a title/artist/album name; not a novel
MAX_LIST = 500  # a wall of 500 search results is already a UI bug, not a feature

# Every script's stdout is read whole by a QML StdioCollector with no byte
# ceiling of its own. Individual result fields are already clipped via
# clip_str/clip_list, but a server-supplied error message (Subsonic's
# <error message="...">) reaches str(exception) uncapped -- cap the whole
# emitted line here so that path, and any future one, can't turn a hostile
# or compromised server's response into an unbounded write on our stdout.
MAX_OUTPUT_BYTES = 256 * 1024


class AuthError(Exception):
    """Bad credentials. Deliberately never triggers endpoint failover: retrying a
    wrong password against a public edge is how you get banned by your own
    rate limiter."""


def clip_str(v, limit=MAX_STR):
    """Bound a server-supplied string field before it reaches QML."""
    if not isinstance(v, str):
        return ""
    return v[:limit]


def clip_list(v, limit=MAX_LIST):
    """Bound a server-supplied array field before we iterate/persist it."""
    if not isinstance(v, list):
        return []
    return v[:limit]


def emit(ok, **kw):
    """Every script's sole stdout write: one compact, size-bounded JSON
    line. Clips every top-level string value (this is where an unclipped
    `error=str(e)` built from a hostile/compromised server's message would
    otherwise slip through) and, as a hard backstop against anything this
    doesn't anticipate, drops the whole payload in favour of a small fixed
    error if the serialized line still comes out oversized.
    """
    safe = {"ok": bool(ok)}
    for k, v in kw.items():
        safe[k] = clip_str(v, 500) if isinstance(v, str) else v
    line = json.dumps(safe)
    if len(line) > MAX_OUTPUT_BYTES:
        line = json.dumps({"ok": False, "error": "output too large"})
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def open_private_dir(path):
    """Create/verify a directory that only we can read or write, and return
    a verified fd for it.

    Refuses to follow a symlink planted at `path`, refuses a directory we
    don't own, and tightens permissions if they're looser than 0700. All
    subsequent operations on this directory's contents must go through the
    returned fd (dir_fd=) rather than the pathname again -- once the fd is
    open, a later replacement of the directory itself can no longer
    redirect them.
    """
    try:
        fd = os.open(path, os.O_DIRECTORY | os.O_NOFOLLOW)
    except FileNotFoundError:
        os.makedirs(path, mode=0o700, exist_ok=True)  # mkdir never follows
        os.chmod(path, 0o700)  # makedirs' mode is masked by umask
        fd = os.open(path, os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        st = os.fstat(fd)
        if not stat.S_ISDIR(st.st_mode):
            raise ValueError("expected a directory: %s" % path)
        if st.st_uid != os.getuid():
            raise ValueError("directory not owned by current user: %s" % path)
        if st.st_mode & (stat.S_IRWXG | stat.S_IRWXO):
            os.fchmod(fd, 0o700)
        return fd
    except Exception:
        os.close(fd)
        raise


def ensure_private_dir(path):
    """Convenience wrapper for callers that only need the directory to exist
    with the right ownership/permissions, not a held fd."""
    os.close(open_private_dir(path))


def mkstemp_at(dirfd, prefix=".tmp-", suffix=""):
    """Create a randomly-named, exclusive, 0600 file relative to an
    already-validated directory fd -- the dir_fd equivalent of
    tempfile.mkstemp, which has no dir_fd support of its own."""
    for _ in range(10):
        name = "%s%08x%08x%s" % (prefix, random.getrandbits(32), random.getrandbits(32), suffix)
        try:
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=dirfd)
            return fd, name
        except FileExistsError:
            continue
    raise OSError("could not create a unique temp file")


def _secure_read(path, max_bytes, require_secure=False):
    """Read a regular file without following symlinks, and without ever
    blocking on or exhausting memory against a FIFO/device/oversized file
    planted at one of our predictable state paths.

    Every property checked -- type, owner, mode, size -- is checked on the
    exact fd that gets read, all in one open, so nothing can be swapped in
    between a separate check and a separate read.
    """
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise ValueError("not a regular file: %s" % path)
        if require_secure:
            if st.st_uid != os.getuid():
                raise ValueError("config not owned by current user: %s" % path)
            if st.st_mode & (stat.S_IRWXG | stat.S_IRWXO):
                raise ValueError("config is group/world accessible: %s" % path)
        with os.fdopen(fd, "rb", closefd=True) as f:
            fd = None  # ownership transferred to the file object
            data = f.read(max_bytes + 1)
        if len(data) > max_bytes:
            raise ValueError("file too large: %s" % path)
        return data
    finally:
        if fd is not None:
            os.close(fd)


def load_json(path, default, max_bytes=MAX_STATE_BYTES, require_secure=False):
    try:
        return json.loads(_secure_read(path, max_bytes, require_secure=require_secure))
    except Exception:
        return default


def save_json(path, data):
    """Atomic, symlink-safe write: random 0600 temp file in a private 0700
    directory, fsync'd, then renamed over the target -- creation and rename
    both performed relative to a held directory fd so a directory swapped in
    after validation can't redirect either one."""
    d = os.path.dirname(path)
    name = os.path.basename(path)
    dirfd = None
    fd = None
    tmp = None
    try:
        dirfd = open_private_dir(d)
        payload = json.dumps(data).encode()
        fd, tmp = mkstemp_at(dirfd)
        with os.fdopen(fd, "wb", closefd=True) as f:
            fd = None
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, name, src_dir_fd=dirfd, dst_dir_fd=dirfd)
        tmp = None
    except Exception:
        pass  # state is a convenience; losing it must never break a call
    finally:
        if fd is not None:
            os.close(fd)
        if tmp is not None:
            try:
                os.unlink(tmp, dir_fd=dirfd)
            except OSError:
                pass
        if dirfd is not None:
            os.close(dirfd)


def load_config():
    cfg = load_json(CONFIG, None, max_bytes=MAX_CONFIG_BYTES, require_secure=True)
    if cfg is None:
        raise FileNotFoundError("not configured")
    if not cfg.get("user") or not cfg.get("password") or not (cfg.get("url") or cfg.get("public_url")):
        raise ValueError("bad config")
    return cfg


def build_url(base, user, password, endpoint, extra=""):
    """Subsonic token auth: fresh salt per request, md5(password + salt).

    The password never crosses the wire, and a captured token is bound to its
    salt rather than being a reusable credential.
    """
    salt = "%08x%08x" % (random.getrandbits(32), random.getrandbits(32))
    token = hashlib.md5((password + salt).encode()).hexdigest()
    q = urllib.parse.urlencode(
        {"u": user, "t": token, "s": salt, "v": "1.16.1", "c": "nbare-navidrome-play", "f": "json"}
    )
    return "%s/rest/%s?%s%s" % (base.rstrip("/"), endpoint, q, ("&" + extra) if extra else "")


def raw(url, timeout, max_bytes=MAX_RESPONSE_BYTES):
    """Read an HTTP response with both a byte ceiling and an overall wall
    clock deadline, so a hostile or compromised server can't exhaust memory
    or disk, or stall a caller by trickling bytes forever."""
    deadline = time.time() + max(timeout * 3, timeout + 5)
    with urllib.request.urlopen(url, timeout=timeout) as r:
        chunks = []
        total = 0
        while True:
            chunk = r.read(65536)
            if not chunk:
                break
            total += len(chunk)
            if total > max_bytes:
                raise ValueError("response too large")
            chunks.append(chunk)
            if time.time() > deadline:
                raise ValueError("response deadline exceeded")
        return b"".join(chunks)


def call(base, cfg, endpoint, extra="", timeout=10, max_bytes=MAX_RESPONSE_BYTES):
    body = json.loads(raw(build_url(base, cfg["user"], cfg["password"], endpoint, extra), timeout, max_bytes))
    body = body["subsonic-response"]
    if body.get("status") != "ok":
        err = body.get("error") or {}
        if err.get("code") in (40, 41, 42, 43, 44):
            raise AuthError(err.get("message", "auth failed"))
        raise RuntimeError(err.get("message", "rejected"))
    return body


def pick_endpoint(cfg, probe="ping"):
    """Choose LAN or public, honouring a sticky window.

    Returns (which, base, timeout, body-of-probe-call).

    The stickiness matters because these scripts run as fresh processes per
    call: with no memory, every call away from home would pay the LAN timeout
    first.
    """
    lan, public = cfg.get("url"), cfg.get("public_url")
    state = load_json(ENDPOINT_FILE, {})
    on_public = state.get("which") == "public"
    fresh = (time.time() - float(state.get("since") or 0)) < PUBLIC_STICKY_SEC

    if on_public and fresh and public:
        order = [("public", public, PUBLIC_TIMEOUT)]
    else:
        order = ([("lan", lan, LAN_TIMEOUT)] if lan else []) + \
                ([("public", public, PUBLIC_TIMEOUT)] if public else [])

    last = None
    for which, base, timeout in order:
        try:
            body = call(base, cfg, probe, timeout=timeout)
            if which != state.get("which") or which == "public":
                save_json(ENDPOINT_FILE, {"which": which, "since": time.time()})
            return which, base, timeout, body
        except AuthError:
            raise
        except Exception as e:
            last = e

    # A sticky public choice can go stale (came home, wifi changed). One retry of
    # the full order beats staying wedged on an endpoint that is gone.
    if on_public and fresh and lan:
        save_json(ENDPOINT_FILE, {})
        return pick_endpoint(cfg, probe)

    raise last or RuntimeError("no endpoint configured")
