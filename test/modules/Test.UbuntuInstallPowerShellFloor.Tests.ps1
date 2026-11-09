<#PSScriptInfo
.VERSION 2026.11.08
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
    in /usr/bin (Microsoft's package) or /usr/local/bin (the tarball), both
    ahead of /snap/bin on the stock PATH.

    Microsoft's package has a trap of its own: when no configured source
    carries powershell, apt answers "already the newest version" and exits 0
    without moving it, so every source is judged by the version the name
    answers with afterward. Such a package moves from the release's own
    .deb, or from Microsoft's 24.04 suite, through apt; a tarball unpacked
    over it would leave dpkg recording a version that is no longer on disk.

    The bodies under test are lifted out of install/ubuntu.kvm.sh rather than
    copied, so a rewrite there is exercised here instead of drifting away from a
    stale duplicate. Everything the repair reaches (pwsh, snap, sudo, apt, curl,
    the installers) is a stub writing to a temporary tree, so the tests run
    anywhere bash does and never touch the host's interpreter or apt.

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
$script:InstallerText = $installerText

# The installer is a top-to-bottom script that elevates, installs packages and
# rewrites the checkout -- it cannot be sourced. Lift the functions under test
# out of it by name; each is defined at column 0 and closed by a lone '}'.
function Get-ShellFunctionBody {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string[]]$Name)
    return Get-YurunaTestShellFunction -Text $Text -Name $Name
}

$script:Lifted = Get-ShellFunctionBody -Text $installerText -Name @(
    'requirement_floor', 'version_ge', 'pwsh_version',
    'bring_powershell_to_required_version', 'run_pwsh_source', 'raise_pwsh_package',
    'powershell_deb_installed', 'apt_package_held', 'pwsh_source', 'pwsh_package_mismatches',
    'bring_powershell_to_newest')

# The top-level lines that add an apt-installed PowerShell to the package list. They
# run before any function is defined that could hold them, so they are lifted as text.
$aptListMatch = [regex]::Match($installerText, '(?ms)^if powershell_deb_installed && ! apt_package_held powershell; then\n.*?^fi\n')
if (-not $aptListMatch.Success) { throw 'install/ubuntu.kvm.sh adds no apt-installed PowerShell to its package list' }
$script:AptListBlock = $aptListMatch.Value

# The top-level lines that install pwsh when it is absent, with the check that ends
# the run when no source could.
$firstInstallMatch = [regex]::Match($installerText, '(?ms)^if ! command -v pwsh >/dev/null 2>&1; then\n.*?^fi\ncommand -v pwsh >/dev/null 2>&1 \|\| die [^\n]*\n')
if (-not $firstInstallMatch.Success) { throw 'install/ubuntu.kvm.sh installs no pwsh when it is absent' }
$script:FirstInstallBlock = $firstInstallMatch.Value

# Stubs stand in for everything the repair reaches outside its own logic. pwsh
# reads its version from a file the test rewrites, so a stubbed upgrade can move
# it the way a real one would; snap and the installers only record that they
# were reached.
$script:Prelude = @'
set -euo pipefail
ARCH="${ARCH:-x86_64}"
log()  { printf 'LOG %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
die()  { printf 'DIE %s\n' "$*"; exit 1; }
note_issue() { printf 'ISSUE %s\n' "$*"; }
# Runs what it is given, without the environment assignments sudo would set first.
sudo() { while [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do shift; done; "$@"; }
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
# apt.installs is the version apt leaves: equal to the installed one, apt has no
# source that offers powershell newer, and says so with a success status.
install_pwsh_apt() {
  printf 'APT\n' >> "$FAKE_ROOT/calls"
  [[ -f "$FAKE_ROOT/apt.installs" ]] || return 1
  if [[ "$(cat "$FAKE_ROOT/apt.installs")" == "$(cat "$FAKE_ROOT/pwsh.version" 2>/dev/null)" ]]; then
    printf 'powershell is already the newest version (%s-1.deb).\n' "$(cat "$FAKE_ROOT/apt.installs")"
  fi
  cat "$FAKE_ROOT/apt.installs" > "$FAKE_ROOT/pwsh.version"
}
install_pwsh_tarball() {
  printf 'TARBALL %s\n' "${PWSH_VERSION:-latest}" >> "$FAKE_ROOT/calls"
  [[ -f "$FAKE_ROOT/tarball.installs" ]] || return 1
  if [[ -n "${PWSH_VERSION:-}" ]]; then printf '%s\n' "$PWSH_VERSION" > "$FAKE_ROOT/pwsh.version"
  else cat "$FAKE_ROOT/tarball.installs" > "$FAKE_ROOT/pwsh.version"; fi
}
# The two package sources end the way the real ones do: <source>.fails holds the
# status (the release .deb: 1 not fetched or verified, 2 apt declined it; the 24.04
# suite: 1 not added, 2 apt declined), and an install leaves Microsoft's package
# installed with every file as dpkg recorded it.
install_pwsh_deb() {
  printf 'DEB %s %s\n' "${PWSH_VERSION:-latest}" "$ARCH" >> "$FAKE_ROOT/calls"
  if [[ -f "$FAKE_ROOT/deb.fails" ]]; then return "$(cat "$FAKE_ROOT/deb.fails")"; fi
  [[ -f "$FAKE_ROOT/deb.installs" ]] || return 1
  if [[ -n "${PWSH_VERSION:-}" ]]; then printf '%s\n' "$PWSH_VERSION" > "$FAKE_ROOT/pwsh.version"
  else cat "$FAKE_ROOT/deb.installs" > "$FAKE_ROOT/pwsh.version"; fi
  : > "$FAKE_ROOT/dpkg.owns-powershell"
  rm -f "$FAKE_ROOT/dpkg.mismatches"
}
install_pwsh_noble() {
  printf 'NOBLE %s\n' "${PWSH_VERSION:-newest}" >> "$FAKE_ROOT/calls"
  if [[ -f "$FAKE_ROOT/noble.fails" ]]; then return "$(cat "$FAKE_ROOT/noble.fails")"; fi
  [[ -f "$FAKE_ROOT/noble.installs" ]] || return 1
  cat "$FAKE_ROOT/noble.installs" > "$FAKE_ROOT/pwsh.version"
  : > "$FAKE_ROOT/dpkg.owns-powershell"
  rm -f "$FAKE_ROOT/dpkg.mismatches"
}
# dpkg -V prints one line for each file of the package that no longer matches what
# dpkg recorded ("??5??????   <path>", "missing     <path>") and exits 0 whatever it
# finds.
dpkg() {
  [[ "${1:-}" == -V ]] || return 1
  if [[ -f "$FAKE_ROOT/dpkg.mismatches" ]]; then cat "$FAKE_ROOT/dpkg.mismatches"; fi
}
# The release feed, the package database and the hold list read files the test
# writes, so no case reaches GitHub, dpkg or apt. dpkg and apt-mark read the same
# selection, so a held package reads "hold ok installed", as dpkg prints it.
pwsh_latest_release() {
  [[ -f "$FAKE_ROOT/github.latest" ]] || return 1
  cat "$FAKE_ROOT/github.latest"
}
dpkg-query() {
  [[ -f "$FAKE_ROOT/dpkg.owns-powershell" ]] || return 1
  if [[ -f "$FAKE_ROOT/apt.holds" ]] && grep -x powershell "$FAKE_ROOT/apt.holds" >/dev/null; then printf 'hold ok installed'
  else printf 'install ok installed'; fi
}
apt-mark() {
  [[ "${1:-}" == showhold ]] || return 1
  if [[ -f "$FAKE_ROOT/apt.holds" ]]; then cat "$FAKE_ROOT/apt.holds"; fi
}
# Only the package list's dry run of powershell reaches apt-get here; a candidate
# whose dependencies this release cannot meet fails it, as apt's solver does.
apt-get() {
  printf 'APT-GET %s\n' "$*" >> "$FAKE_ROOT/calls"
  [[ ! -f "$FAKE_ROOT/apt.candidate-uninstallable" ]]
}
yuruna_cleanup_tmp_paths() { :; }
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
    $root = New-YurunaTestTempDir -Prefix 'yuruna-pwshfloor'
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
    return Invoke-YurunaTestShell -Body (@($script:Prelude, $script:Lifted, $Body) -join "`n") -Environment $Environment
}

# The sources a case reached, in order, or nothing when it reached none. The floor
# repair asks snapd whether it owns a PowerShell before any source runs; with
# -WithoutSnapProbe that question is left out, so a pattern can name every source.
function Read-SourceCall {
    param([Parameter(Mandatory)][string]$Root, [switch]$WithoutSnapProbe)
    $path = Join-Path $Root 'calls'
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    $calls = Get-Content -LiteralPath $path -Raw
    if ($WithoutSnapProbe) { $calls = $calls -replace '(?m)^SNAP list powershell\r?\n', '' }
    return $calls
}

# Writes fixture files into a sandbox: name -> content.
function Set-SandboxFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes inside a temp sandbox the test removes; not user-facing state.')]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][hashtable]$File)
    foreach ($name in $File.Keys) { Set-Content -LiteralPath (Join-Path $Root $name) -Value $File[$name] }
}

