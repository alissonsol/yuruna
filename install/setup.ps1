<#PSScriptInfo
.VERSION 2026.08.05
.GUID 426d4f21-8a35-49be-b7e0-3d18f52a9c6b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna install setup standalone lab
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
    Guided setup: take a machine with the repo on disk to a working Standalone
    host or a working Lab.
.DESCRIPTION
    Runs AFTER the OS bootstrapper (install/ubuntu.kvm.sh, install/macos.utm.sh,
    install/windows.hyper-v.ps1) has installed packages and cloned the repo.
    This script installs nothing and clones nothing: it asks what it cannot
    infer, then orchestrates the scripts that already do each job.

    Two modes:

      Standalone host  one machine that runs tests by itself. Storage defaults
                       to this machine.
      Lab              a beacon that other machines join: shared storage, the
                       caching proxy, the stash and pool-control services, and a
                       'default' pool.

    ORDERING. Storage comes BEFORE the service VMs, in both modes. The stash
    service exits 1 without configured storage, and the caching proxy bakes
    storage into its guest seed at build time -- so a proxy built first is a
    proxy that has to be rebuilt.

    RE-RUNNABLE. Re-running detects what is already true and skips it, so a run
    interrupted halfway is resumed by running it again.

    A service VM that is already healthy is ADOPTED rather than rebuilt, because
    a re-run is usually a repair. Adoption keeps the base image, the seed and the
    configuration baked in at build time, so -Rebuild is what forces the teardown
    that APPLIES a change instead of preserving the very thing the change was
    meant to replace -- and it is also what clears a half-removed VM the last run
    left registered. Budget for it: rebuilding the proxy is roughly 15 minutes.

    LOGGED. Every run writes test/status/log/setup.<yyyy.MM.dd.HH.mm>.log: each
    question, the answer taken and where it came from, each step and its outcome,
    each child script's command line and exit code, and the closing report. A
    setup run is long and mostly unattended in the middle, so by the time anyone
    asks what it did the console is usually gone. The child scripts keep the
    console -- see Invoke-RepoScript for why piping them would make their prompts
    invisible -- and transcribe themselves alongside the run log instead; a child
    that exits non-zero has its tail folded into the log, so a failed step names
    its own reason rather than only its exit code.

    WINDOWS RUNS ELEVATED. Enable-TestAutomation and all three Start-*VM scripts
    independently refuse without Administrator, so the whole run is elevated
    once, up front, rather than failing four steps in. The Stop-*VM scripts need
    it just as much and announce it far less: they remove Hyper-V VMs, so
    unelevated they fail somewhere inside the teardown instead of refusing at
    the top.
.PARAMETER AnswerFile
    YAML answers for an unattended run -- the same code path as the interactive
    one, with no prompts. A guided run writes the answer file it used, so the
    next machine can be set up with it. Schema:

        setup:
          type: standalone          # or: lab
          runTests: true            # configure this machine's host settings
          projectUrl: ''            # '' keeps whatever test.config.yml has;
                                    # omit the key to take the script's default
        storage:
          kind: local               # local | nas | none  ('none' is standalone-only)
          localRoot: '/srv'         # kind: local -- REQUIRED unattended, see below
          networkPath: '//ypool-nas/work/yuruna.pool'
          networkUser: 'yuruna-pool'
          onFailure: stop           # stop | local -- see below
        lab:
          name: workshop

    There is no lab.createDefaultPool key. A lab beacon always ends with a
    'default' pool: the run inspects the pool storage it just configured and
    creates the pool in that intent store when it carries none, leaving an
    existing pool of that name untouched. A lab without a pool is a lab nothing
    can enrol into, so declining it only ever produced a beacon that looked
    finished. The key is warned about and ignored if an older answer file
    still carries it.

    setup.projectUrl is never prompted for. A run with no answer file entry uses
    the $DefaultProjectUrl set at the top of the script, so an operator who does
    not know the project repo still ends with a testable machine. Setting the key
    to '' opts out and keeps whatever test.config.yml already has.

    storage.localRoot is required for an unattended kind: local run (and for an
    unattended NAS run whose onFailure is 'local'). New-LocalLabStorage.ps1 asks
    where the lab's storage should live, and with no answer file entry and nobody
    at the console the run would hang rather than fail -- so setup.ps1 stops with
    this key named instead.

    storage.onFailure governs an unreachable NAS. The default is 'stop': a lab
    quietly becoming beacon-local when the operator asked for a NAS is the kind
    of divergence nobody notices until the beacon is a single point of failure.
    An interactive run offers the choice instead of taking it.
.PARAMETER LogPath
    Continue an existing run log instead of opening a new one. The Windows
    elevated relaunch passes it to itself so one file holds the whole run; there
    is no reason to set it by hand.
.PARAMETER logLevel
    Error | Warning | Information | Verbose | Debug -- how much of the run
    reaches the console. Each level shows itself and every higher-priority one,
    so Debug shows everything. Omitted, the level comes from logLevel: in
    test/test.config.yml, and from 'Information' when that file says nothing
    either.

    It does not stop at this script. The resolved level is published as
    $env:YURUNA_LOG_LEVEL, and every script started from here -- down to the
    per-guest image and VM builders -- reads it from the environment it
    inherits, because PowerShell preference variables do not cross a process
    boundary. So -logLevel Debug makes the WHOLE setup verbose, which is what a
    bring-up that failed somewhere inside a child script needs.

    The run log records what this script emits whatever the level is set to;
    this only decides how much of it also reaches the terminal.
.PARAMETER WhatIf
    Print the ordered task list and stop, changing nothing -- except the run log,
    which a preview writes like any other run. What the preview would do is
    exactly what is worth keeping.
.EXAMPLE
    pwsh install/setup.ps1
.EXAMPLE
    pwsh install/setup.ps1 -WhatIf
.EXAMPLE
    pwsh install/setup.ps1 -AnswerFile lab-answers.yml
.EXAMPLE
    pwsh install/setup.ps1 -logLevel Debug
    Everything this script and every child script it starts can say.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$AnswerFile = '',
    [string]$LogPath = '',
    [ValidateSet('Error', 'Warning', 'Information', 'Verbose', 'Debug', IgnoreCase = $true)]
    [string]$logLevel,
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
# Several preflight probes read a native command's exit code as the ANSWER
# ("is libvirtd running?"), not as a failure. Pinned so an ambient preference
# cannot turn those into terminating errors.
$PSNativeCommandUseErrorActionPreference = $false

# Bound to a script-scoped copy that the helpers read. A re-run is usually a
# repair, so service VMs are adopted when they are already healthy; -Rebuild is
# how an operator forces the teardown that re-bakes changed configuration into a
# guest seed, which adoption by definition does not do.
$Script:Rebuild = [bool]$Rebuild

$RepoRoot = Split-Path -Parent $PSScriptRoot
$TestRoot = Join-Path $RepoRoot 'test'
$ConfigPath = Join-Path $TestRoot 'test.config.yml'

# The project repo a setup run points test.config.yml at. Not asked: every run
# that does not say otherwise should land on the same known-good project, so a
# fresh machine is testable without the operator knowing the URL. Change this
# one line to retarget every future run; an answer file's setup.projectUrl still
# wins per-run, and '' there keeps whatever test.config.yml already has.
$DefaultProjectUrl = 'https://github.com/alissonsol/yuruna-project'

function Import-SetupModule {
<#
.SYNOPSIS
    Import one of the repo's modules with the engine's load narration silenced.
.DESCRIPTION
    At -logLevel Verbose or Debug the engine prints an "Exporting function" line
    per exported name, and a module that imports others prints theirs as well.
    That is several hundred lines across the modules a setup run loads, and it
    buries the output the operator raised the level to see.

    -Verbose:$false on the call cannot suppress the NESTED imports -- those read
    $global:VerbosePreference, not this cmdlet's bound parameters -- so the
    preference itself is dropped for the duration and put back afterwards.
#>
    param([Parameter(Mandatory)][string]$Name)
    $prior = $global:VerbosePreference
    try {
        $global:VerbosePreference = 'SilentlyContinue'
        Import-Module $Name -Force -DisableNameChecking -Verbose:$false
    } finally {
        $global:VerbosePreference = $prior
    }
}

# --- REGION: log level
# The cascade every yuruna entry point shares -- command line beats
# test.config.yml beats 'Information'. See docs/loglevels.md.
#
# Resolved here, before anything is written, for two reasons. The run log's
# header records the level, so a transcript missing what someone expected says
# why. And Resolve-LogLevel publishes $env:YURUNA_LOG_LEVEL, the ONLY channel
# that reaches the child scripts: they run in their own pwsh (see
# Invoke-RepoScript) and preference variables do not survive a process boundary.
# Every one of them calls Use-LogLevelFromEnv, so -logLevel Debug here is
# -logLevel Debug in the storage script, the service-VM starts and the per-guest
# builders those start in turn.
Import-SetupModule (Join-Path $TestRoot 'modules/Test.LogLevel.psm1')
# test.config.yml read line-wise rather than through Test.Config: this runs
# before the preflight that proves powershell-yaml is installed, and on a fresh
# machine before the step that CREATES the file. Anchored at column 0 so it is
# the top-level key, not some section's own logLevel.
$configLogLevel = ''
if (Test-Path -LiteralPath $ConfigPath) {
    foreach ($line in (Get-Content -LiteralPath $ConfigPath)) {
        if ($line -match '^logLevel\s*:\s*([A-Za-z]+)') { $configLogLevel = $Matches[1]; break }
    }
}
$LogLevelSource = if ($logLevel) { 'command line' }
                  elseif ($configLogLevel) { 'test.config.yml' }
                  else { 'default -- not set anywhere' }
$EffectiveLogLevel = Test.LogLevel\Resolve-LogLevel -CmdLineLevel $logLevel -ConfigLevel $configLogLevel
# Resolve-LogLevel writes the $global:* preferences. This script assigns its own
# $InformationPreference above, and a script-scoped assignment shadows the global
# for the whole file -- so without taking the resolved value back, -logLevel
# Error and -logLevel Warning would quiet every child and none of these lines.
$InformationPreference = $global:InformationPreference

# --- REGION: run log
# Every question asked, every answer taken and every message printed also lands
# in test/status/log/setup.<yyyy.MM.dd.HH.mm>.log. A setup run is long, mostly
# unattended in the middle, and the interesting part is usually gone from the
# scrollback by the time anyone looks -- so the record outlives the console.
#
# The repo scripts this one starts write to their own logs, not to this terminal
# (see Invoke-RepoScript), so the console carries none of a child's output. Each
# writes a transcript of its own streams under $Script:ChildLogRoot, and a child
# that exits non-zero has its tail folded into this log. Without that, a failed
# step would be an exit code and nothing else, its reason left in a scrollback
# that is gone by the time anyone asks.
$Script:LogFile     = ''
$Script:ChildLogRoot = ''
$Script:ChildLogSeq  = 0

function Write-SetupLogLine {
<#
.SYNOPSIS
    Append one timestamped record to the run log. A no-op when there is no log.
#>
    param(
        [Parameter(Mandatory)][string]$Level,
        [string]$Message = ''
    )
    if (-not $Script:LogFile) { return }
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $lines = @(foreach ($line in ($Message -split "`r?`n")) { ('{0} {1,-6} {2}' -f $stamp, $Level, $line).TrimEnd() })
    try {
        # -WhatIf:$false twice over: Add-Content supports ShouldProcess, and a
        # preview run still keeps a log -- without it the preview would narrate
        # "What if: Add Content" for every line and record none of them.
        Add-Content -LiteralPath $Script:LogFile -Value $lines -Encoding utf8 -WhatIf:$false
    } catch {
        # The log is a record of the run, never a reason to end one. Say so once,
        # then continue console-only rather than failing on every later line.
        $Script:LogFile = ''
        Write-Warning "Setup log could not be written ($($_.Exception.Message)); the rest of this run is console-only."
    }
}

function Write-SetupMessage {
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Message = '')
    Write-Information $Message
    Write-SetupLogLine -Level 'INFO' -Message $Message
}

function Write-SetupWarning {
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Message = '')
    Write-Warning $Message
    Write-SetupLogLine -Level 'WARN' -Message $Message
}

function Write-SetupVerbose {
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Message = '')
    Write-Verbose $Message
    Write-SetupLogLine -Level 'NOTE' -Message $Message
}

function Write-SetupDetail {
<#
.SYNOPSIS
    Record something in the run log without putting it on the operator's screen.
.DESCRIPTION
    The console carries one line per step and nothing else, so that a twenty-
    minute run reads as a list of outcomes rather than a wall of narration. That
    detail still has to exist somewhere, and the log is where -- a failure is
    diagnosed from the log, not from a scrollback that is long gone by the time
    anyone asks.

    At -logLevel Verbose or Debug the same text also reaches the screen, because
    an operator who raised the level is asking for exactly this.
#>
    param([Parameter(Position = 0)][AllowEmptyString()][string]$Message = '', [string]$Level = 'INFO')
    Write-Verbose $Message
    Write-SetupLogLine -Level $Level -Message $Message
}

