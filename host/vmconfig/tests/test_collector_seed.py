# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
"""Native seed contracts. Requires PyYAML and ALLOY_BINARY for pipeline execution."""
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time
import unittest
import yaml

SEED = yaml.safe_load((Path(__file__).resolve().parents[1] / 'caching-proxy-service.base.user-data').read_text())
CONFIG = next(f['content'] for f in SEED['write_files'] if f['path'] == '/etc/alloy/config.alloy')
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
        block = next(b for b in SEED['runcmd'] if isinstance(b, str) and 'YURUNA_ZOT_INSTALL' in b)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); commands = root/'bin'; commands.mkdir()
            for name in ['curl', 'chmod', 'mv', 'useradd', 'install', 'systemctl', 'setfacl', 'sleep']:
                path = commands/name
                path.write_text('#!/bin/sh\necho "'+name+' $*" >> "$CALLS"\n[ "$FAIL" != "'+name+'" ]\n')
                path.chmod(0o755)
            (commands/'id').write_text('#!/bin/sh\nexit 1\n'); (commands/'id').chmod(0o755)
            # Rewrite owned absolute install paths; no actual service or account is touched.
            block = block.replace('/usr/local/bin/', str(root/'local')+'/').replace('/var/log/zot/', str(root/'log')+'/')
            for failure in ['curl', 'chmod', 'mv', 'useradd', 'install', 'systemctl']:
                calls = root/'calls'; calls.write_text('')
                result = subprocess.run(['bash'], input=block, text=True, capture_output=True,
                    env={**os.environ, 'PATH':str(commands)+':'+os.environ['PATH'], 'FAIL':failure, 'CALLS':str(calls)})
                self.assertNotEqual(result.returncode, 0, failure)
                self.assertIn('FAILED', result.stdout)
                self.assertEqual(calls.read_text().splitlines()[-1].split()[0], failure)

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
