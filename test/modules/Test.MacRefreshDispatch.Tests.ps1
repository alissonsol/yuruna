<#PSScriptInfo
.VERSION 2026.09.24
.GUID 4245aa15-0036-4384-9791-32951e4e7589
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test install macos refresh dispatch pester
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
    Behavioral Pester guard on the macOS installer's --refresh dispatch: the
    fail-safe gate that must terminate before any destructive installer step
    runs rather than fall through into an ordinary install under a
    misread or partial refresh signal.
.DESCRIPTION
    The bodies under test are lifted out of install/macos.utm.sh rather than
    copied, following the same technique Test.MacInstallVersionFloor.Tests.ps1
    uses for this same file, so a rewrite there is exercised here instead of
    drifting away from a stale duplicate.

    `exec` is stubbed so a successful dispatch is observable as captured
    output ("EXEC:...") instead of actually replacing the test process.
    `uname` is left real for the tests that check this file's actual refusal
    on a non-Darwin host, and stubbed only for the tests that need to reach
    the logic past that gate (protocol version, entry script, pwsh
    resolution) -- none of that deeper logic has ever run against real
    macOS Bash 3.2, which is a release gate this suite cannot substitute for.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -Command "Invoke-Pester -Path test/modules/Test.MacRefreshDispatch.Tests.ps1"
#>

BeforeAll {
$here      = Split-Path -Parent $PSCommandPath
$repoRoot  = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$installer = Join-Path $repoRoot 'install/macos.utm.sh'

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

if (-not (Test-Path -LiteralPath $installer)) { throw "Installer not found: $installer" }
$installerText = Get-Content -LiteralPath $installer -Raw

# The installer is a top-to-bottom script that elevates, installs packages and
# rewrites the checkout -- it cannot be sourced. Lift the functions under test
# out of it by name; each is defined at column 0 and closed by a lone '}'.
function Get-ShellFunctionBody {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string[]]$Name)
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $Name) {
        $m = [regex]::Match($Text, "(?ms)^$([regex]::Escape($n))\(\)\s*\{.*?^\}")
        if (-not $m.Success) { throw "Shell function '$n' not found in the installer." }
        $parts.Add($m.Value)
    }
    return ($parts -join "`n")
}

# The functions reference these top-level constants rather than hardcoded
# literals, so they must travel with them: Get-ShellFunctionBody only lifts
# named function bodies, and `set -u` below turns a missed reference into an
# immediate "unbound variable" failure instead of a silently wrong value.
$script:LiftedConstants = foreach ($pattern in @('^YURUNA_REFRESH_PROTOCOL_VERSION=\S+$', '^PATH_LINK_DIR=.*$')) {
    $m = [regex]::Match($installerText, "(?m)$pattern")
    if (-not $m.Success) { throw "Pattern not found in the installer: $pattern" }
    $m.Value
}

$script:Lifted = ($script:LiftedConstants -join "`n") + "`n" + (Get-ShellFunctionBody -Text $installerText -Name @(
    'yuruna_pwsh_candidates', 'yuruna_resolve_pwsh', 'yuruna_refresh_dispatch', 'yuruna_require_install_mode'))

# Also confirm the protocol-version constant embedded in the installer
# matches the declaration file package 4 writes, since a drift between them
# would make every real refresh invocation refuse.
$script:InstallerProtocolVersion = [regex]::Match($installerText, 'YURUNA_REFRESH_PROTOCOL_VERSION=(\S+)').Groups[1].Value

# die/log/warn stand in for the real ones (identical shape); exec is stubbed
# so a successful dispatch is observable instead of replacing this process.
$script:Prelude = @'
set -uo pipefail
log()  { printf 'LOG %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*" >&2; }
die()  { printf 'DIE %s\n' "$*" >&2; exit 1; }
exec() { printf 'EXEC:%s\n' "$*"; }
'@

# Runs a bash body with the lifted functions and the stubs in scope.
function Invoke-InstallerShell {
    param([Parameter(Mandatory)][string]$Body, [hashtable]$Environment = @{}, [switch]$FakeDarwin)
    $prelude = $script:Prelude
    if ($FakeDarwin) {
        $prelude = @'
uname() { if [[ "$1" == "-s" ]]; then printf 'Darwin\n'; else printf 'arm64\n'; fi; }
'@ + "`n" + $prelude
    }
    $script = @($prelude, $script:Lifted, $Body) -join "`n"
    $file = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-refresh-{0}.sh" -f [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $file -Value $script
    $saved = @{}
    foreach ($k in $Environment.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $Environment[$k])
    }
    try {
        $out = & bash $file 2>&1
        return @{ Output = (@($out) -join "`n"); ExitCode = $LASTEXITCODE }
    } finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

# One temp Yuruna checkout per test: entry script + protocol-version file.
function New-RefreshCheckout {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: creates a temp sandbox tree the test removes; not user-facing state.')]
    param([string]$ProtocolVersion, [switch]$OmitEntry, [switch]$OmitVersionFile)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-refresh-checkout-{0}" -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $root 'test/lab') -Force | Out-Null
    if (-not $OmitEntry) {
        Set-Content -LiteralPath (Join-Path $root 'test/lab/Invoke-HostRefresh.ps1') -Value '# fixture'
    }
    if (-not $OmitVersionFile) {
        Set-Content -LiteralPath (Join-Path $root 'test/host-refresh.protocol-version') -Value $ProtocolVersion -NoNewline
    }
    return $root
}
}

