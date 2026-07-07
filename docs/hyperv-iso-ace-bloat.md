# Hyper-V base-image ACL bloat (per-VM ACE accumulation)

## Symptom

`New-VM.ps1` fails when attaching the base install image:

```
Add-VMDvdDrive: Failed to add device 'Virtual CD/DVD Disk'.
Hyper-V Virtual Machine Management service Account does not have permission
to open attachment ... Failed to set security info ...
Error: 'Access is denied.' (0x80070005).
... 'The inherited access control list (ACL) or access control entry (ACE)
could not be built.' ('0x8007053C').
```

It appears suddenly on a host that has run many test cycles, and **persists
even when PowerShell is elevated (Run as Administrator)**.

## Root cause: the ISO's ACL is full, not a permissions problem

The wording is misleading. This is not an elevation problem and not a
"grant the service account access" problem — the file's **DACL has grown
until Windows can no longer add another entry**.

Every time `Add-VMDvdDrive -Path <baseImage>` runs, Hyper-V grants the new
VM read access by **appending an explicit ACE** to the file for that VM's
per-machine virtual account:

- displayed as `NT VIRTUAL MACHINE\<VM-GUID>:(R)` (name form), or
- as a raw SID `S-1-5-83-1-…:(R)` once the VM is gone (both are the same
  `S-1-5-83-1` per-VM account family).

Two facts combine into the failure:

1. **`Remove-VM` never removes that ACE.** Cleanup deletes the VM and its
   per-VM disk, but the grant on the *shared* base image stays.
2. **The base image is downloaded once and reused for every VM.** So those
   ACEs accumulate — one per VM ever created — without bound.

A Windows security descriptor's DACL is capped at **~64 KB**. Once the base
image's DACL nears that ceiling, `SetNamedSecurityInfo` can no longer build
a larger ACL to add the next VM's ACE → **`0x8007053C`
(ERROR_INVALID_INHERITANCE_ACL)**. Because the new VM's ACE never gets
written, the VM worker account can't open the file → **`0x80070005`
(Access denied)**.

### Why elevation is irrelevant

Your admin token authorizes *you* to call `Add-VMDvdDrive`. The operations
that fail are (1) Hyper-V/VMMS writing the new ACE into the file and (2) the
VM's virtual account (`NT VIRTUAL MACHINE\<guid>`) opening the file — both
gated by the **file's ACL**, which is full. Elevation can't shrink an
oversized ACL.

### Why only shared base images are affected

| File | Shared? | Accumulates? |
|---|---|---|
| Base install ISO (`…guest.windows.11.iso`, `…ubuntu.server.24/26.iso`) | reused for every VM | **yes** — one ACE per VM, forever |
| Per-VM seed ISO (`seed.iso` in the per-VM folder) | one VM | no — at most one ACE |
| Per-VM disk (`<VMName>.vhdx`) | one VM | no |
| Base VHDX (`…guest.amazon.linux.2023.vhdx`, `…caching-proxy.vhdx`) | copied per-VM, **never attached directly** | no |

A measurement on a working developer host that had run many cycles: the
Windows 11 base ISO already carried **1,412 ACEs** (1,020 raw-SID +
387 name-form per-VM entries) totalling **~56.5 KB / 64 KB**, with **zero**
live VMs on the host. The Linux base ISOs were accumulating the same way.

## Fix

The mitigation is to **prune the per-VM ACEs of VMs that no longer exist**,
keeping live VMs untouched. The shared helper
`Remove-OrphanedVMFileAccess` (in
[host/windows.hyper-v/modules/Yuruna.Host.psm1](../host/windows.hyper-v/modules/Yuruna.Host.psm1))
does this: it builds the SID set of currently-existing VMs, then removes
every non-inherited `S-1-5-83-1-*` ACE that isn't in that set, and writes the
trimmed descriptor with `Set-Acl`. Writing a *smaller* descriptor succeeds
even when the on-disk ACL is already at the limit, so the helper recovers a
host that has already failed. It preserves inherited ACEs, admin/SYSTEM, the
all-VMs group (`S-1-5-83-0`), capability SIDs, and live VMs' own ACEs — so it
is safe to run while other VMs are using the file (the multi-VM pool case).
If it cannot enumerate/translate the live VMs it aborts rather than risk
removing a live VM's access.

Two call sites keep the DACL bounded:

- **(A) Before each attach** — `New-VM.ps1` for `guest.windows.11`,
  `guest.ubuntu.server.24`, and `guest.ubuntu.server.26` prunes the base
  image immediately before `Add-VMDvdDrive`. By then the VM being created is
  live, so its (not-yet-added) ACE is safe; all earlier VMs' ACEs are gone,
  bounding the DACL to roughly *(live VMs + 1)*.
- **(B) During cleanup** — `Remove-OrphanedVMFiles.ps1` prunes every kept
  base image on each run (no-op on the base VHDX images). This reclaims ACL
  space even when no VM is being created.

### Manual remediation (already-failing host)

Run elevated. Either prune just the dead VMs (preferred — keeps live VMs):

```powershell
Import-Module .\host\windows.hyper-v\modules\Yuruna.Host.psm1 -Force
Remove-OrphanedVMFileAccess -Path "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\host.windows.hyper-v.guest.windows.11.iso"
```

…or, if no VM currently needs the image, reset its ACL entirely (succeeds
even at the limit, because it *replaces* rather than grows the descriptor):

```powershell
icacls "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\host.windows.hyper-v.guest.windows.11.iso" /reset
```

The next `Add-VMDvdDrive` re-adds just the current VM's ACE. Do the same for
the `…ubuntu.server.24/26.iso` base images.

### Diagnostics

```powershell
$iso = "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\host.windows.hyper-v.guest.windows.11.iso"
$acl = Get-Acl $iso
$acl.Access.Count                                        # total ACEs
$acl.GetSecurityDescriptorBinaryForm().Length            # bytes — approaching 65535 is the cause
```

## Scope

Hyper-V-specific — it stems from Hyper-V's per-VM virtual-account ACE model.
KVM and macOS/UTM grant guest file access differently and do not accumulate
per-VM ACEs on shared images.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.07

Back to [Yuruna](../README.md)
