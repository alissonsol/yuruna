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

> The one-liners above are the **convenience path** and are **UNVERIFIED** by
> construction (a single pipe runs the bytes before anything can check them).
> They fetch the moving `refs/heads/main`. For a tagged release, prefer the
> **verified** path below.

## Verified install (signed release)

> Available for published release **tags**. The signing artifacts
> (`install.sha256.sig`, `install/keys/`) first ship in release `2026.06.12`;
> until that tag is cut, use the convenience one-liners above.

A tagged release publishes, next to each installer:

- `install/install.sha256` — SHA-256 of the three installers, and
- `install/install.sha256.sig` — a detached RSA signature of that manifest,

verifiable against the bundled public key `install/keys/yuruna-release-signing.pub`
(`.pem` for `openssl`, `.xml` for Windows PowerShell). This defends a compromised
CDN/mirror or a moved ref — not just same-channel corruption. **First confirm the
key fingerprint out-of-band** (see [install/keys/README.md](keys/README.md)):

```
SHA-256(DER public key) = 14fce044df5de1ebbac6fdeae8d4f87abac618393f06e32748b7ef4571c5c337
```

**Windows Hyper-V** (PowerShell 5.1+; uses .NET, no extra tooling):

```
$base='https://raw.githubusercontent.com/alissonsol/yuruna/refs/tags/2026.06.12'; $t=Join-Path $env:TEMP 'yuruna-install'; New-Item -ItemType Directory -Force $t|Out-Null
'install/windows.hyper-v.ps1','install/install.sha256','install/install.sha256.sig','install/keys/yuruna-release-signing.pub.xml'|%{ irm "$base/$_" -OutFile (Join-Path $t (Split-Path $_ -Leaf)) }
$k=New-Object System.Security.Cryptography.RSACryptoServiceProvider; $k.FromXmlString((Get-Content "$t\yuruna-release-signing.pub.xml" -Raw))
if(-not $k.VerifyData([IO.File]::ReadAllBytes("$t\install.sha256"),'SHA256',[IO.File]::ReadAllBytes("$t\install.sha256.sig"))){throw 'SIGNATURE INVALID -- do not run'}
$h=(Get-FileHash "$t\windows.hyper-v.ps1" -Algorithm SHA256).Hash.ToLower(); if(-not(Select-String -Path "$t\install.sha256" -SimpleMatch $h)){throw 'INSTALLER HASH MISMATCH -- do not run'}
& "$t\windows.hyper-v.ps1"
```

**macOS UTM / Ubuntu KVM** (uses `openssl`, present on both):

```
BASE='https://raw.githubusercontent.com/alissonsol/yuruna/refs/tags/2026.06.12'; S=install/macos.utm.sh   # or install/ubuntu.kvm.sh
t=$(mktemp -d); for f in "$S" install/install.sha256 install/install.sha256.sig install/keys/yuruna-release-signing.pub.pem; do curl -fsSL "$BASE/$f" -o "$t/$(basename "$f")"; done
openssl dgst -sha256 -verify "$t/yuruna-release-signing.pub.pem" -signature "$t/install.sha256.sig" "$t/install.sha256" || { echo 'SIGNATURE INVALID -- do not run'; exit 1; }
grep -qF "$(sha256sum "$t/$(basename "$S")" | cut -d' ' -f1)" "$t/install.sha256" || { echo 'INSTALLER HASH MISMATCH -- do not run'; exit 1; }
bash "$t/$(basename "$S")"
```

The detached signature is produced at release time by `tools/Update-YurunaReleasePins.ps1`.

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

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.12

Back to [Yuruna](../README.md)
