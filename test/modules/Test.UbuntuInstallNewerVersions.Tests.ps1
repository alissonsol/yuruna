<#PSScriptInfo
.VERSION 2026.11.16
.GUID 42fa525b-d6fb-4b09-9d03-bd3ae14d707a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test install ubuntu version report pester
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
    Behavioral Pester guard on the Ubuntu installer's closing "Newer versions
    available" report.
.DESCRIPTION
    The floor check says whether each tool is at least its floor; it says
    nothing about a newer release the tool's own source offers. The report names
    each tool the installer manages that its source has newer than what is
    installed, with why the run left it, and says "unknown" when a source does
    not answer: a lookup that failed must never read as current. PowerShell is
    compared with GitHub's newest release whatever its source, because a
    package that no apt source carries is its own apt candidate.

    The bodies under test are lifted out of install/ubuntu.kvm.sh. apt, dpkg,
    snapd, pwsh, curl and the platform probes are stubs reading files the test
    writes, so no case reaches the network or the host's packages.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -Command "Invoke-Pester -Path test/modules/Test.UbuntuInstallNewerVersions.Tests.ps1"
#>

BeforeAll {
$here      = Split-Path -Parent $PSCommandPath
$repoRoot  = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$installer = Join-Path $repoRoot 'install/ubuntu.kvm.sh'

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

if (-not (Test-Path -LiteralPath $installer)) { throw "Installer not found: $installer" }
$script:Lifted = Get-YurunaTestShellFunction -Text (Get-Content -LiteralPath $installer -Raw) -Name @(
    'requirement_floor', 'version_ge', 'powershell_deb_installed', 'apt_package_held',
    'apt_newer_lines', 'pwsh_newer_line', 'module_newer_lines', 'amd_git_newer_line', 'report_newer_versions')

# Every source the report asks is a stub over a file in $FAKE_ROOT; a missing
# file is a source that did not answer.
$script:Prelude = @'
set -euo pipefail
log()  { printf 'LOG %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
note_issue() { printf 'ISSUE %s\n' "$*"; }
answer() { [[ -f "$FAKE_ROOT/$1" ]] || return 1; cat "$FAKE_ROOT/$1"; }
pwsh_version() { answer pwsh.version; }
pwsh_source() { answer pwsh.source || echo none; }
pwsh_latest_release() { answer github.latest; }
pwsh() { answer pwsh.modules; }
# dpkg and apt-mark read the same selection, so a held package reads "hold ok
# installed", as dpkg prints it.
dpkg-query() {
  [[ -f "$FAKE_ROOT/dpkg.owns-powershell" ]] || return 1
  if [[ -f "$FAKE_ROOT/apt.holds" ]] && grep -x powershell "$FAKE_ROOT/apt.holds" >/dev/null; then printf 'hold ok installed'
  else printf 'install ok installed'; fi
}
apt-mark() { answer apt.holds || true; }
apt-cache() { answer apt.policy; }
dpkg() {
  # Only --compare-versions A lt B is asked; sort -V orders these test versions as dpkg would.
  [[ "$3" == lt && "$2" != "$4" && "$(printf '%s\n%s\n' "$2" "$4" | sort -V | head -1)" == "$2" ]]
}
snap() { answer snap.refresh-list; }
curl() { answer kernel.org.listing; }
is_amd_ryzen_ai_platform() { [[ -f "$FAKE_ROOT/amd.platform" ]]; }
tool_version() { answer "$1.version"; }
APT_PACKAGES=(qemu-utils git tesseract-ocr)
POWERSHELL_YAML_VERSION="0.4.12"
'@

function New-ReportSandbox {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: creates a temp sandbox tree the test removes in its finally block; not user-facing state.')]
    param([hashtable]$Files = @{})
    $root = New-YurunaTestTempDir -Prefix 'yuruna-newer'
    foreach ($sub in @('automation', 'tools')) { New-Item -ItemType Directory -Path (Join-Path $root $sub) -Force | Out-Null }
    Set-Content -LiteralPath (Join-Path $root 'automation/Yuruna.Requirement.yml') -Value @'
requirements:
  - tool: "git"
    command: "git --version"
    version: "2.53.0"
'@
    Set-Content -LiteralPath (Join-Path $root 'tools/Install-TestModule.ps1') -Value @'
$script:YurunaGalleryModulePin = @{
    'PSScriptAnalyzer' = @{ Version = '1.25.0'; Sha512 = 'pinned' }
}
'@
    foreach ($name in $Files.Keys) { Set-Content -LiteralPath (Join-Path $root $name) -Value $Files[$name] }
    return $root
}

function Invoke-ReportShell {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Body)
    return Invoke-YurunaTestShell -Body (@($script:Prelude, $script:Lifted, $Body) -join "`n") `
        -Environment @{ FAKE_ROOT = $Root; YURUNA_DIR = $Root }
}

$script:Policy = @'
qemu-utils:
  Installed: 1:10.2.1+ds-1
  Candidate: 1:10.2.1+ds-1
  Version table:
 *** 1:10.2.1+ds-1 500
git:
  Installed: 1:2.43.0-1ubuntu7
  Candidate: 1:2.43.0-1ubuntu7.3
  Version table:
     1:2.43.0-1ubuntu7.3 500
tesseract-ocr:
  Installed: (none)
  Candidate: 5.3.4-1build5
virt-manager:
  Installed: 1:4.1.0-3
  Candidate: 1:4.1.0-3
gh:
  Installed: 2.100.0
  Candidate: 2.103.3
powershell:
  Installed: 7.6.6-1.deb
  Candidate: 7.6.9-1.deb
'@

# A requirement list whose PowerShell floor is 7.6.9, in place of the sandbox's own.
$script:PowerShellFloor = @'
requirements:
  - tool: "PowerShell"
    version: "7.6.9 (Core)"
  - tool: "git"
    command: "git --version"
    version: "2.53.0"
'@
}

Describe 'apt_newer_lines' {
    It 'names each installed package whose candidate is newer, with why the run left it' {
        $root = New-ReportSandbox -Files @{ 'apt.policy' = $script:Policy; 'apt.holds' = 'powershell'; 'dpkg.owns-powershell' = 'yes' }
        try {
            $r = Invoke-ReportShell -Root $root -Body 'apt_newer_lines'
            Assert-Match '(?m)^git: 1:2\.43\.0-1ubuntu7 -> 1:2\.43\.0-1ubuntu7\.3 \(apt; apt did not move it in this run\)$' $r.Output
            Assert-Match '(?m)^gh: 2\.100\.0 -> 2\.103\.3 \(apt; this installer installs gh only when it is absent\)$' $r.Output
            Assert-Match '(?m)^powershell: 7\.6\.6-1\.deb -> 7\.6\.9-1\.deb \(apt; held by apt-mark hold\)$' $r.Output `
                'a held PowerShell is reported although the package list left it out'
            Assert-True ($r.Output -notmatch 'qemu-utils|virt-manager') 'a package at its candidate is not listed'
            Assert-True ($r.Output -notmatch 'tesseract') 'a package that is not installed is not listed'
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'says unknown when apt does not answer' {
        $root = New-ReportSandbox
        try {
            $r = Invoke-ReportShell -Root $root -Body 'apt_newer_lines'
            Assert-Equal -Expected 'apt packages: unknown (apt-cache policy did not answer)' -Actual $r.Output.Trim()
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'says why the package list left out a powershell candidate apt cannot install' {
        $policy = "powershell:`n  Installed: 7.6.9-1.deb`n  Candidate: 7.6.10-1.deb"
        $root = New-ReportSandbox -Files @{ 'apt.policy' = $policy; 'dpkg.owns-powershell' = 'yes' }
        try {
            $r = Invoke-ReportShell -Root $root -Body "PWSH_APT_UNINSTALLABLE=1`napt_newer_lines"
            Assert-Equal -Expected 'powershell: 7.6.9-1.deb -> 7.6.10-1.deb (apt; apt cannot install that candidate here, so this run left it out of the package list)' -Actual $r.Output.Trim()
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'says unknown, not current, for an installed package that no configured source offers' {
        # apt-cache policy's own words when the only origin left is dpkg's status file:
        # the candidate is the installed version, so apt cannot say what is newer.
        # PowerShell in that state is left to pwsh_newer_line, which asks GitHub.
        $policy = @'
gh:
  Installed: 2.100.0
  Candidate: 2.100.0
  Version table:
 *** 2.100.0 100
        100 /var/lib/dpkg/status
powershell:
  Installed: 7.6.6-1.deb
  Candidate: 7.6.6-1.deb
  Version table:
 *** 7.6.6-1.deb 100
        100 /var/lib/dpkg/status
git:
  Installed: 1:2.43.0-1ubuntu7.3
  Candidate: 1:2.43.0-1ubuntu7.3
  Version table:
 *** 1:2.43.0-1ubuntu7.3 500
        500 http://archive.ubuntu.com/ubuntu resolute-updates/main amd64 Packages
        100 /var/lib/dpkg/status
'@
        $root = New-ReportSandbox -Files @{ 'apt.policy' = $policy; 'dpkg.owns-powershell' = 'yes' }
        try {
            $r = Invoke-ReportShell -Root $root -Body 'apt_newer_lines'
            Assert-Equal -Expected 'gh: 2.100.0 -> unknown (no configured apt source offers gh)' -Actual $r.Output.Trim() `
                -Because 'a package at a candidate some source offers is current, and powershell is reported against GitHub instead'
        } finally { Remove-YurunaTestTempDir $root }
    }
}

Describe 'pwsh_newer_line' {
    It 'names <Expected> for a <Source> copy behind the newest release' -TestCases @(
        @{ Source = 'tarball'; Expected = 'PowerShell: 7.6.6 -> 7.6.9 (release tarball; the tarball upgrade did not complete)' }
        @{ Source = 'other'; Expected = 'PowerShell: 7.6.6 -> 7.6.9 (GitHub release; pwsh comes from a source this installer does not manage)' }
    ) {
        param([string]$Source, [string]$Expected)
        $root = New-ReportSandbox -Files @{ 'pwsh.version' = '7.6.6'; 'pwsh.source' = $Source; 'github.latest' = '7.6.9' }
        try {
            $r = Invoke-ReportShell -Root $root -Body 'pwsh_newer_line'
            Assert-Equal -Expected $Expected -Actual $r.Output.Trim()
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'says unknown, not current, when GitHub names no release' {
        $root = New-ReportSandbox -Files @{ 'pwsh.version' = '7.6.6'; 'pwsh.source' = 'tarball' }
        try {
            $r = Invoke-ReportShell -Root $root -Body 'pwsh_newer_line'
            Assert-Equal -Expected 'PowerShell: 7.6.6 -> unknown (GitHub did not name the newest release)' -Actual $r.Output.Trim()
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'names a snap refresh snapd has pending' {
        $root = New-ReportSandbox -Files @{ 'pwsh.version' = '7.6.6'; 'pwsh.source' = 'snap'
            'snap.refresh-list' = "Name        Version  Rev  Size  Publisher  Notes`npowershell  7.6.9    320  70MB  microsoft  classic" }
        try {
            $r = Invoke-ReportShell -Root $root -Body 'pwsh_newer_line'
            Assert-Equal -Expected 'PowerShell: 7.6.6 -> 7.6.9 (snap; snapd has not refreshed it yet)' -Actual $r.Output.Trim()
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'leaves a current <Source> copy unnamed' -TestCases @(
        @{ Source = 'tarball' }, @{ Source = 'apt' }
    ) {
        param([string]$Source)
        $root = New-ReportSandbox -Files @{ 'pwsh.version' = '7.6.9'; 'pwsh.source' = $Source; 'github.latest' = '7.6.9'; 'dpkg.owns-powershell' = 'yes' }
        try {
            Assert-Equal -Expected '' -Actual (Invoke-ReportShell -Root $root -Body 'pwsh_newer_line').Output.Trim()
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'names Microsoft''s package behind the newest release when <Case>' -TestCases @(
        @{ Case = 'nothing says why'; Files = @{}; Body = ''
            Expected = 'PowerShell: 7.6.6 -> 7.6.9 (Microsoft''s package; the package upgrade did not complete)' }
        @{ Case = 'the operator holds it'; Files = @{ 'apt.holds' = 'powershell' }; Body = ''
            Expected = 'PowerShell: 7.6.6 -> 7.6.9 (Microsoft''s package; held by apt-mark hold; ''sudo apt-mark unhold powershell'' releases it)' }
        @{ Case = 'the run''s package sources fell short'; Files = @{}
            Body = 'PWSH_UPGRADE_WHY="the release .deb could not be fetched or verified, and Microsoft''s Ubuntu 24.04 suite could not be added"'
            Expected = 'PowerShell: 7.6.6 -> 7.6.9 (Microsoft''s package; the release .deb could not be fetched or verified, and Microsoft''s Ubuntu 24.04 suite could not be added)' }
        @{ Case = 'PWSH_VERSION names an older release'; Files = @{}; Body = 'PWSH_VERSION=7.6.6'
            Expected = 'PowerShell: 7.6.6 -> 7.6.9 (Microsoft''s package; PWSH_VERSION is 7.6.6)' }
    ) {
        param([string]$Case, [hashtable]$Files, [string]$Body, [string]$Expected)
        $null = $Case
        # A package no configured source carries is its own apt candidate, so only
        # GitHub's release says it is behind.
        $root = New-ReportSandbox -Files (@{ 'pwsh.version' = '7.6.6'; 'pwsh.source' = 'apt'; 'github.latest' = '7.6.9'; 'dpkg.owns-powershell' = 'yes' } + $Files)
        try {
            $r = Invoke-ReportShell -Root $root -Body ($Body + "`npwsh_newer_line")
            Assert-Equal -Expected $Expected -Actual $r.Output.Trim()
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'says unknown, not current, for Microsoft''s package when GitHub names no release' {
        $root = New-ReportSandbox -Files @{ 'pwsh.version' = '7.6.6'; 'pwsh.source' = 'apt'; 'dpkg.owns-powershell' = 'yes' }
        try {
            $r = Invoke-ReportShell -Root $root -Body 'pwsh_newer_line'
            Assert-Equal -Expected 'PowerShell: 7.6.6 -> unknown (GitHub did not name the newest release)' -Actual $r.Output.Trim()
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'says why the run''s sources fell short when GitHub names no release' {
        # With GitHub out of reach the newest release is unknown, and the reason the
        # package did not move still belongs beside it.
        $root = New-ReportSandbox -Files @{ 'pwsh.version' = '7.6.6'; 'pwsh.source' = 'apt'; 'dpkg.owns-powershell' = 'yes' }
        try {
            $r = Invoke-ReportShell -Root $root -Body ('PWSH_UPGRADE_WHY="the release .deb could not be fetched or verified, and Microsoft''s Ubuntu 24.04 suite could not be added"' + "`npwsh_newer_line")
            Assert-Equal -Expected 'PowerShell: 7.6.6 -> unknown (GitHub did not name the newest release; the release .deb could not be fetched or verified, and Microsoft''s Ubuntu 24.04 suite could not be added)' -Actual $r.Output.Trim()
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'says unknown, not current, for <Label> below its floor when GitHub''s newest release is older still' -TestCases @(
        @{ Label = 'Microsoft''s package'; Source = 'apt'; Files = @{ 'dpkg.owns-powershell' = 'yes' } }
        @{ Label = 'a tarball copy'; Source = 'tarball'; Files = @{} }
    ) {
        param([string]$Label, [string]$Source, [hashtable]$Files)
        $null = $Label
        # GitHub can mark an older line as the latest. The floor check still reports the
        # copy below its floor, and the report must not call that copy current.
        $root = New-ReportSandbox -Files (@{ 'pwsh.version' = '7.6.6'; 'pwsh.source' = $Source; 'github.latest' = '7.4.22'
                'automation/Yuruna.Requirement.yml' = $script:PowerShellFloor } + $Files)
        try {
            $r = Invoke-ReportShell -Root $root -Body 'pwsh_newer_line'
            Assert-Equal -Expected 'PowerShell: 7.6.6 -> unknown (GitHub''s newest release 7.4.22 is below the 7.6.9 floor)' -Actual $r.Output.Trim()
            # A copy at its floor is past that release, and nothing newer is known.
            Set-Content -LiteralPath (Join-Path $root 'pwsh.version') -Value '7.6.9'
            Assert-Equal -Expected '' -Actual (Invoke-ReportShell -Root $root -Body 'pwsh_newer_line').Output.Trim()
        } finally { Remove-YurunaTestTempDir $root }
    }
}

Describe 'module_newer_lines' {
    It 'names a module below its pin and leaves one at or past it' {
        $root = New-ReportSandbox -Files @{ 'pwsh.modules' = "powershell-yaml 0.4.11`nPSScriptAnalyzer 1.25.0" }
        try {
            $r = Invoke-ReportShell -Root $root -Body 'module_newer_lines'
            Assert-Equal -Expected 'powershell-yaml: 0.4.11 -> 0.4.12 (pinned in the PowerShell Gallery; the install of the pin did not complete)' -Actual $r.Output.Trim()
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'reads the PSScriptAnalyzer pin from tools/Install-TestModule.ps1' {
        $root = New-ReportSandbox -Files @{ 'pwsh.modules' = "powershell-yaml 0.4.12`nPSScriptAnalyzer 1.24.0" }
        try {
            $r = Invoke-ReportShell -Root $root -Body 'module_newer_lines'
            Assert-Match '^PSScriptAnalyzer: 1\.24\.0 -> 1\.25\.0 \(pinned' $r.Output.Trim()
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'says unknown when pwsh cannot list them' {
        $root = New-ReportSandbox
        try {
            Assert-Equal -Expected 'PowerShell modules: unknown (pwsh could not list them)' -Actual (Invoke-ReportShell -Root $root -Body 'module_newer_lines').Output.Trim()
        } finally { Remove-YurunaTestTempDir $root }
    }
}

Describe 'amd_git_newer_line' {
    It 'names the newest kernel.org release past the floor build, ordered by number' {
        # 2.9.5 sorts after 2.56.0 as text; release candidates are not releases.
        $root = New-ReportSandbox -Files @{ 'amd.platform' = 'yes'; 'git.version' = '2.53.0'
            'kernel.org.listing' = '<a href="git-2.9.5.tar.xz">git-2.9.5.tar.xz</a> <a href="git-2.56.0.tar.xz">git-2.56.0.tar.xz</a> <a href="git-2.57.0-rc0.tar.xz">git-2.57.0-rc0.tar.xz</a>' }
        try {
            $r = Invoke-ReportShell -Root $root -Body 'amd_git_newer_line'
            Assert-Equal -Expected 'git: 2.53.0 -> 2.56.0 (kernel.org; this installer builds git at its 2.53.0 floor)' -Actual $r.Output.Trim()
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'says nothing off the AMD platform, where apt owns git' {
        $root = New-ReportSandbox -Files @{ 'git.version' = '2.43.0' }
        try {
            Assert-Equal -Expected '' -Actual (Invoke-ReportShell -Root $root -Body 'amd_git_newer_line').Output.Trim()
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'says unknown when kernel.org does not answer' {
        $root = New-ReportSandbox -Files @{ 'amd.platform' = 'yes'; 'git.version' = '2.53.0' }
        try {
            Assert-Equal -Expected 'git: 2.53.0 -> unknown (kernel.org did not answer)' -Actual (Invoke-ReportShell -Root $root -Body 'amd_git_newer_line').Output.Trim()
        } finally { Remove-YurunaTestTempDir $root }
    }
}

Describe 'report_newer_versions' {
    It 'prints one line per tool under its heading and never fails the run' {
        $root = New-ReportSandbox -Files @{ 'pwsh.version' = '7.6.6'; 'pwsh.source' = 'tarball'; 'apt.policy' = $script:Policy
            'pwsh.modules' = "powershell-yaml 0.4.12`nPSScriptAnalyzer 1.25.0" }
        try {
            $r = Invoke-ReportShell -Root $root -Body 'report_newer_versions; echo "EXIT $?"'
            $lines = @($r.Output -split "`n")
            Assert-Equal -Expected 'LOG Newer versions available' -Actual $lines[0]
            Assert-Match '(?m)^LOG   PowerShell: 7\.6\.6 -> unknown \(GitHub did not name the newest release\)$' $r.Output
            Assert-Match '(?m)^LOG   git: 1:2\.43\.0-1ubuntu7 -> 1:2\.43\.0-1ubuntu7\.3 \(apt; ' $r.Output
            Assert-Match '(?m)^EXIT 0$' $r.Output
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'names a PowerShell package that no apt source carries, rather than calling every tool current' {
        # apt-cache policy's own words for an installed package that no source carries:
        # the candidate is the installed version, listed only from dpkg's status file.
        $policy = @'
qemu-utils:
  Installed: 1:10.2.1+ds-1
  Candidate: 1:10.2.1+ds-1
  Version table:
 *** 1:10.2.1+ds-1 500
        500 http://archive.ubuntu.com/ubuntu resolute/main amd64 Packages
        100 /var/lib/dpkg/status
powershell:
  Installed: 7.6.6-1.deb
  Candidate: 7.6.6-1.deb
  Version table:
 *** 7.6.6-1.deb 100
        100 /var/lib/dpkg/status
'@
        $root = New-ReportSandbox -Files @{ 'pwsh.version' = '7.6.6'; 'pwsh.source' = 'apt'; 'github.latest' = '7.6.9'; 'dpkg.owns-powershell' = 'yes'
            'apt.policy' = $policy; 'pwsh.modules' = "powershell-yaml 0.4.12`nPSScriptAnalyzer 1.25.0" }
        try {
            $r = Invoke-ReportShell -Root $root -Body 'report_newer_versions'
            Assert-Match '(?m)^LOG   PowerShell: 7\.6\.6 -> 7\.6\.9 \(Microsoft''s package; ' $r.Output 'the report agrees with a floor check that calls 7.6.6 old'
            Assert-True ($r.Output -notmatch 'none:') 'a tool behind its newest release is never reported as current'
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'names a PowerShell below its floor, rather than calling every tool current, when GitHub''s newest release is older' {
        # The operator's shape with GitHub marking an older line as the latest: the package
        # is listed only from dpkg's status file, and 7.4.22 is older than 7.6.6.
        $policy = @'
qemu-utils:
  Installed: 1:10.2.1+ds-1
  Candidate: 1:10.2.1+ds-1
  Version table:
 *** 1:10.2.1+ds-1 500
        500 http://archive.ubuntu.com/ubuntu resolute/main amd64 Packages
        100 /var/lib/dpkg/status
powershell:
  Installed: 7.6.6-1.deb
  Candidate: 7.6.6-1.deb
  Version table:
 *** 7.6.6-1.deb 100
        100 /var/lib/dpkg/status
'@
        $root = New-ReportSandbox -Files @{ 'pwsh.version' = '7.6.6'; 'pwsh.source' = 'apt'; 'github.latest' = '7.4.22'; 'dpkg.owns-powershell' = 'yes'
            'apt.policy' = $policy; 'pwsh.modules' = "powershell-yaml 0.4.12`nPSScriptAnalyzer 1.25.0"; 'automation/Yuruna.Requirement.yml' = $script:PowerShellFloor }
        try {
            $r = Invoke-ReportShell -Root $root -Body 'report_newer_versions'
            Assert-Match '(?m)^LOG   PowerShell: 7\.6\.6 -> unknown \(GitHub''s newest release 7\.4\.22 is below the 7\.6\.9 floor\)$' $r.Output
            Assert-True ($r.Output -notmatch 'none:') 'the report agrees with a floor check that calls 7.6.6 old'
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'says so in one line when every tool is current' {
        $current = "qemu-utils:`n  Installed: 1.0`n  Candidate: 1.0"
        $root = New-ReportSandbox -Files @{ 'pwsh.version' = '7.6.9'; 'pwsh.source' = 'tarball'; 'github.latest' = '7.6.9'
            'apt.policy' = $current; 'pwsh.modules' = "powershell-yaml 0.4.12`nPSScriptAnalyzer 1.25.0" }
        try {
            $r = Invoke-ReportShell -Root $root -Body 'report_newer_versions'
            Assert-Equal -Expected "LOG Newer versions available`nLOG   none: every tool this installer manages is at the newest version its source offers" -Actual $r.Output.Trim()
        } finally { Remove-YurunaTestTempDir $root }
    }
}
