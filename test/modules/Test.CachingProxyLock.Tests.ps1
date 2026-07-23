<#PSScriptInfo
.VERSION 2026.07.22
.GUID 422d9f13-4b78-4c50-9e31-8d0a5c2f7b91
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test caching-proxy lock adopt pester
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
    Pester coverage for the caching-proxy serialization lock + adopt decision
    (Test.CachingProxyLock.psm1): drain-style acquire/release, live-holder
    fail-fast + bounded wait, stale drain, idempotent release, and the strict
    adopt-if-healthy decision.
.DESCRIPTION
    Throw-based assertions for OS-bundled Pester 3.4 / Pester 5+ compatibility.
    All lock state lives under a per-test temp runtime dir.
    Run with:  Invoke-Pester -Path test/modules/Test.CachingProxyLock.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.CachingProxyLock.psm1') -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

function New-LockTempDir {
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: creates a throwaway runtime dir the calling It block deletes in its finally.')]
    param()
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ("yrn-cplk-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

Describe 'Get-CachingProxyAdoptDecision (strict adopt)' {
    It 'adopts a running VM with a recorded IP and a fully-successful probe' {
        $d = Get-CachingProxyAdoptDecision -VmState 'running' -ProbeSuccess $true -Ip '192.168.7.50'
        Assert-True $d.Adoptable 'running + healthy + ip'
        Assert-Equal -Expected '192.168.7.50' -Actual $d.Ip
    }
    It 'refuses when the VM is not running' {
        $d = Get-CachingProxyAdoptDecision -VmState 'off' -ProbeSuccess $true -Ip '192.168.7.50'
        Assert-Equal -Expected $false -Actual $d.Adoptable
        Assert-True ($d.Reason -like 'vm-not-running*') 'reason names the state'
    }
    It 'refuses when the health probe did not fully succeed (half-wedged proxy rebuilds)' {
        Assert-Equal -Expected $false -Actual (Get-CachingProxyAdoptDecision -VmState 'running' -ProbeSuccess $false -Ip '192.168.7.50').Adoptable
    }
    It 'refuses when there is no recorded IP' {
        $d = Get-CachingProxyAdoptDecision -VmState 'running' -ProbeSuccess $true -Ip ''
        Assert-Equal -Expected $false -Actual $d.Adoptable
        Assert-Equal -Expected 'no-recorded-ip' -Actual $d.Reason
    }
}

Describe 'Enter/Exit-CachingProxyLock (drain-style mutex)' {
    It 'acquires a free lock and releases it' {
        $rd = New-LockTempDir
        try {
            $h = Enter-CachingProxyLock -RuntimeDir $rd -Role 'rebuild' -TimeoutSeconds 0
            Assert-True $h.Acquired 'free lock acquires'
            Assert-True (Test-Path (Join-Path $rd 'caching-proxy.lock')) 'lock file created'
            Exit-CachingProxyLock -Handle $h
            Assert-Equal -Expected $false -Actual (Test-Path (Join-Path $rd 'caching-proxy.lock')) -Because 'release removes the lock'
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
    It 'fail-fasts (try-once) against a live holder and reports its pid/role' {
        $rd = New-LockTempDir
        try {
            $h1 = Enter-CachingProxyLock -RuntimeDir $rd -Role 'rebuild' -TimeoutSeconds 0
            $h2 = Enter-CachingProxyLock -RuntimeDir $rd -Role 'portmap' -TimeoutSeconds 0
            Assert-Equal -Expected $false -Actual $h2.Acquired -Because 'a live holder blocks a try-once acquire'
            Assert-Equal -Expected $PID -Actual $h2.HolderPid -Because 'holder pid surfaced'
            Assert-Equal -Expected 'rebuild' -Actual $h2.HolderRole -Because 'holder role surfaced'
            Exit-CachingProxyLock -Handle $h1
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
    It 'drains a stale (dead-PID) holder and acquires' {
        $rd = New-LockTempDir
        try {
            $pidPath = Join-Path $rd 'caching-proxy.lock'
            Set-Content -Path $pidPath -Value '999999' -NoNewline
            @{ pid = 999999; role = 'rebuild'; startTimeUnixMs = 1 } | ConvertTo-Json -Compress | Set-Content -Path "$pidPath.start" -NoNewline
            $holder = Get-CachingProxyLockHolder -PidPath $pidPath -StartPath "$pidPath.start"
            Assert-Equal -Expected $false -Actual $holder.Alive -Because 'dead pid is not a live holder'
            $h = Enter-CachingProxyLock -RuntimeDir $rd -Role 'rebuild' -TimeoutSeconds 0
            Assert-True $h.Acquired 'stale lock drained + acquired'
            Exit-CachingProxyLock -Handle $h
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
    It 'waits out a live holder up to the timeout, then reports not-acquired' {
        $rd = New-LockTempDir
        try {
            $hHold = Enter-CachingProxyLock -RuntimeDir $rd -Role 'rebuild' -TimeoutSeconds 0
            $t0 = [DateTime]::UtcNow
            $hWait = Enter-CachingProxyLock -RuntimeDir $rd -Role 'rebuild' -TimeoutSeconds 2
            $elapsed = ([DateTime]::UtcNow - $t0).TotalSeconds
            Assert-Equal -Expected $false -Actual $hWait.Acquired -Because 'a live holder is not reclaimed'
            Assert-True ($elapsed -ge 1.5) "bounded wait honored the timeout (elapsed $([Math]::Round($elapsed,1))s)"
            Exit-CachingProxyLock -Handle $hHold
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
    It 'is idempotent on double-release and never removes a lock it does not own' {
        $rd = New-LockTempDir
        try {
            $h = Enter-CachingProxyLock -RuntimeDir $rd -Role 'rebuild' -TimeoutSeconds 0
            Exit-CachingProxyLock -Handle $h
            Exit-CachingProxyLock -Handle $h   # no throw, no-op
            # a lock owned by a DIFFERENT pid is never removed by our handle
            $foreign = Join-Path $rd 'caching-proxy.lock'
            Set-Content -Path $foreign -Value '999999' -NoNewline
            Exit-CachingProxyLock -Handle @{ Acquired = $true; PidPath = $foreign; StartPath = "$foreign.start" }
            Assert-True (Test-Path $foreign) 'Exit must not remove a lock owned by another pid (999999 != our pid)'
        } finally { if (Test-Path $rd) { Remove-Item -Recurse -Force $rd } }
    }
}

Describe 'Get-CachingProxyLockPath' {
    It 'roots the lock under the supplied runtime dir' {
        $p = Get-CachingProxyLockPath -RuntimeDir 'C:\some\runtime'
        Assert-True ($p.PidPath -like '*caching-proxy.lock') 'pid path name'
        Assert-Equal -Expected ($p.PidPath + '.start') -Actual $p.StartPath -Because 'start sidecar sits beside the pid file'
    }
}
