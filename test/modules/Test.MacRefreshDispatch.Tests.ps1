<#PSScriptInfo
.VERSION 2026.09.30
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
    Two kinds of evidence, and the test names say which interpreter produced
    each:

      * Lifted cases. The functions under test are lifted out of
        install/macos.utm.sh rather than copied, following the technique
        Test.MacInstallVersionFloor.Tests.ps1 uses for this same file, and run
        under the `bash` found on PATH with `exec` stubbed, so a successful
        dispatch is observable as captured output ("EXEC:..."). On a Mac that
        is usually Homebrew's bash, not the one the installer meets, so the
        no-pwsh refusal and every service-gate case run again under stock
        Bash 3.2 when the host has it.
      * Whole-file cases. The published refresh forms -- `bash -c "<file
        text>" _ --refresh`, the dropped-placeholder variant, and the
        verified-download `bash <file> --refresh` -- run the REAL installer
        file, unmodified, in a private fixture: a stub `uname` that reports
        Darwin, a recording `pwsh`, and a recording stub in front of every
        command the installer body would reach (brew, git, sudo, curl, ...),
        so any fall-through into the install is caught rather than performed.
        They run under every bash this host has: stock /bin/bash when it
        reports 3.2, bash on PATH, and -- where no 3.2 exists -- bash on PATH
        again with BASH_COMPAT=32, which emulates a few 3.2 parser behaviors
        but is not Bash 3.2.

    Two dedicated cases run the published forms, and the lifted cases above,
    under stock Bash 3.2 and are Skipped, never passed, on a host without it:
    macOS ships Bash 3.2 as /bin/bash, and no amount of source reading or
    compat emulation stands in for running it there. A published-form case
    that cannot run on the host is named in the case's own title, next to
    the lifted case that runs in its place.

    Every run goes through Invoke-BoundedNativeCommand with a 30-second cap, so
    a dispatch that hangs fails the case instead of the suite.
#>

