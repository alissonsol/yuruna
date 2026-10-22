#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Real key-file recovery tests without invoking SSH or changing systemd."""
import base64
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('rotation', Path(__file__).with_name('git_mirror_native_rotation.py'))
rotation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rotation)


class RotationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.key = self.base / 'signing-key.pem'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:3072', '-out', str(self.key)],
                       check=True, capture_output=True, timeout=30)
        self.key.chmod(0o600)
        self.original = self.key.read_bytes()
        self.directory = self.base / ('a' * 32)
        self.request = {'runId': 'a' * 32}
        self.key_patch = patch.object(rotation, 'KEY', self.key)
        self.key_patch.start()
        self.real_command = rotation.command
        self.calls = []
        def command(*args, **kwargs):
            self.calls.append(args)
            return self.real_command(*args, **kwargs) if args[0] == 'openssl' else b''
        self.command_patch = patch.object(rotation, 'command', side_effect=command)
        self.command_patch.start()

    def tearDown(self):
        self.command_patch.stop()
        self.key_patch.stop()
        self.temp.cleanup()

    def test_prepares_public_identity_and_automatic_restore_without_switching(self):
        prepared = rotation.prepare(self.request, self.directory)
        der = base64.b64decode(prepared['publicKey'], validate=True)
        self.assertEqual(prepared['keyId'], hashlib.sha256(der).hexdigest())
        self.assertEqual(self.key.read_bytes(), self.original)
        self.assertTrue(any(args[:1] == ('systemd-run',) and '--on-active=2h' in args for args in self.calls))
        self.assertNotIn('PRIVATE', str(prepared))
        self.assertTrue(rotation.restore(self.request, self.directory)['restored'])
        self.assertFalse(self.directory.exists())

    def test_switch_and_restore_preserve_original_bytes_mode_and_owner(self):
        previous = self.key.stat()
        rotation.prepare(self.request, self.directory)
        rotation.switch(self.directory)
        self.assertNotEqual(self.key.read_bytes(), self.original)
        rotation.restore(self.request, self.directory)
        self.assertEqual(self.key.read_bytes(), self.original)
        self.assertEqual(self.key.stat().st_mode, previous.st_mode)
        self.assertEqual((self.key.stat().st_uid, self.key.stat().st_gid), (previous.st_uid, previous.st_gid))
        self.assertEqual(sum(args[:2] == ('systemctl', 'restart') for args in self.calls), 2)

    def test_external_key_change_is_never_overwritten_and_backup_survives(self):
        rotation.prepare(self.request, self.directory)
        self.key.write_bytes(b'external operator key')
        for action in (lambda: rotation.switch(self.directory), lambda: rotation.restore(self.request, self.directory)):
            with self.assertRaisesRegex(RuntimeError, 'outside this run'):
                action()
        self.assertEqual(self.key.read_bytes(), b'external operator key')
        self.assertEqual((self.directory / 'original.pem').read_bytes(), self.original)

    def test_restart_failure_leaves_the_original_recoverable(self):
        rotation.prepare(self.request, self.directory)
        with patch.object(rotation, 'command', side_effect=RuntimeError('restart failed')):
            with self.assertRaisesRegex(RuntimeError, 'restart failed'):
                rotation.switch(self.directory)
        self.assertEqual((self.directory / 'original.pem').read_bytes(), self.original)
        self.assertTrue(rotation.restore(self.request, self.directory)['restored'])
        self.assertEqual(self.key.read_bytes(), self.original)

    def test_existing_run_and_symlink_are_refused_without_writing_the_key(self):
        rotation.prepare(self.request, self.directory)
        with self.assertRaisesRegex(RuntimeError, 'already exists'):
            rotation.prepare(self.request, self.directory)
        rotation.restore(self.request, self.directory)
        target = self.base / 'actual.pem'
        self.key.rename(target)
        self.key.symlink_to(target)
        with self.assertRaisesRegex(RuntimeError, 'regular private file'):
            rotation.prepare(self.request, self.directory)
        self.assertEqual(target.read_bytes(), self.original)

    def test_partial_prepare_can_be_cleaned_without_touching_original_key(self):
        self.directory.mkdir()
        (self.directory / 'original.pem').write_bytes(self.original)
        self.assertTrue(rotation.restore(self.request, self.directory)['restored'])
        self.assertFalse(self.directory.exists())
        self.assertEqual(self.key.read_bytes(), self.original)

    def test_existing_temporary_file_is_not_removed_or_replaced(self):
        rotation.prepare(self.request, self.directory)
        temporary = self.key.with_name('qualification-key.tmp')
        temporary.write_bytes(b'preserve another file')
        with self.assertRaises(FileExistsError):
            rotation.switch(self.directory)
        self.assertEqual(temporary.read_bytes(), b'preserve another file')
        self.assertEqual(self.key.read_bytes(), self.original)

    def test_restore_retry_restarts_even_when_original_bytes_already_reached_disk(self):
        rotation.prepare(self.request,self.directory)
        rotation.switch(self.directory)
        with patch.object(rotation,'command',side_effect=RuntimeError('restart failed')):
            with self.assertRaisesRegex(RuntimeError,'restart failed'):
                rotation.restore(self.request,self.directory)
        self.assertEqual(self.key.read_bytes(),self.original)
        self.assertTrue((self.directory/'original.pem').exists())
        with patch.object(rotation,'command',return_value=b'') as command:
            self.assertTrue(rotation.restore(self.request,self.directory)['restored'])
        self.assertIn(('systemctl','restart',rotation.UNIT),[call.args for call in command.call_args_list])


if __name__ == '__main__':
    os.umask(0o077)
    unittest.main()
