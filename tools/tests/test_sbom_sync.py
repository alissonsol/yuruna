# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Exercise index isolation, backup retention, and failure recovery in SBOM maintenance."""
# --- REGION: Imports
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
spec = importlib.util.spec_from_file_location("sbom_sync", TOOLS / "Sync-Sbom.py")
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)

# --- REGION: Fixtures
class SbomSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.git("init", "-q")
        self.git("config", "user.name", "SBOM fixture")
        self.git("config", "user.email", "sbom@example.test")
        self.git("config", "core.autocrlf", "false")
        for name in sync.TOOL_FILES:
            self.write(name, (TOOLS / Path(name).name).read_bytes())
        self.write("LICENSE", "MIT License\n")
        self.write("VERSION", "1.0.0\n")
        self.write(sync.POLICY, json.dumps({"schema": "yuruna.sbom-policy/v1", "name": "fixture",
                    "source": "https://example.test/fixture", "creator": "Fixture", "creatorRegid": "example.test",
                    "created": "2026-10-03T00:00:00Z", "licenseId": "MIT", "licensePath": "LICENSE"}))
        self.write("package.json", json.dumps({"name": "fixture", "version": "1.0.0", "dependencies": {"sample": "1.0.0"}}))
        self.write("package-lock.json", json.dumps({"lockfileVersion": 3, "packages": {"": {"name": "fixture", "version": "1.0.0"}, "node_modules/sample": {"version": "1.0.0"}}}))
        self.git("add", "-A")

    def git(self, *args):
        result = subprocess.run(["git", "-C", str(self.root), *args], capture_output=True, check=True)
        return result.stdout

    def write(self, path, data):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data.encode() if isinstance(data, str) else data)

    def run_sync(self, *args):
        return sync.main(["--root", str(self.root), *args])

    def establish(self):
        self.assertEqual(0, self.run_sync("--staged", "--stage"))
        self.git("commit", "-qm", "Initial SBOM fixture")

    def current(self):
        return (self.root / "docs/sbom/repository.spdx.json").read_bytes()

    def enable_hook(self):
        self.write("tools/githooks/pre-commit", (TOOLS / "githooks/pre-commit").read_bytes().replace(b"\r\n", b"\n"))
        (self.root / "tools/githooks/pre-commit").chmod(0o755)
        self.git("add", "--chmod=+x", "tools/githooks/pre-commit")
        self.git("config", "core.hooksPath", "tools/githooks")

# --- REGION: Commit integration
    def test_shared_component_preserves_all_target_groups_and_constraints(self):
        records = sync.normalized([
            {"name": "node", "ecosystem": "nvm", "group": "ubuntu-24", "scope": "runtime", "versionConstraint": "24", "evidence": [{"path": "guest/24.sh"}]},
            {"name": "node", "ecosystem": "nvm", "group": "ubuntu-26", "scope": "build", "versionConstraint": "26", "evidence": [{"path": "guest/26.sh"}]},
        ])
        self.assertEqual(len(records), 1)
        record = records[0]
        self.assertEqual(record["groups"], ["ubuntu-24", "ubuntu-26"])
        self.assertEqual(record["versionConstraints"], ["24", "26"])
        self.assertEqual(record["scopes"], ["build", "runtime"])
        self.assertEqual(len(record["evidence"]), 2)
        self.assertNotIn("versionConstraint", record)
        self.assertEqual(json.loads(sync.record_note(record))["groups"], record["groups"])

    def test_real_hook_generates_stages_and_retains_previous_on_commit(self):
        self.enable_hook()
        self.git("commit", "-qm", "Initial hook-generated SBOM")
        original = self.current()
        self.assertEqual(original, self.git("show", "HEAD:docs/sbom/repository.spdx.json"))
        self.write("VERSION", "2.0.0\n")
        self.git("add", "VERSION")
        self.write("VERSION", "3.0.0\n")
        self.git("commit", "-qm", "Refresh staged source")
        document = json.loads(self.git("show", "HEAD:docs/sbom/repository.spdx.json"))
        self.assertEqual("2.0.0", document["packages"][0]["versionInfo"])
        self.assertEqual(original, self.git("show", "HEAD:docs/sbom/repository.spdx.json.previous"))
        self.assertEqual(b"3.0.0\n", (self.root / "VERSION").read_bytes())

    def test_path_commit_uses_its_alternate_index_and_preserves_other_staged_files(self):
        self.enable_hook()
        self.git("commit", "-qm", "Initial hook-generated SBOM")
        self.write("VERSION", "2.0.0\n")
        self.write("unrelated.txt", "Keep staged for another commit\n")
        self.git("add", "unrelated.txt")
        self.write("package.json", '{"dependencies":{"unstaged":"9.0.0"}}\n')
        self.git("commit", "-qm", "Commit only version", "--", "VERSION")
        inventory = json.loads(self.git("show", "HEAD:docs/sbom/inventory.json"))
        self.assertNotIn("unrelated.txt", inventory["sourceFiles"])
        self.assertNotIn("unstaged", {record["name"] for record in inventory["components"]["repository"]})
        self.assertIn(b"unrelated.txt", self.git("diff", "--cached", "--name-only"))
        self.assertEqual("2.0.0", json.loads(self.git("show", "HEAD:docs/sbom/repository.spdx.json"))["packages"][0]["versionInfo"])

