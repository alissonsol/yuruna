# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42dd8d91-dad4-4870-9614-185a0a314385
"""Exercise installer progress capture before the guest login exists."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
BASH = shutil.which('bash')
if not BASH and os.name == 'nt':
    candidate = Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / 'Git/bin/bash.exe'
    if candidate.is_file():
        BASH = str(candidate)


def seeded_capture():
    source = (ROOT / 'host/vmconfig/ubuntu.server.base.user-data').read_text(encoding='utf-8')
    match = re.search(
        r'^    # --- REGION: Installer progress evidence\n    - \|\n(.*?)^  # --- REGION: late-commands',
        source, re.M | re.S,
    )
    hook = textwrap.dedent(match[1]) if match else ''
    match = re.search(
        r"cat > /run/yuruna-installer-progress.sh << 'YURUNA_INSTALLER_PROGRESS'\n(.*?)\nYURUNA_INSTALLER_PROGRESS",
        hook, re.S,
    )
    return source, hook, match[1] if match else ''


@unittest.skipUnless(BASH, 'bash is required to execute the installer collector')
class InstallerProgressLogging(unittest.TestCase):
    def setUp(self):
        self.source, self.hook, self.collector = seeded_capture()
        self.assertTrue(self.collector, 'stalled installers need capture before late-commands or error-commands')
        self.temp = tempfile.TemporaryDirectory(prefix='yuruna-installer-progress-')
        self.addCleanup(self.temp.cleanup)
        self.fixture = Path(self.temp.name)
        self.env = {**os.environ, 'FIXTURE_DIR': self.fixture.as_posix()}

    def shell(self, script, timeout=15, expected=0):
        result = subprocess.run(
            [BASH, '--noprofile', '--norc'], input=script, text=True,
            capture_output=True, timeout=timeout, env=self.env,
        )
        self.assertEqual(result.returncode, expected, result.stderr + result.stdout)
        return result

    def fixture_collector(self, curl_exit=0):
        (self.fixture / 'instance-id').write_text('guest-fixture-01\n', encoding='utf-8')
        (self.fixture / 'subiquity-server-debug.log').write_text(
            'start: subiquity/Install/install/configure_apt/cmd-in-target\n'
            'apt worker still waiting\napt GH_TOKEN=must-stay-private\n'
            'apt fetch http://user:must-stay-private@archive.test/ubuntu\n'
            + 'finish: subiquity/Network/_send_update: CHANGE enp1s0\n' * 1000,
            encoding='utf-8',
        )
        process = self.fixture / 'proc/77'
        (process / 'fd').mkdir(parents=True)
        (process / 'comm').write_text('apt-get\n', encoding='utf-8')
        (process / 'wchan').write_text('wait_woken\n', encoding='utf-8')
        (process / 'stack').write_text('apt-fixture-stack\n', encoding='utf-8')
        collector = self.collector.replace(
            '/var/lib/cloud/data/instance-id', '"$FIXTURE_DIR/instance-id"',
        ).replace('/var/log/installer/', '"$FIXTURE_DIR"/').replace(
            '/proc/[0-9]*', '"$FIXTURE_DIR"/proc/[0-9]*',
        )
        prefix = r'''
mktemp() { command mktemp "$FIXTURE_DIR/capture.XXXXXX"; }
timeout() { shift 2; "$@"; }
ps() { echo '77 1 S 1671 wait_woken apt-get'; }
ss() { echo 'ESTAB 192.0.2.20:1234 192.0.2.10:3128'; }
ip() { echo 'fixture interface and default route'; }
journalctl() { echo 'networkd fixture DHCP lease renewed'; }
curl() {
    printf '%s\n' "$@" > "$FIXTURE_DIR/curl-args"
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --upload-file ]; then cp "$2" "$FIXTURE_DIR/upload.log"; fi
        shift
    done
    return CURL_EXIT
}
sleep() { exit 0; }
'''.replace('CURL_EXIT', str(curl_exit))
        return prefix + collector

    def probe(self):
        return self.collector[self.collector.index('capture_probe() {'):self.collector.index('capture_snapshot() {')]

    def test_stalled_apt_evidence_uploads_without_ssh(self):
        self.shell(self.fixture_collector())
        captured = (self.fixture / 'upload.log').read_text(encoding='utf-8')
        self.assertIn('configure_apt/cmd-in-target', captured)
        self.assertIn('1671 wait_woken apt-get', captured)
        self.assertIn('apt-fixture-stack', captured)
        self.assertIn('192.0.2.10:3128', captured)
        self.assertIn('DHCP lease renewed', captured)
        self.assertIn('vmName=guest-fixture-01', captured)
        self.assertIn('boot_id', captured)
        self.assertNotIn('must-stay-private', captured)
        self.assertIn('[redacted]', captured)
        self.assertLess(len(captured.encode()), 262144)

    def test_upload_bypasses_proxy_and_keeps_one_bounded_destination(self):
        self.shell(self.fixture_collector())
        arguments = (self.fixture / 'curl-args').read_text(encoding='utf-8').splitlines()
        self.assertIn('--noproxy', arguments)
        self.assertEqual(arguments[arguments.index('--noproxy') + 1], '*')
        self.assertEqual(arguments[arguments.index('--max-time') + 1], '10')
        self.assertTrue(arguments[-1].endswith('/log-upload/installer-progress/guest-fixture-01/latest.log'))

    def test_failed_upload_does_not_fail_or_stop_installer(self):
        result = self.shell(self.fixture_collector(curl_exit=22))
        self.assertEqual(result.returncode, 0)
        self.assertTrue((self.fixture / 'upload.log').is_file())

    def test_probe_timeout_preserves_partial_output_and_exit_status(self):
        result = self.shell('PROBE=$(mktemp)\n' + self.probe() + r'''
capture_probe stalled sh -c 'echo partial-apt-evidence; sleep 30'
rm -f "$PROBE"
echo capture-continued
''')
        self.assertIn('partial-apt-evidence', result.stdout)
        self.assertIn('exit=124', result.stdout)
        self.assertIn('capture-continued', result.stdout)

    def test_probe_output_is_bounded_and_records_native_failure(self):
        result = self.shell('PROBE=$(mktemp)\n' + self.probe() + r'''
capture_probe large sh -c 'head -c 150000 /dev/zero; exit 7'
printf 'status-bytes='; wc -c < "$PROBE"
rm -f "$PROBE"
''')
        self.assertEqual(result.stdout.count('\0'), 16384)
        self.assertIn('exit=7', result.stdout)
        self.assertIn('status-bytes=2', result.stdout)

    def test_missing_probe_tool_is_explicit(self):
        result = self.shell('PROBE=$(mktemp)\n' + self.probe() + '\ncapture_probe absent yuruna-missing-tool\nrm -f "$PROBE"\n')
        self.assertIn('unavailable: yuruna-missing-tool', result.stdout)

    def test_unknown_vm_identity_skips_upload_without_failure(self):
        script = self.fixture_collector()
        (self.fixture / 'instance-id').write_text('unsafe/name\n', encoding='utf-8')
        self.shell(script)
        self.assertFalse((self.fixture / 'curl-args').exists())

    def test_launch_failure_is_nonfatal_and_worker_lifetime_is_bounded(self):
        self.assertIn('RuntimeMaxSec=7200', self.hook)
        self.assertIn('TimeoutStopSec=5s', self.hook)
        for stream in ('StandardInput', 'StandardOutput', 'StandardError'):
            self.assertIn(f'{stream}=null', self.hook)
        launch = re.sub(
            r"cat > /run/yuruna-installer-progress.sh << 'YURUNA_INSTALLER_PROGRESS'\n.*?\nYURUNA_INSTALLER_PROGRESS",
            ':', self.hook, flags=re.S,
        )
        self.shell('set -e\nsystemd-run() { return 1; }\ntimeout() { shift 2; "$@"; }\n' + launch + '\necho install-continued\n')
        late = self.source.split('  late-commands:\n', 1)[1].split('    # --- REGION:', 1)[0]
        self.assertIn('systemctl stop yuruna-installer-progress.service', late)
        self.assertIn('|| true', late)

    def test_missing_capture_tool_does_not_block_install(self):
        prefix = r'''
set -e
command() {
    if [ "$1" = -v ] && [ "$2" = systemd-run ]; then return 1; fi
    builtin command "$@"
}
'''
        result = self.shell(prefix + self.hook + '\necho install-continued\n')
        self.assertIn('install-continued', result.stdout)

    def test_collector_does_not_read_process_arguments_or_guest_user_data(self):
        self.assertNotRegex(self.collector, r'/proc/[^\n]*(?:cmdline|environ)')
        self.assertNotRegex(self.collector, r'ps [^\n]*(?:args|command|cmd=)')
        self.assertNotIn('autoinstall-user-data', self.collector)
        self.assertNotIn('cloud-init-output.log', self.collector)

    def test_collector_and_launch_parse_as_posix_shell(self):
        for script in (self.collector, self.hook):
            result = subprocess.run([BASH, '--posix', '-n'], input=script, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
