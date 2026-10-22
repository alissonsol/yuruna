#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Disposable fault-control regression tests; never invoke systemd or SSH."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("worker", Path(__file__).with_name("git_mirror_native_worker.py"))
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class WorkerFaultTests(unittest.TestCase):
    def test_preserves_unrelated_git_settings_and_replaces_exact_fixture_routes(self):
        raw = b"GIT_CONFIG_COUNT=2\0GIT_CONFIG_KEY_0=credential.helper\0GIT_CONFIG_VALUE_0=existing helper\0GIT_CONFIG_KEY_1=url.file:///fixture.insteadOf\0GIT_CONFIG_VALUE_1=https://github.com/owner/repo.git\0"
        values = worker.environment_assignments(raw, "http://127.0.0.1:12/")
        self.assertEqual(values["GIT_CONFIG_COUNT"], "3")
        self.assertEqual(values["GIT_CONFIG_VALUE_0"], "existing helper")
        self.assertEqual(values["GIT_CONFIG_KEY_1"], "url.http://127.0.0.1:12/.insteadOf")
        self.assertEqual(values["GIT_CONFIG_VALUE_1"], "https://github.com/owner/repo.git")
        self.assertEqual(values["GIT_CONFIG_VALUE_2"], "https://github.com/")

    def test_rejects_malformed_inherited_count(self):
        for count in ("-1", "1025", "invalid"):
            with self.assertRaises(ValueError):
                worker.environment_assignments(f"GIT_CONFIG_COUNT={count}\0".encode(), "http://127.0.0.1/")

    def test_quotes_unit_environment_without_allowing_multiline_injection(self):
        self.assertEqual(worker.environment_file({"GIT_CONFIG_VALUE_0": 'a"b\\c$d'}), 'GIT_CONFIG_VALUE_0="a\\"b\\\\c\\$d"\n')
        with self.assertRaises(ValueError):
            worker.environment_file({"GIT_CONFIG_VALUE_0": "value\nEnvironment=OTHER=unsafe"})

    def test_restore_removes_only_owned_dropin_and_private_runtime(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            directory = base / "runtime"
            directory.mkdir()
            dropins = base / "dropins"
            dropins.mkdir()
            run_id = "a" * 32
            owned = dropins / ("zzzz-qualification-" + run_id + ".conf")
            owned.write_text("temporary")
            unrelated = dropins / "operator.conf"
            unrelated.write_text("preserved")
            (directory / "state.json").write_text(json.dumps({"dropin": str(owned)}))
            with patch.object(worker, "UNIT_DROPINS", dropins), patch.object(worker, "command") as command, patch.object(worker, "worker_pid", return_value=123):
                result = worker.restore({"runId": run_id}, directory)
            self.assertTrue(result["restored"])
            self.assertFalse(owned.exists())
            self.assertFalse(directory.exists())
            self.assertEqual(unrelated.read_text(), "preserved")
            self.assertIn(("systemctl", "restart", worker.UNIT), [call.args for call in command.call_args_list])

    def test_restore_refuses_state_naming_an_unowned_file(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            unrelated = directory / "operator.conf"
            unrelated.write_text("preserved")
            (directory / "state.json").write_text(json.dumps({"dropin": str(unrelated)}))
            with self.assertRaisesRegex(RuntimeError, "unowned"):
                worker.restore({"runId": "a" * 32}, directory)
            self.assertEqual(unrelated.read_text(), "preserved")

    def test_failed_restart_keeps_recovery_state_but_removes_fault(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root) / "runtime"
            directory.mkdir()
            dropins = Path(root) / "dropins"
            dropins.mkdir()
            run_id = "b" * 32
            owned = dropins / ("zzzz-qualification-" + run_id + ".conf")
            owned.write_text("fault")
            (directory / "state.json").write_text(json.dumps({"dropin": str(owned)}))
            def fail_restart(*args, **_kwargs):
                if args[:2] == ("systemctl", "restart"):
                    raise RuntimeError("service restart failed")
            with patch.object(worker, "UNIT_DROPINS", dropins), patch.object(worker, "command", side_effect=fail_restart):
                with self.assertRaisesRegex(RuntimeError, "restart failed"):
                    worker.restore({"runId": run_id}, directory)
            self.assertFalse(owned.exists())
            self.assertTrue((directory / "state.json").exists())


if __name__ == "__main__":
    unittest.main()
