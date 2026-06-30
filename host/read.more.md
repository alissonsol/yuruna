# Hosts — Nerd-Level Details

The crisp version lives in [Hosts — ...](README.md); this file holds the
detail on macOS TCC grants, VM resizing, and IP discovery.

## macOS TCC grants

The harness needs **both** TCC (Transparency, Consent, and Control)
permissions on macOS, granted to the terminal app at
**System Settings → Privacy & Security**:

- **Accessibility** — keystroke injection to UTM VMs.
- **Screen Recording** — window enumeration
  (`CGWindowListCopyWindowInfo` returns titles only to callers holding
  this grant) and per-window capture. Without it,
  `tapOn` loops on "UTM window for `<vm>` not found".

`Enable-TestAutomation.ps1` fires the consent dialog for each, but TCC
forbids automating the toggle itself. Dismissed a dialog? Toggle
manually, then **fully quit and relaunch the terminal** — TCC grants
don't apply to the running process.

## VM sizing and connectivity

Every VM is **16 GB RAM, 4 vCPU, 512 GB disk (dynamic/thin)**. Change
for **new VMs**: edit `New-VM.ps1` (Hyper-V: replace `16384MB`; UTM:
replace `__MEMORY_SIZE__`).

Existing VMs:

```
# Hyper-V (stop first):
Stop-VM -Name "<vm>" -Force
Set-VM  -Name "<vm>" -MemoryStartupBytes 32768MB -MemoryMinimumBytes 32768MB -MemoryMaximumBytes 32768MB
Start-VM -Name "<vm>"
```

UTM: VM settings → **System** → **Memory**.

Find the guest IP:

```
# Hyper-V:
Get-VM -Name "<vm>" | Select-Object -ExpandProperty NetworkAdapters | Select IPAddresses
```

```
# UTM console shows `eth0: <ip>` at the login prompt; or
awk -F'[ =]' '/name=<vm>/{f=1} f && /ip_address/{print $NF; exit}' /var/db/dhcpd_leases
```

Then `ssh <user>@<ip>` (Linux) or `mstsc /v:<ip>` / `ssh User@<ip>`
(Windows).

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.30

Back to [Yuruna](../README.md)
