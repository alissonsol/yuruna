<#PSScriptInfo
.VERSION 2026.06.30
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456755
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7
#requires -RunAsAdministrator

<#
.SYNOPSIS
    Prepares the Windows Hyper-V host to run yuruna automated VM tests.

.DESCRIPTION
    Configures host-side settings needed for unattended, long-running test
    runs against Hyper-V guest VMs:
      * starts the Hyper-V Virtual Machine Management service (vmms)
      * display timeout (AC + DC) -> Never
      * machine inactivity lock -> disabled
      * lock screen on resume -> disabled
      * inbound ICMPv4 echo allowed (guest VMs + LAN can ping the host)
      * inbound TCP on the status-service port allowed (LAN can see status)
      * display scale / text scale -> 100% -- only when YURUNA_VIRTUAL_DISPLAY
        is set (prevents Tesseract OCR failures on VM screenshots caused by
        HiDPI up-scaling on fresh Win11 laptops)
    Requires Administrator elevation. Idempotent -- safe to re-run.

    The opt-in virtual display (checksum-verified usbmmidd_v2) that keeps
    DWM painting the Hyper-V synthetic GPU when the physical monitor comes and
    goes is NOT attached here: it is a per-cycle surface attached at the start
    of every test cycle when YURUNA_VIRTUAL_DISPLAY is set (and torn down by
    Remove-TestVMFiles), because a KVM switch can drop the monitor mid-run, so
    the census must be re-evaluated each cycle rather than once at enable time.
    See docs/host-hyperv.md.

    Run this before Invoke-TestRunner.ps1 when Assert-HostConditionSet
    reports that display timeout or lock screen settings will interfere
    with test runs. If the scale reset fires on a machine that was at
    125% or 150%, sign out and back in (or reboot) before the next run
    so the compositor picks up the new DPI -- OCR otherwise still sees
    the old scale.

.PARAMETER WhatIf
    Shows what would change without applying any settings.

.EXAMPLE
    .\Enable-TestAutomation.ps1
    .\Enable-TestAutomation.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param()

$ErrorActionPreference = "Stop"
# Surface the module's action-taken messages (Set-WindowsHostConditionSet
# reports each setting via Write-Information). Without Continue, the
# display-scale + screen-lock + display-timeout decisions print nothing
# and the operator can't tell what changed -- contradicting the script's
# own header which promises to "inform" of each action.
$InformationPreference = 'Continue'
# Shared bootstrap (Test.HostContract import + powershell-yaml +
# PSScriptAnalyzer install) lives in automation/Yuruna.HostSetup.psm1.
# Rationale + ordering are documented there.
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.HostSetup.psm1') -Force
Initialize-HostSetupModule -RepoRoot $RepoRoot -BoundParameters $PSBoundParameters

Set-WindowsHostConditionSet @PSBoundParameters

# -- networkStorage pool host-identity setup + reimage reclaim (interactive) ---------
# Offer to configure networkStorage pool (NAS replication) and, on a host with no local
# pool identity, scan the NAS registry to reclaim a prior uuid after a reimage.
# Self-skips cleanly when run non-interactively or under -WhatIf. The orchestrator
# loads its own sibling dependencies (config/vault/mount). See docs/pool-storage.md.
if (-not $WhatIfPreference) {
    Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostIdentity.psm1') -Force
    Invoke-PoolStorageSetupAndReclaim -RepoRoot $RepoRoot
}

# Closing guidance: the virtual display is opt-in (see header). On a host that
# runs tests without a connected monitor -- a headless box, a closed laptop
# lid, or a KVM switch that can yank the physical display mid-run -- DWM stops
# painting the Hyper-V synthetic GPU and screen-capture/OCR goes all-black.
# Setting YURUNA_VIRTUAL_DISPLAY makes each cycle attach a virtual display that
# survives the monitor coming and going. It is deliberately NOT set here: it
# changes the host's monitor topology / scaling, so it must stay an explicit
# operator choice. See docs/host-hyperv.md.
# Test-YurunaVirtualDisplayEnabled resolves the live process variable first,
# then the persisted User/Machine scope -- so this reflects what the runner
# will actually do, not just this shell's (possibly stale) process block.
if (Test-YurunaVirtualDisplayEnabled) {
    Write-Information "YURUNA_VIRTUAL_DISPLAY is enabled -- each test cycle will attach a virtual display, so screen-capture/OCR survives running without a connected monitor. To turn it off: [Environment]::SetEnvironmentVariable('YURUNA_VIRTUAL_DISPLAY', `$null, 'Machine'); `$env:YURUNA_VIRTUAL_DISPLAY = `$null"
} else {
    Write-Information @"
YURUNA_VIRTUAL_DISPLAY is not enabled. Leave it off if this host always has a
connected monitor while tests run. If it will operate WITHOUT a connected
display (headless box, closed laptop lid, or a KVM switch that can drop the
monitor mid-run), enable it so each test cycle attaches a virtual display and
screen-capture/OCR doesn't go all-black:

  # persist across sessions (this script runs elevated). The runner reads this
  # scope directly, so it takes effect on the next cycle even when launched from
  # this shell -- though 'dir env:' won't show it until you open a new terminal:
  [Environment]::SetEnvironmentVariable('YURUNA_VIRTUAL_DISPLAY', 'true', 'Machine')

  # or just this shell, for a one-off run (not persisted):
  `$env:YURUNA_VIRTUAL_DISPLAY = 'true'

See docs/host-hyperv.md for what it attaches (checksum-pinned usbmmidd_v2) and the manual fallbacks.
"@
}
