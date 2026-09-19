<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42b7c9d4-3f1a-4e8c-9d52-7c4a1b6e8f30
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test install ubuntu powershell version floor pester
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
    Behavioral Pester guard on the Ubuntu installer's PowerShell floor repair:
    reading the floor out of the requirement list, and deciding whether the
    interpreter already on PATH has to be replaced.
.DESCRIPTION
    PowerShell is the only floor-checked tool on an Ubuntu host whose sources
    lead the archive, so it is the only one the installer can raise -- and the
    decision turns on two things no install log shows:

      * presence is not the question a floor asks. A pwsh that arrived from a
        source the installer does not manage answers the name at whatever
        version it was, indefinitely, and a check that only asks whether the
        command exists reports a healthy host.
      * 7.6.10 is newer than 7.6.4. A string compare and a float compare both
        say otherwise, and PowerShell reaches a two-digit patch inside a line.

    A snap is the shape that motivates the fallback: snapd is the only thing
    that can advance one, and when its channel cannot reach the floor the
    managed sources have to win the name instead -- which they do by landing
    under /usr/local/bin, ahead of /snap/bin on the stock PATH.

    The bodies under test are lifted out of install/ubuntu.kvm.sh rather than
    copied, so a rewrite there is exercised here instead of drifting away from a
    stale duplicate. Everything the repair reaches (pwsh, snap, sudo, the two
    installers) is a stub writing to a temporary tree, so the tests run anywhere
    bash does and never touch the host's interpreter.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -Command "Invoke-Pester -Path test/modules/Test.UbuntuInstallPowerShellFloor.Tests.ps1"
#>

BeforeAll {
$here      = Split-Path -Parent $PSCommandPath
$repoRoot  = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$installer = Join-Path $repoRoot 'install/ubuntu.kvm.sh'

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

$script:Lifted = Get-ShellFunctionBody -Text $installerText -Name @(
    'requirement_floor', 'version_ge', 'pwsh_version',
    'bring_powershell_to_required_version')

# Stubs stand in for everything the repair reaches outside its own logic. pwsh
# reads its version from a file the test rewrites, so a stubbed upgrade can move
# it the way a real one would; snap and the two installers only record that they
# were reached.
$script:Prelude = @'
set -euo pipefail
ARCH="${ARCH:-x86_64}"
log()  { printf 'LOG %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
note_issue() { printf 'ISSUE %s\n' "$*"; }
sudo() { "$@"; }
snap() {
  printf 'SNAP %s\n' "$*" >> "$FAKE_ROOT/calls"
  case "${1:-}" in
    list)    [[ -f "$FAKE_ROOT/snap.owns-powershell" ]] ;;
    refresh)
      [[ -f "$FAKE_ROOT/snap.refreshes-to" ]] || return 1
      cat "$FAKE_ROOT/snap.refreshes-to" > "$FAKE_ROOT/pwsh.version" ;;
    *) return 1 ;;
  esac
}
install_pwsh_apt() {
  printf 'APT\n' >> "$FAKE_ROOT/calls"
  [[ -f "$FAKE_ROOT/apt.installs" ]] || return 1
  cat "$FAKE_ROOT/apt.installs" > "$FAKE_ROOT/pwsh.version"
}
install_pwsh_tarball() {
  printf 'TARBALL\n' >> "$FAKE_ROOT/calls"
  [[ -f "$FAKE_ROOT/tarball.installs" ]] || return 1
  cat "$FAKE_ROOT/tarball.installs" > "$FAKE_ROOT/pwsh.version"
}
'@

# A stand-in interpreter that prints whatever version the test last wrote, and
# a stand-in `snap` binary so `command -v snap` answers.
function New-PowerShellSandbox {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: creates a temp sandbox tree the test removes in its finally block; not user-facing state.')]
    param(
        [Parameter(Mandatory)][string]$PwshVersion,
        # /snap/bin is what the repair recognizes as a snap-provided pwsh; any
        # other directory stands for a copy the installer's own sources own.
        [string]$PwshDir = 'snapbin'
    )
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-pwshfloor-{0}" -f [guid]::NewGuid().ToString('N'))
    foreach ($sub in @('snapbin', 'localbin', 'automation')) {
        New-Item -ItemType Directory -Path (Join-Path $root $sub) -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $root 'pwsh.version') -Value $PwshVersion
    $pwshPath = Join-Path (Join-Path $root $PwshDir) 'pwsh'
    Set-Content -LiteralPath $pwshPath -Value "#!/bin/bash`ncat '$root/pwsh.version'`n"
    & chmod +x $pwshPath
    $snapPath = Join-Path (Join-Path $root 'snapbin') 'snap'
    Set-Content -LiteralPath $snapPath -Value "#!/bin/bash`nexit 0`n"
    & chmod +x $snapPath
    return @{ Root = $root; BinDir = (Join-Path $root $PwshDir) }
}

