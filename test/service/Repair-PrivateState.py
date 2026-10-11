#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.

"""Restore the current account's private state without replacing its lock files."""

import argparse
import json
import os
import stat
import sys
from contextlib import contextmanager
from dataclasses import dataclass


class Refusal(Exception):
    def __init__(self, reason, exit_code=1):
        super().__init__(reason)
        self.reason = reason
        self.exit_code = exit_code


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise Refusal("invalid-arguments")


@dataclass(frozen=True)
class Entry:
    identity: tuple
    directory: bool
    mode: int
    uid: int
    gid: int


def inspect_entry(info, uid, device, home=False):
    mode = info.st_mode
    if stat.S_ISLNK(mode):
        raise Refusal("unsafe-symlink")
    directory = stat.S_ISDIR(mode)
    if not directory and not stat.S_ISREG(mode):
        raise Refusal("unsafe-file-type")
    if not directory and info.st_nlink != 1:
        raise Refusal("unsafe-hardlink")
    if info.st_dev != device:
        raise Refusal("filesystem-boundary")
    if home:
        if not directory or info.st_uid != uid:
            raise Refusal("home-owner-mismatch")
        if stat.S_IMODE(mode) & 0o022:
            raise Refusal("home-writable-by-others")
    elif info.st_uid not in (0, uid):
        raise Refusal("foreign-owner")
    return Entry((info.st_dev, info.st_ino), directory, stat.S_IMODE(mode),
                 info.st_uid, info.st_gid)


def desired_mode(entry, parent=False):
    if parent:
        # Other tools share .yuruna; their harmless read permissions stay intact.
        return (entry.mode | 0o700) & ~0o022
    if entry.directory:
        return 0o700
    return 0o600 | (entry.mode & 0o100)


@contextmanager
def open_home(path):
    if not os.path.isabs(path) or os.path.normpath(path) != path or path == "/":
        raise Refusal("invalid-home")
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    descriptor = os.open("/", flags)
    try:
        # Opening every component separately also rejects links in ancestors.
        for name in path.split("/")[1:]:
            info = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if stat.S_ISLNK(info.st_mode):
                raise Refusal("unsafe-symlink")
            if not stat.S_ISDIR(info.st_mode):
                raise Refusal("invalid-home")
            child = os.open(name, flags, dir_fd=descriptor)
            actual = os.fstat(child)
            if (actual.st_dev, actual.st_ino) != (info.st_dev, info.st_ino):
                os.close(child)
                raise Refusal("path-changed")
            os.close(descriptor)
            descriptor = child
        yield descriptor
    finally:
        os.close(descriptor)


@contextmanager
def open_entry(parent_fd, name, expected, uid, device):
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
    if expected.directory:
        flags |= os.O_DIRECTORY
    descriptor = os.open(name, flags, dir_fd=parent_fd)
    try:
        actual = inspect_entry(os.fstat(descriptor), uid, device)
        if actual.identity != expected.identity or actual.directory != expected.directory:
            raise Refusal("path-changed")
        yield descriptor, actual
    finally:
        os.close(descriptor)


def inspect_at(parent_fd, name, uid, device):
    try:
        info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    return inspect_entry(info, uid, device)


def require_directory(entry):
    if entry and not entry.directory:
        raise Refusal("unsafe-file-type")


def scan(parent_fd, name, uid, device, entries, prefix=()):
    entry = inspect_at(parent_fd, name, uid, device)
    key = prefix + (name,)
    if entry is None:
        if len(key) > 2:
            raise Refusal("path-changed")
        entries[key] = None
        return
    if len(key) <= 2:
        require_directory(entry)
    entries[key] = entry
    if os.geteuid() != 0 and entry.uid != uid:
        raise Refusal("privilege-required", 2)
    with open_entry(parent_fd, name, entry, uid, device) as (descriptor, _):
        if len(key) == 1:
            scan(descriptor, "host-refresh", uid, device, entries, key)
        elif entry.directory:
            for child in sorted(os.listdir(descriptor)):
                scan(descriptor, child, uid, device, entries, key)


