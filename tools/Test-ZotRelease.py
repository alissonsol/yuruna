#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Qualify the zot release the caching-proxy seed pins by syncing real images through it.

`zot verify` accepts a configuration that the same release then refuses to sync
with, so only a real sync qualifies a release. This starts the pinned release
on this machine with the seed's routing table and runs the seed's own sync
self-test (zot-sync-selftest.py) against it: the same probe images and the
same verdict the caching-proxy-service VM reports after it installs zot.

A pass is recorded in host/vmconfig/caching-proxy-service.zot-qualified.json
with a fingerprint of the pin, the zot configuration and the probe list. The
pre-commit hook runs this when one of those changes, and the release gate
(test/modules/Test.ZotQualification.Tests.ps1) refuses a seed whose
fingerprint has no passing record.

Exit status: 0 qualified, or already qualified; 1 the release does not
qualify with the seed's configuration and probe list; 2 the qualification
could not run (no network, no zot binary for this platform, a checksum that
does not match).
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SEED = ROOT / 'host/vmconfig/caching-proxy-service.base.user-data'
RECORD = ROOT / 'host/vmconfig/caching-proxy-service.zot-qualified.json'
CONFIG_PATH = '/etc/zot/config.json'
PROBES_PATH = '/etc/zot/yuruna-sync-probes.list'
SELFTEST_PATH = '/usr/local/bin/zot-sync-selftest.py'
PINS = ('ZOT_VERSION', 'ZOT_SHA256_AMD64', 'ZOT_SHA256_ARM64')
RELEASES = 'https://github.com/project-zot/zot/releases'
RERUN = 'python3 tools/Test-ZotRelease.py'


class CannotRun(Exception):
    """The qualification could not reach a verdict."""


class DoesNotQualify(Exception):
    """The release, its configuration or the probe list fails the live sync."""


def seed_file_body(lines, path):
    """The dedented body of one write_files entry.

    Test.ZotQualification.Tests.ps1 reads the seed the same way, so both
    languages fingerprint the same text.
    """
    marker = '  - path: ' + path
    if marker not in lines:
        raise DoesNotQualify('the seed writes no ' + path)
    at = lines.index(marker)
    while at < len(lines) and lines[at] != '    content: |':
        at += 1
    body = []
    for line in lines[at + 1:]:
        if line and not line.startswith('      '):
            break
        body.append(line[6:] if len(line) >= 6 else '')
    return '\n'.join(body).rstrip() + '\n'


def read_contract(seed):
    text = seed.read_text(encoding='utf-8').replace('\r\n', '\n')
    pins = {}
    for name in PINS:
        found = re.findall(r'^\s*' + name + r'="([^"]+)"\s*$', text, re.M)
        if len(found) != 1:
            raise DoesNotQualify('the seed must set {0}="..." exactly once; it does so {1} times'.format(name, len(found)))
        pins[name] = found[0]
    lines = text.split('\n')
    contract = {'pins': pins, 'config': seed_file_body(lines, CONFIG_PATH),
                'probes': seed_file_body(lines, PROBES_PATH), 'selftest': seed_file_body(lines, SELFTEST_PATH)}
    contract['fingerprint'] = fingerprint(contract)
    return contract


def fingerprint(contract):
    """SHA-256 over everything that decides whether a sync passes: the pin, the configuration, the probes."""
    pins = contract['pins']
    text = ''.join([
        'zot_version=' + pins['ZOT_VERSION'] + '\n',
        'zot_sha256_amd64=' + pins['ZOT_SHA256_AMD64'] + '\n',
        'zot_sha256_arm64=' + pins['ZOT_SHA256_ARM64'] + '\n',
        '[' + CONFIG_PATH + ']\n', contract['config'],
        '[' + PROBES_PATH + ']\n', contract['probes'],
    ])
    return hashlib.sha256(text.encode('utf-8')).hexdigest()


