# Test harness — architecture

How `test/` is put together. See [Yuruna Architecture](architecture.md) for project-wide
architecture and [Yuruna Test ...](../test/README.md) for operator usage.

## Entry points

| Script | Purpose |
|--------|---------|
| `Invoke-TestRunner.ps1`  | Continuous test loop (the daily driver) |
| `Test-Sequence.ps1` | Dev helper: single sequence, any start/stop step |
| `Start-StatusServer.ps1` / `Stop-StatusServer.ps1` | Detached HTTP status UI |
| `Start-SshServer.ps1` / `Stop-SshServer.ps1`       | Host-side OpenSSH (Hyper-V today; macOS placeholder) |
| `Start-CachingProxy.ps1` / `Stop-CachingProxy.ps1` | Expose the Squid VM to remote clients |
| `Test-Config.ps1`            | Validate `test.config.yml` + optional notification send |
| `Test-CachingProxy.ps1`      | Preflight a local or remote cache |
| `Train-Screenshots.ps1`      | Interactive reference-screenshot capture |
| `Remove-TestVMFiles.ps1`     | Purge test VMs and per-VM artifacts |

## Cycle

Each iteration of `Invoke-TestRunner.ps1`:

1. `git pull`, then re-read `test.config.yml`.
2. Every 24h (configurable): refresh base images via `Get-Image.ps1`.
3. For each entry in `guestSequence`:
   - Verify `host/<short-host>/<guestKey>/` exists — missing folder is a
     per-guest failure; other guests still run unless `testCycle.shouldStopOnFailure`.
   - Clean the previous test VM.
   - `New-VM.ps1` → `Start-VM` → poll until running → screenshot
     checkpoints → JSON sequences dispatched via the cycle planner.
4. On first failure: leave the VM, send a Resend notification, exit.

## Modes

`vmCommunication.keystrokeMechanism` in `test.config.yml` selects how the
harness drives guests:

- `"GUI"` — keystroke injection (Hyper-V scancodes, UTM VNC/CGEvent).
  Sequences loaded from `sequences/gui/<name>.yml`.
- `"SSH"` — routes workloads over SSH using a per-host key under
  `test/status/ssh/` that cloud-init injects into each guest.
  `sequences/ssh/<name>.yml`, falling back to `gui/` when no SSH variant
  exists.

Invalid values are normalized to `"GUI"` on startup.

## Module responsibilities

