<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42630144-53bf-4e35-a4c0-971c1bcc65a0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna lab storage smb share teardown reclaim disk
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Stop this machine from serving its own pool and stash shares: withdraw the
    SMB shares, delete the storage accounts, and drop the loopback exemptions
    and aliases -- then report the disk the DATA still holds and print the one
    command that reclaims it.

.DESCRIPTION
    The inverse of New-LocalLabStorage.ps1, for a machine that has joined a lab
    and now mounts the lab's storage instead of its own. Everything that made
    this machine a storage SERVER comes down; nothing that it stored does.

    That split is deliberate and is the whole design of this script. The folders
    under the storage root hold finished cycle archives, stash artifacts, the lab
    vault, and the pool-intent repository -- content whose only copy may be here,
    and which no automated rule can judge. So the bytes are reported, never
    deleted: sizes per folder, what each one holds, and the exact command for
    the operator to run once they have decided. Everything else -- the share
    definitions, the accounts scoped to them, the Windows loopback exemption,
    the hosts-file aliases -- is machine configuration that is wrong the moment
    this host stops serving, and that comes down without asking beyond one
    confirmation.

    Leaving the accounts behind is not the safe option it looks like. The lab's
    NAS has accounts with the SAME names (yuruna-pool, yuruna-stash) and the
    vault now holds the NAS's passwords for them; a local account of that name
    that no longer matches is a credential an operator can spend a long time
    believing is the one being rejected.

    Idempotent. A machine that never served its own storage, or one already
    cleared, reports 'absent' for every step and changes nothing.

    Run it AFTER the conversion, not before: test/pool/Convert-ToPoolWorker.ps1 needs
    the lab's mounts working, and this script's alias removal is scoped by the
    post-conversion configuration. Convert-ToPoolWorker prints the invitation to
    run this as its closing step.

.PARAMETER Root
    Storage root to report on. Omit it and the root is derived from the share
    table -- the directory each published share resolves to, whose parent is the
    root New-LocalLabStorage built. Pass it when the shares are already gone and
    the report is all that is wanted.

.PARAMETER KeepAccount
    Withdraw the shares but leave the local storage accounts in place. For a
    machine where something outside Yuruna authenticates as them.

.PARAMETER ReportOnly
    Change nothing. Print what would come down and what the data holds. The
    honest first run.

.PARAMETER Force
    Skip this script's own confirmation. The operating system may still prompt
    (UAC consent, sudo password).

.EXAMPLE
    pwsh test/lab/Clear-LocalLabStorage.ps1 -ReportOnly
    # What this machine still serves, and what the storage root holds. Safe.

.EXAMPLE
    pwsh test/lab/Clear-LocalLabStorage.ps1
    # Withdraw the shares and accounts; report the data and how to reclaim it.

.NOTES
    Requires Administrator (Windows) or sudo (macOS / Ubuntu) for the removal
    steps. -ReportOnly needs neither on Windows and may need sudo on Linux to
    read the Samba share table.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)][string]$Root,
    [switch]$KeepAccount,
    [switch]$ReportOnly,
    [switch]$Force
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# Honor the caller's logLevel, published as $env:YURUNA_LOG_LEVEL by whatever
# entry point started this script. After the line above on purpose: an explicit
# level is the operator's choice and replaces this script's own default. See
# docs/loglevels.md.
Import-Module (Join-Path $PSScriptRoot '../modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv
$InformationPreference = $global:InformationPreference
# The per-OS steps probe the host with commands whose non-zero exit is the
# answer, not a failure. Pinned so an ambient preference cannot turn those into
# terminating errors.
$PSNativeCommandUseErrorActionPreference = $false

# --- REGION: Lab-wide constants
# The same values New-LocalLabStorage.ps1 builds from. They have to agree with
# it, tier for tier: this script withdraws what that one publishes.
$PoolAccount  = 'yuruna-pool'
$StashAccount = 'yuruna-stash'
$PoolServer   = 'ypool-nas'
$StashServer  = 'ystash-nas'
$PoolShare    = 'yuruna.pool'
$StashShare   = 'yuruna.stash'

# $WhatIfPreference is suppressed across the imports and restored immediately
# after: module-level state built under ShouldProcess (New-YurunaRegistry's
# Set-Variable, the alias registrations) silently becomes a no-op when a dry run
# inherits the switch, and the module then fails on its own uninitialized state.
# Only the imports are covered; every gate this script owns still honors it.
$PreviousWhatIf = $WhatIfPreference
try {
    $WhatIfPreference = $false
    Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force
    $paths = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
    Import-Module (Join-Path $paths.ModulesDir 'Test.LocalLabStorage.psm1') -Global -Force
    Import-Module (Join-Path $paths.ModulesDir 'Test.PoolWorker.psm1')      -Global -Force -DisableNameChecking
    Import-Module (Join-Path $paths.RepoRoot 'automation/Yuruna.Common.psm1') -Global -Force -DisableNameChecking
} finally {
    $WhatIfPreference = $PreviousWhatIf
}

$platform = Get-LocalLabStoragePlatform

function Write-ClearStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][string]$Title)
    Write-Information '' -InformationAction Continue
    Write-Information "[$Number] $Title" -InformationAction Continue
}

