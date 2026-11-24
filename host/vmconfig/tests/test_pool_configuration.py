# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 420a7522-b10e-4f4f-b5d0-f650613e89df
"""Exercise the shipped pool mount, repository maintenance, and runner over static HTTP."""
import functools
import http.server
import importlib.util
import json
import os
from pathlib import Path
import socket
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('zot_release', ROOT / 'tools/Test-ZotRelease.py')
TOOL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TOOL)
SEED = TOOL.SEED.read_text().splitlines()


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def translate_path(self, path):
        return super().translate_path(path.replace('/pool-intent.git/', '/pool-configuration.git/', 1))

    def do_GET(self):
        if getattr(self.server, 'deny', False):
            self.send_error(403)
        else:
            super().do_GET()


class PoolConfiguration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pool fixture '")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.mount = self.root / 'nas'
        self.mount.mkdir()
        self.store = self.mount / 'pool-configuration.git'
        self.status = self.root / 'status'
        handler = functools.partial(QuietHandler, directory=str(self.mount))
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.url = 'http://127.0.0.1:' + str(self.server.server_port)
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'],
                        GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1',
                        NO_PROXY='*', no_proxy='*')
        self.stub('mountpoint', 'exit 0')
        self.stub('runuser', 'shift 3; exec "$@"')
        self.stub('logger', 'exit 0')
        self.stub('getent', 'exit 1')
        # These cases run one maintenance process, not competing lock holders.
        self.stub('flock', 'exit 0')
        self.stub('id', '[ "$*" = "-g www-data" ] || exit 99; printf "33\\n"')
        if not shutil.which('jq'):
            self.stub_jq()

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/sh\n' + body + '\n', encoding='utf-8', newline='\n')
        path.chmod(0o755)

    def stub_jq(self):
        # The seed reads flat credential fields; keep those checks runnable with
        # the fixture's Python dependency when the developer host has no jq.
        code = r'''
import json
import re
import sys
args = sys.argv[1:]
if args and args[0] == '--binary':
    args = args[1:]
if len(args) != 2 or args[0] != '-r':
    sys.exit('unsupported fixture jq flags')
field = re.fullmatch(r'\.([A-Za-z_][A-Za-z0-9_]*) // empty', args[1])
if field is None:
    sys.exit('unsupported fixture jq filter')
try:
    document = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit('invalid fixture JSON')
if not isinstance(document, dict):
    sys.exit('fixture jq requires an object')
value = document.get(field[1])
if value is not None and value is not False:
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, separators=(',', ':'))
    sys.stdout.buffer.write((text + '\n').encode('utf-8'))
'''
        self.stub('jq', 'exec ' + shlex.quote(Path(sys.executable).as_posix())
                  + ' -c ' + shlex.quote(code) + ' "$@"')

    def shell(self, body, *args, env=None, timeout=90):
        # Shell PATH uses colons; a native Windows drive path would split at C:.
        # Set it after shell startup, which can prepend the host's tool folders.
        body = ('fixture_bin=$(cd ' + shlex.quote(self.bin.as_posix()) + ' && pwd -P) || exit 1\n'
                'PATH="$fixture_bin:$PATH"\nexport PATH\n' + body)
        if os.name == 'nt':
            # Native jq otherwise writes CRLF instead of the guest's LF values.
            body = 'jq() { command jq --binary "$@"; }\n' + body
        return subprocess.run(['sh', '-c', body, *args], env=env or self.env,
                              capture_output=True, text=True, timeout=timeout)

    def git(self, *args):
        return subprocess.run(['git', *map(str, args)], env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def maintain(self):
        body = TOOL.seed_file_body(SEED, '/usr/local/bin/yuruna-pool-configuration.sh')
        body = body.replace('/mnt/ypool-nas', shlex.quote(self.mount.as_posix()))
        body = body.replace('/var/www/html/pool-configuration-status', shlex.quote(self.status.as_posix()))
        body = body.replace('/run/yuruna-pool-configuration.lock', shlex.quote((self.root / 'lock').as_posix()))
        body = body.replace('http://127.0.0.1', self.url)
        return self.shell(body)

    def test_shell_resolves_fixture_tools_before_host_executables(self):
        for name in ('curl', 'git', 'id'):
            self.stub(name, 'printf "fixture-' + name + '\\n"')
        result = self.shell('curl --version; git --version; id', timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'fixture-curl\nfixture-git\nfixture-id\n')

    def test_jq_fixture_extracts_fields_and_rejects_unsupported_or_malformed_input(self):
        self.stub_jq()
        document = json.dumps({'networkPath': '//nas/share with "quotes"', 'absent': None, 'disabled': False})
        prefix = 'printf %s ' + shlex.quote(document) + ' | jq '
        result = self.shell(prefix + '-r ' + shlex.quote('.networkPath // empty'), timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '//nas/share with "quotes"\n')
        for field in ('missing', 'absent', 'disabled'):
            result = self.shell(prefix + '-r ' + shlex.quote('.' + field + ' // empty'), timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, '')
        for request in ('-c ' + shlex.quote('.networkPath // empty'), '-r ' + shlex.quote('.networkPath | length')):
            self.assertNotEqual(self.shell(prefix + request, timeout=5).returncode, 0)
        malformed = self.shell("printf %s '{broken' | jq -r '.networkPath // empty'", timeout=5)
        self.assertNotEqual(malformed.returncode, 0)
        self.assertIn('invalid fixture JSON', malformed.stderr)

    def test_missing_mount_reports_failure_without_creating_a_local_store(self):
        self.stub('mountpoint', 'exit 1')
        result = self.maintain()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAIL storage', self.status.read_text())
        self.assertFalse(self.store.exists())
        self.stub('mountpoint', 'exit 0')
        result = self.maintain()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn('OK', self.status.read_text())

    def test_seeding_is_repeatable_and_repairs_static_http_metadata(self):
        result = self.maintain()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        before = self.git('-C', self.store, 'rev-parse', 'HEAD')
        self.git('-C', self.store, 'config', 'receive.updateServerInfo', 'false')
        (self.store / 'info/refs').unlink()
        result = self.maintain()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.git('-C', self.store, 'rev-parse', 'HEAD'), before)
        self.assertEqual(self.git('-C', self.store, 'config', 'receive.updateServerInfo'), 'false')
        self.assertIn('OK', self.status.read_text())
        self.assertIn(before, (self.store / 'info/refs').read_text())

    def test_legacy_store_is_migrated_without_replacing_its_history(self):
        self.assertEqual(self.maintain().returncode, 0)
        before = self.git('-C', self.store, 'rev-parse', 'HEAD')
        self.store.rename(self.mount / 'pool-intent.git')
        result = self.maintain()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(self.git('-C', self.store, 'rev-parse', 'HEAD'), before)

    def test_apache_read_failure_has_a_distinct_diagnostic(self):
        self.assertEqual(self.maintain().returncode, 0)
        self.stub('runuser', 'exit 1')
        result = self.maintain()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAIL apache-read', self.status.read_text())

    def test_http_denial_is_reported_instead_of_success(self):
        self.stub('curl', 'echo 403; exit 0')
        result = self.maintain()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('HTTP 403', self.status.read_text())

    def test_failed_git_setup_is_not_reported_as_seeded(self):
        self.stub('git', 'echo repository-write-denied >&2; exit 128')
        result = self.maintain()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAIL repository', self.status.read_text())
        self.assertIn('repository-write-denied', result.stderr)
        self.assertFalse(self.store.exists())
        self.assertEqual(list(self.mount.glob('.pool-configuration.*')), [])

    def test_object_transfer_failure_is_detected_after_metadata_succeeds(self):
        self.assertEqual(self.maintain().returncode, 0)
        git = subprocess.run(['sh', '-c', 'command -v git'], capture_output=True, text=True, check=True).stdout.strip()
        self.stub('git', 'case " $* " in *" clone "*) echo object-read-denied >&2; exit 128;; esac\n'
                  'exec "' + git + '" "$@"')
        result = self.maintain()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAIL clone', self.status.read_text())
        self.assertIn('object-read-denied', result.stderr)

    @unittest.skipUnless(sys.platform == 'linux', 'Apache fixture uses the Linux apache2 module layout')
    def test_apache_aliases_serve_a_packed_repository_without_allowing_pushes(self):
        self.assertEqual(self.maintain().returncode, 0)
        self.git('-C', self.store, 'gc')
        self.git('-C', self.store, 'update-server-info')
        with socket.socket() as address:
            address.bind(('127.0.0.1', 0))
            port = address.getsockname()[1]
        alias = TOOL.seed_file_body(SEED, '/etc/apache2/conf-available/yuruna-pool-configuration.conf')
        # Apache needs the complete path quoted when the fixture root has spaces or an apostrophe.
        alias = alias.replace('/mnt/ypool-nas/pool-configuration.git', '"' + str(self.store) + '"')
        config = self.root / 'apache.conf'
        modules = '\n'.join('LoadModule {0}_module /usr/lib/apache2/modules/mod_{0}.so'.format(name)
                            for name in ('mpm_event', 'authz_core', 'authz_host', 'alias'))
        config.write_text('ServerRoot "{0}"\nDefaultRuntimeDir "{0}"\nPidFile "{0}/apache.pid"\n'
                          'ErrorLog "{0}/apache.error.log"\nServerName 127.0.0.1\nListen 127.0.0.1:{1}\n'
                          '{2}\n<Directory />\nRequire all denied\n</Directory>\n{3}'.format(
                              self.root, port, modules, alias))
        apache = subprocess.Popen(['apache2', '-f', str(config), '-DFOREGROUND'],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            url = 'http://127.0.0.1:' + str(port)
            for _ in range(100):
                if apache.poll() is not None:
                    self.fail('Apache did not start: ' + apache.communicate()[1])
                try:
                    with urllib.request.urlopen(url + '/pool-configuration.git/HEAD', timeout=0.2):
                        break
                except urllib.error.URLError:
                    time.sleep(0.05)
            else:
                self.fail('Apache did not serve repository HEAD: ' + (self.root / 'apache.error.log').read_text())
            for route in ('pool-configuration.git', 'pool-intent.git'):
                clone = self.root / (route + '-clone')
                self.git('clone', '-q', url + '/' + route, clone)
                self.assertTrue((clone / 'pools.yml').is_file())
                push = subprocess.run(['git', '-C', str(clone), 'push', 'origin', 'HEAD:refs/heads/probe'],
                                      env=self.env, capture_output=True, text=True, timeout=10)
                self.assertNotEqual(push.returncode, 0)
            self.assertEqual(self.git('-C', self.store, 'for-each-ref', '--format=%(refname)'), 'refs/heads/main')
        finally:
            if apache.poll() is None:
                apache.terminate()
            apache.communicate(timeout=10)

    def test_runner_clones_then_fetches_new_configuration_over_static_http(self):
        work = self.root / 'author'
        self.git('init', '-q', '--initial-branch=main', work)
        doc = work / 'pools.yml'
        doc.write_text('schemaVersion: 4\npools:\n- poolId: lab\n  configuredState: paused\n'
                       '  members: [42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa]\n')
        self.git('-C', work, 'add', 'pools.yml')
        self.git('-C', work, '-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-qm', 'pool configuration')
        self.git('clone', '--bare', work, self.store)
        self.git('-C', self.store, 'update-server-info')
        script = self.root / 'sync.ps1'
        script.write_text('''
param($Repo, $Url, $Runtime)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $Repo 'test/modules/Test.PoolSync.psm1') -DisableNameChecking
Import-Module powershell-yaml
$env:YURUNA_RUNTIME_DIR = $Runtime
$cfg = @{ pool = @{ enabled = $true; configurationGitUrl = $Url; localClonePath = (Join-Path $Runtime 'clone') } }
$pool = Sync-YurunaPoolConfiguration -Config $cfg -HostId '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
if (-not $pool) { throw 'No pool configuration was received' }
$pool.configuredState | ConvertTo-Json -Compress
''')
        def sync():
            result = subprocess.run(['pwsh', '-NoProfile', '-File', str(script), str(ROOT),
                                     self.url + '/pool-configuration.git', str(self.root / 'runtime')],
                                    env=self.env, capture_output=True, text=True, timeout=90)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(sync(), 'paused')
        doc.write_text(doc.read_text().replace('paused', 'drain'))
        self.git('-C', work, 'add', 'pools.yml')
        self.git('-C', work, '-c', 'user.name=fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-qm', 'drain pool')
        self.git('-C', work, 'push', self.store, 'main')
        self.git('-C', self.store, 'update-server-info')
        self.assertEqual(sync(), 'drain')
        self.server.deny = True
        self.assertEqual(sync(), 'drain')
        state = json.loads((self.root / 'runtime/pool.state.json').read_text())
        self.assertFalse(state['configurationOk'])

    def fetch_pool(self, network_ip="192.0.2.25", mount_exit=0, resolve=False, mounted=False, unmount_exit=0, complete=True):
        body = TOOL.seed_file_body(SEED, '/usr/local/bin/yuruna-config-fetch.sh')
        host = self.root / 'host-config'
        host.mkdir()
        for name in ('ca.crt', 'client.crt', 'client.key'):
            (host / name).write_text('fixture')
        body = body.replace('CRED="/etc/yuruna/host-config/$NAME.cifs.cred"',
                            'CRED=' + shlex.quote(host.as_posix()) + '"/$NAME.cifs.cred"')
        body = body.replace('/etc/yuruna/host-config', shlex.quote(host.as_posix()))
        body = body.replace('/etc/yuruna/ypool-nas.cifs.cred', shlex.quote((self.root / 'credentials').as_posix()))
        body = body.replace('/etc/yuruna/host.env', shlex.quote((self.root / 'host.env').as_posix()))
        body = body.replace('/mnt/ypool-nas', shlex.quote(self.mount.as_posix()))
        body = body.replace('STATUS="/var/www/html/config-fetch-$NAME-status"',
                            'STATUS=' + shlex.quote((self.root / 'config-fetch-').as_posix()) + '"$NAME-status"')
        payload = dict(networkPath="//nas/pool", networkIp=network_ip,
                       username="fixture", password="secret", version="1")
        if not complete:
            payload = {"ok": False, "error": "NAS is not configured"}
        self.stub('curl', "printf '%s' " + shlex.quote(json.dumps(payload)))
        if mounted:
            (self.root / 'mounted').touch()
            (host / 'pool.version').write_text('previous-version')
        self.stub('mountpoint', 'test -e ' + shlex.quote((self.root / 'mounted').as_posix()))
        self.stub('umount', ('rm -f ' + shlex.quote((self.root / 'mounted').as_posix())) if unmount_exit == 0 else 'exit ' + str(unmount_exit))
        self.stub('getent', 'exit ' + ('0' if resolve else '1'))
        self.stub('mount', 'printf "%s\\n" "$@" > ' + shlex.quote((self.root / 'mount-args').as_posix()) + '\n'
                  + ('touch ' + shlex.quote((self.root / 'mounted').as_posix()) if mount_exit == 0 else 'exit ' + str(mount_exit)))
        result = self.shell(body, 'fetch', 'pool', env=dict(self.env, YURUNA_STATUS_SERVICE_IP='192.0.2.1'), timeout=10)
        return result

    @unittest.skipUnless(os.name == 'posix', 'Credential and diagnostic mode assertions require POSIX file modes')
    def test_pool_mount_grants_apache_read_access_and_keeps_credentials_private(self):
        result = self.fetch_pool()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.root / 'mount-args').read_text()
        for option in ('gid=', 'forceuid', 'forcegid', 'file_mode=0640', 'dir_mode=0750', 'nounix'):
            self.assertIn(option, args)
        self.assertEqual((self.root / 'credentials').stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.root / 'config-fetch-pool-status').stat().st_mode & 0o777, 0o644)

    def test_remote_nas_address_is_not_replaced_with_the_builder_address(self):
        result = self.fetch_pool()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.root / 'mount-args').read_text()
        self.assertIn('ip=192.0.2.25', args)
        self.assertNotIn('ip=192.0.2.1', args)

    def test_local_nas_loopback_is_mapped_to_the_guest_reachable_builder(self):
        result = self.fetch_pool(network_ip='127.0.0.1')
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.root / 'mount-args').read_text()
        self.assertIn('ip=192.0.2.1', args)
        self.assertNotIn('ip=127.0.0.1', args)

    def test_a_guest_resolvable_name_keeps_working_with_an_older_config_service(self):
        result = self.fetch_pool(network_ip='', resolve=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(',ip=', (self.root / 'mount-args').read_text())

    def test_missing_credentials_are_not_misreported_as_an_address_problem(self):
        result = self.fetch_pool(complete=False)
        self.assertFalse((self.root / 'mount-args').exists())
        status = (self.root / 'config-fetch-pool-status').read_text()
        self.assertIn('incomplete-payload', status)
        self.assertNotIn('nas-address-unresolved', status)

    def test_unresolved_remote_nas_does_not_guess_the_builder_as_storage(self):
        result = self.fetch_pool(network_ip='')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'mount-args').exists())
        self.assertIn('nas-address-unresolved', (self.root / 'config-fetch-pool-status').read_text())

    def test_failed_unmount_preserves_the_previous_version_and_does_not_stack_mounts(self):
        result = self.fetch_pool(mounted=True, unmount_exit=32)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / 'host-config/pool.version').read_text(), 'previous-version')
        self.assertFalse((self.root / 'mount-args').exists())
        self.assertIn('unmount-failed', (self.root / 'config-fetch-pool-status').read_text())

    def test_failed_mount_reports_the_address_and_exit_without_marking_the_version_current(self):
        result = self.fetch_pool(mount_exit=32)
        self.assertNotEqual(result.returncode, 0)
        status = (self.root / 'config-fetch-pool-status').read_text()
        self.assertIn('192.0.2.25', status)
        self.assertIn('exit=32', status)
        self.assertNotIn('secret', status + result.stdout + result.stderr)
        self.assertFalse((self.root / 'host-config/pool.version').exists())


if __name__ == '__main__':
    unittest.main()
