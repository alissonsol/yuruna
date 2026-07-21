<#PSScriptInfo
.VERSION 2026.07.20
.GUID 42c43484-d985-4134-91ec-2781371292b3
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guest hostname cloud-init contract pester
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
    Structural Pester guard on the guest-hostname contract: a sequence's
    `variables.hostname` must reach the guest's cloud-init local-hostname.
.DESCRIPTION
    The value crosses four files per guest (planner -> runner -> the
    Invoke-PerGuestNewVm dispatcher -> the per-guest New-VM.ps1), and the
    dispatcher forwards -Hostname only to scripts that DECLARE it, dropping
    it on the Verbose stream otherwise. A guest script that templates a
    hostname but forgets the parameter therefore fails silently: the VM
    builds, and the hostname is just wrong. These guards make that omission
    a test failure instead.

    Every per-guest New-VM.ps1 that substitutes HOSTNAME_PLACEHOLDER must
    declare -Hostname, resolve it against a VM-name fallback, and feed the
    placeholder from that resolved value. Guests with a fixed hostname baked
    into their template (caching-proxy, stash-service) never substitute the
    placeholder and are correctly out of scope.

    Source-text only -- no host driver is imported and no VM is touched.
    Throw-based assertions so the file runs under Pester 3.4 and Pester 5+.
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

# Guest scripts in scope: those that actually template a hostname.
$guestScript = @(
    Get-ChildItem -Path (Join-Path $repoRoot 'host') -Filter 'New-VM.ps1' -Recurse -File |
        Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match 'HOSTNAME_PLACEHOLDER' }
)
$guestCase = @($guestScript | ForEach-Object { @{ name = (Split-Path -Leaf $_.Directory.FullName); path = $_.FullName } })

# Read at script scope, not inside Describe: under Pester 5 a Describe body runs
# in the discovery pass only, so a variable set there is gone by the time an It
# body executes.
$provisionSrc = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'host/modules/Yuruna.HostProvision.psm1')
$engineSrc    = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'test/modules/Invoke-Sequence.psm1')

# Every sequence the framework ships. Project sequences live in a separate
# repo that need not be cloned here, so they are scanned only when present.
$seqFile = @(
    Get-ChildItem -Path (Join-Path $repoRoot 'test/sequences') -Filter '*.yml' -Recurse -File
    $projDir = Join-Path $repoRoot 'project'
    if (Test-Path -LiteralPath $projDir) {
        Get-ChildItem -Path $projDir -Filter '*.yml' -Recurse -File |
            Where-Object { $_.FullName -match '[\\/]test[\\/](gui|ssh)[\\/]' }
    }
)
$seqCase = @($seqFile | ForEach-Object { @{ name = $_.Name; path = $_.FullName } })

Describe 'guest-hostname -- variables.hostname reaches cloud-init local-hostname' {
    It 'finds the templating guest scripts at all (fixture sanity)' {
        Assert-True ($guestScript.Count -ge 3) "expected several hostname-templating guest scripts, found $($guestScript.Count)"
    }

    It 'declares -Hostname so the dispatcher forwards it: <name>' -TestCases $guestCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        Assert-True ($src -match '(?m)^\s*\[string\]\$Hostname\s*=\s*''''') `
            "$name templates a hostname but has no [string]`$Hostname = '' parameter; Invoke-PerGuestNewVm would drop the cascade to Verbose"
    }

    It 'falls back to the VM name when -Hostname is empty: <name>' -TestCases $guestCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        Assert-True ($src -match [regex]::Escape('$GuestHostname = if ($Hostname) { $Hostname } else { $VMName }')) `
            "$name must keep the VM-name default so callers that pin nothing are unaffected"
    }

    It 'feeds HOSTNAME_PLACEHOLDER from the resolved value, not the VM name: <name>' -TestCases $guestCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        $fromVmName = [regex]::Matches($src, 'HOSTNAME_PLACEHOLDER''?\s*(?:,|=)\s*\$VMName')
        Assert-True ($fromVmName.Count -eq 0) `
            "$name still substitutes HOSTNAME_PLACEHOLDER from `$VMName, so a pinned hostname is ignored"
        Assert-True ($src -match 'HOSTNAME_PLACEHOLDER''?\s*(?:,|=)\s*\$GuestHostname') `
            "$name must substitute HOSTNAME_PLACEHOLDER from `$GuestHostname"
    }
}

Describe 'guest-hostname -- instance identity stays pinned to the VM name' {
    # cloud-init re-runs per-instance modules when instance-id changes, and two
    # VMs may legitimately share a pinned hostname. Keying instance-id off the
    # hostname would collide them.
    $metaData = @(
        Get-ChildItem -Path (Join-Path $repoRoot 'host/vmconfig') -Filter '*.meta-data' -File |
            Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match 'HOSTNAME_PLACEHOLDER' }
    )
    $metaCase = @($metaData | ForEach-Object { @{ name = $_.Name; path = $_.FullName } })

    It 'templates instance-id separately from local-hostname: <name>' -TestCases $metaCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        Assert-True ($src -match '(?m)^instance-id:\s*INSTANCE_ID_PLACEHOLDER\s*$') `
            "$name must key instance-id off INSTANCE_ID_PLACEHOLDER, not the hostname"
        Assert-True ($src -match '(?m)^local-hostname:\s*HOSTNAME_PLACEHOLDER\s*$') `
            "$name must still template local-hostname"
    }
}

Describe 'guest-hostname -- the dispatcher forwards under the declare-or-drop rule' {
    It 'introspects the target script for a -Hostname parameter' {
        Assert-True ($provisionSrc -match [regex]::Escape("ContainsKey('Hostname')")) `
            'Invoke-PerGuestNewVm must probe for -Hostname before forwarding'
    }
    It 'appends -Hostname to the child argument list' {
        Assert-True ($provisionSrc -match [regex]::Escape("@('-Hostname', `$Hostname)")) `
            'a probed-and-present -Hostname must actually reach the child script'
    }
}

Describe 'guest-hostname -- ${hostname} resolves in every sequence, pinned or not' {
    # A sequence matching the shell prompt has to name the guest the way the
    # guest names itself. ${vmName} stops being that the moment anything in the
    # chain pins a hostname -- and the sequence that breaks is often NOT the one
    # that pinned it, but a prereq further down the chain that never mentions
    # hostname at all. Seeding ${hostname} as a built-in that falls back to the
    # VM name is what makes the prompt match correct in both cases.
    It 'seeds ${hostname} as a built-in defaulting to the VM name' {
        Assert-True ($engineSrc -match [regex]::Escape('"hostname" = $VMName')) `
            'Invoke-Sequence must seed a ${hostname} built-in, or an unpinned sequence matching on ${hostname} sees an unresolved literal'
    }

    It 'never matches the shell prompt on the VM name: <name>' -TestCases $seqCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        Assert-True ($src -notmatch [regex]::Escape('${username}@${vmName}')) `
            "$name matches the prompt on the VM name; a pinned hostname in ANY sequence of its chain makes that assertion time out"
    }
}
