# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Local shell contracts. Commands that could mutate a host are fixture executables."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT.parent / 'yuruna-project'
AMISAD = ROOT.parent / 'amisad.dev'


def bash(source, env=None):
    return subprocess.run(['bash', '-c', 'set -euo pipefail\n' + source], env=env, text=True, capture_output=True, timeout=20)


class ShellContracts(unittest.TestCase):
    def test_postgresql_preserves_existing_clusters_and_starts_the_instance(self):
        source = (ROOT / 'guest/shared/ubuntu.postgresql.sh').read_text()
        block = source.split('# --- REGION: Ensure PostgreSQL cluster\n', 1)[1]
        block = block.split('# --- REGION: Installation summary\n', 1)[0]
        mocks = r'''
sudo() {
    printf '%s\n' "$*" >> "$CALLS"
    case "$*" in
      'pg_lsclusters --no-header')
        cat "$CLUSTERS"
        return "$LIST_EXIT"
        ;;
      'pg_createcluster 18 main')
        [ "$CREATE_EXIT" -eq 0 ] || return "$CREATE_EXIT"
        printf '%s\n' '18 main 5432 down postgres fixture-data fixture-log' >> "$CLUSTERS"
        ;;
      'systemctl enable postgresql') return 0 ;;
      'systemctl start postgresql@18-main') return "$START_EXIT" ;;
      *) echo "Unexpected privileged command: $*" >&2; return 99 ;;
    esac
}
'''
        cases = [
            ('online', '18 main 5432 online postgres data log\n', False, 0, 0, 0),
            ('stopped', '18 main 5432 down postgres data log\n', False, 0, 0, 0),
            ('missing', '', True, 0, 0, 0),
            ('other-major', '17 main 5432 online postgres data log\n', True, 0, 0, 0),
            ('other-name', '18 reporting 5432 online postgres data log\n', True, 0, 0, 0),
            ('incidental-version', '16 main 5418 down postgres /data/18 log\n', True, 0, 0, 0),
            ('inventory-failure', '18 main 5432 down postgres data log\n', False, 37, 0, 0),
            ('creation-failure', '', True, 0, 41, 0),
            ('startup-failure', '18 main 5432 down postgres data log\n', False, 0, 0, 43),
        ]
        for name, inventory, create, list_exit, create_exit, start_exit in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                clusters = root / 'clusters'
                calls = root / 'calls'
                clusters.write_text(inventory)
                env = {**os.environ, 'CLUSTERS': str(clusters), 'CALLS': str(calls),
                       'LIST_EXIT': str(list_exit), 'CREATE_EXIT': str(create_exit),
                       'START_EXIT': str(start_exit)}
                result = bash(mocks + block, env)
                self.assertEqual(result.returncode, list_exit or create_exit or start_exit, result.stderr)
                expected = ['pg_lsclusters --no-header']
                if not list_exit:
                    if create:
                        expected.append('pg_createcluster 18 main')
                    if not create_exit:
                        expected.extend(['systemctl enable postgresql', 'systemctl start postgresql@18-main'])
                self.assertEqual(calls.read_text().splitlines(), expected)
                if not create or list_exit or create_exit:
                    self.assertEqual(clusters.read_text(), inventory)
                if result.returncode == 0:
                    calls.write_text('')
                    again = bash(mocks + block, env)
                    self.assertEqual(again.returncode, 0, again.stderr)
                    self.assertEqual(calls.read_text().splitlines(), [
                        'pg_lsclusters --no-header', 'systemctl enable postgresql',
                        'systemctl start postgresql@18-main'])

    def test_service_readiness_requires_active_unit_and_optional_http_health(self):
        source = (ROOT / 'automation/yuruna-service-bringup.sh').read_text()
        function = re.search(r'yuruna_service_wait_active\(\) \{.*?\n}', source, re.S)[0]
        cases = [('ready', 'http://fixture/healthz', 0, '1 1 0'),
                 ('starting', 'http://fixture/healthz', 0, '3 2 2'),
                 ('inactive', 'http://fixture/healthz', 1, '3 0 3'),
                 ('unhealthy', 'http://fixture/healthz', 1, '3 3 3'),
                 ('ready', '', 0, '1 0 0')]
        mocks = r'''
unit_calls=0; health_calls=0; sleeps=0
sudo() {
    [ "$*" = 'systemctl is-active --quiet fixture.service' ] || return 99
    unit_calls=$((unit_calls+1))
    [ "$MODE" != inactive ] && { [ "$MODE" != starting ] || [ "$unit_calls" -gt 1 ]; }
}
curl() {
    [ "$*" = '-fsS --max-time 2 http://fixture/healthz' ] || return 99
    health_calls=$((health_calls+1))
    [ "$MODE" != unhealthy ] && { [ "$MODE" != starting ] || [ "$health_calls" -gt 1 ]; }
}
sleep() { [ "$1" = 1 ]; sleeps=$((sleeps+1)); }
'''
        for mode, health, expected, counts in cases:
            with self.subTest(mode=mode, health=health):
                command = (mocks + '\n' + function + '\n' +
                           f"if yuruna_service_wait_active fixture.service 3 '{health}'; " +
                           'then rc=0; else rc=$?; fi\n' +
                           'printf "%s %s %s\\n" "$unit_calls" "$health_calls" "$sleeps"\nexit "$rc"')
                result = bash(command, {**os.environ, 'MODE': mode})
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(result.stdout.strip(), counts)

    def test_service_installers_select_common_readiness_budget_and_health_route(self):
        for service in ('download-agent-service', 'pool-control-service', 'stash-service'):
            source = (ROOT / f'guest/ubuntu.server.26/ubuntu.server.26.{service}.sh').read_text()
            start = source.split('# --- REGION: Start the service and wait for readiness\n', 1)[1]
            # Stop before diagnostics and summaries; execute the real readiness call.
            end = re.search(r'(?m)^fi$', start)
            self.assertIsNotNone(end, service)
            start = start[:end.end()]
            for address in (':8123', '') if service == 'stash-service' else (':8123',):
                with self.subTest(service=service, address=address):
                    mocks = ('sudo() { :; }; ss() { :; }\n'
                             'yuruna_service_wait_active() { printf "%s|%s|%s\\n" "$1" "$2" "$3"; }\n'
                             f"HTTP_ADDR='{address}'; POOL_DIR=fixture; STATE_DIR=fixture\n")
                    result = bash(mocks + start)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    health = 'http://127.0.0.1:8123/healthz' if address else ''
                    self.assertIn(f'{service}.service|30|{health}\n', result.stdout)

    def test_standalone_powershell_installers_keep_strict_checksum_contract(self):
        canonical = (ROOT / 'automation/yuruna-retry.sh').read_text()
        function = re.search(r'(?ms)^yuruna_install_pwsh_tarball\(\) \(\n.*?^\)\n', canonical)[0]
        for relative in ('guest/shared/ubuntu.update.sh',
                         'guest/amazon.linux.2023/amazon.linux.2023.update.sh',
                         'guest/ubuntu.server.26/ubuntu.server.26.pool-control-service.sh'):
            source = (ROOT / relative).read_text()
            copied = re.search(r'(?ms)^    yuruna_install_pwsh_tarball\(\) \(\n.*?^    \)\n', source)[0]
            self.assertEqual(re.sub(r'(?m)^    ', '', copied), function, relative)

    def test_osinfo_stream_and_failure(self):
        source = (ROOT / 'install/ubuntu.kvm.sh').read_text()
        function = re.search(r'osinfo_has_variant\(\) \{.*?\n}', source, re.S)[0]
        for mode, expected in [('match', 0), ('missing', 1), ('failed', 1)]:
            producer = "virt-install() { printf 'ubuntu24.04\\n'; printf 'other\\n%.0s' {1..100000}; }"
            if mode == 'missing':
                producer = "virt-install() { printf 'other\\n'; }"
            if mode == 'failed':
                producer = "virt-install() { printf 'ubuntu24.04\\n'; return 2; }"
            result = bash(producer + '\n' + function + '\nosinfo_has_variant ubuntu24.04')
            self.assertEqual(result.returncode == 0, expected == 0, result.stderr)

    def test_guest_wrappers_and_pins(self):
        subprocess.run([sys.executable, str(ROOT / 'tools/Sync-GuestWorkflows.py'), '--check'], check=True)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'tools').mkdir()
            shutil.copy(ROOT / 'tools/Sync-GuestWorkflows.py', root / 'tools')
            (root / 'VERSION').write_text('2026.09.30\n', newline='')
            (root / 'guest/shared').mkdir(parents=True)
            for release in ('24', '26'):
                (root / f'guest/ubuntu.server.{release}').mkdir()
            for name in ('update', 'code', 'k8s', 'n8n', 'openclaw', 'postgresql'):
                (root / f'guest/shared/ubuntu.{name}.sh').write_text('#!/bin/bash\nprintf "%s\\n" "$@"\nexit 17\n', newline='')
            subprocess.run([sys.executable, str(root / 'tools/Sync-GuestWorkflows.py')], check=True)
            for release in ('24', '26'):
                for name in ('update', 'code', 'k8s', 'n8n', 'openclaw', 'postgresql'):
                    path = root / f'guest/ubuntu.server.{release}/ubuntu.server.{release}.{name}.sh'
                    result = subprocess.run(['bash', path.as_posix(), 'arg with spaces'], text=True, capture_output=True)
                    self.assertEqual((result.returncode, result.stdout), (17, 'arg with spaces\n'))
                    # bash -c is how the installed fetcher runs downloaded payloads.
                    # Intercept only the final exec; assert its destination and digest.
                    digest = hashlib.sha256((root / f'guest/shared/ubuntu.{name}.sh').read_bytes()).hexdigest()
                    intercept = f'''exec() {{ [ "$1" = /usr/local/lib/yuruna/fetch-and-execute.sh ]; [ "$2" = guest/shared/ubuntu.{name}.sh ]; [ "$3" = 'arg with spaces' ]; [ "$E_SHA" = '{digest}' ]; exit 19; }}\n'''
                    result = subprocess.run(['bash', '-c', intercept + path.read_text(), 'fixture', 'arg with spaces'], capture_output=True)
                    self.assertEqual(result.returncode, 19, result.stderr)
            with (root / 'guest/shared/ubuntu.code.sh').open('a', newline='') as f:
                f.write('# drift\n')
            result = subprocess.run(['bash', (root / 'guest/ubuntu.server.24/ubuntu.server.24.code.sh').as_posix()], capture_output=True)
            self.assertEqual(result.returncode, 3)

    def test_guest_workflow_version_stamp(self):
        # A release stamp changes the bytes protected by every wrapper.
        # The generator must refresh all twelve pins and their version lines.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'tools').mkdir()
            shutil.copy(ROOT / 'tools/Sync-GuestWorkflows.py', root / 'tools')
            (root / 'guest/shared').mkdir(parents=True)
            for release in ('24', '26'):
                (root / f'guest/ubuntu.server.{release}').mkdir()
            for name in ('update', 'code', 'k8s', 'n8n', 'openclaw', 'postgresql'):
                shared = root / f'guest/shared/ubuntu.{name}.sh'
                shared.write_bytes(b'#!/bin/bash\n# Version: 2026.09.30\nexit 17\n')
            (root / 'VERSION').write_text('2026.09.30\n')
            subprocess.run([sys.executable, str(root / 'tools/Sync-GuestWorkflows.py')], check=True)

            (root / 'VERSION').write_text('2026.10.14\n')
            for name in ('update', 'code', 'k8s', 'n8n', 'openclaw', 'postgresql'):
                shared = root / f'guest/shared/ubuntu.{name}.sh'
                shared.write_bytes(b'#!/bin/bash\n# Version: 2026.10.14\nexit 17\n')
            stale = subprocess.run([sys.executable, str(root / 'tools/Sync-GuestWorkflows.py'), '--check'], capture_output=True, text=True)
            self.assertNotEqual(stale.returncode, 0)
            self.assertEqual(len(stale.stderr.splitlines()) - 1, 12)
            subprocess.run([sys.executable, str(root / 'tools/Sync-GuestWorkflows.py')], check=True)
            subprocess.run([sys.executable, str(root / 'tools/Sync-GuestWorkflows.py'), '--check'], check=True)
            for release in ('24', '26'):
                for name in ('update', 'code', 'k8s', 'n8n', 'openclaw', 'postgresql'):
                    wrapper = (root / f'guest/ubuntu.server.{release}/ubuntu.server.{release}.{name}.sh').read_text()
                    digest = hashlib.sha256((root / f'guest/shared/ubuntu.{name}.sh').read_bytes()).hexdigest()
                    self.assertIn('# Version: 2026.10.14\n', wrapper)
                    self.assertIn(f'expected="{digest}"', wrapper)

    def test_guest_workflow_pre_commit_stages_pins(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'tools/githooks').mkdir(parents=True)
            (root / 'guest/shared').mkdir(parents=True)
            for release in ('24', '26'):
                (root / f'guest/ubuntu.server.{release}').mkdir()
            hook = root / 'tools/githooks/pre-commit'
            shutil.copy(ROOT / 'tools/githooks/pre-commit', hook)
            hook.chmod(0o755)
            shutil.copy(ROOT / 'tools/Sync-GuestWorkflows.py', root / 'tools')
            # SBOM content is covered separately; this fixture checks workflow pins.
            (root / 'tools/Sync-Sbom.py').write_text('raise SystemExit(0)\n')
            (root / 'tools/Test-AsciiNoBom.ps1').write_text('')
            (root / 'VERSION').write_text('2026.09.30\n')
            for name in ('update', 'code', 'k8s', 'n8n', 'openclaw', 'postgresql'):
                (root / f'guest/shared/ubuntu.{name}.sh').write_bytes(
                    b'#!/bin/bash\n# Version: 2026.09.30\nexit 0\n')
            subprocess.run([sys.executable, str(root / 'tools/Sync-GuestWorkflows.py')], check=True)

            env = os.environ.copy()
            env['GIT_CONFIG_GLOBAL'] = os.devnull
            env['GIT_CONFIG_NOSYSTEM'] = '1'
            # Windows has non-runnable Store aliases for python3 and pwsh.
            # The hook should find the installed Python via its fallback.
            env['PATH'] = os.pathsep.join(
                part for part in env['PATH'].split(os.pathsep) if 'WindowsApps' not in part)

            def git(*args):
                return subprocess.run(['git', *args], cwd=root, env=env,
                                      text=True, capture_output=True, check=True)

            git('init', '--initial-branch=main', '--quiet')
            git('config', 'user.name', 'Fixture')
            git('config', 'user.email', 'fixture@example.invalid')
            git('config', 'commit.gpgsign', 'false')
            git('add', '-A')
            git('-c', 'core.hooksPath=', 'commit', '-q', '-m', 'seed')
            git('config', 'core.hooksPath', 'tools/githooks')

            (root / 'VERSION').write_text('2026.10.14\n')
            for name in ('update', 'code', 'k8s', 'n8n', 'openclaw', 'postgresql'):
                (root / f'guest/shared/ubuntu.{name}.sh').write_bytes(
                    b'#!/bin/bash\n# Version: 2026.10.14\nexit 0\n')
            git('add', 'VERSION', 'guest/shared')
            committed = git('commit', '-q', '-m', 'version stamp')
            self.assertIn('regenerated and staged Ubuntu workflow checksum pins', committed.stderr)
            self.assertEqual(git('status', '--porcelain').stdout, '')
            subprocess.run([sys.executable, str(root / 'tools/Sync-GuestWorkflows.py'), '--check'], check=True)
            for release in ('24', '26'):
                for name in ('update', 'code', 'k8s', 'n8n', 'openclaw', 'postgresql'):
                    path = f'guest/ubuntu.server.{release}/ubuntu.server.{release}.{name}.sh'
                    wrapper = git('show', f'HEAD:{path}').stdout
                    digest = hashlib.sha256(
                        (root / f'guest/shared/ubuntu.{name}.sh').read_bytes()).hexdigest()
                    self.assertIn(f'expected="{digest}"', wrapper)
                    self.assertIn('# Version: 2026.10.14', wrapper)

            # A staged version with an unstaged workflow edit must not pin
            # bytes that the proposed commit does not contain.
            (root / 'VERSION').write_text('2026.10.05\n')
            git('add', 'VERSION')
            shared = root / 'guest/shared/ubuntu.update.sh'
            shared.write_bytes(shared.read_bytes() + b'# unstaged\n')
            blocked = subprocess.run(['git', 'commit', '-q', '-m', 'mixed sources'],
                                     cwd=root, env=env, text=True, capture_output=True)
            self.assertNotEqual(blocked.returncode, 0)
            self.assertIn('unstaged edits', blocked.stderr)
            self.assertEqual(git('diff', '--cached', '--name-only').stdout.strip(), 'VERSION')

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
                (config / 'resources.output.yml').write_text('clusterDnsPrefix: fixture\n', newline='')
            bins = home / 'bin'
            bins.mkdir()
            fixture = '''#!/bin/bash
set -eu
name=${0##*/}
printf '%s %s\n' "$name" "$*" >> "$FIXTURE_LOG"
case "$name:$1" in
 docker:start) [ "$MODE" != registry ] && [ "$MODE" != pull ] ;;
 docker:run) [ "$MODE" != registry ] ;;
 docker:image) if [ "$2" = ls ] && [ "$MODE" != pull ]; then printf 'registry:2\ndotnet/sdk:10.0\ndotnet/aspnet:10.0\n'; fi ;;
 docker:pull) exit 1 ;;
 docker:build) [ "$MODE" != build ] ;;
 docker:push) [ "$MODE" != push ] ;;
 pwsh:*)
   case "$1:$MODE" in
     *Set-Resource.ps1:resource|*Set-Component.ps1:component|*Set-Workload.ps1:workload) exit 1 ;;
   esac ;;
 kubectl:wait) [ "$MODE" != readiness ] ;;
 curl:*) printf '200 0' ;;
 *) exit 0 ;;
esac
'''
            for command in ('sudo', 'mkcert', 'docker', 'curl', 'pwsh', 'kubectl', 'cp', 'sleep'):
                p = bins / command
                p.write_text(fixture, newline='')
                p.chmod(0o755)
            shell_home = subprocess.run(['bash', '-c', 'pwd -P'], cwd=home, text=True,
                                        capture_output=True, check=True).stdout.strip()
            for path in paths:
                for mode in ('hit', 'registry', 'pull', 'resource', 'component', 'workload', 'readiness'):
                    log = home / 'commands.log'
                    log.write_text('')
                    source = re.sub(r'^REAL_HOME=.*$', lambda _: 'REAL_HOME="$FIXTURE_HOME"', path.read_text(), flags=re.M)
                    env = {**os.environ, 'MODE': mode, 'USER': 'fixture', 'FIXTURE_HOME': shell_home,
                           'FIXTURE_LOG': shell_home + '/commands.log', 'http_proxy': 'http://fixture:3128'}
                    result = bash('export PATH="$FIXTURE_HOME/bin:$PATH"\n' + source, env)
                    self.assertEqual(result.returncode == 0, mode == 'hit', f'{path} {mode}: {result.stderr}\n{result.stdout}')
                    commands = log.read_text()
                    if mode == 'hit':
                        self.assertNotIn('docker pull', commands)
                        phases = ['Set-Resource.ps1', 'Set-Component.ps1', 'Set-Workload.ps1', 'kubectl wait']
                        positions = [commands.index(phase) for phase in phases]
                        self.assertEqual(positions, sorted(positions))
                        self.assertNotIn('docker build --progress=plain', commands)
                    elif mode in ('registry', 'pull', 'resource', 'component'):
                        self.assertNotIn('Set-Workload.ps1', commands)
                    elif mode == 'workload':
                        self.assertNotIn('kubectl wait', commands)

            for mode in ('hit', 'pull', 'build', 'push'):
                with self.subTest(build_mode=mode):
                    log.write_text('')
                    env = {**os.environ, 'MODE': mode, 'USER': 'fixture', 'FIXTURE_HOME': shell_home,
                           'FIXTURE_LOG': shell_home + '/commands.log', 'http_proxy': 'http://fixture:3128'}
                    source = ('export PATH="$FIXTURE_HOME/bin:$PATH"\nREAL_HOME="$FIXTURE_HOME"\n'
                              '. "$REAL_HOME/yuruna/project/tools/example-workload.sh"\n'
                              'example_registry_prepare\nexample_build_and_push website website\n')
                    result = bash(source, env)
                    self.assertEqual(result.returncode == 0, mode == 'hit', result.stderr)
                    commands = log.read_text()
                    if mode == 'hit':
                        self.assertIn('docker build --progress=plain', commands)
                        self.assertIn('docker push localhost:5000/website/website:latest', commands)
                    elif mode == 'build':
                        self.assertEqual(commands.count('docker build --progress=plain'), 3)
                        self.assertNotIn('docker push localhost:5000/website/website:latest', commands)

    def test_service_seed_framework_fetch_bounds_preserve_fallback_and_provenance(self):
        import textwrap

        mocks = r'''
wget() {
    local url="${@: -1}"
    printf 'wget %s\n' "$*" >> "$FIXTURE_LOG"
    case "$url" in
        */livecheck) [ "$MODE" = host ] || [ "$MODE" = archive_failure ];;
        */yuruna-archive.tar.gz)
            [ "$*" = "--no-proxy --timeout=30 --tries=1 -qO $FETCH_DIR/archive.tar.gz $url" ] || return 99
            printf 'ARCHIVE\n' > "$FETCH_DIR/archive.tar.gz"
            [ "$MODE" != archive_failure ] || return 7
            ;;
        *) return 99;;
    esac
}
tar() {
    [ "$*" = "-xzf $FETCH_DIR/archive.tar.gz -C $FETCH_DIR/tree" ] || return 99
    local content; content=$(cat "$FETCH_DIR/archive.tar.gz")
    [ "$content" = ARCHIVE ] || return 2
    printf 'fixture-host-version\n' > "$FETCH_DIR/tree/VERSION"
}
git() {
    [ "$*" = "-c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 clone --depth 1 https://github.com/alissonsol/yuruna $FETCH_DIR/tree" ] || return 99
    printf 'git %s\n' "$*" >> "$FIXTURE_LOG"
    [ "$MODE" != git_failure ] || return 9
    command mkdir -p "$FETCH_DIR/tree"
    printf 'fixture-mirror-version\n' > "$FETCH_DIR/tree/VERSION"
}
mkdir() {
    [ "$*" = "-p $FETCH_DIR/tree" ] || [ "$*" = "-p $FIXTURE_DIR" ] || return 99
    command mkdir "$@"
}
sleep() { :; }
chown() { :; }
rm() {
    case "$*" in
      "-rf $FETCH_DIR"|"-rf $FETCH_DIR/tree"|"-rf $FETCH_DIR/previous") command rm "$@" ;;
      *) return 99 ;;
    esac
}
'''
        for service in ('stash-service', 'pool-control-service', 'download-agent-service'):
            seed = (ROOT / f'host/vmconfig/{service}.base.user-data').read_text()
            match = re.search(
                r'(?ms)^(?P<indent>[ \t]*)# --- REGION: Fetch the framework\n'
                r'(?P<body>.*?)^(?P=indent)# --- REGION: Build and start the service\n', seed)
            self.assertIsNotNone(match, service)
            lines = match['body'].splitlines()
            if lines[0].strip() == '- |':
                lines.pop(0)
                body_indent = match['indent'] + '  '
                limit = next((i for i, line in enumerate(lines)
                              if line.strip() and not line.startswith(body_indent)), len(lines))
                lines = lines[:limit]
            block = textwrap.dedent('\n'.join(lines))
            for mode in ('host', 'mirror', 'archive_failure', 'git_failure'):
                with self.subTest(service=service, mode=mode), tempfile.TemporaryDirectory() as tmp:
                    fixture = Path(tmp)
                    host_env = fixture / 'host.env'
                    host_env.write_text('YURUNA_STATUS_SERVICE_IP=192.0.2.10\nYURUNA_STATUS_SERVICE_PORT=8080\n')
                    log = fixture / 'commands.log'
                    log.write_text('')
                    destination = fixture / 'checkout'
                    self.assertEqual(destination.resolve().parent, fixture.resolve())
                    destination.mkdir()
                    (destination / 'VERSION').write_text('previous-version\n')
                    (destination / 'sentinel').write_text('preserve unless replacement validated\n')
                    (fixture / 'framework-source').write_text('source=previous\nversion=previous-version\n')
                    source = re.sub(r'(?m)^[ \t]*DEST=.*$', 'DEST="$FIXTURE_DEST"', block)
                    source = source.replace('/etc/yuruna', '"$FIXTURE_DIR"')
                    env = {**os.environ, 'MODE': mode, 'FIXTURE_LOG': log.as_posix(),
                           'FIXTURE_DEST': destination.as_posix(), 'FIXTURE_DIR': fixture.as_posix()}
                    result = bash(mocks + source + '\nprintf "DAEMON_CONTINUES\\n"', env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn('DAEMON_CONTINUES\n', result.stdout)
                    commands = log.read_text()
                    provenance = (fixture / 'framework-source').read_text()
                    if mode == 'host':
                        self.assertNotIn('git ', commands)
                        self.assertIn('source=host\n', provenance)
                        self.assertIn('version=fixture-host-version\n', provenance)
                    else:
                        self.assertEqual(commands.count('git '), 1)
                        if mode == 'git_failure':
                            self.assertIn('could not obtain the framework source', result.stderr)
                            self.assertEqual(provenance, 'source=previous\nversion=previous-version\n')
                            self.assertEqual((destination / 'VERSION').read_text(), 'previous-version\n')
                            self.assertTrue((destination / 'sentinel').is_file())
                        else:
                            self.assertIn('source=mirror\n', provenance)
                            self.assertIn('version=fixture-mirror-version\n', provenance)
                    if mode != 'git_failure':
                        self.assertFalse((destination / 'sentinel').exists())

    def test_download_agent_optional_powershell_requires_verified_tarball(self):
        seed = (ROOT / 'host/vmconfig/download-agent-service.base.user-data').read_text()
        match = re.search(
            r'(?m)^  # --- REGION: https://yuruna.link/429f3d06-008a\n  - \|\n'
            r'(?P<body>(?:^    .*\n|^\n)+)', seed)
        self.assertIsNotNone(match)
        block = re.sub(r'(?m)^    ', '', match['body'])
        package = 'powershell-7.6.1-linux-x64.tar.gz'
        archive = b'fixture PowerShell archive\n'
        digest = hashlib.sha256(archive).hexdigest()
        valid = f'{digest}  {package}\r\n'
        hashes = {
            'missing': None,
            'malformed': f'{"g" * 64}  {package}\n'.encode(),
            'absent_filename': f'{digest}  {package}.sig\n'.encode(),
            'mismatch': f'{"0" * 64}  {package}\n'.encode(),
            'local_hash_missing': valid.encode(),
            'utf16_malformed': b'\xff\xfe' + valid.encode('utf-16-le') + b'x',
            'verified': valid.encode(),
            'verified_uppercase': f'{digest.upper()} *{package}\n'.encode(),
            'verified_utf16': b'\xff\xfe' + valid.encode('utf-16-le'),
        }
        mocks = r'''
command() { [ "$*" != '-v pwsh' ] || return 1; builtin command "$@"; }
wget() { return 1; }
uname() { printf 'x86_64\n'; }
curl() {
    local url="${@: -1}" output='' next=0 arg
    for arg in "$@"; do
        if [ "$next" -eq 1 ]; then output="$arg"; next=0; fi
        [ "$arg" != -o ] || next=1
    done
    case "$url" in
        */releases/latest) printf 'https://github.com/PowerShell/PowerShell/releases/tag/v7.6.1';;
        */powershell-7.6.1-linux-x64.tar.gz) cp "$FIXTURE_ARCHIVE" "$output";;
        */hashes.sha256)
            [ "$MODE" != missing ] || return 1
            cp "$FIXTURE_HASHES" "$output";;
        *) return 99;;
    esac
}
sha256sum() { [ "$MODE" != local_hash_missing ] || return 1; command sha256sum "$@"; }
mkdir() { [ "$*" = '-p /opt/microsoft/powershell/7' ]; }
tar() { printf 'EXTRACT\n' >> "$FIXTURE_LOG"; }
chmod() { [ "$*" = '+x /opt/microsoft/powershell/7/pwsh' ]; }
ln() { [ "$*" = '-sf /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh' ]; }
'''
        for mode, published in hashes.items():
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                fixture = Path(tmp)
                archive_path = fixture / 'archive.fixture'
                hashes_path = fixture / 'hashes.fixture'
                log = fixture / 'commands.log'
                archive_path.write_bytes(archive)
                hashes_path.write_bytes(published or b'')
                log.write_text('')
                env = {
                    **os.environ,
                    'MODE': mode,
                    'FIXTURE_ARCHIVE': archive_path.as_posix(),
                    'FIXTURE_HASHES': hashes_path.as_posix(),
                    'FIXTURE_LOG': log.as_posix(),
                    'FIXTURE_DIR': fixture.as_posix(),
                }
                source = block.replace('/tmp/', '"$FIXTURE_DIR"/')
                result = bash(mocks + source + '\nprintf "DAEMON_CONTINUES\\n"', env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('DAEMON_CONTINUES\n', result.stdout)
                if mode.startswith('verified'):
                    self.assertEqual(log.read_text(), 'EXTRACT\n')
                    self.assertIn('verified) installed from the release tarball.', result.stdout)
                else:
                    self.assertEqual(log.read_text(), '')
                    self.assertIn('NOT installed.', result.stderr)
                    self.assertIn('Windows 11 family stays unavailable.', result.stderr)


if __name__ == '__main__':
    unittest.main()
