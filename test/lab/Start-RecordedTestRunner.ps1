<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42f3e7ae-0558-4c71-a433-d1496401ace5
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna runner install upgrade
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -Version 7

<#
.SYNOPSIS
    Explicitly start an installer-stopped runner with its captured options.
.DESCRIPTION
    Run locally after setup. The snapshot remains private and recoverable.
    An existing runner is refused; macOS requires the owner's Aqua session.
    This action never changes the clean-exit safeguard used by host refresh.
.PARAMETER SnapshotPath
    Private state.json path printed by the installer before it stopped processes.
.PARAMETER TimeoutSeconds
    Maximum wait for the new runner to own its single-instance record.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SnapshotPath,
    [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../modules/Test.SingleInstance.psm1') -DisableNameChecking
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if ($PSCmdlet.ShouldProcess($root, 'Start runner with the preserved installer options')) {
    Start-YurunaCapturedRunner -RepoRoot $root -SnapshotPath $SnapshotPath -TimeoutSeconds $TimeoutSeconds -Confirm:$false
}