BeforeDiscovery {
    # Interpreters are found at discovery so each one gets its own named
    # block: a failure then says which bash produced it.
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    $versionProbe = 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"'
    $readBashVersion = {
        param([string]$Path)
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
        $probe = Invoke-BoundedNativeCommand -FilePath $Path -ArgumentList @('-c', $versionProbe) -TimeoutSeconds 10
        if ($probe.Started -and -not $probe.TimedOut -and $probe.ExitCode -eq 0) { return $probe.StdOut.Trim() }
        return ''
    }
    $pathBash = (Get-Command -Name bash -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    $pathVersion = & $readBashVersion $pathBash
    $stockVersion = & $readBashVersion '/bin/bash'

    # Only the installer's absolute fallback paths escape the fixture PATH.
    # A PowerShell installed elsewhere must not suppress the missing-tool
    # case: the real-file fixture exposes only its own commands.
    $script:HostPwshCandidate = @(@('/opt/homebrew/bin/pwsh', '/usr/local/bin/pwsh',
            '/usr/local/microsoft/powershell/7/pwsh') | Where-Object { Test-Path -LiteralPath $_ })

    $script:Bash32Path = ''
    $interpreters = [System.Collections.Generic.List[hashtable]]::new()
    if ($pathVersion) {
        $interpreters.Add(@{ InterpreterName = "bash $pathVersion on PATH"; InterpreterPath = $pathBash; BashCompat = ''; Unavailable = ''; HostPwshCandidate = $script:HostPwshCandidate })
        if ($pathVersion -eq '3.2') { $script:Bash32Path = $pathBash }
    }
    if ($stockVersion -eq '3.2' -and $pathVersion -ne '3.2') {
        $interpreters.Add(@{ InterpreterName = 'stock /bin/bash 3.2'; InterpreterPath = '/bin/bash'; BashCompat = ''; Unavailable = ''; HostPwshCandidate = $script:HostPwshCandidate })
        $script:Bash32Path = '/bin/bash'
    }
    # Keep the compatibility matrix discoverable even on stock Bash 3.2,
    # which predates BASH_COMPAT. Its unavailable cases are explicit skips;
    # the native 3.2 matrix and stock checks provide the macOS evidence.
    if ($pathVersion) {
        $unavailable = if ([version]$pathVersion -lt [version]'4.3') { "Bash $pathVersion predates BASH_COMPAT (requires Bash 4.3+); stock Bash 3.2 is exercised separately" } else { '' }
        $interpreters.Add(@{ InterpreterName = "bash $pathVersion on PATH with BASH_COMPAT=32"; InterpreterPath = $pathBash; BashCompat = '32'; Unavailable = $unavailable; HostPwshCandidate = $script:HostPwshCandidate })
    }

    # One row per service-gate case, run under bash on PATH and again under
    # stock Bash 3.2. Calls maps a wildcard over the recorded utmctl calls
    # ("path status <vm>", "bundle status <vm>") to how many must match.
    $gateDefault = @{ PathStatus = 'none'; BundleStatus = 'none'; UtmRunning = $true; TmpDir = 'private'; Rc = 0; Reason = @(); Calls = @{}; MaxSeconds = 0; Because = '' }
    $newGateCase = {
        param([hashtable]$Override)
        $row = $gateDefault.Clone()
        foreach ($k in $Override.Keys) { $row[$k] = $Override[$k] }
        $row
    }
    $script:ServiceGateCases = @(
        & $newGateCase @{ CaseName = 'answers "not running" without asking utmctl when no UTM process exists'; PathStatus = 'started'; BundleStatus = 'started'; UtmRunning = $false
            Rc = 1; Calls = @{ '*' = 0 }; Because = 'no VM executes without UTM, so Apple Events are never involved' }
        & $newGateCase @{ CaseName = 'asks the utmctl on PATH and lets UTM be quit when every service VM is stopped'; PathStatus = 'stopped'; BundleStatus = 'started'
            Rc = 1; Calls = @{ 'path status *' = 4; 'bundle *' = 0 }; Because = 'a positive stopped answer for each of the four service VMs, from the PATH copy, is the only way to quit UTM' }
        & $newGateCase @{ CaseName = 'falls back to the bundle utmctl when none is on PATH'; BundleStatus = 'stopped'
            Rc = 1; Calls = @{ 'bundle status *' = 4 }; Because = 'the bundle copy answered stopped for every service VM' }
        & $newGateCase @{ CaseName = 'preserves when the bundle utmctl reports a running service VM'; BundleStatus = 'suspended'
            Reason = @("utmctl reports .* 'suspended'"); Because = 'a suspended service VM is a reason not to quit UTM' }
        & $newGateCase @{ CaseName = 'preserves when UTM runs and no utmctl exists anywhere'
            Reason = @('no utmctl was found', 'preserving out of caution'); Calls = @{ '*' = 0 }; Because = 'an unreadable state preserves' }
        & $newGateCase @{ CaseName = 'treats a directory at the bundle path as no utmctl'; BundleStatus = 'directory'
            Reason = @('no utmctl was found'); Because = 'a directory cannot answer' }
        & $newGateCase @{ CaseName = 'preserves on an empty status answer'; PathStatus = 'empty'
            Reason = @('returned no output'); Calls = @{ '*' = 1 }; Because = 'no output names no state, and the first unreadable answer decides' }
        & $newGateCase @{ CaseName = 'preserves on an Apple Events denial'; PathStatus = 'denied'
            Reason = @('Apple Events denied'); Because = 'a denied call read nothing' }
        & $newGateCase @{ CaseName = 'preserves on an unrecognized answer'; PathStatus = 'garbled'
            Reason = @('unrecognized result'); Because = 'text nobody classified cannot stand for stopped' }
        & $newGateCase @{ CaseName = 'lets UTM be quit when every service VM is reported not found'; PathStatus = 'not-found'
            Rc = 1; Calls = @{ '*' = 4 }; Because = 'a VM that does not exist is not running' }
        & $newGateCase @{ CaseName = 'stops a utmctl call that never answers at its cap and preserves'; PathStatus = 'hang'
            Reason = @('did not answer within 1s', 'preserving out of caution'); Calls = @{ '*' = 1 }; MaxSeconds = 15
            Because = 'a call held by an unanswered consent dialog has read nothing, and the gate may not wait for it' }
        & $newGateCase @{ CaseName = 'bounds the bundle utmctl call the same way'; BundleStatus = 'hang'
            Reason = @('did not answer within 1s'); Calls = @{ 'bundle status *' = 1 }; MaxSeconds = 15
            Because = 'the fallback copy is asked over the same Apple Events' }
        & $newGateCase @{ CaseName = 'preserves when the bounded call cannot be started'; PathStatus = 'stopped'; TmpDir = 'missing'
            Reason = @('could not be started', 'preserving out of caution'); Calls = @{ '*' = 0 }; Because = 'a call that never ran read nothing' }
    )

    # One row per published-form case. Every row carries every key, so no
    # case reads a variable another row happened to define.
    $caseDefault = @{
        Form = 'bash-c'; Arguments = @('_', '--refresh'); RefreshEnv = '1'; Checkout = 'ok'
        Pwsh = 'recording'; ExecFail = $false; Expect = 'refuse'; Message = ''
    }
    $newCase = {
        param([hashtable]$Override)
        $row = $caseDefault.Clone()
        foreach ($k in $Override.Keys) { $row[$k] = $Override[$k] }
        $row
    }
    $script:RefreshCases = @(
        & $newCase @{ CaseName = 'bash -c with the _ placeholder and both signals execs the entry script'; Expect = 'exec' }
        & $newCase @{ CaseName = 'bash -c with the placeholder dropped (token in $0) execs the entry script'; Arguments = @('--refresh'); Expect = 'exec' }
        & $newCase @{ CaseName = 'the verified-download file form execs the entry script'; Form = 'file'; Arguments = @('--refresh'); Expect = 'exec' }
        & $newCase @{ CaseName = 'the token in both $0 and argv execs the entry script'; Arguments = @('--refresh', '--refresh'); Expect = 'exec' }
        & $newCase @{ CaseName = 'YURUNA_REFRESH=1 without the token refuses'; Arguments = @('_'); Message = 'without the --refresh argument' }
        & $newCase @{ CaseName = 'the token without YURUNA_REFRESH=1 refuses'; RefreshEnv = ''; Message = 'without YURUNA_REFRESH=1' }
        & $newCase @{ CaseName = 'an unsupported extra argument refuses'; Arguments = @('_', '--refresh', '--pin-version'); Message = 'accepts no other arguments' }
        & $newCase @{ CaseName = 'a missing checkout refuses'; Checkout = 'missing'; Message = 'not an existing Yuruna checkout' }
        & $newCase @{ CaseName = 'a checkout without the protocol declaration refuses'; Checkout = 'no-version'; Message = 'protocol declaration not found' }
        & $newCase @{ CaseName = 'a checkout declaring another protocol version refuses'; Checkout = 'wrong-version'; Message = "does not match this installer's" }
        & $newCase @{ CaseName = 'a checkout without the entry script refuses'; Checkout = 'no-entry'; Message = 'entry script not found' }
        & $newCase @{ CaseName = 'no resolvable pwsh refuses'; Pwsh = 'none'; Message = 'pwsh not found' }
        & $newCase @{ CaseName = 'a pwsh that cannot be executed ends the run without falling through'; Pwsh = 'bad'; Expect = 'exec-failed' }
        # Under the file's own `set -e` the failed exec ends the shell with its
        # status before the die after it runs; that die is covered by the
        # lifted case where exec returns. What must hold here is no fall-through.
        & $newCase @{ CaseName = 'a failed exec under execfail still ends the run without falling through'; Pwsh = 'bad'; ExecFail = $true; Expect = 'exec-failed' }
    )
    $script:Interpreters = $interpreters.ToArray()
}

BeforeAll {
$here      = Split-Path -Parent $PSCommandPath
$repoRoot  = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$installer = Join-Path $repoRoot 'install/macos.utm.sh'

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $repoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking

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

# Top-level constants travel with the functions that read them: lifting only
# named function bodies would leave them unset, and `set -u` below turns a
# missed reference into an immediate "unbound variable" failure instead of a
# silently wrong value.
function Get-ShellConstantLine {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string[]]$Pattern)
    foreach ($p in $Pattern) {
        $m = [regex]::Match($Text, "(?m)$p")
        if (-not $m.Success) { throw "Pattern not found in the installer: $p" }
        $m.Value
    }
}

# Every function defined at column 0, with the line it starts on and its text.
# die/log/warn are one-liners; the rest close with a lone '}'.
function Get-ShellFunctionDefinition {
    param([Parameter(Mandatory)][string]$Text)
    $lines = $Text -split "`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $head = [regex]::Match($lines[$i], '^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{')
        if (-not $head.Success) { continue }
        $body = [System.Collections.Generic.List[string]]::new()
        $body.Add($lines[$i])
        if ($lines[$i] -notmatch '\}\s*$') {
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                $body.Add($lines[$j])
                if ($lines[$j] -match '^\}') { break }
            }
        }
        [pscustomobject]@{ Name = $head.Groups[1].Value; Line = $i + 1; Body = ($body -join "`n") }
    }
}

function ConvertTo-PlainText {
    param([AllowNull()][string]$Text)
    if (-not $Text) { return '' }
    $noAnsi = [regex]::Replace($Text, "\x1b\[[0-9;?]*[ -/]*[@-~]", '')
    return [regex]::Replace($noAnsi, "[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", '')
}

$script:LiftedConstants = Get-ShellConstantLine -Text $installerText -Pattern @('^YURUNA_REFRESH_PROTOCOL_VERSION=\S+$', '^PATH_LINK_DIR=.*$')
$script:Lifted = ($script:LiftedConstants -join "`n") + "`n" + (Get-ShellFunctionBody -Text $installerText -Name @(
    'yuruna_pwsh_candidates', 'yuruna_resolve_pwsh', 'yuruna_refresh_dispatch', 'yuruna_require_install_mode'))

