<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42c1a7e9-5b62-4d38-9a04-7e2f1c6b8d90
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test transport vnc pester
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
    Pester coverage for Read-VncBuffer in Test.Transport.psm1: the fixed-size
    RFB read honors an optional wall-clock deadline that bounds the whole
    multi-read handshake, independent of the per-read socket ReceiveTimeout.
.DESCRIPTION
    Read-VncBuffer is pure over a System.IO.Stream, so a MemoryStream drives it
    with no socket. Throw-based assertions; run under Pester 4.10.1 (the top-level
    Assert-* helpers are not visible in It blocks under Pester 5's scope split).
#>

$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.Transport.psm1'
Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue

function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Throw {
    param([scriptblock]$Script, [string]$Match = '', [string]$Because = '')
    $threw = $false
    try { & $Script } catch {
        $threw = $true
        if ($Match -and ($_.Exception.Message -notmatch $Match)) {
            throw "Threw, but message '$($_.Exception.Message)' did not match '$Match'. $Because"
        }
    }
    if (-not $threw) { throw "Expected a throw. $Because" }
}

Describe 'Read-VncBuffer wall-clock deadline' {

    It 'reads exactly Count bytes (no deadline supplied = backward compatible)' {
        $s = [System.IO.MemoryStream]::new([byte[]](1..12))
        $buf = Read-VncBuffer -Stream $s -Count 12
        Assert-True ($buf.Length -eq 12) 'returns the requested count'
        Assert-True ($buf[0] -eq 1 -and $buf[11] -eq 12) 'returns the actual bytes'
    }

    It 'returns the bytes when the deadline is in the future' {
        $s = [System.IO.MemoryStream]::new([byte[]](1..4))
        $buf = Read-VncBuffer -Stream $s -Count 4 -Deadline ([DateTime]::UtcNow.AddSeconds(30))
        Assert-True ($buf.Length -eq 4) 'a comfortable deadline does not interfere'
    }

    It 'throws once the wall-clock deadline has passed' {
        $s = [System.IO.MemoryStream]::new([byte[]](1..12))
        Assert-Throw { Read-VncBuffer -Stream $s -Count 12 -Deadline ([DateTime]::UtcNow.AddSeconds(-1)) } 'deadline' -Because 'a past deadline must throw before/at the first read'
    }

    It 'throws when the stream closes before Count bytes arrive' {
        $s = [System.IO.MemoryStream]::new([byte[]](1..5))
        Assert-Throw { Read-VncBuffer -Stream $s -Count 12 -Deadline ([DateTime]::UtcNow.AddSeconds(30)) } 'closed' -Because 'a short stream (EOF) must throw the connection-closed error'
    }
}
