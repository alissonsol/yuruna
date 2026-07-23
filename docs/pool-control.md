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

**Host-side (proof / fallback):**

```
pwsh test/Start-PoolControlServer.ps1 [-Port 8090] [-AggregatorUrl <url>]
# UI at http://<host>:8090/ ; stop with test/Stop-PoolControlServer.ps1
```

Needs `go` + `pwsh` on PATH and the framework checkout (the CLIs live at
`<repo>/test/*.ps1`).

**On its own VM:** `host/vmconfig/pool-control.base.user-data` seeds an Ubuntu guest
that builds the daemon, installs pwsh + `powershell-yaml`, CIFS-mounts the pool NAS
for the state dir, and runs it under systemd (`guest/ubuntu.server.26/ubuntu.server.26.pool-control.sh`).
The per-hypervisor `guest.pool-control/New-VM.ps1` (mirroring the stash VM chain)
generates the seed with `/etc/yuruna/{pool.env,host.env,pool-nas.cifs.cred}` and a
distinct guest username. The Extension-hosts row then points at the VM (beacon
self-IP); deleting the VM clears it after the announce TTL.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.22

Back to [Yuruna](../README.md)
