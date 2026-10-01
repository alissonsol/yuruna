<a id="420f54a5-0001"></a>

# Install scripts

One bootstrap installer per host. Each is idempotent, prompts for
elevation once with an up-front banner, and clones the repo to
`~/git/yuruna` (or `%USERPROFILE%\git\yuruna` on Windows).

By default the clone tracks the `main` branch, so the host **auto-updates
the framework every test cycle**. To freeze a host at a fixed release, see
**Pin to a release** below.

Enabling the host as a Yuruna test host (display sleep / screen lock /
storage-pool tweaks) is intentionally NOT done automatically. Run
[setup.ps1](setup.ps1) after install -- see **Guided setup** below -- or, for the
host settings alone, `host/<platform>/Enable-TestAutomation.ps1`.

| Host | Installer | Setup notes |
|------|-----------|-------------|
| macOS UTM | [macos.utm.sh](macos.utm.sh) | [macOS UTM ...](../host/macos.utm/README.md) |
| Windows Hyper-V | [windows.hyper-v.ps1](windows.hyper-v.ps1) | [Windows Hyper-V ...](../host/windows.hyper-v/README.md) |
| Ubuntu KVM/libvirt | [ubuntu.kvm.sh](ubuntu.kvm.sh) | [Ubuntu KVM/libvirt ...](../host/ubuntu.kvm/README.md) |

<a id="420f54a5-0002"></a>

## Guided setup

The installer above puts packages and the repo on the machine. [setup.ps1](setup.ps1)
takes it the rest of the way -- to a working **Standalone host** or **Lab** --
asking only what it cannot infer:

```
pwsh install/setup.ps1                    # interactive
pwsh install/setup.ps1 -WhatIf            # print the ordered task list, change nothing
pwsh install/setup.ps1 -AnswerFile a.yml  # unattended, same code path
pwsh install/setup.ps1 -logLevel Debug    # everything the run and its children can say
```

| Mode | What it sets up |
|------|-----------------|
| **Standalone host** | One machine that runs tests by itself: host settings, storage, the caching-proxy-service and the stash service. |
| **Lab** | A beacon other machines join: shared storage, the caching-proxy-service, the stash, pool-control and download-agent services, this host enrolled, and a `default` pool. |

Storage is one of the questions, not an assumption: **this machine** (local SMB
shares, the default for standalone), **an existing NAS share** (mounted, never
created -- set up the share and `networkStorage.*` first), or **none**, which is
standalone-only and skips shared storage and the stash service.

It installs nothing and clones nothing -- it orchestrates the scripts that already
do each job. Storage is configured **before** the service VMs in both modes,
because the stash service exits 1 without it and the caching-proxy-service bakes
storage into its guest seed at build time.

Re-running is safe: each step detects what is already true and skips it, so a run
interrupted halfway is resumed by running it again. On Windows the whole run
elevates once, up front. A guided run ends by writing the answer file it used, so
the next machine can be set up the same way.

Every run -- previews included -- is recorded in
`test/status/log/setup.<yyyy.MM.dd.HH.mm>.log`: each question, the answer taken
and whether anyone chose it, each step and its outcome, each child script's
command line and exit code, and the closing report. The setup names the file at
start and at end. The child scripts keep printing to the console rather than the
log, so their prompts stay visible; on Windows the elevated relaunch continues
the same file.

The log gets all of that whatever `-logLevel` says -- the level decides how much
also reaches the terminal, and how much the child scripts say there. It is the
[shared cascade](../docs/loglevels.md): `Error` through `Debug`, taken from
`logLevel:` in `test/test.config.yml` when the switch is omitted, and passed down
to every script the run starts -- including the per-guest image and VM builders --
so `-logLevel Debug` is the setting for a bring-up that failed somewhere inside
a child.

For what a lab is and how hosts join one, see [docs/lab-operator.md](../docs/lab-operator.md).

<a id="420f54a5-0003"></a>

### Putting a machine back

[test/lab/Disable-TestAutomation.ps1](../test/lab/Disable-TestAutomation.ps1) restores the
host settings `Enable-TestAutomation` changed, from the capture Enable wrote
before it changed anything:

```
pwsh test/lab/Disable-TestAutomation.ps1 -WhatIf        # show what would be restored
pwsh test/lab/Disable-TestAutomation.ps1
pwsh test/lab/Disable-TestAutomation.ps1 -StopServices  # also stop the service VMs
```

It reverses settings only. Packages, PSGallery modules, macOS TCC grants, the
credential vault, cloned repos and images, and everything the storage
questionnaire wrote are **reported, mostly with the command to run** rather than removed --
tearing those down on a "disable settings" is a surprise. On a host enabled by a
build that predates the capture, only what is provably ours is removed -- the status-port
firewall rule and the Yuruna ICMP rule on Windows, the `ufw` status-port rule on
Ubuntu, and **nothing at all on macOS**, which adds no objects of its own. Every
other setting is left alone and reported, because restoring a guessed default is
still a change nobody asked for.