function Write-SetupError {
<#
.SYNOPSIS
    Report a fatal condition to the console and the log. Does not itself end the
    run -- every call site follows it with Exit-Setup.
.DESCRIPTION
    -ErrorAction Continue, deliberately. $ErrorActionPreference is 'Stop' here,
    which makes a plain Write-Error terminating: the closing report and the exit
    code that follow it would never run, and the log would end on the failure
    with no record of what the run had managed first.
#>
    param([Parameter(Position = 0, Mandatory)][string]$Message)
    Write-SetupLogLine -Level 'FAIL' -Message $Message
    Write-Error $Message -ErrorAction Continue
}

function Initialize-SetupLog {
<#
.SYNOPSIS
    Open the run log and write its header. Appends when the file already exists.
.PARAMETER Path
    An existing log to continue writing to. This is how the Windows elevated
    relaunch keeps ONE file for the whole run: the unelevated parent opens the
    log, then hands the path down. Empty means "start a new one".
.DESCRIPTION
    Minute precision in the generated name, matching the timestamps elsewhere
    under status/log. Two runs started inside the same minute share a file and
    each writes its own header, which reads better than two half-records under
    names that differ by a second.
#>
    param([string]$Path = '')
    $target = $Path
    if (-not $target) {
        $target = Join-Path (Join-Path $TestRoot 'status/log') ('setup.{0}.log' -f (Get-Date).ToString('yyyy.MM.dd.HH.mm'))
    }
    try {
        $parent = Split-Path -Parent $target
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent -WhatIf:$false | Out-Null
        }
        $elevated = ''
        if ($IsWindows) {
            $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
            $elevated = if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { ' (elevated)' } else { ' (not elevated)' }
        }
        $header = @(
            ''
            '=================== yuruna setup run ==================='
            ('started     : {0}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss K'))
            ('script      : {0}' -f $PSCommandPath)
            ('repo        : {0}' -f $RepoRoot)
            ('answer file : {0}' -f $(if ($AnswerFile) { $AnswerFile } else { '(none -- interactive run)' }))
            ('log level   : {0} ({1})' -f $EffectiveLogLevel, $LogLevelSource)
            ('user        : {0}{1}' -f [Environment]::UserName, $elevated)
            ('machine     : {0}' -f [Environment]::MachineName)
            ('pwsh        : {0} on {1}' -f $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString)
            $(if ($WhatIfPreference) { 'mode        : -WhatIf preview -- nothing will be changed' })
            '========================================================'
        ) | Where-Object { $null -ne $_ }
        Add-Content -LiteralPath $target -Value $header -Encoding utf8 -WhatIf:$false
        $Script:LogFile = $target
        # Child transcripts sit beside the run log under a name derived from it,
        # so a run's own output and the output of everything it started are found
        # together and age out together.
        $Script:ChildLogRoot = Join-Path (Split-Path -Parent $target) `
            (((Split-Path -Leaf $target) -replace '\.log$', '') + '.children')
    } catch {
        $Script:LogFile = ''
        Write-Warning "Setup log could not be opened at $target ($($_.Exception.Message)); this run is console-only."
    }
}

function Get-ChildTranscriptDirectory {
<#
.SYNOPSIS
    A fresh directory for one child invocation's transcripts. '' when this run
    has no log to hang it off, or when the directory cannot be created.
.DESCRIPTION
    Per invocation, not per script: the service VMs are stopped and started
    several times in a run, and a shared directory would leave the reader
    guessing which attempt a transcript came from. The sequence prefix keeps
    them in run order for anyone reading the folder directly.
#>
    param([Parameter(Mandatory)][string]$Leaf)
    if (-not $Script:ChildLogRoot) { return '' }
    $Script:ChildLogSeq++
    $safe = ($Leaf -replace '\.ps1$', '') -replace '[^A-Za-z0-9._-]', '_'
    $dir = Join-Path $Script:ChildLogRoot ('{0:d2}-{1}' -f $Script:ChildLogSeq, $safe)
    try {
        New-Item -ItemType Directory -Force -Path $dir -WhatIf:$false | Out-Null
        return $dir
    } catch {
        Write-SetupVerbose "child transcript directory could not be created at ${dir}: $($_.Exception.Message)"
        return ''
    }
}

function Write-ChildOutputToLog {
<#
.SYNOPSIS
    Fold everything a child wrote into the run log. Log only -- never the console.
.DESCRIPTION
    Runs on every child, not only on failures: the console carries none of a
    child's output, so this log is the only record of it -- and outliving the
    terminal is the whole reason the log exists.

    Nothing here reaches the console: a step is one line, and a successful
    fifteen-minute VM build has several hundred lines of narration that belong in
    a file, not in front of someone waiting for the next step.
#>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Directory,
        [Parameter(Mandatory)][string]$Leaf
    )
    if (-not $Directory -or -not (Test-Path -LiteralPath $Directory)) { return }
    $files = @(Get-ChildItem -LiteralPath $Directory -Filter '*.log' -File -ErrorAction SilentlyContinue |
               Sort-Object CreationTimeUtc, Name)
    $banner = '^\*{5,}$|^PowerShell transcript (start|end)$|^(Start|End) time: \d+$'
    foreach ($file in $files) {
        $lines = @(Get-Content -LiteralPath $file.FullName -ErrorAction SilentlyContinue |
                   Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch $banner })
        if ($lines.Count -eq 0) { continue }
        Write-SetupLogLine -Level 'CHILD' -Message "----- $Leaf : $($file.Name) ($($lines.Count) line(s)) -----"
        foreach ($line in $lines) { Write-SetupLogLine -Level 'CHILD' -Message "  $line" }
    }
}

function Exit-Setup {
<#
.SYNOPSIS
    End the run, recording the exit code as the log's last line.
.DESCRIPTION
    Every exit goes through here. A log whose final line is whatever happened to
    print last cannot be told apart from a log cut short by a kill or a reboot.
#>
    param([int]$Code = 0)
    # Before the exit line, so an interrupted-looking log still shows the helper
    # was cleaned up. A refresher left running would keep a root authorization
    # alive for as long as this shell does, which is not something to leave
    # behind on an operator's machine.
    Stop-SudoKeepAlive
    Write-SetupLogLine -Level 'END' -Message "setup.ps1 exiting $Code"
    exit $Code
}

function Add-SetupDecision {
<#
.SYNOPSIS
    Record one resolved answer and where it came from.
.DESCRIPTION
    The source matters as much as the value. "storage.kind = local" says what the
    run did; "(answer file)" versus "(default -- not asked)" says whether anyone
    chose it, which is the question asked of a log after a machine turns out to
    be set up differently than expected.
#>
    param(
        [Parameter(Mandatory)][string]$Name,
        $Value,
        [Parameter(Mandatory)][string]$Source
    )
    $text = if ($Value -is [bool]) { $Value.ToString().ToLowerInvariant() }
            elseif ($null -eq $Value -or "$Value" -eq '') { "''" }
            else { "$Value" }
    Write-SetupLogLine -Level 'ANSWER' -Message ('{0} = {1}  ({2})' -f $Name, $text, $Source)
}

Initialize-SetupLog -Path $LogPath

# --- REGION: task bookkeeping
# Every step lands in one of three buckets, and the closing report prints all
# three. "Skipped" is the one that matters: a setup that silently declines to do
# something reads as a setup that already did it.
$Script:Done    = [System.Collections.Generic.List[string]]::new()
$Script:Skipped = [System.Collections.Generic.List[string]]::new()
$Script:Failed  = [System.Collections.Generic.List[string]]::new()
$Script:Plan    = [System.Collections.Generic.List[string]]::new()
$Script:StepNo  = 0

function Add-PlannedStep {
    param([Parameter(Mandatory)][string]$Description)
    $Script:StepNo++
    $Script:Plan.Add(("{0,2}. {1}" -f $Script:StepNo, $Description))
}

function Add-SkippedStep {
<#
.SYNOPSIS
    Record something this run deliberately did not do.
.DESCRIPTION
    Logged where it is decided, not only in the closing report: "the stash
    service was skipped" answers a different question depending on whether it
    came before or after the storage step failed.
.PARAMETER Quiet
    The caller has already printed its own line; only log.
#>
    param(
        [Parameter(Mandatory)][string]$Description,
        [switch]$Quiet
    )
    $Script:Skipped.Add($Description)
    if (-not $Quiet) { Write-Information "  [skip] $Description" }
    Write-SetupLogLine -Level 'SKIP' -Message $Description
}

function Write-StepOutcome {
<#
.SYNOPSIS
    The one line a step is allowed to put on the operator's screen.
.DESCRIPTION
    A run is a list of outcomes. Everything else -- what a step is about to do,
    what its child scripts narrated on the way, which sub-decision it took --
    goes to the log, to be read after the fact by someone with a reason to. On
    screen that detail buries the result it is supposed to explain: the one line
    that says whether the machine is set up reads no differently from the several
    hundred that do not.

    A FAIL carries its reason inline, trimmed to one line, because a failure the
    operator has to open a file to understand is a failure they will re-run
    blindly instead.
#>
    param(
        [Parameter(Mandatory)][ValidateSet('PASS', 'SKIP', 'FAIL')][string]$Outcome,
        [Parameter(Mandatory)][string]$Name,
        [string]$Detail = '',
        [TimeSpan]$Elapsed = [TimeSpan]::Zero
    )
    $suffix = ''
    if ($Detail) {
        # One line: a multi-line exception message would reintroduce exactly the
        # wall of text this display exists to remove. The whole message is in the
        # log, and on a FAIL the child's full output is there with it.
        $flat = ((($Detail -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1) -as [string]).Trim()
        if ($flat.Length -gt 140) { $flat = $flat.Substring(0, 137) + '...' }
        $suffix = " -- $flat"
    }
    # Elapsed only where it is worth knowing: a step that took under five seconds
    # is noise, and the VM builds are what an operator is actually waiting on.
    if ($Elapsed.TotalSeconds -ge 5) {
        $suffix += ' ({0})' -f $(if ($Elapsed.TotalMinutes -ge 1) { '{0}m{1:00}s' -f [int]$Elapsed.TotalMinutes, $Elapsed.Seconds } else { '{0}s' -f [int]$Elapsed.TotalSeconds })
    }
    $line = '  - [{0}]: {1}{2}' -f $Outcome, $Name, $suffix
    # Write-Information, not Write-Host: it honours the -logLevel cascade, so
    # -logLevel Error still silences the per-step feed for a scripted caller.
    Write-Information $line
    Write-SetupLogLine -Level $Outcome -Message "$Name$suffix"
}

function Invoke-SetupStep {
<#
.SYNOPSIS
    Run one setup step, recording its outcome. Under -WhatIf, records the step in
    the plan and runs nothing.
.PARAMETER AlreadyDone
    A predicate that returns $true when the step's work is already true on this
    machine. This is what makes re-running safe.
.PARAMETER Critical
    A failure here stops the run. Non-critical steps report and continue, so one
    optional piece failing does not cost the operator everything after it.
#>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [scriptblock]$AlreadyDone,
        [switch]$Critical
    )
    Add-PlannedStep -Description $Name
    if ($WhatIfPreference) { return $true }

    if ($AlreadyDone) {
        $done = $false
        try { $done = [bool](& $AlreadyDone) } catch { $done = $false }
        if ($done) {
            Write-StepOutcome -Outcome 'SKIP' -Name $Name -Detail 'already done'
            Add-SkippedStep -Description "$Name (already done)" -Quiet
            return $true
        }
    }

    # The step's START goes to the log only. On screen a step announces itself
    # by its RESULT, once, when there is something true to say about it --
    # otherwise every step would occupy two lines and the outcome would be the
    # one further from the eye.
    Write-SetupLogLine -Level 'STEP' -Message $Name
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        # 6>&1 diverts the action's INFORMATION stream into the log instead of the
        # screen. Steps that run in-process have no child process to capture, so
        # without this a module's Write-Information -InformationAction Continue
        # ("applying template overlay" and friends) lands in the middle of the
        # outcome list. The text is not lost, it is filed; the step's own result
        # stays the only thing the console shows.
        #
        # Warnings and errors are deliberately NOT diverted: those are the two
        # streams an operator must see the moment they happen, whatever else the
        # display is doing.
        & $Action 6>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.InformationRecord]) {
                Write-SetupLogLine -Level 'INFO' -Message "  $($_.MessageData)"
            } else {
                # A step action that returns a value: keep it out of the console
                # for the same reason, but record it so nothing vanishes silently.
                Write-SetupLogLine -Level 'INFO' -Message "  $_"
            }
        }
        $sw.Stop()
        $Script:Done.Add($Name)
        Write-SetupLogLine -Level 'DONE' -Message $Name
        Write-StepOutcome -Outcome 'PASS' -Name $Name -Elapsed $sw.Elapsed
        return $true
    } catch {
        $sw.Stop()
        $message = $_.Exception.Message
        $Script:Failed.Add("$Name -- $message")
        Write-StepOutcome -Outcome 'FAIL' -Name $Name -Detail $message -Elapsed $sw.Elapsed
        if ($Critical) {
            # Report BEFORE the error: this is the last thing the run will do, and
            # the list of what did succeed is what the next attempt starts from.
            Write-SetupReport
            Write-SetupError "$Name failed: $message"
            Exit-Setup 1
        }
        return $false
    }
}

function Get-FreeSpaceGb {
<#
.SYNOPSIS
    Free space in GB on the volume holding $Path, rounded to one decimal.
    $null when no mounted volume matches or the figure cannot be read.
.DESCRIPTION
    [System.IO.DriveInfo] rather than a drive-letter split. A POSIX path has no
    qualifier to take off the front, so a Split-Path -Qualifier approach throws
    on its first statement on macOS and Linux and the headroom warning silently
    never runs there -- which is where it is needed most, because a short volume
    otherwise surfaces much later as a failure deep inside a VM build.

    GetDrives() enumerates mounted volumes on all three platforms. The volume
    holding a path is the one whose mount point is the LONGEST matching prefix:
    macOS mounts both '/' and '/System/Volumes/Data', and the shorter match would
    report a different volume's free space than the one about to be written to.

    Per-drive faults are skipped rather than fatal: an enumerated volume can
    refuse AvailableFreeSpace (disconnected network mount, permission-gated
    autofs entry) and the rest of the list is still worth reading.
#>
    param([Parameter(Mandatory)][string]$Path)
    try {
        $sep        = [IO.Path]::DirectorySeparatorChar
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        $full       = [System.IO.Path]::GetFullPath($Path)
        $fullCmp    = if ($full.EndsWith($sep)) { $full } else { $full + $sep }
        $bestRoot   = ''
        $bestFree   = $null
        foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
            try {
                if (-not $drive.IsReady) { continue }
                $root    = $drive.RootDirectory.FullName
                # Compared with the separator appended on both sides so '/Users'
                # matches '/Users/someone' but not '/UsersOther', and a path that
                # IS the mount point still matches.
                $rootCmp = if ($root.EndsWith($sep)) { $root } else { $root + $sep }
                if (-not $fullCmp.StartsWith($rootCmp, $comparison)) { continue }
                if ($rootCmp.Length -ge $bestRoot.Length) {
                    $bestRoot = $rootCmp
                    $bestFree = $drive.AvailableFreeSpace
                }
            } catch { continue }
        }
        if ($null -eq $bestFree) { return $null }
        return [Math]::Round($bestFree / 1GB, 1)
    } catch {
        Write-SetupVerbose "disk headroom check: $($_.Exception.Message)"
        return $null
    }
}

$Script:SudoKeepAlivePid = 0

function Initialize-SetupElevation {
<#
.SYNOPSIS
    Take the operator's sudo credential ONCE, while the terminal is still theirs,
    and publish the contract that forbids anything after this from asking again.
.DESCRIPTION
    Everything past this point runs with its output captured into the run log
    instead of on the terminal. A prompt raised under capture is INVISIBLE: the
    question lands in a file, stdin is still the keyboard, and the run waits
    forever on a keystroke nobody knows to press. That is strictly worse than a
    noisy console, so the credential is taken here and nowhere else.

    YURUNA_NONINTERACTIVE is the repo's existing contract for the second half.
    Initialize-SudoCache declines silently instead of running `sudo -v` when it
    is set, and Invoke-YurunaSudo adds -n, so a call that needs root after the
    timestamp has gone cold fails immediately with an attributable message
    rather than stalling on a hidden password prompt. YURUNA_SUDO_PRIMED is the
    companion fact -- it says a human really did authorize this run -- which
    lets a child tell "nobody authorized this" apart from "authorized, but the
    window closed".

    Windows is exempt: it has no sudo, and the run has already relaunched itself
    elevated (or refused) long before here.

    An unattended run never prompts. It probes with `sudo -n -v` instead and
    reports what it found; an answer file is consent to a setup, not a password.
.OUTPUTS
    [bool] $true when root operations are expected to work unprompted.
#>
    param([string[]]$Reason = @())
    if ($IsWindows) { return $true }
    if (-not (Get-Command sudo -ErrorAction SilentlyContinue)) {
        Write-SetupVerbose 'no sudo on PATH; steps that need root will report their own failure.'
        return $false
    }
    # Already warm (an outer run primed it, or the operator just used sudo): do
    # not spend a prompt on a credential we already hold.
    & sudo -n -v 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-SetupVerbose 'sudo timestamp already warm; no password needed.'
        return $true
    }
    if ($Script:Unattended) {
        Write-SetupWarning ('This run needs sudo and the timestamp is cold, but an answer file is consent to a setup, not a password. ' +
                            'Steps needing root will fail with the command to run. Prime it first with "sudo -v" and re-run.')
        return $false
    }
    Write-SetupMessage ''
    Write-SetupMessage 'This setup needs sudo once, now, for:'
    foreach ($r in $Reason) { Write-SetupMessage "  * $r" }
    Write-SetupMessage 'Everything after this runs unattended -- nothing else will ask you anything.'
    # Straight to the terminal on purpose: sudo reads the password from /dev/tty,
    # so this one call has to keep the console that every later step gives up.
    & sudo -v
    if ($LASTEXITCODE -ne 0) {
        Write-SetupWarning 'sudo was not authorized. The run continues; steps that need root will fail and name what they needed.'
        return $false
    }
    return $true
}

function Start-SudoKeepAlive {
<#
.SYNOPSIS
    Keep the sudo timestamp warm for the length of the run. No-op on Windows.
.DESCRIPTION
    sudo forgets an authorization after about five minutes; a setup run is four
    times that on a good day, and the long steps (a proxy VM build) are exactly
    where the gap falls. Without a refresher the single prime above would go cold
    mid-run and every -n call after it would fail -- turning "authorized once"
    into "authorized for the first two steps".

    The refresher is spawned with Start-Process and no redirection, which gives
    it its own console and no inheritable handles, so it cannot pin the stdout
    pipe this script reads from its own children
    (feedback_windows-detached-grandchild-pins-pipe). It stops itself when this
    process goes away, so an interrupted run cannot strand a process that holds
    a live root authorization.
#>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Spawns a short-lived helper bound to this run; -WhatIf is handled by the caller region.')]
    param()
    if ($IsWindows) { return }
    if (-not (Get-Command sudo -ErrorAction SilentlyContinue)) { return }
    $refresh = "while (Get-Process -Id $PID -ErrorAction SilentlyContinue) { & sudo -n -v 2>`$null; Start-Sleep -Seconds 45 }"
    try {
        $proc = Start-Process -FilePath (Get-CurrentPwshPath) `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $refresh) -PassThru
        $Script:SudoKeepAlivePid = $proc.Id
        Write-SetupVerbose "sudo keep-alive started (pid $($proc.Id))."
    } catch {
        Write-SetupVerbose "sudo keep-alive could not start: $($_.Exception.Message)"
    }
}

function Stop-SudoKeepAlive {
<#
.SYNOPSIS
    Stop the sudo refresher. Safe to call when none was started.
#>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Stops the helper process this run started; no operator decision involved.')]
    param()
    if (-not $Script:SudoKeepAlivePid) { return }
    try { Stop-Process -Id $Script:SudoKeepAlivePid -Force -ErrorAction SilentlyContinue } catch {
        Write-SetupVerbose "sudo keep-alive stop: $($_.Exception.Message)"
    }
    $Script:SudoKeepAlivePid = 0
}

function Invoke-RepoScript {
<#
.SYNOPSIS
    Run one of the repo's own scripts in a child pwsh and throw on a non-zero
    exit.
.DESCRIPTION
    A child process, not dot-sourcing: these scripts set their own preferences,
    import their own modules and call exit. Hosting them in this session would
    let one of them terminate the whole setup, and would leak their module
    imports into every later step.

    THE CHILD WRITES TO A LOG, NOT TO THIS CONSOLE. All three streams are
    redirected: stdout and stderr are drained line-by-line into
    `<leaf>.console.log`, and stdin is closed straight after start, so a child
    that still tries to prompt gets EOF instead of stalling on a question nobody
    can see. The console stays quiet for the duration of a step; the child's own
    words reach the operator through that log and through the failure tail this
    function folds into the run log.

    `& pwsh ...` cannot be used here. It surrenders the two controls this
    function depends on: draining both streams before waiting (a child that
    fills the pipe buffer while nobody reads deadlocks on its own write) and
    bounding the wait so a detached grandchild holding the inherited pipe cannot
    hang the setup. PowerShell would also capture the child's output into a
    pipeline nobody prints, since every call site consumes the result.

    ArgumentList (not a joined string) so each argument reaches the child as one
    argv entry: a storage root or lab name carrying a space must not be re-split
    on the way in -- the legacy-quoting regression class.

    The child inherits this process's environment (UseShellExecute false), and
    $env:YURUNA_LOG_LEVEL rides along in it. That is what carries -logLevel down:
    preference variables stop at the process boundary, the environment variable
    does not. YURUNA_CHILD_TRANSCRIPT_DIR is added the same way and travels the
    same distance -- the child and every pwsh IT starts transcribe into that one
    directory, which is what lets a failure here be reported with the child's own
    words instead of just its exit code.
#>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Arguments = @(),
        [switch]$TolerateFailure
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "script not found: $Path" }
    # A $null element must never reach ArgumentList below: it is added as an
    # EMPTY argv entry, which the child binds to its first POSITIONAL parameter
    # -- a script defaulting that parameter to a real value silently receives ''
    # instead. $Arguments is itself $null whenever a caller passes a statement
    # whose branch produced no output ([string[]] binding turns that into a real
    # $null, discarding the @() default above), and `@(...) + $null` appends the
    # null rather than being a no-op. Filtered, not merely counted: an
    # intentional empty-string argument is still passed through. Done before the
    # EXEC line so the log shows the argv the child actually receives -- a
    # trailing empty entry renders as nothing there, which is what makes this
    # class of fault invisible in a log that looks correct.
    $childArguments = @($Arguments | Where-Object { $null -ne $_ })
    $leaf = [IO.Path]::GetFileName($Path)
    Write-SetupLogLine -Level 'EXEC' -Message "$Path $($childArguments -join ' ')"
    $transcriptDir = Get-ChildTranscriptDirectory -Leaf $leaf
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-CurrentPwshPath
    # UseShellExecute stays false: on .NET it is what lets the streams below be
    # redirected at all.
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError  = $true
    # Stdin is redirected and then closed immediately (below). Two things follow.
    # A child that still tries to read gets EOF and fails instead of stalling
    # forever on a prompt whose text went to the log. And [Console]::IsInputRedirected
    # becomes true inside the child, which is the predicate several scripts
    # already consult before offering an interactive choice -- so closing stdin
    # disarms that whole family of prompts at once rather than one at a time.
    $startInfo.RedirectStandardInput = $true
    # Reading .Environment seeds it from this process, so these add to the
    # inherited set rather than replacing it. They travel to grandchildren too,
    # which is the point: the per-guest New-VM.ps1 scripts are two tiers down.
    if ($transcriptDir) { $startInfo.Environment['YURUNA_CHILD_TRANSCRIPT_DIR'] = $transcriptDir }
    $startInfo.Environment['YURUNA_NONINTERACTIVE'] = '1'
    if ($Script:ElevationOk) { $startInfo.Environment['YURUNA_SUDO_PRIMED'] = '1' }
    # -NonInteractive on the child pwsh itself, so an engine-level prompt (a
    # mandatory parameter nobody bound, an unsuppressed confirmation) is an error
    # rather than a wait.
    foreach ($argument in (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Path) + $childArguments)) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $code = 1
    $process = $null
    $childLog = if ($transcriptDir) { Join-Path $transcriptDir "$leaf.console.log" } else { '' }
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
        try { $process.StandardInput.Close() } catch { Write-SetupVerbose "close child stdin: $($_.Exception.Message)" }
        # Drained line-by-line through the engine's event queue, and started
        # BEFORE the wait: a child that fills the pipe buffer while nobody reads
        # blocks on its own write, which would deadlock a chatty step.
        #
        # Event subscriptions rather than Task.Run: a scriptblock handed to a
        # thread-pool thread has no Runspace and throws on its first statement.
        # Line-at-a-time rather than ReadToEndAsync for the same reason the wait
        # below is timed -- a stream that never reaches EOF still yields every
        # line it produced, instead of an unusable all-or-nothing result.
        $lines = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $subs = @(
            Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -MessageData $lines -Action {
                if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
            }
            Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -MessageData $lines -Action {
                if ($null -ne $EventArgs.Data) { $Event.MessageData.Enqueue($EventArgs.Data) }
            }
        )
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
        # WaitForExit(ms), NEVER the parameterless overload. Only the no-arg form
        # ALSO waits for stream EOF, and EOF never arrives while a detached
        # server the child spawned still holds the inherited pipe -- which the
        # service bring-ups do, because they start the status service. Measured
        # across the eight combinations of (grandchild spawn) x (sync/async read)
        # x (wait overload): that single combination blocks for the GRANDCHILD's
        # lifetime, every other for the child's.
        # See feedback_windows-detached-grandchild-pins-pipe.
        [void]$process.WaitForExit(86400000)
        $code = $process.ExitCode
        # A short settle for lines the child emitted just before exiting, then
        # stop reading unconditionally. Never a wait on EOF, for the reason above.
        Start-Sleep -Milliseconds 200
        foreach ($s in $subs) { Unregister-Event -SubscriptionId $s.Id -ErrorAction SilentlyContinue }
        if ($childLog -and -not $lines.IsEmpty) {
            [System.IO.File]::WriteAllLines($childLog, @($lines.ToArray()), [System.Text.UTF8Encoding]::new($false))
        }
    } finally {
        if ($process) { $process.Dispose() }
    }
    Write-SetupLogLine -Level 'EXIT' -Message "$leaf exited $code"
    # After WaitForExit, so the child's transcript is closed and flushed. Always,
    # not only on failure: the console no longer shows a child's output, so this
    # is the only place it is kept.
    Write-ChildOutputToLog -Directory $transcriptDir -Leaf $leaf
    if ($code -ne 0 -and -not $TolerateFailure) {
        throw "$leaf exited $code"
    }
    return $code
}

function Invoke-ServiceVMReset {
<#
.SYNOPSIS
    Stop and remove a service VM so the Start step that follows it builds from a
    clean slate. Recorded as a step of its own.
.DESCRIPTION
    A run that is not adopting a service VM tears it down before starting it,
    rather than building over whatever the last run left. Two things make this
    the setup's job and not the Start scripts':

    The stash and pool-control Starts delegate to a per-host New-VM.ps1 that
    deletes the VM's bundle/disk directory in place and never unregisters the VM
    from the hypervisor. Rebuilding over a still-registered VM leaves the
    hypervisor holding a registration whose files are gone, and the start that
    follows fails on a VM it believes it already has. The Stop scripts
    unregister first, which is the whole difference.

    The caching proxy is ADOPTED by its own Start whenever its health probe
    passes -- the fast path that skips a ~15-minute rebuild, and the one outcome
    a rebuild cannot use, because an adopted VM keeps the base image, the seed
    and the baked configuration the rebuild exists to replace. Stopping it first
    also clears an abandoned bring-up lock; a Start refuses to take that over on
    its own and stops the run instead.

    Paired with its Start rather than swept up front, so a run only ever removes
    a service it is going to rebuild: a standalone re-run on a machine that was
    once a lab must not silently delete that lab's pool-control service.

    Never critical. A teardown that fails still leaves the Start script its own
    destroy-and-rebuild path, so the run is better off continuing and letting
    the start report what it actually hits.
#>
    param(
        [Parameter(Mandatory)][string]$Service,
        [Parameter(Mandatory)][string]$StopScript
    )
    $stopPath = Join-Path $TestRoot $StopScript
    [void](Invoke-SetupStep -Name "Stop and remove any existing $Service VM (clean slate for the start)" -Action {
        [void](Invoke-RepoScript -Path $stopPath)
    })
}

function Test-ServiceVMAdoptable {
<#
.SYNOPSIS
    Can this service be taken as-is instead of rebuilt? Returns a verdict object
    with Adopt (bool) and Reason (string).
.DESCRIPTION
    Rebuilding a service VM costs roughly fifteen minutes for the caching proxy
    and throws away a warm squid cache, so a re-run that only wanted to fix one
    broken thing paid that price for every service that was already fine. The
    operator's re-run is usually a repair, not a reinstall.

    Three outcomes, from the roster the harness already keeps:
      * running and answering its health port -> adopt, do nothing at all;
      * registered but stopped -> start it (Restore-YurunaServiceVM), which is
        far cheaper than a rebuild and is what a host that was merely powered
        off actually needs;
      * absent, or up but not answering -> rebuild, because there is either
        nothing to adopt or something demonstrably wrong with what is there.

    What adoption gives up: a VM built from earlier inputs keeps them. The seed
    is baked at build time, so a changed cachingProxyIp or storage credential
    does NOT reach a VM that is merely adopted. -Rebuild is the way to force
    that through, and the reason this is a decision rather than a default.
.PARAMETER RosterKey
    Key into Get-YurunaServiceVmRoster: caching-proxy, stash, pool-control,
    download-agent.
#>
    param([Parameter(Mandatory)][string]$RosterKey)
    # A preview asks the machine nothing. Loading the host driver and querying
    # hypervisor state is real work, and a -WhatIf run that probed VMs would also
    # report a plan shaped by a machine state the operator has not agreed to
    # touch yet. It lists the full rebuild, which is the honest upper bound of
    # what a real run might do.
    if ($WhatIfPreference) { return [pscustomobject]@{ Adopt = $false; Reason = 'preview -- nothing was probed' } }
    if ($Script:Rebuild) { return [pscustomobject]@{ Adopt = $false; Reason = '-Rebuild was requested' } }
    try {
        Import-SetupModule (Join-Path $TestRoot 'modules/Test.HostContract.psm1')
        Import-SetupModule (Join-Path $TestRoot 'modules/Test.ServiceVm.psm1')
        [void](Initialize-YurunaHost -RepoRoot $RepoRoot -HostType $HostType)
    } catch {
        # Without the host driver there is no way to ask, and guessing "adopt"
        # would skip a rebuild the machine may need. Fall back to rebuilding.
        return [pscustomobject]@{ Adopt = $false; Reason = "could not load the host contract to check ($($_.Exception.Message))" }
    }
    # Restore-YurunaServiceVM is the existing self-heal: it reports state, starts
    # a registered-but-stopped VM, and probes the health port. Reusing it keeps
    # one definition of "is this service usable" instead of a second, subtly
    # different one here.
    $r = @(Restore-YurunaServiceVM -Key @($RosterKey) -Confirm:$false) | Select-Object -First 1
    if (-not $r) { return [pscustomobject]@{ Adopt = $false; Reason = 'the service roster returned nothing' } }
    Write-SetupDetail "$RosterKey adopt check: state=$($r.StateBefore) outcome=$($r.Outcome) healthy=$($r.Healthy) -- $($r.Message)"
    switch ($r.Outcome) {
        'running'  { return [pscustomobject]@{ Adopt = $true;  Reason = 'already running and answering' } }
        'started'  {
            if ($r.Healthy) { return [pscustomobject]@{ Adopt = $true; Reason = 'was stopped; started it and it answered' } }
            # Started but silent. Give it the benefit of the doubt only when the
            # health probe could not run at all (no address yet); a port that was
            # probed and refused is a real fault worth rebuilding over.
            if ($r.Message -match 'no address') {
                return [pscustomobject]@{ Adopt = $true; Reason = 'was stopped; started it (address not resolved yet, so its port was not probed)' }
            }
            return [pscustomobject]@{ Adopt = $false; Reason = 'started, but its service port did not answer' }
        }
        'absent'   { return [pscustomobject]@{ Adopt = $false; Reason = 'not built on this host yet' } }
        default    { return [pscustomobject]@{ Adopt = $false; Reason = $r.Message } }
    }
}

function Invoke-ServiceVMEnsure {
<#
.SYNOPSIS
    Bring a service up the cheapest way that actually works: adopt it, start it,
    or rebuild it. Records one step either way.
.DESCRIPTION
    The teardown is what makes a re-run apply a changed seed, so it is exactly
    what -Rebuild does -- but it is not the price of every re-run, because most
    re-runs repair one thing rather than reinstall the machine.
#>
    param(
        [Parameter(Mandatory)][string]$Service,
        [Parameter(Mandatory)][string]$RosterKey,
        [Parameter(Mandatory)][string]$StopScript,
        [Parameter(Mandatory)][string]$StartScript,
        [string[]]$StartArguments = @(),
        [switch]$Critical
    )
    # Bound to locals before the scriptblock below captures them:
    # PSReviewUnusedParameter cannot follow a use that happens only inside a
    # scriptblock handed to another command, so a parameter used only there
    # reads to the analyzer as unused.
    $startPath = Join-Path $TestRoot $StartScript
    $startArgs = $StartArguments

    $verdict = try { Test-ServiceVMAdoptable -RosterKey $RosterKey } catch {
        Write-SetupDetail "$Service reuse check failed: $($_.Exception.Message)"
        $null
    }
    if ($verdict -and $verdict.Adopt) {
        Add-SkippedStep -Description "$Service reused ($($verdict.Reason))" -Quiet
        Write-StepOutcome -Outcome 'SKIP' -Name "Start the $Service VM" -Detail $verdict.Reason
        return
    }
    $why = if ($verdict) { $verdict.Reason } else { 'the reuse check did not complete' }
    Write-SetupDetail "$Service will be rebuilt: $why"
    Invoke-ServiceVMReset -Service $Service -StopScript $StopScript
    # -Critical is forwarded rather than reimplemented: the caching proxy is the
    # one service whose failure ends the run, because everything built after it
    # bakes its address into a guest seed that never re-resolves.
    [void](Invoke-SetupStep -Name "Start the $Service VM" -Critical:$Critical -Action {
        [void](Invoke-RepoScript -Path $startPath -Arguments $startArgs)
    })
}

function Get-LocalLabStorageArgument {
<#
.SYNOPSIS
    The argument list for New-LocalLabStorage.ps1, correct for both an
    interactive and an unattended run.
.DESCRIPTION
    Two of that script's prompts are invisible from here and neither is
    suppressed by anything setup.ps1 sets: the "storage is LOCAL to this machine,
    continue?" consent (skipped only by -Force) and "where should the lab's
    storage live?" (skipped only by -Root). Under -AnswerFile the child would sit
    on a Read-Host that nobody is present to answer -- the exact silent stall an
    unattended run must never produce.

    So an unattended run passes -Force (the answer file IS the consent) and
    requires storage.localRoot. Missing it FAILS with the key to set rather than
    blocking: a run that stops with a message can be fixed, a run that hangs
    cannot even be diagnosed remotely.

    The lab name is sanitised to the pool-id charset here. New-LocalLabStorage
    only sanitises the name it invents for itself, so a machine whose hostname
    carries an underscore would pass its own check by hand and fail through us.
#>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '',
        Justification = 'The `return ,$argList` idiom below is what makes the caller receive one array rather than loose strings. Static analysis reads the comma as an [object[]] wrapper; at runtime the pipeline unwraps it and the caller gets the string[].')]
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string]$LabName = '',
        [string]$LocalRoot = '',
        [bool]$Unattended = $false
    )
    $name = if ($LabName) { $LabName } else { [Environment]::MachineName }
    $name = ($name.ToLowerInvariant() -replace '[^a-z0-9-]', '-').Trim('-')
    if (-not $name) { $name = 'lab' }
    if ($name.Length -gt 63) { $name = $name.Substring(0, 63).TrimEnd('-') }

    $argList = @('-LabName', $name)
    if ($LocalRoot) { $argList += @('-Root', $LocalRoot) }
    if ($Unattended) {
        if (-not $LocalRoot) {
            throw ("an unattended local-storage run needs storage.localRoot in the answer file: " +
                   "New-LocalLabStorage.ps1 asks where the lab's storage should live, and with nobody " +
                   "there to answer it the run would hang instead of failing")
        }
        # The answer file is the operator's consent; without -Force the child
        # stops on its local-only confirmation prompt.
        $argList += '-Force'
    }
    return ,$argList
}

function Get-StorageAliasTier {
<#
.SYNOPSIS
    One record per configured storage tier: the server NAME its alias is keyed on
    and the share path that name came from. Empty when storage is unconfigured.
.DESCRIPTION
    Read from test.config.yml rather than from this run's answers, because the
    hosts file has to agree with what the RUNNER will later mount, and that is
    the file -- not the questionnaire. The two tiers are returned separately: a
    machine can legitimately carry a different server name per tier.
.OUTPUTS
    System.Collections.Hashtable[]  @{ Name; NetworkPath }
#>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param()
    Import-SetupModule (Join-Path $TestRoot 'modules/Test.PoolStorage.psm1')
    Import-SetupModule (Join-Path $TestRoot 'modules/Test.Config.psm1')
    $tiers = [System.Collections.Generic.List[hashtable]]::new()
    $cfg = Read-TestConfig -Path $ConfigPath
    foreach ($storage in @(
        (Get-YurunaPoolStorageConfig  -Config $cfg -IgnoreReplicate -WarningAction SilentlyContinue),
        (Get-YurunaStashStorageConfig -Config $cfg -WarningAction SilentlyContinue))) {
        if (-not $storage -or -not $storage.NetworkPath) { continue }
        $name = Get-PoolStorageServerName -NetworkPath $storage.NetworkPath
        if (-not $name) { continue }
        if ($tiers.Name -contains $name) { continue }
        $tiers.Add(@{ Name = $name; NetworkPath = $storage.NetworkPath })
    }
    return $tiers.ToArray()
}

function Import-YamlModule {
<#
.SYNOPSIS
    Import powershell-yaml without its alias creation narrating itself under
    -WhatIf, or its exports under -logLevel Verbose.
.DESCRIPTION
    powershell-yaml creates two aliases at import, and New-Alias supports
    ShouldProcess -- so a preview run prints "What if: New Alias" twice before
    the task list it was actually asked for. Both preferences have to be cleared
    in the GLOBAL scope: a module's top-level code resolves preference variables
    up the module/global chain, not through the caller's dynamic scope, so
    setting them locally (or in a child scope) has no effect -- and that is also
    why -Verbose:$false on the call below would not reach the module's own
    nested imports. Same suppression as Import-SetupModule, which cannot be used
    here because this import is by module NAME and must not be -Force'd.
#>
    $priorWhatIf  = $global:WhatIfPreference
    $priorVerbose = $global:VerbosePreference
    try {
        $global:WhatIfPreference  = $false
        $global:VerbosePreference = 'SilentlyContinue'
        Import-Module powershell-yaml -Verbose:$false
    } finally {
        $global:WhatIfPreference  = $priorWhatIf
        $global:VerbosePreference = $priorVerbose
    }
}

function Read-Choice {
<#
.SYNOPSIS
    Ask a numbered question. Returns the chosen option's Value.
.DESCRIPTION
    Never prompts on an unattended run: with an answer file the value is already
    known, and a Read-Host here is exactly the stall that makes a remote setup
    hang with nobody present to answer it.

    Every outcome is logged with how it was reached -- typed, taken by pressing
    Enter, or never asked. A log that records only the value cannot answer the
    question actually asked of it later: did anyone choose this?
#>
    param(
        [Parameter(Mandatory)][string]$Question,
        [Parameter(Mandatory)][hashtable[]]$Option,
        [Parameter(Mandatory)]$Default
    )
    $label = { param($Value) ($Option | Where-Object { $_.Value -eq $Value } | Select-Object -First 1).Label }
    if ($Script:Unattended) {
        Write-SetupLogLine -Level 'ASK' -Message "$Question -- not asked (unattended)"
        Write-SetupLogLine -Level 'ANSWER' -Message "$Default -- $(& $label $Default) (unattended default)"
        return $Default
    }
    Write-SetupMessage ''
    Write-SetupMessage $Question
    for ($i = 0; $i -lt $Option.Count; $i++) {
        $marker = if ($Option[$i].Value -eq $Default) { ' (default)' } else { '' }
        Write-SetupMessage ("  [{0}] {1}{2}" -f ($i + 1), $Option[$i].Label, $marker)
    }
    while ($true) {
        $answer = (Read-Host 'Choice').Trim()
        if (-not $answer) {
            Write-SetupLogLine -Level 'ANSWER' -Message "$Default -- $(& $label $Default) (Enter: default)"
            return $Default
        }
        $n = 0
        if ([int]::TryParse($answer, [ref]$n) -and $n -ge 1 -and $n -le $Option.Count) {
            Write-SetupLogLine -Level 'ANSWER' -Message "$($Option[$n - 1].Value) -- $($Option[$n - 1].Label) (typed: $answer)"
            return $Option[$n - 1].Value
        }
        Write-SetupMessage "  Enter a number between 1 and $($Option.Count)."
    }
}

function Read-Text {
    param(
        [Parameter(Mandatory)][string]$Question,
        [string]$Default = ''
    )
    if ($Script:Unattended) {
        Write-SetupLogLine -Level 'ASK' -Message "$Question -- not asked (unattended)"
        Write-SetupLogLine -Level 'ANSWER' -Message "$Default (unattended default)"
        return $Default
    }
    $suffix = if ($Default) { " [$Default]" } else { '' }
    Write-SetupLogLine -Level 'ASK' -Message "$Question$suffix"
    $answer = (Read-Host "$Question$suffix").Trim()
    if (-not $answer) {
        Write-SetupLogLine -Level 'ANSWER' -Message "$(if ($Default) { $Default } else { "''" }) (Enter: default)"
        return $Default
    }
    Write-SetupLogLine -Level 'ANSWER' -Message "$answer (typed)"
    return $answer
}

function Write-DashboardHint {
<#
.SYNOPSIS
    Where to look at what this run built, and when its service links go live.
.DESCRIPTION
    A run that ends "ready" tells the operator what it built but not where to
    look at it. The hosts dashboard is that place, and it is useful even on a
    standalone host -- it shows this machine and its extension services, which
    is exactly what someone re-running setup was trying to confirm.

    The second line is the one that prevents a support question. A service VM is
    created and started in under a minute, but its daemon does not exist until
    the guest has installed a Go toolchain and compiled it -- ten minutes to the
    better part of an hour. Until then the dashboard has a row for the service
    and no link on it, because the address a link needs comes from the daemon's
    own announce, and there is no daemon yet to announce. Nothing is wrong at
    that moment and nothing needs doing; saying so here is cheaper than an
    operator concluding the run half-failed and starting over.

    Gated on the proxy address alone, and not on whether a step failed: that
    address is READ FROM the proxy's own state, so having one means the proxy
    came up and Grafana is there to answer. A run that failed elsewhere is
    exactly when an operator wants to see what did come up.

    http, not https. Grafana in the proxy guest serves plain HTTP on :3000 --
    the aggregator is the service that uses TLS, on :9400 -- so an https link
    here would simply fail to connect.
#>
    param(
        [AllowEmptyString()][string]$ProxyIp = ''
    )
    if (-not $ProxyIp) { return }
    Write-SetupMessage ''
    Write-SetupMessage "Yuruna hosts dashboard: http://${ProxyIp}:3000/d/yuruna-pool/yuruna-hosts"
    Write-SetupMessage 'Links to services will become active after their initialization.'
}

function Write-SetupReport {
    Write-SetupMessage ''
    Write-SetupMessage '================ Yuruna setup ================'
    if ($Script:Done.Count -gt 0) {
        Write-SetupMessage 'Done:'
        foreach ($d in $Script:Done) { Write-SetupMessage "  - $d" }
    }
    if ($Script:Skipped.Count -gt 0) {
        Write-SetupMessage ''
        Write-SetupMessage 'Skipped:'
        foreach ($s in $Script:Skipped) { Write-SetupMessage "  - $s" }
    }
    if ($Script:Failed.Count -gt 0) {
        Write-SetupMessage ''
        Write-SetupMessage 'Failed:'
        foreach ($f in $Script:Failed) { Write-SetupMessage "  - $f" }
    }
    Write-SetupMessage '=============================================='
    # Named on the console, not only in the file: the operator who needs the log
    # is the one whose run just failed, and they should not have to know where
    # this script keeps it.
    if ($Script:LogFile) { Write-SetupMessage "Log: $Script:LogFile" }
}

# --- REGION: preflight
Import-SetupModule (Join-Path $RepoRoot 'automation/Yuruna.HostRedirect.psm1')
# Test.HostDetection directly: Yuruna.HostRedirect keeps its own
# Import-HostDetectionModule private, and Get-HostType / Get-HostFolder are what
# this needs.
Import-SetupModule (Join-Path $RepoRoot 'test/modules/Test.HostDetection.psm1')
$HostType = Get-HostType
if (-not $HostType) {
    Write-SetupError 'Host type could not be determined. Only macOS (UTM), Windows (Hyper-V) and Linux (KVM/libvirt) are supported.'
    Exit-Setup 1
}
$HostFolderName = (Get-HostFolder $HostType) -replace '^host[/\\]', ''

Write-SetupMessage ''
Write-SetupMessage "Yuruna setup -- $HostFolderName"
Write-SetupMessage "Repo: $RepoRoot"
if ($Script:LogFile) { Write-SetupMessage "Log:  $Script:LogFile" }

# macOS / Linux: refuse to run as root, BEFORE anything is written. These
# scripts elevate the individual operations that need it (networksetup, the
# SMB server, /etc/hosts), so a whole-run `sudo` buys nothing and breaks the
# result: every artifact lands under root's home (/var/root on macOS) instead
# of the operator's, where the hypervisor -- running as the operator -- cannot
# reach it. The per-VM builders detect this and hand ownership back, but only
# AFTER the image, the bundle and the mounts have gone to the wrong place. It
# also puts the SMB mount points under /var, which macOS reports back through
# its /private symlink and no longer matches what was asked for.
if (-not $IsWindows) {
    $uid = $null
    try { $uid = (& id -u 2>$null) } catch { Write-SetupVerbose "id -u probe: $($_.Exception.Message)" }
    if ("$uid".Trim() -eq '0') {
        $asUser = if ($env:SUDO_USER) { $env:SUDO_USER } else { 'your own account' }
        Write-SetupError @"
Refusing to run as root.

Yuruna setup elevates the individual operations that need it and prompts for
your password when it does. Running the WHOLE script under sudo puts every
artifact in root's home (HOME=$env:HOME) -- base images, VM bundles and the
storage mounts -- where the hypervisor, which runs as $asUser, cannot reach
them.

Re-run without sudo:
    pwsh install/setup.ps1
"@
        Exit-Setup 1
    }
}

# Windows: elevate ONCE, up front. Enable-TestAutomation and all three Start-*VM
# scripts each refuse without Administrator, so a non-elevated run would get
# four steps in and then fail on every one that matters.
if ($IsWindows) {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        if ($WhatIfPreference) {
            # A preview changes nothing, so it needs no elevation -- and
            # relaunching here would be worse than useless: Start-Process itself
            # honours -WhatIf, so the elevated run would never start and this
            # script would exit 0 as though the preview had succeeded.
            Write-SetupWarning 'Not running as Administrator. This preview needs no elevation, but the real run does -- it will relaunch elevated.'
        } else {
            Write-SetupMessage ''
            Write-SetupMessage 'This setup needs Administrator: host settings, the firewall rules and'
            Write-SetupMessage 'every Hyper-V VM operation require it. Relaunching elevated...'
            $relaunchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
            if ($AnswerFile) { $relaunchArgs += @('-AnswerFile', (Resolve-Path -LiteralPath $AnswerFile).Path) }
            # The elevated run continues THIS log rather than opening one of its
            # own. Everything worth reading happens after the elevation, so two
            # files would mean a near-empty one under the time the operator
            # remembers starting and the real record under a name they do not.
            # Handed down as an argument, not an environment variable: the
            # RunAs process is created by the AppInfo service, and the parent's
            # environment does not reliably survive that.
            if ($Script:LogFile) { $relaunchArgs += @('-LogPath', $Script:LogFile) }
            # The level travels as an argument for the same reason the log path
            # does: RunAs builds the process through the AppInfo service, so the
            # $env:YURUNA_LOG_LEVEL this run published does not reliably reach
            # it. Resolved rather than $logLevel verbatim, so a level that came
            # from test.config.yml survives the elevation too.
            $relaunchArgs += @('-logLevel', $EffectiveLogLevel)
            try {
                # -Confirm:$false so an ambient $ConfirmPreference cannot turn the
                # relaunch into a prompt that the elevated child never sees.
                $proc = Start-Process -FilePath (Get-CurrentPwshPath) -ArgumentList $relaunchArgs -Verb RunAs -PassThru -Wait -Confirm:$false
                if (-not $proc) { throw 'the elevated process did not start' }
                Write-SetupLogLine -Level 'NOTE' -Message 'the elevated run''s record is the block above, in this same file'
                Exit-Setup ([int]$proc.ExitCode)
            } catch {
                Write-SetupError "Could not relaunch elevated ($($_.Exception.Message)). Start an Administrator PowerShell and run: pwsh $PSCommandPath"
                Exit-Setup 1
            }
        }
    }
}

# --- REGION: answers
$Script:Unattended = [bool]$AnswerFile
$answers = $null
if ($AnswerFile) {
    if (-not (Test-Path -LiteralPath $AnswerFile)) {
        Write-SetupError "Answer file not found: $AnswerFile"
        Exit-Setup 1
    }
    Import-YamlModule
    $answers = Get-Content -LiteralPath $AnswerFile -Raw | ConvertFrom-Yaml -Ordered
}

function Get-Answer {
<#
.SYNOPSIS
    One value from the answer file by 'section.key' path, or $null.
#>
    param([Parameter(Mandatory)][string]$Path)
    if (-not $answers) { return $null }
    $node = $answers
    foreach ($part in ($Path -split '\.')) {
        if ($node -isnot [System.Collections.IDictionary] -or -not $node.Contains($part)) { return $null }
        $node = $node[$part]
    }
    return $node
}

function Get-DecisionSource {
<#
.SYNOPSIS
    How a resolved answer was arrived at, for the log.
.DESCRIPTION
    Three outcomes and they are not interchangeable: the operator supplied it,
    the operator was asked, or nobody chose it and the script's own default
    stood. The last one is the one worth being able to find later.
#>
    param([Parameter(Mandatory)][bool]$FromAnswerFile)
    if ($FromAnswerFile) { return 'answer file' }
    if ($Script:Unattended) { return 'default -- absent from the answer file' }
    return 'asked'
}

$setupType = Get-Answer 'setup.type'
$setupTypeSource = Get-DecisionSource -FromAnswerFile ([bool]$setupType)
if (-not $setupType) {
    $setupType = Read-Choice -Question 'What are you setting up?' -Default 'standalone' -Option @(
        @{ Label = 'Standalone host -- one machine that runs tests by itself'; Value = 'standalone' }
        @{ Label = 'Lab -- a beacon other machines join (shared storage + services + a pool)'; Value = 'lab' }
    )
}
if ($setupType -notin @('standalone', 'lab')) {
    Write-SetupError "setup.type must be 'standalone' or 'lab' (got '$setupType')."
    Exit-Setup 1
}
$isLab = ($setupType -eq 'lab')

$runTestsAnswer = Get-Answer 'setup.runTests'
$runTestsSource = Get-DecisionSource -FromAnswerFile ($null -ne $runTestsAnswer)
$runTests = if ($null -ne $runTestsAnswer) { [bool]$runTestsAnswer } else {
    (Read-Choice -Question 'Should this machine run tests itself?' -Default $true -Option @(
        @{ Label = 'Yes -- configure host settings (display sleep, screen lock, firewall)'; Value = $true }
        @{ Label = 'No -- this machine only hosts services'; Value = $false }
    ))
}

$projectUrl = Get-Answer 'setup.projectUrl'
$projectUrlSource = if ($null -ne $projectUrl) { 'answer file' } else { 'script default -- never asked' }
if ($null -eq $projectUrl) { $projectUrl = $DefaultProjectUrl }

$storageKind = Get-Answer 'storage.kind'
$storageKindSource = Get-DecisionSource -FromAnswerFile ([bool]$storageKind)
if (-not $storageKind) {
    $storageOptions = @(
        @{ Label = 'This machine -- stand up local SMB shares here (New-LocalLabStorage)'; Value = 'local' }
        @{ Label = 'An existing NAS share'; Value = 'nas' }
    )
    # 'none' is standalone-only: a lab without shared storage is not a lab -- the
    # stash service and the pool intent store both live on it.
    if (-not $isLab) { $storageOptions += @{ Label = 'None -- skip shared storage and the stash service'; Value = 'none' } }
    $storageKind = Read-Choice -Question 'Where should pool and stash storage live?' `
        -Default $(if ($isLab) { 'nas' } else { 'local' }) -Option $storageOptions
}
if ($storageKind -notin @('local', 'nas', 'none')) {
    Write-SetupError "storage.kind must be 'local', 'nas' or 'none' (got '$storageKind')."
    Exit-Setup 1
}
if ($isLab -and $storageKind -eq 'none') {
    Write-SetupError "storage.kind 'none' is not valid for a lab: the stash service and the pool intent store both need shared storage."
    Exit-Setup 1
}

