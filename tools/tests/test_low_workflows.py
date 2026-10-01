# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Local shell contracts. Commands that could mutate a host are fixture executables."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT.parent / 'yuruna-project'
AMISAD = ROOT.parent / 'amisad.dev'


def bash(source, env=None):
    return subprocess.run(['bash', '-c', 'set -euo pipefail\n' + source], env=env, text=True, capture_output=True, timeout=20)


class ShellContracts(unittest.TestCase):
    def test_osinfo_stream_and_failure(self):
        source = (ROOT / 'install/ubuntu.kvm.sh').read_text()
        function = re.search(r'osinfo_has_variant\(\) \{.*?\n}', source, re.S)[0]
        for mode, expected in [('match', 0), ('missing', 1), ('failed', 1)]:
            producer = '''virt-install() { printf 'ubuntu24.04\\n'; python3 -c 'print("other\\n"*100000)'; }'''
            if mode == 'missing':
                producer = "virt-install() { printf 'other\\n'; }"
            if mode == 'failed':
                producer = "virt-install() { printf 'ubuntu24.04\\n'; return 2; }"
            result = bash(producer + '\n' + function + '\nosinfo_has_variant ubuntu24.04')
            self.assertEqual(result.returncode == 0, expected == 0, result.stderr)

    def test_guest_wrappers_and_pins(self):
        subprocess.run(['python3', str(ROOT / 'tools/Sync-GuestWorkflows.py'), '--check'], check=True)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'tools').mkdir()
            shutil.copy(ROOT / 'tools/Sync-GuestWorkflows.py', root / 'tools')
            (root / 'guest/shared').mkdir(parents=True)
            for release in ('24', '26'):
                (root / f'guest/ubuntu.server.{release}').mkdir()
            for name in ('update', 'code', 'n8n', 'openclaw', 'postgresql'):
                (root / f'guest/shared/ubuntu.{name}.sh').write_text('#!/bin/bash\nprintf "%s\\n" "$@"\nexit 17\n')
            subprocess.run(['python3', str(root / 'tools/Sync-GuestWorkflows.py')], check=True)
            for release in ('24', '26'):
                for name in ('update', 'code', 'n8n', 'openclaw', 'postgresql'):
                    path = root / f'guest/ubuntu.server.{release}/ubuntu.server.{release}.{name}.sh'
                    result = subprocess.run(['bash', str(path), 'arg with spaces'], text=True, capture_output=True)
                    self.assertEqual((result.returncode, result.stdout), (17, 'arg with spaces\n'))
                    # bash -c is how the installed fetcher runs downloaded payloads.
                    # Intercept only the final exec; assert its destination and digest.
                    intercept = f'''exec() {{ [ "$1" = /usr/local/lib/yuruna/fetch-and-execute.sh ]; [ "$2" = guest/shared/ubuntu.{name}.sh ]; [ "$3" = 'arg with spaces' ]; [ "$E_SHA" = "$(sha256sum '{root}/guest/shared/ubuntu.{name}.sh' | cut -d' ' -f1)" ]; exit 19; }}\n'''
                    result = subprocess.run(['bash', '-c', intercept + path.read_text(), 'fixture', 'arg with spaces'], capture_output=True)
                    self.assertEqual(result.returncode, 19, result.stderr)
            with (root / 'guest/shared/ubuntu.code.sh').open('a') as f:
                f.write('# drift\n')
            result = subprocess.run(['bash', str(root / 'guest/ubuntu.server.24/ubuntu.server.24.code.sh')], capture_output=True)
            self.assertEqual(result.returncode, 3)

    def test_scenario_http_and_archive_paths(self):
        lib = AMISAD / 'poc/test/amisad-scenario.sh'
        for mode in ('200', '204', '404', '503', 'transport'):
            stub = "curl() { printf 'body\\n" + mode + "'; }"
            if mode == '204':
                stub = "curl() { printf '\\n204'; }"
            if mode == 'transport':
                stub = 'curl() { return 7; }'
            result = bash(stub + f'\n. "{lib}"\namisad_curl http://fixture | cat')
            self.assertEqual(result.returncode == 0, mode in ('200', '204'), result.stderr)
            if mode not in ('200', '204'):
                self.assertIn('SERVICE CALL FAILED', result.stderr)
        for path in (AMISAD / 'poc/test/ubuntu.server.24').glob('*s0*.sh'):
            self.assertIn('. "$POC/test/amisad-scenario.sh"', path.read_text())
            self.assertNotIn('amisad_curl() {', path.read_text())
            subprocess.run(['bash', '-n', str(path)], check=True)

    def test_project_entrypoints(self):
        paths = [p for p in (PROJECT / 'example').glob('*/test/ubuntu.server.*/ubuntu.server.*.workload.k8s.*.sh') if not p.name.endswith('.db.sh')]
        self.assertEqual(len(paths), 3)
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            project = home / 'yuruna/project'
            (project / 'tools').mkdir(parents=True)
            shutil.copy(PROJECT / 'tools/example-workload.sh', project / 'tools')
            for name, component in [('website', 'website'), ('text-to-sql', 'text-to-sql-ui')]:
                (project / f'example/{name}/components/frontend/{component}').mkdir(parents=True)
                config = project / f'example/{name}/config/localhost'
                config.mkdir(parents=True)
                (config / 'resources.output.yml').write_text('clusterDnsPrefix: fixture\n')
            bins = home / 'bin'
            bins.mkdir()
            fixture = '''#!/bin/bash
set -eu
name=${0##*/}
printf '%s %s\n' "$name" "$*" >> "$FIXTURE_LOG"
case "$name:$1" in
 docker:start) [ "$MODE" != registry ] ;;
 docker:run) [ "$MODE" != registry ] ;;
 docker:image) if [ "$2" = ls ] && [ "$MODE" != pull ]; then printf 'registry:2\ndotnet/sdk:10.0\ndotnet/aspnet:10.0\n'; fi ;;
 docker:pull) exit 1 ;;
 docker:build) [ "$MODE" != build ] ;;
 docker:push) [ "$MODE" != push ] ;;
 curl:*) printf '200 0' ;;
 *) exit 0 ;;
esac
'''
            for command in ('sudo', 'mkcert', 'docker', 'curl', 'pwsh', 'kubectl', 'cp', 'sleep'):
                p = bins / command
                p.write_text(fixture)
                p.chmod(0o755)
            for path in paths:
                for mode in ('hit', 'registry', 'pull', 'build', 'push'):
                    log = home / 'commands.log'
                    log.write_text('')
                    source = re.sub(r'^REAL_HOME=.*$', f'REAL_HOME="{home}"', path.read_text(), flags=re.M)
                    env = {**os.environ, 'PATH': f'{bins}:' + os.environ['PATH'], 'MODE': mode, 'FIXTURE_LOG': str(log), 'http_proxy': 'http://fixture:3128'}
                    result = bash(source, env)
                    self.assertEqual(result.returncode == 0, mode == 'hit', f'{path} {mode}: {result.stderr}\n{result.stdout}')
                    commands = log.read_text()
                    if mode == 'hit':
                        self.assertNotIn('docker pull', commands)
                        self.assertIn('docker build --progress=plain', commands)
                        self.assertIn('Set-Workload.ps1', commands)
                    else:
                        self.assertNotIn('Set-Workload.ps1', commands)


if __name__ == '__main__':
    unittest.main()
