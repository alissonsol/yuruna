<#PSScriptInfo
.VERSION 2026.07.20
.GUID 42904e1e-c247-4036-a38b-fb377e975d26
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
    into their template (caching-proxy-service, stash-service) never substitute the
    placeholder and are correctly out of scope.

    Source-text only -- no host driver is imported and no VM is touched.
    Throw-based assertions so the file runs under Pester 3.4 and Pester 5+.
#>

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# Guest scripts in scope: those that actually template a hostname. The Its that
# iterate them are fed by the file-scope case list below; this run-phase copy
# exists only so the fixture-sanity It can assert the glob still matches.
$script:guestScript = @(
    Get-ChildItem -Path (Join-Path $repoRoot 'host') -Filter 'New-VM.ps1' -Recurse -File |
        Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match 'HOSTNAME_PLACEHOLDER' }
)

# Source text the It bodies assert against. $script: keeps it reachable from the
# It scopes, which run after this block has returned.
$script:provisionSrc = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'host/modules/Yuruna.HostProvision.psm1')
$script:engineSrc    = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'test/modules/Test.SequenceEngine.psm1')

}

# Case lists for the Describes below. Pester enumerates a Describe -- and with it
# every -TestCases expression -- during discovery, which happens before any
# BeforeAll body runs, so these resolve their own repo root here at file scope. A
# list built inside BeforeAll is still $null at enumeration time, and the Describe
# consuming it then emits no tests at all and passes while asserting nothing.
$discoveryRepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))

$guestCase = @(
    Get-ChildItem -Path (Join-Path $discoveryRepoRoot 'host') -Filter 'New-VM.ps1' -Recurse -File |
        Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match 'HOSTNAME_PLACEHOLDER' } |
        ForEach-Object { @{ name = (Split-Path -Leaf $_.Directory.FullName); path = $_.FullName } }
)

# Meta-data templates that carry a hostname placeholder.
$metaCase = @(
    Get-ChildItem -Path (Join-Path $discoveryRepoRoot 'host/vmconfig') -Filter '*.meta-data' -File |
        Where-Object { (Get-Content -Raw -LiteralPath $_.FullName) -match 'HOSTNAME_PLACEHOLDER' } |
        ForEach-Object { @{ name = $_.Name; path = $_.FullName } }
)

# Every sequence the framework ships. Project sequences live in a separate
# repo that need not be cloned here, so they are scanned only when present.
$seqFile = @(
    Get-ChildItem -Path (Join-Path $discoveryRepoRoot 'test/sequences') -Filter '*.yml' -Recurse -File
    $projDir = Join-Path $discoveryRepoRoot 'project'
    if (Test-Path -LiteralPath $projDir) {
        Get-ChildItem -Path $projDir -Filter '*.yml' -Recurse -File |
            Where-Object { $_.FullName -match '[\\/]test[\\/](gui|ssh)[\\/]' }
    }
)
$seqCase = @($seqFile | ForEach-Object { @{ name = $_.Name; path = $_.FullName } })

# A glob that stops matching would silently retire its whole Describe, so an
# empty list fails the file outright instead of going quiet.
if ($guestCase.Count -lt 3) { throw "Expected several hostname-templating New-VM.ps1 scripts under $(Join-Path $discoveryRepoRoot 'host'), found $($guestCase.Count). The discovery glob is pointed at the wrong folder." }
if ($metaCase.Count  -lt 1) { throw "Expected at least one *.meta-data template with HOSTNAME_PLACEHOLDER under $(Join-Path $discoveryRepoRoot 'host/vmconfig'), found none." }
if ($seqCase.Count   -lt 1) { throw "Expected at least one sequence .yml under $(Join-Path $discoveryRepoRoot 'test/sequences'), found none." }

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
        Assert-True ($script:provisionSrc -match [regex]::Escape("ContainsKey('Hostname')")) `
            'Invoke-PerGuestNewVm must probe for -Hostname before forwarding'
    }
    It 'appends -Hostname to the child argument list' {
        Assert-True ($script:provisionSrc -match [regex]::Escape("@('-Hostname', `$Hostname)")) `
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
        Assert-True ($script:engineSrc -match [regex]::Escape('"hostname" = $VMName')) `
            'Invoke-Sequence must seed a ${hostname} built-in, or an unpinned sequence matching on ${hostname} sees an unresolved literal'
    }

    It 'never matches the shell prompt on the VM name: <name>' -TestCases $seqCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        Assert-True ($src -notmatch [regex]::Escape('${username}@${vmName}')) `
            "$name matches the prompt on the VM name; a pinned hostname in ANY sequence of its chain makes that assertion time out"
    }
}

Describe 'agetty nudge ordering -- the redraw precedes the wait it unblocks' {

    # agetty prints "login:" once and never reprints it. Console writes that
    # land afterwards (cloud-init's closing banner, subiquity's tail) scroll the
    # prompt away, and the screen then stops changing -- so an OCR wait for
    # "login:" can only spend its entire budget against a frozen frame. The
    # recovery is a keypress, and it only works if it happens BEFORE the wait.
    #
    # Placed after the wait it is unreachable, because a retry block restarts at
    # its first step: every attempt re-enters the wait that cannot pass and no
    # attempt ever reaches the nudge. That shape cost three full waits per guest
    # on several hosts before it was found, and it is invisible in a passing run
    # because the ordering only matters once the prompt has been overwritten.
    It 'puts the redraw keypress before the login wait in <name>' -TestCases $seqCase {
        param($name, $path)
        $src = Get-Content -Raw -LiteralPath $path
        # Only sequences that carry BOTH a redraw nudge and a login wait are in
        # scope; the rest have nothing to order.
        $nudge = [regex]::Match($src, '(?m)^\s*-\s*action:\s*pressKey\s*$.*?redraw a fresh login', 'Singleline')
        $wait  = [regex]::Match($src, '(?m)^\s*-\s*action:\s*waitForText\s*$\s*\n\s*pattern:\s*"login:"')
        if (-not ($nudge.Success -and $wait.Success)) { return }
        Assert-True ($nudge.Index -lt $wait.Index) `
            ("$name waits for 'login:' before nudging agetty; a prompt already scrolled away can never appear, " +
             'and a retry restarts at the wait so the nudge below it is unreachable')
    }
}
