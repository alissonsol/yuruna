# Host I/O registry

Every sequence step that drives the guest GUI (keystrokes, text input,
mouse clicks) goes through a thin dispatcher in
[`Invoke-Sequence.psm1`](../test/modules/Invoke-Sequence.psm1) — which
in turn looks up the current host's backend in a registry exported by
[`test/modules/Test.HostIO.psm1`](../test/modules/Test.HostIO.psm1).

The registry pattern mirrors the OCR provider model
([OCR providers](ocr.md)) and is the seed of the
[capability matrix](capability-matrix.md): every (host, action) pair
is enumerable at startup.

## The public surface

| Function   | Signature                                                          | Used by |
|------------|--------------------------------------------------------------------|---------|
| `Send-Key`   | `-HostType -VMName -KeyName`                                     | sequence engine, `Yuruna.Host\Send-Key` contract |
| `Send-Text`  | `-HostType -VMName -Text -CharDelayMs [-ShellEscape]`            | sequence engine, `Yuruna.Host\Send-Text` contract |
| `Send-Click` | `-HostType -VMName -X -Y [-Capture]`                             | sequence engine, `Yuruna.Host\Send-Click` contract |

Each dispatcher is a five-line `try { Invoke-HostIOAction … } catch
{ Write-Warning; return $false }` wrapper over `Test.HostIO`.

## Why the registry over inline dispatch

The registry centralises the `(HostType, Action)` binding in one
lookup table. Adding a new host or a new action verb is a single
`Register-HostIOProvider` call; nothing in the dispatcher needs to
change. Adding the same host across three separate `if/elseif` chains
(one per action) is a source of "Send-Key works on the new
host but Send-Text was forgotten" drift — the registry makes every
pair enumerable at startup, so the
[capability gate](capability-matrix.md) refuses cycles that reference
an unwired backend rather than failing mid-step. The same pattern
recurs across the workspace: [SequenceAction](handler-schema.md)
(verb registry), [Component registry login](component-registry.md)
and [Host-condition registry](host-condition-registry.md) (provider
matrices), [Remediation dispatcher](remediation.md) (failure-class
handlers). Four of the five share the
[`New-YurunaRegistry`](../test/modules/Test.Registry.psm1) primitive
and surface through `Get-YurunaRegistryDirectory` for autonomous
tooling; the component-login credential-provider registry uses the same
eviction-safe global-anchor pattern but is hand-rolled in
[`automation/Yuruna.CredentialProvider.psm1`](../automation/Yuruna.CredentialProvider.psm1)
(so it is not in `Get-YurunaRegistryDirectory`) — keeping it out of
`test/`, which `New-YurunaRegistry` lives under.

## Backends today

| Host                 | `Send-Key`        | `Send-Text`       | `Send-Click`     |
|----------------------|-------------------|-------------------|------------------|
| `host.windows.hyper-v` | `Send-KeyHyperV` (PS/2 scancodes via WMI Msvm_Keyboard) | `Send-TextHyperV` (per-char scancodes with modifier-reset prefix) | `Send-ClickHyperV` (SendInput) |
| `host.macos.utm`     | VNC first, then AppleScript fallback | VNC first, then JXA/CGEvent | `Send-ClickUtm` (CGEvent in window coords) |
| `host.ubuntu.kvm`    | `Send-KeyKvm` (`virsh send-key`) | `Send-TextKvm` (`virsh send-key` per char) | _(not implemented — KVM guests use SSH after GUI bring-up)_ |

The macOS Send-Key VNC-first / AppleScript-fallback decision lives in
the registered scriptblock, in one place — not a branch repeated across
three dispatchers.

`KeyName` also accepts a modifier chord (`CtrlU`, `CtrlC`) on every
host. A chord is a named key rather than a separate modifier parameter
so the dispatcher, the registry scriptblocks and the three
`Yuruna.Host\Send-Key` facades keep forwarding one string. Chords
resolve from their own `*-Chord` map family: the `*-Named` maps hold a
single code per name and every backend dereferences them as a scalar,
so a chord cannot live there. On macOS a chord takes the CGEvent path
even when AppleScript would serve a plain key — `key code` cannot hold
a modifier down across the base key.

## The registry API

```
Register-HostIOProvider   -HostType -Action -Implementation
Test-HostIOActionAvailable -HostType -Action
Invoke-HostIOAction        -HostType -Action -Arguments
Get-HostIOProviderMatrix   # @{ host.X.Y = @('Send-Key','Send-Text',...) }
Clear-HostIOProvider       # for tests
```

Each `Implementation` is a `param([hashtable]$a)` scriptblock returning
`[bool]`. The dispatcher passes named arguments through the hashtable.

## Adding a new host

1. Implement the per-host backend functions (the actual keystroke
   delivery mechanism — WMI / VNC / virsh / something new).