# --- REGION: What this machine still serves
# Asked of the OS share table rather than of test.config.yml, for the reason
# Get-LocalLabStorageServedPath exists: the config a machine carries for a NAS is
# identical in every key to the config for shares served here, so only the share
# table can tell them apart -- and after a conversion the config names the NAS,
# which would make a config-driven answer say "nothing local" on a machine still
# serving both shares.
Write-ClearStep -Number 1 -Title 'What this machine publishes'
# The probes ask questions and change nothing, so -WhatIf is suppressed across
# them. It has to be suppressed HERE rather than inside the module: preference
# propagation follows the invocation chain, not the module's scope chain, so an
# assignment in the callee is invisible to the cmdlet it wraps. Without this, the
# first Get-SmbShare autoloads the SmbShare module and its own New-Alias calls
# narrate five "What if: Set Alias" lines into the middle of the report.
$served = [ordered]@{}
$PreviousWhatIf = $WhatIfPreference
try {
    $WhatIfPreference = $false
    foreach ($share in @($PoolShare, $StashShare)) {
        $served[$share] = Get-LocalLabStorageSharePath -ShareName $share -Platform $platform
    }
} finally {
    $WhatIfPreference = $PreviousWhatIf
}
foreach ($share in @($PoolShare, $StashShare)) {
    if ($served[$share]) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_247d842524300420' -Arguments @{ share = "$share"; share2 = "$($served[$share])" }) -InformationAction Continue
    } else {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_db2bc1a9363cb568' -Arguments @{ share = "$share" }) -InformationAction Continue
    }
}
$publishedCount = @($served.Values | Where-Object { $_ }).Count

# --- REGION: The storage root and what it holds
# Derived from the share table when the operator did not name one, because a
# recorded root is a second source of truth that drifts from the share it claims
# to describe. A machine whose shares are already withdrawn has nothing to derive
# from, which is exactly when -Root is worth passing.
Write-ClearStep -Number 2 -Title 'Storage root and the data it holds'
if ([string]::IsNullOrWhiteSpace($Root)) {
    foreach ($pair in @(@{ Share = $PoolShare; Server = $PoolServer }, @{ Share = $StashShare; Server = $StashServer })) {
        $networkPath = if ($platform -eq 'windows') { "\\$($pair.Server)\$($pair.Share)" } else { "//$($pair.Server)/$($pair.Share)" }
        $candidate = Get-LocalLabStorageRootFromShare -NetworkPath $networkPath -Platform $platform
        if ($candidate) { $Root = $candidate; break }
    }
}
$reports = @()
if ([string]::IsNullOrWhiteSpace($Root)) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_2ca8b0421554c457') -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_10960fa702effabc') -InformationAction Continue
} else {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_102bce84c0fe2170' -Arguments @{ root = "$Root" }) -InformationAction Continue
    $sep = if ($platform -eq 'windows') { '\' } else { '/' }
    foreach ($folder in @($PoolShare, $StashShare)) {
        $report = Get-LocalLabStorageFolderReport -Path "$($Root.TrimEnd('\', '/'))$sep$folder"
        $reports += $report
        if ($report.Exists) {
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_26b1fc44a88b868a' -FormatValues ($folder, (Format-LocalLabStorageSize -Bytes $report.Bytes), $report.FileCount) -FormatBindings @{ folder = '0,-14'; bytes = '1,10'; fileCount = '2:N0' }) -InformationAction Continue
        } else {
            Write-Information ("  {0,-14} {1}" -f $folder, 'not present') -InformationAction Continue
        }
    }
    $totalBytes = [long]0
    foreach ($r in $reports) { $totalBytes += $r.Bytes }
    if ($totalBytes -gt 0) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_a37529a49333311d' -Arguments @{ totalBytes = "$(Format-LocalLabStorageSize -Bytes $totalBytes)" }) -InformationAction Continue
    }
}

if ($ReportOnly) {
    Write-Information '' -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_68995e34c2b39bba') -InformationAction Continue
    exit 0
}

# --- REGION: Consent
# One question, ahead of every change, naming what comes down AND what does not.
# The second half is the load-bearing half: an operator who believes this deletes
# their cycle archives will decline a script that was never going to.
if (-not $Force -and -not $WhatIfPreference) {
    if (-not (Test-YurunaCanPrompt)) {
        Write-Error (Format-YurunaOperatorMessage -Key 'runner.operator_c447c852d17ccf2c')
        exit 1
    }
    Write-Information '' -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_0e6b41a9acea21ce') -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_a08b0dfba775c345' -Arguments @{ poolShare = "$PoolShare"; stashShare = "$StashShare" }) -InformationAction Continue
    if (-not $KeepAccount) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_be6b3e41a035805e' -Arguments @{ poolAccount = "$PoolAccount"; stashAccount = "$StashAccount" }) -InformationAction Continue
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_a01609a1cf43f19f' -Arguments @{ poolServer = "$PoolServer"; stashServer = "$StashServer" }) -InformationAction Continue
    Write-Information '' -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_33be063a6dbeb4de') -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_5a5cc38a18508944') -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_53f55e23f4d19657') -InformationAction Continue
    Write-Information '' -InformationAction Continue
    $answer = (Read-Host 'Proceed? [y/N]').Trim()
    if ($answer -notmatch '^(y|yes)$') {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_2b91fa5b6a130260') -InformationAction Continue
        exit 0
    }
}

