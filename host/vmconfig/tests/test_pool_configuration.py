# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Exercise the shipped pool mount, repository maintenance, and runner over static HTTP."""
import functools
import http.server
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
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
        self.temp = tempfile.TemporaryDirectory()
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

    def stub(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/sh\n' + body + '\n')
        path.chmod(0o755)

    def git(self, *args):
        return subprocess.run(['git', *map(str, args)], env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def maintain(self):
        body = TOOL.seed_file_body(SEED, '/usr/local/bin/yuruna-pool-configuration.sh')
        body = body.replace('/mnt/ypool-nas', str(self.mount))
        body = body.replace('/var/www/html/pool-configuration-status', str(self.status))
        body = body.replace('/run/yuruna-pool-configuration.lock', str(self.root / 'lock'))
        body = body.replace('http://127.0.0.1', self.url)
        return subprocess.run(['sh', '-c', body], env=self.env, capture_output=True, text=True, timeout=90)

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

    def test_apache_aliases_serve_a_packed_repository_without_allowing_pushes(self):
        self.assertEqual(self.maintain().returncode, 0)
        self.git('-C', self.store, 'gc')
        self.git('-C', self.store, 'update-server-info')
        with socket.socket() as address:
            address.bind(('127.0.0.1', 0))
            port = address.getsockname()[1]
        alias = TOOL.seed_file_body(SEED, '/etc/apache2/conf-available/yuruna-pool-configuration.conf')
        alias = alias.replace('/mnt/ypool-nas', str(self.mount))
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

    def test_pool_mount_grants_apache_read_access_and_keeps_credentials_private(self):
        body = TOOL.seed_file_body(SEED, '/usr/local/bin/yuruna-config-fetch.sh')
        host = self.root / 'host-config'
        host.mkdir()
        for name in ('ca.crt', 'client.crt', 'client.key'):
            (host / name).write_text('fixture')
        body = body.replace('/etc/yuruna/host-config', str(host))
        body = body.replace('/etc/yuruna/ypool-nas.cifs.cred', str(self.root / 'credentials'))
        body = body.replace('/etc/yuruna/host.env', str(self.root / 'host.env'))
        body = body.replace('/mnt/ypool-nas', str(self.mount))
        body = body.replace('/var/www/html/config-fetch-', str(self.root / 'config-fetch-'))
        self.stub('curl', "printf '%s' '{\"networkPath\":\"//nas/pool\",\"username\":\"fixture\",\"password\":\"secret\",\"version\":\"1\"}'")
        self.stub('mountpoint', 'exit 1')
        self.stub('mount', 'printf "%s\\n" "$@" > "' + str(self.root / 'mount-args') + '"')
        result = subprocess.run(['sh', '-c', body, 'fetch', 'pool'], env=dict(self.env, YURUNA_STATUS_SERVICE_IP='192.0.2.1'),
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        args = (self.root / 'mount-args').read_text()
        for option in ('gid=', 'forceuid', 'forcegid', 'file_mode=0640', 'dir_mode=0750', 'nounix'):
            self.assertIn(option, args)
        self.assertEqual((self.root / 'credentials').stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.root / 'config-fetch-pool-status').stat().st_mode & 0o777, 0o644)


if __name__ == '__main__':
    unittest.main()
