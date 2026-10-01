# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
import subprocess, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]

class Utf8Roots(unittest.TestCase):

    def test_directory_and_explicit_target(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'nested').mkdir()
            (root / 'nested' / 'bad.json').write_bytes(b'\xef\xbb\xbf{}')
            good = root / 'good.md'
            good.write_text('ok')
            command = f"& '{ROOT}/tools/Test-Utf8Catalog.ps1' -Path @('{root}','{good}')"
            result = subprocess.run(['pwsh', '-NoProfile', '-Command', command], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn('bad.json', result.stdout + result.stderr)

    def test_empty_directory_does_not_hide_behind_explicit_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'empty').mkdir()
            good = root / 'good.md'
            good.write_text('ok')
            command = f"& '{ROOT}/tools/Test-Utf8Catalog.ps1' -Path @('{root / 'empty'}','{good}'); exit $LASTEXITCODE"
            result = subprocess.run(['pwsh', '-NoProfile', '-Command', command], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def test_directory_only_excludes_binary(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / 'valid.json').write_text('{}')
            (root / 'binary.png').write_bytes(b'\xff')
            result = subprocess.run(['pwsh', '-NoProfile', '-File', str(ROOT / 'tools/Test-Utf8Catalog.ps1'), '-Path', temp], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
if __name__ == '__main__':
    unittest.main()