$storageNetworkPath = [string](Get-Answer 'storage.networkPath')
$storageNetworkUser = [string](Get-Answer 'storage.networkUser')
# Captured before the prompts below, which overwrite the values with what the
# operator types -- after them there is no telling the two sources apart.
$storageNetworkFromFile = [bool]$storageNetworkPath
if ($storageKind -eq 'nas') {
    if (-not $storageNetworkPath) { $storageNetworkPath = Read-Text -Question 'NAS share for the pool (e.g. //ypool-nas/work/yuruna.pool)' }
    if (-not $storageNetworkUser) { $storageNetworkUser = Read-Text -Question 'NAS account' -Default 'yuruna-pool' }
    if (-not $storageNetworkPath -or -not $storageNetworkUser) {
        Write-SetupError "storage.kind 'nas' needs both storage.networkPath and storage.networkUser."
        Exit-Setup 1
    }
}
# Where local shares live. Only consulted for storage.kind = local (including the
# NAS fallback); interactively New-LocalLabStorage asks and suggests a default.
$storageLocalRoot = [string](Get-Answer 'storage.localRoot')
$storageOnFailure = [string](Get-Answer 'storage.onFailure')
$storageOnFailureSource = if ($storageOnFailure) { 'answer file' } else { 'default -- never asked' }
if (-not $storageOnFailure) { $storageOnFailure = 'stop' }
if ($storageOnFailure -notin @('stop', 'local')) {
    Write-SetupError "storage.onFailure must be 'stop' or 'local' (got '$storageOnFailure')."
    Exit-Setup 1
}