Describe 'Refresh protocol version' {
    It 'the constant baked into the installer matches test/host-refresh.protocol-version' {
        $declared = (Get-Content -LiteralPath (Join-Path $repoRoot 'test/host-refresh.protocol-version') -Raw).Trim()
        Assert-Equal $declared $script:InstallerProtocolVersion 'a drift here would make every real refresh invocation refuse'
    }
}

Describe 'yuruna_refresh_dispatch -- signal combinations' {
    It 'falls through to install mode when neither signal is present' {
        $r = Invoke-InstallerShell -Body @'
yuruna_refresh_dispatch "installer.sh"
echo "MODE=$YURUNA_INSTALL_MODE"
'@
        Assert-Equal 0 $r.ExitCode 'no signal must never refuse'
        Assert-Match 'MODE=1' $r.Output 'the explicit install branch must set the mode flag'
    }

    It 'refuses when only the --refresh token is present (argv), no env var' {
        $r = Invoke-InstallerShell -Body 'yuruna_refresh_dispatch "installer.sh" --refresh'
        Assert-True ($r.ExitCode -ne 0) 'token alone must refuse'
        Assert-Match 'without YURUNA_REFRESH=1' $r.Output 'must name the missing half'
    }

    It 'refuses when only YURUNA_REFRESH=1 is present, no token anywhere' {
        $r = Invoke-InstallerShell -Body 'yuruna_refresh_dispatch "installer.sh"' -Environment @{ YURUNA_REFRESH = '1' }
        Assert-True ($r.ExitCode -ne 0) 'the env var alone must refuse'
        Assert-Match 'without the --refresh argument' $r.Output 'must name the missing half'
    }

    It 'recognizes the token when it lands in $0 (a dropped bash -c placeholder)' {
        # The convenience one-liner is `bash -c "$(curl ...)" _ --refresh`; an
        # operator who drops the "_" placeholder puts --refresh in $0 instead
        # of "$@". This must still be recognized as a refresh SIGNAL (paired
        # here with the env var so it reaches the platform gate), not silently
        # ignored as an unrecognized argv.
        $r = Invoke-InstallerShell -Body 'yuruna_refresh_dispatch "--refresh"' -Environment @{ YURUNA_REFRESH = '1' }
        Assert-Match 'Refresh only supports macOS' $r.Output '$0 placement must reach the platform gate, not fall through to install'
    }

    It 'recognizes the token when it lands in "$@" (the documented form)' {
        $r = Invoke-InstallerShell -Body 'yuruna_refresh_dispatch "installer.sh" --refresh' -Environment @{ YURUNA_REFRESH = '1' }
        Assert-Match 'Refresh only supports macOS' $r.Output 'the documented argv form must reach the platform gate'
    }

    It 'refuses an unsupported extra argument alongside --refresh' {
        $r = Invoke-InstallerShell -Body 'yuruna_refresh_dispatch "installer.sh" --refresh --pin-version' -Environment @{ YURUNA_REFRESH = '1' }
        Assert-True ($r.ExitCode -ne 0) 'an unrecognized extra flag must refuse, not be silently ignored'
        Assert-Match 'accepts no other arguments' $r.Output ''
    }

    It 'refuses on a non-Darwin host with a real (unstubbed) uname, using the actual installer file' {
        # Runs against the genuine `uname` on this box: proves the refresh
        # preflight really does gate on platform rather than assuming it.
        $r = Invoke-InstallerShell -Body 'yuruna_refresh_dispatch "installer.sh" --refresh' -Environment @{ YURUNA_REFRESH = '1' }
        Assert-Match 'Refresh only supports macOS' $r.Output 'a well-formed refresh request on a non-Darwin host must still refuse'
        Assert-True ($r.ExitCode -ne 0) ''
    }
}

