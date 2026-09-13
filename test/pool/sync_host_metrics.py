#!/usr/bin/env python3
# Version: 2026.09.13
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Update only the pool-host metric filter; validate and roll back failed reloads.

See https://yuruna.link/429f3d06-0046. This helper is invoked by the host's
Sync-PoolHostMetricsOnProxy.ps1; it never installs packages or rebuilds the VM.
"""
import base64
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request


def update_filter(text, retention):
    """Preserve all other configuration and refuse ambiguous/nonstandard rules."""
    jobs = list(re.finditer(r"(?m)^( *)- job_name: ['\"]?pool-host['\"]?\s*$", text))
    if len(jobs) != 1:
        raise ValueError("Expected exactly one pool-host scrape job.")
    job = jobs[0]
    next_job = re.search(r"(?m)^" + re.escape(job[1]) + r"- job_name:", text[job.end():])
    end = job.end() + next_job.start() if next_job else len(text)
    section = text[job.start():end]
    rule = re.compile(r"(?m)^( *- source_labels: \[__name__\]\s*\n)( *regex: )[^\n]*(\n *action: keep\s*$)")
    if len(list(rule.finditer(section))) != 1:
        raise ValueError("Expected one canonical __name__ keep rule; custom rules require manual review.")
    changed = rule.sub(lambda m: m[1] + m[2] + "'" + retention.replace("'", "''") + "'" + m[3], section)
    return text[:job.start()] + changed + text[end:]


def reload_state(url):
    with urllib.request.urlopen(url, timeout=2) as response:
        data = response.read(4 * 1024 * 1024).decode()
    values = {}
    for name in ("prometheus_config_last_reload_successful", "prometheus_config_last_reload_success_timestamp_seconds"):
        match = re.search(r"(?m)^" + name + r"\s+([0-9.eE+-]+)\s*$", data)
        if not match:
            raise RuntimeError("Prometheus does not expose " + name)
        values[name] = float(match[1])
    return values["prometheus_config_last_reload_successful"], values["prometheus_config_last_reload_success_timestamp_seconds"]


def run(command):
    subprocess.run(command, check=True, timeout=15, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def reload_and_confirm(previous, systemctl, url):
    run([systemctl, "kill", "--kill-who=main", "--signal=HUP", "prometheus.service"])
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        success, stamp = reload_state(url)
        if success == 1 and stamp > previous:
            return
        time.sleep(0.5)
    raise RuntimeError("Prometheus did not acknowledge a successful reload within 20 seconds.")


def synchronize(path, retention, promtool="promtool", systemctl="systemctl", url="http://127.0.0.1:9090/metrics"):
    original = path.read_bytes()
    candidate = update_filter(original.decode(), retention).encode()
    if candidate == original:
        return "UNCHANGED: pool-host metric filter already matches."
    _, previous = reload_state(url)
    candidate_path = None
    backup_path = None
    replaced = False
    try:
        with tempfile.NamedTemporaryFile(prefix=".yuruna-candidate-", suffix=".yml", dir=path.parent, delete=False) as output:
            output.write(candidate)
            output.flush()
            os.fsync(output.fileno())
            candidate_path = Path(output.name)
        shutil.copystat(path, candidate_path)
        stat = path.stat()
        os.chown(candidate_path, stat.st_uid, stat.st_gid)
        run([promtool, "check", "config", str(candidate_path)])
        if path.read_bytes() != original:
            raise RuntimeError("Prometheus configuration changed during validation; refusing to overwrite it.")
        with tempfile.NamedTemporaryFile(prefix=".yuruna-backup-", suffix=".yml", dir=path.parent, delete=False) as backup:
            backup.write(original)
            backup.flush()
            os.fsync(backup.fileno())
            backup_path = Path(backup.name)
        shutil.copystat(path, backup_path)
        os.chown(backup_path, stat.st_uid, stat.st_gid)
        os.replace(candidate_path, path)
        replaced = True
        reload_and_confirm(previous, systemctl, url)
        backup_path.unlink()
        return "UPDATED: pool-host metric filter validated and reload acknowledged."
    except BaseException as error:
        if replaced and backup_path:
            os.replace(backup_path, path)
            try:
                try:
                    _, rollback_previous = reload_state(url)
                except Exception:
                    rollback_previous = previous
                reload_and_confirm(rollback_previous, systemctl, url)
            except BaseException as rollback:
                raise RuntimeError("Configuration restored, but rollback reload was not confirmed: " + str(rollback)) from error
            raise RuntimeError("Configuration restored and reloaded after update failure: " + str(error)) from error
        raise
    finally:
        if candidate_path and candidate_path.exists():
            candidate_path.unlink()
        if backup_path and backup_path.exists() and not replaced:
            backup_path.unlink()


def interrupted(signum, _frame):
    raise InterruptedError("Metric synchronization interrupted by signal " + str(signum))


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    try:
        rule = base64.b64decode(sys.argv[1], validate=True).decode()
        print(synchronize(Path("/etc/prometheus/prometheus.yml"), rule))
    except Exception as failure:
        print("FAILED: " + str(failure), file=sys.stderr)
        sys.exit(1)
