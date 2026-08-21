<#PSScriptInfo
.VERSION 2026.08.21
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
    'requirement_repair_key', 'requirement_key_command', 'bring_tools_to_required_versions')

# Stubs stand in for everything the promotion reaches outside its own logic.
# sudo runs the command as-is (every path below is inside the temp tree), and
# brew answers for a prefix laid out on disk by the test.
$script:Prelude = @'
set -euo pipefail
log()  { printf 'LOG %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
note_issue() { printf 'ISSUE %s\n' "$*"; }
sudo() { "$@"; }
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
    $file = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-floor-{0}.sh" -f [guid]::NewGuid().ToString('N'))
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

# One temp tree per test: a fake brew prefix, a fake system bin, and the
# directory the promotion links into.
function New-FloorSandbox {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: creates a temp sandbox tree the test removes in its finally block; not user-facing state.')]
    param()
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-floor-{0}" -f [guid]::NewGuid().ToString('N'))
    foreach ($sub in @('brew/bin', 'sysbin', 'local/bin', 'pkg')) {
        New-Item -ItemType Directory -Path (Join-Path $root $sub) -Force | Out-Null
    }
    return $root
}
}

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
        # delete; a timestamped neighbour is a state they can walk back from.
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
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
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

Describe 'bring_tools_to_required_versions' {
    It 'repairs each failing tool once per pass and stops when the check comes back clean' {
        # PowerShell and AES-GCM are two lines about one runtime: repairing that
        # runtime twice in a pass would install the same build twice and report
        # it twice.
        $r = Invoke-InstallerShell -Body @'
# The check runs inside a process substitution, so its side effects land in a
# subshell -- the count of which check this is has to live on disk.
FLOOR_STATE="$(mktemp)"
printf '0\n' > "$FLOOR_STATE"
requirement_issue_line() {
  local n
  n=$(( $(cat "$FLOOR_STATE") + 1 ))
  printf '%s\n' "$n" > "$FLOOR_STATE"
  case $n in
    1) printf '%s\n' \
         "PowerShell BELOW: found 7.3.6 is older than required 7.6.4." \
         "AES-GCM MISSING: this runtime has no AES-GCM, so Lab token enrollment fails" \
         "curl BELOW: found 8.7.1 is older than required 8.21.0." ;;
    2) printf '%s\n' "PowerShell BELOW: found 7.5.0 is older than required 7.6.4." ;;
    *) : ;;
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
requirement_issue_line() { : ; }
run_requirement_repair() { printf 'REPAIR %s\n' "$1"; }
bring_tools_to_required_versions
'@
        Assert-True ($r.Output -notmatch 'REPAIR ') 'a machine at its floors must not be touched'
        Assert-Match 'every managed tool meets its required version' $r.Output
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
requirement_issue_line() { printf '%s\n' "PowerShell BELOW: found 7.5.0 is older than required 7.6.4."; }
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