2. Add a per-host module `test/modules/Test.HostIO.<NewHost>.psm1`
   owning its `Register-HostIOProvider` calls (mirror
   `Test.HostIO.HyperV.psm1` / `Test.HostIO.Utm.psm1` /
   `Test.HostIO.Kvm.psm1`), and add its `Import-Module` line to
   `Invoke-Sequence.psm1`:

   ```powershell
   Register-HostIOProvider -HostType 'host.your.new.host' -Action 'Send-Key' -Implementation {
       param([hashtable]$a)
       return (Send-KeyYourNewHost -VMName $a.VMName -KeyName $a.KeyName)
   }
   # ... and Send-Text, Send-Click as applicable
   ```
3. The startup capability matrix automatically picks up the new
   registration; sequences referencing actions your backend does not
   yet implement will fail the cycle gate with a list of what IS
   available on the host.

## Adding a new action

1. Pick a verb name (`Send-Scroll`, `Send-Drag`, etc.).
2. Implement per supported host.
3. Register each implementation.
4. Register the verb in
   [`Test.SequenceAction`](../test/modules/Test.SequenceAction.psm1)
   with its `-HostIORequirement` so the
   [capability gate](capability-matrix.md) refuses cycles on hosts
   without a backend.
5. Add a dispatcher (`Send-Scroll`, three-line wrapper) and export it
   from `Invoke-Sequence.psm1` so the
   `Yuruna.Host\Send-Scroll` contract can route through it.

## Why the registry uses a global anchor

`Test.HostIO`'s registry table is anchored on
`$global:YurunaHostIOProviders` so `-Force` re-imports of the module
(triggered by sibling-module imports during cycle startup) do not
empty the table. See repo memory
`feedback_module_force_import_evicts_global.md` for the trap that
caught this in development.

The paired provider registries (`Test.ScreenshotProvider`,
`Test.VncProvider`, …) follow the same pattern: each delegates storage
to the shared `Test.Registry` primitive (`New-YurunaRegistry`) so there
is one registry mechanism across the harness and every domain shows up
in the cross-domain introspection directory
(`Get-YurunaRegistryDirectory`/`Summary`), and each reuses a `$global:`
anchor name (`$global:YurunaScreenshotProviders`,
`$global:YurunaVncProviders`, …) as the backing store so registrations
stay cross-module-eviction-safe and survive `-Force` re-imports.

## Backend module layout

[`Test.Transport.psm1`](../test/modules/Test.Transport.psm1) holds the
per-host I/O backends consumed by the registry:

- **Key code maps** — `UTMKeyMap`, `MacCharKeyCodes`, `PS2ScanCodes`,
  `CharScanCodes` (KVM key map lives inside `Get-KvmCharKeyMap`).
- **Cached connections** — `Get-HyperVKeyboard` +
  `script:CachedKb`/`KbVM`; `Connect-VNC` / `Disconnect-VNC` + the
  cached VNC handle.
- **Send-Key backends** — `Send-KeyHyperV` / `Send-KeyVNC` /
  `Send-KeyUTM` / `Send-KeyKvm` / `Send-KeyAXUI`, plus `Send-ChordUTM`
  for the macOS modifier-chord path.
- **Send-Text backends** — `Send-TextHyperV` / `Send-TextVNC` /
  `Send-TextUTM` / `Send-TextKvm` / `Send-TextAXUI`, plus the
  `Test-HardCharsInText` + `ConvertTo-ShellEscapedText` helpers used
  only by `Send-TextUTM`.
- **Send-Click backends** — `Initialize-HyperVMouseType`,
  `Send-ClickHyperV`, `Send-ClickUtm`.
- **Send-ScanCode** — Hyper-V PS/2 scancode-burst primitive.

The public surface is unchanged: `Invoke-Sequence.psm1` exports the
three dispatchers (`Send-Key`, `Send-Text`, `Send-Click`) and routes
them through `Test.HostIO`'s registry; the registered scriptblocks in
the per-host `Test.HostIO.<Host>.psm1` modules call the bare backend names above,
which resolve via the global session table once `Test.Transport` is
imported with `-Global`.

## Transport config reload at module load

`Test.Transport` reads transport-level defaults (`characterDelayMs`,
`vncPort`, …) from `test.config.yml` at module-load time via
`Test.Config` (mtime-cached, so this is cheap even on re-import). The
cycle re-imports modules every cycle so a freshly-committed
`vmCommunication.characterDelayMs` / `vmCommunication.vncPort` takes
effect on the next step rather than requiring a runner restart. This
mirrors the broader live-edit responsiveness contract — an operator
clicking "Stop on failure" in the dashboard at step 5 must abort the
cycle at step 6, not wait for the next cycle.

A per-step throttle collapses repeated `-Force` re-imports to a single
parse. The `Read-TestConfig` mtime check short-circuits the parse when
the file is unchanged, but the function call + `Test-Path` + `Get-Item`
still cost ~1-2 ms each, which compounds across 8+ re-imports per step.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.21

Back to [Yuruna](../README.md)
