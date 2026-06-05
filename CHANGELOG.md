# Changelog

Yuruna uses [Calendar Versioning](https://calver.org/): `YYYY.MM.DD`.
Tags are cut from the `main` branch; entries below summarize each
tagged release.

## 2026.06.05

- **Multi-registry login for component pushes.** Adds ECR, GAR, Docker Hub, and generic Docker login alongside azurecr; the registryLogin phase now shares the build/tag/push log capture.
- **Ctrl+C cleanup in Test-Sequence.** Interrupts now stop the VM cleanly instead of orphaning a half-baked guest; the disk is retained for post-mortem via virsh/vmconnect/utmctl.
- **Single-instance guard for dev entry points.** Test-Sequence and Test-Project refuse to start when an Invoke-TestRunner already owns `runner.pid`, avoiding pidfile/status.json races on the same runtime dir.
- **Shared cloud-init base + per-host overlays for Ubuntu Server.** Six drifting per-platform user-data files collapse to one base plus three overlays; orphan/undefined anchors throw at merge time so a typo can't ship a broken guest install.
- **Removed broken `test/Train-Screenshots.ps1`.** The trainer aborted at module-load after an earlier split; runtime screenshot testing stays via `Invoke-ScreenshotTest`.

## 2026.05.29

- **Self-healing reliability features.** Adds the runner state machine, snapshot manifest sidecars, and a remediation dispatcher.
- **Stash service.** New extension to receive SCP'd guest artifacts (diagnostic bundles, screenshots) into a host-side stash; PowerShell wrapper over a Go daemon.
- **Jittered backoff between retry attempts.** The `retry` verb no longer burns all attempts in milliseconds; it waits a jittered, capped delay and refreshes the heartbeat so the watchdog stays aligned.
- **Concurrent-write safety for `status.json`.** Atomic writers now use per-writer PID+GUID temp names so one process's rename can't clobber another's half-written temp.
- **Atomic `last_failure.json`.** Both normal and crash paths write through `Write-YurunaStateFile`, closing the window where a reader could see a truncated record.

## 2026.05.22

- **Username cascade + corporate identity mapping.** New `users.yml` maps logical sequence usernames onto corporate identities (AD/Entra) plus the vault keys holding their passwords.
- **`test/status/` reorganization (breaking layout change).** All harness runtime state moves under one tree with at most two subfolder levels before data.

## 2026.05.15

- **Initial release.** First release with working hosts and guests.

Back to [Yuruna](README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
