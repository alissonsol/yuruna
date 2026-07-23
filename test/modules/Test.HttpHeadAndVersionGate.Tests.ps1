<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42d8b0a1-6c74-4e35-9f28-1a5b3c7d0e46
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test http head version-gate pester
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
    Guards two functional fixes: the status server never writes a body on a HEAD
    response, and Check-DependencyVersion signals dependency drift via its exit code.
.DESCRIPTION
    An HTTP HEAD response must carry GET's headers (including Content-Length)
    but zero body bytes; writing the body resets the client connection. The static-
    file route was the one path that wrote the body unconditionally. This test locks
    every file-bytes write behind a non-HEAD guard.

    Check-DependencyVersion.ps1 must exit 1 when a pin has a newer stable
    release -- a structured drift report alone cannot gate CI -- while a
    transient check failure alone does not fail the gate. This test locks
    that exit contract without running the (networked) script.

    The throw-based Assert-* helpers are defined at script scope and referenced from
    It blocks, so this runs under Pester 4.10.1 (Pester 5's scope split hides
    top-level helpers from It blocks).
#>

$here    = Split-Path -Parent $PSCommandPath
$repo    = Split-Path -Parent (Split-Path -Parent $here)
$sssPath = Join-Path $repo 'test/Start-StatusService.ps1'
$chkPath = Join-Path $repo 'automation/Check-DependencyVersion.ps1'

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

# The gate script's source is read at FILE scope: a Describe body is executed
# during discovery and its variables are discarded before any It runs, so an
# in-Describe $chkText would reach the exit-contract guards as $null -- where
# .Contains() throws and a -notmatch guard passes vacuously.
$chkText = Get-Content -Raw -LiteralPath $chkPath

Describe 'static-file responses honor HEAD (headers, no body)' {
    It 'guards every file-bytes body write behind a non-HEAD check' {
        # Every `$res.OutputStream.Write(`$bytes ...) must run only when the method
        # is not HEAD -- guarded inline on the same line, or by an
        # `if (`$req.HttpMethod -ne 'HEAD') {` on the immediately preceding line.
        $lines   = Get-Content -LiteralPath $sssPath
        $writeRe = 'OutputStream\.Write\(' + [char]0x60 + '\$bytes'   # 0x60 = backtick
        $guardRe = "HttpMethod -ne 'HEAD'"
        $total = 0; $unguarded = @()
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match $writeRe) {
                $total++
                $inline = $lines[$i] -match $guardRe
                $prev   = ($i -gt 0) -and ($lines[$i-1] -match $guardRe)
                if (-not ($inline -or $prev)) { $unguarded += ($i + 1) }
            }
        }
        Assert-True ($total -ge 5) "expected several file-bytes body writes, found $total"
        Assert-Equal -Expected 0 -Actual $unguarded.Count -Because "unguarded HEAD body writes at line(s): $($unguarded -join ', ')"
    }
}

Describe 'Check-DependencyVersion signals drift via exit code' {
    It 'exits non-zero when a pinned dependency has drifted' {
        Assert-True ($chkText.Contains('if ($updateCount -gt 0) { exit 1 }')) 'must exit 1 on drift'
    }

    It 'does not fail the gate on a transient check failure alone' {
        Assert-True ($chkText -notmatch 'failCount\s*-gt\s*0[^}]*exit\s+1') 'a check failure alone must not force a non-zero exit'
    }
}
