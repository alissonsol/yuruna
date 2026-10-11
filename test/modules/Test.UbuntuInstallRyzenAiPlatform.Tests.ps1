<#PSScriptInfo
.VERSION 2026.10.11
.GUID 421942f3-d52f-4211-83d4-3fe55a882f99
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test install ubuntu debian amd ryzen backports version floor pester
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
    Behavioral Pester guard on the Ubuntu installer's handling of the AMD Ryzen
    AI Developer Platform: recognizing the platform, reading the version a tool
    answers with, sending each tool below its floor to the source that can raise
    it, and keeping virt-install on the system interpreter it needs.
.DESCRIPTION
    The platform is Debian trixie underneath, so apt-get install leaves git,
    python3, curl and qemu-img below floors that track the Ubuntu 26.04 archive.
    Backports raise curl and qemu-img and a signed release tarball raises git.
    python3 cannot move: virt-install, virt-manager and the platform's own tools
    run `#!/usr/bin/env python3` and need /usr/bin/python3's modules, so any
    other interpreter on PATH breaks every VM build. The choices turn on things
    no install log shows:

      * the version banner differs per tool, and three of the four print more
        than one dotted number on their first line.
      * a host that is not the platform, or a tool already at its floor, must be
        left alone.
      * a python3 link that shadows the system interpreter is removed only when
        it points at the standalone tree, and that tree only while it holds
        nothing else.
      * the osinfo diagnostics run under the installer's errexit and pipefail,
        and must report a virt-install that cannot start rather than end the run.

    The bodies under test are lifted out of install/ubuntu.kvm.sh rather than
    copied, so a rewrite there is exercised here instead of drifting away from a
    stale duplicate. Everything the repair reaches outside its own logic (sudo,
    apt, the build, virt-install) is a stub writing to a temporary tree, so the
    tests run anywhere bash does and never touch the host.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -Command "Invoke-Pester -Path test/modules/Test.UbuntuInstallRyzenAiPlatform.Tests.ps1"
#>