$labName = ''
$labNameSource = ''
if ($isLab) {
    $labName = [string](Get-Answer 'lab.name')
    $labNameSource = Get-DecisionSource -FromAnswerFile ([bool]$labName)
    if (-not $labName) { $labName = Read-Text -Question 'Lab beacon name' -Default ([Environment]::MachineName.ToLowerInvariant()) }
}
# The 'default' pool is NOT asked about and has no answer-file key. A lab with no
# pool is a lab no host can be enrolled into, so "no" only ever produced a beacon
# that looked finished and enrolled nobody. The pool is DERIVED at the end of the
# run from the storage this run configured: whatever pool folder ended up in
# test.config.yml is inspected, and a 'default' pool is created there when the
# intent store carries none. An existing pool of that name is left exactly as it
# is (New-Pool -IfMissing), so an operator who paused or renamed theirs keeps it
# across every re-run.
#
# An older answer file may still carry lab.createDefaultPool. It is deliberately
# not read: honouring 'false' would produce that same half-set-up lab, and
# silently ignoring a key the operator wrote is worse than saying so.
if ($isLab -and $null -ne (Get-Answer 'lab.createDefaultPool')) {
    Write-SetupWarning ("lab.createDefaultPool in the answer file is obsolete and was ignored: the 'default' pool is now " +
                        'always ensured from the configured pool storage. Remove the key to silence this.')
}

