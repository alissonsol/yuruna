# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Record what a test suite reads, and tell whether a recorded pass still holds.

`run` executes one suite process under strace and keeps every path the process
tree opened, executed, probed, listed or changed. `commit` turns a passing
run's observations into a record: a fingerprint of each input as it stands
after the run, with the suite's NUnit result. `check` recomputes the
fingerprints of recorded suites and names the ones whose inputs are unchanged,
so tools/Invoke-TestSuite.ps1 can count a recorded pass instead of running the
suite again.

Inside the workspace a file is keyed by its content and mode, a directory a
suite listed by its entry names, and a path the suite probed by what is there
now, absence included. Outside the workspace (the runtime, modules and system
tools) a file whose bytes a suite read is keyed by its size, modification time
and mode, and a path it only probed by its directory's modification time, which
changes whenever an entry is added, removed or replaced. What strace cannot
see -- the environment, the calendar day, the runner itself -- reaches every
record through the caller's context string.
"""

from __future__ import annotations

import argparse
import errno
import glob
import gzip
import hashlib
import json
import os
import posixpath
import re
import select
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

SCHEMA = 1

# Kernel views, device nodes and scratch space hold nothing a suite's verdict
# may depend on, and change on every run.
DEFAULT_IGNORED = ("/proc", "/sys", "/dev", "/run", "/tmp", "/var/tmp")

TRACED_CALLS = "trace=%file,%process,getdents64,fchdir"

OBSERVE, READ, LIST, LINK, WRITE = 1, 2, 4, 8, 16
INSPECTED = OBSERVE | READ | LIST | LINK


# --- REGION: Trace parsing
_FD = r"(AT_FDCWD|-?\d+)(?:<((?:[^>\\]|\\.)*)>)?"
_STR = r'"((?:[^"\\]|\\.)*)"'
_PATH_FIRST = re.compile(_STR)
_FD_PATH = re.compile(_FD + r", (?:" + _STR + r"|NULL)")
_FD_ONLY = re.compile(_FD)
_TWO_PATHS = re.compile(_STR + r", " + _STR)
_FD_PATH_FD_PATH = re.compile(_FD + r", " + _STR + r", " + _FD + r", " + _STR)
_STR_FD_PATH = re.compile(_STR + r", " + _FD + r", " + _STR)
_OPEN_WRITE = re.compile(r"O_(?:WRONLY|RDWR|CREAT|TRUNC|APPEND|TMPFILE)")
_CLONE_FLAGS = re.compile(r"flags=([A-Z0-9_|]+)")
_RESULT = re.compile(r"^(-?\d+|\?)(?:<(.*)>)?(?: (E[A-Z0-9_]+))?")
_ESCAPE = re.compile(rb"\\(x[0-9a-fA-F]{2}|[0-7]{1,3}|.)")
_ESCAPES = {b"n": b"\n", b"t": b"\t", b"r": b"\r", b"v": b"\v", b"f": b"\f"}
_EXITED = re.compile(r"^\+\+\+ (?:exited with (\d+)|killed by (SIG[A-Z0-9]+))")

# How each traced call names its path: a plain path argument, a directory
# descriptor and a path, a descriptor alone, or two paths.
_PLAIN = {
    "open": READ, "creat": WRITE, "execve": READ, "stat": OBSERVE, "lstat": OBSERVE,
    "stat64": OBSERVE, "lstat64": OBSERVE, "access": OBSERVE, "readlink": LINK,
    "getxattr": OBSERVE, "lgetxattr": OBSERVE, "listxattr": OBSERVE, "llistxattr": OBSERVE,
    "mkdir": WRITE, "rmdir": WRITE, "unlink": WRITE, "truncate": WRITE, "chmod": WRITE,
    "chown": WRITE, "lchown": WRITE, "utime": WRITE, "utimes": WRITE, "mknod": WRITE,
    "setxattr": WRITE, "lsetxattr": WRITE, "removexattr": WRITE, "lremovexattr": WRITE,
}
_AT = {
    "openat": READ, "openat2": READ, "execveat": READ, "newfstatat": OBSERVE,
    "fstatat64": OBSERVE, "statx": OBSERVE, "faccessat": OBSERVE, "faccessat2": OBSERVE,
    "readlinkat": LINK, "mkdirat": WRITE, "unlinkat": WRITE, "mknodat": WRITE,
    "fchmodat": WRITE, "fchmodat2": WRITE, "fchownat": WRITE, "utimensat": WRITE,
    "futimesat": WRITE,
}
_OPENS = {"open", "openat", "openat2"}
_FORKS = {"clone", "clone3", "fork", "vfork"}


def unescape(text: str) -> str:
    """Decode a path as strace quotes it: octal or hex escapes for bytes."""
    if "\\" not in text and text.isascii():
        return text
    data = text.encode("latin-1")

    def replace(match):
        token = match.group(1)
        if token[:1] == b"x":
            return bytes([int(token[1:], 16)])
        if token[:1].isdigit():
            return bytes([int(token, 8) & 0xFF])
        return _ESCAPES.get(token, token)

    return os.fsdecode(_ESCAPE.sub(replace, data))


def _prefixes(paths):
    exact = tuple(sorted({path.rstrip("/") or "/" for path in paths}))
    return exact, tuple(path + "/" if path != "/" else path for path in exact)


def _under(path, prefixes):
    exact, nested = prefixes
    return path in exact or path.startswith(nested)


def _exit_status(line):
    match = _EXITED.match(line)
    if not match:
        return None
    if match.group(1) is not None:
        return int(match.group(1))
    try:
        return 128 + signal.Signals[match.group(2)].value
    except KeyError:
        return 128


class TraceReader:
    """Fold `strace -f -y` lines into one set of observed paths.

    -y prints the directory a descriptor names, AT_FDCWD included, so most
    relative paths resolve from the line itself. The calls that take a bare
    relative path (stat, access, chdir...) resolve against the process's
    working directory, tracked per filesystem context: a thread created with
    CLONE_FS shares its creator's, every other child starts with a copy.
    """

    def __init__(self, ignored=(), zones=(), on_list=None):
        self.paths: dict[str, int] = {}
        self.mutated: set[str] = set()
        self.unresolved = 0
        # An ignored directory wins over the workspace, and the workspace over
        # the defaults: a workspace under /tmp is still recorded, its results
        # and temporary folders never are.
        self._ignored = _prefixes(ignored)
        self._zones = _prefixes(zones)
        self._defaults = _prefixes(DEFAULT_IGNORED)
        self._on_list = on_list
        self._cwd: dict[str, list] = {}
        self._pending: dict[str, str] = {}
        self.main_pid = None
        self.main_exit = None

    def feed(self, line: str) -> None:
        line = line.rstrip("\n")
        space = line.find(" ")
        if space <= 0:
            return
        pid, body = line[:space], line[space + 1:].lstrip()
        if self.main_pid is None:
            self.main_pid = pid
        if body.startswith("+++ "):
            if pid == self.main_pid:
                self.main_exit = _exit_status(body)
            return
        if body.endswith("<unfinished ...>"):
            self._pending[pid] = body[: -len("<unfinished ...>")].rstrip()
            return
        if body.startswith("<... "):
            start = self._pending.pop(pid, None)
            close = body.find(" resumed>")
            if start is None or close < 0:
                return
            body = start + body[close + len(" resumed>"):]
        paren = body.find("(")
        equals = body.rfind(" = ")
        if paren <= 0 or equals < paren:
            return
        name = body[:paren]
        head = body[paren + 1:equals].rstrip()
        if head.endswith(")"):
            head = head[:-1]
        result = _RESULT.match(body[equals + 3:])
        if not result:
            return
        code, annotation, error = result.groups()
        ok = code != "?" and not code.startswith("-")
        self._dispatch(pid, name, head, code, annotation, error, ok)

    # Each handler records what a successful or failed call tells about a path.
    def _dispatch(self, pid, name, args, code, annotation, error, ok):
        if name in _AT:
            match = _FD_PATH.match(args)
            if not match:
                return
            fd, fd_path, raw = match.groups()
            if fd != "AT_FDCWD" and fd_path is None and raw is not None and not raw.startswith("/"):
                self.unresolved += 1
                return
            if fd == "AT_FDCWD" and fd_path is not None:
                self._cell(pid)[0] = unescape(fd_path)
            base = unescape(fd_path) if fd_path is not None else self._cell(pid)[0]
            path = self._resolve(base, raw if raw is not None else "")
            self._note(path, self._kind(name, _AT[name], args, ok, error))
        elif name in _PLAIN:
            match = _PATH_FIRST.match(args)
            if match:
                path = self._resolve(self._cell(pid)[0], match.group(1))
                self._note(path, self._kind(name, _PLAIN[name], args, ok, error))
        elif name == "getdents64" or name == "getdents":
            match = _FD_ONLY.match(args)
            if match and match.group(2) is not None:
                self._note(self._resolve(None, match.group(2)), LIST)
        elif name == "chdir":
            match = _PATH_FIRST.match(args)
            if match:
                path = self._resolve(self._cell(pid)[0], match.group(1))
                self._note(path, OBSERVE)
                if ok and path:
                    self._cell(pid)[0] = path
        elif name == "fchdir":
            match = _FD_ONLY.match(args)
            if ok and match and match.group(2) is not None:
                self._cell(pid)[0] = unescape(match.group(2))
        elif name in ("rename", "link", "symlink"):
            match = _TWO_PATHS.match(args)
            if match:
                cwd = self._cell(pid)[0]
                if name != "symlink":
                    self._note(self._resolve(cwd, match.group(1)), WRITE if name == "rename" and ok else OBSERVE)
                self._note(self._resolve(cwd, match.group(2)), WRITE if ok else OBSERVE)
        elif name in ("renameat", "renameat2", "linkat"):
            match = _FD_PATH_FD_PATH.match(args)
            if match:
                old_fd, old_base, old, new_fd, new_base, new = match.groups()
                cwd = self._cell(pid)[0]
                old_path = self._resolve(unescape(old_base) if old_base else cwd, old)
                new_path = self._resolve(unescape(new_base) if new_base else cwd, new)
                self._note(old_path, WRITE if name != "linkat" and ok else OBSERVE)
                self._note(new_path, WRITE if ok else OBSERVE)
        elif name == "symlinkat":
            match = _STR_FD_PATH.match(args)
            if match:
                _, fd, base, link = match.groups()
                self._note(self._resolve(unescape(base) if base else self._cell(pid)[0], link), WRITE if ok else OBSERVE)
        elif name in _FORKS:
            if ok:
                flags = _CLONE_FLAGS.search(args)
                self._fork(pid, code, bool(flags and "CLONE_FS" in flags.group(1).split("|")))

    @staticmethod
    def _kind(name, kind, args, ok, error):
        if name in _OPENS:
            if _OPEN_WRITE.search(args):
                return WRITE if ok else OBSERVE
            return READ if ok else OBSERVE
        if kind == READ:
            return READ if ok else OBSERVE
        if kind == WRITE and not ok:
            return OBSERVE
        return kind

    def _cell(self, pid):
        cell = self._cwd.get(pid)
        if cell is None:
            cell = self._cwd[pid] = [None]
        return cell

    def _fork(self, parent, child, shares_fs):
        known = self._cwd.get(child)
        if known is not None and known[0] is not None:
            return
        source = self._cell(parent)
        self._cwd[child] = source if shares_fs else [source[0]]

    def _resolve(self, base, raw):
        path = unescape(raw)
        if not path.startswith("/"):
            if base is None:
                self.unresolved += 1
                return None
            path = base + "/" + path if path else base
        return posixpath.normpath(path) if path != "/" else path

    def _note(self, path, kind):
        if not path or _under(path, self._ignored) or (_under(path, self._defaults) and not _under(path, self._zones)):
            return
        # Python's byte-code caches are derived from sources that are inputs in
        # their own right, and are rewritten whenever a source is newer.
        if "/__pycache__/" in path or path.endswith("/__pycache__"):
            return
        seen = self.paths.get(path, 0)
        if kind == WRITE and seen & INSPECTED and not seen & WRITE:
            self.mutated.add(path)
        if kind == LIST and not seen & LIST and self._on_list and _under(path, self._zones):
            self._on_list(path)
        self.paths[path] = seen | kind


# --- REGION: Fingerprints
def _sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def _is_git_index(path):
    return path.endswith("/.git/index") or bool(re.search(r"/\.git/worktrees/[^/]+/index$", path))


def git_index_digest(path):
    """Fingerprint a Git index by its entries, not its stat cache.

    `git status` rewrites the index whenever it refreshes cached stat data,
    which changes the file without changing what is staged.
    """
    if not os.path.isfile(path):
        return "absent"
    git_dir = os.path.dirname(path)
    environment = dict(os.environ, GIT_INDEX_FILE=path)
    for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR"):
        environment.pop(name, None)
    try:
        listing = subprocess.run(["git", "--git-dir", git_dir, "--work-tree", os.path.dirname(git_dir), "ls-files", "--stage", "-z"],
                                 env=environment, capture_output=True, check=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return "unreadable"
    return "index:" + hashlib.sha256(listing).hexdigest()


class Fingerprints:
    """Compute input fingerprints once per path, whichever record asks."""

    def __init__(self):
        self._memo: dict[tuple, tuple] = {}

    def value(self, cls, path):
        key = (cls, path)
        if key not in self._memo:
            self._memo[key] = self._compute(cls, path)
        return self._memo[key]

    @staticmethod
    def _stat(path, follow=True):
        try:
            return os.stat(path) if follow else os.lstat(path)
        except FileNotFoundError:
            return None
        except NotADirectoryError:
            return None

    def _compute(self, cls, path):
        """Return (value, stat) where stat dates the state for race checks."""
        try:
            if cls == "g":
                return git_index_digest(path), None
            if cls == "r":
                try:
                    return "link:" + os.readlink(path), self._stat(path, follow=False)
                except FileNotFoundError:
                    return "absent", None
                except OSError as failure:
                    if failure.errno == errno.EINVAL:
                        return "notlink", None
                    if failure.errno == errno.ENOTDIR:
                        return "absent", None
                    raise
            st = self._stat(path)
            if st is None:
                return "absent", None
            if cls == "o":
                if stat.S_ISDIR(st.st_mode):
                    return "dir", None
                if stat.S_ISREG(st.st_mode):
                    try:
                        return "file:%s:%o" % (_sha256_file(path), st.st_mode & 0o7777), st
                    except PermissionError:
                        return "unreadable:%d:%d:%o" % (st.st_size, st.st_mtime_ns, st.st_mode & 0o7777), st
                return "other:%o" % stat.S_IFMT(st.st_mode), None
            if cls == "l":
                if not stat.S_ISDIR(st.st_mode):
                    return "notdir", None
                names = sorted(os.fsencode(name) for name in os.listdir(path))
                return "list:" + hashlib.sha256(b"\0".join(names)).hexdigest(), st
            if cls == "O":
                if stat.S_ISDIR(st.st_mode):
                    return "dir", None
                return "file:%d:%d:%o" % (st.st_size, st.st_mtime_ns, st.st_mode & 0o7777), st
        except OSError as failure:
            return "error:%s" % errno.errorcode.get(failure.errno, failure.errno), None
        raise ValueError("unknown fingerprint class " + cls)


def _inside(path, zones):
    return any(path == zone or path.startswith(zone + "/") for zone in zones)


def classify(paths: dict, zones) -> dict:
    """Map observed paths to the fingerprint classes that cover them.

    o: content inside the workspace     l: a directory's entry names
    r: link target                       g: Git index entries
    O: what is at a path outside the workspace, by size and time for a file,
       and an immutable Git object inside it
    """
    inputs = {}
    listed_outside = {path for path, flags in paths.items()
                      if flags & LIST and not flags & WRITE and not _inside(path, zones)}
    for path, flags in paths.items():
        if flags & WRITE:
            continue
        if _inside(path, zones):
            if _is_git_index(path):
                inputs[("g", path)] = None
            elif "/.git/objects/" in path:
                inputs[("O", path)] = None
            else:
                if flags & (OBSERVE | READ):
                    inputs[("o", path)] = None
                if flags & LIST:
                    inputs[("l", path)] = None
                if flags & LINK:
                    inputs[("r", path)] = None
            continue
        if flags & LIST:
            inputs[("l", path)] = None
        if flags & LINK:
            inputs[("r", path)] = None
        # Command lookup lists every PATH directory and then probes each entry.
        # The listing already changes when an entry is added or removed, and a
        # probe that finds an entry tells only that it is there.
        if flags & READ or (flags & OBSERVE and posixpath.dirname(path) not in listed_outside):
            inputs[("O", path)] = None
    return inputs


def fingerprint(paths: dict, mutated, zones, started_ns, index_baseline, fingerprints=None, listing_baseline=None):
    """Fingerprint a run's inputs; return (inputs, reasons it cannot be reused).

    index_baseline holds the Git index digests taken when the run started, and
    listing_baseline each workspace directory's entries as they stood when the
    suite listed it. A directory whose entries are the same then and at the end
    of the run only had a transient entry in between -- another suite's probe or
    a temporary file -- and the listing the suite saw still holds.
    """
    listing_baseline = listing_baseline or {}
    fingerprints = fingerprints or Fingerprints()
    reasons = []
    for path in sorted(mutated):
        if not _is_git_index(path):
            reasons.append("changed a path it had read: " + path)
    for path, flags in paths.items():
        if flags & WRITE and _is_git_index(path):
            paths[path] = flags & ~WRITE
    pending = list(classify(paths, zones))
    inputs = []
    seen = set()
    while pending:
        key = pending.pop()
        if key in seen:
            continue
        seen.add(key)
        cls, path = key
        value, st = fingerprints.value(cls, path)
        # Outside the workspace, directories such as the home directory change
        # all the time as other programs replace their files; the entry names a
        # suite listed there are compared, not when the directory last changed.
        if cls == "l" and not _inside(path, zones):
            st = None
        if cls == "l" and listing_baseline.get(path) == value:
            st = None
        if st is not None and max(st.st_mtime_ns, st.st_ctime_ns) >= started_ns:
            reasons.append("an input changed during the run: " + path)
        if cls == "g" and path in index_baseline and index_baseline[path] != value:
            reasons.append("the Git index changed during the run: " + path)
        inputs.append([cls, path, value])
    inputs.sort(key=lambda item: (item[1], item[0]))
    return inputs, reasons


def index_snapshot(zones):
    """Git index digests at the start of a run, for every repository in the zones."""
    found = {}
    for zone in zones:
        for pattern in ("/.git/index", "/*/.git/index"):
            for path in glob.glob(glob.escape(zone) + pattern):
                found[path] = git_index_digest(path)
    return found


# --- REGION: Tracing
# How long processes a suite left behind may keep strace attached after the
# suite's own process exits. The runner waits as long for the output streams of
# an untraced suite, and a lingering process cannot change a verdict already
# written to the NUnit file.
LINGER_SECONDS = 5


def _read_trace(fifo, process, reader):
    """Feed strace's output to the reader until strace exits.

    The FIFO is opened read-write so the open never blocks and no early EOF is
    seen before strace connects. Whatever strace wrote before exiting is still
    in the pipe, so the stream ends when the strace process does. Returns
    whether strace had to be detached from processes that outlived the suite.
    """
    fd = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
    tail = b""
    main_exited = None
    detached = False

    def consume(chunk):
        nonlocal tail
        lines = (tail + chunk).split(b"\n")
        tail = lines.pop()
        for line in lines:
            reader.feed(line.decode("latin-1"))

    try:
        while True:
            ready, _, _ = select.select([fd], [], [], 0.2)
            if ready:
                consume(os.read(fd, 1 << 20))
            elif process.poll() is not None:
                break
            if reader.main_exit is not None and main_exited is None:
                main_exited = time.monotonic()
            if (main_exited is not None and not detached and process.poll() is None and
                    time.monotonic() - main_exited > LINGER_SECONDS):
                # SIGTERM makes strace detach and leave the remaining processes
                # running untraced, as they would have run without it.
                process.terminate()
                detached = True
        while True:
            try:
                chunk = os.read(fd, 1 << 20)
            except BlockingIOError:
                break
            if not chunk:
                break
            consume(chunk)
        if tail:
            reader.feed(tail.decode("latin-1"))
    finally:
        os.close(fd)
    return detached


def command_run(args):
    zones = [os.path.realpath(zone) for zone in args.zone]
    ignored = [os.path.realpath(path) for path in args.ignore]
    index_baseline = index_snapshot(zones)
    started_ns = time.time_ns()
    # Each workspace directory is listed again the moment the trace shows the
    # suite listing it, while that listing is still what the suite saw.
    listing_baseline = {}
    snapshot = Fingerprints()
    reader = TraceReader(ignored, zones, on_list=lambda path: listing_baseline.setdefault(path, snapshot.value("l", path)[0]))
    scratch = tempfile.mkdtemp(prefix="yrn-trace-")
    try:
        fifo = os.path.join(scratch, "trace")
        os.mkfifo(fifo, 0o600)
        # -q keeps the exit lines that say how the suite's own process ended;
        # --seccomp-bpf stops the tracee only for the traced calls. strace
        # started with -o and a command blocks fatal signals by default, so
        # --interruptible=anywhere is what lets SIGTERM detach it from a
        # daemon the suite left behind.
        tracer = [args.strace, "-f", "-q", "-y", "--seccomp-bpf", "--interruptible=anywhere", "-e", "signal=none",
                  "-e", TRACED_CALLS, "-o", fifo, "--"]
        process = subprocess.Popen(tracer + args.command)
        detached = False
        try:
            detached = _read_trace(fifo, process, reader)
        finally:
            code = process.wait()
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    if detached and reader.main_exit is not None:
        code = reader.main_exit
    elif code < 0:
        code = 128 - code
    reasons = []
    if reader.unresolved:
        reasons.append("%d relative path(s) had no known working directory" % reader.unresolved)
    inputs, unreusable = fingerprint(reader.paths, reader.mutated, zones, started_ns, index_baseline,
                                     listing_baseline=listing_baseline)
    candidate = {"schema": SCHEMA, "startedNs": started_ns, "exitCode": code,
                 "unreusable": reasons + unreusable, "inputs": inputs}
    _write_atomic(args.out, json.dumps(candidate, separators=(",", ":")).encode("utf-8"))
    return code


# --- REGION: Records
def record_path(cache, suite):
    return os.path.join(cache, "records", hashlib.sha256(suite.encode("utf-8")).hexdigest()[:32] + ".json.gz")


def _write_atomic(path, data):
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=directory, prefix=".tmp-")
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(data)
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise


def command_commit(args):
    with open(args.candidate, "rb") as stream:
        candidate = json.loads(stream.read())
    if candidate.get("schema") != SCHEMA:
        return _answer({"recorded": False, "reason": "the observation file has another schema"})
    if candidate.get("unreusable"):
        return _answer({"recorded": False, "reason": candidate["unreusable"][0],
                        "reasons": len(candidate["unreusable"])})
    with open(args.xml, "rb") as stream:
        nunit = stream.read().decode("utf-8")
    record = {
        "schema": SCHEMA, "suite": args.suite, "context": args.context,
        "recordedUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "total": args.total, "skipped": args.skipped, "seconds": args.seconds,
        "inputs": candidate["inputs"], "nunit": nunit,
    }
    data = gzip.compress(json.dumps(record, separators=(",", ":")).encode("utf-8"), compresslevel=6, mtime=0)
    _write_atomic(record_path(args.cache, args.suite), data)
    return _answer({"recorded": True, "inputs": len(candidate["inputs"])})


def check(cache, suites, context, fingerprints=None):
    """Return {suite: answer}: a reusable record's facts, or why there is none."""
    fingerprints = fingerprints or Fingerprints()
    answers = {}
    for suite in suites:
        path = record_path(cache, suite)
        try:
            with gzip.open(path, "rb") as stream:
                record = json.loads(stream.read())
        except FileNotFoundError:
            answers[suite] = {"hit": False, "reason": "no recorded pass"}
            continue
        except (OSError, ValueError, EOFError):
            answers[suite] = {"hit": False, "reason": "the record is unreadable"}
            continue
        if record.get("schema") != SCHEMA or record.get("suite") != suite:
            answers[suite] = {"hit": False, "reason": "the record belongs to another schema or suite"}
            continue
        if record.get("context") != context:
            answers[suite] = {"hit": False, "reason": "recorded under another context (day, environment, toolchain or runner)"}
            continue
        changed = None
        for cls, input_path, value in record.get("inputs", []):
            if fingerprints.value(cls, input_path)[0] != value:
                changed = input_path
                break
        if changed is not None:
            answers[suite] = {"hit": False, "reason": "input changed: " + changed}
            continue
        answers[suite] = {"hit": True, "total": record["total"], "skipped": record["skipped"],
                          "seconds": record["seconds"], "recordedUtc": record["recordedUtc"],
                          "inputs": len(record.get("inputs", [])), "nunit": record["nunit"]}
    return answers


