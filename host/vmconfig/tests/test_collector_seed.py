# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Native seed contracts. Requires PyYAML and ALLOY_BINARY for pipeline execution.

ZOT_BINARY, when set, names the zot release under review; its check syncs from registry.k8s.io.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request
import yaml

SEED = yaml.safe_load((Path(__file__).resolve().parents[1] / 'caching-proxy-service.base.user-data').read_text())
CONFIG = next(f['content'] for f in SEED['write_files'] if f['path'] == '/etc/alloy/config.alloy')
ZOT_CONFIG = next(f['content'] for f in SEED['write_files'] if f['path'] == '/etc/zot/config.json')
ZOT_INSTALL = next(b for b in SEED['runcmd'] if isinstance(b, str) and 'YURUNA_ZOT_INSTALL' in b)
ZOT_SHA256_AMD64 = re.search(r'ZOT_SHA256_AMD64="([0-9a-f]{64})"', ZOT_INSTALL)[1]
ERREXIT = re.compile(r'^set\s+(-[A-Za-z]*e|-o\s+errexit\b)')
HEREDOC = re.compile(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)")

def top_level_errexit(block):
    """Lines that turn errexit on outside a subshell or heredoc.

    cloud-init runs every runcmd item as one script, so errexit set at an
    item's top level stays on for every later item.
    """
    depth, terminator, found = 0, None, []
    for number, raw in enumerate(block.splitlines(), 1):
        line = raw.strip()
        if terminator:
            if line == terminator: terminator = None
            continue
        if not line or line.startswith('#'): continue
        if line == '(': depth += 1
        elif line.startswith(')'): depth = max(0, depth - 1)
        elif depth == 0 and ERREXIT.match(line): found.append(f'{number}: {line}')
        heredoc = HEREDOC.search(line)
        if heredoc: terminator = heredoc.group(1)
    return found

def run_zot_install(root, fail='', digest=ZOT_SHA256_AMD64):
    """Run the seed's zot install block as x86_64 with every system-changing command stubbed.

    FAIL names the stub that fails; sha256sum reports DIGEST for any file. Returns the
    result and the stubbed commands in call order.
    """
    commands = root/'bin'; commands.mkdir(exist_ok=True)
    for name in ['curl', 'chmod', 'mv', 'useradd', 'install', 'systemctl', 'setfacl', 'sleep']:
        (commands/name).write_text('#!/bin/sh\necho "'+name+' $*" >> "$CALLS"\n[ "$FAIL" != "'+name+'" ]\n', newline='')
    (commands/'sha256sum').write_text('#!/bin/sh\necho "sha256sum $*" >> "$CALLS"\n[ "$FAIL" != sha256sum ] || exit 1\necho "$DIGEST  $1"\n', newline='')
    (commands/'uname').write_text('#!/bin/sh\necho x86_64\n', newline='')
    (commands/'id').write_text('#!/bin/sh\nexit 1\n', newline='')
    for path in commands.iterdir(): path.chmod(0o755)
    shell_root = subprocess.run(['bash', '-c', 'pwd -P'], cwd=root, text=True,
                                capture_output=True, check=True).stdout.strip()
    # Rewrite owned absolute install paths; no actual service or account is touched.
    block = re.sub(r'/(?:usr/local/bin|var/log/zot|var/lib/zot|etc/zot)(?:/[A-Za-z0-9._/-]*)?',
                   lambda match: '"$FIXTURE_ROOT' + match[0] + '"', ZOT_INSTALL)
    calls = root/'calls'; calls.write_text('')
    result = subprocess.run(['bash'], input='export PATH="$FIXTURE_ROOT/bin:$PATH"\n' + block,
        text=True, capture_output=True,
        env={**os.environ, 'FIXTURE_ROOT':shell_root, 'FAIL':fail, 'CALLS':shell_root+'/calls', 'DIGEST':digest})
    return result, [line.split()[0] for line in calls.read_text().splitlines()]