$script:ServiceGateLifted = ((Get-ShellConstantLine -Text $installerText -Pattern @(
    '^UTM_APP=.*$', '^UTMCTL_BUNDLE=.*$', '^SERVICE_VM_DETECT_REASON=.*$', '^YURUNA_SERVICE_VM_NAME=\(.*\)$',
    '^UTMCTL_STATUS_TIMEOUT_SECONDS=\d+$')) -join "`n") +
    "`n" + (Get-ShellFunctionBody -Text $installerText -Name @('yuruna_utmctl_status', 'is_service_vm_running'))

# The protocol-version constant embedded in the installer has to match the
# declaration file the entry script ships with: a drift between them would
# make every real refresh invocation refuse.
$script:InstallerProtocolVersion = [regex]::Match($installerText, 'YURUNA_REFRESH_PROTOCOL_VERSION=(\S+)').Groups[1].Value

# die/log/warn stand in for the real ones (identical shape). exec is stubbed so
# a successful dispatch is observable instead of replacing this process, and it
# exits like the real exec never returns -- a stub that returned would run the
# code after the exec, which only a FAILED exec ever reaches.
$script:Prelude = @'
set -uo pipefail
log()  { printf 'LOG %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*" >&2; }
die()  { printf 'DIE %s\n' "$*" >&2; exit 1; }
exec() { printf 'EXEC:%s\n' "$*"; printf 'NONINTERACTIVE:%s\n' "${YURUNA_NONINTERACTIVE-<unset>}"; exit 0; }
'@

# Variables a parent test process may carry that would change what the
# installer does; every run starts from these, then applies its own.
$script:BaseEnvironment = @{
    YURUNA_REFRESH = ''; YURUNA_NONINTERACTIVE = ''; YURUNA_INSTALL_LOG = ''; YURUNA_INSTALL_MODE = ''
    BASH_ENV = ''; ENV = ''; BASH_COMPAT = ''; LC_ALL = 'C'
}

# Runs a bash body with the lifted functions and the stubs in scope, under
# -Bash (bash on PATH unless a specific interpreter is named).
function Invoke-InstallerShell {
    param(
        [Parameter(Mandatory)][string]$Body,
        [hashtable]$Environment = @{},
        [switch]$FakeDarwin,
        [string]$Lifted = $script:Lifted,
        [string]$Bash = 'bash'
    )
    $prelude = $script:Prelude
    if ($FakeDarwin) {
        $prelude = @'
uname() { if [[ "$1" == "-s" ]]; then printf 'Darwin\n'; else printf 'arm64\n'; fi; }
'@ + "`n" + $prelude
    }
    $text = @($prelude, $Lifted, $Body) -join "`n"
    $dir = New-YurunaTestTempDir -Prefix 'yuruna-refresh-lifted'
    try {
        $file = Join-Path $dir 'lifted.sh'
        [IO.File]::WriteAllText($file, $text + "`n")
        $environmentForRun = $script:BaseEnvironment.Clone()
        foreach ($k in $Environment.Keys) { $environmentForRun[$k] = $Environment[$k] }
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-BoundedNativeCommand -FilePath $Bash -ArgumentList @($file) -Environment $environmentForRun -TimeoutSeconds 30
        Assert-True ($r.Started -and -not $r.TimedOut) "the lifted run under $Bash must start and finish inside its cap"
        return @{ Output = (ConvertTo-PlainText ($r.StdOut + "`n" + $r.StdErr)); ExitCode = $r.ExitCode; ElapsedSeconds = $stopwatch.Elapsed.TotalSeconds }
    } finally {
        Remove-YurunaTestTempDir $dir
    }
}

# One temp Yuruna checkout per test: entry script + protocol-version file.
function New-RefreshCheckout {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: creates a temp sandbox tree the test removes; not user-facing state.')]
    param([string]$ProtocolVersion, [switch]$OmitEntry, [switch]$OmitVersionFile)
    $root = New-YurunaTestTempDir -Prefix 'yuruna-refresh-checkout'
    New-Item -ItemType Directory -Path (Join-Path $root 'test/lab') -Force | Out-Null
    if (-not $OmitEntry) {
        [IO.File]::WriteAllText((Join-Path $root 'test/lab/Invoke-HostRefresh.ps1'), "# fixture`n")
    }
    if (-not $OmitVersionFile) {
        [IO.File]::WriteAllText((Join-Path $root 'test/host-refresh.protocol-version'), $ProtocolVersion)
    }
    return $root
}

# A shell script written with LF endings and made executable without a native
# chmod call.
function Write-StubScript {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes an executable stub inside a temp sandbox the test removes.')]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"))
    [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute')
}

# Everything the installer body reaches before its first destructive region,
# and every tool a destructive region runs. In a refresh-shaped run none of
# them may be invoked: a recorded call is a fall-through into the install.
$script:SentinelCommand = @(
    'brew', 'git', 'sudo', 'curl', 'osascript', 'pkill', 'killall', 'open', 'utmctl', 'launchctl', 'id',
    'mkfifo', 'tee', 'mktemp', 'mkdir', 'date', 'sw_vers', 'sysctl', 'xcode-select', 'pgrep', 'lsof',
    'shasum', 'dseditgroup', 'nc', 'ps')

# The no-pwsh refusal, lifted: the candidate list is replaced rather than
# `command` stubbed, because the fixed candidates exist on a real Mac and a
# stubbed PATH lookup alone would still resolve one there. This is the form of
# the case every host can run.
function Invoke-NoPwshLiftedCase {
    param([string]$Bash = 'bash')
    $root = New-RefreshCheckout -ProtocolVersion $script:InstallerProtocolVersion
    try {
        return Invoke-InstallerShell -Bash $Bash -FakeDarwin -Body @'
yuruna_pwsh_candidates() { printf '%s\n' "/nonexistent/one/pwsh" "/nonexistent/two/pwsh"; }
yuruna_refresh_dispatch "installer.sh" --refresh
'@ -Environment @{ YURUNA_REFRESH = '1'; YURUNA_DIR = $root }
    } finally { Remove-YurunaTestTempDir $root }
}

function Confirm-NoPwshRefusal {
    param([Parameter(Mandatory)][hashtable]$Result, [Parameter(Mandatory)][string]$Interpreter)
    Assert-Match 'pwsh not found' $Result.Output "the refusal names the missing pwsh ($Interpreter)"
    Assert-Equal 1 $Result.ExitCode "a refusal exits through die ($Interpreter)"
    Assert-False ($Result.Output -match 'EXEC:') "nothing may be exec'd without a resolved pwsh ($Interpreter)"
}

# One sandbox per service-gate case: a PATH copy of utmctl, a bundle copy at a
# private UTMCTL_BUNDLE, and a pgrep answer. Every utmctl call records which
# copy answered. A hanging copy records its call and then sleeps well past the
# 1-second cap the case sets, so only the bound can end it in time.
function Invoke-ServiceGate {
    param(
        [Parameter(Mandatory)][hashtable]$Case,
        [string]$Bash = 'bash'
    )
    $statusText = @{
        stopped = 'stopped'; started = 'started'; suspended = 'suspended'; empty = ''
        denied = 'Error from event: The operation could not be completed. (OSStatus error -1743.)'
        'not-found' = 'Virtual machine not found'; garbled = 'something nobody expected'
    }
    $newStub = {
        param([string]$Label, [string]$Status)
        $answer = if ($Status -eq 'hang') { 'exec sleep 30' } else { "printf '%s' '" + $statusText[$Status] + "'" }
        "#!/bin/bash`nprintf '$Label %s\n' `"`$*`" >> '$rec'`n$answer`n"
    }
    $root = New-YurunaTestTempDir -Prefix 'yuruna-service-gate'
    try {
        $rec = Join-Path $root 'utmctl.log'
        $pathBin = Join-Path $root 'bin'
        $tmp = Join-Path $root 'tmp'
        New-Item -ItemType Directory -Force -Path $pathBin, $tmp | Out-Null
        if ($Case.PathStatus -ne 'none') {
            Write-StubScript -Path (Join-Path $pathBin 'utmctl') -Text (& $newStub 'path' $Case.PathStatus)
        }
        $bundle = Join-Path $root 'UTM.app/Contents/MacOS/utmctl'
        if ($Case.BundleStatus -eq 'directory') {
            New-Item -ItemType Directory -Force -Path $bundle | Out-Null
        } elseif ($Case.BundleStatus -ne 'none') {
            Write-StubScript -Path $bundle -Text (& $newStub 'bundle' $Case.BundleStatus)
        }
        $running = if ($Case.UtmRunning) { '0' } else { '1' }
        $tmpDir = if ($Case.TmpDir -eq 'missing') { Join-Path $root 'no-such-dir' } else { $tmp }
        $r = Invoke-InstallerShell -Bash $Bash -Lifted $script:ServiceGateLifted -Body @"
UTMCTL_BUNDLE='$bundle'
UTMCTL_STATUS_TIMEOUT_SECONDS=1
YURUNA_DIR='$root/checkout'
pgrep() { return $running; }
is_service_vm_running
echo "RC=`$?"
echo "REASON=`$SERVICE_VM_DETECT_REASON"
"@ -Environment @{ PATH = "${pathBin}:/usr/bin:/bin"; TMPDIR = $tmpDir }
        $calls = if (Test-Path -LiteralPath $rec) { @(Get-Content -LiteralPath $rec) } else { @() }
        return @{
            Rc             = [regex]::Match($r.Output, '(?m)^RC=(\d+)').Groups[1].Value
            Reason         = [regex]::Match($r.Output, '(?m)^REASON=(.*)$').Groups[1].Value
            Calls          = $calls
            Output         = $r.Output
            ElapsedSeconds = $r.ElapsedSeconds
            Leftover       = @(Get-ChildItem -LiteralPath $tmp -Force -ErrorAction SilentlyContinue | ForEach-Object Name)
        }
    } finally {
        Remove-YurunaTestTempDir $root
    }
}

function Confirm-ServiceGateOutcome {
    param([Parameter(Mandatory)][hashtable]$Result, [Parameter(Mandatory)][hashtable]$Case, [Parameter(Mandatory)][string]$Interpreter)
    $where = "$($Case.CaseName) ($Interpreter)"
    Assert-Equal ([string]$Case.Rc) $Result.Rc "$($Case.Because): $where; output: $($Result.Output)"
    foreach ($pattern in @($Case.Reason)) {
        Assert-Match $pattern $Result.Reason "the reason must say why: $where"
    }
    if ($Case.Rc -eq 1) {
        Assert-Equal '' $Result.Reason "a verdict that lets UTM be quit carries no reason: $where"
    }
    foreach ($wildcard in $Case.Calls.Keys) {
        $matched = @($Result.Calls | Where-Object { $_ -like $wildcard })
        Assert-Equal $Case.Calls[$wildcard] $matched.Count ("utmctl calls matching '$wildcard': $where; recorded: " + (@($Result.Calls) -join ' | '))
    }
    if ($Case.MaxSeconds -gt 0) {
        Assert-True ($Result.ElapsedSeconds -lt $Case.MaxSeconds) "the gate must end within $($Case.MaxSeconds)s, not wait for the call: $where; took $([Math]::Round($Result.ElapsedSeconds, 1))s"
    }
    Assert-Equal 0 @($Result.Leftover).Count ("the bounded call leaves no private file behind: $where; found: " + (@($Result.Leftover) -join ', '))
}

# Runs one published refresh form against the REAL installer file.
function Invoke-RealInstallerForm {
    param(
        [Parameter(Mandatory)][hashtable]$Case,
        [Parameter(Mandatory)][string]$InterpreterPath,
        [AllowEmptyString()][string]$BashCompat = ''
    )
    $root = New-YurunaTestTempDir -Prefix 'yuruna-refresh-real'
    $bin = Join-Path $root 'bin'; $rec = Join-Path $root 'rec'; $homeDir = Join-Path $root 'home'; $tmp = Join-Path $root 'tmp'
    New-Item -ItemType Directory -Force -Path $bin, $rec, $homeDir, $tmp | Out-Null

    $checkout = Join-Path $root 'checkout'
    if ($Case.Checkout -ne 'missing') {
        New-Item -ItemType Directory -Force -Path (Join-Path $checkout 'test/lab') | Out-Null
        if ($Case.Checkout -ne 'no-entry') {
            [IO.File]::WriteAllText((Join-Path $checkout 'test/lab/Invoke-HostRefresh.ps1'), "# fixture`n")
        }
        if ($Case.Checkout -ne 'no-version') {
            $declared = if ($Case.Checkout -eq 'wrong-version') { '999' } else { $script:InstallerProtocolVersion }
            [IO.File]::WriteAllText((Join-Path $checkout 'test/host-refresh.protocol-version'), $declared)
        }
    }

    Write-StubScript -Path (Join-Path $bin 'uname') -Text @'
#!/bin/bash
case "${1:-}" in
  -m) printf 'arm64\n' ;;
  *)  printf 'Darwin\n' ;;
esac
'@
    foreach ($name in $script:SentinelCommand) {
        Write-StubScript -Path (Join-Path $bin $name) -Text ("#!/bin/bash`nprintf '%s %s\n' '$name' `"`$*`" >> '$rec/sentinel.log'`nexit 1`n")
    }
    switch ($Case.Pwsh) {
        'recording' {
            Write-StubScript -Path (Join-Path $bin 'pwsh') -Text ("#!/bin/bash`nprintf '%s\n' `"`$@`" > '$rec/pwsh.argv'`nprintf '%s' `"`${YURUNA_NONINTERACTIVE-<unset>}`" > '$rec/pwsh.noninteractive'`nexit 0`n")
        }
        'bad' {
            Write-StubScript -Path (Join-Path $bin 'pwsh') -Text "#!/nonexistent/interpreter`nexit 0`n"
        }
        default { }
    }

    # The dispatch reads its protocol declaration with cat. Keep that real
    # reader reachable without inheriting unrelated tools from /usr/bin.
    $catProbe = Invoke-BoundedNativeCommand -FilePath $InterpreterPath -ArgumentList @('-c', 'type -P cat') -TimeoutSeconds 10
    Assert-True ($catProbe.Started -and -not $catProbe.TimedOut -and $catProbe.ExitCode -eq 0 -and $catProbe.StdOut.Trim()) 'the interpreter must resolve cat for the protocol fixture'
    $catPath = $catProbe.StdOut.Trim().Replace("'", "'\''")
    Write-StubScript -Path (Join-Path $bin 'cat') -Text ("#!/bin/bash`nexec '$catPath' " + '"$@"' + "`n")

    $argv = [System.Collections.Generic.List[string]]::new()
    if ($Case.ExecFail) { $argv.Add('-O'); $argv.Add('execfail') }
    if ($Case.Form -eq 'file') {
        # The verified-download form runs the file from its own temp directory.
        $download = Join-Path $root 'download'
        New-Item -ItemType Directory -Force -Path $download | Out-Null
        $copy = Join-Path $download 'macos.utm.sh'
        [IO.File]::WriteAllText($copy, $script:InstallerText)
        $argv.Add($copy)
    } else {
        $argv.Add('-c'); $argv.Add($script:InstallerText)
    }
    foreach ($a in $Case.Arguments) { $argv.Add([string]$a) }

    $environmentForRun = $script:BaseEnvironment.Clone()
    $environmentForRun['HOME'] = $homeDir
    $environmentForRun['YURUNA_DIR'] = $checkout
    $environmentForRun['PATH'] = $bin
    $environmentForRun['TMPDIR'] = $tmp
    $environmentForRun['YURUNA_REFRESH'] = [string]$Case.RefreshEnv
    $environmentForRun['BASH_COMPAT'] = $BashCompat

    try {
        $r = Invoke-BoundedNativeCommand -FilePath $InterpreterPath -ArgumentList $argv.ToArray() -Environment $environmentForRun -TimeoutSeconds 30
        $argvFile = Join-Path $rec 'pwsh.argv'
        $nonInteractiveFile = Join-Path $rec 'pwsh.noninteractive'
        $sentinelFile = Join-Path $rec 'sentinel.log'
        return @{
            Started          = [bool]$r.Started
            TimedOut         = [bool]$r.TimedOut
            ExitCode         = $r.ExitCode
            Output           = (ConvertTo-PlainText ($r.StdOut + "`n" + $r.StdErr))
            PwshArgv         = if (Test-Path -LiteralPath $argvFile) { @((Get-Content -LiteralPath $argvFile) | Where-Object { $_ -ne '' }) } else { $null }
            PwshNonInteractive = if (Test-Path -LiteralPath $nonInteractiveFile) { [IO.File]::ReadAllText($nonInteractiveFile) } else { $null }
            Sentinel         = if (Test-Path -LiteralPath $sentinelFile) { @(Get-Content -LiteralPath $sentinelFile) } else { @() }
            InstallLog       = @(
                if (Test-Path -LiteralPath (Join-Path $homeDir 'Library')) { 'Library' }
                Get-ChildItem -LiteralPath $tmp -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
            Entry            = (Join-Path $checkout 'test/lab/Invoke-HostRefresh.ps1')
        }
    } finally {
        Remove-YurunaTestTempDir $root
    }
}

# The assertions every published-form case shares, by expected outcome.
function Confirm-RealFormOutcome {
    param([Parameter(Mandatory)][hashtable]$Result, [Parameter(Mandatory)][hashtable]$Case, [string]$Interpreter)
    Assert-True ($Result.Started -and -not $Result.TimedOut) "the installer must start and end inside its cap under $Interpreter"
    Assert-Equal 0 @($Result.Sentinel).Count ("no install-body command may run under $Interpreter; recorded: " + (@($Result.Sentinel) -join ' | '))
    Assert-Equal 0 @($Result.InstallLog).Count ("no install log may be created under $Interpreter; found: " + (@($Result.InstallLog) -join ', '))
    switch ($Case.Expect) {
        'exec' {
            Assert-Equal 0 $Result.ExitCode "the recording pwsh exits 0, so the exec'd run must too ($Interpreter)"
            Assert-NotNull $Result.PwshArgv "the dispatch must exec pwsh ($Interpreter)"
            $expected = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $Result.Entry)
            Assert-Equal ($expected -join ' ') (@($Result.PwshArgv) -join ' ') "the exec vector is fixed ($Interpreter)"
            Assert-Equal '1' $Result.PwshNonInteractive "the entry script must see YURUNA_NONINTERACTIVE=1 ($Interpreter)"
        }
        'exec-failed' {
            # install/README.md documents both endings: the shell's own code
            # when the failed exec ends the shell, 1 when the die after it runs.
            Assert-True ($Result.ExitCode -in @(1, 126, 127)) "a failed exec must end the run with 1, 126 or 127, got $($Result.ExitCode) ($Interpreter)"
            Assert-Null $Result.PwshArgv "the unexecutable pwsh never ran ($Interpreter)"
        }
        default {
            Assert-Equal 1 $Result.ExitCode "a refusal exits through die ($Interpreter)"
            Assert-Match ([regex]::Escape($Case.Message)) $Result.Output "the refusal must name its reason ($Interpreter)"
            Assert-Null $Result.PwshArgv "a refusal must not reach pwsh ($Interpreter)"
        }
    }
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
        $r = Invoke-InstallerShell -Body 'uname() { printf "Linux\n"; }; yuruna_refresh_dispatch "--refresh"' -Environment @{ YURUNA_REFRESH = '1' }
        Assert-Match 'Refresh only supports macOS' $r.Output '$0 placement must reach the platform gate, not fall through to install'
    }

    It 'recognizes the token when it lands in "$@" (the documented form)' {
        $r = Invoke-InstallerShell -Body 'uname() { printf "Linux\n"; }; yuruna_refresh_dispatch "installer.sh" --refresh' -Environment @{ YURUNA_REFRESH = '1' }
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
        if ($IsMacOS) { Set-ItResult -Skipped -Because 'this host is Darwin, so the real uname passes the platform gate'; return }
        $r = Invoke-InstallerShell -Body 'yuruna_refresh_dispatch "installer.sh" --refresh' -Environment @{ YURUNA_REFRESH = '1' }
        Assert-Match 'Refresh only supports macOS' $r.Output 'a well-formed refresh request on a non-Darwin host must still refuse'
        Assert-True ($r.ExitCode -ne 0) ''
    }
}

