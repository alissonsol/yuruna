#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Install bounded, recoverable Git origins inside a disposable worker sandbox."""
import base64
import fcntl
import grp
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import subprocess
import sys
import tarfile

UNIT = 'git-mirror-worker.service'
BASE = Path('/var/lib/yuruna/git-mirror/qualification')
STATE = Path('/run/yuruna-gitmirror-origins')
DROPINS = Path('/run/systemd/system/git-mirror-worker.service.d')


def command(*args, timeout=60, check=True):
    return subprocess.run(args, capture_output=True, text=True, check=check, timeout=timeout).stdout.strip()


def environment_assignments(raw, repositories):
    current = dict(item.split(b'=', 1) for item in raw.split(b'\0') if b'=' in item)
    count = int(current.get(b'GIT_CONFIG_COUNT', b'0'))
    if not 0 <= count <= 1024:
        raise ValueError('invalid inherited worker Git configuration')
    values = {}
    for index in range(count):
        key = current[f'GIT_CONFIG_KEY_{index}'.encode()].decode()
        value = current[f'GIT_CONFIG_VALUE_{index}'.encode()].decode()
        for repository in repositories:
            if key.startswith('url.') and key.endswith('.insteadOf') and value in (repository['canonicalUrl'], repository['canonicalUrl'].removesuffix('.git')):
                key = f"url.{Path(repository['path']).as_uri()}.insteadOf"
        values[f'GIT_CONFIG_KEY_{index}'] = key
        values[f'GIT_CONFIG_VALUE_{index}'] = value
    for key, value in [('protocol.file.allow', 'always'), ('credential.helper', '')] + [
            (f'url.{path.as_uri()}.insteadOf', origin)
            for repository in repositories
            for path in [Path(repository['path'])]
            for origin in [repository['canonicalUrl'], repository['canonicalUrl'].removesuffix('.git')]]:
        values[f'GIT_CONFIG_KEY_{count}'] = key
        values[f'GIT_CONFIG_VALUE_{count}'] = value
        count += 1
    values['GIT_CONFIG_COUNT'] = str(count)
    return values


def environment_file(values):
    def quote(value):
        if any(character in value for character in '\0\r\n'):
            raise ValueError('invalid worker environment value')
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('$', '\\$').replace('`', '\\`') + '"'
    return ''.join(key + '=' + quote(value) + '\n' for key, value in values.items())


def receive_bundles(stream, directory):
    expected = {'framework.bundle', 'project.bundle'}
    seen = set()
    total = 0
    with tarfile.open(fileobj=stream, mode='r|') as archive:
        for member in archive:
            if not member.isfile() or member.name not in expected or member.name in seen or not 0 < member.size <= 256 * 1024 * 1024:
                raise ValueError('unexpected native origin bundle member')
            total += member.size
            if total > 512 * 1024 * 1024:
                raise ValueError('native origin bundles exceed the limit')
            with archive.extractfile(member) as source, (directory / member.name).open('xb') as target:
                shutil.copyfileobj(source, target, 1024 * 1024)
            seen.add(member.name)
    if seen != expected:
        raise ValueError('both prepared public origin bundles are required')


def restore(request):
    directory = STATE / request['runId']
    origin_root = BASE / request['runId']
    dropin = DROPINS / ('zz-qualification-origins-' + request['runId'] + '.conf')
    dropin.unlink(missing_ok=True)
    command('systemctl', 'daemon-reload')
    command('systemctl', 'restart', UNIT)
    command('systemctl', 'stop', 'yuruna-mirror-origins-restore-' + request['runId'] + '.timer', check=False)
    # Restart has canceled every reader of the temporary upstreams first.
    if origin_root.exists():
        shutil.rmtree(origin_root)
    if directory.exists():
        shutil.rmtree(directory)
    return {'passed': True, 'restored': True}