def secure_entry(descriptor, entry, uid, gid, parent=False):
    changed = False
    if entry.uid != uid or entry.gid != gid:
        os.fchown(descriptor, uid, gid)
        changed = True
    mode = desired_mode(entry, parent)
    if stat.S_IMODE(os.fstat(descriptor).st_mode) != mode:
        os.fchmod(descriptor, mode)
        changed = True
    actual = os.fstat(descriptor)
    if actual.st_uid != uid or actual.st_gid != gid or stat.S_IMODE(actual.st_mode) != mode:
        raise Refusal("repair-unverified")
    return changed


def apply(parent_fd, name, uid, gid, device, entries, prefix=()):
    key = prefix + (name,)
    expected = entries[key]
    actual = inspect_at(parent_fd, name, uid, device)
    changed = False
    if expected is None:
        if actual is not None:
            raise Refusal("path-changed")
        os.mkdir(name, 0o700, dir_fd=parent_fd)
        expected = inspect_at(parent_fd, name, uid, device)
        changed = True
    elif actual is None or actual.identity != expected.identity:
        raise Refusal("path-changed")
    with open_entry(parent_fd, name, expected, uid, device) as (descriptor, opened):
        changed = secure_entry(descriptor, opened, uid, gid, parent=len(key) == 1) or changed
        if len(key) == 1:
            child_key = key + ("host-refresh",)
            if child_key not in entries:
                entries[child_key] = None
            changed = apply(descriptor, "host-refresh", uid, gid, device, entries, key) or changed
        elif opened.directory:
            children = {path[-1] for path in entries if path[:-1] == key}
            if set(os.listdir(descriptor)) != children:
                raise Refusal("path-changed")
            for child in sorted(children):
                changed = apply(descriptor, child, uid, gid, device, entries, key) or changed
    return changed


def repair(home, uid, gid, check=False):
    if os.name != "posix" or not hasattr(os, "O_NOFOLLOW"):
        raise Refusal("platform-unsupported")
    if uid < 0 or gid < 0 or os.geteuid() not in (0, uid):
        raise Refusal("identity-mismatch")
    with open_home(home) as descriptor:
        home_stat = os.fstat(descriptor)
        home_entry = inspect_entry(home_stat, uid, home_stat.st_dev, home=True)
        entries = {}
        scan(descriptor, ".yuruna", uid, home_stat.st_dev, entries)
        needed = any(entry is None or entry.uid != uid or entry.gid != gid or
                     entry.mode != desired_mode(entry, parent=len(path) == 1)
                     for path, entry in entries.items())
        if check:
            return {"repaired": False, "reason": "repair-needed" if needed else "ok"}
        # Recheck the named home before writes; all later access stays anchored
        # to directory descriptors rather than following paths from the root.
        with open_home(home) as current_fd:
            current = inspect_entry(os.fstat(current_fd), uid, home_stat.st_dev, home=True)
            if current.identity != home_entry.identity:
                raise Refusal("path-changed")
        changed = apply(descriptor, ".yuruna", uid, gid, home_stat.st_dev, entries)
        return {"repaired": changed, "reason": "ok"}


def main(argv=None):
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("--home", required=True)
    parser.add_argument("--uid", required=True, type=int)
    parser.add_argument("--gid", required=True, type=int)
    parser.add_argument("--check", action="store_true")
    try:
        args = parser.parse_args(argv)
        result = repair(args.home, args.uid, args.gid, args.check)
        code = 0
    except Refusal as error:
        result = {"repaired": False, "reason": error.reason}
        code = error.exit_code
    except PermissionError:
        result = {"repaired": False, "reason": "privilege-required" if os.geteuid() != 0 else "access-denied"}
        code = 2 if os.geteuid() != 0 else 1
    except OSError:
        result = {"repaired": False, "reason": "io-error"}
        code = 1
    print(json.dumps(result, separators=(",", ":")))
    return code


if __name__ == "__main__":
    sys.exit(main())