# Runs POSIX stand-in executables and shell installers that Windows cannot launch.
Describe 'yuruna_refresh_dispatch -- past the platform gate (Darwin stubbed)' -Skip:$IsWindows {
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
        } finally { Remove-YurunaTestTempDir $root }
    }

    It 'refuses on a protocol-version mismatch' {
        $root = New-RefreshCheckout -ProtocolVersion '999'
        try {
            $r = Invoke-InstallerShell -FakeDarwin -Body 'yuruna_refresh_dispatch "installer.sh" --refresh' `
                -Environment @{ YURUNA_REFRESH = '1'; YURUNA_DIR = $root }
            Assert-Match "does not match this installer's" $r.Output ''
            Assert-True ($r.ExitCode -ne 0) ''
        } finally { Remove-YurunaTestTempDir $root }
    }

    It 'refuses when the entry script itself is missing despite a matching protocol version' {
        $root = New-RefreshCheckout -ProtocolVersion $script:InstallerProtocolVersion -OmitEntry
        try {
            $r = Invoke-InstallerShell -FakeDarwin -Body 'yuruna_refresh_dispatch "installer.sh" --refresh' `
                -Environment @{ YURUNA_REFRESH = '1'; YURUNA_DIR = $root }
            Assert-Match 'entry script not found' $r.Output ''
        } finally { Remove-YurunaTestTempDir $root }
    }

    It 'refuses when no pwsh can be resolved anywhere' {
        Confirm-NoPwshRefusal -Result (Invoke-NoPwshLiftedCase) -Interpreter 'bash on PATH'
    }

    It 'execs the resolved pwsh against the entry script on a fully satisfied request' {
        $root = New-RefreshCheckout -ProtocolVersion $script:InstallerProtocolVersion
        $fakePwshDir = Join-Path $root 'fakebin'
        Write-StubScript -Path (Join-Path $fakePwshDir 'pwsh') -Text "#!/bin/bash`necho fake-pwsh`n"
        try {
            $r = Invoke-InstallerShell -FakeDarwin -Body @"
PATH="${fakePwshDir}:`$PATH"
yuruna_refresh_dispatch "installer.sh" --refresh
"@ -Environment @{ YURUNA_REFRESH = '1'; YURUNA_DIR = $root }
            Assert-Match 'EXEC:.*fakebin/pwsh' $r.Output 'must exec the resolved pwsh, not fall through to install'
            Assert-Match 'Invoke-HostRefresh\.ps1' $r.Output 'must pass the real entry script path'
            Assert-Match 'EXEC:\S+ -NoLogo -NoProfile -NonInteractive -File ' $r.Output 'the exec vector carries -NonInteractive'
            Assert-Equal 0 $r.ExitCode ''
        } finally { Remove-YurunaTestTempDir $root }
    }

    It 'exports YURUNA_NONINTERACTIVE=1 to the exec''d entry script even when the caller set another value' {
        $root = New-RefreshCheckout -ProtocolVersion $script:InstallerProtocolVersion
        $fakePwshDir = Join-Path $root 'fakebin'
        Write-StubScript -Path (Join-Path $fakePwshDir 'pwsh') -Text "#!/bin/bash`nexit 0`n"
        try {
            $r = Invoke-InstallerShell -FakeDarwin -Body @"
PATH="${fakePwshDir}:`$PATH"
yuruna_refresh_dispatch "installer.sh" --refresh
"@ -Environment @{ YURUNA_REFRESH = '1'; YURUNA_DIR = $root; YURUNA_NONINTERACTIVE = '0' }
            Assert-Match '(?m)^NONINTERACTIVE:1$' $r.Output 'nobody may be assumed to be at the keyboard of a refresh'
        } finally { Remove-YurunaTestTempDir $root }
    }

    It 'dies instead of returning when exec itself returns' {
        # bash keeps going after a failed exec under `shopt -s execfail`; the
        # line after the exec is what stops that from falling into the install.
        $root = New-RefreshCheckout -ProtocolVersion $script:InstallerProtocolVersion
        $fakePwshDir = Join-Path $root 'fakebin'
        Write-StubScript -Path (Join-Path $fakePwshDir 'pwsh') -Text "#!/bin/bash`nexit 0`n"
        try {
            $r = Invoke-InstallerShell -FakeDarwin -Body @"
exec() { printf 'EXEC-FAILED:%s\n' "`$*"; return 126; }
PATH="${fakePwshDir}:`$PATH"
yuruna_refresh_dispatch "installer.sh" --refresh
echo FELL-THROUGH
"@ -Environment @{ YURUNA_REFRESH = '1'; YURUNA_DIR = $root }
            Assert-Match 'EXEC-FAILED:' $r.Output 'the exec was attempted'
            Assert-Match 'Could not start' $r.Output 'a returning exec must end in die'
            Assert-False ($r.Output -match 'FELL-THROUGH') 'the dispatch must never return after a failed exec'
            Assert-Equal 1 $r.ExitCode ''
        } finally { Remove-YurunaTestTempDir $root }
    }
}

