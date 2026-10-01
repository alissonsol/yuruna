# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Exercise the seeded installer error hook without a VM or network access."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
BASH = shutil.which('bash')
if not BASH and os.name == 'nt':
    candidate = Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / 'Git/bin/bash.exe'
    if candidate.is_file():
        BASH = str(candidate)

SOURCE = (ROOT / 'host/vmconfig/ubuntu.server.base.user-data').read_text(encoding='utf-8')
HOOK = textwrap.dedent(re.search(
    r'^  error-commands:\n    - \|\n((?:      [^\n]*\n|\n)+)', SOURCE, re.M
)[1])
PROBE = HOOK[HOOK.index('capture_probe() ('):HOOK.index('MOUNTSNAP=')]


@unittest.skipUnless(BASH, 'bash is required to execute the installer hook')
class InstallerFailureLogging(unittest.TestCase):
    def shell(self, source, timeout=15):
        result = subprocess.run(
            [BASH, '--noprofile', '--norc'], input=source, text=True,
            capture_output=True, timeout=timeout,
        )
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return result

    def test_hook_parses_as_posix_shell(self):
        result = subprocess.run([BASH, '--posix', '-n'], input=HOOK, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_probe_times_out_and_keeps_partial_evidence(self):
        result = self.shell(PROBE + '''
capture_probe blocked sh -c 'echo partial-evidence; sleep 30'
echo capture-continued
''')
        self.assertIn('partial-evidence', result.stdout)
        self.assertIn('exit=124;', result.stdout)
        self.assertIn('capture-continued', result.stdout)

    def test_missing_timeout_skips_probe(self):
        result = self.shell('''
command() {
    if [ "$1" = -v ] && [ "$2" = timeout ]; then return 1; fi
    builtin command "$@"
}
''' + PROBE + '\ncapture_probe skipped echo must-not-execute\n')
        self.assertIn('unavailable: timeout missing', result.stdout)
        self.assertNotIn('must-not-execute', result.stdout)

    def test_missing_optional_tool_is_visible(self):
        result = self.shell(PROBE + '\ncapture_probe optional yuruna-missing-probe-tool\n')
        self.assertIn('unavailable: yuruna-missing-probe-tool not installed', result.stdout)

    def test_probe_caps_output_without_losing_exit_status(self):
        result = self.shell(PROBE + '\ncapture_probe large sh -c "head -c 150000 /dev/zero; exit 7"\n')
        self.assertEqual(result.stdout.count('\0'), 131072)
        self.assertIn('output truncated at 131072 bytes', result.stdout)
        self.assertIn('exit=7;', result.stdout)

    def test_failure_hook_uploads_snapshot_after_failed_probes(self):
        # The native probes and HTTP transport are fixtures; the hook, output
        # limiting, exit recording, and uploaded file contents are production code.
        fixture = r'''
set -e
FIXTURE_DIR=$(mktemp -d)
export FIXTURE_DIR
trap 'rm -f "$FIXTURE_DIR/"*; rmdir "$FIXTURE_DIR"' EXIT
mktemp() { command mktemp "$FIXTURE_DIR/capture.XXXXXX"; }
hostname() { echo installer-fixture; }
command() {
    if [ "$1" = -v ]; then
        case "$2" in
            lsof) return 1 ;;
            findmnt|lsns|fuser) return 0 ;;
        esac
    fi
    builtin command "$@"
}
timeout() {
    shift 2
    echo "probe:$1" >> "$FIXTURE_DIR/order"
    case "$1" in
        cat) echo 'mount-id=42 /target/run' ;;
        sh) echo 'pid=77 reference=fd/3 path=/target/run/held'; echo 'mnt_id: 42' ;;
        ps) echo '77 1 S 10 wait fixture-holder' ;;
        findmnt) echo 'partial mount tree'; return 124 ;;
        lsns) echo 'permission denied'; return 1 ;;
        fuser) echo '77'; return 0 ;;
        *) return 2 ;;
    esac
}
ip() { echo 'fixture network'; }
grep() { return 1; }
curl() {
    local upload='' last=''
    while [ "$#" -gt 0 ]; do
        case "$1" in --upload-file) upload="$2"; shift ;; esac
        last="$1"
        shift
    done
    if [ -n "$upload" ]; then
        echo "upload:${last##*/}" >> "$FIXTURE_DIR/order"
        cp "$upload" "$FIXTURE_DIR/${last##*/}"
    else
        echo network >> "$FIXTURE_DIR/order"
        echo 'http=200'
    fi
}
(
'''
        checks = r'''
)
cat "$FIXTURE_DIR/mounts-at-failure.txt"
echo '== operation order =='
cat "$FIXTURE_DIR/order"
test -s "$FIXTURE_DIR/network-at-failure.txt"
'''
        result = self.shell(fixture + HOOK + checks)
        self.assertIn('path=/target/run/held', result.stdout)
        self.assertIn('mnt_id: 42', result.stdout)
        self.assertIn('exit=124;', result.stdout)
        self.assertIn('exit=1;', result.stdout)
        self.assertIn('unavailable: lsof not installed', result.stdout)
        order = result.stdout.split('== operation order ==\n')[1].splitlines()
        first_network = order.index('network')
        self.assertTrue(all(line.startswith('probe:') for line in order[:first_network]))
        self.assertEqual(sum(line.startswith('probe:') for line in order), first_network)
        self.assertLess(first_network, order.index('upload:mounts-at-failure.txt'))
        self.assertIn('upload:network-at-failure.txt', order)
        self.assertIn('Yuruna installer failure artifacts: /log/installer-fail/installer-fixture/', result.stderr)

    def test_process_references_include_holder_namespace_and_fd_mount_id(self):
        scan = re.search(r"sh -c '\n(.*?)\n    '\n", HOOK, re.S)[1]
        # A synthetic proc tree keeps the real scanner independent of the
        # test machine's processes. readlink stands in for Linux proc symlinks.
        fixture = r'''
set -e
FIXTURE_DIR=$(mktemp -d)
trap 'rm -f "$FIXTURE_DIR/77/fd/3" "$FIXTURE_DIR/77/fdinfo/3" "$FIXTURE_DIR/77/comm" "$FIXTURE_DIR/77/mountinfo"; rmdir "$FIXTURE_DIR/77/fd" "$FIXTURE_DIR/77/fdinfo" "$FIXTURE_DIR/77" "$FIXTURE_DIR"' EXIT
mkdir -p "$FIXTURE_DIR/77/fd" "$FIXTURE_DIR/77/fdinfo"
: > "$FIXTURE_DIR/77/fd/3"
printf 'mnt_id:\t42\n' > "$FIXTURE_DIR/77/fdinfo/3"
echo fixture-holder > "$FIXTURE_DIR/77/comm"
echo '42 1 0:5 / /run rw - tmpfs tmpfs rw' > "$FIXTURE_DIR/77/mountinfo"
readlink() {
    case "$1" in
        */root) echo /target ;;
        */cwd) echo /unrelated ;;
        */fd/3) echo '/target/run/held file' ;;
        */ns/mnt) echo 'mnt:[123]' ;;
        *) return 1 ;;
    esac
}
'''
        result = self.shell(fixture + scan.replace('/proc/[0-9]*', '"$FIXTURE_DIR"/[0-9]*'))
        self.assertIn('pid=77 comm=fixture-holder', result.stdout)
        self.assertIn('mount-namespace=mnt:[123]', result.stdout)
        self.assertIn('42 1 0:5 / /run rw', result.stdout)
        self.assertIn('reference=fd/3 path=/target/run/held file', result.stdout)
        self.assertIn('mnt_id:\t42', result.stdout)
        self.assertNotIn('/unrelated', result.stdout)
        self.assertEqual(result.stdout.count('mount-namespace='), 1)


if __name__ == '__main__':
    unittest.main()
