<#PSScriptInfo
.VERSION 2026.06.30
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

Describe 'Test-PortListenerFree' {
    It 'reports a known-unused high port as bindable' {
        Assert-True (Test-PortListenerFree -Port $FreePort) "port $FreePort should be free"
    }

    It 'reports a port we are actively holding as NOT bindable' {
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
    It 'classifies a free port as Free' {
        $r = Resolve-PortOrphan -Port $FreePort -Confirm:$false
        Assert-Equal -Expected 'Free' -Actual $r.Status -Because 'free port -> Free'
        Assert-Equal -Expected '' -Actual $r.Message -Because 'free port has no banner'
    }

    It 'classifies a still-held port as Conflict with an actionable banner' {
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