# The resolved questionnaire, in one block, before any of it is acted on. The
# inline ANSWER lines above record each exchange as it happened; this records
# what the run is about to DO, which is what a later reader compares the machine
# against.
Write-SetupLogLine -Level 'PLAN' -Message 'Resolved answers:'
Add-SetupDecision -Name 'setup.type'              -Value $setupType          -Source $setupTypeSource
Add-SetupDecision -Name 'setup.runTests'          -Value $runTests           -Source $runTestsSource
Add-SetupDecision -Name 'setup.projectUrl'        -Value $projectUrl         -Source $projectUrlSource
Add-SetupDecision -Name 'storage.kind'            -Value $storageKind        -Source $storageKindSource
$localRootSource = if ($storageLocalRoot) { 'answer file' }
                   elseif ($storageKind -eq 'local') { 'not set -- New-LocalLabStorage will ask' }
                   else { "not needed -- storage.kind is '$storageKind'" }
# 'asked' is a claim, and it is only true where the questions are reachable: the
# NAS pair is never put to an operator who chose local or no storage at all.
$networkSource = if ($storageKind -ne 'nas') { "not asked -- storage.kind is '$storageKind'" }
                 else { Get-DecisionSource -FromAnswerFile $storageNetworkFromFile }
Add-SetupDecision -Name 'storage.localRoot'       -Value $storageLocalRoot   -Source $localRootSource
Add-SetupDecision -Name 'storage.networkPath'     -Value $storageNetworkPath -Source $networkSource
Add-SetupDecision -Name 'storage.networkUser'     -Value $storageNetworkUser -Source $networkSource
Add-SetupDecision -Name 'storage.onFailure'       -Value $storageOnFailure   -Source $storageOnFailureSource
if ($isLab) {
    Add-SetupDecision -Name 'lab.name'              -Value $labName -Source $labNameSource
    Add-SetupDecision -Name "lab pool 'default'"    -Value 'ensure' -Source 'always -- derived from the configured pool storage'
}

