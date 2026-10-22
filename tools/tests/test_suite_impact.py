"""Recorded-pass regressions for tools/suite_impact.py.

LICENSEURI https://yuruna.link/license
Copyright (c) 2019-2026 by Alisson Sol et al.
"""

import gzip
import importlib.util
import io
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from contextlib import redirect_stdout

MODULE_PATH = pathlib.Path(__file__).resolve().parents[1] / "suite_impact.py"
SPEC = importlib.util.spec_from_file_location("suite_impact", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

# The recorder traces with strace, so its paths, FIFOs and descriptors are
# Linux ones; elsewhere every case is skipped and the runner records nothing.
ONLY_LINUX = unittest.skipUnless(sys.platform.startswith("linux"), "the recorder runs only on Linux")


def _traced():
    try:
        with open("/proc/self/status", encoding="ascii") as stream:
            return any(line.startswith("TracerPid:") and line.split()[1] != "0" for line in stream)
    except OSError:
        return False


def read(lines, ignored=(), zones=()):
    reader = MODULE.TraceReader(ignored, zones)
    for line in textwrap.dedent(lines).strip().splitlines():
        reader.feed(line)
    return reader


# --- REGION: Trace parsing
@ONLY_LINUX
class TraceReaderTests(unittest.TestCase):
    def test_a_descriptor_annotation_resolves_a_relative_path(self):
        reader = read('''
            10 openat(AT_FDCWD</work/repo>, "docs/a.md", O_RDONLY|O_CLOEXEC) = 3</work/repo/docs/a.md>
            10 newfstatat(5</work/repo/tools>, "x.ps1", 0x7ff, 0) = -1 ENOENT (No such file or directory)
        ''')
        self.assertEqual(reader.paths["/work/repo/docs/a.md"], MODULE.READ)
        self.assertEqual(reader.paths["/work/repo/tools/x.ps1"], MODULE.OBSERVE)

    def test_a_bare_relative_path_uses_the_working_directory_the_process_last_showed(self):
        reader = read('''
            10 newfstatat(AT_FDCWD</work/repo>, ".", {st_mode=S_IFDIR|0775}, 0) = 0
            10 stat("test/x.ps1", 0x7ff) = -1 ENOENT (No such file or directory)
            10 chdir("docs") = 0
            10 lstat("../README.md", {st_mode=S_IFREG|0664}) = 0
        ''')
        self.assertIn("/work/repo/test/x.ps1", reader.paths)
        self.assertIn("/work/repo/README.md", reader.paths)
        self.assertEqual(reader.unresolved, 0)

    def test_a_thread_shares_its_creators_directory_and_a_child_copies_it(self):
        reader = read('''
            10 newfstatat(AT_FDCWD</a>, ".", 0x1, 0) = 0
            10 clone3({flags=CLONE_VM|CLONE_FS|CLONE_FILES|CLONE_THREAD, exit_signal=0}, 88) = 11
            10 vfork( <unfinished ...>
            10 <... vfork resumed>) = 12
            11 chdir("/b") = 0
            10 stat("shared", 0x1) = 0
            12 stat("copied", 0x1) = 0
        ''')
        self.assertIn("/b/shared", reader.paths)
        self.assertIn("/a/copied", reader.paths)

    def test_an_unfinished_call_is_joined_with_its_resumption(self):
        reader = read('''
            10 openat(AT_FDCWD</r>, "slow.txt", O_RDONLY <unfinished ...>
            11 stat("/r/other", 0x1) = 0
            10 <... openat resumed>) = 4</r/slow.txt>
        ''')
        self.assertEqual(reader.paths["/r/slow.txt"], MODULE.READ)

    def test_opening_for_writing_is_a_write_and_a_failed_write_is_a_probe(self):
        reader = read('''
            10 openat(AT_FDCWD</r>, "out.log", O_WRONLY|O_CREAT|O_TRUNC, 0644) = 3</r/out.log>
            10 openat(AT_FDCWD</r>, "locked", O_RDWR|O_CREAT|O_EXCL, 0644) = -1 EEXIST (File exists)
            10 mkdir("/r/made", 0777) = 0
            10 renameat2(AT_FDCWD</r>, "a.tmp", AT_FDCWD</r>, "a", RENAME_NOREPLACE) = 0
        ''')
        self.assertEqual(reader.paths["/r/out.log"], MODULE.WRITE)
        self.assertEqual(reader.paths["/r/locked"], MODULE.OBSERVE)
        self.assertEqual(reader.paths["/r/made"], MODULE.WRITE)
        self.assertEqual(reader.paths["/r/a.tmp"], MODULE.WRITE)
        self.assertEqual(reader.paths["/r/a"], MODULE.WRITE)
        self.assertEqual(reader.mutated, set())

    def test_changing_a_path_after_reading_it_is_a_mutation(self):
        reader = read('''
            10 openat(AT_FDCWD</r>, "state.json", O_RDONLY) = 3</r/state.json>
            10 openat(AT_FDCWD</r>, "state.json", O_WRONLY|O_TRUNC) = 3</r/state.json>
        ''')
        self.assertEqual(reader.mutated, {"/r/state.json"})

    def test_a_listing_is_kept_for_the_directory_the_descriptor_names(self):
        reader = read('''
            10 getdents64(7</r/test/modules>, 0x55 /* 12 entries */, 32768) = 480
        ''')
        self.assertEqual(reader.paths["/r/test/modules"], MODULE.LIST)

    def test_an_ignored_directory_wins_over_the_workspace_and_the_workspace_over_the_defaults(self):
        reader = read('''
            10 openat(AT_FDCWD</>, "/tmp/ws/input", O_RDONLY) = 3</tmp/ws/input>
            10 openat(AT_FDCWD</>, "/tmp/ws/.test-results/x", O_RDONLY) = 3</tmp/ws/.test-results/x>
            10 openat(AT_FDCWD</>, "/tmp/other", O_RDONLY) = 3</tmp/other>
            10 openat(AT_FDCWD</>, "/proc/self/maps", O_RDONLY) = 3</proc/self/maps>
        ''', ignored=["/tmp/ws/.test-results"], zones=["/tmp/ws"])
        self.assertEqual(sorted(reader.paths), ["/tmp/ws/input"])

    def test_python_byte_code_caches_are_not_inputs(self):
        reader = read('''
            10 openat(AT_FDCWD</ws>, "tools/__pycache__/x.cpython-313.pyc", O_RDONLY) = 3</x>
            10 openat(AT_FDCWD</ws>, "tools/__pycache__/x.cpython-313.pyc", O_WRONLY|O_CREAT|O_TRUNC, 0644) = 3</x>
            10 openat(AT_FDCWD</ws>, "tools/x.py", O_RDONLY) = 3</ws/tools/x.py>
        ''', zones=["/ws"])
        self.assertEqual(sorted(reader.paths), ["/ws/tools/x.py"])
        self.assertEqual(reader.mutated, set())

    def test_a_workspace_listing_is_taken_when_the_suite_lists_it(self):
        listed = []
        reader = MODULE.TraceReader((), ["/ws"], on_list=listed.append)
        for line in ('10 getdents64(3</ws/docs>, 0x1 /* 4 entries */, 32768) = 96',
                     '10 getdents64(3</ws/docs>, 0x1 /* 0 entries */, 32768) = 0',
                     '10 getdents64(4</usr/bin>, 0x1 /* 9 entries */, 32768) = 216'):
            reader.feed(line)
        self.assertEqual(listed, ["/ws/docs"])

    def test_a_quoted_byte_is_decoded(self):
        reader = read(r'''
            10 openat(AT_FDCWD</r>, "caf\303\251.md", O_RDONLY) = 3</r/caf\303\251.md>
        ''')
        self.assertIn("/r/caf\u00e9.md", reader.paths)

    def test_the_first_process_exit_line_is_the_suite_status(self):
        self.assertEqual(read('''
            10 execve("/usr/bin/pwsh", ["pwsh"], 0x1 /* 9 vars */) = 0
            11 +++ exited with 9 +++
            10 +++ exited with 3 +++
        ''').main_exit, 3)
        self.assertEqual(read('''
            10 execve("/usr/bin/pwsh", ["pwsh"], 0x1 /* 9 vars */) = 0
            10 +++ killed by SIGKILL +++
        ''').main_exit, 137)

    def test_a_relative_path_without_a_known_directory_is_counted(self):
        reader = read('''
            10 stat("nowhere", 0x1) = 0
        ''')
        self.assertEqual(reader.unresolved, 1)
        self.assertEqual(reader.paths, {})


# --- REGION: Fingerprints and records
@ONLY_LINUX
class FingerprintTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="impact-test-")
        self.zone = os.path.join(self.root, "ws")
        self.outside = os.path.join(self.root, "sys")
        os.makedirs(os.path.join(self.zone, "docs"))
        os.makedirs(os.path.join(self.outside, "bin"))
        self.write(os.path.join(self.zone, "docs", "a.md"), "alpha")
        self.write(os.path.join(self.outside, "bin", "tool"), "#!/bin/sh\n")
        self.cache = os.path.join(self.root, "cache")
        self.started = time.time_ns()
        time.sleep(0.01)

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    @staticmethod
    def write(path, text):
        with open(path, "w", encoding="utf-8") as stream:
            stream.write(text)

    def observe(self, paths, mutated=()):
        return MODULE.fingerprint(dict(paths), set(mutated), [self.zone], self.started, {})

    def commit(self, paths, context="ctx"):
        inputs, reasons = self.observe(paths)
        candidate = os.path.join(self.root, "observations.json")
        with open(candidate, "w", encoding="utf-8") as stream:
            json.dump({"schema": MODULE.SCHEMA, "inputs": inputs, "unreusable": reasons}, stream)
        xml = os.path.join(self.root, "nunit.xml")
        self.write(xml, "<test-results total=\"1\" />")
        with redirect_stdout(io.StringIO()) as answer:
            MODULE.main(["commit", "--candidate", candidate, "--cache", self.cache, "--suite", "test/A.Tests.ps1",
                         "--context", context, "--xml", xml, "--total", "1", "--skipped", "0", "--seconds", "2.5"])
        return json.loads(answer.getvalue())

    def test_a_workspace_file_is_keyed_by_content_not_by_time(self):
        path = os.path.join(self.zone, "docs", "a.md")
        self.started = time.time_ns() + 10**12
        before, _ = self.observe({path: MODULE.READ})
        os.utime(path, ns=(1, 1))
        same, _ = MODULE.fingerprint({path: MODULE.READ}, set(), [self.zone], self.started, {}, MODULE.Fingerprints())
        self.write(path, "beta")
        after, _ = MODULE.fingerprint({path: MODULE.READ}, set(), [self.zone], self.started, {}, MODULE.Fingerprints())
        self.assertEqual(before, same)
        self.assertNotEqual(before, after)

    def test_an_input_changed_during_the_run_cannot_be_reused(self):
        path = os.path.join(self.zone, "docs", "a.md")
        self.write(path, "changed while the suite ran")
        _, reasons = self.observe({path: MODULE.READ})
        self.assertTrue(any("changed during the run" in reason for reason in reasons), reasons)

    def test_a_workspace_root_with_a_transient_entry_still_holds(self):
        # Another suite's probe file came and went in the root while this one ran.
        listing = MODULE.Fingerprints().value("l", self.zone)[0]
        probe = os.path.join(self.zone, "probe.tmp")
        self.write(probe, "")
        os.unlink(probe)
        _, reasons = MODULE.fingerprint({self.zone: MODULE.LIST}, set(), [self.zone], self.started, {},
                                        listing_baseline={self.zone: listing})
        self.assertEqual(reasons, [])
        self.write(probe, "kept")
        _, reasons = MODULE.fingerprint({self.zone: MODULE.LIST}, set(), [self.zone], self.started, {},
                                        MODULE.Fingerprints(), listing_baseline={self.zone: listing})
        self.assertEqual(reasons, ["an input changed during the run: " + self.zone])

    def test_a_suite_that_changes_a_path_it_read_cannot_be_reused(self):
        path = os.path.join(self.zone, "docs", "a.md")
        _, reasons = self.observe({path: MODULE.READ | MODULE.WRITE}, mutated=[path])
        self.assertIn("changed a path it had read: " + path, reasons)

    def test_a_probe_in_a_listed_directory_outside_the_workspace_needs_no_entry(self):
        listed = os.path.join(self.outside, "bin")
        os.utime(listed, ns=(1, 1))
        inputs, reasons = self.observe({listed: MODULE.LIST, os.path.join(listed, "tool"): MODULE.OBSERVE,
                                        os.path.join(self.outside, "elsewhere"): MODULE.OBSERVE})
        self.assertEqual(reasons, [])
        self.assertEqual([(cls, path) for cls, path, _ in inputs],
                         [("l", listed), ("O", os.path.join(self.outside, "elsewhere"))])

    def test_a_listing_outside_the_workspace_is_keyed_by_names_not_by_time(self):
        listed = os.path.join(self.outside, "bin")
        first, reasons = self.observe({listed: MODULE.LIST})
        self.write(os.path.join(listed, "tool"), "replaced in place\n")
        second, _ = MODULE.fingerprint({listed: MODULE.LIST}, set(), [self.zone], self.started, {}, MODULE.Fingerprints())
        self.assertEqual(reasons, [])
        self.assertEqual(first, second)

    def test_a_recorded_pass_holds_until_an_input_or_the_context_changes(self):
        path = os.path.join(self.zone, "docs", "a.md")
        missing = os.path.join(self.zone, "docs", "b.md")
        os.utime(path, ns=(1, 1))
        # Setting a time changes the inode's change time, which dates the state.
        self.started = time.time_ns() + 1
        self.assertTrue(self.commit({path: MODULE.READ, missing: MODULE.OBSERVE})["recorded"])
        hit = MODULE.check(self.cache, ["test/A.Tests.ps1"], "ctx")["test/A.Tests.ps1"]
        self.assertTrue(hit["hit"])
        self.assertEqual((hit["total"], hit["skipped"], hit["nunit"]), (1, 0, "<test-results total=\"1\" />"))
        self.assertFalse(MODULE.check(self.cache, ["test/A.Tests.ps1"], "other")["test/A.Tests.ps1"]["hit"])
        self.write(missing, "now present")
        answer = MODULE.check(self.cache, ["test/A.Tests.ps1"], "ctx")["test/A.Tests.ps1"]
        self.assertEqual(answer, {"hit": False, "reason": "input changed: " + missing})
        self.assertEqual(MODULE.check(self.cache, ["test/B.Tests.ps1"], "ctx")["test/B.Tests.ps1"]["reason"], "no recorded pass")

    def test_an_unreusable_run_is_not_recorded(self):
        path = os.path.join(self.zone, "docs", "a.md")
        self.write(path, "changed while the suite ran")
        answer = self.commit({path: MODULE.READ})
        self.assertFalse(answer["recorded"])
        self.assertIn("changed during the run", answer["reason"])
        self.assertFalse(os.path.exists(MODULE.record_path(self.cache, "test/A.Tests.ps1")))

    def test_an_unreadable_record_is_a_miss(self):
        record = MODULE.record_path(self.cache, "test/A.Tests.ps1")
        os.makedirs(os.path.dirname(record))
        with open(record, "wb") as stream:
            stream.write(b"not gzip")
        self.assertEqual(MODULE.check(self.cache, ["test/A.Tests.ps1"], "ctx")["test/A.Tests.ps1"],
                         {"hit": False, "reason": "the record is unreadable"})

    @unittest.skipIf(shutil.which("git") is None, "git is not installed")
    def test_a_git_index_is_keyed_by_what_it_stages(self):
        repo = os.path.join(self.zone, "repo")
        os.makedirs(repo)
        subprocess.run(["git", "init", "-q", repo], check=True)
        self.write(os.path.join(repo, "f.txt"), "one")
        subprocess.run(["git", "-C", repo, "add", "f.txt"], check=True)
        index = os.path.join(repo, ".git", "index")
        staged = MODULE.git_index_digest(index)
        os.utime(os.path.join(repo, "f.txt"), ns=(5, 5))
        subprocess.run(["git", "-C", repo, "update-index", "--really-refresh"], check=False, capture_output=True)
        self.assertEqual(MODULE.git_index_digest(index), staged)
        self.write(os.path.join(repo, "f.txt"), "two")
        subprocess.run(["git", "-C", repo, "add", "f.txt"], check=True)
        self.assertNotEqual(MODULE.git_index_digest(index), staged)


