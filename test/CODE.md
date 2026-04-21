# Test harness — architecture

How `test/` is put together. See [../CODE.md](../CODE.md) for project-wide
architecture and [README.md](README.md) for operator usage.

## Entry points

| Script | Purpose |
|--------|---------|
| `Invoke-TestRunner.ps1`  | Continuous VDE test loop (the daily driver) |
| `Invoke-TestSequence.ps1` | Dev helper: single sequence, any start/stop step |
| `Start-StatusServer.ps1` / `Stop-StatusServer.ps1` | Detached HTTP status UI |
| `Start-SshServer.ps1` / `Stop-SshServer.ps1`       | Host-side OpenSSH (Hyper-V today; macOS placeholder) |
| `Start-CachingProxy.ps1` / `Stop-CachingProxy.ps1` | Expose the Squid VM to remote clients |
| `Test-Config.ps1`            | Validate `test-config.json` + optional notification send |
| `Test-CachingProxy.ps1`      | Preflight a local or remote cache |
| `Train-Screenshots.ps1`      | Interactive reference-screenshot capture |
| `Remove-TestVMFiles.ps1`     | Purge test VMs and per-VM artifacts |

## Cycle

Each iteration of `Invoke-TestRunner.ps1`:

1. `git pull`, then re-read `test-config.json`.
2. Every 24h (configurable): refresh base images via `Get-Image.ps1`.
3. For each entry in `guestOrder`:
   - Verify `virtual/<hostType>/<guestKey>/` exists — missing folder is a
     per-guest failure; other guests still run unless `stopOnFailure`.
   - Clean the previous test VM.
   - `New-VM.ps1` → `Start-VM` → poll until running → screenshot
     checkpoints → extension scripts in `test/extensions/`.
4. On first failure: leave the VM, send a Resend notification, exit.

## Modes

`keystrokeMechanism` in `test-config.json` selects how the harness drives
guests:

- `"GUI"` — keystroke injection (Hyper-V scancodes, UTM VNC/CGEvent).
  Sequences loaded from `sequences/gui/<name>.json`.
- `"SSH"` — routes workloads over SSH using a per-host key under
  `test/.ssh/` that cloud-init injects into each guest.
  `sequences/ssh/<name>.json`, falling back to `gui/` when no SSH variant
  exists.

Invalid values are normalized to `"GUI"` on startup.

## Module responsibilities

All modules live in `test/modules/`.

| Module | Purpose |
|--------|---------|
| `Get-NewText`         | Diff-based OCR text extraction (pure C#) |
| `Test.Host`           | Platform detection, git, host-condition guards |
| `Test.Status`         | `status.json` lifecycle |
| `Test.StatusServer`   | Status HTTP server start/stop |
| `Test.SshServer`      | Host-side OpenSSH install / toggle |
| `Test.Notify`         | Resend email notifications |
| `Test.Get-Image`      | Base image download + refresh |
| `Test.Log` / `Test.LogDir` / `Test.TrackDir` | Transcript and state directories |
| `Test.New-VM`         | VM create + verify + cleanup |
| `Test.Install-OS`     | OS-install sequence orchestration |
| `Test.Start-VM`       | VM start/stop + verify running |
| `Test.Invoke-PoolTest`| Extension test discovery and execution |
| `Test.Screenshot`     | Capture, compare, schedule |
| `Test.OcrEngine` / `Test.Tesseract` | Pluggable OCR engines |
| `Test.CachingProxy` / `Test.HostProxy` / `Test.PortMap` | Squid-cache discovery and host-side forwarders |
| `Test.Provenance`     | Artifact provenance metadata |

Extensions (`test/extensions/`) are `.ps1` files named
`Test-Start.guest.<name>.ps1` (OS install) or
`Test-Workload.guest.<name>.ps1` (post-install validation). They receive
`$HostType`, `$GuestKey`, `$VMName`; exit code non-zero = failure. Full
API: [extensions/README.md](extensions/README.md).

## Runtime directories

```
test/
├── status/
│   ├── index.html              Status dashboard (committed)
│   ├── status.json.template    Template (committed)
│   ├── track/                  $env:YURUNA_TRACK_DIR default (git-ignored)
│   │                           status.json, PID locks, control.* flags,
│   │                           current-action.json, caching-proxy state
│   └── log/                    $env:YURUNA_LOG_DIR default (git-ignored)
│                               HTML transcripts + per-component debug subdirs
├── sequences/
│   ├── actions.json            Action reference
│   ├── gui/                    GUI-mode sequences
│   └── ssh/                    SSH-mode sequences (falls back to gui/)
├── screenshots/<guestKey>/
│   ├── schedule.json           Capture checkpoints + thresholds
│   ├── reference/*.png         Trained reference screenshots
│   └── captures/               Per-run captures (git-ignored)
└── .ssh/                       Per-host harness SSH keys
```

Override track and log directories via `$env:YURUNA_TRACK_DIR` and
`$env:YURUNA_LOG_DIR` before launch; the status server remaps the URL
prefixes.

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | All guests passed (runner was interrupted or completed) |
| `1` | One or more guests failed, or pre-flight error |

Back to [[Test harness](README.md)]