# --- REGION: 0. one authorization, then nothing may ask again
# The last point at which the operator still owns the terminal. Every step below
# runs with its output captured into the run log, and a prompt raised under
# capture is invisible: the question goes to a file while stdin stays the
# keyboard, so the run waits forever for a keystroke nobody knows to press. The
# credential is taken here, once, and the contract that forbids any later
# question is published into the environment every child inherits.
if (-not $WhatIfPreference) {
    $Script:ElevationOk = Initialize-SetupElevation -Reason @(
        'host settings -- display sleep, screen lock, power management',
        'local SMB shares and their mount points, when storage lives on this machine',
        'the hosts-file aliases that point ypool-nas / ystash-nas at this machine',
        'clearing state a previous sudo run left behind'
    )
    if ($Script:ElevationOk) { Start-SudoKeepAlive }
    # Published AFTER the prime so the prime itself is allowed to ask. From here
    # on Initialize-SudoCache declines silently and Invoke-YurunaSudo adds -n, so
    # a root operation that cannot proceed fails fast and says so instead of
    # stalling on a password prompt no one can see.
    $env:YURUNA_NONINTERACTIVE = '1'
    if ($Script:ElevationOk) { $env:YURUNA_SUDO_PRIMED = '1' }
    Write-SetupMessage ''
    Write-SetupMessage 'Setup processing:'
}

# --- REGION: 1. preflight checks
[void](Invoke-SetupStep -Name 'Preflight: pwsh, hypervisor, powershell-yaml, disk headroom' -Critical -Action {
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        throw "powershell-yaml is not installed. Run the bootstrapper first: install/$HostFolderName.*"
    }
    $home_ = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
    $freeGb = Get-FreeSpaceGb -Path $home_
    if ($null -eq $freeGb) {
        Write-SetupVerbose "disk headroom check: no mounted volume matched '$home_'; headroom not checked."
    } elseif ($freeGb -lt 40) {
        Write-SetupWarning "Only $freeGb GB free on the volume holding $home_ -- VM images need roughly 40 GB. Continuing."
    }
    Write-SetupDetail "host type: $HostType"
})

# --- REGION: 1b. what a previous `sudo` run left behind
# BEFORE anything is written, because two of the things this finds are what makes
# the writing fail. Refusing to run as root (above) stops the next root run; it
# does nothing about the machine an earlier one already changed, and that state
# does not announce itself -- it surfaces as a permission error on a runtime file
# or as a port that is unbindable with no visible holder, neither of which names
# sudo as the cause.
#
# Clearing it means chown/umount/rm/kill as root, so it is never done silently:
# an interactive run is asked per finding, and an unattended run stops with the
# exact commands instead. An answer file is consent to a setup, not to reaching
# into another account's processes and files.
if (-not $IsWindows) {
    [void](Invoke-SetupStep -Name 'Check for state left behind by a previous sudo run' -Critical -Action {
        Import-SetupModule (Join-Path $TestRoot 'modules/Test.RootArtifact.psm1')
        Import-SetupModule (Join-Path $TestRoot 'modules/Test.PortOwner.psm1')
        Import-SetupModule (Join-Path $TestRoot 'modules/Test.Config.psm1')

        # The CONFIGURED ports, so a checkout moved off the defaults is not
        # checked against ports it never uses.
        $ports = @(8080, 8443)
        try {
            if (Test-Path -LiteralPath $ConfigPath) {
                $cfg = Read-TestConfig -Path $ConfigPath -NoCache
                $statusPort = Get-TestConfigValue -Config $cfg -Path 'statusService.port'
                $configPort = Get-TestConfigValue -Config $cfg -Path 'configService.port'
                $ports = @($(if ($statusPort) { [int]$statusPort } else { 8080 }),
                           $(if ($configPort) { [int]$configPort } else { 8443 }))
            }
        } catch { Write-SetupVerbose "service-port read for the root sweep: $($_.Exception.Message)" }

        $found = @(Get-YurunaRootArtifact -RepoRoot $RepoRoot -Port $ports)
        if ($found.Count -eq 0) {
            Write-SetupDetail 'no root-owned yuruna state on this machine.'
            return
        }
        Write-YurunaRootArtifactReport -Artifact $found
        foreach ($a in $found) { Write-SetupLogLine -Level 'ROOT' -Message "$($a.Kind): $($a.Summary)" }

        if ($Script:Unattended) {
            $blocking = @($found | Where-Object { $_.Blocking })
            if ($blocking.Count -eq 0) {
                Write-SetupWarning 'Root-owned leftovers were found but none of them block this run; continuing. The block above lists them.'
                return
            }
            throw ("$($blocking.Count) root-owned leftover(s) block this run and an unattended run will not clear them " +
                   '(that means chown / umount / kill against another account). Run the commands listed above, or re-run ' +
                   'this script interactively to be asked about each one.')
        }

        foreach ($a in $found) {
            $question = '  {0} -- {1}?' -f $a.Summary, $(if ($a.Blocking) { 'Clear it now' } else { 'Remove it now' })
            $choice = Read-Choice -Question $question -Default $true -Option @(
                @{ Label = "Yes -- run the commands above with sudo (you may be prompted for your password)"; Value = $true }
                @{ Label = 'No -- leave it and continue'; Value = $false }
            )
            if (-not $choice) { continue }
            # -Confirm:$false: the question above IS the confirmation, and the
            # function's ConfirmImpact High would otherwise ask a second time for
            # the same decision.
            if (Clear-YurunaRootArtifact -Artifact $a -Confirm:$false) {
                Write-SetupDetail "cleared: $($a.Summary)"
            } else {
                Write-SetupWarning "could not clear: $($a.Summary). Run the commands listed above by hand."
            }
        }

        # Re-scan rather than trusting the clear results: an unmount that reported
        # success can still leave the point busy, and the question that matters is
        # what the machine looks like NOW.
        $left = @(Get-YurunaRootArtifact -RepoRoot $RepoRoot -Port $ports | Where-Object { $_.Blocking })
        if ($left.Count -gt 0) {
            throw ("$($left.Count) root-owned leftover(s) still block this run: " +
                   "$(($left | ForEach-Object { $_.Summary }) -join '; '). Clear them with the commands listed above and re-run.")
        }
    })
}