# --- REGION: Withdraw the shares
# Before the accounts. Deleting the account a live share is scoped to leaves a
# share nobody can reach, which reads as a broken mount rather than as a
# finished teardown.
Write-ClearStep -Number 3 -Title 'Withdraw the SMB shares'
$shareResult = Remove-LocalLabStorageShare -ShareName @($PoolShare, $StashShare)
foreach ($name in @($PoolShare, $StashShare)) {
    $state = if ($shareResult.Contains($name)) { $shareResult[$name] } else { 'absent' }
    Write-Information "  $name -> $state" -InformationAction Continue
}

# --- REGION: Delete the storage accounts
Write-ClearStep -Number 4 -Title 'Local storage accounts'
if ($KeepAccount) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_5186836962e30a5a') -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_4a30b7a4236eecee') -InformationAction Continue
} else {
    foreach ($account in @($PoolAccount, $StashAccount)) {
        $state = Remove-LocalLabStorageAccount -Name $account
        Write-Information "  $account -> $state" -InformationAction Continue
    }
}

# --- REGION: Loopback exemption and aliases
# The aliases go only when they still point at THIS machine. After a conversion
# the sync has usually repointed them at the lab's NAS -- same name, different
# address -- and dropping one then would leave the mount with a name nothing
# resolves. Get-PoolWorkerAliasPlan owns that rule; here the configured-server
# list is empty on purpose, so a name that resolves off-box is reported as
# someone else's and kept either way.
Write-ClearStep -Number 5 -Title 'Loopback exemption and hosts aliases'
$exemption = Remove-LocalLabStorageLoopbackException -Name @($PoolServer, $StashServer)
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_763a5e41017336a8' -Arguments @{ exemption = "$exemption" }) -InformationAction Continue

$resolution = @{}
foreach ($name in @($PoolServer, $StashServer)) {
    $address = ''
    try {
        $addrs = @([System.Net.Dns]::GetHostAddresses($name))
        $pick  = $addrs | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        if (-not $pick) { $pick = $addrs | Select-Object -First 1 }
        if ($pick) { $address = $pick.ToString() }
    } catch {
        Write-Verbose "resolving '$name': $($_.Exception.Message)"
    }
    $resolution[$name] = $address
}
$aliasPlan = Get-PoolWorkerAliasPlan -CandidateName @($PoolServer, $StashServer) -ConfiguredServer @() -Resolution $resolution
foreach ($outcome in @(Remove-PoolWorkerAlias -RepoRoot $paths.RepoRoot -Plan $aliasPlan)) {
    Write-Information "  $($outcome.Name) -> $($outcome.Action) ($($outcome.Message))" -InformationAction Continue
}

# --- REGION: How to reclaim the disk
# The closing output is the deliverable for the decision this script refuses to
# make. Both platform spellings are never printed -- one command, for the machine
# it is running on, so it can be pasted rather than adapted.
Write-ClearStep -Number 6 -Title 'Reclaiming the disk'
$totalBytes = [long]0
foreach ($r in $reports) { $totalBytes += $r.Bytes }
if (-not $Root -or $totalBytes -eq 0) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_8704c7292e596735') -InformationAction Continue
} else {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_7d8a4cb8b83d5194' -Arguments @{ totalBytes = "$(Format-LocalLabStorageSize -Bytes $totalBytes)" }) -InformationAction Continue
    Write-Information "    $Root" -InformationAction Continue
    Write-Information '' -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_c852b4aa29c7d4e3') -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_d9c7d7673104508b') -InformationAction Continue
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_488c8abbe599cfff') -InformationAction Continue
    Write-Information '' -InformationAction Continue
    foreach ($r in $reports) {
        if (-not $r.Exists -or $r.Bytes -eq 0) { continue }
        $size = Format-LocalLabStorageSize -Bytes $r.Bytes
        if ($platform -eq 'windows') {
            Write-Information "    Remove-Item -LiteralPath '$($r.Path)' -Recurse -Force   # $size" -InformationAction Continue
        } else {
            Write-Information "    sudo rm -rf '$($r.Path)'   # $size" -InformationAction Continue
        }
    }
}

Write-Information '' -InformationAction Continue
if ($publishedCount -eq 0) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_7c4827b6128f6453') -InformationAction Continue
} else {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_f7abf3e2e6a0aa21') -InformationAction Continue
}
exit 0

# Copyright (c) 2019-2026 by Alisson Sol et al.
