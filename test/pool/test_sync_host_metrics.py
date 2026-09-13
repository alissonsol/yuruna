# Version: 2026.09.13
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
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    def test_reload_failure_restores_file_and_reloads_even_when_metrics_are_unavailable(self):
        with patch.object(module, "reload_state", side_effect=[(1, 10), OSError("unavailable")]), patch.object(module, "run"), patch.object(module, "reload_and_confirm", side_effect=[RuntimeError("rejected"), None]) as reload:
            with self.assertRaisesRegex(RuntimeError, "restored and reloaded"):
                module.synchronize(self.path, "new")
            self.assertEqual(reload.call_count, 2)
        self.assertEqual(self.path.read_text(), CONFIG)
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    def test_success_is_validated_and_acknowledged(self):
        with patch.object(module, "reload_state", return_value=(1, 10)), patch.object(module, "run") as run, patch.object(module, "reload_and_confirm") as reload:
            self.assertIn("UPDATED", module.synchronize(self.path, "new"))
            self.assertEqual(run.call_args.args[0][:3], ["promtool", "check", "config"])
            reload.assert_called_once()
        self.assertEqual(self.path.read_text(), CONFIG.replace("'old'", "'new'"))
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])


if __name__ == "__main__":
    unittest.main()