It refuses to run while a test runner owns the host's runtime directory. Full
breakdown in [docs/operator.md](../docs/operator.md#putting-the-machine-back).

<a id="420f54a5-0004"></a>

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
than the macOS `bash -c "$(curl ...)"` form. Both reach the same script,
but process substitution keeps it a real file argument for bash, which
sidesteps a stdin/sudo-prompt edge case some Ubuntu terminals trip on.

> The one-liners above are the **convenience path** and are **UNVERIFIED** by
> construction (a single pipe runs the bytes before anything can check them).
> They fetch the moving `refs/heads/main`, and the resulting clone **tracks
> `main` and auto-updates every cycle** (see **Pin to a release** below). For a
> signature-checked install, prefer the **verified** path below.

<a id="420f54a5-0005"></a>

## Pin to a release (disable auto-update)

To freeze a host at the current release -- the version in the repo's
`VERSION` file at install time -- add `-PinVersion` (Windows) /
`PIN_VERSION=1` (macOS, Ubuntu).

**From the web (pinned):**

macOS UTM:

```
PIN_VERSION=1 /bin/bash -c "$(curl -fsSL "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/macos.utm.sh?nocache=$(date +%Y%m%d%H%M%S)")"
```

Windows Hyper-V (a piped `irm | iex` cannot take parameters, so build a
scriptblock from the fetched bytes and pass the switch):

```
& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows.hyper-v.ps1?nocache=$(Get-Date -Format yyyyMMddHHmmss)"))) -PinVersion
```

Ubuntu KVM/libvirt:

```
PIN_VERSION=1 bash <(curl -fsSL "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/ubuntu.kvm.sh?nocache=$(date +%Y%m%d%H%M%S)")
```

**Locally from the `install/` folder (pinned):**

```
# Windows
.\install\windows.hyper-v.ps1 -PinVersion

# macOS  (env var or flag, equivalent)
PIN_VERSION=1 bash install/macos.utm.sh
bash install/macos.utm.sh --pin-version

# Ubuntu  (env var or flag, equivalent)
PIN_VERSION=1 bash install/ubuntu.kvm.sh
bash install/ubuntu.kvm.sh --pin-version
```

To pin to a *specific other* release instead of this installer's baked one,
pass the tag directly: `-YurunaBranch 2026.06.20` /
`YURUNA_BRANCH=2026.06.20`.

<a id="420f54a5-0006"></a>

## Verified install (signed release)

> Available for published release **tags**. The signing artifacts
> (`install.sha256.sig`, `install/keys/`) first ship in release `2026.06.12`;
> for an older tag, use the convenience one-liners above.

A tagged release publishes, next to each installer:

- `install/install.sha256` -- SHA-256 of the three installers, and
- `install/install.sha256.sig` -- a detached RSA signature of that manifest,

verifiable against the bundled public key `install/keys/yuruna-release-signing.pub`
(`.pem` for `openssl`, `.xml` for Windows PowerShell). This defends against a
compromised CDN/mirror or a moved ref -- not just same-channel corruption. **First
confirm the key fingerprint out-of-band** (see [install/keys/README.md](keys/README.md)):

```
SHA-256(DER public key) = 14fce044df5de1ebbac6fdeae8d4f87abac618393f06e32748b7ef4571c5c337
```

Both snippets refuse unless every download succeeds, the manifest signature
verifies, and the installer's SHA-256 equals the one manifest row whose path is
exactly the file downloaded -- a hash that appears on another row, or anywhere
else in the manifest, does not count.

**Windows Hyper-V** (PowerShell 5.1+; uses .NET, no extra tooling). The block is
one statement, so a failed check stops it even when the console runs pasted
lines one at a time:

```
& { $ErrorActionPreference='Stop'; $base='https://raw.githubusercontent.com/alissonsol/yuruna/refs/tags/2026.09.30'; $t=Join-Path $env:TEMP ('yuruna-install-'+[guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force $t|Out-Null
'install/windows.hyper-v.ps1','install/install.sha256','install/install.sha256.sig','install/keys/yuruna-release-signing.pub.xml'|%{ irm "$base/$_" -OutFile (Join-Path $t (Split-Path $_ -Leaf)) }
$k=New-Object System.Security.Cryptography.RSACryptoServiceProvider; $k.FromXmlString((Get-Content "$t\yuruna-release-signing.pub.xml" -Raw))
if(-not $k.VerifyData([IO.File]::ReadAllBytes("$t\install.sha256"),'SHA256',[IO.File]::ReadAllBytes("$t\install.sha256.sig"))){throw 'SIGNATURE INVALID -- do not run'}
$h=(Get-FileHash "$t\windows.hyper-v.ps1" -Algorithm SHA256).Hash.ToLower(); $w=@(Get-Content "$t\install.sha256" | %{ if($_ -cmatch '^([0-9a-f]{64})  install/windows\.hyper-v\.ps1$'){ $Matches[1] } }); if($w.Count -ne 1 -or $h -cnotmatch '^[0-9a-f]{64}$' -or $w[0] -cne $h){throw 'INSTALLER HASH MISMATCH -- do not run'}
$ErrorActionPreference='Continue'; & "$t\windows.hyper-v.ps1" }
```

**macOS UTM / Ubuntu KVM** (uses `openssl`, present on both). On Ubuntu, set
`S=install/ubuntu.kvm.sh` in the first line:

```
BASE='https://raw.githubusercontent.com/alissonsol/yuruna/refs/tags/2026.09.30'; S=install/macos.utm.sh
t=$(mktemp -d); for f in "$S" install/install.sha256 install/install.sha256.sig install/keys/yuruna-release-signing.pub.pem; do curl -fsSL "$BASE/$f" -o "$t/$(basename "$f")" || { echo "DOWNLOAD FAILED: $f -- do not run"; exit 1; }; done
openssl dgst -sha256 -verify "$t/yuruna-release-signing.pub.pem" -signature "$t/install.sha256.sig" "$t/install.sha256" || { echo 'SIGNATURE INVALID -- do not run'; exit 1; }
got=$(openssl dgst -sha256 -r "$t/$(basename "$S")" | cut -d' ' -f1); want=$(awk -v p="$S" 'NF == 2 && $2 == p { print $1; n++ } END { if (n != 1) exit 1 }' "$t/install.sha256") || want=''
printf '%s\n' "$got" | grep -Eqx '[0-9a-f]{64}' && [ "$got" = "$want" ] || { echo 'INSTALLER HASH MISMATCH -- do not run'; exit 1; }
bash "$t/$(basename "$S")"
```

The detached signature is produced at release time by `tools/Update-YurunaReleasePins.ps1`.

Each link in the table above goes to the per-host README with post-install
steps (group membership, screen-saver settings, TCC grants, etc.).

<a id="420f54a5-0008"></a>

## Refresh an installed macOS host

`macos.utm.sh --refresh` installs nothing. It hands off to the host-refresh
entry script of the checkout already on the machine,
`test/lab/Invoke-HostRefresh.ps1`, which probes the hypervisor and repairs what
it can within a bounded budget. Verifying the installer's signature
authenticates only this dispatcher, not the checkout and modules it then runs,
so this is not a way to repair a checkout you do not trust -- reinstall for
that.

Both signals are required: the `--refresh` argument and `YURUNA_REFRESH=1`.
Either one alone refuses and changes nothing, so a leftover variable cannot turn
an ordinary install into a refresh, or a refresh into an install.

Convenience form (unverified), pinned to a release tag. The `_` fills the `$0`
slot that `bash -c` gives its script text, so `--refresh` arrives as an
argument:

```
YURUNA_REFRESH=1 /bin/bash -c "$(curl -fsSL 'https://raw.githubusercontent.com/alissonsol/yuruna/refs/tags/2026.09.30/install/macos.utm.sh')" _ --refresh
```

Verified form: run the **macOS UTM / Ubuntu KVM** block under **Verified
install** above with `S=install/macos.utm.sh`, replacing its last line with:

```
YURUNA_REFRESH=1 bash "$t/$(basename "$S")" --refresh
```

> Use the tag shown here or a newer one. An installer from a release older than
> the first refresh-capable one does not know `--refresh`: it ignores the
> argument and runs a **full install**, including the reset that removes the
> test VMs.

The exit code is the entry script's: `0` when the host was healthy or has been
repaired, `1` when the refresh was refused or failed before changing anything
(the dispatcher's own refusals included), and `2` when the host still needs
attention. Any other code is a failure the entry script did not report itself.
A dispatcher that cannot start `pwsh`, for example, ends with the shell's own
code, such as `126` or `127`, before anything has changed. To see what a
refresh would do without changing anything, run the entry script from the
checkout root:

```
pwsh -NoProfile -File test/lab/Invoke-HostRefresh.ps1 -WhatIf
```

The dispatcher is macOS-only; on the other hosts, run the entry script directly.

<a id="420f54a5-0007"></a>

## GitHub CLI (`gh`)

Each installer also installs the [GitHub CLI](https://cli.github.com/)
as one of its package steps (`GitHub.cli` via winget on Windows,
`brew install gh` on macOS, the `cli.github.com` apt repo on Ubuntu).
The binary lands on PATH but is unauthenticated -- run

```
gh auth login
```

once per host. The installer cannot do it: authentication requires an
interactive web flow (or a personal-access token paste) that the
operator has to drive.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.09.30

Back to [Yuruna](../README.md)
