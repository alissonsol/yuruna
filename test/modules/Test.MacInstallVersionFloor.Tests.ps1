<#PSScriptInfo
.VERSION 2026.11.23
.GUID 4207f1a4-6b1e-4c0a-9a05-9b2a1f6c3d77
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test install macos version floor pester
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
    Behavioral Pester guard on the macOS installer's version-floor repair: the
    decision about WHICH copy of a tool a name resolves to, and the promotion
    that makes the newest one win.
.DESCRIPTION
    A floor is judged on what a tool prints when it is invoked by name, so the
    repair turns on two comparisons that are easy to get backwards and
    impossible to observe from the install log:

      * 8.21.0 is newer than 8.7.1. A string compare and a float compare both
        say otherwise, and that exact pair is the curl floor a Mac is measured
        against, since Apple's curl never advances past what shipped with the OS.
      * the newest copy INSTALLED is not the copy that runs. A keg-only formula
        is installed unlinked by design, and a second PowerShell can sit ahead of
        a newer one on PATH -- in both shapes `brew upgrade` succeeds, run after
        run, while the name keeps answering with the old version.

    The bodies under test are lifted out of install/macos.utm.sh rather than
    copied, so a rewrite there is exercised here instead of drifting away from a
    stale duplicate. Everything the promotion touches (PATH, the link directory,
    brew, sudo) is redirected into a temporary tree, so the tests run anywhere
    bash does and never write outside it.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -Command "Invoke-Pester -Path test/modules/Test.MacInstallVersionFloor.Tests.ps1"
#>

BeforeAll {
$here      = Split-Path -Parent $PSCommandPath
$repoRoot  = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$installer = Join-Path $repoRoot 'install/macos.utm.sh'

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
$script:SavedMsys = Save-YurunaTestEnvironment -Name 'MSYS'
if ($IsWindows) {
    # Git Bash otherwise copies the target, so readlink cannot verify the
    # installer promoted the link. Emulated symlinks need no host privilege.
    $env:MSYS = (@($env:MSYS, 'winsymlinks:sys') | Where-Object { $_ }) -join ' '
}

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
    'tool_version', 'version_ge', 'brew_formula_binary', 'prefer_newest_binary',
    'requirement_repair_key', 'requirement_key_command', 'bring_tools_to_required_versions',
    'requirement_issue_check', 'brew_run', 'brew_ensure_formula', 'brew_ensure_cask',
    'brew_upgrade_if_installed', 'brew_unpin_if_pinned', 'repair_powershell',
    'brew_outdated_rows', 'non_brew_pwsh_paths', 'github_latest_pwsh',
    'module_rows_below_pin', 'report_newer_versions')

# The powershell-yaml install runs as one pwsh -Command string; lifted whole so
# the test runs the bytes the installer runs.
$script:YamlBlock = [regex]::Match($installerText,
    "(?ms)YURUNA_MODULE_SHA512=`"\`$POWERSHELL_YAML_SHA512`" pwsh -NoProfile -Command '\n(.*?)\n' \|\| note_issue").Groups[1].Value
if (-not $script:YamlBlock) { throw 'The powershell-yaml install block was not found in the installer.' }