def command_check(args):
    request = json.loads(sys.stdin.read())
    return _answer(check(args.cache, request["suites"], args.context))


def _answer(value):
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    return 0


# --- REGION: Command line
def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="action", required=True)

    run = commands.add_parser("run", help="run a command under strace and write its observations")
    run.add_argument("--strace", required=True)
    run.add_argument("--out", required=True)
    run.add_argument("--zone", action="append", default=[], help="a workspace root keyed by content")
    run.add_argument("--ignore", action="append", default=[], help="a directory whose paths are never inputs")
    run.add_argument("command", nargs=argparse.REMAINDER)

    commit = commands.add_parser("commit", help="store a passing run's observations as a record")
    for name in ("candidate", "cache", "suite", "context", "xml"):
        commit.add_argument("--" + name, required=True)
    commit.add_argument("--total", type=int, required=True)
    commit.add_argument("--skipped", type=int, required=True)
    commit.add_argument("--seconds", type=float, required=True)

    verify = commands.add_parser("check", help="read {\"suites\": [...]} and answer which records still hold")
    verify.add_argument("--cache", required=True)
    verify.add_argument("--context", required=True)

    args = parser.parse_args(argv)
    if args.action == "run":
        if args.command[:1] == ["--"]:
            args.command = args.command[1:]
        if not args.command:
            parser.error("run needs a command after --")
        return command_run(args)
    if args.action == "commit":
        return command_commit(args)
    return command_check(args)


if __name__ == "__main__":
    sys.exit(main())
