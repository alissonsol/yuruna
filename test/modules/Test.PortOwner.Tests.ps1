<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42c6a4b0-7182-4394-8ea5-2b3c4d5e6f70
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test portowner statusservice pester
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
    Pester coverage for Test.PortOwner.psm1's status-port pre-flight: the
    HttpListener bind-probe (Test-PortListenerFree) and the classifier
    (Resolve-PortOrphan) that decides Free / Recovered / Conflict.
.DESCRIPTION
    Throw-based assertions for OS-bundled Pester 3.4 / Pester 5+ compatibility.
    The "held port" cases bind a real HttpListener in-process so the detection
    is exercised without spawning another user's server; -WhatIf keeps the
    orphan-reclaim path from stopping the (self-owned) holder during the test.
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.PortOwner.psm1') -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

# A high port unlikely to collide with a real listener on a test host.
$FreePort = 54219

# Can this shell actually make the reservation the module probes with?
#
# Test-PortListenerFree deliberately binds `http://*:<port>/` rather than
# localhost: a wildcard reservation is what reveals a holder owned by ANOTHER
# user, which lsof/netsh cannot show without elevation. On Windows that same
# wildcard is an HTTP.sys URL reservation and needs admin (or a `netsh http add
# urlacl`), so from an ordinary shell every bind returns "Access is denied" --
# which the module cannot distinguish from "someone else holds the port", and a
# genuinely free port then classifies as Conflict. The product path is unaffected
# (the runner requires Administrator), but this suite cannot produce a verdict
# from a non-elevated shell.
#
# So probe the capability instead of guessing at it, and tell the two causes
# apart: localhost binds without privilege, the wildcard does not. localhost
# binding while the wildcard is denied means "not allowed", not "port busy" --
# only then is skipping honest. Skipping (not passing) keeps the gap visible.
function Test-CanBindPrefix {
    [CmdletBinding()] [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Prefix)
    $listener = [System.Net.HttpListener]::new()
    try {
        $listener.Prefixes.Add($Prefix)
        $listener.Start()
        $listener.Stop()
        return $true
    } catch {
        return $false
    } finally {
        $listener.Close()
    }
}

$PortIsActuallyFree  = Test-CanBindPrefix -Prefix "http://localhost:$FreePort/"
$CanReserveWildcard  = $PortIsActuallyFree -and (Test-CanBindPrefix -Prefix "http://*:$FreePort/")
$PrivilegeBlocked    = $PortIsActuallyFree -and -not $CanReserveWildcard
if ($PrivilegeBlocked) {
    Write-Warning "Test.PortOwner: port $FreePort is free, but this shell may not reserve http://*:$FreePort/ (needs elevation, or 'netsh http add urlacl'). The tests that need the reservation are SKIPPED, not passed -- run the suite elevated to exercise them. The PrivilegeRequired path IS exercised here, since this is exactly the state it describes."
}

Describe 'Test-PortListenerFree' {
    It 'reports a known-unused high port as bindable' -Skip:(-not $CanReserveWildcard) {
        Assert-True (Test-PortListenerFree -Port $FreePort) "port $FreePort should be free"
    }

    It 'reports a port we are actively holding as NOT bindable' -Skip:(-not $CanReserveWildcard) {
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://*:$FreePort/")
        $listener.Start()
        try {
            Assert-True (-not (Test-PortListenerFree -Port $FreePort)) "held port $FreePort should be unbindable"
        } finally {
            $listener.Stop(); $listener.Close()
        }
    }
}

Describe 'Resolve-PortOrphan' {
    It 'classifies a free port as Free' -Skip:(-not $CanReserveWildcard) {
        $r = Resolve-PortOrphan -Port $FreePort -Confirm:$false
        Assert-Equal -Expected 'Free' -Actual $r.Status -Because 'free port -> Free'
        Assert-Equal -Expected '' -Actual $r.Message -Because 'free port has no banner'
    }

    It 'classifies a still-held port as Conflict with an actionable banner' -Skip:(-not $CanReserveWildcard) {
        # Hold the port ourselves and pass -WhatIf so the orphan-reclaim path
        # never actually stops the (self-owned) holder. The port stays held
        # across the probe, so the classifier must return Conflict rather than
        # silently letting a blind cycle proceed.
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://*:$FreePort/")
        $listener.Start()
        try {
            $r = Resolve-PortOrphan -Port $FreePort -WhatIf
            Assert-Equal -Expected 'Conflict' -Actual $r.Status -Because 'held port -> Conflict'
            Assert-True ([bool]$r.Message) 'conflict carries an operator banner'
            Assert-True ([bool]($r.Message -match 'Refusing')) 'banner states the refusal'
            Assert-True ([bool]($r.Message -match [string]$FreePort)) 'banner names the port'
        } finally {
            $listener.Stop(); $listener.Close()
        }
    }
}

# A failed wildcard bind has two causes that call for opposite responses from the
# operator: something is holding the port, or this process may not reserve the URL
# at all. Conflating them tells someone whose port is empty to go and stop a
# holder that does not exist. These pin the two apart.
Describe 'Test-PortPrivilegeBlocked' {
    It 'reports a free port that this shell may not reserve' -Skip:(-not $PrivilegeBlocked) {
        Assert-True (Test-PortPrivilegeBlocked -Port $FreePort) `
            'the port is empty and the wildcard was refused for privilege -- that is the whole point of this classification'
    }

    It 'stays quiet when the wildcard reservation actually succeeds' -Skip:(-not $CanReserveWildcard) {
        Assert-True (-not (Test-PortPrivilegeBlocked -Port $FreePort)) `
            'nothing to explain when the bind works'
    }

    # Runs whatever the privilege level: elevated, the wildcard binds and the
    # answer is $false immediately; unelevated, the wildcard is denied but the
    # localhost bind then fails against our own listener, which proves the port is
    # NOT empty -- so the privilege story must not be told either way. This is the
    # assertion that stops the new status from swallowing a real conflict.
    It 'never claims privilege for a port that is genuinely occupied' {
        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add("http://localhost:$FreePort/")
        $listener.Start()
        try {
            Assert-True (-not (Test-PortPrivilegeBlocked -Port $FreePort)) `
                'something holds the port, so this is a conflict -- not a privilege problem'
        } finally {
            $listener.Stop(); $listener.Close()
        }
    }
}

Describe 'Resolve-PortOrphan: PrivilegeRequired' {
    It 'classifies a free-but-unreservable port apart from a conflict, and names the real remedy' -Skip:(-not $PrivilegeBlocked) {
        $r = Resolve-PortOrphan -Port $FreePort -Confirm:$false

        Assert-Equal -Expected 'PrivilegeRequired' -Actual $r.Status `
            -Because 'the port is empty; calling this a Conflict sends the operator hunting a holder that does not exist'
        Assert-Equal -Expected 0 -Actual @($r.Pids).Count -Because 'nothing holds the port, so there is no PID to report'

        # The banner has to say the two things the operator needs and must not say
        # the thing that is false.
        Assert-True ([bool]($r.Message -match 'Refusing'))              'it still refuses -- the server binds the same prefix'
        Assert-True ([bool]($r.Message -match 'privilege problem'))     'it names the real cause'
        Assert-True ([bool]($r.Message -match 'netsh http add urlacl')) 'it gives the one-time remedy'
        Assert-True ([bool]($r.Message -match [string]$FreePort))       'it names the port'
        Assert-True (-not ($r.Message -match 'owned by another user'))  'it must NOT invent a holder'
    }
}