# --- REGION: Tracing through a stand-in strace
FAKE_STRACE = r'''
import os, subprocess, sys, time
args = sys.argv[1:]
out = args[args.index("-o") + 1]
command = args[args.index("--") + 1:]
lines = ['100 execve("%s", ["x"], 0x1 /* 1 vars */) = 0' % command[0]]
for path in os.environ.get("FAKE_READS", "").split(os.pathsep):
    if path:
        lines.append('100 openat(AT_FDCWD</>, "%s", O_RDONLY) = 3</x>' % path)
code = subprocess.call(command)
with open(out, "w") as stream:
    stream.write("\n".join(lines + ["100 +++ exited with %d +++" % code]) + "\n")
    stream.flush()
    if os.environ.get("FAKE_LINGER"):
        time.sleep(60)
sys.exit(code)
'''


@ONLY_LINUX
class RunTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="impact-run-")
        self.zone = os.path.join(self.root, "ws")
        os.makedirs(self.zone)
        self.input = os.path.join(self.zone, "input.txt")
        with open(self.input, "w", encoding="utf-8") as stream:
            stream.write("data")
        os.utime(self.input, ns=(1, 1))
        self.fake = os.path.join(self.root, "fake-strace")
        with open(self.fake, "w", encoding="utf-8") as stream:
            stream.write("#!" + sys.executable + "\n" + FAKE_STRACE)
        os.chmod(self.fake, 0o755)
        self.out = os.path.join(self.root, "observations.json")
        self.saved = dict(os.environ)
        os.environ["FAKE_READS"] = self.input

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.saved)
        shutil.rmtree(self.root, ignore_errors=True)

    def run_traced(self, *command):
        return MODULE.main(["run", "--strace", self.fake, "--out", self.out, "--zone", self.zone, "--"] + list(command))

    def test_the_suite_exit_code_and_its_reads_come_back(self):
        code = self.run_traced(sys.executable, "-c", "raise SystemExit(4)")
        with open(self.out, encoding="utf-8") as stream:
            observed = json.load(stream)
        self.assertEqual(code, 4)
        self.assertEqual(observed["unreusable"], [])
        self.assertIn(["o", self.input, observed["inputs"][[row[1] for row in observed["inputs"]].index(self.input)][2]],
                      observed["inputs"])

    def test_strace_is_detached_from_processes_that_outlive_the_suite(self):
        os.environ["FAKE_LINGER"] = "1"
        saved = MODULE.LINGER_SECONDS
        MODULE.LINGER_SECONDS = 0.5
        try:
            started = time.monotonic()
            code = self.run_traced(sys.executable, "-c", "raise SystemExit(0)")
        finally:
            MODULE.LINGER_SECONDS = saved
        self.assertEqual(code, 0)
        self.assertLess(time.monotonic() - started, 30)
        self.assertTrue(os.path.exists(self.out))


