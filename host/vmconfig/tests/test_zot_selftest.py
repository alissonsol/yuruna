# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""The zot sync self-test against a stand-in registry: each verdict, and the fix it tells the reader.

Runs the script exactly as the seed ships it, read out of the seed the way
tools/Test-ZotRelease.py reads it, so no PyYAML and no zot binary are needed.
"""
import http.server
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('test_zot_release', ROOT / 'tools/Test-ZotRelease.py')
TOOL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TOOL)
CONTRACT = TOOL.read_contract(TOOL.SEED)

INDEX = {'schemaVersion': 2, 'mediaType': 'application/vnd.docker.distribution.manifest.list.v2+json',
         'manifests': [{'digest': 'sha256:' + 'a' * 64, 'platform': {'os': 'linux', 'architecture': 'arm64'}},
                       {'digest': 'sha256:' + 'b' * 64, 'platform': {'os': 'linux', 'architecture': 'amd64'}}]}
CHILD = {'schemaVersion': 2, 'config': {'digest': 'sha256:' + 'c' * 64}}
REFUSAL = {'level': 'error', 'error': 'docker media type requires http.compat docker2s2: mediaType "x"', 'message': 'failed to sync image'}


class StandInZot(http.server.ThreadingHTTPServer):
    """Answers like zot -- a tag, its children by digest, their config blobs -- and like the upstream behind it.

    The upstream sits under /upstream/ and, like a public registry, wants an
    anonymous Bearer token from /token before it answers.
    """

    def __init__(self, root, mode):
        super().__init__(('127.0.0.1', 0), Handler)
        self.root, self.mode, self.requests = root, mode, []

    def healed(self):
        config = json.loads((self.root / 'config.json').read_text())
        return 'docker2s2' in config.get('http', {}).get('compat', []) and (self.root / 'restarted').exists()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, status, body=b'', media='application/json', headers=None):
        self.send_response(status)
        self.send_header('Content-Type', media)
        self.send_header('Content-Length', str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def upstream(self):
        server = self.server
        if server.mode == 'missing':
            return self.answer(404)
        if server.mode == 'upstream-down':
            return self.answer(503)
        if self.headers.get('Authorization') != 'Bearer t0k3n':
            realm = 'http://127.0.0.1:{0}/token'.format(server.server_address[1])
            return self.answer(401, headers={'WWW-Authenticate': 'Bearer realm="{0}",service="stand-in",scope="repository:pause:pull"'.format(realm)})
        return self.answer(200, media=INDEX['mediaType'])

    def do_HEAD(self):
        self.server.requests.append('HEAD ' + self.path)
        return self.upstream() if self.path.startswith('/upstream/') else self.answer(405)

    def do_GET(self):
        server, path = self.server, self.path.split('?')[0]
        server.requests.append(self.path)
        if path == '/v2/':
            return self.answer(200)
        if path == '/token':
            return self.answer(200, json.dumps({'token': 't0k3n'}).encode())
        mode = 'ok' if server.mode == 'refuse' and server.healed() else server.mode
        if mode == 'missing':
            return self.answer(404, b'{"errors":[{"code":"MANIFEST_UNKNOWN"}]}')
        if mode in ('refuse', 'refuse-quietly', 'upstream-down'):
            if mode == 'refuse':
                with open(server.root / 'zot.log', 'a') as log:
                    log.write(json.dumps(REFUSAL) + '\n')
            return self.answer(503, b'{"errors":[{"code":"UNKNOWN"}]}')
        if '/blobs/' in path:
            return self.answer(200, b'{}', 'application/octet-stream')
        if path.endswith('b' * 64):
            return self.answer(200, json.dumps(CHILD).encode(), 'application/vnd.docker.distribution.manifest.v2+json')
        return self.answer(200, json.dumps(INDEX).encode(), INDEX['mediaType'])


class SyncSelfTest(unittest.TestCase):
    def run_selftest(self, mode, *extra, release='ZOT_VERSION=v2.1.99\nZOT_PINNED_VERSION=v2.1.99\nZOT_OVERRIDE=0\n',
                     zot=None, upstream_url=None):
        root = Path(self.directory.name)
        (root / 'config.json').write_text(json.dumps({'http': {'address': '127.0.0.1', 'port': '5000'}}))
        (root / 'probes.list').write_text(CONTRACT['probes'])
        (root / 'selftest.py').write_text(CONTRACT['selftest'])
        (root / 'release.env').write_text(release)
        server = StandInZot(root, mode)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        base = zot or 'http://127.0.0.1:{0}'.format(server.server_address[1])
        command = [sys.executable, str(root / 'selftest.py'), '--zot', base, '--wait', '1', '--timeout', '10',
                   '--probes', str(root / 'probes.list'), '--config', str(root / 'config.json'),
                   '--log', str(root / 'zot.log'), '--release-env', str(root / 'release.env'),
                   '--state-dir', str(root / 'state'),
                   '--upstream-url', upstream_url or 'http://127.0.0.1:{0}/upstream/{{upstream}}/{{repository}}/{{reference}}'.format(
                       server.server_address[1])]
        result = subprocess.run(command + list(extra), capture_output=True, text=True, timeout=120)
        state = json.loads((root / 'state/zot-selftest.json').read_text())
        prom = (root / 'state/zot-selftest.prom').read_text()
        text = (root / 'state/zot-selftest.txt').read_text()
        return result, state, prom, text, server

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def test_a_release_that_syncs_every_probe_passes(self):
        result, state, prom, text, server = self.run_selftest('ok')
        self.assertEqual((result.returncode, state['verdict']), (0, 'ok'), result.stderr)
        self.assertIn('yuruna_zot_selftest_ok 1', prom)
        self.assertTrue(text.startswith('zot sync self-test           : OK -- zot v2.1.99 synced 4 of 4 probe images'), text)
        # Tag with ns=, then the amd64 child by digest, then its config blob -- the path a pull walks.
        self.assertIn('/v2/pause/manifests/3.10.2?ns=registry.k8s.io', server.requests)
        self.assertIn('/v2/pause/manifests/sha256:' + 'b' * 64 + '?ns=registry.k8s.io', server.requests)
        self.assertIn('/v2/pause/blobs/sha256:' + 'c' * 64 + '?ns=registry.k8s.io', server.requests)

    def test_a_refusal_names_the_mode_zot_asks_for_and_every_fix(self):
        result, state, prom, text, _ = self.run_selftest('refuse')
        self.assertEqual((result.returncode, state['verdict']), (1, 'incompatible'))
        self.assertIn('yuruna_zot_selftest_ok 0', prom)
        self.assertIn('yuruna_zot_selftest_probe_failed{image="registry.k8s.io/pause:3.10.2",stage="tag",status="503",'
                      'outcome="rejected",compat="docker2s2"} 1', prom)
        self.assertIn('INCOMPATIBLE -- zot v2.1.99 refused 4 of 4 probe images', text)
        self.assertIn("HTTP 503 for the tag; zot's log: docker media type requires http.compat docker2s2", text)
        for fix in ('sudo /usr/local/bin/zot-sync-selftest.py --heal', 'add "docker2s2" to the "compat" list',
                    'sudo systemctl restart zot', 'record the new verdict', 'vmStart.cachingProxyZotVersion', 'vmStart.cachingProxyZotSha256',
                    'Update Yuruna', 'tools/Test-ZotRelease.py'):
            self.assertIn(fix, text)
        self.assertNotIn('compat', json.loads((Path(self.directory.name) / 'config.json').read_text())['http'])

    @unittest.skipIf(os.name == 'nt', 'the restart command is split POSIX-style, as on the VM')
    def test_heal_adds_the_mode_restarts_zot_and_tests_again(self):
        root = Path(self.directory.name)
        restart = '{0} -c "open({1!r}, \'w\').close()"'.format(sys.executable, str(root / 'restarted'))
        result, state, prom, text, _ = self.run_selftest('refuse', '--heal', '--restart-command', restart)
        self.assertEqual((result.returncode, state['verdict'], state['compatAdded']), (0, 'healed', ['docker2s2']), text)
        config = json.loads((root / 'config.json').read_text())
        self.assertEqual(config['http']['compat'], ['docker2s2'])
        self.assertEqual(config['http']['port'], '5000')
        self.assertTrue((root / 'config.json.before-selftest').exists())
        self.assertIn('yuruna_zot_selftest_compat_added{mode="docker2s2"} 1', prom)
        self.assertIn('OK AFTER REPAIR', text)
        self.assertIn('report it', text)

    def test_a_gone_probe_image_blames_the_probe_list_not_zot(self):
        result, state, _, text, _ = self.run_selftest('missing')
        self.assertEqual((result.returncode, state['verdict']), (1, 'gone'))
        self.assertIn('PROBE IMAGE GONE', text)
        self.assertIn('the upstream registry answers HTTP 404', text)
        self.assertIn('This says nothing about zot', text)

    def test_an_upstream_outage_is_no_verdict_rather_than_an_incompatible_zot(self):
        result, state, prom, text, _ = self.run_selftest('upstream-down')
        self.assertEqual((result.returncode, state['verdict']), (2, 'unanswered'))
        self.assertIn('yuruna_zot_selftest_verdict{verdict="unanswered"} 1', prom)
        self.assertIn('NO VERDICT', text)
        self.assertIn('the upstream registry answers HTTP 503', text)
        self.assertNotIn('INCOMPATIBLE', text)

    def test_an_upstream_out_of_reach_is_no_verdict(self):
        result, state, _, text, _ = self.run_selftest(
            'refuse-quietly', upstream_url='http://127.0.0.1:9/{upstream}/{repository}/{reference}')
        self.assertEqual((result.returncode, state['verdict']), (2, 'unanswered'))
        self.assertIn('the upstream registry did not answer from here either', text)

    def test_zot_refusing_what_its_upstream_serves_is_incompatible_even_unexplained(self):
        result, state, _, text, server = self.run_selftest('refuse-quietly')
        self.assertEqual((result.returncode, state['verdict']), (1, 'incompatible'))
        # The upstream was asked the anonymous way a public registry requires.
        self.assertIn('/token?service=stand-in&scope=repository:pause:pull', server.requests)
        self.assertIn('the upstream registry serves it', text)
        self.assertIn("zot's log line above names the cause", text)
        self.assertIn('vmStart.cachingProxyZotVersion', text)

    def test_zot_that_does_not_answer_is_no_verdict(self):
        result, state, prom, text, _ = self.run_selftest('ok', zot='http://127.0.0.1:9')
        self.assertEqual((result.returncode, state['verdict']), (2, 'down'))
        self.assertIn('yuruna_zot_selftest_ok 0', prom)
        self.assertIn('NO VERDICT -- zot did not answer GET /v2/ at http://127.0.0.1:9', text)

    def test_an_override_says_which_release_replaced_the_pin(self):
        result, _, prom, text, _ = self.run_selftest('ok', release='ZOT_VERSION=v2.1.21\nZOT_PINNED_VERSION=v2.1.22\nZOT_OVERRIDE=1\n')
        self.assertEqual(result.returncode, 0)
        self.assertIn('zot v2.1.21 (set by vmStart.cachingProxyZotVersion; this Yuruna release pins v2.1.22)', text)
        self.assertIn('yuruna_zot_selftest_release_info{version="v2.1.21",pinned="v2.1.22",override="1"} 1', prom)


class Qualification(unittest.TestCase):
    def test_the_record_qualifies_the_seed(self):
        self.assertIsNone(TOOL.check(CONTRACT, TOOL.RECORD),
                          'run python3 tools/Test-ZotRelease.py: the zot pin, configuration or probe list changed without a live sync')

    def test_the_seed_pins_the_release_its_install_block_downloads(self):
        record = json.loads(TOOL.RECORD.read_text())
        self.assertEqual(record['zotVersion'], CONTRACT['pins']['ZOT_VERSION'])
        self.assertEqual(record['sha256'], {'amd64': CONTRACT['pins']['ZOT_SHA256_AMD64'], 'arm64': CONTRACT['pins']['ZOT_SHA256_ARM64']})

    def test_a_refusal_tells_the_contributor_where_to_add_the_mode(self):
        state = {'verdict': 'incompatible', 'probes': [
            {'image': 'registry.k8s.io/pause:3.10.2', 'status': 503, 'stage': 'tag', 'outcome': 'rejected',
             'reason': 'docker media type requires http.compat docker2s2', 'compat': 'docker2s2'}]}
        contract = dict(CONTRACT, pins=dict(CONTRACT['pins'], ZOT_VERSION='v9.9.9'))
        text = TOOL.guidance(state, contract, TOOL.RECORD)
        self.assertIn('zot v9.9.9 does NOT qualify', text)
        self.assertIn('zot asks for http.compat "docker2s2"', text)
        self.assertIn('host/vmconfig/caching-proxy-service.base.user-data', text)
        self.assertIn('Or keep ZOT_VERSION and both ZOT_SHA256 pins at ' + CONTRACT['pins']['ZOT_VERSION'], text)
        self.assertIn('https://github.com/project-zot/zot/releases/tag/v9.9.9', text)

    def test_any_change_to_the_pin_configuration_or_probes_moves_the_fingerprint(self):
        for change in (dict(pins=dict(CONTRACT['pins'], ZOT_VERSION='v0.0.0')),
                       dict(config=CONTRACT['config'].replace('docker2s2', 'other')),
                       dict(probes=CONTRACT['probes'] + 'quay.io coreos/etcd v3.6.0\n')):
            self.assertNotEqual(TOOL.fingerprint(dict(CONTRACT, **change)), CONTRACT['fingerprint'])


if __name__ == '__main__':
    unittest.main()
