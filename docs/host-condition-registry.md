# Host-condition registry

Each supported host platform (Windows Hyper-V, macOS UTM, Ubuntu KVM)
exposes the same three-method contract:

- `Set-<Platform>HostConditionSet` — apply settings the unattended
  runner needs (display timeout, screen lock, sudo cache, libvirt
  group membership, ...). Called by `Enable-TestAutomation.ps1`.
- `Assert-<Platform>HostConditionSet` — gate every test cycle on
  those settings still being in effect.
- `Test-<Platform>HostMinimum` — quick check for one-off operator
  helpers (`Remove-TestVMFiles.ps1`, `Remove-OrphanedVMFiles.ps1`,
  ...) where the full Assert would be a false positive during
  interactive maintenance.

The facade
[`test/modules/Test.HostCondition.psm1`](../test/modules/Test.HostCondition.psm1)
holds the registry; each platform sibling
([`.Mac`](../test/modules/Test.HostCondition.Mac.psm1),
[`.Windows`](../test/modules/Test.HostCondition.Windows.psm1),
[`.Linux`](../test/modules/Test.HostCondition.Linux.psm1))
exports the matched triplet plus a few platform-specific helpers
(TCC grants on macOS, firewall rules on Windows, libvirt diagnostics
on Linux).

The registry replaces parallel per-host dispatch chains — an
`if/elseif` on `$HostType` inside `Assert-HostConditionSet` plus a
`switch ($HostType)` in `Test-HostRequirement`
([`Test.HostDetection`](../test/modules/Test.HostDetection.psm1)):
inline dispatch needs two edits in two files per new host; the
registry needs one `Register-HostConditionProvider` call.

## Public surface

| Function | Used by |
|---|---|
| `Register-HostConditionProvider -HostType -Set -Assert -AssertMinimum [-RequiresElevation] [-Display] [-DisplayTeardown] [-ClockSync]` | Facade loader; external host plugins |
| `Get-HostConditionProvider -HostType` | Dispatchers; introspection |
| `Get-HostConditionProviderMatrix` | Startup capability matrix |
| `Clear-HostConditionProvider` | Tests only |
| `Assert-HostConditionSet -HostType` | Outer runner per-cycle gate |
| `Get-HostClockSkew` / `Get-HostClockSkewLimit` | Host-clock measurement (direct NTP over UDP) |
| `Assert-HostClock -HostType` | Every platform's `Assert`; `Test-Config` reporting |
| `Sync-HostClock -HostType` | Outer runner cycle boundary; `Test-Config` fix offer |
| `Test-ElevationRequired -HostType` | Cleanup helpers ([`Test.HostDetection`](../test/modules/Test.HostDetection.psm1)) |
| `Test-HostRequirement -HostType [-Quiet]` | One-off operator helpers ([`Test.HostDetection`](../test/modules/Test.HostDetection.psm1)) |

## Provider record shape

Each registration carries an eight-field ordered dict:

```
@{
    HostType          = 'host.windows.hyper-v'
    Set               = { param([string]$HostType) ... }
    Assert            = { param([string]$HostType) ... [bool] }
    AssertMinimum     = { param() ... [bool] }
    RequiresElevation = $true   # consumed by Test-ElevationRequired
    Display           = { param() ... }   # optional: per-cycle display-surface ensure (e.g. attach a virtual monitor on headless Hyper-V); $null when unneeded. Invoked by Initialize-HostDisplay.
    DisplayTeardown   = { param() ... }   # optional inverse: tear the surface down; $null when unneeded. Invoked by Remove-HostDisplay.
    ClockSync         = { param() ... @{ Succeeded; Message } }   # optional: put this host's clock back under NTP discipline. Invoked by Sync-HostClock.
}
```

`Set` and `Assert` are paired; both take `-HostType` and may be
called multiple times per cycle. `AssertMinimum` is lighter than
`Assert` (no display-timeout / screen-lock / TCC-grant checks) and
exists for cleanup helpers that legitimately run during interactive
maintenance.

## Three platforms today

| HostType | RequiresElevation | What `Assert` gates on | `ClockSync` |
|---|---|---|---|
| `host.windows.hyper-v` | `$true` | Administrator elevation, vmms service, display timeout, lock screen, host clock | W32Time → Automatic + started + `w32tm /resync /force` |
| `host.macos.utm` | `$false` | Accessibility + Screen Recording TCC grants, display sleep, screen lock, host clock | `systemsetup -setusingnetworktime on` + `sntp -sS` |
| `host.ubuntu.kvm` | `$false` | Host clock, `/dev/kvm` present, libvirtd active, virsh round-trip, current shell's group set includes `libvirt` | `timedatectl set-ntp true` + step the active daemon |

