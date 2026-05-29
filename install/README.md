# Install scripts

One bootstrap installer per host. Each one is idempotent, prompts for
elevation once with an up-front banner, and clones the repo to
`~/git/yuruna` (or `%USERPROFILE%\git\yuruna` on Windows).

Enabling the host as a Yuruna test host (display sleep / screen lock /
storage-pool tweaks) is intentionally NOT done automatically. Run
`host/<platform>/Enable-TestAutomation.ps1` after install if you want this
machine to act as a test host.

| Host | Installer | Setup notes |
|------|-----------|-------------|
| macOS UTM | [macos.utm.sh](macos.utm.sh) | [macOS UTM ...](../host/macos.utm/README.md) |
| Windows Hyper-V | [windows.hyper-v.ps1](windows.hyper-v.ps1) | [Windows Hyper-V ...](../host/windows.hyper-v/README.md) |
| Ubuntu KVM/libvirt | [ubuntu.kvm.sh](ubuntu.kvm.sh) | [Ubuntu KVM/libvirt ...](../host/ubuntu.kvm/README.md) |

## Remote one-liners

Each one-liner appends `?nocache=<timestamp>` unconditionally. The
install is a one-shot per fresh host and a stale cached installer is
the worst kind of stale (the operator can't tell, and re-running from
the README is the documented recovery path). For the system-wide
`YurunaCacheContent` cache-buster honored by every OTHER Yuruna
one-liner (fetch-and-execute, guest workload installs), see
[docs/caching.md](../docs/caching.md).

**macOS UTM** (paste into Terminal):

```
/bin/bash -c "$(curl -fsSL "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/macos.utm.sh?nocache=$(date +%Y%m%d%H%M%S)")"
```

**Windows Hyper-V** (paste into PowerShell or Windows PowerShell, will
self-elevate):

```
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows.hyper-v.ps1?nocache=$(Get-Date -Format yyyyMMddHHmmss)" | iex
```

**Ubuntu KVM/libvirt** (paste into Terminal):

```
bash <(curl -fsSL "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/ubuntu.kvm.sh?nocache=$(date +%Y%m%d%H%M%S)")
```

The Ubuntu line uses process substitution (`bash <(curl ...)`) rather
than the `bash -c "$(curl ...)"` form that the macOS one uses. Both reach
the same script, but the process-substitution form keeps the script as
a real file argument for bash, which sidesteps a stdin/sudo-prompt
edge case some Ubuntu terminals trip on.

Each link in the table above goes to the per-host README with the
post-install steps (group membership, screen-saver settings, TCC
grants, etc.).

## GitHub CLI (`gh`)

Each installer also installs the [GitHub CLI](https://cli.github.com/)
as one of its package steps (`GitHub.cli` via winget on Windows,
`brew install gh` on macOS, the `cli.github.com` apt repo on Ubuntu).
The binary lands on PATH but is unauthenticated -- run

```
gh auth login
```

once per host to authenticate. The installer cannot do this for you:
authentication requires an interactive web flow (or a personal-access
token paste) that the operator has to drive.

Back to [Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
