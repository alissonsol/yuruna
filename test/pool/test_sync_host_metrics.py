# Version: 2026.09.30
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Offline transaction tests; no Prometheus, SSH, or service is contacted."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("sync_metrics", Path(__file__).with_name("sync_host_metrics.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
CONFIG = """global:
  scrape_interval: 15s
scrape_configs:
  - job_name: pool-host
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: 'old'
        action: keep
  - job_name: other
    static_configs:
      - targets: ['localhost:9090']
"""


class MetricSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "prometheus.yml"
        self.path.write_text(CONFIG)

    def test_changes_only_filter_and_is_idempotent(self):
        changed = module.update_filter(CONFIG, "new|selected")
        self.assertEqual(changed, CONFIG.replace("'old'", "'new|selected'"))
        self.path.write_text(changed)
        with patch.object(module, "reload_state", side_effect=AssertionError("Must not contact service")):
            self.assertIn("UNCHANGED", module.synchronize(self.path, "new|selected"))

    def test_refuses_ambiguous_or_customized_configuration(self):
        for source in (CONFIG + CONFIG, CONFIG.replace("action: keep", "action: drop"), CONFIG.replace("job_name: pool-host", "job_name: other")):
            with self.assertRaises(ValueError):
                module.update_filter(source, "new")

    def test_validation_failure_never_replaces_config(self):
        with patch.object(module, "reload_state", return_value=(1, 10)), patch.object(module, "run", side_effect=subprocess.CalledProcessError(1, "promtool")):
            with self.assertRaises(subprocess.CalledProcessError):
                module.synchronize(self.path, "new")
        self.assertEqual(self.path.read_text(), CONFIG)
        self.assertEqual(set(self.path.parent.iterdir()), {self.path, self.path.with_name(self.path.name + ".yuruna.lock")})

    def test_reload_failure_restores_file_and_reloads_even_when_metrics_are_unavailable(self):
        with patch.object(module, "reload_state", side_effect=[(1, 10), OSError("unavailable")]), patch.object(module, "run"), patch.object(module, "reload_and_confirm", side_effect=[RuntimeError("rejected"), None]) as reload:
            with self.assertRaisesRegex(RuntimeError, "restored and reloaded"):
                module.synchronize(self.path, "new")
            self.assertEqual(reload.call_count, 2)
        self.assertEqual(self.path.read_text(), CONFIG)
        self.assertEqual(set(self.path.parent.iterdir()), {self.path, self.path.with_name(self.path.name + ".yuruna.lock")})

    def test_success_is_validated_and_acknowledged(self):
        with patch.object(module, "reload_state", return_value=(1, 10)), patch.object(module, "run") as run, patch.object(module, "reload_and_confirm") as reload:
            self.assertIn("UPDATED", module.synchronize(self.path, "new"))
            self.assertEqual(run.call_args.args[0][:3], ["promtool", "check", "config"])
            reload.assert_called_once()
        self.assertEqual(self.path.read_text(), CONFIG.replace("'old'", "'new'"))
        self.assertEqual(set(self.path.parent.iterdir()), {self.path, self.path.with_name(self.path.name + ".yuruna.lock")})



metrics = module
BASE = b"scrape_configs:\n  - job_name: pool-host\n    metric_relabel_configs:\n      - source_labels: [__name__]\n        regex: 'old'\n        action: keep\n"

class Synchronization(unittest.TestCase):

    def test_reload_conflict_preserves_foreign_bytes_and_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'prometheus.yml'
            path.write_bytes(BASE)

            def reload(*args):
                path.write_bytes(b'foreign edit\n')
                raise RuntimeError('reload failed')
            with patch.object(metrics, 'run'), patch.object(metrics, 'reload_state', return_value=(1, 1)), patch.object(metrics, 'reload_and_confirm', side_effect=reload):
                with self.assertRaisesRegex(RuntimeError, 'changed|conflict'):
                    metrics.synchronize(path, 'new')
            self.assertEqual(path.read_bytes(), b'foreign edit\n')
            self.assertEqual(next(Path(directory).glob('.yuruna-backup-*')).read_bytes(), BASE)

    def test_failed_reload_restores_owned_candidate(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'prometheus.yml'
            path.write_bytes(BASE)
            with patch.object(metrics, 'run'), patch.object(metrics, 'reload_state', return_value=(1, 1)), patch.object(metrics, 'reload_and_confirm', side_effect=[InterruptedError('cancelled'), None]):
                with self.assertRaisesRegex(RuntimeError, 'restored and reloaded'):
                    metrics.synchronize(path, 'new')
            self.assertEqual(path.read_bytes(), BASE)

    def test_validation_conflict_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'prometheus.yml'
            path.write_bytes(BASE)
            with patch.object(metrics, 'run', side_effect=lambda _: path.write_bytes(b'foreign')), patch.object(metrics, 'reload_state', return_value=(1, 1)):
                with self.assertRaisesRegex(RuntimeError, 'changed'):
                    metrics.synchronize(path, 'new')
            self.assertEqual(path.read_bytes(), b'foreign')

    def test_backup_cleanup_cannot_undo_acknowledged_update(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'prometheus.yml'
            path.write_bytes(BASE)
            unlink = Path.unlink

            def fail_backup(p, *a, **kw):
                if p.name.startswith('.yuruna-backup-'):
                    raise PermissionError('backup locked')
                return unlink(p, *a, **kw)
            with patch.object(metrics, 'run'), patch.object(metrics, 'reload_state', return_value=(1, 1)), patch.object(metrics, 'reload_and_confirm') as reload, patch.object(Path, 'unlink', fail_backup):
                self.assertTrue(metrics.synchronize(path, 'new').startswith('UPDATED'))
            self.assertEqual(reload.call_count, 1)
            self.assertIn(b"regex: 'new'", path.read_bytes())
if __name__ == '__main__':
    unittest.main()