def check(contract, record_path):
    """None when the record qualifies this contract, else what changed."""
    try:
        record = json.loads(record_path.read_text(encoding='utf-8'))
    except FileNotFoundError:
        return 'there is no qualification record ({0})'.format(relative(record_path))
    except ValueError as error:
        return 'the qualification record {0} is not JSON: {1}'.format(relative(record_path), error)
    if record.get('fingerprint') == contract['fingerprint']:
        return None
    pinned = contract['pins']['ZOT_VERSION']
    if record.get('zotVersion') != pinned:
        return 'ZOT_VERSION is {0}, but the last qualified release is {1}'.format(pinned, record.get('zotVersion'))
    if record.get('sha256') != {'amd64': contract['pins']['ZOT_SHA256_AMD64'], 'arm64': contract['pins']['ZOT_SHA256_ARM64']}:
        return 'a ZOT_SHA256 pin changed since {0} was qualified'.format(pinned)
    return 'the zot configuration or the probe list changed since {0} was qualified'.format(pinned)


def relative(path):
    try:
        return Path(path).resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


def cache_dir(version):
    if os.name == 'nt':
        base = Path(os.environ.get('LOCALAPPDATA') or Path.home() / 'AppData/Local') / 'yuruna/cache'
    else:
        base = Path(os.environ.get('XDG_CACHE_HOME') or Path.home() / '.cache') / 'yuruna'
    return base / 'zot' / version


def release_asset():
    system = platform.system().lower()
    arch = {'x86_64': 'amd64', 'amd64': 'amd64', 'aarch64': 'arm64', 'arm64': 'arm64'}.get(platform.machine().lower())
    if system not in ('linux', 'darwin', 'windows') or not arch:
        raise CannotRun('zot publishes no binary for {0} {1}; run this on Linux, macOS or Windows (x64/arm64)'.format(
            platform.system(), platform.machine()))
    return 'zot-{0}-{1}{2}'.format(system, arch, '.exe' if system == 'windows' else ''), system, arch


def download(url, timeout=60):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return response.read()
    except (urllib.error.URLError, OSError) as error:
        raise CannotRun('could not download {0}: {1}'.format(url, error))


