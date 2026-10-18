#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.

"""Private-state repair tests confined to disposable directories."""

import contextlib
import importlib.util
import io
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    "private_state_repair", Path(__file__).with_name("Repair-PrivateState.py"))
REPAIR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = REPAIR
SPEC.loader.exec_module(REPAIR)


@unittest.skipUnless(os.name == "posix", "Unix file ownership and directory descriptors")
class PrivateStateRepairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="yuruna-private-repair-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name).resolve()
        self.uid = os.geteuid()
        self.gid = os.getegid()
        self.parent = self.home / ".yuruna"
        self.root = self.parent / "host-refresh"

    def make_tree(self):
        self.root.mkdir(parents=True)
        self.parent.chmod(0o700)
        self.root.chmod(0o700)
        return self.root

    def invoke(self, check=False):
        return REPAIR.repair(str(self.home), self.uid, self.gid, check)

    def invoke_main(self, *extra):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = REPAIR.main(["--home", str(self.home), "--uid", str(self.uid),
                                "--gid", str(self.gid), *extra])
        return code, json.loads(output.getvalue())

    def assert_refused(self, reason, operation=None):
        with self.assertRaises(REPAIR.Refusal) as caught:
            (operation or self.invoke)()
        self.assertEqual(reason, caught.exception.reason)

    def test_creates_only_private_directories_owner_only(self):
        result = self.invoke()
        self.assertEqual({"repaired": True, "reason": "ok"}, result)
        self.assertEqual(0o700, stat.S_IMODE(self.parent.stat().st_mode))
        self.assertEqual(0o700, stat.S_IMODE(self.root.stat().st_mode))
        self.assertEqual([self.root], list(self.parent.iterdir()))

    def test_check_creates_nothing(self):
        self.assertEqual({"repaired": False, "reason": "repair-needed"}, self.invoke(check=True))
        self.assertFalse(self.parent.exists())

    def test_check_reports_loose_permissions_without_changing_them(self):
        self.make_tree().chmod(0o755)
        self.assertEqual("repair-needed", self.invoke(check=True)["reason"])
        self.assertEqual(0o755, stat.S_IMODE(self.root.stat().st_mode))

    def test_healthy_tree_needs_no_mutation(self):
        self.make_tree()
        with mock.patch.object(REPAIR.os, "fchown") as chown, \
                mock.patch.object(REPAIR.os, "fchmod") as chmod:
            self.assertEqual({"repaired": False, "reason": "ok"}, self.invoke())
        chown.assert_not_called()
        chmod.assert_not_called()

    def test_repairs_nested_permissions_and_preserves_inodes_and_contents(self):
        self.make_tree()
        self.parent.chmod(0o775)
        self.root.chmod(0o777)
        nested = self.root / "work"
        nested.mkdir(mode=0o755)
        lock = nested / "status-service.start.lock"
        lock.write_bytes(b'{"pid":42}\n\x00lock metadata')
        lock.chmod(0o664)
        script = nested / "resume.sh"
        script.write_bytes(b"#!/bin/sh\nexit 0\n")
        script.chmod(0o755)
        before = {path: (path.stat().st_ino, path.read_bytes()) for path in (lock, script)}
        self.assertTrue(self.invoke()["repaired"])
        self.assertEqual(0o755, stat.S_IMODE(self.parent.stat().st_mode))
        for path in (self.root, nested):
            self.assertEqual(0o700, stat.S_IMODE(path.stat().st_mode))
        self.assertEqual(0o600, stat.S_IMODE(lock.stat().st_mode))
        self.assertEqual(0o700, stat.S_IMODE(script.stat().st_mode))
        for path, (inode, contents) in before.items():
            self.assertEqual(inode, path.stat().st_ino)
            self.assertEqual(contents, path.read_bytes())
        self.assertFalse(self.invoke()["repaired"])

    def test_does_not_traverse_or_remode_sibling_application_state(self):
        self.make_tree()
        sibling = self.parent / "host-proxy-backup.json"
        sibling.write_bytes(b"other subsystem state")
        sibling.chmod(0o644)
        alias = self.parent / "unrelated-link"
        alias.symlink_to(sibling)
        self.invoke()
        self.assertEqual(0o644, stat.S_IMODE(sibling.stat().st_mode))
        self.assertTrue(alias.is_symlink())

    def test_permission_repair_keeps_an_existing_flight_lock_held(self):
        import fcntl

        self.make_tree()
        lock = self.root / "status-service.start.lock"
        lock.write_bytes(b"running process")
        lock.chmod(0o644)
        with lock.open("rb") as owner:
            fcntl.flock(owner.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            inode = os.fstat(owner.fileno()).st_ino
            self.invoke()
            self.assertEqual(inode, lock.stat().st_ino)
            with lock.open("rb") as contender:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(contender.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertEqual(b"running process", owner.read())

    def test_refuses_writable_home_without_repairing_it(self):
        self.home.chmod(0o777)
        self.assert_refused("home-writable-by-others")
        self.assertFalse(self.parent.exists())
        self.home.chmod(0o700)

    def test_refuses_home_owned_by_another_account(self):
        with mock.patch.object(REPAIR.os, "geteuid", return_value=0):
            self.assert_refused("home-owner-mismatch", lambda: REPAIR.repair(
                str(self.home), self.uid + 100, self.gid))
        self.assertFalse(self.parent.exists())

    def test_refuses_relative_and_noncanonical_home_paths(self):
        for path in ("relative", str(self.home) + "/.", "/"):
            with self.subTest(path=path):
                self.assert_refused("invalid-home", lambda: REPAIR.repair(path, self.uid, self.gid))

    def test_refuses_symlink_home_or_ancestor(self):
        link = self.home / "alias"
        link.symlink_to(self.home, target_is_directory=True)
        for path in (link, link / "missing"):
            with self.subTest(path=path):
                self.assert_refused("unsafe-symlink", lambda: REPAIR.repair(str(path), self.uid, self.gid))

    def test_refuses_symlink_application_parent(self):
        elsewhere = self.home / "elsewhere"
        elsewhere.mkdir()
        self.parent.symlink_to(elsewhere, target_is_directory=True)
        self.assert_refused("unsafe-symlink")
        self.assertEqual([], list(elsewhere.iterdir()))

    def test_refuses_symlink_root(self):
        self.parent.mkdir()
        elsewhere = self.home / "elsewhere"
        elsewhere.mkdir()
        self.root.symlink_to(elsewhere, target_is_directory=True)
        self.assert_refused("unsafe-symlink")

    def test_validates_entire_tree_before_permissions_are_changed(self):
        self.make_tree().chmod(0o755)
        ordinary = self.root / "a-lock"
        ordinary.write_text("unchanged")
        ordinary.chmod(0o644)
        bad = self.root / "z-link"
        bad.symlink_to(ordinary)
        self.assert_refused("unsafe-symlink")
        self.assertEqual(0o755, stat.S_IMODE(self.root.stat().st_mode))
        self.assertEqual(0o644, stat.S_IMODE(ordinary.stat().st_mode))

    def test_refuses_hardlink_without_changing_other_name(self):
        self.make_tree()
        outside = self.home / "outside"
        outside.write_text("untouched")
        outside.chmod(0o644)
        os.link(outside, self.root / "linked-lock")
        self.assert_refused("unsafe-hardlink")
        self.assertEqual(0o644, stat.S_IMODE(outside.stat().st_mode))
        self.assertEqual("untouched", outside.read_text())

    def test_refuses_special_files_without_blocking_on_them(self):
        self.make_tree()
        os.mkfifo(self.root / "pipe")
        self.assert_refused("unsafe-file-type")

    def test_refuses_regular_file_at_directory_location(self):
        self.parent.write_text("not a directory")
        self.assert_refused("unsafe-file-type")
        self.assertEqual("not a directory", self.parent.read_text())

    def test_refuses_foreign_owner_even_when_elevated(self):
        self.make_tree()
        real_inspect = REPAIR.inspect_entry

        def inspect(info, uid, device, home=False):
            if info.st_ino == self.root.stat().st_ino:
                fields = list(info)
                fields[4] = self.uid + 100
                info = os.stat_result(fields)
            return real_inspect(info, uid, device, home)

        with mock.patch.object(REPAIR.os, "geteuid", return_value=0), \
                mock.patch.object(REPAIR, "inspect_entry", side_effect=inspect):
            self.assert_refused("foreign-owner")

    def test_root_owned_tree_requests_privilege_before_any_write(self):
        self.make_tree()
        real_inspect = REPAIR.inspect_entry
        root_inode = self.root.stat().st_ino

        def inspect(info, uid, device, home=False):
            if info.st_ino == root_inode:
                fields = list(info)
                fields[4] = 0
                info = os.stat_result(fields)
            return real_inspect(info, uid, device, home)

        if self.uid == 0:
            self.skipTest("requires a nonroot fixture identity")
        with mock.patch.object(REPAIR, "inspect_entry", side_effect=inspect), \
                mock.patch.object(REPAIR.os, "fchown") as chown, \
                mock.patch.object(REPAIR.os, "fchmod") as chmod:
            code, result = self.invoke_main()
        self.assertEqual(2, code)
        self.assertEqual({"repaired": False, "reason": "privilege-required"}, result)
        chown.assert_not_called()
        chmod.assert_not_called()

    def test_elevated_repair_changes_owner_through_open_descriptor(self):
        real = self.home.stat()
        before_fields = list(real)
        before_fields[0] = stat.S_IFDIR | 0o755
        before_fields[4] = 0
        before = os.stat_result(before_fields)
        after_owner_fields = list(before)
        after_owner_fields[4:6] = [1234, 1234]
        after_owner = os.stat_result(after_owner_fields)
        after_fields = list(after_owner)
        after_fields[0] = stat.S_IFDIR | 0o700
        after = os.stat_result(after_fields)
        entry = REPAIR.inspect_entry(before, 1234, real.st_dev)
        with mock.patch.object(REPAIR.os, "fchown") as chown, \
                mock.patch.object(REPAIR.os, "fchmod") as chmod, \
                mock.patch.object(REPAIR.os, "fstat", side_effect=[after_owner, after]):
            self.assertTrue(REPAIR.secure_entry(42, entry, 1234, 1234))
        chown.assert_called_once_with(42, 1234, 1234)
        chmod.assert_called_once_with(42, 0o700)

    def test_refuses_filesystem_boundary(self):
        self.make_tree()
        real_inspect = REPAIR.inspect_entry
        root_inode = self.root.stat().st_ino

        def inspect(info, uid, device, home=False):
            if info.st_ino == root_inode:
                fields = list(info)
                fields[2] += 1
                info = os.stat_result(fields)
            return real_inspect(info, uid, device, home)

        with mock.patch.object(REPAIR, "inspect_entry", side_effect=inspect):
            self.assert_refused("filesystem-boundary")

    def test_refuses_identity_change_between_scan_and_repair(self):
        self.make_tree()
        real_apply = REPAIR.apply
        moved = self.parent / "old-host-refresh"
        swapped = False

        def swap(parent_fd, name, uid, gid, device, entries, prefix=()):
            nonlocal swapped
            if not swapped:
                self.root.rename(moved)
                self.root.mkdir(mode=0o755)
                swapped = True
            return real_apply(parent_fd, name, uid, gid, device, entries, prefix)

        with mock.patch.object(REPAIR, "apply", side_effect=swap):
            self.assert_refused("path-changed")
        self.assertEqual(0o755, stat.S_IMODE(self.root.stat().st_mode))

    def test_unreadable_root_requests_privilege_without_an_unbounded_retry(self):
        self.make_tree()
        with mock.patch.object(REPAIR, "scan", side_effect=PermissionError), \
                mock.patch.object(REPAIR.os, "geteuid", return_value=self.uid or 1234):
            if self.uid == 0:
                self.skipTest("requires a nonroot fixture identity")
            code, result = self.invoke_main()
        self.assertEqual(2, code)
        self.assertEqual("privilege-required", result["reason"])

    def test_main_prints_one_json_result(self):
        code, result = self.invoke_main()
        self.assertEqual(0, code)
        self.assertEqual({"repaired": True, "reason": "ok"}, result)

    def test_main_reports_refusal_as_json(self):
        self.home.chmod(0o777)
        code, result = self.invoke_main()
        self.home.chmod(0o700)
        self.assertEqual(1, code)
        self.assertEqual({"repaired": False, "reason": "home-writable-by-others"}, result)

    def test_invalid_arguments_use_the_same_json_error_contract(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = REPAIR.main(["--uid", "not-a-number"])
        self.assertEqual(1, code)
        self.assertEqual({"repaired": False, "reason": "invalid-arguments"},
                         json.loads(output.getvalue()))


if __name__ == "__main__":
    unittest.main()