# Stubs stand in for everything the promotion reaches outside its own logic.
# sudo runs the command as-is (every path below is inside the temp tree), after
# the -n every installer call carries, and brew answers for a prefix laid out on
# disk by the test.
$script:Prelude = @'
set -euo pipefail
log()  { printf 'LOG %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
note_issue() { printf 'ISSUE %s\n' "$*"; }
sudo() { if [[ "${1:-}" == -n ]]; then shift; fi; "$@"; }
brew() {
  case "$1 ${2:-}" in
    "--prefix --installed")
      [[ -d "$FAKE_BREW/opt/$3" ]] || return 1
      printf '%s\n' "$FAKE_BREW/opt/$3" ;;
    "--prefix ")   printf '%s\n' "$FAKE_BREW" ;;
    "unlink "*)
      printf 'BREW-UNLINK %s\n' "${2:-}" >> "$FAKE_BREW/brew.calls"
      rm -f "$FAKE_BREW"/bin/* ;;
    *)             return 0 ;;
  esac
}
'@

# A stand-in tool that prints what the real one prints for --version.
function New-FakeTool {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes a throwaway executable inside a temp sandbox that the test removes; not user-facing state.')]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$VersionLine
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath $Path -Value "#!/bin/bash`nprintf '%s\n' '$VersionLine'`n" -NoNewline:$false
    & chmod +x $Path
}

# Runs a bash body with the lifted functions and the stubs in scope.
function Invoke-InstallerShell {
    param([Parameter(Mandatory)][string]$Body, [hashtable]$Environment = @{})
    $script = @($script:Prelude, $script:Lifted, $Body) -join "`n"
    $dir = New-YurunaTestTempDir -Prefix 'yuruna-floor'
    $file = Join-Path $dir 'floor.sh'
    Set-Content -LiteralPath $file -Value $script
    $saved = Save-YurunaTestEnvironment -Name @($Environment.Keys)
    foreach ($k in $Environment.Keys) { [Environment]::SetEnvironmentVariable($k, $Environment[$k]) }
    try {
        $out = & bash $file 2>&1
        return @{ Output = (@($out) -join "`n"); ExitCode = $LASTEXITCODE }
    } finally {
        Restore-YurunaTestEnvironment -Saved $saved
        Remove-YurunaTestTempDir $dir
    }
}

# One temp tree per test: a fake brew prefix, a fake system bin, and the
# directory the promotion links into.
function New-FloorSandbox {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: creates a temp sandbox tree the test removes in its finally block; not user-facing state.')]
    param()
    $root = New-YurunaTestTempDir -Prefix 'yuruna-floor'
    foreach ($sub in @('brew/bin', 'sysbin', 'local/bin', 'pkg')) {
        New-Item -ItemType Directory -Path (Join-Path $root $sub) -Force | Out-Null
    }
    return $root
}
}

AfterAll { Restore-YurunaTestEnvironment -Saved $script:SavedMsys }

Describe 'version_ge' {
    It 'orders release numbers by field, not as text' {
        # The curl pair this installer is measured against: 8.21.0 is newer than
        # 8.7.1, and every compare that treats the string or the decimal as the
        # number says the opposite.
        $r = Invoke-InstallerShell -Body @'
version_ge 8.21.0 8.7.1 && echo NEWER-WINS
version_ge 8.7.1 8.21.0 && echo WRONG-WAY-ROUND
echo DONE
'@
        Assert-Match 'NEWER-WINS' $r.Output 'version_ge must accept 8.21.0 as newer than 8.7.1'
        Assert-True ($r.Output -notmatch 'WRONG-WAY-ROUND') 'version_ge must reject 8.7.1 as newer than 8.21.0'
    }
    It 'accepts an exact match' {
        $r = Invoke-InstallerShell -Body 'version_ge 7.6.4 7.6.4 && echo AT-FLOOR'
        Assert-Match 'AT-FLOOR' $r.Output 'a version equal to the floor meets it'
    }
    It 'treats an unreadable version as not meeting the floor' {
        # An empty answer means the binary could not be run; promoting it would
        # put a tool nothing can execute in front of one that works.
        $r = Invoke-InstallerShell -Body 'version_ge "" 7.6.4 || echo NOT-MET'
        Assert-Match 'NOT-MET' $r.Output 'an unreadable version cannot satisfy a floor'
    }
}

Describe 'tool_version' {
    It 'reads the version each managed tool prints' {
        $root = New-FloorSandbox
        try {
            New-FakeTool -Path "$root/sysbin/curl" -VersionLine 'curl 8.7.1 (x86_64-apple-darwin24.0) libcurl/8.7.1 LibreSSL/3.3.6'
            New-FakeTool -Path "$root/sysbin/pwsh" -VersionLine 'PowerShell 7.3.6'
            $r = Invoke-InstallerShell -Body @"
echo "curl=`$(tool_version '$root/sysbin/curl')"
echo "pwsh=`$(tool_version '$root/sysbin/pwsh')"
"@
            Assert-Match 'curl=8\.7\.1' $r.Output 'curl reports its version in the first line, ahead of the libcurl noise'
            Assert-Match 'pwsh=7\.3\.6' $r.Output 'pwsh --version prints the runtime version'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'answers nothing for a binary that cannot run' {
        $root = New-FloorSandbox
        try {
            Set-Content -LiteralPath "$root/sysbin/broken" -Value "#!/bin/bash`nexit 131`n"
            & chmod +x "$root/sysbin/broken"
            $r = Invoke-InstallerShell -Body @"
echo "got=[`$(tool_version '$root/sysbin/broken' || true)]"
"@
            Assert-Match 'got=\[\]' $r.Output 'a runtime-less pwsh exits 131 and must not be treated as a candidate'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'prefer_newest_binary' {
    It 'puts a keg-only formula in front of the copy the OS ships' {
        # curl is the shape: Homebrew installs it unlinked by design, so the
        # name keeps answering with Apple's version until something links it.
        $root = New-FloorSandbox
        try {
            New-FakeTool -Path "$root/sysbin/curl"          -VersionLine 'curl 8.7.1 (arm64-apple-darwin25.0) libcurl/8.7.1'
            New-FakeTool -Path "$root/brew/opt/curl/bin/curl" -VersionLine 'curl 8.21.0 (arm64-apple-darwin25.0) libcurl/8.21.0'
            $r = Invoke-InstallerShell -Body @"
export FAKE_BREW='$root/brew'
export PATH_LINK_DIR='$root/local/bin'
export PATH='$root/local/bin:$root/sysbin:/usr/bin:/bin'
prefer_newest_binary curl curl
readlink '$root/local/bin/curl'
"@
            Assert-Match ([regex]::Escape("$root/brew/opt/curl/bin/curl")) $r.Output `
                'the keg-only binary must be linked into the directory the whole machine resolves from'
            Assert-Match 'now resolves to 8\.21\.0' $r.Output `
                'linking is only the mechanism -- the name has to answer with the newer curl afterwards'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'unlinks a Homebrew copy that is older than the best one' {
        # A second PowerShell ahead on PATH is the shape that survives every
        # `brew upgrade`: brew's bin comes first for any shell that ran
        # shellenv, so linking the newer copy is not enough on its own.
        $root = New-FloorSandbox
        try {
            New-FakeTool -Path "$root/brew/opt/powershell/bin/pwsh" -VersionLine 'PowerShell 7.3.6'
            New-FakeTool -Path "$root/pkg/pwsh"                     -VersionLine 'PowerShell 7.6.4'
            & ln -sfn "$root/brew/opt/powershell/bin/pwsh" "$root/brew/bin/pwsh"
            $r = Invoke-InstallerShell -Body @"
export FAKE_BREW='$root/brew'
export PATH_LINK_DIR='$root/local/bin'
export PATH='$root/brew/bin:$root/local/bin:$root/sysbin:/usr/bin:/bin'
prefer_newest_binary pwsh powershell '$root/pkg/pwsh'
cat "`$FAKE_BREW/brew.calls"
"@
            Assert-Match 'BREW-UNLINK powershell' $r.Output `
                'an older Homebrew copy ahead of the link directory has to come off PATH, or it keeps winning'
            Assert-Match 'now resolves to 7\.6\.4' $r.Output `
                'the promotion is only real when the name answers with the newest build afterwards'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'leaves a machine alone when the name already resolves to the newest copy' {
        $root = New-FloorSandbox
        try {
            New-FakeTool -Path "$root/sysbin/curl"            -VersionLine 'curl 8.21.0 (arm64-apple-darwin26.0) libcurl/8.21.0'
            New-FakeTool -Path "$root/brew/opt/curl/bin/curl" -VersionLine 'curl 8.21.0 (arm64-apple-darwin26.0) libcurl/8.21.0'
            $r = Invoke-InstallerShell -Body @"
export FAKE_BREW='$root/brew'
export PATH_LINK_DIR='$root/local/bin'
export PATH='$root/local/bin:$root/sysbin:/usr/bin:/bin'
prefer_newest_binary curl curl
[[ -e '$root/local/bin/curl' ]] && echo LINKED || echo NO-LINK
"@
            Assert-Match 'NO-LINK' $r.Output 'a machine already at the newest version must not be relinked'
            Assert-True ($r.Output -notmatch 'BREW-UNLINK') 'nothing may be unlinked when the resolved copy is already the newest'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'keeps a real file that occupies the link path' {
        # Something an operator installed by hand is not this installer's to
        # delete; a timestamped neighbor is a state they can walk back from.
        $root = New-FloorSandbox
        try {
            New-FakeTool -Path "$root/sysbin/curl"            -VersionLine 'curl 8.7.1 (arm64) libcurl/8.7.1'
            New-FakeTool -Path "$root/brew/opt/curl/bin/curl" -VersionLine 'curl 8.21.0 (arm64) libcurl/8.21.0'
            New-FakeTool -Path "$root/local/bin/curl"         -VersionLine 'curl 8.9.0 (hand-built) libcurl/8.9.0'
            $r = Invoke-InstallerShell -Body @"
export FAKE_BREW='$root/brew'
export PATH_LINK_DIR='$root/local/bin'
export PATH='$root/local/bin:$root/sysbin:/usr/bin:/bin'
prefer_newest_binary curl curl
ls '$root/local/bin'
"@
            Assert-Match 'curl\.pre-yuruna\.' $r.Output 'a real binary at the link path has to be kept, not overwritten'
            Assert-Match ([regex]::Escape("$root/brew/opt/curl/bin/curl")) $r.Output 'the newest copy still has to win the name'
            $kept = @(Get-ChildItem -LiteralPath "$root/local/bin" -Filter 'curl.pre-yuruna.*')
            Assert-Equal 1 $kept.Count "the real file is kept beside the link: $($r.Output)"
            Assert-Match ([regex]::Escape("$root/local/bin/curl: $($kept[0].FullName) -> $root/brew/opt/curl/bin/curl")) $r.Output `
                'the previous value names where the replaced file now is, never <none>'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'relinks an older copy in the link directory even when this shell already runs the newest' {
        # Microsoft's .pkg links its pwsh into /usr/local/bin. This shell ran
        # `brew shellenv` and resolves the upgraded formula, while the status
        # service and the runner's children resolve the .pkg's link.
        $root = New-FloorSandbox
        try {
            New-FakeTool -Path "$root/brew/opt/powershell/bin/pwsh" -VersionLine 'PowerShell 7.6.9'
            New-FakeTool -Path "$root/pkg/pwsh"                     -VersionLine 'PowerShell 7.6.6'
            & ln -sfn "$root/brew/opt/powershell/bin/pwsh" "$root/brew/bin/pwsh"
            & ln -sfn "$root/pkg/pwsh" "$root/local/bin/pwsh"
            $r = Invoke-InstallerShell -Body @"
export FAKE_BREW='$root/brew'
export PATH_LINK_DIR='$root/local/bin'
export PATH='$root/brew/bin:$root/local/bin:$root/sysbin:/usr/bin:/bin'
prefer_newest_binary pwsh powershell '$root/pkg/pwsh'
printf 'LINK %s\n' "`$(readlink '$root/local/bin/pwsh')"
[[ -L '$root/local/bin/pwsh' && "`$(readlink '$root/local/bin/pwsh')" -ef '$root/brew/opt/powershell/bin/pwsh' ]] && echo LINK-TARGET-IS-NEWEST
"@
            Assert-Match '(?m)^LINK-TARGET-IS-NEWEST$' $r.Output `
                'the link the whole machine resolves has to name the newest copy, not the .pkg'
            Assert-Match 'answers 7\.6\.6, older than 7\.6\.9' $r.Output 'the log has to say why a shell that already runs the newest copy relinks'
            Assert-Match ([regex]::Escape("$root/local/bin/pwsh: $root/pkg/pwsh -> ")) $r.Output `
                'the replaced link is reported as previous -> new, so the earlier target can be put back'
            Assert-True ($r.Output -notmatch 'BREW-UNLINK') 'the newest copy is Homebrew''s own, so nothing may be unlinked'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'the formula and cask steps' -Skip:$IsWindows {
    It 'upgrades a formula only once it is installed' {
        $r = Invoke-InstallerShell -Body @'
brew_ensure_formula() { printf 'ENSURE %s\n' "$1"; }
brew() { [[ "$1 $2 $3 $4" == "list --formula --versions curl" ]]; }
brew_upgrade_if_installed curl
brew_upgrade_if_installed wget
'@
        Assert-Match 'ENSURE curl' $r.Output 'a formula the floor repair once added has to be upgraded like the others'
        Assert-True ($r.Output -notmatch 'ENSURE wget') 'a formula that is not installed is not installed just for being listed'
    }
    It 'lists the brew curl among the upgrades and no longer asks for a PowerShell cask' {
        Assert-Match '(?m)^brew_upgrade_if_installed curl$' $installerText 'the formula list has to carry the brew curl'
        Assert-True ($installerText -notmatch 'cask powershell') 'Homebrew no longer publishes a PowerShell cask, so nothing may install or upgrade one'
    }
    It 'hands a UTM installed from the DMG to the cask' {
        $root = New-YurunaTestTempDir -Prefix 'yuruna-cask'
        try {
            New-Item -ItemType Directory -Path "$root/UTM.app/Contents" -Force | Out-Null
            $r = Invoke-InstallerShell -Body @"
brew() { printf 'BREW %s\n' "`$*"; [[ "`$1" != list ]]; }
brew_ensure_cask utm '$root/UTM.app'
"@
            Assert-Match 'BREW install --cask --force utm' $r.Output 'a copy outside brew never advances on its own, so the cask has to take it over'
            Assert-Match 'the cask takes it over' $r.Output
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'leaves a UTM from the App Store to the App Store' {
        $root = New-YurunaTestTempDir -Prefix 'yuruna-cask'
        try {
            New-Item -ItemType Directory -Path "$root/UTM.app/Contents/_MASReceipt" -Force | Out-Null
            $r = Invoke-InstallerShell -Body @"
brew() { printf 'BREW %s\n' "`$*"; [[ "`$1" != list ]]; }
brew_ensure_cask utm '$root/UTM.app'
"@
            Assert-True ($r.Output -notmatch 'BREW install') 'an App Store copy is the App Store''s to update'
            Assert-Match 'came from the App Store' $r.Output
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'repairs PowerShell through the formula on every pass, never through a cask' {
        $r = Invoke-InstallerShell -Body @'
brew_unpin_if_pinned() { :; }
brew_ensure_formula() { printf 'ENSURE %s\n' "$1"; }
brew_ensure_cask() { printf 'CASK %s\n' "$1"; }
prefer_newest_binary() { printf 'PROMOTE %s\n' "$*"; }
repair_powershell 1
repair_powershell 2
'@
        Assert-Equal -Expected 2 -Actual @($r.Output -split "`n" | Where-Object { $_ -eq 'ENSURE powershell' }).Count
        Assert-True ($r.Output -notmatch 'CASK') 'the escalation pass may not reach for a cask Homebrew no longer has'
        Assert-Match 'PROMOTE pwsh powershell /usr/local/microsoft/powershell/7/pwsh' $r.Output
    }
}

Describe 'report_newer_versions' -Skip:$IsWindows {
    BeforeAll {
        # Every top-level value the lifted functions read, set the way the
        # installer sets it, since the fixture runs under `set -u`.
        $script:ReportPrelude = @'
REPORT_BREW_FORMULAE="git powershell tesseract qemu wget openssl gh curl"
REPORT_BREW_CASKS="utm"
POWERSHELL_YAML_VERSION="0.4.12"
YURUNA_DIR="$PWD"
brew() {
  case "$1 $2" in
    "list --formula") case "$4" in git|gh|powershell) return 0 ;; *) return 1 ;; esac ;;
    "list --cask")    [[ "$4" == utm ]] ;;
    "outdated --json=v2")
      case "$3" in
        --formula) printf '%s' "${FORMULA_JSON:-}" ;;
        --cask)    printf '%s' "${CASK_JSON:-}" ;;
      esac
      # brew exits 1 whenever a named package is outdated.
      return 1 ;;
    *) return 0 ;;
  esac
}
'@
    }
    It 'lists each tool its source offers newer, with why this run left it' {
        $root = New-FloorSandbox
        try {
            New-FakeTool -Path "$root/local/bin/pwsh" -VersionLine 'PowerShell 6.2.0'
            $r = Invoke-InstallerShell -Body (@($script:ReportPrelude, @"
export PATH_LINK_DIR='$root/local/bin'
export PRESERVE_SERVICE_VM=1
export FORMULA_JSON='{"formulae":[{"name":"gh","installed_versions":["2.102.0"],"current_version":"2.103.3","pinned":true},{"name":"git","installed_versions":["2.55.0"],"current_version":"2.56.0","pinned":false}],"casks":[]}'
export CASK_JSON='{"formulae":[],"casks":[{"name":"utm","installed_versions":["5.0.7"],"current_version":"5.0.8"}]}'
curl() { printf 'https://github.com/PowerShell/PowerShell/releases/tag/v7.0.0'; }
module_rows_below_pin() { printf 'powershell-yaml\t0.4.11\t0.4.12\n'; }
report_newer_versions
echo "RC=`$?"
"@) -join "`n")
            Assert-Match 'LOG Newer versions available' $r.Output
            Assert-Match ([regex]::Escape("LOG   gh: 2.102.0 -> 2.103.3 (Homebrew formula; held by 'brew pin' -- 'brew unpin gh' lets it upgrade)")) $r.Output
            Assert-Match ([regex]::Escape('LOG   git: 2.55.0 -> 2.56.0 (Homebrew formula; brew did not move it in this run)')) $r.Output
            Assert-Match ([regex]::Escape('LOG   utm: 5.0.7 -> 5.0.8 (Homebrew cask; a service VM is running, so UTM cannot quit)')) $r.Output
            Assert-Match ([regex]::Escape("LOG   PowerShell: 6.2.0 -> 7.0.0 (GitHub release; $root/local/bin/pwsh comes from a source this installer does not manage)")) $r.Output
            Assert-Match ([regex]::Escape('LOG   powershell-yaml: 0.4.11 -> 0.4.12 (pinned in the PowerShell Gallery; the install of the pin did not complete)')) $r.Output
            Assert-Match 'RC=0' $r.Output
            Assert-True ($r.Output -notmatch 'ISSUE ') 'the report is advisory and never adds to the closing issues'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'names the unattended deferral as the reason a newer UTM waits, whether or not a service VM runs' {
        # An unattended run holds the UTM cask back on its own account; naming
        # a service VM there sends the operator looking for one that may not
        # exist.
        $r = Invoke-InstallerShell -Body (@($script:ReportPrelude, @'
export PATH_LINK_DIR="$PWD/no-such-link-dir"
export YURUNA_UNATTENDED=1 PRESERVE_SERVICE_VM=1
export FORMULA_JSON='{"formulae":[],"casks":[]}'
export CASK_JSON='{"formulae":[],"casks":[{"name":"utm","installed_versions":["5.0.7"],"current_version":"5.0.8"}]}'
non_brew_pwsh_paths() { :; }
module_rows_below_pin() { :; }
report_newer_versions
'@) -join "`n")
        Assert-Match ([regex]::Escape('LOG   utm: 5.0.7 -> 5.0.8 (Homebrew cask; an unattended run never upgrades UTM; run this installer from a terminal of the desktop session)')) $r.Output
        Assert-True ($r.Output -notmatch 'a service VM is running') 'the unattended reason replaces the service-VM one'
    }
    It 'reads a source that does not answer as unknown, never as current, and still succeeds' {
        $root = New-FloorSandbox
        try {
            New-FakeTool -Path "$root/local/bin/pwsh" -VersionLine 'PowerShell 6.2.0'
            $r = Invoke-InstallerShell -Body (@($script:ReportPrelude, @"
export PATH_LINK_DIR='$root/local/bin'
curl() { return 6; }
module_rows_below_pin() { return 1; }
report_newer_versions
echo "RC=`$?"
"@) -join "`n")
            Assert-Match 'LOG   Homebrew formulae: unknown \(brew outdated did not answer\)' $r.Output
            Assert-Match 'LOG   Homebrew casks: unknown \(brew outdated did not answer\)' $r.Output
            Assert-Match ([regex]::Escape('LOG   PowerShell: 6.2.0 -> unknown (GitHub did not name the newest release)')) $r.Output
            Assert-Match ([regex]::Escape('LOG   PowerShell modules: unknown (pwsh could not list them)')) $r.Output
            Assert-True ($r.Output -notmatch '  none:') 'a source that did not answer may not read as everything current'
            Assert-Match 'RC=0' $r.Output
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'says none in one line when every source answers that nothing is behind' {
        $r = Invoke-InstallerShell -Body (@($script:ReportPrelude, @'
export PATH_LINK_DIR="$PWD/no-such-link-dir"
export FORMULA_JSON='{"formulae":[],"casks":[]}'
export CASK_JSON='{"formulae":[],"casks":[]}'
non_brew_pwsh_paths() { :; }
module_rows_below_pin() { :; }
report_newer_versions
'@) -join "`n")
        Assert-Match 'LOG   none: every tool this installer manages is at the newest version its source offers' $r.Output
    }
    It 'names a module installed below its pin and not one at or above it' {
        $root = New-YurunaTestTempDir -Prefix 'yuruna-pins'
        try {
            # A pin above every real release, so whatever this machine has
            # installed elsewhere reads as below it, and one sandboxed copy
            # above it reads as current.
            New-Item -ItemType Directory -Path "$root/tools", "$root/modules/PSScriptAnalyzer/100.0.0" -Force | Out-Null
            Set-Content -LiteralPath "$root/tools/Install-TestModule.ps1" -Value "    'PSScriptAnalyzer' = @{ Version = '99.0.0'; Sha512 = 'x' }"
            Set-Content -LiteralPath "$root/modules/PSScriptAnalyzer/100.0.0/PSScriptAnalyzer.psd1" -Value "@{ ModuleVersion = '100.0.0' }"
            New-Item -ItemType Directory -Path "$root/modules/powershell-yaml/1.0.0" -Force | Out-Null
            Set-Content -LiteralPath "$root/modules/powershell-yaml/1.0.0/powershell-yaml.psd1" -Value "@{ ModuleVersion = '1.0.0' }"
            $r = Invoke-InstallerShell -Body @"
export PSModulePath='$root/modules'
POWERSHELL_YAML_VERSION='99.0.0'
YURUNA_DIR='$root'
module_rows_below_pin
"@
            Assert-Match "(?m)^powershell-yaml\t[0-9.]+\t99\.0\.0$" $r.Output 'a copy below its pin has to be named with the pin'
            Assert-True ($r.Output -notmatch 'PSScriptAnalyzer') 'a copy above its pin is current'
        } finally { Remove-YurunaTestTempDir $root }
    }
}

Describe 'the utmctl link onto PATH' -Skip:$IsWindows {
    BeforeAll {
        # The region runs whole, as top-level code of the installer, against a
        # bundle and a link directory inside the temp tree.
        $from = $installerText.IndexOf('# --- REGION: UTM verification', [StringComparison]::Ordinal)
        $to = $installerText.IndexOf('# --- REGION: PowerShell modules', [StringComparison]::Ordinal)
        if ($from -lt 0 -or $to -le $from) { throw 'The UTM verification region was not found in the installer.' }
        $script:UtmRegion = $installerText.Substring($from, $to - $from)
        function Invoke-UtmctlLink {
            param([Parameter(Mandatory)][string]$Root, [string]$Stub = '')
            New-FakeTool -Path "$Root/UTM.app/Contents/MacOS/utmctl" -VersionLine 'utmctl bundle'
            Invoke-InstallerShell -Body (@($Stub, @"
UTM_APP='$Root/UTM.app'
UTMCTL_BUNDLE="`$UTM_APP/Contents/MacOS/utmctl"
PATH_LINK_DIR='$Root/local/bin'
YURUNA_INSTALL_LOG=''
export PATH='$Root/local/bin:/usr/bin:/bin'
"@, $script:UtmRegion, "printf 'TARGET %s\n' `"`$(readlink '$Root/local/bin/utmctl' || true)`"", "echo FINISHED") -join "`n")
        }
    }
    It 'reports the link it replaces as previous -> new' {
        $root = New-FloorSandbox
        try {
            New-FakeTool -Path "$root/old/utmctl" -VersionLine 'utmctl old'
            & ln -sfn "$root/old/utmctl" "$root/local/bin/utmctl"
            $r = Invoke-UtmctlLink -Root $root
            Assert-Match ([regex]::Escape("LOG Linking utmctl onto PATH: $root/local/bin/utmctl: $root/old/utmctl -> $root/UTM.app/Contents/MacOS/utmctl")) $r.Output `
                'the earlier target is named with the new one, so it can be put back from the log'
            Assert-Match ([regex]::Escape("TARGET $root/UTM.app/Contents/MacOS/utmctl")) $r.Output 'the link names the bundle afterwards'
            Assert-Match 'FINISHED' $r.Output
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'reports a first link as <none> -> new' {
        $root = New-FloorSandbox
        try {
            $r = Invoke-UtmctlLink -Root $root
            Assert-Match ([regex]::Escape("LOG Linking utmctl onto PATH: $root/local/bin/utmctl: <none> -> $root/UTM.app/Contents/MacOS/utmctl")) $r.Output
            Assert-Match ([regex]::Escape("TARGET $root/UTM.app/Contents/MacOS/utmctl")) $r.Output
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'keeps a real file at the link path and names the kept copy as the previous value' {
        # A copied utmctl, or one an older UTM left, is not this installer's to
        # delete; the timestamped neighbor is a state the operator can walk back to.
        $root = New-FloorSandbox
        try {
            New-FakeTool -Path "$root/local/bin/utmctl" -VersionLine 'utmctl copied by hand'
            $r = Invoke-UtmctlLink -Root $root
            $kept = @(Get-ChildItem -LiteralPath "$root/local/bin" -Filter 'utmctl.pre-yuruna.*')
            Assert-Equal 1 $kept.Count "the real file is kept beside the link: $($r.Output)"
            Assert-Match 'utmctl copied by hand' (Get-Content -LiteralPath $kept[0].FullName -Raw) 'the kept copy holds the original bytes'
            Assert-Match ([regex]::Escape("LOG Linking utmctl onto PATH: $root/local/bin/utmctl: $($kept[0].FullName) -> $root/UTM.app/Contents/MacOS/utmctl")) $r.Output `
                'the previous value names where the replaced file now is, never <none>'
            Assert-Match ([regex]::Escape("TARGET $root/UTM.app/Contents/MacOS/utmctl")) $r.Output
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'leaves a real file in place and links nothing when it cannot be moved aside' {
        $root = New-FloorSandbox
        try {
            New-FakeTool -Path "$root/local/bin/utmctl" -VersionLine 'utmctl copied by hand'
            $stub = 'sudo() { if [[ "${1:-}" == -n ]]; then shift; fi; if [[ "$1" == mv ]]; then return 1; fi; "$@"; }'
            $r = Invoke-UtmctlLink -Root $root -Stub $stub
            Assert-Match 'ISSUE Could not move .*/local/bin/utmctl aside' $r.Output 'the closing summary says why utmctl was not linked'
            Assert-Match 'utmctl copied by hand' (Get-Content -LiteralPath "$root/local/bin/utmctl" -Raw) 'the file is left as it was'
            Assert-Null (Get-Item -LiteralPath "$root/local/bin/utmctl").LinkType 'the path is still the real file, not a link'
            Assert-True ($r.Output -notmatch 'LOG Linking utmctl') 'nothing is linked over a file that could not be kept'
            Assert-Match 'FINISHED' $r.Output 'the install goes on with the utmctl that is there'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'the powershell-yaml install block' -Skip:$IsWindows {
    BeforeAll {
        # A package that stands in for the gallery's, and the pin that names it.
        $script:YamlFixture = New-YurunaTestTempDir -Prefix 'yuruna-yaml-pkg'
        $staging = Join-Path $script:YamlFixture 'staging'
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $staging 'powershell-yaml.psd1') -Value "@{ ModuleVersion = '9.9.9'; RootModule = 'powershell-yaml.psm1' }"
        Set-Content -LiteralPath (Join-Path $staging 'powershell-yaml.psm1') -Value '# fixture'
        $script:YamlPackage = Join-Path $script:YamlFixture 'powershell-yaml.9.9.9.nupkg'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($staging, $script:YamlPackage)
        $script:YamlSha512 = [Convert]::ToBase64String([Security.Cryptography.SHA512]::HashData([IO.File]::ReadAllBytes($script:YamlPackage)))

        function Invoke-YamlBlock {
            param([Parameter(Mandatory)][string]$Root)
            # The download is the one thing faked: it hands over the fixture
            # package and records that it was asked.
            $stub = @'
function Invoke-WebRequest {
    [CmdletBinding()]
    param($Uri, $OutFile, $TimeoutSec)
    Add-Content -LiteralPath $env:YURUNA_TEST_CALLS -Value $Uri
    Copy-Item -LiteralPath $env:YURUNA_TEST_PACKAGE -Destination $OutFile
}
'@
            $scriptPath = Join-Path $Root 'yaml.ps1'
            Set-Content -LiteralPath $scriptPath -Value ($stub + "`n" + $script:YamlBlock)
            $names = @('YURUNA_MODULE_VERSION', 'YURUNA_MODULE_SHA512', 'XDG_DATA_HOME', 'PSModulePath', 'YURUNA_TEST_CALLS', 'YURUNA_TEST_PACKAGE')
            $saved = Save-YurunaTestEnvironment -Name $names
            try {
                $env:YURUNA_MODULE_VERSION = '9.9.9'
                $env:YURUNA_MODULE_SHA512 = $script:YamlSha512
                $env:XDG_DATA_HOME = Join-Path $Root 'data'
                $env:PSModulePath = Join-Path $Root 'data/powershell/Modules'
                $env:YURUNA_TEST_CALLS = Join-Path $Root 'calls.txt'
                $env:YURUNA_TEST_PACKAGE = $script:YamlPackage
                $out = & pwsh -NoProfile -NonInteractive -File $scriptPath 2>&1
                return @{ Output = (@($out) -join "`n"); ExitCode = $LASTEXITCODE }
            } finally { Restore-YurunaTestEnvironment -Saved $saved }
        }
    }
    AfterAll { Remove-YurunaTestTempDir $script:YamlFixture }

    It 'raises an installed copy older than the pin to the pin' {
        $root = New-YurunaTestTempDir -Prefix 'yuruna-yaml'
        try {
            $old = Join-Path $root 'data/powershell/Modules/powershell-yaml/1.0.0'
            New-Item -ItemType Directory -Path $old -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $old 'powershell-yaml.psd1') -Value "@{ ModuleVersion = '1.0.0' }"
            $r = Invoke-YamlBlock -Root $root
            Assert-Equal -Expected 0 -Actual $r.ExitCode $r.Output
            Assert-Match 'replacing powershell-yaml 1\.0\.0 with the pinned 9\.9\.9' $r.Output
            Assert-True (Test-Path -LiteralPath (Join-Path $root 'data/powershell/Modules/powershell-yaml/9.9.9/powershell-yaml.psd1')) `
                'the pinned version has to be unpacked beside the older one, where Import-Module loads the highest'
        } finally { Remove-YurunaTestTempDir $root }
    }
    It 'leaves a copy at the pin alone and downloads nothing' {
        $root = New-YurunaTestTempDir -Prefix 'yuruna-yaml'
        try {
            $current = Join-Path $root 'data/powershell/Modules/powershell-yaml/9.9.9'
            New-Item -ItemType Directory -Path $current -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $current 'powershell-yaml.psd1') -Value "@{ ModuleVersion = '9.9.9' }"
            $r = Invoke-YamlBlock -Root $root
            Assert-Match 'powershell-yaml 9\.9\.9 already installed' $r.Output
            Assert-True (-not (Test-Path -LiteralPath (Join-Path $root 'calls.txt'))) 'a copy at the pin needs no download'
        } finally { Remove-YurunaTestTempDir $root }
    }
}

Describe 'requirement_repair_key' {
    It 'routes AES-GCM to the PowerShell repair' {
        # AES-GCM is a property of the runtime, not a tool of its own: repairing
        # it as anything else would report a missing package that does not exist.
        $r = Invoke-InstallerShell -Body @'
requirement_repair_key "AES-GCM MISSING: this runtime has no AES-GCM, so Lab token enrollment fails"
requirement_repair_key "PowerShell BELOW: found 7.3.6 is older than required 7.6.4."
'@
        Assert-Equal -Expected 'powershell powershell' -Actual (($r.Output -split "`n" | Where-Object { $_ }) -join ' ') `
            'both lines describe the same runtime and repair the same way'
    }
    It 'routes each managed tool to its own repair' {
        $r = Invoke-InstallerShell -Body @'
requirement_repair_key "curl BELOW: found 8.7.1 is older than required 8.21.0."
requirement_repair_key "qemu-img BELOW: found 9.0.0 is older than required 10.2.0."
requirement_repair_key "Docker MISSING: no version detected." || echo UNKNOWN
'@
        $lines = @($r.Output -split "`n" | Where-Object { $_ })
        Assert-Equal -Expected 'curl'     -Actual $lines[0]
        Assert-Equal -Expected 'qemu-img' -Actual $lines[1]
        Assert-Equal -Expected 'UNKNOWN'  -Actual $lines[2] 'a tool this installer does not manage has no repair here'
    }
    It 'names the command each key is judged on' {
        $r = Invoke-InstallerShell -Body @'
requirement_key_command powershell
requirement_key_command curl
'@
        Assert-Equal -Expected 'pwsh curl' -Actual (($r.Output -split "`n" | Where-Object { $_ }) -join ' ') `
            'the PowerShell floor is read from the pwsh binary, which is not what the formula is called'
    }
}

# Runs POSIX stand-in executables and shell installers that Windows cannot launch.
Describe 'bring_tools_to_required_versions' -Skip:$IsWindows {
    It 'repairs each failing tool once per pass and stops when the check comes back clean' {
        # PowerShell and AES-GCM are two lines about one runtime: repairing that
        # runtime twice in a pass would install the same build twice and report
        # it twice.
        $r = Invoke-InstallerShell -Body @'
# The check runs in the installer's own shell, so a counter variable sees
# every call; it answers the way Test-Requirement.ps1 -WarnOnly does.
FLOOR_CALLS=0
requirement_issue_check() {
  FLOOR_CALLS=$(( FLOOR_CALLS + 1 ))
  floor_rc=0
  case $FLOOR_CALLS in
    1) floor_out="$(printf 'REQUIREMENT-ISSUE: %s\n' \
         "PowerShell BELOW: found 7.3.6 is older than required 7.6.4." \
         "AES-GCM MISSING: this runtime has no AES-GCM, so Lab token enrollment fails" \
         "curl BELOW: found 8.7.1 is older than required 8.21.0.")" ;;
    2) floor_out='REQUIREMENT-ISSUE: PowerShell BELOW: found 7.5.0 is older than required 7.6.4.' ;;
    *) floor_out='' ;;
  esac
}
run_requirement_repair() { printf 'REPAIR %s pass=%s\n' "$1" "$2"; }
bring_tools_to_required_versions
'@
        $repairs = @($r.Output -split "`n" | Where-Object { $_ -like 'REPAIR *' })
        Assert-Equal -Expected 'REPAIR powershell pass=1' -Actual $repairs[0]
        Assert-Equal -Expected 'REPAIR curl pass=1'       -Actual $repairs[1] 'every failing tool is repaired, not just the first'
        Assert-Equal -Expected 'REPAIR powershell pass=2' -Actual $repairs[2] 'a tool still short after the first pass gets the escalation pass'
        Assert-Equal -Expected 3 -Actual $repairs.Count 'AES-GCM and PowerShell must collapse into one repair per pass'
        Assert-Match 'every managed tool meets its required version' $r.Output
        Assert-True ($r.Output -notmatch 'ISSUE ') 'a machine the repair passes fixed has nothing left to report'
    }
    It 'repairs nothing when every tool already meets its floor' {
        $r = Invoke-InstallerShell -Body @'
requirement_issue_check() { floor_rc=0; floor_out=''; }
run_requirement_repair() { printf 'REPAIR %s\n' "$1"; }
bring_tools_to_required_versions
'@
        Assert-True ($r.Output -notmatch 'REPAIR ') 'a machine at its floors must not be touched'
        Assert-Match 'every managed tool meets its required version' $r.Output
    }
    It 'reports a check that could not run instead of calling every floor met' {
        # With -WarnOnly the check exits 0 whenever it ran. A non-zero exit with
        # no issue lines -- powershell-yaml missing, typically -- says nothing
        # about the versions, and reading it as "no issues" would skip every
        # repair and report a clean machine.
        $r = Invoke-InstallerShell -Body @'
POWERSHELL_YAML_VERSION=9.9.9
requirement_issue_check() { floor_rc=1; floor_out=$'noise\npowershell-yaml is required to read the requirement list\n'; }
run_requirement_repair() { printf 'REPAIR %s\n' "$1"; }
bring_tools_to_required_versions
echo FINISHED
'@
        Assert-Match 'Install-Module powershell-yaml -RequiredVersion 9\.9\.9 -Scope CurrentUser' $r.Output 'the advice names the installer''s pin'
        Assert-Match 'ISSUE The version floors could not be checked: automation/Test-Requirement\.ps1 exited 1, with its output printed above' $r.Output `
            'the failure reaches the closing summary'
        Assert-Match 'powershell-yaml is required to read the requirement list' $r.Output 'the check''s own output is shown whole'
        Assert-True ($r.Output -notmatch 'every managed tool meets') 'a check that did not run must not report the floors met'
        Assert-True ($r.Output -notmatch 'REPAIR ') 'no repair runs on a result that was never produced'
        Assert-Match 'FINISHED' $r.Output 'the install continues'
    }
    It 'takes its exit status from the check itself, run without color codes' {
        # The status is what tells a check that ran from one that could not; the
        # loop above trusts it, so it has to come from pwsh, not from a pipeline.
        $r = Invoke-InstallerShell -Body @'
YURUNA_DIR=/nonexistent; FLOOR_TOOL_LIST=curl
pwsh() { printf 'NO_COLOR=%s\n' "${NO_COLOR:-}"; echo 'powershell-yaml is required' >&2; return 1; }
requirement_issue_check
echo "RC=$floor_rc"; printf 'OUT=%s\n' "$floor_out"
pwsh() { printf 'REQUIREMENT-ISSUE: curl BELOW: found 8.7.1 is older than required 8.18.0.\n'; }
requirement_issue_check
echo "RC2=$floor_rc"
'@
        Assert-Match 'RC=1' $r.Output 'a check that could not run reports its exit status'
        Assert-Match 'NO_COLOR=1' $r.Output 'pwsh runs without color codes'
        Assert-Match 'powershell-yaml is required' $r.Output 'its error output is kept for the operator'
        Assert-Match 'RC2=0' $r.Output 'a check that ran reports success'
    }
    It 'reports what two passes could not reach, naming the binary that answers' {
        # The floor may be ahead of every build that exists. What the operator
        # needs then is which binary is answering, which the version alone never
        # says -- a floor nothing can reach and a newer copy hidden behind an
        # older one on PATH read identically without it.
        $root = New-FloorSandbox
        try {
            New-FakeTool -Path "$root/sysbin/pwsh" -VersionLine 'PowerShell 7.5.0'
            $r = Invoke-InstallerShell -Body @"
export PATH='$root/sysbin:/usr/bin:/bin'
requirement_issue_check() { floor_rc=0; floor_out='REQUIREMENT-ISSUE: PowerShell BELOW: found 7.5.0 is older than required 7.6.4.'; }
run_requirement_repair() { printf 'REPAIR %s pass=%s\n' "`$1" "`$2"; }
bring_tools_to_required_versions
"@
            $repairs = @($r.Output -split "`n" | Where-Object { $_ -like 'REPAIR *' })
            Assert-Equal -Expected 2 -Actual $repairs.Count 'two passes, then the loop stops instead of retrying a floor it cannot reach'
            Assert-Match "ISSUE PowerShell BELOW" $r.Output 'what the repair could not fix still has to reach the closing summary'
            Assert-Match ([regex]::Escape("'pwsh' resolves to $root/sysbin/pwsh")) $r.Output `
                'the report has to name the binary that answered, not only the version it gave'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'record_dotnet_install_location keeps the operator''s .NET runtime location' -Skip:$IsWindows {
    # The machine-wide location file is operator configuration: Microsoft's SDK
    # package records its own runtime there. A built-in default (Homebrew's
    # runtime) fills only an absent, blank or dead value, and a replacement is
    # reported as previous -> new with the old file kept beside it.
    BeforeAll {
        $script:DotnetLifted = Get-YurunaTestShellFunction -Text $installerText -Name 'record_dotnet_install_location'
        $script:DotnetPrelude = @'
set -euo pipefail
log()  { printf 'LOG %s\n' "$*"; }
note_issue() { printf 'ISSUE %s\n' "$*"; }
sudo() { if [[ "${1:-}" == -n ]]; then shift; fi; "$@"; }
'@
        function Invoke-DotnetLocation {
            param([string]$Root, [string]$Previous)
            New-Item -ItemType Directory -Path (Join-Path $Root 'brew/libexec'), (Join-Path $Root 'etc') -Force | Out-Null
            $file = Join-Path $Root 'etc/dotnet/install_location_arm64'
            if ($null -ne $Previous) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
                [IO.File]::WriteAllText($file, "$Previous`n")
            }
            $body = @($script:DotnetPrelude, $script:DotnetLifted, "record_dotnet_install_location '$file' '$Root/brew/libexec'") -join "`n"
            $run = Invoke-YurunaTestShell -Body $body
            return @{ Run = $run; File = $file; Wanted = "$Root/brew/libexec" }
        }
    }

    It 'keeps a location that names an existing runtime directory, unchanged on disk' {
        $root = Join-Path $TestDrive 'kept'
        $operator = Join-Path $root 'usr/local/share/dotnet'
        New-Item -ItemType Directory -Path $operator -Force | Out-Null
        $r = Invoke-DotnetLocation -Root $root -Previous $operator
        $r.Run.ExitCode | Should -Be 0
        [IO.File]::ReadAllText($r.File) | Should -BeExactly "$operator`n"
        $r.Run.Output | Should -Match ([regex]::Escape("Keeping the .NET runtime location in $($r.File): $operator"))
        @(Get-ChildItem -LiteralPath (Split-Path -Parent $r.File) -Filter '*.yuruna-backup.*') | Should -HaveCount 0
    }

    It 'replaces a location whose directory is gone, reporting previous -> new and keeping a backup' {
        $root = Join-Path $TestDrive 'stale'
        $dead = Join-Path $root 'missing/dotnet'
        $r = Invoke-DotnetLocation -Root $root -Previous $dead
        $r.Run.ExitCode | Should -Be 0
        [IO.File]::ReadAllText($r.File) | Should -BeExactly "$($r.Wanted)`n"
        $r.Run.Output | Should -Match ([regex]::Escape("install_location: $dead -> $($r.Wanted)"))
        $backup = @(Get-ChildItem -LiteralPath (Split-Path -Parent $r.File) -Filter '*.yuruna-backup.*')
        $backup | Should -HaveCount 1
        [IO.File]::ReadAllText($backup[0].FullName) | Should -BeExactly "$dead`n"
    }

    It 'records the location when no file exists' {
        $root = Join-Path $TestDrive 'absent'
        $r = Invoke-DotnetLocation -Root $root -Previous $null
        $r.Run.ExitCode | Should -Be 0
        [IO.File]::ReadAllText($r.File) | Should -BeExactly "$($r.Wanted)`n"
        $r.Run.Output | Should -Match 'Recording the .NET runtime location'
    }
}
