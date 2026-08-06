<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42f3b8c1-6d29-4e07-b514-8a3c7d02e9f4
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
    accepted mainly so the behaviour can be exercised against a copy.

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

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = Resolve-Path (Join-Path -Path $ScriptDir -ChildPath '..' -AdditionalChildPath '..')
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking

if (-not $IsMacOS) {
    Write-Error "This is the macOS lease store (bootpd). Nothing to do on this platform."
    exit 1
}
if (-not (Test-Path -LiteralPath $LeasePath)) {
    Write-Output "No lease file at '$LeasePath' -- nothing to prune."
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
        is already in the neighbour table, so it is recognised without a packet
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
    Write-Output "Kept despite a newer block of the same name (still answering):"
    foreach ($v in $vetoed) { Write-Output "  $($v.Name): $($v.IpAddress)" }
}
if ($stale.Count -eq 0) {
    Write-Output "No superseded lease blocks to remove in '$LeasePath'."
    if ($Name.Count -gt 0) { Write-Output "  (scope: $($Name -join ', '))" }
    exit 0
}

Write-Output ""
Write-Output "Superseded lease blocks in '$LeasePath':"
foreach ($group in ($stale | Group-Object -Property Name | Sort-Object Name)) {
    $addresses = @($group.Group | Sort-Object -Property LeaseExpiry -Descending |
        ForEach-Object { "$($_.IpAddress) (expires $([DateTimeOffset]::FromUnixTimeSeconds($_.LeaseExpiry).LocalDateTime.ToString('MM-dd HH:mm')))" })
    Write-Output "  $($group.Name): $($addresses -join ', ')"
}
Write-Output ""
Write-Output "  $($stale.Count) block(s) to remove. The live block of each name is kept."
if (-not $SkipReachabilityCheck) { Write-Output "  Addresses that answered ARP or ping were already excluded." }
Write-Output ""

if (-not $PSCmdlet.ShouldProcess($LeasePath, "Remove $($stale.Count) superseded lease block(s)")) { exit 0 }

$newText = Remove-DhcpLeaseBlockText -LeaseText $leaseText -Block $stale
if ($newText -eq $leaseText) {
    Write-Warning "Nothing changed -- the selected blocks were not found in the text that was read."
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
    Write-Warning "'$LeasePath' changed while this ran (the DHCP server issued or renewed a lease). Nothing was written -- re-run to prune against the current file."
    exit 1
}

$result = Invoke-YurunaSudo -Argument @('tee', $LeasePath) -InputText $newText -TolerateBlocked
if ($result.Blocked) {
    Write-Warning "sudo refused, so '$LeasePath' was not modified: $($result.Output.Trim())"
    exit 1
}
if ($result.ExitCode -ne 0) {
    Write-Error "Writing '$LeasePath' failed (exit $($result.ExitCode)): $($result.Output.Trim())"
    exit 1
}

$remaining = @(Select-StaleDhcpLeaseBlock -LeaseText (Get-Content -Raw -LiteralPath $LeasePath) -Name $Name -InUseVerdict { 'unknown' })
Write-Output ""
Write-Output "Removed $($stale.Count) superseded lease block(s)."
if ($remaining.Count -gt 0) {
    Write-Warning "$($remaining.Count) superseded block(s) still present -- they were kept because their address answered, or the file moved under the write."
}
Write-Output ""
