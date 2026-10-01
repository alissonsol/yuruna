# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]

class PesterSelection(unittest.TestCase):

    def test_worker_selects_five_and_rejects_six_only(self):
        module_path = subprocess.check_output(['pwsh', '-NoProfile', '-Command', '$env:PSModulePath'], text=True).strip()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            six = root / 'Pester/6.0.0'
            six.mkdir(parents=True)
            (six / 'Pester.psd1').write_text("@{RootModule='Pester.psm1';ModuleVersion='6.0.0';GUID='9456807e-216a-4b8b-9ed1-95f0671b9358'}")
            (six / 'Pester.psm1').write_text("throw 'Pester 6 must not load'")
            suite = root / 'fixture.ps1'
            suite.write_text("Describe 'native fixture' { It 'passes' { 1 | Should -Be 1 } }")
            result = root / 'result.xml'
            command = ['pwsh', '-NoProfile', '-File', str(ROOT / 'tools/_InvokeOneSuite.ps1'), '-Suite', str(suite), '-Xml', str(result)]
            run = subprocess.run(command, env={**os.environ, 'PSModulePath': str(root) + os.pathsep + module_path}, capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertTrue(result.exists())
            result.unlink()
            expression = f"$env:PSModulePath='{root}'; & '{ROOT}/tools/_InvokeOneSuite.ps1' -Suite '{suite}' -Xml '{result}'; exit $LASTEXITCODE"
            run = subprocess.run(['pwsh', '-NoProfile', '-Command', expression], capture_output=True, text=True)
            self.assertNotEqual(run.returncode, 0)
            self.assertIn('Pester 5.x is required', run.stdout + run.stderr)
            self.assertFalse(result.exists())
if __name__ == '__main__':
    unittest.main()