# --- REGION: Exact committed inputs
    def test_staged_snapshot_ignores_unstaged_manifest_edit(self):
        self.establish()
        self.write("VERSION", "2.0.0\n")
        self.git("add", "VERSION")
        self.write("VERSION", "3.0.0\n")
        self.assertEqual(0, self.run_sync("--staged", "--stage"))
        document = json.loads(self.current())
        self.assertEqual("2.0.0", document["packages"][0]["versionInfo"])
        self.assertEqual(b"3.0.0\n", (self.root / "VERSION").read_bytes())
        self.assertEqual(b"2.0.0\n", self.git("show", ":VERSION"))
        self.assertEqual(0, self.run_sync("--staged", "--check"))

    def test_output_edit_is_protected_before_any_files_change(self):
        self.establish()
        self.write("VERSION", "2.0.0\n")
        self.git("add", "VERSION")
        self.write("docs/sbom/repository.spdx.json", "operator draft\n")
        before = self.git("diff", "--cached", "--binary")
        self.assertEqual(2, self.run_sync("--staged", "--stage"))
        self.assertEqual(b"operator draft\n", self.current())
        self.assertEqual(before, self.git("diff", "--cached", "--binary"))
        self.assertFalse((self.root / "docs/sbom/repository.spdx.json.previous").exists())

    def test_unstaged_generator_edit_refuses_wrong_code(self):
        self.establish()
        self.write("tools/Sync-Sbom.py", (TOOLS / "Sync-Sbom.py").read_bytes() + b"\n# unstaged change\n")
        self.assertEqual(2, self.run_sync("--staged", "--stage"))

# --- REGION: Prior version retention
    def test_previous_is_saved_and_unchanged_run_does_not_rotate_it(self):
        self.establish()
        original = self.current()
        self.write("VERSION", "2.0.0\n")
        self.git("add", "VERSION")
        self.assertEqual(0, self.run_sync("--staged", "--stage"))
        previous = self.root / "docs/sbom/repository.spdx.json.previous"
        self.assertEqual(original, previous.read_bytes())
        before = self.git("diff", "--cached", "--binary")
        self.assertEqual(0, self.run_sync("--staged", "--stage"))
        self.assertEqual(original, previous.read_bytes())
        self.assertEqual(before, self.git("diff", "--cached", "--binary"))

    def test_first_creation_does_not_invent_previous_version(self):
        self.assertEqual(0, self.run_sync("--staged", "--stage"))
        self.assertFalse(list((self.root / "docs/sbom").rglob("*.previous")))

    def test_staging_failure_restores_prior_files_and_index(self):
        self.establish()
        self.write("VERSION", "2.0.0\n")
        self.git("add", "VERSION")
        original = self.current()
        staged_before = self.git("diff", "--cached", "--binary")
        original_git = sync.git
        def fail_add(root, *args, **kwargs):
            if args[:2] == ("add", "-A"):
                raise RuntimeError("simulated staging failure")
            return original_git(root, *args, **kwargs)
        with patch.object(sync, "git", side_effect=fail_add):
            self.assertEqual(2, self.run_sync("--staged", "--stage"))
        self.assertEqual(original, self.current())
        self.assertEqual(staged_before, self.git("diff", "--cached", "--binary"))
        self.assertFalse(list((self.root / "docs/sbom").rglob("*.previous")))

    def test_retired_component_keeps_previous_and_stages_deletion(self):
        self.establish()
        tags = list((self.root / "docs/sbom/swid").glob("repository-*.swidtag"))
        selected = next(p for p in tags if b'name="sample"' in p.read_bytes())
        original = selected.read_bytes()
        self.write("package.json", '{"name":"fixture","version":"1.0.0"}\n')
        self.write("package-lock.json", '{"lockfileVersion":3,"packages":{}}\n')
        self.git("add", "package.json", "package-lock.json")
        self.assertEqual(0, self.run_sync("--staged", "--stage"))
        self.assertFalse(selected.exists())
        self.assertEqual(original, selected.with_name(selected.name + ".previous").read_bytes())
        status = self.git("diff", "--cached", "--no-renames", "--name-status").decode()
        self.assertIn("D\t" + selected.relative_to(self.root).as_posix(), status)