def prepare(request, stream):
    directory = STATE / request['runId']
    origin_root = BASE / request['runId']
    if directory.exists() or origin_root.exists():
        raise RuntimeError('this native origin run already exists')
    repositories = request['repositories']
    if len(repositories) != 2 or {entry['name'] for entry in repositories} != {'framework', 'project'}:
        raise ValueError('exactly the two prepared public repositories are required')
    for entry in repositories:
        expected = 'https://github.com/alissonsol/yuruna' + ('-project' if entry['name'] == 'project' else '') + '.git'
        if entry['canonicalUrl'] != expected or not all(re.fullmatch('[0-9a-f]{40}', entry[key]) for key in ('commit', 'tree')):
            raise ValueError('invalid native origin identity')
    directory.mkdir(mode=0o700, parents=True)
    origin_root.mkdir(mode=0o750, parents=True)
    worker = pwd.getpwnam('yuruna-git-worker').pw_uid
    readers = grp.getgrnam('yuruna-git-readers').gr_gid
    # Root owns the parent so the worker cannot replace a different run's
    # directory before privileged cleanup or setup.
    os.chown(BASE, 0, readers)
    os.chmod(BASE, 0o750)
    helper = directory / 'origins.py'
    helper.write_text(globals().get('_PROGRAM') or Path(__file__).read_text())
    cleanup = base64.b64encode(json.dumps(dict(request, action='Restore')).encode()).decode()
    try:
        command('systemd-run', '--quiet', '--unit=yuruna-mirror-origins-restore-' + request['runId'],
                '--on-active=3h', '/usr/bin/python3', str(helper), cleanup)
        receive_bundles(stream, directory)
        for entry in repositories:
            path = origin_root / (entry['name'] + '.git')
            command('git', 'clone', '--bare', str(directory / (entry['name'] + '.bundle')), str(path))
            command('git', '-C', str(path), 'symbolic-ref', 'HEAD', 'refs/heads/main')
            if command('git', '-C', str(path), 'rev-parse', 'HEAD') != entry['commit'] or command('git', '-C', str(path), 'rev-parse', 'HEAD^{tree}') != entry['tree']:
                raise RuntimeError('received native origin differs from the frozen candidate')
            entry['path'] = str(path)
        for path in [origin_root] + list(origin_root.rglob('*')):
            if path.is_symlink():
                raise RuntimeError('native Git origin contains a symbolic link')
            os.chown(path, worker, readers)
            os.chmod(path, 0o750 if path.is_dir() else 0o640)
        pid = int(command('systemctl', 'show', UNIT, '--property=MainPID', '--value'))
        if pid <= 0:
            raise RuntimeError('the actual worker must be running before fixture routing')
        values = environment_assignments(Path(f'/proc/{pid}/environ').read_bytes(), repositories)
        env_path = directory / 'origins.env'
        env_path.write_text(environment_file(values))
        DROPINS.mkdir(parents=True, exist_ok=True)
        dropin = DROPINS / ('zz-qualification-origins-' + request['runId'] + '.conf')
        with dropin.open('x') as file:
            file.write('[Service]\nEnvironmentFile=' + str(env_path) + '\n')
        command('systemctl', 'daemon-reload')
        command('systemctl', 'restart', UNIT)
        pid = int(command('systemctl', 'show', UNIT, '--property=MainPID', '--value'))
        actual = dict(item.split(b'=', 1) for item in Path(f'/proc/{pid}/environ').read_bytes().split(b'\0') if b'=' in item)
        if any(actual.get(key.encode()) != value.encode() for key, value in values.items()):
            raise RuntimeError('another service setting overrides the prepared origins')
        return {'passed': True, 'repositories': repositories, 'automaticRestoreSeconds': 10800}
    except BaseException:
        restore(request)
        raise


def main():
    os.umask(0o077)
    request = json.loads(base64.b64decode(sys.argv[1], validate=True))
    if os.geteuid() != 0 or not re.fullmatch('[0-9a-f]{32}', request.get('runId', '')):
        raise ValueError('native origins require root and a valid disposable run identity')
    STATE.mkdir(mode=0o700, exist_ok=True)
    if STATE.is_symlink() or STATE.stat().st_uid != 0 or (STATE.stat().st_mode & 0o777) != 0o700:
        raise RuntimeError('native origin state is not private')
    with (STATE / 'origins.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if request['action'] == 'Prepare':
            if any(path.is_dir() for path in STATE.iterdir()):
                raise RuntimeError('restore the previous controlled origins before starting another run')
            result = prepare(request, sys.stdin.buffer)
        elif request['action'] == 'Restore':
            result = restore(request)
        else:
            raise ValueError('invalid native origin action')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
