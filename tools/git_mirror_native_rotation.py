#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Recoverable signing-key rotation on an explicitly disposable proxy VM."""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys

BASE = Path('/run/yuruna-gitmirror-rotation')
KEY = Path('/etc/yuruna/git-mirror/signing-key.pem')
UNIT = 'git-mirror-worker.service'


def command(*args, check=True):
    return subprocess.run(args, capture_output=True, check=check, timeout=60).stdout


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def replace_key(source, metadata):
    temporary = KEY.with_name('qualification-key.tmp')
    created = False
    try:
        with temporary.open('xb') as stream:
            created = True
            stream.write(source.read_bytes())
            stream.flush()
            os.fsync(stream.fileno())
        os.chown(temporary, metadata['uid'], metadata['gid'])
        os.chmod(temporary, metadata['mode'])
        os.replace(temporary, KEY)
    finally:
        if created:
            temporary.unlink(missing_ok=True)


def restore(request, directory):
    if directory.is_symlink():
        raise RuntimeError('rotation state must not be a symbolic link')
    state_path = directory / 'state.json'
    if not state_path.exists():
        if directory.exists():
            shutil.rmtree(directory)
        return {'restored': True, 'changed': False}
    state = json.loads(state_path.read_text())
    if KEY.is_symlink() or digest(KEY) not in (state['oldHash'], state['newHash']):
        raise RuntimeError('signing key changed outside this run; its private backup remains available')
    if digest(KEY) != state['oldHash']:
        replace_key(directory / 'original.pem', state)
    # A previous restore can reach disk before a failed service restart. Always
    # replace the resident signer before retiring the backup and restore timer.
    command('systemctl', 'restart', UNIT)
    command('systemctl', 'stop', 'yuruna-mirror-key-restore-' + request['runId'] + '.timer', check=False)
    shutil.rmtree(directory)
    return {'restored': True, 'changed': True}


def prepare(request, directory):
    if directory.exists():
        raise RuntimeError('rotation state already exists; restore it before reuse')
    metadata = KEY.lstat()
    if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o600:
        raise RuntimeError('the provisioned signing key must be a regular private file')
    directory.mkdir(mode=0o700)
    helper = directory / 'rotation.py'
    helper.write_text(globals().get('_PROGRAM') or Path(__file__).read_text())
    original = directory / 'original.pem'
    original.write_bytes(KEY.read_bytes())
    new_key = directory / 'new.pem'
    command('openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt', 'rsa_keygen_bits:3072', '-out', str(new_key))
    public = command('openssl', 'pkey', '-in', str(new_key), '-pubout', '-outform', 'DER')
    state = {'uid': metadata.st_uid, 'gid': metadata.st_gid, 'mode': stat.S_IMODE(metadata.st_mode),
             'oldHash': digest(original), 'newHash': digest(new_key)}
    (directory / 'state.json').write_text(json.dumps(state))
    cleanup = base64.b64encode(json.dumps(dict(request, action='Restore')).encode()).decode()
    # The key remains recoverable if the SSH controller or its host disappears.
    command('systemd-run', '--quiet', '--unit=yuruna-mirror-key-restore-' + request['runId'],
            '--on-active=2h', '/usr/bin/python3', str(helper), cleanup)
    return {'publicKey': base64.b64encode(public).decode(), 'keyId': hashlib.sha256(public).hexdigest()}


def switch(directory):
    state = json.loads((directory / 'state.json').read_text())
    if KEY.is_symlink() or digest(KEY) != state['oldHash']:
        raise RuntimeError('refusing to replace a signing key changed outside this run')
    replace_key(directory / 'new.pem', state)
    command('systemctl', 'restart', UNIT)
    return {'switched': True}


def main():
    os.umask(0o077)
    if os.geteuid() != 0:
        raise RuntimeError('native signing-key control requires root in the disposable proxy')
    request = json.loads(base64.b64decode(sys.argv[1], validate=True))
    if not re.fullmatch('[0-9a-f]{32}', request.get('runId', '')):
        raise ValueError('invalid rotation identity')
    if request.get('action') not in ('Prepare', 'Switch', 'Restore'):
        raise ValueError('invalid rotation action')
    BASE.mkdir(mode=0o700, exist_ok=True)
    if BASE.is_symlink() or BASE.stat().st_uid != 0 or stat.S_IMODE(BASE.stat().st_mode) != 0o700:
        raise RuntimeError('rotation state root is not private')
    directory = BASE / request['runId']
    with (BASE / 'rotation.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if request['action'] == 'Prepare':
            # Only one outstanding rotation may own the provisioned key.
            if any(path.is_dir() for path in BASE.iterdir()):
                raise RuntimeError('another rotation must be restored first')
            result = prepare(request, directory)
        elif request['action'] == 'Switch':
            result = switch(directory)
        else:
            result = restore(request, directory)
    print(json.dumps(result))


if __name__ == '__main__':
    main()
