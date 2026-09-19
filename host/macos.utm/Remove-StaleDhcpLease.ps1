<#PSScriptInfo
.VERSION 2026.09.18
.GUID 4287fe47-ee43-47e6-b67f-e2fb5baf90c5
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host macos utm dhcp lease cleanup
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

<#
.SYNOPSIS
    Remove superseded blocks from macOS `/var/db/dhcpd_leases` so a guest-name
    lookup has one answer per name instead of several.

.DESCRIPTION
    The macOS shared-NAT DHCP server files every lease under the name the guest
    sends and never prunes. A VM name that gets rebuilt therefore accumulates
    one block per incarnation, because each rebuilt guest presents a fresh
    client identity (systemd derives its DHCP DUID from a machine-id that the
    rebuild regenerates) and so is issued a NEW address rather than the one its
    predecessor held.

    Address discovery falls back to this file keyed on the guest name, and picks
    the largest `lease=` expiry among the matches. That is correct once the live
    guest has taken its lease -- and wrong for the seconds before it does, when
    the only blocks bearing the name belong to guests that no longer exist. The
    address handed back then is syntactically perfect, on-link, and dead.

    This script deletes those superseded blocks. It keeps, always:

      * the largest-expiry block of every name -- the live guest;
      * every name carrying only one block, live or not;
      * any block whose address still answers, whatever its expiry claims.

    So it can be run on a host with guests up: the reachability veto means an
    address in use is never removed, even when the expiry heuristic thinks it
    is stale.

    The file belongs to the DHCP server, which rewrites it whenever a lease
    moves. The read-modify-write is therefore checked against the file's size
    and timestamp before the write lands; a file that changed underneath is
    left alone and the run reports that it should be repeated. A timestamped
    backup is taken first.

.PARAMETER Name
    Restrict to these guest names. Default: every name in the file. The name is
    the guest's own hostname -- the VM name only when no sequence pinned
    `variables.hostname`.

.PARAMETER LeasePath
    Lease file to operate on. Defaults to /var/db/dhcpd_leases; a path is
    accepted mainly so the behavior can be exercised against a copy.

.PARAMETER SkipReachabilityCheck
    Drop the in-use veto and decide on expiry alone. Faster on a file with many
    duplicates, and appropriate only when no guest is running.

.PARAMETER BackupPath
    Where to write the pre-change copy. Defaults to a timestamped file beside
    the runtime dir.

.EXAMPLE
    pwsh host/macos.utm/Remove-StaleDhcpLease.ps1 -WhatIf
    Report what would be removed, change nothing.

.EXAMPLE
    pwsh host/macos.utm/Remove-StaleDhcpLease.ps1 -Name yuruna-stash-service
    Collapse just the stash service's accumulated blocks down to the live one.

.EXAMPLE
    pwsh -Command "& ./host/macos.utm/Remove-StaleDhcpLease.ps1 -Name yuruna-stash-service,yuruna-caching-proxy-service"
    Several names at once. `pwsh -File` cannot be used for this: it passes
    arguments as plain strings, so `-Name a,b` arrives as the single name
    "a,b", which matches nothing and the run reports there is nothing to do.
    -Verbose prints the candidate count, which is how that shows up.

.NOTES
    Needs sudo for the write; reading is unprivileged. Idempotent -- a second
    run finds one block per name and removes nothing.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string[]]$Name = @(),
    [string]$LeasePath = '/var/db/dhcpd_leases',
    [switch]$SkipReachabilityCheck,
    [string]$BackupPath
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Resolve-Path (Join-Path -Path $ScriptDir -ChildPath '..' -AdditionalChildPath '..')
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking

if (-not $IsMacOS) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_808c686d372a1e15')
    exit 1
}
if (-not (Test-Path -LiteralPath $LeasePath)) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_46325258731730bf' -Arguments @{ leasePath = "$LeasePath" })
    exit 0
}

$before     = Get-Item -LiteralPath $LeasePath
$leaseText  = Get-Content -Raw -LiteralPath $LeasePath

function Test-AddressInUse {
    <#
    .SYNOPSIS
        $true when something is using $Address right now.
    .DESCRIPTION
        ARP first, ICMP second. A guest that has talked to this host recently
        is already in the neighbor table, so it is recognized without a packet
        being sent; anything not resolved there gets one ping, because a live
        but quiet guest may simply have aged out.

        Positive evidence only, in both halves. The direction of the mistake is
        what matters: reporting "free" for an address that is in use deletes a
        live guest's lease, while the opposite merely keeps a block that could
        have gone. vmnet pre-populates the whole bridge subnet with unresolved
        entries, so the existence of an ARP row means nothing here -- only a
        resolved hardware address counts.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Address)
    try {
        $entry = (& arp -n $Address 2>&1 | Out-String)
        if ($entry -match '(?i)\bat\s+(([0-9a-f]{1,2}:){5}[0-9a-f]{1,2})\b') { return $true }
    } catch { Write-Debug "arp -n $Address failed: $_" }
    try {
        if (Test-Connection -TargetName $Address -Count 1 -Quiet -TimeoutSeconds 1 -ErrorAction Stop) { return $true }
    } catch { Write-Debug "ping $Address failed: $_" }
    return $false
}

