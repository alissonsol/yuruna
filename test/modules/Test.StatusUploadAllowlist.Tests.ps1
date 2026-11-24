<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42db5b4f-9255-4491-9e61-27cc60af1914
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

    Read from test/service/Invoke-StatusServiceRuntime.ps1, the tracked
    runtime the service runs.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -File test/modules/Test.StatusUploadAllowlist.Tests.ps1
#>

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$svcPath  = Join-Path $repoRoot 'test/service/Invoke-StatusServiceRuntime.ps1'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# File scope, above the first Describe: a Describe body is evaluated during
# discovery and its variables are gone before any It runs.
$SvcSource = Get-Content -Raw -LiteralPath $svcPath
# The literal the route actually tests uploads against.
$UploadRegexMatch = [regex]::Match($SvcSource, "uploadRel\s+-match\s+'(\\\.\([^']+\)\$)'")
$script:UploadRegex = if ($UploadRegexMatch.Success) { $UploadRegexMatch.Groups[1].Value } else { $null }

}

Describe 'status-service /log-upload allowlist' {
    It 'still has an extension allowlist on the upload route' {
        Assert-True ($null -ne $script:UploadRegex) `
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
            'mounts-at-failure.txt',
            'installer-cause.txt',
            'autoinstall-user-data.log',
            'curtin-errors.tar',
            '1785870436.086154699.install_fail.crash',
            'probe.json',
            'stderr.err'
        )) {
            Assert-True ($name -match $script:UploadRegex) "'$name' must be accepted by the upload allowlist"
            Assert-True ("installer-fail/vm/20260804T190716Z/$name" -match $script:UploadRegex) `
                "'$name' must still be accepted under a bucket path"
        }
    }

    It 'probes the proxy the seed was given, which the installer''s own apt configuration never names' {
        # curtin writes the proxy into /target, so a probe that reads the live
        # system's apt configuration reports no proxy while curtin is failing
        # against one, and the record then shows every direct route healthy.
        $seed = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../../host/vmconfig/ubuntu.server.base.user-data')
        Assert-True ($seed -match 'APT_PROXY="CACHING_PROXY_URL_PLACEHOLDER"') 'the error hook must probe the proxy baked into the seed'
        Assert-Equal -Expected $false -Actual ($seed -match 'APT_PROXY=\$\(grep') -Because 'reading the installer''s apt configuration finds no proxy'
    }

    It 'extracts apt''s statement from curtin''s archive, one copy of each line' -Skip:($IsWindows) {
        # Runs the hook's own lines, so a filter that stops matching apt's wording
        # fails here rather than on the next pool-wide outage.
        $seed = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '../../host/vmconfig/ubuntu.server.base.user-data')
        $block = [regex]::Match($seed, '(?ms)^\s*CURTIN_LOG=\$\(tar.*?^\s*fi > "\$CAUSESNAP"').Value
        Assert-True ([bool]$block) 'the cause extraction must stay in the error hook'
        $work = Join-Path $TestDrive 'hook'
        $logDir = Join-Path $work 'curtin-logs-2026-11-06-01-17'
        $null = New-Item -ItemType Directory -Force -Path $logDir
        # curtin repeats its output, indented, inside the report at the end of the log.
        Set-Content -LiteralPath (Join-Path $logDir 'curtin-install.log') -Value @(
            'Reading package lists...',
            'E: Can not write log (Is /dev/pts mounted?) - posix_openpt (19: No such device)',
            ' linux-generic : Depends: linux-image-generic (= 7.0.0-43.43) but 7.0.0-30.30 is to be installed',
            '                 Recommends: linux-tools-7.0.0-43-generic but it is not installable',
            'E: Unable to satisfy dependencies. Reached two conflicting assignments:',
            '   2. linux-image-generic:amd64=7.0.0-43.43 Depends linux-modules-7.0.0-43-generic',
            '      but none of the choices are installable:',
            '        E: Unable to satisfy dependencies. Reached two conflicting assignments:',
            '        Running command [''udevadm'', ''settle'']')
        $archive = Join-Path $work 'curtin-errors.tar'
        & tar -cf $archive -C $work 'curtin-logs-2026-11-06-01-17'
        $cause = Join-Path $work 'cause.txt'
        $script = $block.Replace('/var/log/installer/curtin-errors.tar', $archive).Replace('$CAUSESNAP', $cause)
        & sh -c $script
        $lines = @(Get-Content -LiteralPath $cause)
        Assert-Equal -Expected (@(
            'linux-generic : Depends: linux-image-generic (= 7.0.0-43.43) but 7.0.0-30.30 is to be installed',
            'E: Unable to satisfy dependencies. Reached two conflicting assignments:',
            '2. linux-image-generic:amd64=7.0.0-43.43 Depends linux-modules-7.0.0-43-generic',
            'but none of the choices are installable:') -join "`n") -Actual ($lines -join "`n")
    }

    It 'rejects executable and extensionless uploads' {
        foreach ($name in @('evil.ps1', 'evil.exe', 'evil.sh', 'evil.bat', 'noextension', 'trailingdot.')) {
            Assert-Equal -Expected $false -Actual ($name -match $script:UploadRegex) `
                -Because "'$name' must NOT be accepted: /log-upload takes no credential"
        }
    }

    It 'does not let a bare allowed extension appear mid-name' {
        # The anchor is what makes the allowlist an allowlist. Without the
        # trailing $, 'payload.log.ps1' passes and the route writes a script.
        Assert-Equal -Expected $false -Actual ('payload.log.ps1' -match $script:UploadRegex) `
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