def expected_digest(contract, asset, system, arch):
    if system == 'linux':
        return contract['pins']['ZOT_SHA256_' + arch.upper()]
    # The seed pins only the Linux binaries it installs; another platform's
    # binary is checked against the release's own checksum list.
    version = contract['pins']['ZOT_VERSION']
    sums = download('{0}/download/{1}/checksums.sha256.txt'.format(RELEASES, version)).decode('utf-8', 'replace')
    for line in sums.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].lstrip('*') == asset:
            return parts[0].lower()
    raise CannotRun('{0}/tag/{1} lists no checksum for {2}'.format(RELEASES, version, asset))


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as handle:
        for block in iter(lambda: handle.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def zot_binary(contract, supplied):
    asset, system, arch = release_asset()
    want = expected_digest(contract, asset, system, arch)
    version = contract['pins']['ZOT_VERSION']
    if supplied:
        got = sha256_of(supplied)
        if got != want:
            raise DoesNotQualify('{0} is not the {1} {2} the seed pins (SHA-256 {3}, want {4}). A ZOT_VERSION change must '
                                 'update ZOT_SHA256_AMD64 and ZOT_SHA256_ARM64 from the release checksums.sha256.txt.'.format(
                                     supplied, version, asset, got, want))
        return Path(supplied), asset
    target = cache_dir(version) / asset
    if target.is_file() and sha256_of(target) == want:
        return target, asset
    url = '{0}/download/{1}/{2}'.format(RELEASES, version, asset)
    print('Downloading zot {0} ({1}) once into {2} ...'.format(version, asset, target.parent), flush=True)
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_name(asset + '.part')
    try:
        with urllib.request.urlopen(url, timeout=60) as response, open(partial, 'wb') as out:
            shutil.copyfileobj(response, out, 1 << 20)
    except (urllib.error.URLError, OSError) as error:
        if partial.exists():
            partial.unlink()
        raise CannotRun('could not download {0}: {1}'.format(url, error))
    got = sha256_of(partial)
    if got != want:
        partial.unlink()
        if system == 'linux':
            raise DoesNotQualify('{0} has SHA-256 {1}, but the seed pins {2}. Copy both ZOT_SHA256 pins from {3}/download/{4}/'
                                 'checksums.sha256.txt.'.format(url, got, want, RELEASES, version))
        raise CannotRun('{0} has SHA-256 {1}, but its release lists {2}'.format(url, got, want))
    partial.chmod(0o755)
    os.replace(partial, target)
    return target, asset


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def local_config(config_text, scratch, port):
    """The seed's configuration with storage, log and listener moved into scratch.

    The routing table stays the seed's. The Docker Hub credential is optional
    and absent here, as on an anonymous install. Scheduled polls mirror whole
    tags at startup and never serve a guest's pull, so they are left out.
    """
    config = json.loads(config_text)
    config.setdefault('storage', {})['rootDirectory'] = str(scratch / 'storage')
    config.setdefault('log', {})['output'] = str(scratch / 'zot.log')
    config.setdefault('http', {}).update(address='127.0.0.1', port=str(port))
    sync = config.get('extensions', {}).get('sync', {})
    sync.pop('credentialsFile', None)
    sync['registries'] = [entry for entry in sync.get('registries', []) if entry.get('onDemand')]
    return config


def qualify(contract, binary, asset):
    version = contract['pins']['ZOT_VERSION']
    scratch = Path(tempfile.mkdtemp(prefix='yuruna-zot-'))
    process = None
    try:
        port = free_port()
        config = scratch / 'config.json'
        config.write_text(json.dumps(local_config(contract['config'], scratch, port), indent=2), encoding='utf-8')
        (scratch / 'probes.list').write_text(contract['probes'], encoding='utf-8')
        (scratch / 'zot-sync-selftest.py').write_text(contract['selftest'], encoding='utf-8')
        (scratch / 'release.env').write_text('ZOT_VERSION={0}\nZOT_PINNED_VERSION={0}\nZOT_OVERRIDE=0\n'.format(version), encoding='utf-8')
        with open(scratch / 'zot.out', 'wb') as out:
            process = subprocess.Popen([str(binary), 'serve', str(config)], stdout=out, stderr=subprocess.STDOUT)
        print('Syncing the probe images through zot {0} ({1}) with the seed\'s configuration ...'.format(version, asset), flush=True)
        selftest = subprocess.run([sys.executable, str(scratch / 'zot-sync-selftest.py'), '--quiet',
                                   '--zot', 'http://127.0.0.1:{0}'.format(port), '--wait', '30',
                                   '--probes', str(scratch / 'probes.list'), '--config', str(config),
                                   '--log', str(scratch / 'zot.log'), '--release-env', str(scratch / 'release.env'),
                                   '--state-dir', str(scratch / 'state')], timeout=3600)
        state_file = scratch / 'state/zot-selftest.json'
        if not state_file.is_file():
            raise CannotRun('the seed\'s sync self-test ended (exit {0}) without a result'.format(selftest.returncode))
        state = json.loads(state_file.read_text(encoding='utf-8'))
        if state['verdict'] == 'down':
            exited = process.poll()
            output = (scratch / 'zot.out').read_text(encoding='utf-8', errors='replace').strip().splitlines()[-15:]
            if exited is not None:
                raise DoesNotQualify('zot {0} exited (status {1}) instead of serving the seed\'s configuration:\n    {2}'.format(
                    version, exited, '\n    '.join(output) or '(no output)'))
            raise CannotRun('zot {0} did not answer GET /v2/ within 30 seconds'.format(version))
        return state
    finally:
        if process and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
        shutil.rmtree(scratch, ignore_errors=True)


def guidance(state, contract, record_path):
    """What a contributor does about a release that fails the live sync."""
    version = contract['pins']['ZOT_VERSION']
    failed = [probe for probe in state['probes'] if probe['outcome'] != 'ok']
    lines = []
    for probe in failed:
        answer = 'no answer' if probe['status'] == 0 else 'HTTP {0}'.format(probe['status'])
        line = '  {0}: {1} at the {2}'.format(probe['image'], answer, probe['stage'])
        lines.append(line + ("; zot's log: " + probe['reason'] if probe['reason'] else ''))
    try:
        qualified = json.loads(record_path.read_text(encoding='utf-8')).get('zotVersion')
    except (OSError, ValueError):
        qualified = None
    seed = relative(SEED)
    if state['verdict'] == 'gone':
        return '\n'.join(['The probe list names {0} image(s) the upstream registry no longer publishes:'.format(len(failed))] + lines + [
            'What to do: replace each in {0} in {1} with a tag that registry publishes, then commit again.'.format(PROBES_PATH, seed),
        ])
    if state['verdict'] == 'unanswered':
        return '\n'.join(['The qualification has no verdict: an upstream registry did not answer from this machine.'] + lines + [
            'What to do: check this machine\'s internet access to those registries, then run {0} again.'.format(RERUN),
        ])
    modes = sorted({probe['compat'] for probe in failed if probe['compat']})
    text = ['zot {0} does NOT qualify: with the seed\'s configuration it refused {1} of {2} probe images.'.format(
        version, len(failed), len(state['probes']))] + lines + [
        'A caching-proxy-service VM built with this pin would refuse those images to every guest.',
        'What to do:',
    ]
    if modes:
        text += ['  - zot asks for http.compat {0}. Add it to the "compat" list in the "http" block of'.format(
                     ', '.join('"{0}"'.format(mode) for mode in modes)),
                 '    {0} in {1}, then commit again; the hook re-runs this qualification.'.format(CONFIG_PATH, seed)]
    else:
        text += ["  - zot's log lines above name the cause. Change {0} in {1} to match,".format(CONFIG_PATH, seed),
                 '    then commit again; the hook re-runs this qualification.']
    if qualified and qualified != version:
        text += ['  - Or keep ZOT_VERSION and both ZOT_SHA256 pins at {0}, the release {1} records as qualified.'.format(
            qualified, relative(record_path))]
    text += ['  - Read the release notes for sync and compat changes: {0}/tag/{1}'.format(RELEASES, version),
             '  Re-run by hand: ' + RERUN]
    return '\n'.join(text)


def write_record(contract, state, asset, record_path):
    pins = contract['pins']
    record = {
        'zotVersion': pins['ZOT_VERSION'],
        'sha256': {'amd64': pins['ZOT_SHA256_AMD64'], 'arm64': pins['ZOT_SHA256_ARM64']},
        'fingerprint': contract['fingerprint'],
        'qualifiedOn': datetime.date.today().isoformat(),
        'qualifiedWith': asset,
        'probes': [{'image': probe['image'], 'mediaType': probe['mediaType']} for probe in state['probes']],
    }
    with open(record_path, 'w', encoding='utf-8', newline='\n') as handle:
        handle.write(json.dumps(record, indent=2) + '\n')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n', 1)[0])
    parser.add_argument('--check', action='store_true', help='only compare the seed with the record; no network')
    parser.add_argument('--force', action='store_true', help='qualify again even when the record matches')
    parser.add_argument('--stage', action='store_true', help='git add the record after a pass')
    parser.add_argument('--binary', default=os.environ.get('ZOT_BINARY'),
                        help='a downloaded zot release binary to use instead of fetching it (default: $ZOT_BINARY)')
    parser.add_argument('--seed', type=Path, default=SEED, help=argparse.SUPPRESS)
    parser.add_argument('--record', type=Path, default=RECORD, help=argparse.SUPPRESS)
    parser.add_argument('--quiet', action='store_true')
    args = parser.parse_args(argv)
    try:
        contract = read_contract(args.seed)
        changed = check(contract, args.record)
        if changed is None and not args.force:
            if not args.quiet:
                print('zot {0} is qualified for this seed ({1}).'.format(contract['pins']['ZOT_VERSION'], relative(args.record)))
            return 0
        if args.check:
            print('zot qualification: {0}.'.format(changed), file=sys.stderr)
            print('A zot release can accept this configuration and still refuse the images the lab pulls, so the change\n'
                  'needs a live sync. Run: {0}  (needs internet; downloads the pinned release once)'.format(RERUN), file=sys.stderr)
            return 1
        binary, asset = zot_binary(contract, args.binary)
        state = qualify(contract, binary, asset)
        if state['verdict'] == 'unanswered':
            raise CannotRun(guidance(state, contract, args.record))
        if state['verdict'] != 'ok':
            raise DoesNotQualify(guidance(state, contract, args.record))
        write_record(contract, state, asset, args.record)
        if args.stage:
            subprocess.run(['git', '-C', str(ROOT), 'add', '--', relative(args.record)], check=True)
        formats = sorted({probe['mediaType'] for probe in state['probes']})
        print('zot {0} qualified: it synced {1} probe images ({2}) with the seed\'s configuration; recorded in {3}.'.format(
            contract['pins']['ZOT_VERSION'], len(state['probes']), ', '.join(formats), relative(args.record)))
        return 0
    except DoesNotQualify as error:
        print(str(error), file=sys.stderr)
        return 1
    except CannotRun as error:
        print('zot qualification could not run: {0}'.format(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