# Runs POSIX stand-in executables and shell installers that Windows cannot launch.
Describe 'pwsh resolution' -Skip:$IsWindows {
    It 'lists the location Microsoft''s PowerShell package installs to' {
        $r = Invoke-InstallerShell -Body 'yuruna_pwsh_candidates' -Environment @{ PATH = '/nonexistent-path-dir' }
        Assert-Match '(?m)^/usr/local/microsoft/powershell/7/pwsh$' $r.Output 'a host whose only pwsh is that package must still resolve one'
        Assert-Match '(?m)^/opt/homebrew/bin/pwsh$' $r.Output 'the Homebrew prefix stays a candidate'
    }

    It 'rejects a directory named pwsh and keeps looking' {
        $root = New-YurunaTestTempDir -Prefix 'yuruna-refresh-pwshdir'
        try {
            $dirCandidate = Join-Path $root 'first/pwsh'
            New-Item -ItemType Directory -Force -Path $dirCandidate | Out-Null
            $fileCandidate = Join-Path $root 'second/pwsh'
            Write-StubScript -Path $fileCandidate -Text "#!/bin/bash`nexit 0`n"
            $r = Invoke-InstallerShell -Body @"
yuruna_pwsh_candidates() { printf '%s\n' '$dirCandidate' '$fileCandidate'; }
yuruna_resolve_pwsh && echo "RESOLVED-OK"
"@
            Assert-Match ('(?m)^' + [regex]::Escape($fileCandidate) + '$') $r.Output 'the regular file after the directory is the resolved pwsh'
            Assert-False ($r.Output -match ('(?m)^' + [regex]::Escape($dirCandidate) + '$')) 'a directory passes -x but can never be exec''d'

            $r2 = Invoke-InstallerShell -Body @"
yuruna_pwsh_candidates() { printf '%s\n' '$dirCandidate'; }
yuruna_resolve_pwsh && echo RESOLVED || echo UNRESOLVED
"@
            Assert-Match 'UNRESOLVED' $r2.Output 'a directory alone resolves nothing'
        } finally { Remove-YurunaTestTempDir $root }
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
        # Structural, not behavioral: confirms the guard call sits in the source
        # ahead of each destructive site -- the Homebrew prefix ownership change,
        # the runner/status-service stop with the UTM quit, the package region,
        # the status backup, the clone/update region and the baseline reset --
        # so a future edit that deletes one of these calls is caught here even
        # though this suite cannot drive the whole installer end to end.
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

Describe 'The dispatch closure is complete before the dispatch runs' {
    BeforeAll {
        $script:Definitions = @(Get-ShellFunctionDefinition -Text $installerText)
        $dispatchCall = [regex]::Match($installerText, '(?m)^yuruna_refresh_dispatch "\$0" "\$@"\s*$')
        Assert-True $dispatchCall.Success 'the dispatch call line exists at column 0'
        $script:DispatchCallLine = ($installerText.Substring(0, $dispatchCall.Index) -split "`n").Count
        $script:PreDispatchCode = (($installerText.Substring(0, $dispatchCall.Index) -split "`n") |
            ForEach-Object { if ($_ -match '^\s*#') { '' } else { $_ } }) -join "`n"
    }

    It 'defines every function the dispatch can reach above the line that calls it' {
        # Bash resolves a function when the call executes, not when it is
        # parsed: a helper defined below the dispatch call is simply "command
        # not found" at refresh time -- and under `set -e` that ends the run in
        # a way no refusal message explains.
        $byName = @{}
        foreach ($d in $script:Definitions) { if (-not $byName.ContainsKey($d.Name)) { $byName[$d.Name] = $d } }
        $closure = [System.Collections.Generic.HashSet[string]]::new()
        $queue = [System.Collections.Generic.Queue[string]]::new()
        $queue.Enqueue('yuruna_refresh_dispatch')
        while ($queue.Count -gt 0) {
            $name = $queue.Dequeue()
            if (-not $closure.Add($name)) { continue }
            # Comments name functions without calling them; only code counts.
            # A '#' after whitespace starts a comment; '${#x}' has none before it.
            $body = (($byName[$name].Body -split "`n") | ForEach-Object {
                    if ($_ -match '^\s*#') { '' } else { $_ -replace '\s#\s.*$', '' }
                }) -join "`n"
            foreach ($other in $byName.Keys) {
                if ($other -ne $name -and [regex]::IsMatch($body, "(?<![A-Za-z0-9_])$([regex]::Escape($other))(?![A-Za-z0-9_])")) {
                    $queue.Enqueue($other)
                }
            }
        }
        foreach ($required in @('die', 'yuruna_resolve_pwsh', 'yuruna_pwsh_candidates')) {
            Assert-True ($closure.Contains($required)) "the closure walk must see the dispatch call $required"
        }
        foreach ($name in $closure) {
            Assert-True ($byName[$name].Line -lt $script:DispatchCallLine) "$name is called by the dispatch but defined at line $($byName[$name].Line), after the dispatch call at line $($script:DispatchCallLine)"
        }
    }

    It 'defines yuruna_require_install_mode next to die(), before the dispatch' {
        $die = $script:Definitions | Where-Object Name -eq 'die' | Select-Object -First 1
        $guard = $script:Definitions | Where-Object Name -eq 'yuruna_require_install_mode' | Select-Object -First 1
        Assert-NotNull $guard 'the guard exists'
        Assert-True ($guard.Line -lt $script:DispatchCallLine) 'the guard must exist before the dispatch runs'
        Assert-True ($guard.Line -gt $die.Line) 'the guard follows die()'
        $lines = $installerText -split "`n"
        # Lines strictly between the two definitions (0-based: die.Line .. guard.Line-2).
        $slice = @(if ($guard.Line - $die.Line -gt 1) { $lines[$die.Line..($guard.Line - 2)] })
        $between = @($slice | Where-Object { $_.Trim() -and $_ -notmatch '^\s*#' })
        Assert-Equal 0 $between.Count ('only comments may separate die() from the guard; found: ' + ($between -join ' | '))
    }

    It 'expands no named array before the dispatch' {
        # An empty named-array expansion under `set -u` is an "unbound
        # variable" abort on Bash 3.2 and a silent empty list on newer bash,
        # so the path every refresh takes carries none at all.
        $hits = [regex]::Matches($script:PreDispatchCode, '\$\{[A-Za-z_][A-Za-z0-9_]*\[[@*]\]')
        Assert-Equal 0 $hits.Count ('named-array expansions before the dispatch: ' + (($hits | ForEach-Object Value) -join ', '))
    }

    It 'sources no file (the published forms carry no sibling library)' {
        $code = (($installerText -split "`n") | ForEach-Object { if ($_ -match '^\s*#') { '' } else { $_ } }) -join "`n"
        $hits = [regex]::Matches($code, '(?m)(^|[;&|{(]\s*|\bthen\s+|\bdo\s+)(source|\.)\s+["$A-Za-z0-9_/~.-]')
        Assert-Equal 0 $hits.Count ('source/. of a file: ' + (($hits | ForEach-Object Value) -join ', '))
    }
}

Describe 'No Bash-4-only construct in the installer' {
    BeforeAll {
        # macOS ships Bash 3.2 as /bin/bash and the one-liner runs under it. Each
        # pattern names a construct that is a syntax error, or silently means
        # something else, before Bash 4.
        $script:Bash4Pattern = [ordered]@{
            'declare/local -A, -n, -l, -u, -g' = '\b(declare|typeset|local)\s+(-[A-Za-z]*\s+)*-[A-Za-z]*[Anlug]'
            'mapfile / readarray'               = '\b(mapfile|readarray)\b'
            'case modification ${x,,} ${x^^}'   = '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?(,,?|\^\^?)'
            'coproc'                            = '\bcoproc\b'
            'append-both redirection &>>'       = '&>>'
            'pipe-both |&'                      = '\|&'
            'case fallthrough ;;&'              = ';;&'
            'case fallthrough ;&'               = '(?<!;);&'
            'EPOCHSECONDS / EPOCHREALTIME'      = '\bEPOCH(SECONDS|REALTIME)\b'
            'BASHPID'                           = '\bBASHPID\b'
            'wait -n'                           = '\bwait\s+-n\b'
            '[[ -v name ]]'                     = '\[\[\s+-v\s'
            '[ -v name ] / test -v'             = '(\[|\btest)\s+-v\s'
            '${x@Q} transformations'            = '\$\{[^}]*@[QEPAaKkUuL]\}'
            'negative array index ${a[-1]}'     = '\$\{[A-Za-z_][A-Za-z0-9_]*\[-[0-9]+\]\}'
            'negative substring length'         = '\$\{[A-Za-z_][A-Za-z0-9_]*:[^}:]*:-[0-9]'
            'stepped brace range {1..9..2}'     = '\{-?[0-9]+\.\.-?[0-9]+\.\.-?[0-9]+\}'
            'Bash 4 shopt options'              = '\bshopt\s+-s\s+(globstar|lastpipe|autocd|dirspell|checkjobs|globasciiranges|direxpand|compat4[0-9]|compat5[0-9])\b'
            'read -N / read -i'                 = '\bread\s+(-[A-Za-z]+\s+)*-[A-Za-z]*[Ni]\b'
            'fd variable {fd}>'                 = '\{[A-Za-z_][A-Za-z0-9_]*\}[<>]'
            "printf '%(fmt)T'"                  = '%\([^)]*\)T'
        }
        # A sample of each construct, so a pattern that silently matches
        # nothing cannot pass the scan below by being broken.
        $script:Bash4Sample = @{
            'declare/local -A, -n, -l, -u, -g' = 'declare -A map=()'
            'mapfile / readarray'               = 'mapfile -t lines < f'
            'case modification ${x,,} ${x^^}'   = 'echo "${name,,}"'
            'coproc'                            = 'coproc cat'
            'append-both redirection &>>'       = 'cmd &>> log'
            'pipe-both |&'                      = 'cmd |& tee log'
            'case fallthrough ;;&'              = 'a) x ;;&'
            'case fallthrough ;&'               = 'a) x ;&'
            'EPOCHSECONDS / EPOCHREALTIME'      = 'now=$EPOCHSECONDS'
            'BASHPID'                           = 'echo $BASHPID'
            'wait -n'                           = 'wait -n'
            '[[ -v name ]]'                     = 'if [[ -v name ]]; then :; fi'
            '[ -v name ] / test -v'             = 'if [ -v name ]; then :; fi'
            '${x@Q} transformations'            = 'echo "${x@Q}"'
            'negative array index ${a[-1]}'     = 'echo "${a[-1]}"'
            'negative substring length'         = 'echo "${x:0:-1}"'
            'stepped brace range {1..9..2}'     = 'for i in {1..9..2}; do :; done'
            'Bash 4 shopt options'              = 'shopt -s globstar'
            'read -N / read -i'                 = 'read -r -N 1 c'
            'fd variable {fd}>'                 = 'exec {fd}>file'
            "printf '%(fmt)T'"                  = "printf '%(%F)T' -1"
        }
    }

    It 'every construct pattern recognizes its own sample' {
        foreach ($name in $script:Bash4Pattern.Keys) {
            Assert-True ([regex]::IsMatch($script:Bash4Sample[$name], $script:Bash4Pattern[$name])) "the '$name' pattern must match its sample"
        }
    }

    It 'the installer code (comments excluded) uses none of them' {
        $code = (($installerText -split "`n") | ForEach-Object { if ($_ -match '^\s*#') { '' } else { $_ } }) -join "`n"
        $found = foreach ($name in $script:Bash4Pattern.Keys) {
            foreach ($m in [regex]::Matches($code, $script:Bash4Pattern[$name])) { "$name -> $($m.Value)" }
        }
        Assert-NoFinding @($found) 'Bash-4-only constructs in install/macos.utm.sh:'
    }
}

# Runs POSIX stand-in executables and shell installers that Windows cannot launch.
Describe 'is_service_vm_running preserves on anything it cannot read' -Skip:$IsWindows {
    It '<CaseName>' -ForEach $script:ServiceGateCases {
        $result = Invoke-ServiceGate -Case $_
        Confirm-ServiceGateOutcome -Result $result -Case $_ -Interpreter 'bash on PATH'
    }
}

# Runs POSIX stand-in executables and shell installers that Windows cannot launch.
Describe 'published refresh forms run the real installer file under <InterpreterName>' -ForEach $script:Interpreters -Skip:$IsWindows {
    It '<CaseName>' -ForEach $script:RefreshCases {
        if ($Unavailable) {
            Set-ItResult -Skipped -Because $Unavailable
            return
        }
        if ($_.Pwsh -eq 'none' -and @($HostPwshCandidate).Count -gt 0) {
            Set-ItResult -Skipped -Because ('a fixed pwsh candidate exists on this host (' + (@($HostPwshCandidate) -join ', ') + '), so no fixture PATH can make pwsh unresolvable')
            return
        }
        $result = Invoke-RealInstallerForm -Case $_ -InterpreterPath $InterpreterPath -BashCompat $BashCompat
        Confirm-RealFormOutcome -Result $result -Case $_ -Interpreter $InterpreterName
    }
}

# Defined only where a Bash 3.2 interpreter exists (a stock macOS host), so
# a host without one reports no row at all rather than a skipped one; the
# release gate requires these rows to pass on a macOS host.
if ($script:Bash32Path) {
    Describe 'Stock Bash 3.2' {
        # The label templates keep the case tables out of the reported test names.
        # A published form that cannot run as the real file on this host is named
        # in the title, so a pass never hides it; the lifted case below runs the
        # same refusal under the same interpreter in its place.
        $bash32Label = if ($script:Bash32Path) { $script:Bash32Path } else { 'not present on this host' }
        $notRunnable = @(if (@($script:HostPwshCandidate).Count -gt 0) { $script:RefreshCases | Where-Object { $_.Pwsh -eq 'none' } | ForEach-Object { $_.CaseName } })
        $realFormLabel = if ($script:Bash32Path -and $notRunnable.Count) { "$bash32Label; run lifted instead, a fixed pwsh exists: $($notRunnable -join ', ')" } else { $bash32Label }

        It 'ran the published forms under stock Bash 3.2 (<Bash32Label>)' -ForEach @(@{ Bash32Label = $realFormLabel; Bash32 = $script:Bash32Path; Cases = $script:RefreshCases; NotRunnable = $notRunnable }) {
            if (-not $Bash32) {
                Set-ItResult -Skipped -Because 'no Bash 3.2 interpreter on this host; the release gate runs this suite on a macOS host'
                return
            }
            $probe = Invoke-BoundedNativeCommand -FilePath $Bash32 -ArgumentList @('-c', 'printf "%s" "$BASH_VERSION"') -TimeoutSeconds 10
            Assert-Match '^3\.2\.' $probe.StdOut.Trim() 'the interpreter under test must really be Bash 3.2'
            $notRun = @($Cases | Where-Object { $_.CaseName -in @($NotRunnable) })
            foreach ($case in $notRun) {
                # Only the no-pwsh refusal has a lifted stand-in; any other case
                # that stopped being runnable would be a silent gap.
                Assert-Equal 'none' $case.Pwsh "only the no-pwsh form may be replaced by its lifted case; '$($case.CaseName)' would go unrun"
            }
            Assert-Equal @($NotRunnable).Count $notRun.Count ('every name in the title is a published form of this suite: ' + (@($NotRunnable) -join ', '))
            $toRun = @($Cases | Where-Object { $_.CaseName -notin @($NotRunnable) })
            foreach ($case in $toRun) {
                $result = Invoke-RealInstallerForm -Case $case -InterpreterPath $Bash32
                Confirm-RealFormOutcome -Result $result -Case $case -Interpreter "Bash $($probe.StdOut.Trim()) ($($case.CaseName))"
            }
        }

        It 'ran the lifted no-pwsh refusal and every service-gate case under stock Bash 3.2 (<Bash32Label>)' -ForEach @(@{ Bash32Label = $bash32Label; Bash32 = $script:Bash32Path; GateCases = $script:ServiceGateCases }) {
            if (-not $Bash32) {
                Set-ItResult -Skipped -Because 'no Bash 3.2 interpreter on this host; the release gate runs this suite on a macOS host'
                return
            }
            $probe = Invoke-BoundedNativeCommand -FilePath $Bash32 -ArgumentList @('-c', 'printf "%s" "$BASH_VERSION"') -TimeoutSeconds 10
            $version = $probe.StdOut.Trim()
            Assert-Match '^3\.2\.' $version 'the interpreter under test must really be Bash 3.2'
            Confirm-NoPwshRefusal -Result (Invoke-NoPwshLiftedCase -Bash $Bash32) -Interpreter "Bash $version"
            Assert-True (@($GateCases).Count -gt 0) 'the service-gate table reached this case'
            foreach ($case in $GateCases) {
                $result = Invoke-ServiceGate -Case $case -Bash $Bash32
                Confirm-ServiceGateOutcome -Result $result -Case $case -Interpreter "Bash $version"
            }
        }
    }
}
