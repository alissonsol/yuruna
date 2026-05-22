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

**macOS UTM** (paste into Terminal):

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/macos.utm.sh)"
```

**Windows Hyper-V** (paste into PowerShell or Windows PowerShell, will
self-elevate):

```powershell
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows.hyper-v.ps1$nc" | iex
```

**Ubuntu KVM/libvirt** (paste into Terminal):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/ubuntu.kvm.sh)
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

```bash
gh auth login
```

once per host to authenticate. The installer cannot do this for you:
authentication requires an interactive web flow (or a personal-access
token paste) that the operator has to drive.

Back to [Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
