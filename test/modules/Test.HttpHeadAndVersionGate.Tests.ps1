<#PSScriptInfo
.VERSION 2026.10.30
.GUID 4205b74c-99c2-4813-9bcc-4e26d11c1f8b
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
    Guards two functional fixes: the status service never writes a body on a HEAD
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

    The throw-based Assert-* helpers live in the file's BeforeAll, which is the
    scope Pester 5 shares with the It blocks; defining them at script scope
    instead makes every It fail on a missing command rather than on an
    assertion.
#>

BeforeAll {
$here    = Split-Path -Parent $PSCommandPath
$repo    = Split-Path -Parent (Split-Path -Parent $here)
$script:sssPath = Join-Path $repo 'test/service/Invoke-StatusServiceRuntime.ps1'
$chkPath = Join-Path $repo 'automation/Check-DependencyVersion.ps1'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# The gate script's source is read at FILE scope: a Describe body is executed
# during discovery and its variables are discarded before any It runs, so an
# in-Describe $script:chkText would reach the exit-contract guards as $null -- where
# .Contains() throws and a -notmatch guard passes vacuously.
$script:chkText = Get-Content -Raw -LiteralPath $chkPath

}

Describe 'static-file responses honor HEAD (headers, no body)' {
    It 'guards every file-bytes body write behind a non-HEAD check' {
        # Every $res.OutputStream.Write($bytes ...) must run only when the method
        # is not HEAD -- guarded inline on the same line, or by an
        # `if ($req.HttpMethod -ne 'HEAD') {` on the immediately preceding line.
        $lines   = Get-Content -LiteralPath $script:sssPath
        $writeRe = 'OutputStream\.Write\(\$bytes'
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

Describe 'static-file responses keep an empty file a byte array' {
    It 'never assigns response bytes from an if-expression, which turns an empty file into $null' {
        # A branch's output is enumerated, so a zero-length byte array arrives as
        # $null. The body write then throws on every platform and the handler
        # aborts the response: on Windows the client sees a reset connection,
        # and elsewhere an empty 200 with a handler error in the server log.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:sssPath, [ref]$null, [ref]$null)
        $assignments = @($ast.FindAll({ param($node)
                    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                    $node.Left.Extent.Text -match '^\$(bytes|assetBytes)$'
                }, $true))
        Assert-True ($assignments.Count -ge 5) "expected several response-byte assignments, found $($assignments.Count)"
        $fromIf = @($assignments | Where-Object { $_.Right -is [System.Management.Automation.Language.IfStatementAst] } | ForEach-Object { $_.Extent.StartLineNumber })
        Assert-Equal -Expected 0 -Actual $fromIf.Count -Because "response bytes assigned from an if-expression at line(s): $($fromIf -join ', ')"
    }
}

Describe 'Check-DependencyVersion signals drift via exit code' {
    It 'exits non-zero when a pinned dependency has drifted' {
        Assert-True ($script:chkText.Contains('if ($updateCount -gt 0) { exit 1 }')) 'must exit 1 on drift'
    }

    It 'does not fail the gate on a transient check failure alone' {
        Assert-True ($script:chkText -notmatch 'failCount\s*-gt\s*0[^}]*exit\s+1') 'a check failure alone must not force a non-zero exit'
    }
}
