# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""The apt index self-test against stand-in repositories: each verdict, and what it tells the reader.

Runs the script exactly as the seed ships it, read out of the seed the way
tools/Test-ZotRelease.py reads it, so neither squid nor a network is needed.
"""
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import threading
import types
import unittest

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('test_zot_release', ROOT / 'tools/Test-ZotRelease.py')
TOOL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TOOL)
SEED_LINES = TOOL.SEED.read_text(encoding='utf-8').replace('\r\n', '\n').split('\n')
SELFTEST = types.ModuleType('apt_index_selftest')
exec(compile(TOOL.seed_file_body(SEED_LINES, '/usr/local/bin/yuruna-apt-index-selftest.py'), 'yuruna-apt-index-selftest.py', 'exec'), SELFTEST.__dict__)
PROBES = TOOL.seed_file_body(SEED_LINES, '/etc/squid/yuruna-apt-index-probes.list')

DOCKER = 'https://download.docker.com/linux/ubuntu'


def inrelease(listing, date='Wed, 21 Oct 2026 08:17:46 UTC'):
    """An InRelease whose MD5Sum section disagrees on purpose, so only SHA256 may be read."""
    lines = ['Origin: Docker', 'Date: ' + date, 'MD5Sum:']
    lines += [' {0} {1} {2}'.format('0' * 32, 1, path) for path in listing]
    lines.append('SHA256:')
    lines += [' {0} {1} {2}'.format(hashlib.sha256(body).hexdigest(), len(body), path) for path, body in listing.items()]
    return ('\n'.join(lines) + '\n').encode()


def getter(files):
    def get(url):
        if url not in files:
            raise OSError('404 for ' + url)
        value = files[url]
        return value() if callable(value) else value
    return get


class AptIndexSelfTest(unittest.TestCase):
    def test_reads_only_the_sha256_section(self):
        listed = SELFTEST.listed_sha256(inrelease({'stable/binary-arm64/Packages.bz2': b'abc'}))
        self.assertEqual(listed, {'stable/binary-arm64/Packages.bz2': (3, hashlib.sha256(b'abc').hexdigest())})

    def test_a_pair_that_agrees_is_consistent(self):
        root = DOCKER + '/dists/noble'
        files = {root + '/InRelease': inrelease({'stable/binary-amd64/Packages.bz2': b'amd64', 'stable/binary-amd64/Packages': b'x'}),
                 root + '/stable/binary-amd64/Packages.bz2': b'amd64'}
        result = SELFTEST.check_pair(getter(files), {'base': DOCKER, 'suite': 'noble', 'component': 'stable'}, 'amd64')
        self.assertEqual(result['state'], 'consistent')
        self.assertEqual(result['index'], 'stable/binary-amd64/Packages.bz2', 'apt prefers bz2 over the uncompressed index')

    def test_a_pair_that_disagrees_names_the_sizes_and_the_release(self):
        # The shape that failed every arm64 guest: a stored InRelease beside an
        # index from a later publish.
        root = DOCKER + '/dists/noble'
        files = {root + '/InRelease': inrelease({'stable/binary-arm64/Packages.bz2': b'x' * 7}),
                 root + '/stable/binary-arm64/Packages.bz2': b'y' * 9}
        probes = [{'base': DOCKER, 'suite': 'noble', 'component': 'stable', 'arches': ['arm64']}]
        state = {'results': SELFTEST.run(getter(files), probes, 0), 'epoch': 1, 'time': 'T'}
        state['verdict'] = SELFTEST.verdict_of(state['results'])
        self.assertEqual(state['verdict'], 'mismatch')
        text = SELFTEST.render_text(state)
        self.assertTrue(text.startswith(SELFTEST.LABEL + 'MISMATCH -- 1 of 1 disagree'), text)
        self.assertIn('download.docker.com/linux/ubuntu noble arm64: stable/binary-arm64/Packages.bz2 is 9 bytes', text)
        self.assertIn('(Date: Wed, 21 Oct 2026 08:17:46 UTC) lists 7', text)
        self.assertIn('-X PURGE', text, 'the line says how to free the pair')
        self.assertIn('yuruna_apt_index_consistent{repository="download.docker.com/linux/ubuntu",suite="noble",architecture="arm64"} 0',
                      SELFTEST.render_prom(state))

    def test_an_origin_caught_mid_publish_is_read_again(self):
        root = DOCKER + '/dists/noble'
        reads = {'count': 0}

        def index():
            reads['count'] += 1
            return b'old' if reads['count'] == 1 else b'new'
        files = {root + '/InRelease': inrelease({'stable/binary-arm64/Packages.bz2': b'new'}),
                 root + '/stable/binary-arm64/Packages.bz2': index}
        slept = []
        results = SELFTEST.run(getter(files), [{'base': DOCKER, 'suite': 'noble', 'component': 'stable', 'arches': ['arm64']}],
                               30, sleep=slept.append)
        self.assertEqual(results[0]['state'], 'consistent')
        self.assertEqual(slept, [30])

    def test_a_flat_repository_keeps_its_index_beside_its_inrelease(self):
        base = 'https://pkgs.k8s.io/core:/stable:/v1.37/deb'
        files = {base + '/InRelease': inrelease({'Packages.xz': b'k', 'Packages.gz': b'k'}), base + '/Packages.xz': b'k'}
        result = SELFTEST.check_pair(getter(files), {'base': base, 'suite': '/', 'component': '-'}, 'all')
        self.assertEqual((result['state'], result['index']), ('consistent', 'Packages.xz'))

    def test_an_unreadable_pair_is_unverified_and_alone_gives_no_verdict(self):
        probes = [{'base': DOCKER, 'suite': 'noble', 'component': 'stable', 'arches': ['amd64']}]
        state = {'results': SELFTEST.run(getter({}), probes, 0), 'epoch': 1, 'time': 'T'}
        state['verdict'] = SELFTEST.verdict_of(state['results'])
        self.assertEqual(state['verdict'], 'none')
        self.assertIn('NO VERDICT', SELFTEST.render_text(state))
        self.assertIn('unverified -- InRelease unreadable', SELFTEST.render_text(state))
        self.assertIn('yuruna_apt_index_unverified{', SELFTEST.render_prom(state))

    def test_the_shipped_probe_list_covers_both_architectures_and_the_warmed_minor(self):
        with tempfile.TemporaryDirectory() as scratch:
            path = os.path.join(scratch, 'probes.list')
            Path(path).write_text(PROBES, encoding='utf-8')
            probes = SELFTEST.read_probes(path, '1.37')
            pairs = [(p['base'], p['suite'], a) for p in probes for a in p['arches']]
            self.assertIn((DOCKER, 'noble', 'arm64'), pairs)
            self.assertIn((DOCKER, 'resolute', 'amd64'), pairs)
            self.assertIn(('https://pkgs.k8s.io/core:/stable:/v1.37/deb', '/', 'all'), pairs)
            unresolved = [p for p in SELFTEST.read_probes(path, '') if p.get('skip')]
            self.assertEqual(len(unresolved), 1, 'a Kubernetes probe without a resolved minor is skipped, not guessed')

    def test_main_writes_its_state_and_exits_one_on_a_mismatch(self):
        repo = 'http://repo.example/linux/ubuntu'
        files = {repo + '/dists/noble/InRelease': inrelease({'stable/binary-amd64/Packages.gz': b'a' * 4}),
                 repo + '/dists/noble/stable/binary-amd64/Packages.gz': b'b' * 5}

        class Proxy(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                body = files.get(self.path)
                self.send_response(200 if body is not None else 404)
                self.send_header('Content-Length', str(len(body or b'')))
                self.end_headers()
                self.wfile.write(body or b'')

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Proxy)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            with tempfile.TemporaryDirectory() as scratch:
                probes = os.path.join(scratch, 'probes.list')
                Path(probes).write_text(repo + ' noble stable amd64\n', encoding='utf-8')
                proxy = 'http://127.0.0.1:{0}'.format(server.server_address[1])
                code = SELFTEST.main(['--probes', probes, '--prewarm-meta', os.path.join(scratch, 'none'), '--proxy-http', proxy,
                                      '--proxy-https', proxy, '--cafile', '', '--state-dir', scratch, '--settle', '0', '--quiet'])
                self.assertEqual(code, 1)
                state = json.loads(Path(scratch, 'apt-index-selftest.json').read_text())
                self.assertEqual((state['verdict'], state['results'][0]['servedBytes'], state['results'][0]['listedBytes']), ('mismatch', 5, 4))
                self.assertTrue(Path(scratch, 'apt-index-selftest.txt').read_text().startswith(SELFTEST.LABEL + 'MISMATCH'))
                self.assertIn('yuruna_apt_index_selftest_available 1', Path(scratch, 'apt-index-selftest.prom').read_text())
        finally:
            server.shutdown()
            server.server_close()


if __name__ == '__main__':
    unittest.main()