class CollectorSeed(unittest.TestCase):
    def test_shell_syntax(self):
        for block in SEED['runcmd']:
            if isinstance(block, str):
                block = block.replace('# === YURUNA_OVERLAY_FIRMWARE_PKGS ===', 'for pkg in fixture; do')
                result = subprocess.run(['bash', '-n'], input=block, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_errexit_stays_inside_its_item(self):
        self.assertEqual(top_level_errexit('true\nset -e\nfalse\n'), ['2: set -e'])
        self.assertEqual(top_level_errexit('set -o errexit\n'), ['1: set -o errexit'])
        self.assertEqual(top_level_errexit('(\nset -e\nfalse\n) || echo failed\n'), [])
        self.assertEqual(top_level_errexit("bash -e <<'X' || exit 1\nset -e\nX\n"), [])
        leaks = [f'item {index}: {line}' for index, block in enumerate(SEED['runcmd'])
                 if isinstance(block, str) for line in top_level_errexit(block)]
        self.assertEqual(leaks, [], 'errexit set at the top level of a runcmd item stays on for every later item')

    def test_zot_mandatory_failures_stop_installation(self):
        for failure in ['curl', 'sha256sum', 'chmod', 'mv', 'useradd', 'install', 'systemctl']:
            with tempfile.TemporaryDirectory() as directory:
                result, calls = run_zot_install(Path(directory), fail=failure)
                self.assertNotEqual(result.returncode, 0, failure)
                self.assertIn('FAILED', result.stdout)
                self.assertEqual(calls[-1], failure)

    def test_zot_installs_only_the_binary_its_pin_names(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result, calls = run_zot_install(root)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('mv', calls)
            staged = root/'usr/local/bin/zot.tmp'; staged.parent.mkdir(parents=True); staged.write_text('a replaced release asset')
            result, calls = run_zot_install(root, digest='0' * 64)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('failed its SHA-256 check', result.stdout)
            self.assertNotIn('chmod', calls); self.assertNotIn('mv', calls)
            self.assertFalse(staged.exists(), 'a binary that failed its check stays on disk')

    def test_zot_stores_docker_manifest_lists(self):
        self.assertIn('docker2s2', json.loads(ZOT_CONFIG)['http'].get('compat', []),
                      'registry.k8s.io serves Docker manifest lists, which zot 2.1.22 and later refuse to sync without docker2s2')

    @unittest.skipUnless(os.environ.get('ZOT_BINARY'), 'set ZOT_BINARY to check the zot release under review against its pin')
    def test_zot_binary_under_review_is_the_one_the_seed_pins(self):
        binary = Path(os.environ['ZOT_BINARY'])
        arch = {'x86_64': 'AMD64', 'amd64': 'AMD64', 'aarch64': 'ARM64', 'arm64': 'ARM64'}[platform.machine().lower()]
        pin = re.search(r'ZOT_SHA256_' + arch + r'="([0-9a-f]{64})"', ZOT_INSTALL)[1]
        self.assertEqual(hashlib.sha256(binary.read_bytes()).hexdigest(), pin,
                         'a ZOT_VERSION bump must update ZOT_SHA256_AMD64 and ZOT_SHA256_ARM64 with it')
        version = re.search(r'ZOT_VERSION="([^"]+)"', ZOT_INSTALL)[1]
        reported = subprocess.run([str(binary), '--version'], text=True, capture_output=True, timeout=30)
        self.assertIn(f'"{version}-', reported.stdout + reported.stderr)

    @unittest.skipUnless(os.environ.get('ZOT_BINARY'), 'set ZOT_BINARY to sync through the zot release under review')
    def test_zot_syncs_a_docker_manifest_list_and_the_child_a_guest_pulls(self):
        # `zot verify` accepts a config this sync refuses, so only a real sync qualifies a zot release.
        config = json.loads(ZOT_CONFIG)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
            # Storage, log, listener and the optional Hub credential move; the routing table is the seed's.
            config['storage']['rootDirectory'] = str(root/'storage'); config['log']['output'] = str(root/'zot.log')
            config['http'].update(address='127.0.0.1', port=str(port))
            config['extensions']['sync'].pop('credentialsFile', None)
            # Scheduled polls mirror whole multi-arch tags at startup and never serve a guest's pull.
            config['extensions']['sync']['registries'] = [r for r in config['extensions']['sync']['registries'] if r['onDemand']]
            (root/'config.json').write_text(json.dumps(config))
            accept = ('application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, '
                      'application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json')
            def get(path):
                request = urllib.request.Request(f'http://127.0.0.1:{port}/v2/{path}', headers={'Accept': accept})
                try:
                    with urllib.request.urlopen(request, timeout=600) as response:
                        return response.status, response.headers.get('Content-Type'), response.read()
                except urllib.error.HTTPError as error:
                    return error.code, error.headers.get('Content-Type'), error.read()
            process = subprocess.Popen([os.environ['ZOT_BINARY'], 'serve', str(root/'config.json')],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                for _ in range(100):
                    try:
                        if get('')[0] == 200: break
                    except OSError:
                        time.sleep(.1)
                status, media, body = get('pause/manifests/3.10.2?ns=registry.k8s.io')
                self.assertEqual((status, media), (200, 'application/vnd.docker.distribution.manifest.list.v2+json'), body[:200])
                child = next(m['digest'] for m in json.loads(body)['manifests']
                             if m['platform']['os'] == 'linux' and m['platform']['architecture'] == 'amd64')
                status, media, body = get(f'pause/manifests/{child}?ns=registry.k8s.io')
                self.assertEqual((status, media), (200, 'application/vnd.docker.distribution.manifest.v2+json'), body[:200])
                status, _, _ = get(f"pause/blobs/{json.loads(body)['config']['digest']}?ns=registry.k8s.io")
                self.assertEqual(status, 200)
            finally:
                process.terminate(); process.wait(timeout=30)
            self.assertNotIn('requires http.compat docker2s2', (root/'zot.log').read_text())

    def test_alloy_labels_filtering_timestamps_and_restart_positions(self):
        alloy = os.environ['ALLOY_BINARY']
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            files = [root/'squid/yuruna_access.log', root/'squid/yuruna_loopback.log', root/'zot/zot.log']
            legacy = {}
            for path in files:
                path.parent.mkdir(exist_ok=True)
                path.write_text('already-shipped\n'); legacy[str(path)] = str(path.stat().st_size)
            (root/'positions.yaml').write_text(yaml.safe_dump({'positions': legacy}))
            squid = '1727000000.125 1 127.0.0.1 new-squid\n'
            zot = ''.join(json.dumps({'time':'2026-09-28T00:00:00Z', **row})+'\n' for row in [
                {'path':'/metrics','message':'drop-this'}, {'path':'/v2/','message':'request'}, {'message':'background'}])
            for path, line in zip(files, [squid, squid, zot]):
                with path.open('a') as out: out.write(line)
            config = CONFIG[:CONFIG.index('loki.write "default"')] + 'loki.echo "default" {}\n'
            config = config.replace('loki.write.default','loki.echo.default').replace('/var/log/',str(root)+'/').replace('/var/lib/alloy/promtail-positions.yaml',str(root/'positions.yaml'))
            (root/'config.alloy').write_text(config)
            subprocess.run([alloy,'validate',str(root/'config.alloy')],check=True,capture_output=True)
            def run(expected):
                with socket.socket() as sock:
                    sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
                log=root/'output'
                with log.open('w') as out:
                    process=subprocess.Popen([alloy,'run','--disable-reporting',f'--server.http.listen-addr=127.0.0.1:{port}',f'--storage.path={root}/state',str(root/'config.alloy')],stdout=out,stderr=out,env={**os.environ,'TZ':'UTC'})
                    try:
                        for _ in range(100):
                            if log.read_text().count('msg="received log entry"') >= expected: break
                            if process.poll() is not None: break
                            time.sleep(.05)
                    finally:
                        process.terminate(); process.wait(timeout=15)
                return [line for line in log.read_text().splitlines() if 'msg="received log entry"' in line]
            lines=run(4)
            self.assertEqual(len(lines),4,lines)
            joined='\n'.join(lines)
            self.assertNotIn('already-shipped',joined);self.assertNotIn('drop-this',joined)
            for job in ['squid','squid_loopback','zot']:self.assertIn('job=\\"'+job+'\\"',joined)
            self.assertIn('2024-09-22T10:13:20.125Z',joined);self.assertIn('2026-09-28T00:00:00.000Z',joined)
            for path in files:
                with path.open('a') as out:out.write('1727000001.125 1 127.0.0.1 after-restart\n' if path != files[-1] else '{"time":"2026-09-28T00:00:01Z","path":"/v2/","message":"after-restart"}\n')
            lines=run(3)
            self.assertEqual(len(lines),3,lines)
            self.assertTrue(all('after-restart' in line for line in lines),lines)

if __name__ == '__main__': unittest.main()
