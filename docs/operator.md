# Yuruna operator guide

Bring-up runbook for a single Yuruna test machine: operating-system
baseline to a passing test cycle, plus the two service VMs a standalone
machine benefits from (caching proxy, stash service).

This guide assumes you operate **one machine**. To bring up a lab —
several machines sharing one caching proxy, NAS-backed storage, and
pool control — complete steps 1–4 here on each machine, then continue
with the [Lab operator guide](lab-operator.md).

The order is deliberate: each step validates the one before it, and
cheap checks run before expensive ones (config validation before the
caching-proxy VM build). Every step names the script it runs and links
the reference doc that owns the details.

---

## 1. Operating-system baseline (assumed)

A freshly installed Windows 11 Pro/Enterprise/Education (or Windows
Server), macOS 26+, or Ubuntu 26+ host. Tested baseline: 32 GB RAM,
512 GB free disk, 16+ physical cores ([requirements.md](requirements.md)).

## 2. Preflight dependencies

Before running the installer, confirm:

- **License / activation** — Windows must be activated and a
  Hyper-V-capable edition (Pro or above; Home has no Hyper-V).
- **OS updates applied** — pending updates can force a reboot mid-install.
- **Virtualization enabled in firmware** — Intel VT-x / AMD-V
  (Ubuntu: `grep -E 'vmx|svm' /proc/cpuinfo` must match).
- **Network access to github.com** — the installer clones the framework.

The installer re-checks the hardware baselines and prompts before
proceeding on an under-spec'd host.

## 3. Install the framework