# One process tree cannot be traced twice: under a recording run this case
# would trace a process that is already traced.
@ONLY_LINUX
@unittest.skipUnless(os.environ.get("YURUNA_STRACE") or shutil.which("strace"), "strace is not available")
@unittest.skipIf(_traced(), "this process is already traced")
class RealStraceTests(unittest.TestCase):
    """What the real strace reports for reads, probes and listings."""

    def test_reads_probes_and_listings_of_a_shell_are_recorded(self):
        strace = os.environ.get("YURUNA_STRACE") or shutil.which("strace")
        root = tempfile.mkdtemp(prefix="impact-strace-")
        try:
            zone = os.path.join(root, "ws")
            os.makedirs(os.path.join(zone, "docs"))
            with open(os.path.join(zone, "docs", "a.md"), "w", encoding="utf-8") as stream:
                stream.write("alpha")
            os.utime(os.path.join(zone, "docs", "a.md"), ns=(1, 1))
            os.utime(os.path.join(zone, "docs"), ns=(1, 1))
            out = os.path.join(root, "observations.json")
            script = "cd docs && cat a.md >/dev/null && test -e b.md; ls >/dev/null; exit 0"
            code = subprocess.run([sys.executable, str(MODULE_PATH), "run", "--strace", strace, "--out", out, "--zone", zone,
                                   "--", "/bin/sh", "-c", script], cwd=zone, check=False).returncode
            with open(out, encoding="utf-8") as stream:
                observed = json.load(stream)
            classes = {(cls, path) for cls, path, _ in observed["inputs"]}
            self.assertEqual(code, 0)
            self.assertIn(("o", os.path.join(zone, "docs", "a.md")), classes)
            self.assertIn(("o", os.path.join(zone, "docs", "b.md")), classes)
            self.assertIn(("l", os.path.join(zone, "docs")), classes)
            values = {path: value for cls, path, value in observed["inputs"] if cls == "o"}
            self.assertEqual(values[os.path.join(zone, "docs", "b.md")], "absent")
        finally:
            shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