# --- REGION: Index identity revalidation
    def test_staging_reads_repository_blobs_only_once(self):
        with patch.object(sync, "git", wraps=sync.git) as calls:
            self.assertEqual(0, self.run_sync("--staged", "--stage"))
        batches = [call for call in calls.call_args_list if call.args[1:3] == ("cat-file", "--batch")]
        listings = [call for call in calls.call_args_list if call.args[1:4] == ("ls-files", "--stage", "-z")]
        self.assertEqual(1, len(batches))
        self.assertEqual(2, len(listings))

    def assert_concurrent_change_rejected(self, change):
        self.establish()
        original = self.current()
        self.write("VERSION", "2.0.0\n")
        self.git("add", "VERSION")
        generate = sync.generate
        def change_after_generation(files):
            result = generate(files)
            change()
            return result
        with patch.object(sync, "generate", side_effect=change_after_generation):
            self.assertEqual(2, self.run_sync("--staged", "--stage"))
        self.assertEqual(original, self.current())
        self.assertFalse((self.root / "docs/sbom/repository.spdx.json.previous").exists())
        self.assertEqual(original, self.git("show", ":docs/sbom/repository.spdx.json"))

    def test_concurrent_source_content_change_rolls_back_outputs(self):
        def change():
            self.write("VERSION", "3.0.0\n")
            self.git("add", "VERSION")
        self.assert_concurrent_change_rejected(change)

    def test_concurrent_source_addition_rolls_back_outputs(self):
        def change():
            self.write("new [source].txt", "new source\n")
            self.git("add", "new [source].txt")
        self.assert_concurrent_change_rejected(change)

    def test_concurrent_source_deletion_rolls_back_outputs(self):
        self.assert_concurrent_change_rejected(lambda: self.git("rm", "LICENSE"))

    def test_concurrent_source_rename_rolls_back_outputs(self):
        self.assert_concurrent_change_rejected(lambda: self.git("mv", "LICENSE", "renamed-license"))

    def test_concurrent_mode_change_rolls_back_outputs(self):
        self.assert_concurrent_change_rejected(lambda: self.git("update-index", "--chmod=+x", "VERSION"))

    def test_concurrent_index_conflict_rolls_back_outputs(self):
        def change():
            oid = self.git("rev-parse", ":VERSION").strip()
            subprocess.run(["git", "-C", str(self.root), "update-index", "--index-info"],
                           input=b"0 " + b"0" * 40 + b"\tVERSION\n100644 " + oid + b" 1\tVERSION\n",
                           check=True, capture_output=True)
        self.assert_concurrent_change_rejected(change)

    def test_alternate_index_revalidation_does_not_read_the_main_index(self):
        import os
        alternate = self.root / ".git/alternate-index"
        alternate.write_bytes((self.root / ".git/index").read_bytes())
        self.write("only-in-main.txt", "unrelated\n")
        self.git("add", "only-in-main.txt")
        with patch.dict(os.environ, {"GIT_INDEX_FILE": str(alternate)}):
            self.assertEqual(0, self.run_sync("--staged", "--stage"))
            inventory = json.loads(self.git("show", ":docs/sbom/inventory.json"))
            self.assertNotIn("only-in-main.txt", inventory["sourceFiles"])
        self.assertNotIn(b"docs/sbom/inventory.json", self.git("ls-files"))

    def test_source_identity_excludes_output_backups_but_includes_document_paths(self):
        self.write("docs/sbom/repository.spdx.json.previous", "large backup\n")
        self.write("docs/source [reference].md", "source document\n")
        self.git("add", "-A")
        files = sync.read_snapshot(self.root, staged=True)
        paths = {path for path, _, _ in files.source_index}
        self.assertNotIn("docs/sbom/repository.spdx.json.previous", paths)
        self.assertIn("docs/source [reference].md", paths)
        self.assertEqual(b"large backup\n", files["docs/sbom/repository.spdx.json.previous"])

# --- REGION: Portable reproducibility
    def test_text_crlf_matches_lf_without_altering_binary_bytes(self):
        self.establish()
        lf = sync.generate(sync.read_snapshot(self.root, staged=True))
        for name in sync.TOOL_FILES:
            self.write(name, (self.root / name).read_bytes().replace(b"\n", b"\r\n"))
        self.assertEqual(0, self.run_sync("--staged", "--check"))
        self.assertEqual(lf, sync.generate(sync.read_snapshot(self.root)))
        self.assertEqual(b"binary\0\r\n", sync.canonical_bytes(b"binary\0\r\n"))

    def test_all_standard_relationships_and_xml_links_resolve(self):
        result = sync.generate(sync.read_snapshot(self.root, staged=True))
        sync.validate_outputs(result)
        self.assertEqual(3, len([n for n in result if n.endswith(".spdx.json")]))
        self.assertEqual(3, len([n for n in result if n.endswith(".cdx.json")]))
        damaged = dict(result)
        component_path = next(n for n in result if "/swid/" in n)
        del damaged[component_path]
        with self.assertRaisesRegex(RuntimeError, "SWID component link"):
            sync.validate_outputs(damaged)


if __name__ == "__main__":
    unittest.main()