# The release's hash list as GitHub publishes it: UTF-16 LE with a BOM and CRLF line
# ends, naming the LTS packages, the other packages and the tarballs beside the asset
# the case wants.
function Write-ReleaseHashList {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes inside a temp sandbox the test removes; not user-facing state.')]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Asset, [Parameter(Mandatory)][string]$Digest)
    $siblings = @('powershell-7.6.9-linux-arm64.tar.gz', 'powershell-7.6.9-linux-musl-x64.tar.gz',
        'powershell-7.6.9-linux-x64-fxdependent.tar.gz', 'powershell-7.6.9-linux-x64-musl-noopt-fxdependent.tar.gz',
        'powershell-7.6.9-linux-x64.tar.gz', 'powershell-lts_7.6.9-1.deb_amd64.deb', 'powershell-lts_7.6.9-1.deb_arm64.deb',
        'powershell_7.6.9-1.deb_amd64.deb', 'powershell_7.6.9-1.deb_arm64.deb') | Where-Object { $_ -ne $Asset }
    $lines = @($siblings | ForEach-Object { "$('ab' * 32) *$_" }) + "$Digest *$Asset"
    [IO.File]::WriteAllText((Join-Path $Root 'hashes.sha256'), (($lines -join "`r`n") + "`r`n"), [Text.UnicodeEncoding]::new($false, $true))
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
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'reads the row it was asked for, not the first row in the file' {
        $box = New-PowerShellSandbox -PwshVersion '7.6.5'
        try {
            New-RequirementFile -Root $box.Root -Body $script:SampleRequirements
            $r = Invoke-InstallerShell -Body 'requirement_floor git' `
                -Environment @{ YURUNA_DIR = $box.Root }
            Assert-Match '^2\.53\.0$' $r.Output.Trim() 'each row is addressed by its own tool name'
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'answers nothing when the requirement list is not on disk yet' {
        # The repair runs after the checkout, but a run that lost the clone must
        # leave the interpreter alone rather than compare against an empty floor.
        $box = New-PowerShellSandbox -PwshVersion '7.6.5'
        try {
            $r = Invoke-InstallerShell -Body 'requirement_floor PowerShell || echo NO-FLOOR' `
                -Environment @{ YURUNA_DIR = (Join-Path $box.Root 'absent') }
            Assert-Match 'NO-FLOOR' $r.Output 'a missing requirement list yields no floor'
        } finally { Remove-YurunaTestTempDir $box.Root }
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
        } finally { Remove-YurunaTestTempDir $box.Root }
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
        } finally { Remove-YurunaTestTempDir $box.Root }
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
        } finally { Remove-YurunaTestTempDir $box.Root }
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
        } finally { Remove-YurunaTestTempDir $box.Root }
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
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'moves Microsoft''s package that no configured source carries from the release .deb, through apt' {
        # No configured source carries powershell, so apt answers "already the newest
        # version" and exits 0 -- in the package list, which already asked those
        # sources, so the repair does not ask them again.
        $box = New-PowerShellSandbox -PwshVersion '7.6.4' -PwshDir 'localbin'
        try {
            New-RequirementFile -Root $box.Root -Body $script:SampleRequirements
            Set-SandboxFile -Root $box.Root -File @{ 'dpkg.owns-powershell' = 'yes'; 'apt.installs' = '7.6.4'
                'deb.installs' = '7.6.5'; 'noble.installs' = '7.6.5'; 'tarball.installs' = '7.6.5' }
            $r = Invoke-InstallerShell -Body 'bring_powershell_to_required_version' `
                -Environment @{ YURUNA_DIR = $box.Root; FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Match '(?s)^DEB latest x86_64\s*$' (Read-SourceCall -Root $box.Root -WithoutSnapProbe) `
                'the release .deb, and nothing else: no apt no-op, no 24.04 suite, no tarball over the package'
            Assert-Match 'PowerShell is now 7\.6\.5' $r.Output 'the repair reports the version it reached'
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'installs nothing when <Case> is below the floor' -TestCases @(
        @{ Case = 'the operator''s PWSH_VERSION'; Pin = '7.6.4'; Latest = '7.6.9'; Expected = 'PWSH_VERSION names 7\.6\.4' }
        @{ Case = 'the release GitHub marks as the latest'; Pin = $null; Latest = '7.4.22'; Expected = 'GitHub''s newest release is 7\.4\.22' }
    ) {
        param([string]$Case, [AllowNull()][string]$Pin, [string]$Latest, [string]$Expected)
        $null = $Case
        # GitHub's latest follows publish order, and an older line can be published
        # after the newest one; installing it would downgrade the interpreter.
        $box = New-PowerShellSandbox -PwshVersion '7.6.0' -PwshDir 'localbin'
        try {
            New-RequirementFile -Root $box.Root -Body $script:SampleRequirements
            Set-SandboxFile -Root $box.Root -File @{ 'dpkg.owns-powershell' = 'yes'; 'github.latest' = $Latest
                'deb.installs' = '7.6.5'; 'noble.installs' = '7.6.5'; 'tarball.installs' = '7.6.5' }
            $environment = @{ YURUNA_DIR = $box.Root; FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            if ($Pin) { $environment.PWSH_VERSION = $Pin }
            $r = Invoke-InstallerShell -Body 'bring_powershell_to_required_version' -Environment $environment
            Assert-Equal -Expected '' -Actual (Read-SourceCall -Root $box.Root -WithoutSnapProbe).Trim() -Because 'no source is asked for a release below the floor'
            Assert-Match "ISSUE PowerShell 7\.6\.0 is below the 7\.6\.5 floor, and $Expected, which is below it too, so this installer installed nothing; re-run it with PWSH_VERSION set to 7\.6\.5 or later\." $r.Output
            Assert-True (@($r.Output -split "`n" | Where-Object { $_ -like 'ISSUE *' }).Count -eq 1) 'one issue, not one per source'
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'tries Microsoft''s 24.04 suite when the release .deb <Case>' -TestCases @(
        @{ Case = 'could not be fetched or verified'; Status = '1' }
        @{ Case = 'was declined by apt'; Status = '2' }
    ) {
        param([string]$Case, [string]$Status)
        $null = $Case
        $box = New-PowerShellSandbox -PwshVersion '7.6.4' -PwshDir 'localbin'
        try {
            New-RequirementFile -Root $box.Root -Body $script:SampleRequirements
            Set-SandboxFile -Root $box.Root -File @{ 'dpkg.owns-powershell' = 'yes'; 'apt.installs' = '7.6.4'
                'deb.fails' = $Status; 'noble.installs' = '7.6.5'; 'tarball.installs' = '7.6.5' }
            $r = Invoke-InstallerShell -Body 'bring_powershell_to_required_version' `
                -Environment @{ YURUNA_DIR = $box.Root; FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            $calls = Read-SourceCall -Root $box.Root -WithoutSnapProbe
            Assert-Match '(?s)^DEB latest x86_64\s+NOBLE newest\s*$' $calls 'the release .deb, then the 24.04 suite, in that order'
            Assert-Match 'PowerShell is now 7\.6\.5' $r.Output
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'reports the floor, and unpacks no tarball over the package, when no package source can reach it' {
        $box = New-PowerShellSandbox -PwshVersion '7.6.4' -PwshDir 'localbin'
        try {
            New-RequirementFile -Root $box.Root -Body $script:SampleRequirements
            Set-SandboxFile -Root $box.Root -File @{ 'dpkg.owns-powershell' = 'yes'; 'apt.installs' = '7.6.4'
                'deb.fails' = '1'; 'noble.fails' = '1'; 'tarball.installs' = '7.6.5' }
            $r = Invoke-InstallerShell -Body 'bring_powershell_to_required_version; echo "WHY $PWSH_UPGRADE_WHY"' `
                -Environment @{ YURUNA_DIR = $box.Root; FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-True ((Read-SourceCall -Root $box.Root) -notmatch 'TARBALL') 'a tarball over the package would leave dpkg recording the old version'
            Assert-Match 'ISSUE PowerShell is 7\.6\.4 after the upgrade attempt, still below the 7\.6\.5 floor' $r.Output
            Assert-Match 'WHY the release \.deb could not be fetched or verified, and Microsoft''s Ubuntu 24\.04 suite could not be added' $r.Output `
                'the closing report learns why each package source fell short'
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'says in the floor issue why <Case> fell short' -TestCases @(
        @{ Case = 'the package sources'; Dpkg = $true; NobleRc = '1'
            Expected = 'the release \.deb could not be fetched or verified, and Microsoft''s Ubuntu 24\.04 suite could not be added' }
        @{ Case = 'every source'; Dpkg = $false; NobleRc = '1'
            Expected = 'the release \.deb could not be fetched or verified, and Microsoft''s Ubuntu 24\.04 suite could not be added, and the release tarball could not be installed' }
        @{ Case = 'the package sources on a host that is not Ubuntu'; Dpkg = $true; NobleRc = '3'
            Expected = 'the release \.deb could not be fetched or verified, and Microsoft''s Ubuntu 24\.04 suite is added only on Ubuntu hosts' }
    ) {
        param([string]$Case, [bool]$Dpkg, [string]$NobleRc, [string]$Expected)
        $null = $Case
        # GitHub and Microsoft's repository both out of reach: each source's own failure
        # scrolls past in the run, and the closing summary is what the operator reads.
        $box = New-PowerShellSandbox -PwshVersion '7.6.4' -PwshDir 'localbin'
        try {
            New-RequirementFile -Root $box.Root -Body $script:SampleRequirements
            Set-SandboxFile -Root $box.Root -File @{ 'deb.fails' = '1'; 'noble.fails' = $NobleRc }
            if ($Dpkg) { Set-SandboxFile -Root $box.Root -File @{ 'dpkg.owns-powershell' = 'yes' } }
            $r = Invoke-InstallerShell -Body 'bring_powershell_to_required_version' `
                -Environment @{ YURUNA_DIR = $box.Root; FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Match ('(?m)^ISSUE PowerShell is 7\.6\.4 after the upgrade attempt, still below the 7\.6\.5 floor: ' + $Expected + '\.$') $r.Output
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'replaces no package the operator holds, and says how to release it' {
        $box = New-PowerShellSandbox -PwshVersion '7.6.4' -PwshDir 'localbin'
        try {
            New-RequirementFile -Root $box.Root -Body $script:SampleRequirements
            Set-SandboxFile -Root $box.Root -File @{ 'dpkg.owns-powershell' = 'yes'; 'apt.holds' = 'powershell'
                'apt.installs' = '7.6.5'; 'deb.installs' = '7.6.5'; 'noble.installs' = '7.6.5'; 'tarball.installs' = '7.6.5' }
            $r = Invoke-InstallerShell -Body 'bring_powershell_to_required_version' `
                -Environment @{ YURUNA_DIR = $box.Root; FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-True ((Read-SourceCall -Root $box.Root) -notmatch '(?m)^(APT|DEB|NOBLE|TARBALL)') 'no source replaces a held package'
            Assert-Match 'ISSUE PowerShell 7\.6\.4 is below the 7\.6\.5 floor, and Microsoft''s powershell package is held with apt-mark hold' $r.Output
            Assert-Match "sudo apt-mark unhold powershell" $r.Output 'the issue names the command that releases the hold'
            Assert-True (@($r.Output -split "`n" | Where-Object { $_ -like 'ISSUE *' }).Count -eq 1) 'the hold is one issue, not one per source'
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'still tries the next source when <Case> dies' -TestCases @(
        @{ Case = 'the apt path'; Dpkg = $false; Body = "install_pwsh_apt() { printf 'APT\n' >> `"`$FAKE_ROOT/calls`"; exit 1; }"; Expected = '(?s)^APT\s+DEB latest x86_64\s*$' }
        @{ Case = 'the release .deb'; Dpkg = $true; Body = "install_pwsh_deb() { printf 'DEB\n' >> `"`$FAKE_ROOT/calls`"; exit 1; }"; Expected = '(?s)^DEB\s+NOBLE newest\s*$' }
    ) {
        param([string]$Case, [bool]$Dpkg, [string]$Body, [string]$Expected)
        $null = $Case
        # die() is exit 1: a key gpg cannot read ends the apt attempt this way, and a
        # checksum that does not match ends the release .deb. The host's own Microsoft
        # repo is asked only when no package is installed.
        $box = New-PowerShellSandbox -PwshVersion '7.6.4' -PwshDir 'localbin'
        try {
            New-RequirementFile -Root $box.Root -Body $script:SampleRequirements
            Set-SandboxFile -Root $box.Root -File @{ 'deb.installs' = '7.6.5'; 'noble.installs' = '7.6.5' }
            if ($Dpkg) { Set-SandboxFile -Root $box.Root -File @{ 'dpkg.owns-powershell' = 'yes' } }
            $r = Invoke-InstallerShell -Body ($Body + "`nbring_powershell_to_required_version") `
                -Environment @{ YURUNA_DIR = $box.Root; FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Match $Expected (Read-SourceCall -Root $box.Root -WithoutSnapProbe) 'a source that gives up ends its own attempt only'
            Assert-Match 'PowerShell is now 7\.6\.5' $r.Output
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'gives the operator''s PWSH_VERSION to both package sources' {
        $box = New-PowerShellSandbox -PwshVersion '7.6.4' -PwshDir 'localbin'
        try {
            New-RequirementFile -Root $box.Root -Body $script:SampleRequirements
            Set-SandboxFile -Root $box.Root -File @{ 'dpkg.owns-powershell' = 'yes'; 'deb.fails' = '1'; 'noble.installs' = '7.6.8' }
            $null = Invoke-InstallerShell -Body 'bring_powershell_to_required_version' `
                -Environment @{ YURUNA_DIR = $box.Root; FAKE_ROOT = $box.Root; PWSH_VERSION = '7.6.8'; PATH = "$($box.BinDir):/usr/bin:/bin" }
            $calls = Read-SourceCall -Root $box.Root
            Assert-Match '(?m)^DEB 7\.6\.8 x86_64$' $calls 'the release .deb is the one PWSH_VERSION names'
            Assert-Match '(?m)^NOBLE 7\.6\.8$' $calls 'apt is asked for the version PWSH_VERSION names'
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'on aarch64 <Case>' -TestCases @(
        @{ Case = 'moves Microsoft''s arm64 package from the release .deb'; Dpkg = $true; Deb = '7.6.5'; Expected = '(?s)^DEB latest aarch64\s*$'; Reached = $true }
        @{ Case = 'reports a package the arm64 release .deb cannot move, with no 24.04 suite and no tarball'; Dpkg = $true; Deb = $null; Expected = '(?s)^DEB latest aarch64\s*$'; Reached = $false }
        @{ Case = 'keeps the tarball for a copy no package owns'; Dpkg = $false; Deb = '7.6.5'; Expected = '(?s)^TARBALL latest\s*$'; Reached = $true }
    ) {
        param([string]$Case, [bool]$Dpkg, [AllowNull()][string]$Deb, [string]$Expected, [bool]$Reached)
        $null = $Case
        # No Microsoft Ubuntu suite carries an arm64 powershell, so neither apt nor the
        # 24.04 suite is a source here.
        $box = New-PowerShellSandbox -PwshVersion '7.6.4' -PwshDir 'localbin'
        try {
            New-RequirementFile -Root $box.Root -Body $script:SampleRequirements
            Set-SandboxFile -Root $box.Root -File @{ 'noble.installs' = '7.6.5'; 'apt.installs' = '7.6.5'; 'tarball.installs' = '7.6.5' }
            if ($Dpkg) { Set-SandboxFile -Root $box.Root -File @{ 'dpkg.owns-powershell' = 'yes' } }
            if ($Deb) { Set-SandboxFile -Root $box.Root -File @{ 'deb.installs' = $Deb } } else { Set-SandboxFile -Root $box.Root -File @{ 'deb.fails' = '1' } }
            $r = Invoke-InstallerShell -Body 'bring_powershell_to_required_version' `
                -Environment @{ ARCH = 'aarch64'; YURUNA_DIR = $box.Root; FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Match $Expected (Read-SourceCall -Root $box.Root -WithoutSnapProbe)
            if ($Reached) { Assert-Match 'PowerShell is now 7\.6\.5' $r.Output }
            else { Assert-Match 'ISSUE PowerShell is 7\.6\.4 after the upgrade attempt, still below the 7\.6\.5 floor' $r.Output }
        } finally { Remove-YurunaTestTempDir $box.Root }
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
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
}

Describe 'pwsh_source' {
    It 'names <Expected> for <Case>' -TestCases @(
        @{ Case = 'a snap'; Path = '/snap/bin/pwsh'; Resolved = '/usr/bin/snap'; Dpkg = $false; Expected = 'snap' }
        @{ Case = 'the package apt installed from Microsoft''s repository'; Path = '/usr/bin/pwsh'; Resolved = '/opt/microsoft/powershell/7/pwsh'; Dpkg = $true; Expected = 'apt' }
        @{ Case = 'that package, held with apt-mark hold'; Path = '/usr/bin/pwsh'; Resolved = '/opt/microsoft/powershell/7/pwsh'; Dpkg = $true; Held = $true; Expected = 'apt' }
        @{ Case = 'a tarball this installer unpacked'; Path = '/usr/local/bin/pwsh'; Resolved = '/opt/microsoft/powershell/7/pwsh'; Dpkg = $false; Expected = 'tarball' }
        @{ Case = 'a copy from anywhere else'; Path = '/home/op/.dotnet/tools/pwsh'; Resolved = '/home/op/.dotnet/tools/pwsh'; Dpkg = $false; Expected = 'other' }
    ) {
        param([string]$Case, [string]$Path, [string]$Resolved, [bool]$Dpkg, [bool]$Held, [string]$Expected)
        $null = $Case
        # The deb and a tarball share /opt/microsoft/powershell/7, so only dpkg can
        # tell which source owns the copy there. A hold changes dpkg's status to
        # "hold ok installed"; the package still owns the tree.
        $box = New-PowerShellSandbox -PwshVersion '7.6.6' -PwshDir 'localbin'
        try {
            if ($Dpkg) { Set-Content -LiteralPath (Join-Path $box.Root 'dpkg.owns-powershell') -Value 'yes' }
            if ($Held) { Set-Content -LiteralPath (Join-Path $box.Root 'apt.holds') -Value 'powershell' }
            $r = Invoke-InstallerShell -Body "readlink() { printf '%s\n' '$Resolved'; }`npwsh_source '$Path'" `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Equal -Expected $Expected -Actual $r.Output.Trim()
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
}

Describe 'the apt package list carries an apt-installed PowerShell' {
    It '<Case>' -TestCases @(
        @{ Case = 'adds powershell when apt installed it'; Dpkg = $true; Held = $false; Expected = 'qemu-utils powershell' }
        @{ Case = 'leaves out a powershell the operator holds, which would make apt refuse the list'; Dpkg = $true; Held = $true; Expected = 'qemu-utils' }
        @{ Case = 'leaves out a powershell apt did not install'; Dpkg = $false; Held = $false; Expected = 'qemu-utils' }
    ) {
        param([string]$Case, [bool]$Dpkg, [bool]$Held, [string]$Expected)
        $null = $Case
        $box = New-PowerShellSandbox -PwshVersion '7.6.6' -PwshDir 'localbin'
        try {
            if ($Dpkg) { Set-Content -LiteralPath (Join-Path $box.Root 'dpkg.owns-powershell') -Value 'yes' }
            if ($Held) { Set-Content -LiteralPath (Join-Path $box.Root 'apt.holds') -Value "linux-image-generic`npowershell" }
            $r = Invoke-InstallerShell -Body ("APT_PACKAGES=(qemu-utils)`n" + $script:AptListBlock + 'echo "${APT_PACKAGES[*]}"') `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Equal -Expected $Expected -Actual $r.Output.Trim()
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'leaves out a candidate apt cannot install, which would make apt refuse the whole list' {
        # A newer powershell whose dependencies this release cannot meet fails apt's
        # dry run of the whole list, and that dry run ends the install.
        $box = New-PowerShellSandbox -PwshVersion '7.6.6' -PwshDir 'localbin'
        try {
            Set-SandboxFile -Root $box.Root -File @{ 'dpkg.owns-powershell' = 'yes'; 'apt.candidate-uninstallable' = 'yes' }
            $r = Invoke-InstallerShell -Body ("APT_PACKAGES=(qemu-utils)`n" + $script:AptListBlock + 'echo "LIST ${APT_PACKAGES[*]}"; echo "LEFT-OUT ${PWSH_APT_UNINSTALLABLE:-0}"') `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Match '(?m)^LIST qemu-utils$' $r.Output 'the package step goes on without powershell'
            Assert-Match '(?m)^LEFT-OUT 1$' $r.Output 'the closing report learns why powershell stayed'
            Assert-Match 'WARN apt cannot install the powershell its sources offer here' $r.Output 'the run says so where it happens'
            Assert-Match 'install -y --no-install-recommends --simulate powershell' (Read-SourceCall -Root $box.Root) 'apt is asked about powershell alone'
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'reads a hold that apt-mark lists after many others' {
        # With pipefail, a grep that stops at its first match can fail the
        # producer with SIGPIPE, and the held package would read as not held.
        $box = New-PowerShellSandbox -PwshVersion '7.6.6' -PwshDir 'localbin'
        try {
            $holds = @('powershell') + @(1..60000 | ForEach-Object { "package-$_" })
            Set-Content -LiteralPath (Join-Path $box.Root 'apt.holds') -Value $holds
            $r = Invoke-InstallerShell -Body 'if apt_package_held powershell; then echo HELD; else echo NOT-HELD; fi' `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Equal -Expected 'HELD' -Actual $r.Output.Trim()
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
}

Describe 'bring_powershell_to_newest' {
    It 'replaces a tarball copy that met the floor with the newest release' {
        # The reported shape: 7.6.6 met its floor, so nothing moved it although
        # 7.6.9 was out.
        $box = New-PowerShellSandbox -PwshVersion '7.6.6' -PwshDir 'localbin'
        try {
            Set-Content -LiteralPath (Join-Path $box.Root 'github.latest') -Value '7.6.9'
            Set-Content -LiteralPath (Join-Path $box.Root 'tarball.installs') -Value 'unused'
            $r = Invoke-InstallerShell -Body "pwsh_source() { echo tarball; }`nbring_powershell_to_newest; pwsh_version" `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Match 'TARBALL 7\.6\.9' (Get-Content -LiteralPath (Join-Path $box.Root 'calls') -Raw) 'the newest release is what the tarball path is asked for'
            Assert-Match '(?m)^7\.6\.9$' $r.Output 'the name answers with the newest release afterward'
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'leaves a tarball copy that is already the newest release' {
        $box = New-PowerShellSandbox -PwshVersion '7.6.9' -PwshDir 'localbin'
        try {
            Set-Content -LiteralPath (Join-Path $box.Root 'github.latest') -Value '7.6.9'
            $r = Invoke-InstallerShell -Body "pwsh_source() { echo tarball; }`nbring_powershell_to_newest" `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Match 'PowerShell 7\.6\.9 is at or past 7\.6\.9' $r.Output 'a current copy is reported and not touched'
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $box.Root 'calls'))) 'no source is reached for a current copy'
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'installs the operator''s PWSH_VERSION, never anything newer and never a downgrade' {
        $box = New-PowerShellSandbox -PwshVersion '7.6.6' -PwshDir 'localbin'
        try {
            Set-Content -LiteralPath (Join-Path $box.Root 'github.latest') -Value '7.6.9'
            Set-Content -LiteralPath (Join-Path $box.Root 'tarball.installs') -Value 'unused'
            $null = Invoke-InstallerShell -Body "pwsh_source() { echo tarball; }`nbring_powershell_to_newest" `
                -Environment @{ FAKE_ROOT = $box.Root; PWSH_VERSION = '7.6.8'; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Match 'TARBALL 7\.6\.8' (Get-Content -LiteralPath (Join-Path $box.Root 'calls') -Raw) 'PWSH_VERSION names the release to install'
            Remove-Item -LiteralPath (Join-Path $box.Root 'calls')
            $r = Invoke-InstallerShell -Body "pwsh_source() { echo tarball; }`nbring_powershell_to_newest" `
                -Environment @{ FAKE_ROOT = $box.Root; PWSH_VERSION = '7.6.4'; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $box.Root 'calls'))) 'an older PWSH_VERSION does not downgrade the interpreter'
            Assert-Match 'at or past 7\.6\.4' $r.Output
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'keeps the copy and the run when <Case>' -TestCases @(
        @{ Case = 'GitHub names no release'; Latest = $null; Installs = $false; Expected = 'GitHub did not name PowerShell''s newest release; the tarball copy keeps 7\.6\.6' }
        @{ Case = 'the tarball cannot be installed'; Latest = '7.6.9'; Installs = $false; Expected = 'the PowerShell 7\.6\.9 tarball could not be installed; PowerShell stays at 7\.6\.6' }
    ) {
        param([string]$Case, [AllowNull()][string]$Latest, [bool]$Installs, [string]$Expected)
        $null = $Case, $Installs
        # This host already runs a working interpreter, so a source that gives up
        # ends the attempt, not the install: the run goes on to the next line.
        $box = New-PowerShellSandbox -PwshVersion '7.6.6' -PwshDir 'localbin'
        try {
            if ($Latest) { Set-Content -LiteralPath (Join-Path $box.Root 'github.latest') -Value $Latest }
            $r = Invoke-InstallerShell -Body "pwsh_source() { echo tarball; }`ninstall_pwsh_tarball() { exit 1; }`nbring_powershell_to_newest; echo CONTINUED; pwsh_version" `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Match $Expected $r.Output
            Assert-Match 'CONTINUED' $r.Output 'the install goes on'
            Assert-Match '(?m)^7\.6\.6$' $r.Output 'the working interpreter stays'
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'asks snapd to refresh a snap' {
        $box = New-PowerShellSandbox -PwshVersion '7.6.6' -PwshDir 'snapbin'
        try {
            Set-Content -LiteralPath (Join-Path $box.Root 'snap.refreshes-to') -Value '7.6.9'
            $r = Invoke-InstallerShell -Body "pwsh_source() { echo snap; }`nbring_powershell_to_newest; pwsh_version" `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            $calls = Get-Content -LiteralPath (Join-Path $box.Root 'calls') -Raw
            Assert-Match 'SNAP refresh powershell' $calls 'snapd moves a snap'
            Assert-True ($calls -notmatch 'TARBALL') 'a snap is not replaced by a tarball'
            Assert-Match '(?m)^7\.6\.9$' $r.Output
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'leaves a copy from a source this installer does not manage to that source' {
        # The closing report names what is newer.
        $box = New-PowerShellSandbox -PwshVersion '7.6.6' -PwshDir 'localbin'
        try {
            Set-Content -LiteralPath (Join-Path $box.Root 'github.latest') -Value '7.6.9'
            $null = Invoke-InstallerShell -Body "pwsh_source() { echo other; }`nbring_powershell_to_newest" `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $box.Root 'calls'))) 'no source is reached for an other copy'
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'moves Microsoft''s package that apt left behind GitHub''s newest release through apt from the release .deb' {
        # The package list moved the package only as far as a configured source offers,
        # and on this shape no source carries powershell at all.
        $box = New-PowerShellSandbox -PwshVersion '7.6.6' -PwshDir 'localbin'
        try {
            Set-SandboxFile -Root $box.Root -File @{ 'github.latest' = '7.6.9'; 'dpkg.owns-powershell' = 'yes'; 'deb.installs' = 'unused'
                'noble.installs' = '7.6.9'; 'tarball.installs' = '7.6.9' }
            $r = Invoke-InstallerShell -Body "pwsh_source() { echo apt; }`nbring_powershell_to_newest; pwsh_version" `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            $calls = Read-SourceCall -Root $box.Root
            Assert-Match '(?s)^DEB 7\.6\.9 x86_64\s*$' $calls 'the newest release''s .deb, and nothing else'
            Assert-Match '(?m)^7\.6\.9$' $r.Output 'the name answers with the newest release afterward'
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'falls back to Microsoft''s 24.04 suite, never to a tarball over the package' {
        $box = New-PowerShellSandbox -PwshVersion '7.6.6' -PwshDir 'localbin'
        try {
            Set-SandboxFile -Root $box.Root -File @{ 'github.latest' = '7.6.9'; 'dpkg.owns-powershell' = 'yes'; 'deb.fails' = '2'
                'noble.installs' = '7.6.9'; 'tarball.installs' = '7.6.9' }
            $r = Invoke-InstallerShell -Body "pwsh_source() { echo apt; }`nbring_powershell_to_newest; pwsh_version" `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            $calls = Read-SourceCall -Root $box.Root
            Assert-Match '(?s)^DEB 7\.6\.9 x86_64\s+NOBLE newest\s*$' $calls 'apt installs powershell from the 24.04 suite when the release .deb fell short'
            Assert-Match '(?m)^7\.6\.9$' $r.Output
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'keeps the package and the run, and says why, when no package source can move it' {
        $box = New-PowerShellSandbox -PwshVersion '7.6.6' -PwshDir 'localbin'
        try {
            Set-SandboxFile -Root $box.Root -File @{ 'github.latest' = '7.6.9'; 'dpkg.owns-powershell' = 'yes'; 'deb.fails' = '1'
                'noble.fails' = '2'; 'tarball.installs' = '7.6.9' }
            $r = Invoke-InstallerShell -Body "pwsh_source() { echo apt; }`nbring_powershell_to_newest; echo CONTINUED; pwsh_version" `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-True ((Read-SourceCall -Root $box.Root) -notmatch 'TARBALL') 'no tarball unpacks over the package'
            Assert-Match 'WARN   PowerShell 7\.6\.9 could not be installed: the release \.deb could not be fetched or verified, and apt did not install powershell from Microsoft''s apt sources; PowerShell stays at 7\.6\.6' $r.Output
            Assert-Match 'CONTINUED' $r.Output 'the install goes on'
            Assert-Match '(?m)^7\.6\.6$' $r.Output 'the working interpreter stays'
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'gives the release .deb the operator''s PWSH_VERSION, and apt the same version' {
        $box = New-PowerShellSandbox -PwshVersion '7.6.6' -PwshDir 'localbin'
        try {
            Set-SandboxFile -Root $box.Root -File @{ 'github.latest' = '7.6.9'; 'dpkg.owns-powershell' = 'yes'; 'deb.fails' = '1'; 'noble.installs' = '7.6.8' }
            $r = Invoke-InstallerShell -Body "pwsh_source() { echo apt; }`nbring_powershell_to_newest; pwsh_version" `
                -Environment @{ FAKE_ROOT = $box.Root; PWSH_VERSION = '7.6.8'; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Match '(?s)^DEB 7\.6\.8 x86_64\s+NOBLE 7\.6\.8\s*$' (Read-SourceCall -Root $box.Root) 'PWSH_VERSION names the release, never anything newer'
            Assert-Match '(?m)^7\.6\.8$' $r.Output
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'on aarch64 asks only the arm64 release .deb for Microsoft''s package' {
        # No Microsoft Ubuntu suite carries an arm64 powershell.
        $box = New-PowerShellSandbox -PwshVersion '7.6.6' -PwshDir 'localbin'
        try {
            Set-SandboxFile -Root $box.Root -File @{ 'github.latest' = '7.6.9'; 'dpkg.owns-powershell' = 'yes'; 'deb.fails' = '1'
                'noble.installs' = '7.6.9'; 'tarball.installs' = '7.6.9' }
            $r = Invoke-InstallerShell -Body "pwsh_source() { echo apt; }`nbring_powershell_to_newest; pwsh_version" `
                -Environment @{ ARCH = 'aarch64'; FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Match '(?s)^DEB 7\.6\.9 aarch64\s*$' (Read-SourceCall -Root $box.Root)
            Assert-Match '(?m)^7\.6\.6$' $r.Output
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'leaves Microsoft''s package at the newest release alone' {
        $box = New-PowerShellSandbox -PwshVersion '7.6.9' -PwshDir 'localbin'
        try {
            Set-SandboxFile -Root $box.Root -File @{ 'github.latest' = '7.6.9'; 'dpkg.owns-powershell' = 'yes'; 'deb.installs' = '7.6.9' }
            $r = Invoke-InstallerShell -Body "pwsh_source() { echo apt; }`nbring_powershell_to_newest" `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Match 'PowerShell 7\.6\.9 is at or past 7\.6\.9' $r.Output
            Assert-Equal -Expected '' -Actual (Read-SourceCall -Root $box.Root)
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'leaves a package the operator holds to the operator' {
        # apt-mark hold makes dpkg's status "hold ok installed". The package still owns
        # /opt/microsoft/powershell/7, so no source may replace or unpack over it; the
        # classification runs for real here, with only the link resolved by a stub.
        $box = New-PowerShellSandbox -PwshVersion '7.6.6' -PwshDir 'localbin'
        try {
            Set-SandboxFile -Root $box.Root -File @{ 'github.latest' = '7.6.9'; 'dpkg.owns-powershell' = 'yes'; 'apt.holds' = 'powershell'
                'deb.installs' = '7.6.9'; 'noble.installs' = '7.6.9'; 'tarball.installs' = '7.6.9' }
            $r = Invoke-InstallerShell -Body "readlink() { printf '%s\n' /opt/microsoft/powershell/7/pwsh; }`nbring_powershell_to_newest; pwsh_version" `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Equal -Expected '' -Actual (Read-SourceCall -Root $box.Root) -Because 'no source replaces a held package'
            Assert-Match 'held with apt-mark hold' $r.Output 'the run says why it left the package'
            Assert-Match '(?m)^7\.6\.6$' $r.Output 'the held package keeps its version'
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'never downgrades Microsoft''s package when GitHub marks an older release as the latest' {
        $box = New-PowerShellSandbox -PwshVersion '7.6.6' -PwshDir 'localbin'
        try {
            Set-SandboxFile -Root $box.Root -File @{ 'github.latest' = '7.4.22'; 'dpkg.owns-powershell' = 'yes'; 'deb.installs' = '7.4.22'; 'noble.installs' = '7.4.22' }
            $r = Invoke-InstallerShell -Body "pwsh_source() { echo apt; }`nbring_powershell_to_newest; pwsh_version" `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Equal -Expected '' -Actual (Read-SourceCall -Root $box.Root)
            Assert-Match 'PowerShell 7\.6\.6 is at or past 7\.4\.22' $r.Output
            Assert-Match '(?m)^7\.6\.6$' $r.Output
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'reinstalls the release .deb when the package''s files no longer match what dpkg recorded, <Case>' -TestCases @(
        # A tarball unpacked over the package leaves dpkg recording the old version: the
        # files answer as the newest release while dpkg's checksums are the old ones.
        @{ Case = 'at the version pwsh answers when that is the newest'; Have = '7.6.9'; Expected = '(?s)^DEB 7\.6\.9 x86_64\s*$' }
        @{ Case = 'moving it to the newest release when it is behind'; Have = '7.6.6'; Expected = '(?s)^DEB 7\.6\.9 x86_64\s*$' }
    ) {
        param([string]$Case, [string]$Have, [string]$Expected)
        $null = $Case
        $box = New-PowerShellSandbox -PwshVersion $Have -PwshDir 'localbin'
        try {
            Set-SandboxFile -Root $box.Root -File @{ 'github.latest' = '7.6.9'; 'dpkg.owns-powershell' = 'yes'; 'deb.installs' = '7.6.9'
                'dpkg.mismatches' = "??5??????   /opt/microsoft/powershell/7/pwsh.dll`nmissing     /opt/microsoft/powershell/7/pwsh.xml" }
            $r = Invoke-InstallerShell -Body "pwsh_source() { echo apt; }`nbring_powershell_to_newest; pwsh_version" `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Match $Expected (Read-SourceCall -Root $box.Root) 'the release .deb goes through apt, which rewrites every file it records'
            Assert-Match 'every file of Microsoft''s PowerShell package matches what dpkg recorded' $r.Output 'dpkg -V is asked again afterward'
            Assert-True ($r.Output -notmatch '(?m)^ISSUE ') 'a repaired package is no issue'
            Assert-Match '(?m)^7\.6\.9$' $r.Output
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'reports, and leaves, a held package whose files no longer match what dpkg recorded' {
        $box = New-PowerShellSandbox -PwshVersion '7.6.9' -PwshDir 'localbin'
        try {
            Set-SandboxFile -Root $box.Root -File @{ 'github.latest' = '7.6.9'; 'dpkg.owns-powershell' = 'yes'; 'apt.holds' = 'powershell'; 'deb.installs' = '7.6.9'
                'dpkg.mismatches' = "??5??????   /opt/microsoft/powershell/7/pwsh.dll`n??5??????   /opt/microsoft/powershell/7/System.Private.CoreLib.dll`nmissing     /opt/microsoft/powershell/7/pwsh.xml`nmissing     /usr/share/man/man1/pwsh.1.gz" }
            $r = Invoke-InstallerShell -Body "pwsh_source() { echo apt; }`nbring_powershell_to_newest" `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Equal -Expected '' -Actual (Read-SourceCall -Root $box.Root) -Because 'a held package is reinstalled from no source'
            Assert-Match "ISSUE Microsoft's powershell package has files that no longer match what dpkg recorded \('dpkg -V powershell' lists 3 under /opt/microsoft/powershell/7\), and it is held with apt-mark hold" $r.Output
            Assert-Match "sudo apt-mark unhold powershell" $r.Output 'the issue names the command that releases the hold'
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'reports a package whose files still do not match after the reinstall fails' {
        $box = New-PowerShellSandbox -PwshVersion '7.6.9' -PwshDir 'localbin'
        try {
            Set-SandboxFile -Root $box.Root -File @{ 'github.latest' = '7.6.9'; 'dpkg.owns-powershell' = 'yes'; 'deb.fails' = '1'
                'dpkg.mismatches' = '??5??????   /opt/microsoft/powershell/7/pwsh.dll' }
            $r = Invoke-InstallerShell -Body "pwsh_source() { echo apt; }`nbring_powershell_to_newest; echo CONTINUED" `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Match '(?s)^DEB 7\.6\.9 x86_64\s*$' (Read-SourceCall -Root $box.Root)
            Assert-Match "ISSUE Microsoft's powershell package still has files that do not match what dpkg recorded \('dpkg -V powershell' lists 1 under /opt/microsoft/powershell/7\)" $r.Output
            Assert-Match 'CONTINUED' $r.Output 'the install goes on'
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'counts no file that dpkg''s own path-exclude setting left out, <Case>' -TestCases @(
        @{ Case = 'reinstalling nothing for a package that is not held'; Held = $false }
        @{ Case = 'naming no mismatch for a package that is held'; Held = $true }
    ) {
        param([string]$Case, [bool]$Held)
        $null = $Case
        # A minimized Ubuntu install has path-exclude=/usr/share/man/* in
        # /etc/dpkg/dpkg.cfg.d/excludes, so dpkg -V lists the package's manual page as
        # missing on every run, and a reinstall leaves it out again.
        $box = New-PowerShellSandbox -PwshVersion '7.6.9' -PwshDir 'localbin'
        try {
            Set-SandboxFile -Root $box.Root -File @{ 'github.latest' = '7.6.9'; 'dpkg.owns-powershell' = 'yes'; 'deb.installs' = '7.6.9'
                'dpkg.mismatches' = 'missing     /usr/share/man/man1/pwsh.1.gz' }
            if ($Held) { Set-SandboxFile -Root $box.Root -File @{ 'apt.holds' = 'powershell' } }
            $r = Invoke-InstallerShell -Body "pwsh_source() { echo apt; }`nbring_powershell_to_newest" `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = "$($box.BinDir):/usr/bin:/bin" }
            Assert-Equal -Expected '' -Actual (Read-SourceCall -Root $box.Root) -Because 'a reinstall cannot restore what dpkg itself leaves out'
            Assert-True ($r.Output -notmatch '(?m)^ISSUE ') "a package whose interpreter files all match is no issue: $($r.Output)"
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
}

Describe 'first install of pwsh' {
    BeforeAll {
        # A sandbox whose PATH has no pwsh until a stubbed source installs one. The host's
        # own interpreter lives in a directory every stock PATH names, so PATH here is the
        # sandbox's bin directory and links to the few tools the block and its stubs run.
        function New-AbsentPowerShellSandbox {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: creates a temp sandbox tree the test removes in its finally block; not user-facing state.')]
            param()
            $box = New-PowerShellSandbox -PwshVersion '7.6.9' -PwshDir 'localbin'
            Move-Item -LiteralPath (Join-Path $box.BinDir 'pwsh') -Destination (Join-Path $box.Root 'pwsh.stub')
            $tools = Join-Path $box.Root 'tools'
            New-Item -ItemType Directory -Path $tools -Force | Out-Null
            foreach ($tool in @('cat', 'cp', 'chmod', 'grep', 'rm')) {
                $source = (Get-Command -Name $tool -CommandType Application | Select-Object -First 1).Source
                New-Item -ItemType SymbolicLink -Path (Join-Path $tools $tool) -Target $source | Out-Null
            }
            $box.Path = "$($box.BinDir):$tools"
            return $box
        }
        # Each source records itself; one named in <source>.installs puts pwsh on PATH,
        # and the rest fail as their real counterparts do when they install nothing.
        $script:FirstInstallStubs = @'
pwsh_appears() { cp "$FAKE_ROOT/pwsh.stub" "$FAKE_ROOT/localbin/pwsh"; chmod +x "$FAKE_ROOT/localbin/pwsh"; }
install_pwsh_apt()     { printf 'APT\n' >> "$FAKE_ROOT/calls";     [[ -f "$FAKE_ROOT/apt.installs" ]] || return 1; pwsh_appears; }
install_pwsh_deb()     { printf 'DEB\n' >> "$FAKE_ROOT/calls";     [[ -f "$FAKE_ROOT/deb.installs" ]] || return 1; pwsh_appears; : > "$FAKE_ROOT/dpkg.owns-powershell"; }
install_pwsh_noble()   { printf 'NOBLE\n' >> "$FAKE_ROOT/calls";   [[ -f "$FAKE_ROOT/noble.installs" ]] || return 1; pwsh_appears; : > "$FAKE_ROOT/dpkg.owns-powershell"; }
install_pwsh_tarball() { printf 'TARBALL\n' >> "$FAKE_ROOT/calls"; [[ -f "$FAKE_ROOT/tarball.installs" ]] || return 1; pwsh_appears; }
'@
    }
    It 'installs the release .deb on a fresh x86_64 host whose apt sources carry no powershell' {
        # Microsoft's 26.04 suite publishes no powershell, so apt fails with "Unable to
        # locate package powershell" and the release's .deb is the next source.
        $box = New-AbsentPowerShellSandbox
        try {
            Set-SandboxFile -Root $box.Root -File @{ 'deb.installs' = 'yes'; 'tarball.installs' = 'yes' }
            $r = Invoke-InstallerShell -Body ($script:FirstInstallStubs + "`n" + $script:FirstInstallBlock + 'echo INSTALLED') `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = $box.Path }
            Assert-Match '(?s)^APT\s+DEB\s*$' (Read-SourceCall -Root $box.Root) 'dpkg owns the interpreter from the first run'
            Assert-Match '(?m)^INSTALLED$' $r.Output
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'tries each source in turn while pwsh is still absent' {
        $box = New-AbsentPowerShellSandbox
        try {
            Set-SandboxFile -Root $box.Root -File @{ 'tarball.installs' = 'yes' }
            $r = Invoke-InstallerShell -Body ($script:FirstInstallStubs + "`n" + $script:FirstInstallBlock + 'echo INSTALLED') `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = $box.Path }
            Assert-Match '(?s)^APT\s+DEB\s+NOBLE\s+TARBALL\s*$' (Read-SourceCall -Root $box.Root)
            Assert-Match '(?m)^INSTALLED$' $r.Output
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'still tries the next source when the apt path dies' {
        # A key gpg cannot read ends install_pwsh_apt through die(), which is exit 1.
        $box = New-AbsentPowerShellSandbox
        try {
            Set-SandboxFile -Root $box.Root -File @{ 'deb.installs' = 'yes' }
            $dies = "install_pwsh_apt() { printf 'APT\n' >> `"`$FAKE_ROOT/calls`"; exit 1; }`n"
            $r = Invoke-InstallerShell -Body ($script:FirstInstallStubs + "`n" + $dies + $script:FirstInstallBlock + 'echo INSTALLED') `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = $box.Path }
            Assert-Match '(?s)^APT\s+DEB\s*$' (Read-SourceCall -Root $box.Root)
            Assert-Match '(?m)^INSTALLED$' $r.Output 'the install goes on'
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'ends the run when no source installs pwsh' {
        $box = New-AbsentPowerShellSandbox
        try {
            $r = Invoke-InstallerShell -Body ($script:FirstInstallStubs + "`n" + $script:FirstInstallBlock + 'echo INSTALLED') `
                -Environment @{ FAKE_ROOT = $box.Root; PATH = $box.Path }
            Assert-Match 'DIE pwsh not found after install' $r.Output
            Assert-True ($r.Output -notmatch 'INSTALLED') 'nothing runs after the failed install'
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
    It 'installs the tarball on aarch64, where no Microsoft Ubuntu suite carries powershell' {
        $box = New-AbsentPowerShellSandbox
        try {
            Set-SandboxFile -Root $box.Root -File @{ 'apt.installs' = 'yes'; 'deb.installs' = 'yes'; 'tarball.installs' = 'yes' }
            $r = Invoke-InstallerShell -Body ($script:FirstInstallStubs + "`n" + $script:FirstInstallBlock + 'echo INSTALLED') `
                -Environment @{ ARCH = 'aarch64'; FAKE_ROOT = $box.Root; PATH = $box.Path }
            Assert-Match '(?s)^TARBALL\s*$' (Read-SourceCall -Root $box.Root)
            Assert-Match '(?m)^INSTALLED$' $r.Output
        } finally { Remove-YurunaTestTempDir $box.Root }
    }
}

Describe 'install_pwsh_apt' {
    BeforeAll {
        # The body as the installer defines it, with the files it reads and writes under
        # /etc moved into the sandbox. Microsoft's suite answers the Release probe, and apt
        # installs what it is asked to.
        $script:AptSourceLifted = (Get-YurunaTestShellFunction -Text $script:InstallerText -Name @('install_pwsh_apt')).
            Replace('/etc/apt/', '$FAKE_ROOT/etc/apt/').Replace('/etc/os-release', '$FAKE_ROOT/etc/os-release')
        $script:AptSourcePrelude = @'
set -euo pipefail
log()  { printf 'LOG %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
die()  { printf 'DIE %s\n' "$*"; exit 1; }
yuruna_track_tmp() { :; }
lsb_release() { echo resolute; }
curl() { printf 'CURL %s\n' "$*" >> "$FAKE_ROOT/calls"; }
sudo() { while [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do shift; done; "$@"; }
apt-get() { printf 'APT-GET %s\n' "$*" >> "$FAKE_ROOT/calls"; }
'@
    }
    It 'says whether it added Microsoft''s apt repo or found it already listed' {
        $root = New-YurunaTestTempDir -Prefix 'yuruna-pwshapt'
        try {
            foreach ($sub in @('etc/apt/sources.list.d', 'etc/apt/keyrings')) { New-Item -ItemType Directory -Path (Join-Path $root $sub) -Force | Out-Null }
            $list = Join-Path $root 'etc/apt/sources.list.d/microsoft-prod.list'
            Set-SandboxFile -Root $root -File @{ 'etc/os-release' = 'VERSION_ID="26.04"'; 'etc/apt/keyrings/microsoft.gpg' = 'keyring'
                'etc/apt/sources.list.d/microsoft-prod.list' = 'the operator''s own line' }
            $body = @($script:AptSourcePrelude, $script:AptSourceLifted, 'install_pwsh_apt; echo "RC $?"') -join "`n"
            $r = Invoke-YurunaTestShell -Body $body -Environment @{ FAKE_ROOT = $root }
            Assert-Match '(?m)^RC 0$' $r.Output $r.Output
            Assert-Match '(?m)^LOG Microsoft apt repo already listed in \S+/etc/apt/sources\.list\.d/microsoft-prod\.list \(codename=resolute\)$' $r.Output
            Assert-True ($r.Output -notmatch 'Adding Microsoft apt repo') 'a list already present is not reported as added'
            Assert-Equal -Expected 'the operator''s own line' -Actual (Get-Content -LiteralPath $list -Raw).Trim() -Because 'the operator''s list is left as it was'
            # The same run on a host without the list adds it, and says so.
            Remove-Item -LiteralPath $list
            $r = Invoke-YurunaTestShell -Body $body -Environment @{ FAKE_ROOT = $root }
            Assert-Match '(?m)^LOG Adding Microsoft apt repo \(codename=resolute\)$' $r.Output $r.Output
            Assert-Match '^deb \[arch=amd64 signed-by=\S+/etc/apt/keyrings/microsoft\.gpg\] https://packages\.microsoft\.com/ubuntu/26\.04/prod resolute main$' (Get-Content -LiteralPath $list -Raw).Trim()
        } finally { Remove-YurunaTestTempDir $root }
    }
}

Describe 'install_pwsh_deb and install_pwsh_tarball' {
    BeforeAll {
        $script:AssetLifted = Get-YurunaTestShellFunction -Text $script:InstallerText -Name @('apt_package_held', 'fetch_pwsh_release_asset', 'install_pwsh_deb', 'install_pwsh_tarball')
        # curl serves the fixture asset and hash list by name, to a file or to its output,
        # and records its arguments. sudo runs what lands in the sandbox -- the directory
        # mktemp makes from the /tmp template, moved into the sandbox, standing for the one
        # only root can write, and the files written into it -- and only records the rest,
        # so no case touches /tmp, /opt, /usr/local or apt; it also records the bytes apt
        # is handed. With copy.swapped the file root wrote is not what curl delivered.
        # downloads.swapped stands for another process of the account: it rewrites every
        # file curl leaves anywhere but a directory sudo made, with its own asset and a
        # hash list that matches it.
        $script:AssetPrelude = @'
set -euo pipefail
ARCH="${ARCH:-x86_64}"
log()  { printf 'LOG %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
die()  { printf 'DIE %s\n' "$*"; exit 1; }
yuruna_track_tmp() { :; }
pwsh_latest_release() { echo 7.6.9; }
apt-mark() {
  [[ "${1:-}" == showhold ]] || return 1
  if [[ -f "$FAKE_ROOT/apt.holds" ]]; then cat "$FAKE_ROOT/apt.holds"; fi
}
curl() {
  local out="" url="" args="$*"
  while (( $# )); do
    case "$1" in
      -o) out="$2"; shift 2 ;;
      --retry|--retry-delay|--connect-timeout|--max-time|--retry-max-time) shift 2 ;;
      -*) shift ;;
      *) url="$1"; shift ;;
    esac
  done
  printf 'CURL %s\n' "$args" >> "$FAKE_ROOT/calls"
  case "$url" in
    */hashes.sha256) cat "$FAKE_ROOT/hashes.sha256" > "${out:-/dev/stdout}" ;;
    */"$(cat "$FAKE_ROOT/asset.name")") [[ ! -f "$FAKE_ROOT/asset.missing" ]] || return 22; printf 'release bytes\n' > "${out:-/dev/stdout}" ;;
    *) return 22 ;;
  esac
  if [[ -n "$out" && -f "$FAKE_ROOT/downloads.swapped" ]] && ! grep -Fx "ROOT-OWNED ${out%/*}" "$FAKE_ROOT/calls" >/dev/null; then
    printf 'attacker bytes\n' > "${out%/*}/$(cat "$FAKE_ROOT/asset.name")"
    cp "$FAKE_ROOT/attacker/hashes.sha256" "${out%/*}/hashes.sha256"
  fi
}
sudo() {
  printf 'SUDO %s\n' "$*" >> "$FAKE_ROOT/calls"
  local dir last="${!#}"
  case "$1" in
    mktemp)
      dir="$(mktemp -d "$FAKE_ROOT/${last#/tmp/}")" || return
      printf 'ROOT-OWNED %s\n' "$dir" >> "$FAKE_ROOT/calls"
      printf '%s\n' "$dir" ;;
    install|chmod|tee)
      [[ "$last" == "$FAKE_ROOT"/* ]] || return 0
      "$@" || return
      if [[ "$1" == tee && -f "$FAKE_ROOT/copy.swapped" && "$last" == */"$(cat "$FAKE_ROOT/asset.name")" ]]; then
        printf 'swapped bytes\n' > "$last"
      fi ;;
    tar) [[ ! -f "$FAKE_ROOT/tar.fails" ]] ;;
    DEBIAN_FRONTEND=*)
      printf 'APT-READS %s\n' "$(cat "$last")" >> "$FAKE_ROOT/calls"
      [[ ! -f "$FAKE_ROOT/apt.declines" ]] ;;
    *) return 0 ;;
  esac
}
'@
        $script:AssetDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::ASCII.GetBytes("release bytes`n"))).ToLowerInvariant()
        $script:AttackerDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::ASCII.GetBytes("attacker bytes`n"))).ToLowerInvariant()
        function Invoke-AssetShell {
            param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Body, [hashtable]$Environment = @{})
            $shellEnvironment = @{ FAKE_ROOT = $Root; TMPDIR = $Root } + $Environment
            return Invoke-YurunaTestShell -Body (@($script:AssetPrelude, $script:AssetLifted, $Body) -join "`n") -Environment $shellEnvironment
        }
    }
    It 'hands apt the verified <Arch> package from the directory only root can write, so dpkg records what it unpacks' -TestCases @(
        @{ Arch = 'x86_64'; Asset = 'powershell_7.6.9-1.deb_amd64.deb' }
        @{ Arch = 'aarch64'; Asset = 'powershell_7.6.9-1.deb_arm64.deb' }
    ) {
        param([string]$Arch, [string]$Asset)
        $root = New-YurunaTestTempDir -Prefix 'yuruna-pwshdeb'
        try {
            Set-SandboxFile -Root $root -File @{ 'asset.name' = $Asset }
            Write-ReleaseHashList -Root $root -Asset $Asset -Digest $script:AssetDigest
            $r = Invoke-AssetShell -Root $root -Body 'install_pwsh_deb; echo "RC $?"' -Environment @{ ARCH = $Arch }
            Assert-Match '(?m)^RC 0$' $r.Output $r.Output
            $calls = Read-SourceCall -Root $root
            $owned = [regex]::Match($calls, '(?m)^ROOT-OWNED (\S+)$').Groups[1].Value
            Assert-True ($owned -ne '') 'the copy apt reads lands in a directory sudo created'
            # --reinstall replaces files that no longer match what dpkg recorded; the lock
            # timeout waits out an unattended upgrade instead of failing at once.
            Assert-Match ('(?m)^SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall -o DPkg::Lock::Timeout=120 ' + [regex]::Escape("$owned/$Asset") + '$') $calls `
                'apt installs the verified copy by its absolute path'
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'checks the file root wrote, which is the one apt reads' {
        $root = New-YurunaTestTempDir -Prefix 'yuruna-pwshdeb'
        try {
            Set-SandboxFile -Root $root -File @{ 'asset.name' = 'powershell_7.6.9-1.deb_amd64.deb'; 'copy.swapped' = 'yes' }
            Write-ReleaseHashList -Root $root -Asset 'powershell_7.6.9-1.deb_amd64.deb' -Digest $script:AssetDigest
            $r = Invoke-AssetShell -Root $root -Body '( install_pwsh_deb ) || echo "RC $?"'
            Assert-Match 'DIE PowerShell 7\.6\.9: powershell_7\.6\.9-1\.deb_amd64\.deb SHA-256 does not match hashes\.sha256' $r.Output `
                'curl delivered the release''s bytes; the file root would hand apt did not hold them'
            Assert-True ((Read-SourceCall -Root $root) -notmatch 'apt-get') 'apt never sees a file that was not checked'
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'hands apt the release''s bytes when another process of the account rewrites the asset and its hash list together' {
        # Both files from the same directory let that process swap them as a pair, with a
        # digest line that matches its own bytes; each download lands where only root can
        # write instead.
        $root = New-YurunaTestTempDir -Prefix 'yuruna-pwshdeb'
        try {
            Set-SandboxFile -Root $root -File @{ 'asset.name' = 'powershell_7.6.9-1.deb_amd64.deb'; 'downloads.swapped' = 'yes' }
            Write-ReleaseHashList -Root $root -Asset 'powershell_7.6.9-1.deb_amd64.deb' -Digest $script:AssetDigest
            $attacker = Join-Path $root 'attacker'
            New-Item -ItemType Directory -Path $attacker -Force | Out-Null
            Write-ReleaseHashList -Root $attacker -Asset 'powershell_7.6.9-1.deb_amd64.deb' -Digest $script:AttackerDigest
            $r = Invoke-AssetShell -Root $root -Body '( install_pwsh_deb ) || echo "RC $?"'
            $calls = Read-SourceCall -Root $root
            Assert-True ($calls -notmatch 'APT-READS attacker bytes') "apt never installs bytes another process wrote: $($r.Output)"
            Assert-Match '(?m)^APT-READS release bytes$' $calls 'apt installs the release''s own package'
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'has root open nothing outside the directory only root can write' {
        # Root reading a path in a directory the account can write follows a link another
        # process planted there, so a file only root may read would be copied into a
        # directory every account can read.
        $root = New-YurunaTestTempDir -Prefix 'yuruna-pwshdeb'
        try {
            Set-SandboxFile -Root $root -File @{ 'asset.name' = 'powershell_7.6.9-1.deb_amd64.deb' }
            Write-ReleaseHashList -Root $root -Asset 'powershell_7.6.9-1.deb_amd64.deb' -Digest $script:AssetDigest
            $r = Invoke-AssetShell -Root $root -Body 'install_pwsh_deb; echo "RC $?"'
            Assert-Match '(?m)^RC 0$' $r.Output $r.Output
            $calls = Read-SourceCall -Root $root
            $owned = [regex]::Match($calls, '(?m)^ROOT-OWNED (\S+)$').Groups[1].Value
            $named = @([regex]::Matches((@($calls -split "`n" | Where-Object { $_ -like 'SUDO *' }) -join "`n"), [regex]::Escape($root) + '/\S+') | ForEach-Object { $_.Value })
            Assert-True ($named.Count -gt 0) 'root writes the downloads into the sandbox''s stand-in for its directory'
            $outside = @($named | Where-Object { $_ -ne $owned -and -not $_.StartsWith("$owned/") })
            Assert-Equal -Expected '' -Actual ($outside -join ' ') -Because 'every path root names lies in the directory it made'
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'hands apt no package the operator holds, which a same-version reinstall would release' {
        # apt refuses a held version change but performs a same-version --reinstall, and
        # dpkg then resets the hold to install.
        $root = New-YurunaTestTempDir -Prefix 'yuruna-pwshdeb'
        try {
            Set-SandboxFile -Root $root -File @{ 'asset.name' = 'powershell_7.6.9-1.deb_amd64.deb'; 'apt.holds' = "linux-image-generic`npowershell" }
            Write-ReleaseHashList -Root $root -Asset 'powershell_7.6.9-1.deb_amd64.deb' -Digest $script:AssetDigest
            $r = Invoke-AssetShell -Root $root -Body '( PWSH_VERSION=7.6.9 install_pwsh_deb ) || echo "RC $?"'
            Assert-Match '(?m)^RC 2$' $r.Output 'a held package reads as one apt did not install'
            Assert-Equal -Expected '' -Actual (Read-SourceCall -Root $root) -Because 'nothing is downloaded and apt is not asked'
            Assert-Match "WARN   Microsoft's powershell package is held with apt-mark hold, so no release \.deb replaces it; 'sudo apt-mark unhold powershell' releases it" $r.Output
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'downloads with the latest-release lookup''s retries, under a total time cap' {
        $root = New-YurunaTestTempDir -Prefix 'yuruna-pwshdeb'
        try {
            Set-SandboxFile -Root $root -File @{ 'asset.name' = 'powershell_7.6.9-1.deb_amd64.deb' }
            Write-ReleaseHashList -Root $root -Asset 'powershell_7.6.9-1.deb_amd64.deb' -Digest $script:AssetDigest
            $null = Invoke-AssetShell -Root $root -Body 'install_pwsh_deb'
            $fetches = @((Read-SourceCall -Root $root) -split "`n" | Where-Object { $_ -like 'CURL *' })
            Assert-Equal -Expected 2 -Actual $fetches.Count -Because 'the asset and its hash list'
            # --max-time bounds one attempt; --retry-max-time stops starting new ones.
            foreach ($fetch in $fetches) {
                Assert-Match '^CURL -fsSL --retry 3 --retry-delay 5 --retry-connrefused --connect-timeout 15 --max-time 900 --retry-max-time 900 ' $fetch
            }
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'makes the directory only root can write under /tmp, whatever TMPDIR sudo keeps' {
        # /tmp's sticky bit keeps other accounts from renaming what root created there; a
        # TMPDIR the account can write would not.
        $root = New-YurunaTestTempDir -Prefix 'yuruna-pwshdeb'
        try {
            Set-SandboxFile -Root $root -File @{ 'asset.name' = 'powershell_7.6.9-1.deb_amd64.deb' }
            Write-ReleaseHashList -Root $root -Asset 'powershell_7.6.9-1.deb_amd64.deb' -Digest $script:AssetDigest
            $null = Invoke-AssetShell -Root $root -Body 'install_pwsh_deb'
            Assert-Match '(?m)^SUDO mktemp -d /tmp/yuruna-pwsh\.X{10}$' (Read-SourceCall -Root $root)
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'never hands apt a package that <Case>' -TestCases @(
        @{ Case = 'does not match the release''s hashes.sha256'; Missing = $false; Expected = 'DIE PowerShell 7\.6\.9: powershell_7\.6\.9-1\.deb_amd64\.deb SHA-256 does not match hashes\.sha256' }
        @{ Case = 'could not be downloaded'; Missing = $true; Expected = 'DIE PowerShell 7\.6\.9: could not download powershell_7\.6\.9-1\.deb_amd64\.deb' }
    ) {
        param([string]$Case, [bool]$Missing, [string]$Expected)
        $null = $Case
        $root = New-YurunaTestTempDir -Prefix 'yuruna-pwshdeb'
        try {
            Set-SandboxFile -Root $root -File @{ 'asset.name' = 'powershell_7.6.9-1.deb_amd64.deb' }
            if ($Missing) { Set-SandboxFile -Root $root -File @{ 'asset.missing' = 'yes' } }
            Write-ReleaseHashList -Root $root -Asset 'powershell_7.6.9-1.deb_amd64.deb' -Digest ('09' * 32)
            # As the callers run it: in a subshell on the left of ||, where errexit does not hold.
            $r = Invoke-AssetShell -Root $root -Body '( install_pwsh_deb ) || echo "RC $?"'
            Assert-Match $Expected $r.Output
            Assert-Match '(?m)^RC 1$' $r.Output 'a package that is not the release''s ends with status 1'
            Assert-True ((Read-SourceCall -Root $root) -notmatch 'apt-get') 'apt never sees an unverified package'
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'ends with status 2 when apt declines the verified package' {
        $root = New-YurunaTestTempDir -Prefix 'yuruna-pwshdeb'
        try {
            Set-SandboxFile -Root $root -File @{ 'asset.name' = 'powershell_7.6.9-1.deb_amd64.deb'; 'apt.declines' = 'yes' }
            Write-ReleaseHashList -Root $root -Asset 'powershell_7.6.9-1.deb_amd64.deb' -Digest $script:AssetDigest
            $r = Invoke-AssetShell -Root $root -Body '( install_pwsh_deb ) || echo "RC $?"'
            Assert-Match '(?m)^RC 2$' $r.Output 'the report can tell an apt refusal from a failed download'
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'relinks nothing when the verified tarball does not unpack' {
        # The callers run the tarball in a subshell on the left of ||, where errexit does
        # not hold: each step has to stop the attempt itself, before the link moves.
        $root = New-YurunaTestTempDir -Prefix 'yuruna-pwshtar'
        try {
            Set-SandboxFile -Root $root -File @{ 'asset.name' = 'powershell-7.6.9-linux-x64.tar.gz'; 'tar.fails' = 'yes' }
            Write-ReleaseHashList -Root $root -Asset 'powershell-7.6.9-linux-x64.tar.gz' -Digest $script:AssetDigest
            $r = Invoke-AssetShell -Root $root -Body '( PWSH_VERSION=7.6.9 install_pwsh_tarball ) || echo "RC $?"'
            $calls = Read-SourceCall -Root $root
            Assert-Match '(?m)^SUDO tar -xzf \S+/powershell-7\.6\.9-linux-x64\.tar\.gz -C /opt/microsoft/powershell/7$' $calls 'the verified tarball was unpacked'
            Assert-True ($calls -notmatch 'ln -sf') 'a tree that did not unpack is never linked'
            Assert-Match '(?m)^RC 1$' $r.Output
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'unpacks the verified <Arch> tarball from the directory only root can write, then links it' -TestCases @(
        @{ Arch = 'x86_64'; Asset = 'powershell-7.6.9-linux-x64.tar.gz' }
        @{ Arch = 'aarch64'; Asset = 'powershell-7.6.9-linux-arm64.tar.gz' }
    ) {
        param([string]$Arch, [string]$Asset)
        $root = New-YurunaTestTempDir -Prefix 'yuruna-pwshtar'
        try {
            Set-SandboxFile -Root $root -File @{ 'asset.name' = $Asset }
            Write-ReleaseHashList -Root $root -Asset $Asset -Digest $script:AssetDigest
            $r = Invoke-AssetShell -Root $root -Body 'install_pwsh_tarball; echo "RC $?"' -Environment @{ ARCH = $Arch }
            Assert-Match '(?m)^RC 0$' $r.Output $r.Output
            $calls = Read-SourceCall -Root $root
            $owned = [regex]::Match($calls, '(?m)^ROOT-OWNED (\S+)$').Groups[1].Value
            $steps = @($calls -split "`n" | Where-Object { $_ -match '^SUDO (install -d|tar|chmod \+x|ln) ' })
            Assert-Equal -Expected 4 -Actual $steps.Count -Because $calls
            Assert-Equal -Expected 'SUDO install -d -m 0755 /opt/microsoft/powershell/7' -Actual $steps[0]
            Assert-Equal -Expected "SUDO tar -xzf $owned/$Asset -C /opt/microsoft/powershell/7" -Actual $steps[1] -Because 'tar reads the copy that was verified'
            Assert-Equal -Expected 'SUDO chmod +x /opt/microsoft/powershell/7/pwsh' -Actual $steps[2]
            Assert-Equal -Expected 'SUDO ln -sf /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh' -Actual $steps[3]
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'unpacks nothing when the tarball <Case>' -TestCases @(
        @{ Case = 'does not match the release''s hashes.sha256'; Missing = $false; Expected = 'DIE PowerShell 7\.6\.9: powershell-7\.6\.9-linux-x64\.tar\.gz SHA-256 does not match hashes\.sha256' }
        @{ Case = 'could not be downloaded'; Missing = $true; Expected = 'DIE PowerShell 7\.6\.9: could not download powershell-7\.6\.9-linux-x64\.tar\.gz' }
    ) {
        param([string]$Case, [bool]$Missing, [string]$Expected)
        $null = $Case
        $root = New-YurunaTestTempDir -Prefix 'yuruna-pwshtar'
        try {
            Set-SandboxFile -Root $root -File @{ 'asset.name' = 'powershell-7.6.9-linux-x64.tar.gz' }
            if ($Missing) { Set-SandboxFile -Root $root -File @{ 'asset.missing' = 'yes' } }
            Write-ReleaseHashList -Root $root -Asset 'powershell-7.6.9-linux-x64.tar.gz' -Digest ('09' * 32)
            $r = Invoke-AssetShell -Root $root -Body '( install_pwsh_tarball ) || echo "RC $?"'
            Assert-Match $Expected $r.Output
            Assert-Match '(?m)^RC 1$' $r.Output
            Assert-True ((Read-SourceCall -Root $root) -notmatch 'SUDO (install -d|tar|ln) ') 'nothing under /opt or /usr/local is touched'
        } finally { Remove-YurunaTestTempDir $root }
    }
}

Describe 'Microsoft''s Ubuntu 24.04 suite for PowerShell' {
    BeforeAll {
        $script:SuiteLifted = Get-YurunaTestShellFunction -Text $script:InstallerText -Name @(
            'apt_offers_powershell', 'remove_pwsh_noble_source', 'add_pwsh_noble_source',
            'retire_pwsh_noble_source', 'retry_apt_update_without_pwsh_noble_source', 'install_pwsh_noble')
        # The suite's settings exactly as the installer assigns them, with only the /etc/apt
        # paths moved into the sandbox.
        $settings = [regex]::Matches($script:InstallerText, '(?m)^(PWSH_NOBLE_[A-Z]+|MS_APT_KEY_FPR_NOBLE)=[^\n]*$') | ForEach-Object { $_.Value }
        if (@($settings).Count -ne 6) { throw "install/ubuntu.kvm.sh assigns $(@($settings).Count) of the six settings of its 24.04 suite" }
        $script:SuiteSettings = ($settings -join "`n").Replace('="/etc/apt/', '="$FAKE_ROOT/etc/apt/')
        # The top-level lines of the run's own index refresh, lifted as text: the calls that
        # keep the suite from stopping a run and retire it once it is no longer needed.
        $script:RefreshBlock = [regex]::Match($script:InstallerText, '(?m)^log "Refreshing apt index"\nsudo apt-get update -q[^\n]*\nretire_pwsh_noble_source\n').Value
        # madison answers from what the sandbox's apt would know: the host's own sources
        # (madison.host) and, once an update has read the suite's index, the suite. apt-get
        # update fails on apt.update-fails, and on suite.unverifiable while the suite is
        # configured, as when apt cannot verify the suite's index; suite.empty is a suite
        # that carries no powershell. The other tools record their calls.
        $script:SuitePrelude = @'
set -euo pipefail
log()  { printf 'LOG %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
die()  { printf 'DIE %s\n' "$*"; exit 1; }
yuruna_track_tmp() { :; }
sudo() { while [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do shift; done; "$@"; }
install() { printf 'INSTALL %s\n' "$*" >> "$FAKE_ROOT/calls"; }
tee() { printf 'TEE %s\n' "$1" >> "$FAKE_ROOT/calls"; command tee "$@"; }
gpg() {
  local out="" in=""
  while (( $# )); do case "$1" in -o) out="$2"; shift 2 ;; --*) shift ;; *) in="$1"; shift ;; esac; done
  printf 'GPG\n' >> "$FAKE_ROOT/calls"
  { printf 'dearmored '; cat "$in"; } > "$out"
}
curl() {
  local out="" url=""
  while (( $# )); do case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
  printf 'CURL %s\n' "$url" >> "$FAKE_ROOT/calls"
  [[ ! -f "$FAKE_ROOT/key.unreachable" ]] || return 22
  printf 'armored key\n' > "$out"
}
verify_key_fingerprints() {
  printf 'VERIFY %s\n' "$2" >> "$FAKE_ROOT/calls"
  [[ ! -f "$FAKE_ROOT/key.mismatch" ]] || die "Unexpected key fingerprint in $1"
}
apt-cache() {
  [[ "${1:-}" == madison ]] || return 1
  if [[ -f "$FAKE_ROOT/madison.host" ]]; then cat "$FAKE_ROOT/madison.host"; fi
  if [[ -f "$FAKE_ROOT/suite.indexed" ]]; then
    printf '%s\n' 'powershell | 7.6.9-1.deb | https://packages.microsoft.com/ubuntu/24.04/prod noble/main amd64 Packages'
  fi
}
apt-get() {
  printf 'APT-GET %s\n' "$*" >> "$FAKE_ROOT/calls"
  case " $* " in
    *" update "*)
      [[ ! -f "$FAKE_ROOT/apt.update-fails" ]] || return 100
      if [[ -f "$FAKE_ROOT/suite.unverifiable" && -f "$PWSH_NOBLE_LIST" ]]; then return 100; fi
      if [[ -f "$PWSH_NOBLE_LIST" && ! -f "$FAKE_ROOT/suite.empty" ]]; then : > "$FAKE_ROOT/suite.indexed"; else rm -f "$FAKE_ROOT/suite.indexed"; fi ;;
    *" install "*) [[ ! -f "$FAKE_ROOT/apt.install-fails" ]] || return 100 ;;
  esac
}
'@
        $script:HostLine = 'powershell | 7.6.10-1.deb | https://packages.microsoft.com/ubuntu/26.04/prod resolute/main amd64 Packages'
        function New-SuiteSandbox {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: creates a temp sandbox tree the test removes in its finally block; not user-facing state.')]
            param([switch]$WithSuite)
            $root = New-YurunaTestTempDir -Prefix 'yuruna-pwshsuite'
            foreach ($sub in @('etc/apt/sources.list.d', 'etc/apt/preferences.d', 'etc/apt/keyrings')) {
                New-Item -ItemType Directory -Path (Join-Path $root $sub) -Force | Out-Null
            }
            if ($WithSuite) {
                foreach ($file in (Get-SuiteFile -Root $root)) { Set-Content -LiteralPath $file -Value 'written by this installer' }
                Set-Content -LiteralPath (Join-Path $root 'suite.indexed') -Value 'yes'
            }
            return $root
        }
        function Get-SuiteFile {
            param([Parameter(Mandatory)][string]$Root)
            return @(
                (Join-Path $Root 'etc/apt/sources.list.d/yuruna-powershell-noble.sources'),
                (Join-Path $Root 'etc/apt/preferences.d/yuruna-powershell-noble.pref'),
                (Join-Path $Root 'etc/apt/keyrings/yuruna-powershell-noble.gpg'))
        }
        function Invoke-SuiteShell {
            param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Body, [hashtable]$Environment = @{})
            # The installer reads ID from /etc/os-release at the top of a run.
            $shellEnvironment = @{ FAKE_ROOT = $Root; TMPDIR = $Root; ID = 'ubuntu' }
            foreach ($k in $Environment.Keys) { $shellEnvironment[$k] = $Environment[$k] }
            return Invoke-YurunaTestShell -Body (@($script:SuitePrelude, $script:SuiteSettings, $script:SuiteLifted, $Body) -join "`n") -Environment $shellEnvironment
        }
    }
    It 'names the suite, the origin its Release file states and the key that signs it' {
        # Origin from https://packages.microsoft.com/ubuntu/24.04/prod/dists/noble/InRelease;
        # its signature verifies only with the primary key of
        # https://packages.microsoft.com/keys/microsoft.asc.
        Assert-Match '(?m)^PWSH_NOBLE_URL="https://packages\.microsoft\.com/ubuntu/24\.04/prod"$' $script:SuiteSettings
        Assert-Match '(?m)^PWSH_NOBLE_ORIGIN="microsoft-ubuntu-noble-prod noble"$' $script:SuiteSettings
        Assert-Match '(?m)^MS_APT_KEY_FPR_NOBLE="BC528686B50D79E339D3721CEB3E94ADBE1229CF"' $script:SuiteSettings
    }
    It 'adds the pinned suite only when no source the host has offers powershell, then installs from it' {
        $root = New-SuiteSandbox
        try {
            $r = Invoke-SuiteShell -Root $root -Body 'install_pwsh_noble; echo "RC $?"'
            Assert-Match '(?m)^RC 0$' $r.Output $r.Output
            $calls = Read-SourceCall -Root $root
            Assert-Match '(?m)^CURL https://packages\.microsoft\.com/keys/microsoft\.asc$' $calls
            Assert-Match '(?m)^VERIFY BC528686B50D79E339D3721CEB3E94ADBE1229CF$' $calls 'the key is checked against its pinned fingerprint before apt trusts it'
            # The pin lands before the source, and apt installs only after the update.
            $order = @($calls -split "`n" | Where-Object { $_ -match '^(TEE|APT-GET) ' })
            Assert-Match 'yuruna-powershell-noble\.pref$' $order[0]
            Assert-Match 'yuruna-powershell-noble\.sources$' $order[1]
            Assert-Equal -Expected 'APT-GET update -qq' -Actual $order[2]
            Assert-Equal -Expected 'APT-GET install -y powershell' -Actual $order[3]
            $files = Get-SuiteFile -Root $root
            $pin = Get-Content -LiteralPath $files[1] -Raw
            Assert-Equal -Expected "Package: *`nPin: release o=microsoft-ubuntu-noble-prod noble`nPin-Priority: -1`n`nPackage: powershell`nPin: release o=microsoft-ubuntu-noble-prod noble`nPin-Priority: 500`n" -Actual $pin `
                -Because 'apt takes powershell from the suite and nothing else'
            $source = Get-Content -LiteralPath $files[0] -Raw
            Assert-Equal -Expected "Types: deb`nURIs: https://packages.microsoft.com/ubuntu/24.04/prod`nSuites: noble`nComponents: main`nArchitectures: amd64`nSigned-By: $($files[2])`n" -Actual $source
            Assert-Match '^dearmored armored key' (Get-Content -LiteralPath $files[2] -Raw) 'the verified key is the keyring the source names'
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'adds no Ubuntu suite to a host on another distribution' {
        $root = New-SuiteSandbox
        try {
            $r = Invoke-SuiteShell -Root $root -Body '( install_pwsh_noble ) || echo "RC $?"' -Environment @{ ID = 'debian'; PRETTY_NAME = 'Debian GNU/Linux 13 (trixie)' }
            Assert-Match '(?m)^RC 3$' $r.Output 'status 3 tells the caller the suite is not for this host'
            Assert-Match 'LOG Not adding Microsoft''s Ubuntu 24\.04 suite: this host runs Debian GNU/Linux 13 \(trixie\), not Ubuntu' $r.Output
            $calls = Read-SourceCall -Root $root
            Assert-True ($calls -notmatch '(?m)^(CURL|TEE|APT-GET) ') "nothing is fetched, written or asked of apt: $calls"
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'installs from a source the host already has, adding nothing' {
        $root = New-SuiteSandbox
        try {
            Set-SandboxFile -Root $root -File @{ 'madison.host' = $script:HostLine }
            $r = Invoke-SuiteShell -Root $root -Body 'install_pwsh_noble; echo "RC $?"'
            Assert-Match '(?m)^RC 0$' $r.Output
            Assert-Equal -Expected 'APT-GET install -y powershell' -Actual (Read-SourceCall -Root $root).Trim()
            Assert-True (-not (@(Get-SuiteFile -Root $root) | Where-Object { Test-Path -LiteralPath $_ })) 'no file of the suite is written'
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'asks apt for the version PWSH_VERSION names' {
        $root = New-SuiteSandbox
        try {
            Set-SandboxFile -Root $root -File @{ 'madison.host' = $script:HostLine }
            $null = Invoke-SuiteShell -Root $root -Body 'install_pwsh_noble' -Environment @{ PWSH_VERSION = '7.6.8' }
            Assert-Match '(?m)install -y powershell=7\.6\.8-1\.deb$' (Read-SourceCall -Root $root)
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'removes what it wrote, and installs nothing, when the suite <Case>' -TestCases @(
        @{ Case = 'cannot be read by apt'; Fixture = 'apt.update-fails' }
        @{ Case = 'carries no powershell'; Fixture = 'suite.empty' }
    ) {
        param([string]$Case, [string]$Fixture)
        $null = $Case
        $root = New-SuiteSandbox
        try {
            Set-SandboxFile -Root $root -File @{ $Fixture = 'yes' }
            $r = Invoke-SuiteShell -Root $root -Body '( install_pwsh_noble ) || echo "RC $?"'
            Assert-Match '(?m)^RC 1$' $r.Output 'a suite that could not be added ends with status 1'
            Assert-True (-not (@(Get-SuiteFile -Root $root) | Where-Object { Test-Path -LiteralPath $_ })) 'every file the attempt wrote is gone'
            Assert-True ((Read-SourceCall -Root $root) -notmatch 'install -y') 'apt is not asked to install from a suite it could not use'
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'trusts no key but the one that signs the suite' {
        $root = New-SuiteSandbox
        try {
            Set-SandboxFile -Root $root -File @{ 'key.mismatch' = 'yes' }
            $r = Invoke-SuiteShell -Root $root -Body '( install_pwsh_noble ) || echo "RC $?"'
            Assert-Match 'DIE Unexpected key fingerprint' $r.Output
            Assert-Match '(?m)^RC 1$' $r.Output
            Assert-True ((Read-SourceCall -Root $root) -notmatch 'TEE|GPG|APT-GET') 'nothing reaches apt before the key is verified'
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'removes the suite once another source offers powershell' {
        $root = New-SuiteSandbox -WithSuite
        try {
            Set-SandboxFile -Root $root -File @{ 'madison.host' = $script:HostLine }
            $r = Invoke-SuiteShell -Root $root -Body 'retire_pwsh_noble_source; echo "RC $?"'
            Assert-Match '(?m)^RC 0$' $r.Output
            Assert-True (-not (@(Get-SuiteFile -Root $root) | Where-Object { Test-Path -LiteralPath $_ })) 'the source, pin and keyring are all removed'
            Assert-Match '(?m)^APT-GET update -q$' (Read-SourceCall -Root $root) 'apt reads the change at once'
            Assert-Match 'Another apt source offers powershell' $r.Output
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'keeps the suite while it is the only source that offers powershell' {
        $root = New-SuiteSandbox -WithSuite
        try {
            $r = Invoke-SuiteShell -Root $root -Body 'retire_pwsh_noble_source; echo "RC $?"'
            Assert-Match '(?m)^RC 0$' $r.Output
            Assert-Equal -Expected 3 -Actual @(Get-SuiteFile -Root $root | Where-Object { Test-Path -LiteralPath $_ }).Count
            Assert-Equal -Expected '' -Actual (Read-SourceCall -Root $root)
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'never lets the suite stop the index refresh' {
        # Microsoft can change the key that signs the suite; apt then fails every refresh
        # with "The repository ... is not signed", and the installer's refresh ends the run.
        $root = New-SuiteSandbox -WithSuite
        try {
            $r = Invoke-SuiteShell -Root $root -Body '( exit 100 ) || retry_apt_update_without_pwsh_noble_source; echo "RC $?"'
            Assert-Match '(?m)^RC 0$' $r.Output 'the refresh runs again without the suite'
            Assert-True (-not (@(Get-SuiteFile -Root $root) | Where-Object { Test-Path -LiteralPath $_ })) 'the suite is removed'
            Assert-Equal -Expected 'APT-GET update -q' -Actual (Read-SourceCall -Root $root).Trim()
            Assert-Match 'WARN .apt-get update. failed with Microsoft''s Ubuntu 24\.04 suite configured' $r.Output
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'leaves a failed index refresh to end the install when the suite is not configured' {
        $root = New-SuiteSandbox
        try {
            $r = Invoke-SuiteShell -Root $root -Body 'if ( exit 100 ) || retry_apt_update_without_pwsh_noble_source; then echo REFRESHED; else echo "RC $?"; fi'
            Assert-Match '(?m)^RC 100$' $r.Output 'apt''s own status ends the run, as it always has'
            Assert-Equal -Expected '' -Actual (Read-SourceCall -Root $root) -Because 'nothing is retried'
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'retires the suite in the run''s own index refresh once another source offers powershell' {
        Assert-True ($script:RefreshBlock -ne '') 'install/ubuntu.kvm.sh refreshes the apt index, then retires the 24.04 suite'
        $root = New-SuiteSandbox -WithSuite
        try {
            Set-SandboxFile -Root $root -File @{ 'madison.host' = $script:HostLine }
            $r = Invoke-SuiteShell -Root $root -Body ($script:RefreshBlock + 'echo CONTINUED')
            Assert-Match '(?m)^CONTINUED$' $r.Output $r.Output
            Assert-True (-not (@(Get-SuiteFile -Root $root) | Where-Object { Test-Path -LiteralPath $_ })) 'the source, pin and keyring are all removed'
            $updates = @((Read-SourceCall -Root $root) -split "`n" | Where-Object { $_ -eq 'APT-GET update -q' })
            Assert-Equal -Expected 2 -Actual $updates.Count -Because 'the refresh, then the one that reads the removal'
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'goes on past an index refresh that fails with the suite configured' {
        # Microsoft can change the key that signs the suite; apt then refuses its index,
        # and every refresh fails while the suite stays configured.
        Assert-True ($script:RefreshBlock -ne '') 'install/ubuntu.kvm.sh refreshes the apt index, then retires the 24.04 suite'
        $root = New-SuiteSandbox -WithSuite
        try {
            Set-SandboxFile -Root $root -File @{ 'suite.unverifiable' = 'yes' }
            $r = Invoke-SuiteShell -Root $root -Body ($script:RefreshBlock + 'echo CONTINUED')
            Assert-Match '(?m)^CONTINUED$' $r.Output "the run goes on: $($r.Output)"
            Assert-True (-not (@(Get-SuiteFile -Root $root) | Where-Object { Test-Path -LiteralPath $_ })) 'the suite is removed'
            Assert-Match 'WARN .apt-get update. failed with Microsoft''s Ubuntu 24\.04 suite configured' $r.Output
        } finally { Remove-YurunaTestTempDir $root }
    }
}