Describe 'yuruna_refresh_dispatch -- past the platform gate (Darwin stubbed)' {
    It 'refuses when the target directory does not exist' {
        $missing = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-missing-{0}" -f [guid]::NewGuid().ToString('N'))
        $r = Invoke-InstallerShell -FakeDarwin -Body 'yuruna_refresh_dispatch "installer.sh" --refresh' `
            -Environment @{ YURUNA_REFRESH = '1'; YURUNA_DIR = $missing }
        Assert-Match 'not an existing Yuruna checkout' $r.Output ''
    }

    It 'refuses when the protocol-version file is absent (pre-refresh checkout)' {
        $root = New-RefreshCheckout -ProtocolVersion $script:InstallerProtocolVersion -OmitVersionFile
        try {
            $r = Invoke-InstallerShell -FakeDarwin -Body 'yuruna_refresh_dispatch "installer.sh" --refresh' `
                -Environment @{ YURUNA_REFRESH = '1'; YURUNA_DIR = $root }
            Assert-Match 'protocol declaration not found' $r.Output 'must name the missing file'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses on a protocol-version mismatch' {
        $root = New-RefreshCheckout -ProtocolVersion '999'
        try {
            $r = Invoke-InstallerShell -FakeDarwin -Body 'yuruna_refresh_dispatch "installer.sh" --refresh' `
                -Environment @{ YURUNA_REFRESH = '1'; YURUNA_DIR = $root }
            Assert-Match "does not match this installer's" $r.Output ''
            Assert-True ($r.ExitCode -ne 0) ''
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses when the entry script itself is missing despite a matching protocol version' {
        $root = New-RefreshCheckout -ProtocolVersion $script:InstallerProtocolVersion -OmitEntry
        try {
            $r = Invoke-InstallerShell -FakeDarwin -Body 'yuruna_refresh_dispatch "installer.sh" --refresh' `
                -Environment @{ YURUNA_REFRESH = '1'; YURUNA_DIR = $root }
            Assert-Match 'entry script not found' $r.Output ''
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses when no pwsh can be resolved anywhere' {
        $root = New-RefreshCheckout -ProtocolVersion $script:InstallerProtocolVersion
        try {
            $r = Invoke-InstallerShell -FakeDarwin -Body @'
command() { return 1; }
yuruna_refresh_dispatch "installer.sh" --refresh
'@ -Environment @{ YURUNA_REFRESH = '1'; YURUNA_DIR = $root }
            Assert-Match 'pwsh not found' $r.Output ''
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'execs the resolved pwsh against the entry script on a fully satisfied request' {
        $root = New-RefreshCheckout -ProtocolVersion $script:InstallerProtocolVersion
        $fakePwshDir = Join-Path $root 'fakebin'
        New-Item -ItemType Directory -Path $fakePwshDir -Force | Out-Null
        $fakePwsh = Join-Path $fakePwshDir 'pwsh'
        Set-Content -LiteralPath $fakePwsh -Value "#!/bin/bash`necho fake-pwsh`n"
        & chmod +x $fakePwsh
        try {
            $r = Invoke-InstallerShell -FakeDarwin -Body @"
PATH="${fakePwshDir}:`$PATH"
yuruna_refresh_dispatch "installer.sh" --refresh
"@ -Environment @{ YURUNA_REFRESH = '1'; YURUNA_DIR = $root }
            Assert-Match 'EXEC:.*fakebin/pwsh' $r.Output 'must exec the resolved pwsh, not fall through to install'
            Assert-Match 'Invoke-HostRefresh\.ps1' $r.Output 'must pass the real entry script path'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'yuruna_require_install_mode' {
    It 'passes silently once the dispatch install branch has run' {
        $r = Invoke-InstallerShell -Body @'
yuruna_refresh_dispatch "installer.sh"
yuruna_require_install_mode
echo REACHED
'@
        Assert-Equal 0 $r.ExitCode ''
        Assert-Match 'REACHED' $r.Output 'a destructive region must run once install mode is confirmed'
    }

    It 'dies if called before the dispatch has confirmed install mode' {
        $r = Invoke-InstallerShell -Body 'yuruna_require_install_mode'
        Assert-True ($r.ExitCode -ne 0) 'the guard must refuse an unconfirmed mode rather than assume install'
        Assert-Match 'a confirmed install run' $r.Output ''
    }
}

Describe 'Destructive regions call the install-mode guard' {
    It 'every named destructive region in the installer calls yuruna_require_install_mode before acting' {
        # Structural, not behavioral: confirms the guard call sits in the
        # source ahead of each site the plan names, so a future edit that
        # deletes one of these calls is caught here even though this suite
        # cannot drive the whole installer end to end.
        $sites = @(
            'if \[\[ \$NEEDS_REPAIR -eq 1 \]\]; then\s*\n\s*yuruna_require_install_mode',
            'yuruna_require_install_mode\s*\n\s*log "Stopping anything that would block a repo update',
            'yuruna_require_install_mode\s*\n\s*log "Installing / upgrading required formulae"',
            'preserve_test_status\(\) \{\s*\n\s*yuruna_require_install_mode',
            '# --- REGION: Clone / update the repo\s*\n\s*yuruna_require_install_mode',
            '# --- REGION: Baseline reset: remove test-\* VMs\s*\n\s*yuruna_require_install_mode'
        )
        foreach ($pattern in $sites) {
            Assert-True ([regex]::IsMatch($installerText, $pattern)) "missing install-mode guard for pattern: $pattern"
        }
    }
}