# --- REGION: 2. config
[void](Invoke-SetupStep -Name 'Create or refresh test/test.config.yml from the template' -Critical -AlreadyDone {
    # Only "already done" when the file exists AND the operator named no project
    # URL -- otherwise there is a change to apply.
    (Test-Path -LiteralPath $ConfigPath) -and -not $projectUrl
} -Action {
    Import-SetupModule (Join-Path $TestRoot 'modules/Test.ConfigSync.psm1')
    # test.config.yml.template -- NOT test.config.template.yml. Getting this
    # backwards silently disabled the refresh AND, on a machine with no
    # test.config.yml yet, killed the whole run on this -Critical step.
    $template = Join-Path $TestRoot 'test.config.yml.template'
    if (Test-Path -LiteralPath $template) {
        [void](Update-TestConfigFromTemplate -ConfigPath $ConfigPath -TemplatePath $template)
    } elseif (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "neither $ConfigPath nor its template ($template) exists"
    }
    if ($projectUrl) {
        # Line-level edit, deliberately: a full YAML round-trip through
        # ConvertTo-Yaml would drop this file's comments, which are most of its
        # documentation.
        $lines = Get-Content -LiteralPath $ConfigPath
        $hit = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^(\s*)projectUrl\s*:') {
                $lines[$i] = "$($Matches[1])projectUrl: $projectUrl"
                $hit = $true
                break
            }
        }
        if (-not $hit) { throw "no projectUrl key found in $ConfigPath to set" }
        Set-Content -LiteralPath $ConfigPath -Value $lines
        Write-SetupDetail "projectUrl -> $projectUrl"
    }
})

# --- REGION: 3. folders
[void](Invoke-SetupStep -Name 'Create the image, VM, log and runtime folders' -Action {
    $base = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
    foreach ($d in @(
        (Join-Path $base 'yuruna/image'),
        (Join-Path $base 'yuruna/vms'),
        (Join-Path $TestRoot 'status/log'),
        (Join-Path $TestRoot 'status/runtime')
    )) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
})

# --- REGION: 4. host settings
if ($runTests) {
    [void](Invoke-SetupStep -Name 'Configure host settings (Enable-TestAutomation -SkipPoolStorage)' -Action {
        # -SkipPoolStorage: setup.ps1 owns storage, in its own order, at step 5.
        # Without the switch Enable ends in an interactive NAS questionnaire,
        # which would both duplicate step 5 and stall an unattended run.
        [void](Invoke-RepoScript -Path (Join-Path $TestRoot 'Enable-TestAutomation.ps1') -Arguments @('-SkipPoolStorage'))
    })
} else {
    Add-SkippedStep -Description 'Host settings (this machine was declared services-only)'
}

# --- REGION: 5. storage
$storageConfigured = $false
if ($storageKind -eq 'none') {
    Add-SkippedStep -Description 'Shared storage, and with it the stash service (storage.kind = none)'
} elseif ($storageKind -eq 'local') {
    $ok = Invoke-SetupStep -Name 'Stand up local pool and stash shares (New-LocalLabStorage)' -AlreadyDone {
        Import-SetupModule (Join-Path $TestRoot 'modules/Test.PoolStorage.psm1')
        Import-SetupModule (Join-Path $TestRoot 'modules/Test.Config.psm1')
        $cfg = Read-TestConfig -Path $ConfigPath
        $pool = Get-YurunaPoolStorageConfig -Config $cfg -IgnoreReplicate -WarningAction SilentlyContinue
        if (-not ($pool -and $pool.LocalPath)) { return $false }
        # A mounted share is NOT enough to call this done. The config a machine
        # carries for a NAS is identical in every key to the config for shares on
        # this machine -- only the host alias differs -- so a machine still
        # pointed at a NAS reads as "already local" and keeps the storage, the
        # aliases and the credentials the operator just asked to replace. The
        # alias is the one thing that tells them apart.
        if (-not (Test-PoolStorageServerIsLocal -NetworkPath $pool.NetworkPath)) { return $false }
        [bool](Test-YurunaPoolStorageMounted -Config $pool)
    } -Action {
        $storageArgs = Get-LocalLabStorageArgument -LabName $labName -LocalRoot $storageLocalRoot -Unattended $Script:Unattended
        [void](Invoke-RepoScript -Path (Join-Path $TestRoot 'New-LocalLabStorage.ps1') -Arguments $storageArgs)
    }
    $storageConfigured = $ok
} else {
    $ok = Invoke-SetupStep -Name "Mount the NAS share $storageNetworkPath" -Action {
        Import-SetupModule (Join-Path $TestRoot 'modules/Test.PoolStorage.psm1')
        Import-SetupModule (Join-Path $TestRoot 'modules/Test.Config.psm1')
        # Sudoers FIRST on Linux: the mount runs `sudo -n` and fails outright
        # without the drop-in, which reads as an unreachable NAS.
        if ($IsLinux -and (Get-Command Set-PoolStorageSudoers -ErrorAction SilentlyContinue)) {
            [void](Set-PoolStorageSudoers -Confirm:$false)
        }
        $cfg  = Read-TestConfig -Path $ConfigPath
        $pool = Get-YurunaPoolStorageConfig -Config $cfg -IgnoreReplicate -WarningAction SilentlyContinue
        if (-not $pool) {
            throw "networkStorage.pool is not configured in $ConfigPath. Set networkPath ($storageNetworkPath), networkUser ($storageNetworkUser) and localPath there, then re-run."
        }
        if (-not (Connect-YurunaPoolStorage -Config $pool)) {
            throw "could not mount $storageNetworkPath"
        }
    }
    if (-not $ok) {
        # A NAS that cannot be mounted is ordinary -- it is down, or this
        # operator never had one. Neither should end a setup that is otherwise
        # complete, so offer real local shares rather than a degraded anything.
        $fallback = if ($Script:Unattended) { $storageOnFailure } else {
            Read-Choice -Question "The NAS $storageNetworkPath could not be mounted. What now?" -Default 'stop' -Option @(
                @{ Label = 'Stop here -- fix the NAS and re-run'; Value = 'stop' }
                @{ Label = 'Use local shares on this machine instead (a real lab others can join)'; Value = 'local' }
            )
        }
        if ($fallback -eq 'local') {
            $ok = Invoke-SetupStep -Name 'Fall back to local pool and stash shares (New-LocalLabStorage)' -Action {
                $storageArgs = Get-LocalLabStorageArgument -LabName $labName -LocalRoot $storageLocalRoot -Unattended $Script:Unattended
                [void](Invoke-RepoScript -Path (Join-Path $TestRoot 'New-LocalLabStorage.ps1') -Arguments $storageArgs)
            }
            $storageConfigured = $ok
            $storageKind = 'local'
        } else {
            Write-SetupReport
            Write-SetupError "Storage is not configured and storage.onFailure is 'stop'. Nothing further will run."
            Exit-Setup 1
        }
    } else {
        $storageConfigured = $true
    }
}

# --- REGION: 5b. hosts aliases -- standalone
# Standalone is the mode where nothing else owns these lines. A lab always stands
# up storage, and the local-storage script writes the aliases as part of it; a
# standalone host may decline storage entirely (storage.kind = none is
# standalone-only) or point at a NAS, and then no step in the run ever looks at
# the hosts file.
#
# What that costs: 'ypool-nas' is a NAME, and the same name means the NAS on a
# machine that used to have one and this machine on a machine that now serves its
# own shares. Every other value is identical between those two worlds -- share
# path, account, mount point -- so a stale line does not fail, it SUCCEEDS against
# the wrong server. The alias is the only thing that decides which, and this is
# where it is made to agree with the storage the operator just chose.
if (-not $isLab -and $storageKind -eq 'local') {
    [void](Invoke-SetupStep -Name 'Point the pool and stash aliases at this machine (hosts file)' -AlreadyDone {
        $tiers = @(Get-StorageAliasTier)
        if ($tiers.Count -eq 0) { return $false }
        foreach ($tier in $tiers) {
            if (-not (Test-PoolStorageServerIsLocal -NetworkPath $tier.NetworkPath)) { return $false }
        }
        return $true
    } -Action {
        $tiers = @(Get-StorageAliasTier)
        if ($tiers.Count -eq 0) {
            throw "no networkStorage server names are set in $ConfigPath, so there is no alias to point anywhere. Re-run the storage step first."
        }
        # Set-LocalLabStorageHostAlias, not a hosts-file edit of our own: it owns
        # the loopback address the local shares are published on, and the elevated
        # re-launch the hosts file needs on macOS and Linux.
        Import-SetupModule (Join-Path $TestRoot 'modules/Test.LocalLabStorage.psm1')
        $names = @($tiers | ForEach-Object { $_.Name })
        $written = Set-LocalLabStorageHostAlias -RepoRoot $RepoRoot -Name $names
        Write-SetupDetail "$written of $($names.Count) alias(es) rewritten: $($names -join ', ')"
    })
} elseif (-not $isLab) {
    # storage.kind nas / none. The right address is the operator's NAS, which this
    # script has no way to learn -- they gave a name, not an address. But a name
    # resolving to LOOPBACK is knowably wrong here: it is what a previous
    # local-storage run left behind, and it silently redirects the mount to this
    # machine. Reported rather than repaired, with the line to delete.
    [void](Invoke-SetupStep -Name 'Check the pool and stash aliases in the hosts file' -Action {
        $stale = @(Get-StorageAliasTier | Where-Object { Test-PoolStorageServerIsLocal -NetworkPath $_.NetworkPath })
        if ($stale.Count -eq 0) { return }
        $hostsFile = if ($IsWindows) { "$env:SystemRoot\System32\drivers\etc\hosts" } else { '/etc/hosts' }
        throw ("$(($stale | ForEach-Object { $_.Name }) -join ', ') still resolve(s) to this machine, which is left over from local " +
               "shares and would point the mount at this host instead of the NAS. Remove those line(s) from $hostsFile " +
               "(or run: pwsh automation/Set-HostAlias.ps1 -ComputerName <name>, with no -IPAddress, elevated) and re-run.")
    })
}

# --- REGION: 6. caching proxy
$proxyIp = ''
# The proxy's own bring-up adopts a healthy VM and takes -ForceRebuild. Stopping
# it first defeats that -- the adopt probe finds nothing left, so the re-run pays
# the full ~15-minute rebuild and discards a warm squid cache. So the teardown
# happens only when the reuse check (or -Rebuild) says the VM is not worth
# keeping, and -ForceRebuild is forwarded so the Start script does not re-adopt
# what setup just decided to replace.
# @(if ...) rather than $(if ... else { @() }): a branch that emits an empty
# array emits NO output, and the subexpression collapses to $null on the way
# into a [string[]] parameter -- which then appends an empty argv entry the
# child binds to its first positional parameter. The array-subexpression form
# yields a real empty array, so the not-rebuilding case passes no argument.
Invoke-ServiceVMEnsure -Service 'caching-proxy service' -RosterKey 'caching-proxy' -Critical `
    -StopScript 'Stop-CachingProxyServiceVM.ps1' -StartScript 'Start-CachingProxyServiceVM.ps1' `
    -StartArguments @(if ($Script:Rebuild) { '-ForceRebuild' })
if (-not $WhatIfPreference) {
    Import-SetupModule (Join-Path $TestRoot 'modules/Test.CachingProxyService.psm1')
    try {
        $state = Read-CachingProxyServiceState
        if ($state -and $state.ipAddress) { $proxyIp = [string]$state.ipAddress }
    } catch { Write-SetupVerbose "proxy state read: $($_.Exception.Message)" }
}

# --- REGION: 6b. aggregator readiness
# The gate that closes the "services never register" bug: the aggregator URL is
# baked into each dependent guest's seed ONCE, and an empty value there is never
# re-resolved for the life of that VM.
[void](Invoke-SetupStep -Name 'Wait for the pool-aggregator service to answer (up to 15 min)' -Critical -Action {
    $ready = if ($proxyIp) { Wait-YurunaAggregatorReady -ProxyAddress $proxyIp } else { Wait-YurunaAggregatorReady }
    if (-not $ready) {
        throw ("the pool-aggregator service did not become ready. Creating the stash or pool-control VM now would bake an " +
               "EMPTY aggregator URL into its seed, which never re-resolves -- the service would run but never appear on " +
               "the dashboard. Check it inside the proxy VM with 'journalctl -u pool-aggregator-service -n 50', then re-run this script.")
    }
})