Cross-host harness modules live in `test/modules/`. All host-specific
code (VM lifecycle, image fetch, screenshots, port maps, host proxy,
SSH server) is delegated to a per-host driver module — see [Yuruna.Host
contract](#yurunahost-contract) below.

| Module | Purpose |
|--------|---------|
| `Test.Host`            | Platform detection, git, host-condition guards, `Initialize-YurunaHost` dispatcher |
| `Test.Status`          | `status.json` lifecycle |
| `Test.StatusServer`    | Status HTTP server start/stop |
| `Test.Extension`       | Loader for the pluggable extension areas under `test/extension/<area>/` (authentication, notification, host-ssh-server) |
| `Test.Notify`          | Thin dispatcher to the active notification extension(s) (`Send-Notification -EventCode -EventMessage -EventNote`); default extension delivers email via Resend |
| `Test.Log` / `Test.LogDir` / `Test.RuntimeDir` | Transcript and state directories |
| `Test.Start-GuestOS`        | Start-GuestOS tile: start.guest.* sequence orchestration |
| `Test.Start-GuestWorkload`  | Start-GuestWorkload tile: post-OS workload sequence orchestration |
| `Test.OcrEngine` / `Test.Tesseract` | Pluggable OCR engines |
| `Test.Ssh`             | Per-guest SSH keys + `ssh`/`scp` helpers |
| `Test.Provenance`      | Artifact provenance metadata |
| `Test.VM.common`       | Cross-host VM helpers shared by every Yuruna.Host driver |

### Yuruna.Host contract

`Initialize-YurunaHost` (in `Test.Host`) imports the matching driver
based on host type:

| Host type | Driver |
|-----------|--------|
| `host.windows.hyper-v` | [`host/windows.hyper-v/modules/Yuruna.Host.psm1`](../host/windows.hyper-v/modules/Yuruna.Host.psm1) (real) |
| `host.macos.utm`       | [`host/macos.utm/modules/Yuruna.Host.psm1`](../host/macos.utm/modules/Yuruna.Host.psm1) (real) |
| `host.ubuntu.kvm`      | [`host/ubuntu.kvm/modules/Yuruna.Host.psm1`](../host/ubuntu.kvm/modules/Yuruna.Host.psm1) (stubs only) |

The driver exports a fixed set of contract functions covering VM
lifecycle (`New-VM`, `Start-VM`, `Stop-VM`, `Remove-VM`, `Rename-VM`,
`Get-VMState`), snapshot management (`Save-VMDiskSnapshot`,
`Restore-VMDiskSnapshot`), image fetch (`Get-Image`, `Get-ImagePath`),
VM I/O (`Send-Text`, `Send-Key`, `Send-Click`, `Get-VMScreenshot`),
discovery (`Wait-VMIp`, `Get-VMIp`, `Get-VMMac`), networking
(`Get-ExternalNetwork`, `New-ExternalNetwork`,
`Test-CacheVMOnExternalNetwork`), caching-proxy port maps
(`Add-PortMap`, `Remove-PortMap`, `Test-CachingProxyAvailable`,
`Get-CachingProxyVMIp`), host-side proxy (`Set-HostProxy`,
`Clear-HostProxy`, `Remove-HostProxy`), virtualization checks
(`Assert-Virtualization`), and SSH server lifecycle
(`Test-SshServerSupported`, `Install-SshServer`, `Start-SshServer`,
`Stop-SshServer`, `Get-SshServerStatus`). Per-host implementation
notes for the contracts whose behaviour diverges in operationally
significant ways (snapshot + rename, screen I/O):
[Sequence actions and host contracts](test-sequences.md#yurunahost-contract).

Per-cycle dispatch is YAML-driven: each cycle reads
`project/test/test.sequence.yml` to get the top-level workload sequence
names, walks each sequence's `baseline` field (object keyed by guest
OS) to derive a dependency-ordered chain, and dispatches each chain
entry through [`modules/Invoke-Sequence.psm1`](../test/modules/Invoke-Sequence.psm1).
Sequences whose name starts with `start.` run during the runner's
Start-GuestOS step; everything else runs during Start-GuestWorkload. No
per-OS `.ps1` glue is required. Full architecture:
[Test Modules](../test/modules/README.md).

## Runtime directories

```
test/
├── status/
│   ├── index.html              Status dashboard (committed)
│   ├── status.json.template    Template (committed)
│   ├── track/                  $env:YURUNA_RUNTIME_DIR default (git-ignored)
│   │                           status.json, PID locks, control.* flags,
│   │                           current-action.json, caching-proxy state
│   │   └── extension/          events.log (JSON-lines, no
│   │                           plaintext values; redacted from /track/)
│   └── log/                    $env:YURUNA_LOG_DIR default (git-ignored)
│                               HTML transcripts + per-component debug subdirs
├── sequences/
│   ├── actions.yml             Action catalogue (YAML, machine-readable)
│   ├── actions.md              Action reference + per-host contract notes
│   ├── gui/                    GUI-mode sequences
│   └── ssh/                    SSH-mode sequences (falls back to gui/)
├── schemas/                    JSON Schema files (YAML-encoded) for extension/* configs + vault
├── extension/                  Pluggable extension areas (Test.Extension loader; committed code only)
│   ├── authentication/         default.psm1, authentication.config.yml
│   ├── host-ssh-server/        default.psm1 wraps Yuruna.Host SSH contract
│   └── notification/           default.psm1, notification.config.yml, transports.yml.template
├── screenshots/<guestKey>/
│   ├── schedule.json           Capture checkpoints + thresholds
│   └── reference/*.png         Trained reference screenshots (committed)
└── status/                     Status dashboard + ALL harness runtime state
    ├── index.html, hostinfo.html, test.config.html, yuruna.common.{css,js},
    │                           status.json.template     (committed UI)
    ├── runtime/                $env:YURUNA_RUNTIME_DIR -- pids,
    │                           status.json, control flags, ipaddresses.txt,
    │                           caching-proxy.txt, server.err, host.uuid,
    │                           yuruna-caching-proxy.yml, .status-server.ps1
    ├── log/                    $env:YURUNA_LOG_DIR -- HTML transcripts,
    │                           OCR debug, failure screenshots
    ├── perf/                   JSONL perf rows + content-addressed
    │                           host/guest dumps
    ├── extension/
    │   ├── authentication/     vault.yml, vault.lock, events.log (plaintext)
    │   └── notification/       transports.yml (Resend API key)
    ├── captures/
    │   ├── sequences/          takeScreenshot debug PNGs
    │   └── training/           per-cycle training captures, guest-prefixed
    └── ssh/                    yuruna_ed25519(.pub) -- generated per host
```

### Extension areas

Each area under `test/extension/<area>/` ships a committed
`<area>.config.yml` naming the active `<name>.psm1` modules
(authentication uses exactly `active[0]`; notification iterates the
list). A user override is to drop a sibling `<name>.psm1` next to
`default.psm1` and edit the area's `<area>.config.yml`.

- **authentication** — credential vault simulating an external auth
  provider. The default extension's vault.yml persists across cycles
  (Initialize-VaultConnection is a no-op when the file already
  exists); the "fake" behaviour is the lazy-create branch in
  Get-Password (first reference for a username generates+stores a
  password, every later call returns the same stored value). Sequence
  steps fetch live values via
  `${ext:authentication.GetPassword(${username})}` /
  `${ext:authentication.NewRandomPassword()}` substitutions; commits are done
  via the `callExtension` action verb (`authentication.SetPassword`). A named
  system mutex serialises read-modify-write across parallel guests.
- **notification** — per-event-code dispatch (`cycle.failure`,
  `config.smoke`). Subscribers and transport credentials live in
  `test/status/extension/notification/transports.yml` (gitignored
  runtime state); template (`transports.yml.template`) ships in-tree
  under `test/extension/notification/`.
- **host-ssh-server** — config-driven enable/disable of the host's SSH
  server, applied each cycle by the runner. Reads
  `hostSshServer.enabled` from [test.config.yml](../test/test.config.yml). The
  default provider delegates to the active `Yuruna.Host` driver's SSH
  contract (`Test-SshServerSupported`, `Test-SshServerInstalled`,
  `Start-SshServer`, `Stop-SshServer`, `Get-SshServerStatus`); install
  is still a one-time manual step (`pwsh test/Start-SshServer.ps1`).
  Exports `Get-SshServerInfo`, `Enable-SshServer`, `Disable-SshServer`,
  all returning a uniform `@{ supported; installed; enabled; ok;
  message }` hashtable so a future VM-based provider can swap in
  without caller changes.

Override track and log directories via `$env:YURUNA_RUNTIME_DIR` and
`$env:YURUNA_LOG_DIR` before launch; the status server remaps the URL
prefixes.

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | All guests passed (runner was interrupted or completed) |
| `1` | One or more guests failed, or pre-flight error |

Back to [Yuruna Test ...](../test/README.md) · [Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