Run the remote one-liner for the host OS (from
[install/README.md](../install/README.md), also linked at
<https://yuruna.link/install>):

Windows (PowerShell, self-elevates):

```
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows.hyper-v.ps1?nocache=$(Get-Date -Format yyyyMMddHHmmss)" | iex
```

macOS (Terminal):

```
/bin/bash -c "$(curl -fsSL "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/macos.utm.sh?nocache=$(date +%Y%m%d%H%M%S)")"
```

Ubuntu (Terminal):

```
bash <(curl -fsSL "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/ubuntu.kvm.sh?nocache=$(date +%Y%m%d%H%M%S)")
```

Alternatively `git clone` the repo and run the matching
`install/<host>.{ps1,sh}` yourself; for a signature-checked install or
to pin a release (disable auto-update), see
[install/README.md](../install/README.md). The clone lands in
`~/git/yuruna` (`%USERPROFILE%\git\yuruna` on Windows). **Reboot if the
installer says RESTART REQUIRED** (first-time Hyper-V enablement).

## 4. Create the Yuruna test user

```
pwsh test/New-LocalTestUser.ps1 -Admin
```

Elevated (Administrator / sudo). Creates a dedicated local OS account
(default name `yurunatest`) that owns test operation, so the harness
never runs under your personal profile. `-Admin` makes it a local
machine administrator — required, because the steps below elevate. The
password is asked for interactively on the elevated side (twice,
confirmed) and is immediately usable, so an unattended host can log in
without a first-login rotation standing in the way; add
`-ForcePasswordChange` if you want a one-shot initial credential
instead. The same account name is registered under the default Yuruna
authentication extension. Cross-platform (Windows / macOS / Ubuntu);
details are owned by `test/New-LocalTestUser.ps1` comment-based help.

Sign in as this user for everything that follows, so the per-host
config, vault, and runtime state it creates belong to the test account.

> **Single machine or lab?** From here on this guide is the
> single-machine path. For a lab, switch to the
> [Lab operator guide](lab-operator.md) now — it picks up exactly
> after this step.

## 5. Enable test automation

```
pwsh test/Enable-TestAutomation.ps1
```

Explicit opt-in that turns this machine into a test host: display
sleep, screen saver, screen lock, display scaling (Windows), TCC
grants (macOS). Elevated (Administrator / sudo); idempotent; supports
`-WhatIf`. On Windows, sign out and back in if it reports display-scaling
changes — OCR needs 100% scaling. Details are owned by
`host/<platform>/Enable-TestAutomation.ps1`.

## 6. Configure and validate

Edit `test/test.config.yml` (created from
`test/test.config.yml.template`; parameter reference:
[test-config.md](test-config.md)). Minimum for a first run:
`repositories.projectUrl` (and `GH_TOKEN` if private), `guestSequence`.
Then validate:

```
pwsh test/Test-Config.ps1
```

Checks the config and the `test/extension/*` configs, probes GitHub and
Resend reachability, and fires a smoke-test notification (`-SkipSend`
to validate only). Fix every FAIL before moving on — this takes seconds
and the next step takes many minutes.

## 7. Local shares for pool and stash storage

Durable storage ([pool-storage.md](pool-storage.md),
[stash-guide.md](stash-guide.md)) is backed by two SMB3 shares. On a
single machine both live here. Create the folders, the lab vault, and
the seeded intent repository in one idempotent step:

```
pwsh test/New-Lab.ps1 -Name <name> -Root D:\work
```

It generates one credential per share account into the lab vault
(plain YAML protected by filesystem permissions, so it stays copyable;
see `test/schemas/lab.vault.schema.yml`). Sharing the folders is left
to the operator — one dedicated account per share:

```powershell
# Elevated, Windows example
New-LocalUser yuruna-pool  -Password (Read-Host -AsSecureString 'yuruna-pool password')
New-LocalUser yuruna-stash -Password (Read-Host -AsSecureString 'yuruna-stash password')
New-SmbShare -Name yuruna.pool  -Path D:\work\yuruna.pool  -FullAccess yuruna-pool
New-SmbShare -Name yuruna.stash -Path D:\work\yuruna.stash -FullAccess yuruna-stash
icacls D:\work\yuruna.pool  /grant 'yuruna-pool:(OI)(CI)M'
icacls D:\work\yuruna.stash /grant 'yuruna-stash:(OI)(CI)M'
```

(Ubuntu/macOS: any Samba/SMB server with the same two share names and
accounts.) Then fill `networkStorage.*` in `test.config.yml`, put the
share passwords in the vault, and set `pool.networkReplicate: true` if
this host should archive cycles to the share — see
[test-config.md](test-config.md).

## 8. Start the caching proxy + dashboards

```
pwsh test/Start-CachingProxyVM.ps1
```

Builds the `yuruna-caching-proxy` VM and exposes ports 80 (CA cert),
3128/3129 (Squid), 3000 (Grafana), 9302 (metrics). Elevated on Windows;
macOS needs `sudo -E`. Set `vmStart.cachingProxyIP` in
`test.config.yml` to the proxy's IP so cycles find it. The cache VM
survives framework reinstalls. Details: [caching.md](caching.md#caching-proxy--test-harness-operator-reference).

## 9. Start the stash service

```
pwsh test/Start-StashVM.ps1
```

Brings up the `yuruna-stash-service` VM — the shared drop box for files
and snippets (web UI + scp). It mounts the `yuruna.stash` share from
step 7, so set that up first. No login; trusted networks only. User
guide: [stash-guide.md](stash-guide.md).

## 10. Run one test cycle

```
pwsh test/Test-Project.ps1
```

One-shot cycle: wipes `project/`, re-clones `repositories.projectUrl`,
runs a single cycle exactly as the runner would, and exits. Debug here
until green — one cycle with no loop around it is the cheapest place.

## 11. Run continuous cycles

```
pwsh test/Invoke-TestRunner.ps1
```

The resilient outer loop: pulls the framework, runs a cycle in a fresh
inner process, repeats; on failure it pauses until new commits land or
a timeout passes ([test-runner.md](test-runner.md)). It auto-starts the
status dashboard at `http://<host>:8080/` — no separate
`Start-StatusService.ps1` step needed.

---

## VM administrator accounts

Each service VM is seeded with its own administrator, and each password
lives under its own vault key:

| VM | Administrator |
| -- | ------------- |
| `yuruna-caching-proxy` | `caching-proxy-admin` |
| `yuruna-pool-control` | `pool-control-admin` |
| `yuruna-stash-service` | `stash-admin` |

(`yuruna-pool-control` appears when a lab builds the pool-control VM —
[lab-operator.md](lab-operator.md).) One account for all three would
mean one vault entry: building any VM would overwrite the password the
other two were provisioned with, and their console logins would stop
working with no visible cause.

A VM whose seed named a different administrator keeps that account and
that vault entry until it is rebuilt — the names above apply from the
next build of each VM. `Move-CachingProxy.ps1` talks to two cache VMs at
once, so pass `-OldUser` when the source VM's account differs from the
`caching-proxy-admin` default. Remove a superseded vault entry only after
every VM provisioned with it has been rebuilt.

`users.yml.template` declares all three. An existing
`status/extension/authentication/users.yml` is not re-bootstrapped from
the template (that happens only when the file is absent), so hosts running
`strict: true` need the three entries added by hand — see
[test-config.md](test-config.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.26

Back to [Yuruna](../README.md)