# --- REGION: 7. stash service
if ($storageConfigured) {
    Invoke-ServiceVMEnsure -Service 'stash service' -RosterKey 'stash' `
        -StopScript 'Stop-StashServiceVM.ps1' -StartScript 'Start-StashServiceVM.ps1'
} else {
    Add-SkippedStep -Description 'Stash service (it exits 1 without configured storage)'
}

# --- REGION: 8. bind config to the local proxy
[void](Invoke-SetupStep -Name 'Point test.config.yml at this machine''s caching proxy' -AlreadyDone {
    if (-not $proxyIp) { return $false }
    (Get-Content -LiteralPath $ConfigPath -Raw) -match "(?m)^\s*cachingProxyIp\s*:\s*$([regex]::Escape($proxyIp))\s*$"
} -Action {
    if (-not $proxyIp) { throw 'the caching proxy VM did not report an IP address' }
    $lines = Get-Content -LiteralPath $ConfigPath
    $hit = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^(\s*)cachingProxyIp\s*:') {
            $lines[$i] = "$($Matches[1])cachingProxyIp: $proxyIp"
            $hit = $true
            break
        }
    }
    if (-not $hit) { throw "no vmStart.cachingProxyIp key found in $ConfigPath to set" }
    Set-Content -LiteralPath $ConfigPath -Value $lines
    Write-SetupDetail "cachingProxyIp -> $proxyIp"
})

# --- REGION: 9. validate
[void](Invoke-SetupStep -Name 'Validate the configuration (Test-Config gate)' -Action {
    Import-SetupModule (Join-Path $TestRoot 'modules/Test.ConfigPreflight.psm1')
    $gate = Invoke-ConfigGate -TestRoot $TestRoot -ConfigPath $ConfigPath -CallerName 'setup.ps1'
    if (-not $gate.passed) { throw "Test-Config reported failures (exit $($gate.exitCode)); the block above names them" }
})

# --- REGION: 9b. download-agent service
# Both modes: wherever there is a caching proxy there is an image pool worth
# sharing. Non-critical on purpose -- with no agent every Get-Image falls back
# to fetching from the origin, which is exactly the behavior without it.
$downloadAgentEnabled = $true
if (-not $WhatIfPreference) {
    try {
        Import-SetupModule (Join-Path $TestRoot 'modules/Test.Config.psm1')
        $daEnabled = Get-TestConfigValue -Config (Read-TestConfig -Path $ConfigPath -NoCache) -Path 'downloadAgentService.enabled'
        # An absent key reads as enabled. A hand-edited value can arrive as a
        # string, and [bool]'false' is $true -- the one coercion that would turn
        # an operator's opt-out into an opt-in.
        if ($daEnabled -is [bool]) {
            $downloadAgentEnabled = $daEnabled
        } elseif ($null -ne $daEnabled) {
            $downloadAgentEnabled = -not ("$daEnabled".Trim() -match '^(?i:false|0|no|off)$')
        }
    } catch { Write-SetupVerbose "downloadAgentService.enabled read: $($_.Exception.Message)" }
}
if (-not $downloadAgentEnabled) {
    Add-SkippedStep -Description 'Download-agent service (downloadAgentService.enabled is false)'
} elseif (-not $storageConfigured) {
    Add-SkippedStep -Description 'Download-agent service (it has no pool share to hold the images)'
} else {
    Invoke-ServiceVMEnsure -Service 'download-agent service' -RosterKey 'download-agent' `
        -StopScript 'Stop-DownloadAgentServiceVM.ps1' -StartScript 'Start-DownloadAgentServiceVM.ps1'
}

# --- REGION: 10-13. lab only
$intentGitUrl = ''
if ($isLab) {
    [void](Invoke-SetupStep -Name 'Enrol this machine into its own lab (Set-LabToken)' -Action {
        if (-not $proxyIp) { throw 'no caching-proxy address is known, so there is nothing to enrol against' }
        # The 6-char code rotates about once a minute, so it is read here rather
        # than asked for -- an operator could not type one fast enough to still
        # be valid. /metrics is open by design (the dashboard shows the same
        # value) and this read is beacon-local.
        $code = ''
        foreach ($scheme in @('https', 'http')) {
            try {
                $metrics = Invoke-WebRequest -Uri "${scheme}://${proxyIp}:9400/metrics" -TimeoutSec 10 -SkipCertificateCheck -SkipHttpErrorCheck -ErrorAction Stop
                if ([int]$metrics.StatusCode -ge 200 -and [int]$metrics.StatusCode -lt 300 -and
                    "$($metrics.Content)" -match 'yuruna_pool_lab_token\{[^}]*token="([^"]+)"') {
                    $code = $Matches[1]
                    break
                }
            } catch { Write-SetupVerbose "metrics read over ${scheme}: $($_.Exception.Message)" }
        }
        if (-not $code) { throw "could not read the lab token from ${proxyIp}:9400/metrics; the dashboard's 'Lab token' tile shows it, and 'pwsh test/Set-LabToken.ps1 -LabToken <code> -CachingProxyService $proxyIp -BounceStatusService' finishes this step" }
        [void](Invoke-RepoScript -Path (Join-Path $TestRoot 'Set-LabToken.ps1') `
            -Arguments @($code, '-CachingProxyService', $proxyIp, '-BounceStatusService', '-NonInteractive'))
    })

    # Always, and derived rather than asked: the intent store lives on whatever
    # pool storage this run actually ended up with, so it is read back out of
    # test.config.yml here instead of being predicted from the questionnaire. A
    # run that fell back from an unreachable NAS to local shares lands on the
    # local path for the same reason.
    [void](Invoke-SetupStep -Name "Ensure the lab's 'default' pool exists" -Action {
        Import-SetupModule (Join-Path $TestRoot 'modules/Test.PoolStorage.psm1')
        Import-SetupModule (Join-Path $TestRoot 'modules/Test.Config.psm1')
        $cfg  = Read-TestConfig -Path $ConfigPath -NoCache
        $pool = Get-YurunaPoolStorageConfig -Config $cfg -IgnoreReplicate -WarningAction SilentlyContinue
        if (-not $pool -or -not $pool.LocalPath) { throw 'pool storage has no localPath, so the intent store has nowhere to live' }
        # The WRITABLE local path through the mount. The http:// URL apache
        # serves is read-only by design and push-fails; without an explicit
        # writable URL New-Pool exits "No intent store URL".
        $script:intentGitUrl = Join-Path $pool.LocalPath 'pool-intent.git'
        # -IfMissing: this step runs on every re-run, and a plain upsert would
        # reset a pool the operator had set to 'paused' or 'drain' back to 'run'
        # each time. New-Pool seeds the bare store itself when the pool folder
        # carries none yet, so a NAS tier that never ran New-Lab works here too.
        [void](Invoke-RepoScript -Path (Join-Path $TestRoot 'New-Pool.ps1') `
            -Arguments @('-PoolId', 'default', '-IfMissing', '-IntentGitUrl', $script:intentGitUrl))
    })

    [void](Invoke-SetupStep -Name 'Validate the pool intent store' -Action {
        if (-not $intentGitUrl) { throw 'no intent store URL was resolved' }
        [void](Invoke-RepoScript -Path (Join-Path $TestRoot 'Test-PoolIntent.ps1') -Arguments @('-IntentGitUrl', $intentGitUrl))
    })

    # LAST of the lab steps, and after the intent store exists. The pool-control
    # daemon serves that store and points the caching proxy's read-only
    # /pool-intent.git route at it as it comes up, so a bring-up ordered ahead of
    # New-Pool builds a UI against a store that is not there yet and publishes an
    # alias to nothing. It is also the longest step by far -- the daemon is
    # compiled inside the guest -- so putting the quick, always-needed enrolment
    # and pool steps ahead of it means a run that dies here still leaves a lab
    # that is joinable and has its pool.
    Invoke-ServiceVMEnsure -Service 'pool-control service' -RosterKey 'pool-control' `
        -StopScript 'Stop-PoolControlServiceVM.ps1' -StartScript 'Start-PoolControlServiceVM.ps1'
}

# --- REGION: -WhatIf stops here
if ($WhatIfPreference) {
    Write-SetupMessage ''
    Write-SetupMessage "Planned tasks for a $setupType setup on $HostFolderName :"
    foreach ($p in $Script:Plan) { Write-SetupMessage "  $p" }
    Write-SetupMessage ''
    Write-SetupMessage 'Nothing was changed (-WhatIf).'
    if ($Script:LogFile) { Write-SetupMessage "Log: $Script:LogFile" }
    Exit-Setup 0
}

# --- REGION: write the answer file this run used
$answerOut = Join-Path $RepoRoot "install/setup.answers.$setupType.yml"
if (-not $AnswerFile) {
    try {
        $doc = [ordered]@{
            setup = [ordered]@{ type = $setupType; runTests = $runTests; projectUrl = "$projectUrl" }
            storage = [ordered]@{ kind = $storageKind; localRoot = "$storageLocalRoot"; networkPath = "$storageNetworkPath"; networkUser = "$storageNetworkUser"; onFailure = $storageOnFailure }
        }
        # No createDefaultPool key: the pool is ensured on every run, so writing
        # one would re-introduce a setting that the next run ignores.
        if ($isLab) { $doc['lab'] = [ordered]@{ name = $labName } }
        Import-YamlModule
        ConvertTo-Yaml $doc | Set-Content -LiteralPath $answerOut -Encoding utf8
        Write-SetupMessage ''
        Write-SetupMessage "Answers written to $answerOut -- pass it with -AnswerFile to set up the next machine the same way."
    } catch {
        # A WARNING, not a verbose note. The operator has just answered a
        # questionnaire believing the answers were kept for the next machine, and
        # a note nobody sees at the default log level leaves them holding a file
        # that does not exist. The usual cause is the file already being there
        # owned by root, from a run that was started with sudo.
        Write-SetupWarning "Could not write the answer file $answerOut ($($_.Exception.Message)). This run is unaffected, but there is no answer file to set up the next machine with. If it exists and is owned by root, remove it (sudo rm '$answerOut') and re-run."
    }
}

# --- REGION: report
Write-SetupReport

# A non-critical step that failed still leaves the run here. Saying "ready" and
# exiting 0 over a Failed list is the same defect this whole feature exists to
# prevent -- green while broken -- and a CI caller reading only the exit code
# would never learn otherwise. So the banner and the exit code both tell the
# truth, and the run still reports everything it DID manage.
$hadFailures = ($Script:Failed.Count -gt 0)
Write-SetupMessage ''
if ($hadFailures) {
    Write-SetupWarning "$($Script:Failed.Count) step(s) failed -- this machine is NOT fully set up. The Failed list above names each one."
    Write-SetupMessage 'Fix what it names and re-run this script: completed steps detect themselves and are skipped.'
}

if ($isLab) {
    Write-SetupMessage $(if ($hadFailures) { "Lab `"$labName`" is INCOMPLETE -- see the failures above." } else { "Lab `"$labName`" is ready. This machine is the lab beacon." })
    if ($proxyIp) {
        Write-SetupMessage ''
        Write-SetupMessage 'To join another machine: read the Lab token tile on the dashboard'
        Write-SetupMessage "  http://${proxyIp}:3000"
        Write-SetupMessage 'then run THERE (the code rotates every minute, so read it at the time):'
        Write-SetupMessage "  pwsh test/Set-LabToken.ps1 -CachingProxyService $proxyIp -LabToken <code from the tile>"
    }
    if ($storageKind -eq 'local') {
        Write-SetupMessage ''
        Write-SetupMessage 'This lab uses LOCAL shares on this machine. That is a real lab others can join,'
        Write-SetupMessage 'with two consequences worth knowing:'
        Write-SetupMessage '  - this machine is now the single point of failure for the pool storage;'
        Write-SetupMessage "  - 'ypool-nas' and 'ystash-nas' map to loopback here, so each joining host needs"
        Write-SetupMessage '    a hosts-file entry pointing those names at this machine, plus the share credential.'
        Write-SetupMessage 'Moving to a NAS later is a re-run of the storage step, not a rebuild.'
    }
    Write-SetupMessage ''
    Write-SetupMessage 'The auto-enrolment sweep is NOT on. Two steps turn it on when you want it:'
    Write-SetupMessage '  1. add autoEnrollment: { enabled: true, targetPoolId: default } to pools.yml in the intent store'
    Write-SetupMessage '  2. start the pool-control daemon with --auto-enrol'
    Write-SetupMessage "Until (1) is written, the 'target pool carries no test-set' guard is not armed for"
    Write-SetupMessage "a pool merely NAMED default -- the guard binds to autoEnrollment.targetPoolId."
} else {
    Write-SetupMessage $(if ($hadFailures) { 'Standalone host is INCOMPLETE -- see the failures above.' } else { 'Standalone host is ready.' })
    if (-not $hadFailures) {
        Write-SetupMessage ''
        Write-SetupMessage 'Next:'
        Write-SetupMessage '  pwsh test/Invoke-TestRunner.ps1'
    }
}
Write-DashboardHint -ProxyIp $proxyIp
Write-SetupMessage ''

# The config gate is deliberately non-critical -- a validation failure should not
# throw away a proxy VM that came up correctly -- but it must not be reported as
# success either.
Exit-Setup $(if ($hadFailures) { 1 } else { 0 })