# Candidates first, reachability second, both here rather than handing the
# probe to Select-StaleDhcpLeaseBlock: its -InUseVerdict runs the scriptblock
# across a module boundary, and a veto that silently misfires there would
# either delete a live guest's lease or quietly protect every block. Splitting
# the two keeps the probe running in the scope it was written for, and lets the
# skipped addresses be reported instead of just vanishing from the list.
$candidates = @(Select-StaleDhcpLeaseBlock -LeaseText $leaseText -Name $Name)
Write-Verbose "Read $($leaseText.Length) bytes from '$LeasePath'; $($candidates.Count) block(s) superseded by a newer one of the same name."
$vetoed = @()
if (-not $SkipReachabilityCheck) {
    $kept = foreach ($candidate in $candidates) {
        if (Test-AddressInUse -Address $candidate.IpAddress) {
            $vetoed += $candidate
            Write-Verbose "Keeping $($candidate.IpAddress) for '$($candidate.Name)' -- it answers, so the expiry is not the whole story."
        } else {
            $candidate
        }
    }
    $candidates = @($kept)
}
$stale = @($candidates)

if ($vetoed.Count -gt 0) {
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_f30d82476a4c72f2')
    foreach ($v in $vetoed) { Write-Output "  $($v.Name): $($v.IpAddress)" }
}
if ($stale.Count -eq 0) {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_e6c7788318dbd530' -Arguments @{ leasePath = "$LeasePath" })
    if ($Name.Count -gt 0) { Write-Output "  (scope: $($Name -join ', '))" }
    exit 0
}

Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_8cc02f27922fb519' -Arguments @{ leasePath = "$LeasePath" })
foreach ($group in ($stale | Group-Object -Property Name | Sort-Object Name)) {
    $addresses = @($group.Group | Sort-Object -Property LeaseExpiry -Descending |
        ForEach-Object { "$($_.IpAddress) (expires $([DateTimeOffset]::FromUnixTimeSeconds($_.LeaseExpiry).LocalDateTime.ToString('MM-dd HH:mm')))" })
    Write-Output "  $($group.Name): $($addresses -join ', ')"
}
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_5fad151840eb109b' -Arguments @{ count = "$($stale.Count)" })
if (-not $SkipReachabilityCheck) { Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_7df037e616faba5f') }
Write-Output ""

if (-not $PSCmdlet.ShouldProcess($LeasePath, (Format-YurunaOperatorMessage -Key 'host.operator_52d8339a86ba49b9' -Arguments @{ count = "$($stale.Count)" }))) { exit 0 }

$newText = Remove-DhcpLeaseBlockText -LeaseText $leaseText -Block $stale
if ($newText -eq $leaseText) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4b47d943d3446221')
    exit 0
}

if (-not $BackupPath) {
    $runtimeDir = $env:YURUNA_RUNTIME_DIR
    if ([string]::IsNullOrWhiteSpace($runtimeDir)) { $runtimeDir = Join-Path $RepoRoot 'test/status/runtime' }
    if (-not (Test-Path -LiteralPath $runtimeDir)) { New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null }
    $BackupPath = Join-Path $runtimeDir "dhcpd_leases.$((Get-Date).ToString('yyyyMMdd-HHmmss')).bak"
}
Set-Content -LiteralPath $BackupPath -Value $leaseText -Encoding ascii -NoNewline
Write-Output "  Backup: $BackupPath"

# bootpd owns this file and rewrites it on every lease event. Re-stat rather
# than trusting the copy in memory: a lease issued while the reachability
# probes ran would otherwise be erased by writing back text that predates it.
$after = Get-Item -LiteralPath $LeasePath
if ($after.Length -ne $before.Length -or $after.LastWriteTimeUtc -ne $before.LastWriteTimeUtc) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_e8c93cc811535ed2' -Arguments @{ leasePath = "$LeasePath" })
    exit 1
}

$result = Invoke-YurunaSudo -Argument @('tee', $LeasePath) -InputText $newText -TolerateBlocked
if ($result.Blocked) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_5f275b9c5959dddd' -Arguments @{ leasePath = "$LeasePath"; trim = "$($result.Output.Trim())" })
    exit 1
}
if ($result.ExitCode -ne 0) {
    Write-Error (Format-YurunaOperatorMessage -Key 'exceptions.host_29ec111859986081' -Arguments @{ leasePath = "$LeasePath"; exitCode = "$($result.ExitCode)"; trim = "$($result.Output.Trim())" })
    exit 1
}

$remaining = @(Select-StaleDhcpLeaseBlock -LeaseText (Get-Content -Raw -LiteralPath $LeasePath) -Name $Name -InUseVerdict { 'unknown' })
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_04e3cb54d8a3671c' -Arguments @{ count = "$($stale.Count)" })
if ($remaining.Count -gt 0) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4901e25ce48280cc' -Arguments @{ count = "$($remaining.Count)" })
}
Write-Output ""
