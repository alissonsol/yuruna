<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42f8c1d4-6b02-4e79-9d3a-71c5e08b4f26
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test status-service upload allowlist pester
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
    Guards the /log-upload extension allowlist on the status service.
.DESCRIPTION
    /log-upload is the one unauthenticated WRITE surface the status service
    exposes: a failing guest installer PUTs its logs there before the VM dies,
    so it cannot require a credential. The extension allowlist is what keeps
    that surface narrow, and it is load-bearing in two directions -- too tight
    and a real installer artifact is dropped silently (the guest sees only a
    non-fatal curl error and the evidence is gone with the VM), too loose and
    an unauthenticated writer can land a script under the served log tree.

    The regex is read out of the service source rather than restated here, so
    this cannot pass against an allowlist that no longer exists or has been
    widened somewhere else in the file.

    Read from Start-StatusService.ps1, which is the tracked GENERATOR, not
    from test/status/runtime/.status-service.ps1 -- that copy is gitignored
    runtime output, absent on a fresh clone and overwritten on every service
    start, so a guard reading it would test a file no commit can change.
    The generator emits the route inside a here-string, hence the escaped `$
    in the pattern below.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -File test/modules/Test.StatusUploadAllowlist.Tests.ps1
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$svcPath  = Join-Path $repoRoot 'test/Start-StatusService.ps1'

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

# File scope, above the first Describe: a Describe body is evaluated during
# discovery and its variables are gone before any It runs.
$SvcSource = Get-Content -Raw -LiteralPath $svcPath
# The literal the route actually tests uploads against. In the generator the
# route lives in a here-string, so the end-anchor is written as a backtick-
# escaped `$; strip that escape to recover the regex the running service uses.
$UploadRegexMatch = [regex]::Match($SvcSource, "uploadRel\s+-match\s+'(\\\.\([^']+\)``?\$)'")
$UploadRegex = if ($UploadRegexMatch.Success) { $UploadRegexMatch.Groups[1].Value -replace '`\$', '$' } else { $null }

Describe 'status-service /log-upload allowlist' {
    It 'still has an extension allowlist on the upload route' {
        Assert-True ($null -ne $UploadRegex) `
            "no '-match' extension allowlist found near uploadRel in $svcPath -- the write surface may have been widened"
    }

    It 'accepts every artifact the installer error hook uploads' {
        # Each of these is PUT by the error-commands block in
        # host/vmconfig/ubuntu.server.base.user-data. One silently rejected
        # extension means that artifact is missing from every future installer
        # post-mortem, and nothing reports the loss.
        foreach ($name in @(
            'subiquity-server-debug.log',
            'installer-journal.txt',
            'network-at-failure.txt',
            'autoinstall-user-data.log',
            'curtin-errors.tar',
            '1785870436.086154699.install_fail.crash',
            'probe.json',
            'stderr.err'
        )) {
            Assert-True ($name -match $UploadRegex) "'$name' must be accepted by the upload allowlist"
            Assert-True ("installer-fail/vm/20260804T190716Z/$name" -match $UploadRegex) `
                "'$name' must still be accepted under a bucket path"
        }
    }

    It 'rejects executable and extensionless uploads' {
        foreach ($name in @('evil.ps1', 'evil.exe', 'evil.sh', 'evil.bat', 'noextension', 'trailingdot.')) {
            Assert-Equal -Expected $false -Actual ($name -match $UploadRegex) `
                -Because "'$name' must NOT be accepted: /log-upload takes no credential"
        }
    }

    It 'does not let a bare allowed extension appear mid-name' {
        # The anchor is what makes the allowlist an allowlist. Without the
        # trailing $, 'payload.log.ps1' passes and the route writes a script.
        Assert-Equal -Expected $false -Actual ('payload.log.ps1' -match $UploadRegex) `
            -Because 'the extension test must be anchored at end-of-string'
    }

    It 'keeps the traversal and absolute-path guards alongside it' {
        # The extension check alone does not stop ../../ escaping the log tree.
        Assert-True ($SvcSource -match "uploadRel\s+-match\s+'\(\^\|/\)\\\.\\\.\(/\|") `
            'the ".." traversal guard must remain on the upload route'
        Assert-True ($SvcSource -match "uploadRel\s+-match\s+'\^/'") `
            'the absolute-path guard must remain on the upload route'
    }
}
