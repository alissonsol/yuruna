# Pool control service

The Pool control service is the operator UI + API for the LAN pool intent (F3). It
serves three pages and drives the pool-intent git store; runners only PULL that
store read-only.

## What it does

- **Assign** (`/`) &mdash; assign a test-set (a framework/project repo pair) to each
  pool; show members and the copy-config-from-a-peer command.
- **Pools** (`/pools`) &mdash; create a pool (mints its stable `poolGuid`, the
  dashboard "Pool ID"), set desiredState (run/paused/drain), add/remove hosts (a
  host belongs to at most one pool), delete an empty pool.
- **Test sets** (`/test-sets`) &mdash; CRUD the named-triple library
  (`test-sets.yml`). GH_TOKEN is **never** stored here &mdash; it stays host-local.

Assigning copies the chosen library triple into the pool's inline `testSet`; a
pooled runner then overrides its `repositories.frameworkUrl`/`projectUrl` with it
for the cycle and runs the assigned project's own `test.runner.yml`.

## Architecture

A small Go daemon (`test/extension/pool-control/server`, module `pool-control`) that:

- Serves the embedded static pages + a JSON API (`/api/state`, `/api/pool`,
  `/api/pool/testset`, `/api/testset`, ...). Strict page CSP; XSS-safe DOM.
- **Shells out to the PowerShell pool-admin CLIs** (`New-Pool.ps1`,
  `Set-PoolTestSet.ps1`, `Add-HostToPool.ps1`, `Remove-Pool.ps1`,
  `Set-PoolTestSetDefinition.ps1`, `Get-PoolIntent.ps1`) rather than reimplementing
  git + YAML + schema validation + commit/push in Go &mdash; one authoritative
  implementation. A failed push surfaces to the UI as an error (never a silent
  success).
- **Self-announces** to the pool aggregator (beacon, area `pool-control`) and, via
  the `runtime/pool-control.json` marker + `host.registration.json`, appears in the
  Extension hosts table (shown as "Pool control"). Either path alone paints the row.
- Persists an **audit log** (`audit.jsonl`) + **status.json** (last write,
  last-publish outcome, heartbeat, intent-readable, health) under
  `poolNetworkPath/pool-control/` (the pool NAS), surviving restarts. `/healthz`
  serves that status. A monitor loop probes the intent every `--monitor-interval`.

## Running it

**Default &mdash; on its own VM:**

```powershell
pwsh test/Start-PoolControlVM.ps1 [-VMName yuruna-pool-control]
# stop (and tear down the VM) with test/Stop-PoolControlVM.ps1
```

Like Start-CachingProxyVM / Start-StashVM, this brings the service up on a
dedicated VM. `host/vmconfig/pool-control.base.user-data` seeds an Ubuntu guest
that builds the daemon, installs pwsh + `powershell-yaml`, CIFS-mounts the pool NAS
for the state dir, and runs it under systemd (`guest/ubuntu.server.26/ubuntu.server.26.pool-control.sh`).
The per-hypervisor `guest.pool-control/New-VM.ps1` (mirroring the stash VM chain)
generates the seed with `/etc/yuruna/{pool.env,host.env,pool-nas.cifs.cred}` and a
distinct guest username. **No `go` toolchain is needed on the host** &mdash; the
daemon is built inside the guest. The Extension-hosts row then points at the VM
(beacon self-IP); deleting the VM clears it after the announce TTL.

After the VM boots, the launcher waits for the daemon to actually serve on `:80`
(up to 15 min; override with `YURUNA_POOL_CONTROL_READY_TIMEOUT=<seconds>`) before
reporting success &mdash; an IP alone is not "up", since the guest still has to
build the daemon. If `:80` never comes up, it pulls the in-guest build log,
`cloud-init status`, and the `pool-control.service` journal over the harness SSH
key and prints them, so a failed build shows you the reason instead of a dead URL.
(That log is root-only; the harness `yuruna` account has NOPASSWD `sudo`, so
`sudo tail /var/log/cloud-init-output.log` reads it &mdash; a plain `tail` returns
`Permission denied`.)

**Host-side (proof / fallback):**

```powershell
pwsh test/Start-PoolControlVM.ps1 -HostSideProof [-Port 8090] [-AggregatorUrl <url>]
# UI at http://<host>:8090/ ; stop with test/Stop-PoolControlVM.ps1
```

`-HostSideProof` builds + runs the daemon directly on this host instead of a VM.
Needs `go` + `pwsh` on PATH and the framework checkout (the CLIs live at
`<repo>/test/*.ps1`).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.24

Back to [Yuruna](../README.md)