BeforeAll {
$here      = Split-Path -Parent $PSCommandPath
$repoRoot  = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$installer = Join-Path $repoRoot 'install/ubuntu.kvm.sh'

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

if (-not (Test-Path -LiteralPath $installer)) { throw "Installer not found: $installer" }
$installerText = Get-Content -LiteralPath $installer -Raw

# The installer elevates, installs packages and rewrites the checkout, so it
# cannot be sourced. The functions under test are lifted out of it by name.
$script:Lifted = Get-YurunaTestShellFunction -Text $installerText -Name @(
    'requirement_floor', 'version_ge', 'is_amd_ryzen_ai_platform', 'tool_version',
    'tool_below_floor', 'confirm_tool_floor', 'raise_tool_from_suite',
    'bring_amd_ryzen_ai_platform_to_floors', 'remove_standalone_python',
    'floor_check_tools', 'virt_install_runs', 'osinfo_db_diag', 'local_git_incomplete',
    'osinfo_has_variant', 'check_virt_install_ready', 'ensure_osinfo_db_has_ubuntu24', 'report_floor_check')

# Stubs for everything the repair reaches beyond its own decisions. apt raises a
# tool by rewriting the version file its stand-in binary prints, and so does the
# build. Each stub records that it was reached.
$script:Prelude = @'
set -euo pipefail
ARCH="${ARCH:-x86_64}"
qemu_kvm_pkg="qemu-system-x86"
log()  { printf 'LOG %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
note_issue() { printf 'ISSUE %s\n' "$*"; }
sudo() {
  if [[ "${1:-}" == rm || "${1:-}" == rmdir ]]; then "$@"; return; fi
  printf 'SUDO %s\n' "$*" >> "$FAKE_ROOT/calls"
  [[ "${1:-}" == DEBIAN_FRONTEND=* ]] || return 0
  [[ ! -f "$FAKE_ROOT/apt.fails" ]] || return 1
  local pkg tool ver
  for pkg in "$@"; do
    if [[ -f "$FAKE_ROOT/apt-raises.$pkg" ]]; then
      read -r tool ver < "$FAKE_ROOT/apt-raises.$pkg"
      printf '%s\n' "$ver" > "$FAKE_ROOT/$tool.version"
    fi
  done
}
enable_debian_backports() {
  printf 'BACKPORTS %s\n' "$1" >> "$FAKE_ROOT/calls"
  [[ ! -f "$FAKE_ROOT/backports.fails" ]]
}
build_git_from_source() {
  printf 'GIT-BUILD ver=%s suite=%s\n' "$1" "${3:-}" >> "$FAKE_ROOT/calls"
  [[ -f "$FAKE_ROOT/git.builds" ]] || return 1
  cat "$FAKE_ROOT/git.builds" > "$FAKE_ROOT/git.version"
}
'@

# The first line each real tool prints for --version, with the number the test
# controls substituted in. curl and qemu-img carry a second dotted number on that
# line, which is what the parser must not pick up.
$script:Banner = @{
    'git'      = 'git version {0}'
    'python3'  = 'Python {0}'
    'curl'     = 'curl {0} (x86_64-pc-linux-gnu) libcurl/{0} OpenSSL/3.5.7 zlib/1.3.1 brotli/1.1.0'
    'qemu-img' = 'qemu-img version {0} (Debian 1:{0}+ds-0+deb13u1)'
}

$script:SampleRequirements = @'
requirements:
  - tool: "git"
    command: |-
      ((git --version) -replace '^git version ','')
    version: "2.53.0"
    releases: "https://git-scm.com/downloads"
  - tool: "python3"
    command: |-
      ((python3 --version) -replace '^Python ','')
    version: "3.14.4"
    releases: "https://www.python.org/downloads/"
  - tool: "curl"
    command: |-
      ((curl --version | Select-Object -First 1) -replace '\s*\(.*$','')
    version: "curl 8.18.0"
    releases: "https://curl.se/download.html"
  - tool: "qemu-img"
    command: |-
      ((qemu-img --version | Select-Object -First 1) -replace ',\s*Copyright.*$','')
    version: "qemu-img version 10.2.1"
    releases: "https://www.qemu.org/download/"
'@

# A temporary tree holding the requirement list, a stand-in binary per tool that
# prints the banner for whatever version the test last wrote, a stand-in
# virt-install the test can make fail, and the call log.
function New-PlatformSandbox {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: creates a temp sandbox tree the test removes in its finally block; not user-facing state.')]
    param([Parameter(Mandatory)][hashtable]$Version)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-ryzenai-{0}" -f [guid]::NewGuid().ToString('N'))
    foreach ($sub in @('bin', 'automation')) {
        New-Item -ItemType Directory -Path (Join-Path $root $sub) -Force | Out-Null
    }
    Set-Content -LiteralPath (Join-Path $root 'automation/Yuruna.Requirement.yml') -Value $script:SampleRequirements
    foreach ($tool in $script:Banner.Keys) {
        Set-Content -LiteralPath (Join-Path $root "$tool.version") -Value $Version[$tool]
        $line = $script:Banner[$tool] -f ('$(cat ''' + (Join-Path $root "$tool.version") + ''')')
        $path = Join-Path (Join-Path $root 'bin') $tool
        Set-Content -LiteralPath $path -Value "#!/bin/bash`necho `"$line`"`necho 'second line'`n"
        & chmod +x $path
    }
    # Fails the way it does under the wrong interpreter when virt.fails exists;
    # otherwise prints virt.list for --osinfo list.
    $virt = Join-Path (Join-Path $root 'bin') 'virt-install'
    Set-Content -LiteralPath $virt -Value @"
#!/bin/bash
if [[ -f '$root/virt.fails' ]]; then
  echo 'Traceback (most recent call last):' >&2
  echo "ModuleNotFoundError: No module named 'gi'" >&2
  exit 1
fi
if [[ "`$1" == --version ]]; then echo 5.0.0; exit 0; fi
cat '$root/virt.list' 2>/dev/null || true
"@
    & chmod +x $virt
    return $root
}

# Runs a bash body with the lifted functions and the stubs in scope. The sandbox
# bin directory leads PATH so a stand-in, never a host binary, answers each name.
function Invoke-PlatformShell {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Body,
        [string]$PrettyName = 'AMD Ryzen AI Developer Platform 1 (rex)'
    )
    $environment = @{
        YURUNA_DIR      = $Root
        FAKE_ROOT       = $Root
        HOME            = $Root
        PRETTY_NAME     = $PrettyName
        DEBIAN_CODENAME = 'trixie'
        PATH            = "$(Join-Path $Root 'bin'):/usr/bin:/bin"
    }
    return Invoke-YurunaTestShell -Body (@($script:Prelude, $script:Lifted, $Body) -join "`n") -Environment $environment
}

function Get-SandboxCall {
    param([Parameter(Mandatory)][string]$Root)
    $path = Join-Path $Root 'calls'
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    return Get-Content -LiteralPath $path -Raw
}

$script:Below = @{ 'git' = '2.47.3'; 'python3' = '3.13.5'; 'curl' = '8.14.1'; 'qemu-img' = '10.0.13' }
$script:AtFloor = @{ 'git' = '2.53.0'; 'python3' = '3.14.4'; 'curl' = '8.18.0'; 'qemu-img' = '10.2.1' }
}

Describe 'is_amd_ryzen_ai_platform' {
    It 'recognizes the platform by the start of its release name' {
        $root = New-PlatformSandbox -Version $script:Below
        try {
            $r = Invoke-PlatformShell -Root $root -Body 'is_amd_ryzen_ai_platform && echo PLATFORM'
            Assert-Match 'PLATFORM' $r.Output 'the release name the platform ships is recognized'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'does not claim an Ubuntu host or a host that names no release' {
        $root = New-PlatformSandbox -Version $script:Below
        try {
            $r = Invoke-PlatformShell -Root $root -PrettyName 'Ubuntu 26.04 LTS' -Body 'is_amd_ryzen_ai_platform || echo NOT-PLATFORM'
            Assert-Match 'NOT-PLATFORM' $r.Output 'an Ubuntu release is not the platform'
            $r = Invoke-PlatformShell -Root $root -PrettyName '' -Body 'is_amd_ryzen_ai_platform || echo NOT-PLATFORM'
            Assert-Match 'NOT-PLATFORM' $r.Output 'an empty release name is not the platform'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'tool_version' {
    It 'reads the version out of each banner, not the library or package number beside it' {
        # curl prints its libcurl version and qemu-img its Debian package version
        # on the same line; the first dotted number is the tool's own.
        $root = New-PlatformSandbox -Version $script:Below
        try {
            $r = Invoke-PlatformShell -Root $root -Body @'
for t in git python3 curl qemu-img; do printf '%s=%s\n' "$t" "$(tool_version "$t")"; done
'@
            foreach ($tool in $script:Below.Keys) {
                Assert-Match ("(?m)^{0}={1}$" -f [regex]::Escape($tool), [regex]::Escape($script:Below[$tool])) $r.Output "$tool reads as $($script:Below[$tool])"
            }
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'bring_amd_ryzen_ai_platform_to_floors' {
    It 'leaves a host that is not the platform alone' {
        $root = New-PlatformSandbox -Version $script:Below
        try {
            $r = Invoke-PlatformShell -Root $root -PrettyName 'Ubuntu 26.04 LTS' -Body 'bring_amd_ryzen_ai_platform_to_floors; echo DONE'
            Assert-Match 'DONE' $r.Output 'the repair returns cleanly'
            Assert-True ((Get-SandboxCall -Root $root) -eq '') 'no source is enabled or reached on another distribution'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'raises curl, qemu-img and git through the sources that carry them' {
        $root = New-PlatformSandbox -Version $script:Below
        try {
            Set-Content -LiteralPath (Join-Path $root 'apt-raises.curl') -Value 'curl 8.21.0'
            Set-Content -LiteralPath (Join-Path $root 'apt-raises.qemu-utils') -Value 'qemu-img 11.0.2'
            Set-Content -LiteralPath (Join-Path $root 'git.builds') -Value '2.53.0'
            $r = Invoke-PlatformShell -Root $root -Body 'bring_amd_ryzen_ai_platform_to_floors'
            $calls = Get-SandboxCall -Root $root
            Assert-Match 'BACKPORTS trixie-backports' $calls 'the backports suite of the Debian base is enabled'
            Assert-Match '-t trixie-backports curl' $calls 'curl comes from backports'
            Assert-Match '-t trixie-backports qemu-utils qemu-system-x86' $calls 'the emulator moves with the image tool'
            Assert-Match 'GIT-BUILD ver=2\.53\.0 suite=trixie-backports' $calls 'git builds at its floor, against the backports libcurl'
            foreach ($pair in @('curl now answers 8\.21\.0', 'qemu-img now answers 11\.0\.2', 'git now answers 2\.53\.0')) {
                Assert-Match $pair $r.Output "the repair reports what the name answers afterwards ($pair)"
            }
            Assert-True ($r.Output -notmatch 'ISSUE') 'a repair that reaches every floor it can records no issue'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'keeps the platform python3 and says once why it stays below its floor' {
        # Any other interpreter on PATH breaks virt-install, so nothing may try to
        # replace it, and the gap is explained rather than recorded as an issue.
        $root = New-PlatformSandbox -Version $script:Below
        try {
            $r = Invoke-PlatformShell -Root $root -Body 'bring_amd_ryzen_ai_platform_to_floors'
            Assert-Match 'LOG\s+python3 3\.13\.5 stays below the 3\.14\.4 floor: virt-install' $r.Output 'the reason is given in the run'
            Assert-True ($r.Output -notmatch 'ISSUE[^\n]*python3') 'the python3 gap is not an install issue'
            Assert-StringEqual -Expected '3.13.5' -Actual (Get-Content -LiteralPath (Join-Path $root 'python3.version') -Raw).Trim() `
                'python3 is left exactly as the platform ships it'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'reaches no source for tools already at their floors' {
        $root = New-PlatformSandbox -Version $script:AtFloor
        try {
            $r = Invoke-PlatformShell -Root $root -Body 'bring_amd_ryzen_ai_platform_to_floors'
            $calls = Get-SandboxCall -Root $root
            Assert-True ($calls -notmatch 'SUDO DEBIAN_FRONTEND') 'apt installs nothing'
            Assert-True ($calls -notmatch 'GIT-BUILD') 'git is not rebuilt'
            Assert-True ($r.Output -notmatch 'stays below') 'a python3 at its floor needs no explanation'
            Assert-Match 'git 2\.53\.0 meets the 2\.53\.0 floor' $r.Output 'each tool at its floor is reported as such'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'still builds git when backports cannot be enabled' {
        # Without backports the git headers come from the base archive, which
        # still matches the base libcurl; curl and qemu-img have nowhere to go.
        $root = New-PlatformSandbox -Version $script:Below
        try {
            Set-Content -LiteralPath (Join-Path $root 'backports.fails') -Value 'yes'
            Set-Content -LiteralPath (Join-Path $root 'git.builds') -Value '2.53.0'
            $r = Invoke-PlatformShell -Root $root -Body 'bring_amd_ryzen_ai_platform_to_floors'
            $calls = Get-SandboxCall -Root $root
            Assert-Match 'ISSUE Could not enable trixie-backports' $r.Output 'the missing source reaches the closing summary'
            Assert-True ($calls -notmatch 'SUDO DEBIAN_FRONTEND') 'no backports install is attempted'
            Assert-Match 'GIT-BUILD ver=2\.53\.0 suite=(\r?\n|$)' $calls 'git builds without a target release'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'records a failed source in the closing summary and carries on' {
        # Finishing silently below a floor is what the closing summary exists to
        # prevent; a failed source must reach it without ending the install.
        $root = New-PlatformSandbox -Version $script:Below
        try {
            Set-Content -LiteralPath (Join-Path $root 'apt.fails') -Value 'yes'
            $r = Invoke-PlatformShell -Root $root -Body 'bring_amd_ryzen_ai_platform_to_floors; echo FINISHED'
            Assert-Match 'ISSUE Installing curl from trixie-backports failed' $r.Output 'a failed apt install is recorded'
            Assert-Match 'qemu-utils' (Get-SandboxCall -Root $root) 'a later tool is still attempted after an earlier one fails'
            Assert-Match 'ISSUE Building git 2\.53\.0 from its release tarball failed' $r.Output 'a failed build is recorded with the version it aimed for'
            Assert-Match 'FINISHED' $r.Output 'the install continues past every failure'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'names the binary that answered when a repair does not win the name' {
        # An install under /usr/local/bin only wins where that directory leads
        # PATH; the warning shows which copy is answering instead.
        $root = New-PlatformSandbox -Version $script:Below
        try {
            Set-Content -LiteralPath (Join-Path $root 'git.builds') -Value '2.47.3'
            $r = Invoke-PlatformShell -Root $root -Body 'bring_amd_ryzen_ai_platform_to_floors'
            Assert-Match 'WARN\s+git answers 2\.47\.3 after the repair, still below the 2\.53\.0 floor \(resolved: .*/bin/git\)' $r.Output `
                'a repair that leaves the old version answering says which binary it is'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'remove_standalone_python' {
    BeforeAll {
        # local/bin and opt/ stand in for /usr/local/bin and /opt/cpython. Links
        # are named in -Link as name=target-relative-to-the-tree.
        function New-ShadowTree {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: builds links under a temp sandbox the test removes; not user-facing state.')]
            param([Parameter(Mandatory)][string]$Root, [string[]]$Dir = @(), [string[]]$Link = @())
            New-Item -ItemType Directory -Path (Join-Path $Root 'local/bin') -Force | Out-Null
            foreach ($d in $Dir) { New-Item -ItemType Directory -Path (Join-Path $Root $d) -Force | Out-Null }
            foreach ($pair in $Link) {
                $name, $target = $pair -split '=', 2
                & ln -s (Join-Path $Root $target) (Join-Path (Join-Path $Root 'local/bin') $name)
            }
            return $Root
        }
        function Test-LinkPresent {
            param([Parameter(Mandatory)][string]$Path)
            return [bool](Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
        }
        function Invoke-Cleanup {
            param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Tree)
            return Invoke-PlatformShell -Root $Root -Body "remove_standalone_python '$Tree/local/bin' '$Tree/opt'; echo DONE"
        }
    }
    It 'removes the python3 shadow, its sibling links, its version directory and the emptied tree' {
        $root = New-PlatformSandbox -Version $script:Below
        try {
            $tree = New-ShadowTree -Root (Join-Path $root 'shadow') -Dir 'opt/3.14.8/bin', 'elsewhere' `
                -Link 'python3=opt/3.14.8/bin/python3', 'python3.14=opt/3.14.8/bin/python3.14', 'python3.12=elsewhere/python3.12'
            $r = Invoke-Cleanup -Root $root -Tree $tree
            Assert-Match 'DONE' $r.Output 'the cleanup returns cleanly'
            Assert-False (Test-LinkPresent (Join-Path $tree 'local/bin/python3')) 'the python3 shadow is gone'
            Assert-False (Test-LinkPresent (Join-Path $tree 'local/bin/python3.14')) 'a sibling link into the same version goes with it'
            Assert-True (Test-LinkPresent (Join-Path $tree 'local/bin/python3.12')) 'a link to another interpreter is left alone'
            Assert-False (Test-Path -LiteralPath (Join-Path $tree 'opt')) 'the version directory goes, and the tree it emptied with it'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'keeps an interpreter in the tree that only a python3.N link reaches' {
        # python3.12 shadows nothing; only the python3 name breaks virt-install.
        $root = New-PlatformSandbox -Version $script:Below
        try {
            $tree = New-ShadowTree -Root (Join-Path $root 'shadow') -Dir 'opt/3.14.8/bin', 'opt/3.12.7/bin' `
                -Link 'python3=opt/3.14.8/bin/python3', 'python3.12=opt/3.12.7/bin/python3.12'
            $null = Invoke-Cleanup -Root $root -Tree $tree
            Assert-False (Test-Path -LiteralPath (Join-Path $tree 'opt/3.14.8')) 'the shadowing version is removed'
            Assert-True (Test-Path -LiteralPath (Join-Path $tree 'opt/3.12.7')) 'the other interpreter is kept'
            Assert-True (Test-LinkPresent (Join-Path $tree 'local/bin/python3.12')) 'and so is its link'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'touches nothing when no python3 link points into the tree' {
        $root = New-PlatformSandbox -Version $script:Below
        try {
            $tree = New-ShadowTree -Root (Join-Path $root 'shadow') -Dir 'opt/3.12.7/bin' -Link 'python3.12=opt/3.12.7/bin/python3.12'
            $r = Invoke-Cleanup -Root $root -Tree $tree
            Assert-True (Test-Path -LiteralPath (Join-Path $tree 'opt/3.12.7')) 'an unlinked tree is never deleted'
            Assert-True ($r.Output -notmatch 'removed') 'nothing is reported removed'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'removes only the link for a --prefix install with no version directory' {
        $root = New-PlatformSandbox -Version $script:Below
        try {
            $tree = New-ShadowTree -Root (Join-Path $root 'shadow') -Dir 'opt/bin', 'opt/lib' -Link 'python3=opt/bin/python3'
            $null = Invoke-Cleanup -Root $root -Tree $tree
            Assert-False (Test-LinkPresent (Join-Path $tree 'local/bin/python3')) 'the shadow still goes'
            Assert-True (Test-Path -LiteralPath (Join-Path $tree 'opt/bin')) 'a bin directory is not a version directory to delete'
            Assert-True (Test-Path -LiteralPath (Join-Path $tree 'opt/lib')) 'nor is anything beside it'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'does nothing on a host with no standalone tree' {
        $root = New-PlatformSandbox -Version $script:Below
        try {
            $tree = New-ShadowTree -Root (Join-Path $root 'empty')
            $r = Invoke-Cleanup -Root $root -Tree $tree
            Assert-Match 'DONE' $r.Output 'the cleanup returns cleanly'
            Assert-True ($r.Output -notmatch 'removed|ISSUE|WARN') 'nothing is reported when nothing is there'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'local_git_incomplete' {
    BeforeAll {
        # A stand-in for the /usr/local build: --exec-path names a directory
        # that holds git-subtree unless told otherwise, and a Perl-only grep
        # succeeds unless the build is told it has no PCRE2.
        function New-LocalGit {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: writes a stand-in git under a temp sandbox the test removes; not user-facing state.')]
            param([Parameter(Mandatory)][string]$Root, [switch]$NoSubtree, [switch]$NoPcre)
            $dir = Join-Path $Root 'localbin'
            $exec = Join-Path $Root 'localexec'
            New-Item -ItemType Directory -Path $dir, $exec -Force | Out-Null
            if (-not $NoSubtree) {
                Set-Content -LiteralPath (Join-Path $exec 'git-subtree') -Value '#!/bin/sh'
                & chmod +x (Join-Path $exec 'git-subtree')
            }
            # Like the real build, one without PCRE2 still runs a plain -P pattern
            # (git compiles it as a fixed string) and fails only on a Perl-only
            # construct, so a probe weakened to a plain pattern would pass.
            $grep = if ($NoPcre) {
                "if [[ `"`$*`" == *'(?='* ]]; then echo 'fatal: cannot use Perl-compatible regexes when not compiled with USE_LIBPCRE' >&2; exit 128; fi; exit 0"
            } else { 'exit 0' }
            $git = Join-Path $dir 'git'
            Set-Content -LiteralPath $git -Value "#!/bin/bash`nif [[ `"`$1`" == --exec-path ]]; then echo '$exec'; exit 0; fi`n$grep`n"
            & chmod +x $git
            return $git
        }
    }
    It 'accepts a build that has both PCRE2 and git-subtree' {
        $root = New-PlatformSandbox -Version $script:AtFloor
        try {
            $git = New-LocalGit -Root $root
            $r = Invoke-PlatformShell -Root $root -Body "PATH=`"$(Split-Path $git):`$PATH`"; local_git_incomplete '$git' && echo INCOMPLETE || echo COMPLETE"
            Assert-Match 'COMPLETE' $r.Output 'a full build is not rebuilt'
            Assert-True ($r.Output -notmatch 'INCOMPLETE') 'a full build is not reported incomplete'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'flags a build without git-subtree, and one without PCRE2' {
        $root = New-PlatformSandbox -Version $script:AtFloor
        try {
            $git = New-LocalGit -Root (Join-Path $root 'nosub') -NoSubtree
            $r = Invoke-PlatformShell -Root $root -Body "PATH=`"$(Split-Path $git):`$PATH`"; local_git_incomplete '$git' && echo INCOMPLETE"
            Assert-Match 'INCOMPLETE' $r.Output 'a build missing git-subtree is rebuilt'
            $git = New-LocalGit -Root (Join-Path $root 'nopcre') -NoPcre
            $r = Invoke-PlatformShell -Root $root -Body "PATH=`"$(Split-Path $git):`$PATH`"; local_git_incomplete '$git' && echo INCOMPLETE"
            Assert-Match 'INCOMPLETE' $r.Output 'a build that cannot run git grep -P is rebuilt'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'leaves alone a git that is not the build answering on PATH' {
        # The Debian git, or anyone else's, is never rebuilt on this test.
        $root = New-PlatformSandbox -Version $script:AtFloor
        try {
            $git = New-LocalGit -Root $root -NoSubtree -NoPcre
            $r = Invoke-PlatformShell -Root $root -Body "local_git_incomplete '$git' && echo INCOMPLETE || echo NOT-OURS"
            Assert-Match 'NOT-OURS' $r.Output 'only the build that answers the name is judged'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'rebuilds an incomplete build even when it meets the floor' {
        $root = New-PlatformSandbox -Version $script:AtFloor
        try {
            Set-Content -LiteralPath (Join-Path $root 'git.builds') -Value '2.53.0'
            $r = Invoke-PlatformShell -Root $root -Body "local_git_incomplete() { return 0; }`nbring_amd_ryzen_ai_platform_to_floors"
            Assert-Match 'lacks PCRE2 or git-subtree' $r.Output 'the reason for the rebuild is given'
            Assert-Match 'GIT-BUILD ver=2\.53\.0' (Get-SandboxCall -Root $root) 'the build runs at the floor version'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'git rebuild decisions' {
    It 'leaves a newer incomplete /usr/local git alone instead of downgrading it' {
        $versions = $script:AtFloor.Clone(); $versions['git'] = '2.54.1'
        $root = New-PlatformSandbox -Version $versions
        try {
            Set-Content -LiteralPath (Join-Path $root 'git.builds') -Value '2.53.0'
            $r = Invoke-PlatformShell -Root $root -Body "local_git_incomplete() { return 0; }`nbring_amd_ryzen_ai_platform_to_floors"
            Assert-True ((Get-SandboxCall -Root $root) -notmatch 'GIT-BUILD') 'a newer build is never rebuilt at the floor'
            Assert-Match 'WARN\s+/usr/local/bin/git 2\.54\.1 lacks PCRE2 or git-subtree but is newer than the 2\.53\.0 floor' $r.Output `
                'the gap left in place is named'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'builds nothing when the git floor cannot be read' {
        $root = New-PlatformSandbox -Version $script:AtFloor
        try {
            Remove-Item -LiteralPath (Join-Path $root 'automation/Yuruna.Requirement.yml')
            $r = Invoke-PlatformShell -Root $root -Body "local_git_incomplete() { return 0; }`nbring_amd_ryzen_ai_platform_to_floors"
            Assert-True ((Get-SandboxCall -Root $root) -notmatch 'GIT-BUILD') 'no build is attempted without a version to build'
            Assert-True ($r.Output -notmatch 'ISSUE Building git') 'and no failed build is reported'
            Assert-True ($r.Output -notmatch 'newer than') 'nor a comparison against a floor that was never read'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'build_git_from_source' {
    BeforeAll {
        # The real function, with the network, signature check, unpacking and
        # make replaced by recorders, so what it asks for can be read back.
        $script:BuildFunction = Get-YurunaTestShellFunction -Text (Get-Content -LiteralPath (Join-Path $repoRoot 'install/ubuntu.kvm.sh') -Raw) -Name 'build_git_from_source'
        $script:BuildStubs = @'
curl() { local out=''; while (( $# )); do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done; printf 'x' > "$out"; }
gzip() { printf 'tar'; }
gpg() { local out=''; while (( $# )); do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done; : > "$out"; }
gpgv() { echo '[GNUPG:] VALIDSIG E1F036B1FEE7221FC778ECEFB0B5E88696AFE6CB 2026-02-02 0 0 4 0 1 8 00 96E07AF25771955980DAD10020D04E5A713660A7'; }
tar() { local dir=''; while (( $# )); do case "$1" in -C) dir="$2"; shift 2 ;; *) shift ;; esac; done; mkdir -p "$dir/git-2.53.0/contrib/subtree"; }
make() { printf 'MAKE %s\n' "$*" >> "$FAKE_ROOT/calls"; }
'@
    }
    It 'builds with PCRE2 and installs git-subtree beside core git' {
        $root = New-PlatformSandbox -Version $script:Below
        try {
            $work = Join-Path $root 'work'; New-Item -ItemType Directory -Path $work -Force | Out-Null
            $r = Invoke-PlatformShell -Root $root -Body (@($script:BuildFunction, $script:BuildStubs, "build_git_from_source 2.53.0 '$work' trixie-backports && echo BUILT") -join "`n")
            $calls = Get-SandboxCall -Root $root
            Assert-Match 'BUILT' $r.Output 'the build reports success'
            Assert-Match 'SUDO DEBIAN_FRONTEND=noninteractive apt-get install .*-t trixie-backports .*libpcre2-dev' $calls 'the PCRE2 headers are installed'
            Assert-Match 'MAKE -C \S+/git-2\.53\.0 -j\S+ prefix=/usr/local NO_TCLTK=1 USE_LIBPCRE2=YesPlease all' $calls 'core git is built with PCRE2'
            Assert-Match 'SUDO make -C \S+/git-2\.53\.0/contrib/subtree .*install' $calls 'git-subtree is installed'
            Assert-Match 'installed git-subtree beside it' $r.Output 'the subtree install is reported'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'refuses a tarball the pinned key did not sign' {
        $root = New-PlatformSandbox -Version $script:Below
        try {
            $work = Join-Path $root 'work'; New-Item -ItemType Directory -Path $work -Force | Out-Null
            $r = Invoke-PlatformShell -Root $root -Body (@($script:BuildFunction, $script:BuildStubs,
                    "gpgv() { echo '[GNUPG:] VALIDSIG AAAA 2026-02-02 0 0 4 0 1 8 00 1111111111111111111111111111111111111111'; }",
                    "build_git_from_source 2.53.0 '$work' trixie-backports || echo REFUSED") -join "`n")
            Assert-Match 'REFUSED' $r.Output 'the build fails closed'
            Assert-True ((Get-SandboxCall -Root $root) -cnotmatch '(?m)^MAKE ') 'nothing is compiled from an unverified tarball'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'virt-install readiness' {
    It 'makes a virt-install that cannot start a preflight error, not osinfo warnings' {
        $root = New-PlatformSandbox -Version $script:Below
        try {
            Set-Content -LiteralPath (Join-Path $root 'virt.fails') -Value 'yes'
            $r = Invoke-PlatformShell -Root $root -Body @'
PREFLIGHT_ERRORS=(); PREFLIGHT_WARNINGS=()
check_virt_install_ready
printf 'ERROR %s\n' "${PREFLIGHT_ERRORS[@]:-}"; printf 'WARNING %s\n' "${PREFLIGHT_WARNINGS[@]:-}"
'@
            Assert-Match "ERROR 'virt-install' is on PATH but does not run: ModuleNotFoundError: No module named 'gi'" $r.Output 'the cause is named as an error'
            Assert-True ($r.Output -notmatch 'WARNING osinfo') 'no misleading osinfo warning is added'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'checks osinfo variants once virt-install runs' {
        $root = New-PlatformSandbox -Version $script:Below
        try {
            Set-Content -LiteralPath (Join-Path $root 'virt.list') -Value 'linux2022'
            $r = Invoke-PlatformShell -Root $root -Body @'
PREFLIGHT_ERRORS=(); PREFLIGHT_WARNINGS=()
check_virt_install_ready
printf 'ERRORS %s\n' "${#PREFLIGHT_ERRORS[@]}"; printf 'WARNING %s\n' "${PREFLIGHT_WARNINGS[@]:-}"
'@
            Assert-Match 'ERRORS 0' $r.Output 'a working virt-install is not an error'
            Assert-Match "WARNING osinfo-db has neither 'ubuntu24.04' nor 'ubuntu22.04'" $r.Output 'the variant check still runs'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'skips the osinfo refresh when virt-install cannot start' {
        # Missing data would otherwise send the refresh after a database that
        # is not the problem.
        $root = New-PlatformSandbox -Version $script:Below
        try {
            Set-Content -LiteralPath (Join-Path $root 'virt.fails') -Value 'yes'
            $r = Invoke-PlatformShell -Root $root -Body @'
curl() { printf 'CURL %s\n' "$*" >> "$FAKE_ROOT/calls"; return 1; }
ensure_osinfo_db_has_ubuntu24; echo RETURNED
'@
            Assert-Match 'WARN\s+virt-install does not run' $r.Output 'the skip and its reason are said'
            Assert-Match 'RETURNED' $r.Output 'the run continues'
            Assert-True ((Get-SandboxCall -Root $root) -notmatch 'CURL') 'no refresh is fetched'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'report_floor_check' {
    It 'records a check that could not run instead of reporting nothing' {
        $root = New-PlatformSandbox -Version $script:Below
        try {
            $r = Invoke-PlatformShell -Root $root -Body @'
pwsh() { printf 'NO_COLOR=%s\n' "${NO_COLOR:-}"; echo 'ConvertFrom-Content: powershell-yaml is required' >&2; return 1; }
report_floor_check; echo FINISHED
'@
            Assert-Match 'ISSUE The version floors could not be checked: automation/Test-Requirement\.ps1 exited 1' $r.Output 'the failure reaches the closing summary'
            Assert-Match 'powershell-yaml is required' $r.Output 'the check''s own output is shown whole'
            Assert-Match 'NO_COLOR=1' $r.Output 'pwsh runs without color codes'
            Assert-Match 'FINISHED' $r.Output 'the install continues'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'records each shortfall a successful check reports' {
        $root = New-PlatformSandbox -Version $script:Below
        try {
            $r = Invoke-PlatformShell -Root $root -Body @'
pwsh() { printf 'transcript noise\nREQUIREMENT-ISSUE: curl BELOW: found 8.14.1 is older than required 8.18.0.\n'; }
report_floor_check
'@
            Assert-Match '(?m)^ISSUE curl BELOW: found 8\.14\.1 is older than required 8\.18\.0\.$' $r.Output 'the shortfall is recorded without its prefix'
            Assert-True ($r.Output -notmatch 'ISSUE transcript') 'other output is not mistaken for a shortfall'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'floor_check_tools' {
    It 'leaves python3 out of the closing check only on the platform' {
        $root = New-PlatformSandbox -Version $script:Below
        try {
            $platform = Invoke-PlatformShell -Root $root -Body 'floor_check_tools'
            Assert-StringEqual -Expected 'PowerShell,git,qemu-img,wget,tesseract,curl' -Actual $platform.Output.Trim() `
                'a gap no re-run can clear stays out of the summary'
            $ubuntu = Invoke-PlatformShell -Root $root -PrettyName 'Ubuntu 26.04 LTS' -Body 'floor_check_tools'
            Assert-StringEqual -Expected 'PowerShell,git,qemu-img,wget,tesseract,curl,python3' -Actual $ubuntu.Output.Trim() `
                'every other host is still checked for python3'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'osinfo diagnostics under the installer''s strict mode' {
    BeforeAll {
        # The installer runs with errexit, errtrace, nounset and pipefail and an
        # ERR trap that ends the run; the diagnostics must survive all of it.
        $script:Strict = "set -Eeuo pipefail`ntrap 'echo ERR-TRAP-FIRED; exit 99' ERR"
    }
    It 'reports a virt-install that cannot start instead of ending the run' {
        $root = New-PlatformSandbox -Version $script:Below
        try {
            Set-Content -LiteralPath (Join-Path $root 'virt.fails') -Value 'yes'
            $r = Invoke-PlatformShell -Root $root -Body "$script:Strict`nosinfo_db_diag pre; echo SURVIVED"
            Assert-True ($r.Output -notmatch 'ERR-TRAP-FIRED') 'a failing virt-install does not trip the ERR trap'
            Assert-Match 'SURVIVED' $r.Output 'the run continues past the diagnostics'
            Assert-Match "virt-install --osinfo list exited 1: ModuleNotFoundError: No module named 'gi'" $r.Output `
                'the failure and its last line are reported'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'survives a listing with no ubuntu entry, the case it exists to diagnose' {
        $root = New-PlatformSandbox -Version $script:Below
        try {
            Set-Content -LiteralPath (Join-Path $root 'virt.list') -Value "linux2022`nlinux2024"
            $r = Invoke-PlatformShell -Root $root -Body "$script:Strict`nosinfo_db_diag pre; echo SURVIVED"
            Assert-True ($r.Output -notmatch 'ERR-TRAP-FIRED') 'a grep with no match does not trip the ERR trap'
            Assert-Match 'count: 2 lines' $r.Output 'the listing is still measured'
            Assert-Match 'ubuntu\* short-ids visible: <none>' $r.Output 'the absence is reported'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'tells a virt-install that runs from one that cannot' {
        $root = New-PlatformSandbox -Version $script:Below
        try {
            $ok = Invoke-PlatformShell -Root $root -Body "$script:Strict`nvirt_install_runs && echo RUNS"
            Assert-Match 'RUNS' $ok.Output 'a working virt-install passes'
            Set-Content -LiteralPath (Join-Path $root 'virt.fails') -Value 'yes'
            $broken = Invoke-PlatformShell -Root $root -Body "$script:Strict`nif ! why=`"`$(virt_install_runs)`"; then echo `"BROKEN: `$why`"; fi"
            Assert-Match "BROKEN: ModuleNotFoundError: No module named 'gi'" $broken.Output 'the cause is the last line it reported'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
