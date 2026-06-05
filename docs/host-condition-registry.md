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

Before the registry pattern landed, the facade carried an `if/elseif`
chain on `$HostType` inside `Assert-HostConditionSet`, and
[`Test.HostDetection`](../test/modules/Test.HostDetection.psm1) had a
parallel `switch ($HostType)` in `Test-HostRequirement`. Adding a new
host needed two edits in two files; today it is one
`Register-HostConditionProvider` call.

## Public surface

| Function | Used by |
|---|---|
| `Register-HostConditionProvider -HostType -Set -Assert -AssertMinimum -RequiresElevation` | Facade loader; external host plugins |
| `Get-HostConditionProvider -HostType` | Dispatchers; introspection |
| `Get-HostConditionProviderMatrix` | Startup capability matrix |
| `Clear-HostConditionProvider` | Tests only |
| `Assert-HostConditionSet -HostType` | Outer runner per-cycle gate |
| `Test-ElevationRequired -HostType` | Cleanup helpers ([`Test.HostDetection`](../test/modules/Test.HostDetection.psm1)) |
| `Test-HostRequirement -HostType [-Quiet]` | One-off operator helpers ([`Test.HostDetection`](../test/modules/Test.HostDetection.psm1)) |

## Provider record shape

Each registration carries a five-field ordered dict:

```
@{
    HostType          = 'host.windows.hyper-v'
    Set               = { param([string]$HostType) ... }
    Assert            = { param([string]$HostType) ... [bool] }
    AssertMinimum     = { param() ... [bool] }
    RequiresElevation = $true   # consumed by Test-ElevationRequired
}
```

`Set` and `Assert` are paired; both take `-HostType` and may be
called multiple times per cycle. `AssertMinimum` is lighter than
`Assert` (no display-timeout / screen-lock / TCC-grant checks) and
exists for cleanup helpers that legitimately run during interactive
maintenance.

## Three platforms today

| HostType | RequiresElevation | What `Assert` gates on |
|---|---|---|
| `host.windows.hyper-v` | `$true` | Administrator elevation, vmms service, display timeout, lock screen |
| `host.macos.utm` | `$false` | Accessibility + Screen Recording TCC grants, display sleep, screen lock |
| `host.ubuntu.kvm` | `$false` | `/dev/kvm` present, libvirtd active, virsh round-trip, current shell's group set includes `libvirt` |

The Linux `Assert` diagnostic distinguishes "kvm missing" from
"libvirtd down" from "stale group set" from "not in libvirt group at
all" so the operator gets actionable steps, not a generic
"permission denied".

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
   names + `RequiresElevation`.
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

- [Component registry login](component-registry.md) — same `New-YurunaRegistry` primitive, different domain.
- [Host I/O registry](host-io.md) — the older two-level registry that established the pattern.
- [macOS host](host-macos.md), [Hyper-V host](host-hyperv.md) — per-platform deep dives.

Back to [Test harness](test-harness.md) · [Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