# The requirement list the repair reads its floor out of, laid down at the path
# the installer resolves relative to YURUNA_DIR.
function New-RequirementFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes inside a temp sandbox the test removes; not user-facing state.')]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Body)
    Set-Content -LiteralPath (Join-Path $Root 'automation/Yuruna.Requirement.yml') -Value $Body
}

# Runs a bash body with the lifted functions and the stubs in scope. PATH is
# replaced outright so the sandbox's pwsh is the only one reachable -- the host
# interpreter must never be what a test measures.
function Invoke-InstallerShell {
    param([Parameter(Mandatory)][string]$Body, [hashtable]$Environment = @{})
    $script = @($script:Prelude, $script:Lifted, $Body) -join "`n"
    $file = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-pwshfloor-{0}.sh" -f [guid]::NewGuid().ToString('N'))
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

$script:SampleRequirements = @'
requirements:
  - tool: "PowerShell"
    command: |-
      "$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
    version: "7.6.5 (Core)"
    releases: "https://github.com/powershell/powershell/releases"
  - tool: "git"
    command: |-
      ((git --version) -replace '^git version ','')
    version: "2.53.0"
    releases: "https://git-scm.com/downloads"
'@
}

Describe 'requirement_floor' {
    It 'reads the number out of a version string that carries vendor decoration' {
        # The PowerShell row records "7.6.5 (Core)" because that is what the
        # probe prints; the edition is not part of the comparison.
        $box = New-PowerShellSandbox -PwshVersion '7.6.5'
        try {
            New-RequirementFile -Root $box.Root -Body $script:SampleRequirements
            $r = Invoke-InstallerShell -Body 'requirement_floor PowerShell' `
                -Environment @{ YURUNA_DIR = $box.Root }
            Assert-Match '^7\.6\.5$' $r.Output.Trim() 'the floor is the dotted number, without the edition'
        } finally { Remove-Item -LiteralPath $box.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'reads the row it was asked for, not the first row in the file' {
        $box = New-PowerShellSandbox -PwshVersion '7.6.5'
        try {
            New-RequirementFile -Root $box.Root -Body $script:SampleRequirements
            $r = Invoke-InstallerShell -Body 'requirement_floor git' `
                -Environment @{ YURUNA_DIR = $box.Root }
            Assert-Match '^2\.53\.0$' $r.Output.Trim() 'each row is addressed by its own tool name'
        } finally { Remove-Item -LiteralPath $box.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'answers nothing when the requirement list is not on disk yet' {
        # The repair runs after the checkout, but a run that lost the clone must
        # leave the interpreter alone rather than compare against an empty floor.
        $box = New-PowerShellSandbox -PwshVersion '7.6.5'
        try {
            $r = Invoke-InstallerShell -Body 'requirement_floor PowerShell || echo NO-FLOOR' `
                -Environment @{ YURUNA_DIR = (Join-Path $box.Root 'absent') }
            Assert-Match 'NO-FLOOR' $r.Output 'a missing requirement list yields no floor'
        } finally { Remove-Item -LiteralPath $box.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'version_ge' {
    It 'orders release numbers by field, not as text' {
        # PowerShell reaches a two-digit patch inside a line, and both a string
        # compare and a decimal compare call 7.6.10 the older of the pair.
        $r = Invoke-InstallerShell -Body @'
version_ge 7.6.10 7.6.4 && echo NEWER-WINS
version_ge 7.6.4 7.6.10 && echo WRONG-WAY-ROUND
echo DONE
'@
        Assert-Match 'NEWER-WINS' $r.Output 'version_ge must accept 7.6.10 as newer than 7.6.4'
        Assert-True ($r.Output -notmatch 'WRONG-WAY-ROUND') 'version_ge must reject 7.6.4 as newer than 7.6.10'
    }
    It 'accepts an exact match' {
        $r = Invoke-InstallerShell -Body 'version_ge 7.6.4 7.6.4 && echo AT-FLOOR'
        Assert-Match 'AT-FLOOR' $r.Output 'a version equal to the floor meets it'
    }
    It 'treats an unreadable version as not meeting the floor' {
        $r = Invoke-InstallerShell -Body 'version_ge "" 7.6.4 || echo NOT-MET'
        Assert-Match 'NOT-MET' $r.Output 'an unreadable version cannot satisfy a floor'
    }
}

Describe 'bring_powershell_to_required_version' {
    It 'leaves an interpreter that already meets the floor alone' {
        $box = New-PowerShellSandbox -PwshVersion '7.6.5'
        try {
            New-RequirementFile -Root $box.Root -Body $script:SampleRequirements
            $r = Invoke-InstallerShell -Body 'bring_powershell_to_required_version' `
                -Environment @{ YURUNA_DIR = $box.Root; FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Match 'meets the 7\.6\.5 floor' $r.Output 'a host at the floor is reported and not touched'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $box.Root 'calls'))) 'no upgrade source is reached when the floor is already met'
        } finally { Remove-Item -LiteralPath $box.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'refreshes a snap-provided interpreter in place when that reaches the floor' {
        # A snap advances only through snapd. When its channel carries the floor,
        # the host keeps the provenance its operator chose.
        $box = New-PowerShellSandbox -PwshVersion '7.6.4' -PwshDir 'snapbin'
        try {
            New-RequirementFile -Root $box.Root -Body $script:SampleRequirements
            Set-Content -LiteralPath (Join-Path $box.Root 'snap.owns-powershell') -Value 'yes'
            Set-Content -LiteralPath (Join-Path $box.Root 'snap.refreshes-to') -Value '7.6.5'
            $r = Invoke-InstallerShell -Body 'bring_powershell_to_required_version' `
                -Environment @{ YURUNA_DIR = $box.Root; FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Match 'PowerShell is now 7\.6\.5' $r.Output 'a snap refresh that reaches the floor ends the repair'
            $calls = Get-Content -LiteralPath (Join-Path $box.Root 'calls') -Raw
            Assert-Match 'SNAP refresh powershell' $calls 'snapd is asked first for a snap-provided interpreter'
            Assert-True ($calls -notmatch 'TARBALL') 'the managed sources are not reached once the snap meets the floor'
        } finally { Remove-Item -LiteralPath $box.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'falls through to the managed sources when the snap channel cannot reach the floor' {
        # The reported shape: snapd has nothing newer, so a copy the installer
        # owns has to win the name instead.
        $box = New-PowerShellSandbox -PwshVersion '7.6.4' -PwshDir 'snapbin'
        try {
            New-RequirementFile -Root $box.Root -Body $script:SampleRequirements
            Set-Content -LiteralPath (Join-Path $box.Root 'snap.owns-powershell') -Value 'yes'
            Set-Content -LiteralPath (Join-Path $box.Root 'snap.refreshes-to') -Value '7.6.4'
            Set-Content -LiteralPath (Join-Path $box.Root 'tarball.installs') -Value '7.6.5'
            $r = Invoke-InstallerShell -Body 'bring_powershell_to_required_version' `
                -Environment @{ YURUNA_DIR = $box.Root; FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            $calls = Get-Content -LiteralPath (Join-Path $box.Root 'calls') -Raw
            Assert-Match 'SNAP refresh powershell' $calls 'the in-place refresh is still attempted first'
            Assert-Match 'TARBALL' $calls 'a snap stuck below the floor falls through to the managed sources'
            Assert-Match 'PowerShell is now 7\.6\.5' $r.Output 'the managed source raises the version the name answers with'
        } finally { Remove-Item -LiteralPath $box.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'upgrades an interpreter no package manager here provides' {
        # A hand-unpacked pwsh is neither a snap nor a package; it is still below
        # the floor, and the tarball path is what replaces it. snapd owns no
        # PowerShell here, so the in-place refresh must not be attempted.
        $box = New-PowerShellSandbox -PwshVersion '7.6.4' -PwshDir 'localbin'
        try {
            New-RequirementFile -Root $box.Root -Body $script:SampleRequirements
            Set-Content -LiteralPath (Join-Path $box.Root 'tarball.installs') -Value '7.6.5'
            $r = Invoke-InstallerShell -Body 'bring_powershell_to_required_version' `
                -Environment @{ YURUNA_DIR = $box.Root; FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            $calls = Get-Content -LiteralPath (Join-Path $box.Root 'calls') -Raw
            Assert-True ($calls -notmatch 'SNAP refresh') 'snapd is not asked to refresh an interpreter it does not own'
            Assert-Match 'TARBALL' $calls 'the managed sources are reached'
            Assert-Match 'PowerShell is now 7\.6\.5' $r.Output 'the repair reports the version it reached'
        } finally { Remove-Item -LiteralPath $box.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'reports a floor no source on this host could reach' {
        # Finishing silently below a floor is the failure this whole region
        # closes, so an exhausted repair has to reach the closing summary.
        $box = New-PowerShellSandbox -PwshVersion '7.6.4' -PwshDir 'localbin'
        try {
            New-RequirementFile -Root $box.Root -Body $script:SampleRequirements
            $r = Invoke-InstallerShell -Body 'bring_powershell_to_required_version' `
                -Environment @{ YURUNA_DIR = $box.Root; FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Match 'ISSUE PowerShell is 7\.6\.4 after the upgrade attempt, still below the 7\.6\.5 floor' $r.Output `
                'an unreachable floor is reported rather than passed over'
        } finally { Remove-Item -LiteralPath $box.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'leaves the interpreter alone when no floor can be read' {
        # No floor is not the same as a floor of zero: without a number to
        # compare against, replacing a working interpreter is the worse move.
        $box = New-PowerShellSandbox -PwshVersion '7.6.4' -PwshDir 'localbin'
        try {
            $r = Invoke-InstallerShell -Body 'bring_powershell_to_required_version' `
                -Environment @{ YURUNA_DIR = (Join-Path $box.Root 'absent'); FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Match 'WARN Could not read the PowerShell floor' $r.Output 'the run says why it did not check'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $box.Root 'calls'))) 'no source is reached without a floor to compare against'
        } finally { Remove-Item -LiteralPath $box.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