The Linux `Assert` diagnostic distinguishes "kvm missing" from
"libvirtd down" from "stale group set" from "not in libvirt group at
all" so the operator gets actionable steps, not a generic
"permission denied".

## The host clock

Every hypervisor here seeds a guest's clock from the host at
power-on, so a host that has drifted starts every VM equally wrong —
and the guest's own NTP client steps it to real time seconds into the
boot, landing in the middle of whatever that guest is bringing up. A
Kubernetes guest survives that step looking healthy from every angle
except the one that matters: pods `Running` but never `Ready` (their
status timestamps sit in the future, so `kubectl` prints their age as
`<invalid>`), Services with no endpoints, every NodePort refusing,
while a `curl` straight at the pod IP answers `200`. Nothing in that
picture points back at a clock.

So the clock is handled at three levels:

| Level | What happens |
|---|---|
| `Assert-HostClock`, in every platform's `Assert` | Refuses the cycle past `Get-HostClockSkewLimit` (120s) with the symptom spelled out. An **unmeasurable** clock passes — an isolated lab has no route to a time server and must still run. |
| `Sync-HostClock`, at the outer runner's cycle boundary | Best-effort repair, warn-only. This is the one safe moment to correct a drifted host: no guest is running, so the step cannot do to our own VMs what it would do mid-cycle. |
| `Set-*HostConditionSet` / `Enable-TestAutomation.ps1` | The durable fix: enable the platform's time service so it stays disciplined. `Test-Config.ps1` reports the skew and offers the same repair interactively. |

`Get-HostClockSkew` speaks NTP directly over UDP rather than shelling
out to the platform's time client: on a drifting host that client is
usually the thing that is broken or absent, its output is localized,
and its timeouts are not ours to choose. It returns `$null` — never
`0` — when nothing answers, so "unreachable network" can never be
mistaken for "disciplined clock".

## Registry shape

The facade calls
[`New-YurunaRegistry -Name 'HostCondition' -AnchorVar
'YurunaHostConditionProviders'`](../test/modules/Test.Registry.psm1)
and exposes thin wrappers around `Register` / `Get` / `GetMatrix` /
`Clear`. The provider entries survive `-Force` re-imports of the
facade because the backing store is anchored under
`$global:YurunaHostConditionProviders` — the same eviction-safety
pattern `Test.HostIO`, `Test.SequenceAction`, and `Test.CredentialProvider`
use.

## Adding a new host

1. Implement the three functions for your platform:
   - `Set-<Platform>HostConditionSet -HostType <id>`
   - `Assert-<Platform>HostConditionSet -HostType <id>`
   - `Test-<Platform>HostMinimum`
2. Add a sibling module under `test/modules/Test.HostCondition.<Platform>.psm1`
   and export the triplet.
3. Add the sibling to the facade's `Import-Module` block; add the
   `Register-IfAvailable` line listing the new HostType + function
   names + `RequiresElevation`. Add `-ClockSyncFn` pointing at a
   `Sync-<Platform>HostClock` that returns `@{ Succeeded; Message }`
   — without it the platform is gated on its clock but cannot repair
   it, and every drifted run stops at the gate.
4. Add the matching `HostType` token to
   [`Test.HostDetection`](../test/modules/Test.HostDetection.psm1)'s
   `Get-HostType` discovery so the new platform is detectable.
5. Provide a host driver under
   `host/<short>/modules/Yuruna.Host.psm1`
   matching the `Yuruna.Host` contract (`New-VM`, `Start-VM`,
   `Stop-VM`, `Get-VM`, `Remove-VM`, `Get-VMState`, ...).
6. The startup capability matrix picks the new entry up
   automatically.

## Related

- [Component registry login](component-registry.md) — same eviction-safe global-anchor pattern, hand-rolled in `automation/Yuruna.CredentialProvider.psm1` rather than on `New-YurunaRegistry`.
- [Host I/O registry](host-io.md) — the older two-level registry that established the pattern.
- [macOS host](host-macos.md), [Hyper-V host](host-hyperv.md) — per-platform deep dives.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.26

Back to [Yuruna](../README.md)
