<#PSScriptInfo
.VERSION 2026.08.02
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

    The service VMs are deliberately never "already true". Every run stops and
    removes the caching-proxy service, and the stash and pool-control services
    it is about to start, then builds them fresh. That is what lets a re-run
    APPLY a change instead of preserving the very thing the change was meant to
    replace -- and it is what keeps a start from failing over a half-removed VM
    the last run left registered. Budget for it: rebuilding the proxy is roughly
    15 minutes.

    LOGGED. Every run writes test/status/log/setup.<yyyy.MM.dd.HH.mm>.log: each
    question, the answer taken and where it came from, each step and its outcome,
    each child script's command line and exit code, and the closing report. A
    setup run is long and mostly unattended in the middle, so by the time anyone
    asks what it did the console is usually gone. The output of the child scripts
    themselves stays on the console -- see Invoke-RepoScript for why capturing it
    would make their prompts invisible.

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
          createDefaultPool: true

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
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$AnswerFile = '',
    [string]$LogPath = ''
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
# Several preflight probes read a native command's exit code as the ANSWER
# ("is libvirtd running?"), not as a failure. Pinned so an ambient preference
# cannot turn those into terminating errors.
$PSNativeCommandUseErrorActionPreference = $false

$RepoRoot = Split-Path -Parent $PSScriptRoot
$TestRoot = Join-Path $RepoRoot 'test'
$ConfigPath = Join-Path $TestRoot 'test.config.yml'

# The project repo a setup run points test.config.yml at. Not asked: every run
# that does not say otherwise should land on the same known-good project, so a
# fresh machine is testable without the operator knowing the URL. Change this
# one line to retarget every future run; an answer file's setup.projectUrl still
# wins per-run, and '' there keeps whatever test.config.yml already has.
$DefaultProjectUrl = 'https://github.com/alissonsol/yuruna-project'

# --- REGION: run log
# Every question asked, every answer taken and every message printed also lands
# in test/status/log/setup.<yyyy.MM.dd.HH.mm>.log. A setup run is long, mostly
# unattended in the middle, and the interesting part is usually gone from the
# scrollback by the time anyone looks -- so the record outlives the console.
#
# What is NOT here: the output of the repo scripts this one starts. They inherit
# this terminal by design (see Invoke-RepoScript) and capturing them would make
# their prompts invisible. The log records each one's command line and exit code
# instead, which is what says WHICH child a run died in.
$Script:LogFile = ''

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
            ('user        : {0}{1}' -f [Environment]::UserName, $elevated)
            ('machine     : {0}' -f [Environment]::MachineName)
            ('pwsh        : {0} on {1}' -f $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString)
            $(if ($WhatIfPreference) { 'mode        : -WhatIf preview -- nothing will be changed' })
            '========================================================'
        ) | Where-Object { $null -ne $_ }
        Add-Content -LiteralPath $target -Value $header -Encoding utf8 -WhatIf:$false
        $Script:LogFile = $target
    } catch {
        $Script:LogFile = ''
        Write-Warning "Setup log could not be opened at $target ($($_.Exception.Message)); this run is console-only."
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
            # Write-Information plus an explicit log level, rather than
            # Write-SetupMessage: step boundaries are what a log is scanned for,
            # and a level of their own is what makes them filterable. Routing the
            # same text through both would only duplicate it.
            Write-Information "  [skip] $Name -- already done."
            Add-SkippedStep -Description "$Name (already done)" -Quiet
            return $true
        }
    }

    Write-SetupMessage ''
    Write-Information "==> $Name"
    Write-SetupLogLine -Level 'STEP' -Message $Name
    try {
        & $Action
        $Script:Done.Add($Name)
        Write-SetupLogLine -Level 'DONE' -Message $Name
        return $true
    } catch {
        $message = $_.Exception.Message
        if ($Critical) {
            $Script:Failed.Add("$Name -- $message")
            # Report BEFORE the error: this is the last thing the run will do, and
            # the list of what did succeed is what the next attempt starts from.
            Write-SetupReport
            Write-SetupError "$Name failed: $message"
            Exit-Setup 1
        }
        $Script:Failed.Add("$Name -- $message")
        Write-SetupWarning "$Name failed: $message"
        return $false
    }
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

    THE CHILD INHERITS THIS CONSOLE. Started through ProcessStartInfo with no
    redirection, so its stdout and stdin are this terminal's -- not a pipe.

    `& pwsh ...` cannot be used here. PowerShell captures a native command's
    output whenever something downstream consumes it, and every call site is
    consumed: the exit code is read, and the enclosing step's result is
    assigned. The child's every line then lands in a pipeline nobody prints.
    The operator sees a script that has produced nothing for minutes, and a
    child that stops at a Read-Host stops INVISIBLY -- the prompt is captured
    with everything else, so the run looks hung until someone presses Enter at
    a question they were never shown. Both the storage script's consent prompt
    and its "where should storage live?" question are exactly that.

    ArgumentList (not a joined string) so each argument reaches the child as one
    argv entry: a storage root or lab name carrying a space must not be re-split
    on the way in -- the legacy-quoting regression class.
#>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Arguments = @(),
        [switch]$TolerateFailure
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "script not found: $Path" }
    $leaf = [IO.Path]::GetFileName($Path)
    Write-SetupMessage "    $leaf $($Arguments -join ' ')"
    # The child's own output never reaches the log -- it is written straight to
    # this console -- so its command line and exit code are what tie a run's
    # failure to the script it happened in.
    Write-SetupLogLine -Level 'EXEC' -Message "$Path $($Arguments -join ' ')"
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Get-CurrentPwshPath
    # UseShellExecute stays false: on .NET it is what makes the child inherit
    # the parent's standard handles rather than being given a new console.
    $startInfo.UseShellExecute = $false
    foreach ($argument in (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Path) + $Arguments)) {
        [void]$startInfo.ArgumentList.Add($argument)
    }
    $code = 1
    $process = $null
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $process.WaitForExit()
        $code = $process.ExitCode
    } finally {
        if ($process) { $process.Dispose() }
    }
    Write-SetupLogLine -Level 'EXIT' -Message "$leaf exited $code"
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
    Every run tears down the service VMs it is about to start rather than
    building over whatever the last run left. Two things make this the setup's
    job and not the Start scripts':

    The stash and pool-control Starts delegate to a per-host New-VM.ps1 that
    deletes the VM's bundle/disk directory in place and never unregisters the VM
    from the hypervisor. Rebuilding over a still-registered VM leaves the
    hypervisor holding a registration whose files are gone, and the start that
    follows fails on a VM it believes it already has. The Stop scripts
    unregister first, which is the whole difference.

    The caching proxy is ADOPTED whenever its health probe passes -- the
    fast path that skips a ~15-minute rebuild, and the one outcome a re-run
    cannot use, because an adopted VM keeps the base image, the seed and the
    baked configuration the re-run exists to replace. Stopping it first also
    clears an abandoned bring-up lock; a Start refuses to take that over on its
    own and stops the run instead.

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
    Import-Module (Join-Path $TestRoot 'modules/Test.PoolStorage.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $TestRoot 'modules/Test.Config.psm1') -Force -DisableNameChecking
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
    -WhatIf.
.DESCRIPTION
    powershell-yaml creates two aliases at import, and New-Alias supports
    ShouldProcess -- so a preview run prints "What if: New Alias" twice before
    the task list it was actually asked for. The preference has to be cleared in
    the GLOBAL scope: a module's top-level code resolves preference variables up
    the module/global chain, not through the caller's dynamic scope, so setting
    it locally (or in a child scope) has no effect.
#>
    $prior = $global:WhatIfPreference
    try {
        $global:WhatIfPreference = $false
        Import-Module powershell-yaml -Verbose:$false
    } finally {
        $global:WhatIfPreference = $prior
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
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.HostRedirect.psm1') -Force -DisableNameChecking
# Test.HostDetection directly: Yuruna.HostRedirect keeps its own
# Import-HostDetectionModule private, and Get-HostType / Get-HostFolder are what
# this needs.
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostDetection.psm1') -Force -DisableNameChecking
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
$createDefaultPool = $false
$createDefaultPoolSource = ''
if ($isLab) {
    $labName = [string](Get-Answer 'lab.name')
    $labNameSource = Get-DecisionSource -FromAnswerFile ([bool]$labName)
    if (-not $labName) { $labName = Read-Text -Question 'Lab beacon name' -Default ([Environment]::MachineName.ToLowerInvariant()) }
    $poolAnswer = Get-Answer 'lab.createDefaultPool'
    $createDefaultPoolSource = Get-DecisionSource -FromAnswerFile ($null -ne $poolAnswer)
    $createDefaultPool = if ($null -ne $poolAnswer) { [bool]$poolAnswer } else {
        (Read-Choice -Question "Create the 'default' pool?" -Default $true -Option @(
            @{ Label = 'Yes'; Value = $true }
            @{ Label = 'No'; Value = $false }
        ))
    }
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
    Add-SetupDecision -Name 'lab.name'              -Value $labName           -Source $labNameSource
    Add-SetupDecision -Name 'lab.createDefaultPool' -Value $createDefaultPool -Source $createDefaultPoolSource
}

# --- REGION: 1. preflight checks
[void](Invoke-SetupStep -Name 'Preflight: pwsh, hypervisor, powershell-yaml, disk headroom' -Critical -Action {
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        throw "powershell-yaml is not installed. Run the bootstrapper first: install/$HostFolderName.*"
    }
    $home_ = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
    try {
        $drive = Get-PSDrive -Name (Split-Path -Qualifier $home_).TrimEnd(':') -ErrorAction SilentlyContinue
        if ($drive -and $drive.Free -and $drive.Free -lt 40GB) {
            Write-SetupWarning "Only $([Math]::Round($drive.Free / 1GB, 1)) GB free on $($drive.Name): -- VM images need roughly 40 GB. Continuing."
        }
    } catch { Write-SetupVerbose "disk headroom check: $($_.Exception.Message)" }
    Write-SetupMessage "    host type: $HostType"
})

# --- REGION: 2. config
[void](Invoke-SetupStep -Name 'Create or refresh test/test.config.yml from the template' -Critical -AlreadyDone {
    # Only "already done" when the file exists AND the operator named no project
    # URL -- otherwise there is a change to apply.
    (Test-Path -LiteralPath $ConfigPath) -and -not $projectUrl
} -Action {
    Import-Module (Join-Path $TestRoot 'modules/Test.ConfigSync.psm1') -Force -DisableNameChecking
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
        Write-SetupMessage "    projectUrl -> $projectUrl"
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
        Import-Module (Join-Path $TestRoot 'modules/Test.PoolStorage.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $TestRoot 'modules/Test.Config.psm1') -Force -DisableNameChecking
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
        Import-Module (Join-Path $TestRoot 'modules/Test.PoolStorage.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $TestRoot 'modules/Test.Config.psm1') -Force -DisableNameChecking
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
        Import-Module (Join-Path $TestRoot 'modules/Test.LocalLabStorage.psm1') -Force -DisableNameChecking
        $names = @($tiers | ForEach-Object { $_.Name })
        $written = Set-LocalLabStorageHostAlias -RepoRoot $RepoRoot -Name $names
        Write-SetupMessage "    $written of $($names.Count) alias(es) rewritten: $($names -join ', ')"
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
Invoke-ServiceVMReset -Service 'caching-proxy service' -StopScript 'Stop-CachingProxyServiceVM.ps1'
[void](Invoke-SetupStep -Name 'Start the caching-proxy service VM' -Critical -Action {
    [void](Invoke-RepoScript -Path (Join-Path $TestRoot 'Start-CachingProxyServiceVM.ps1'))
})
if (-not $WhatIfPreference) {
    Import-Module (Join-Path $TestRoot 'modules/Test.CachingProxyService.psm1') -Force -DisableNameChecking
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
    Invoke-ServiceVMReset -Service 'stash service' -StopScript 'Stop-StashServiceVM.ps1'
    [void](Invoke-SetupStep -Name 'Start the stash service VM' -Action {
        [void](Invoke-RepoScript -Path (Join-Path $TestRoot 'Start-StashServiceVM.ps1'))
    })
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
    Write-SetupMessage "    cachingProxyIp -> $proxyIp"
})

# --- REGION: 9. validate
[void](Invoke-SetupStep -Name 'Validate the configuration (Test-Config gate)' -Action {
    Import-Module (Join-Path $TestRoot 'modules/Test.ConfigPreflight.psm1') -Force -DisableNameChecking
    $gate = Invoke-ConfigGate -TestRoot $TestRoot -ConfigPath $ConfigPath -CallerName 'setup.ps1'
    if (-not $gate.passed) { throw "Test-Config reported failures (exit $($gate.exitCode)); the block above names them" }
})

# --- REGION: 10-13. lab only
$intentGitUrl = ''
if ($isLab) {
    Invoke-ServiceVMReset -Service 'pool-control service' -StopScript 'Stop-PoolControlServiceVM.ps1'
    [void](Invoke-SetupStep -Name 'Start the pool-control service VM' -Action {
        [void](Invoke-RepoScript -Path (Join-Path $TestRoot 'Start-PoolControlServiceVM.ps1'))
    })

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

    if ($createDefaultPool) {
        [void](Invoke-SetupStep -Name "Create the 'default' pool" -Action {
            Import-Module (Join-Path $TestRoot 'modules/Test.PoolStorage.psm1') -Force -DisableNameChecking
            Import-Module (Join-Path $TestRoot 'modules/Test.Config.psm1') -Force -DisableNameChecking
            $cfg  = Read-TestConfig -Path $ConfigPath
            $pool = Get-YurunaPoolStorageConfig -Config $cfg -IgnoreReplicate -WarningAction SilentlyContinue
            if (-not $pool -or -not $pool.LocalPath) { throw 'pool storage has no localPath, so the intent store has nowhere to live' }
            # The WRITABLE local path through the mount. The http:// URL apache
            # serves is read-only by design and push-fails; without an explicit
            # writable URL New-Pool exits "No intent store URL".
            $script:intentGitUrl = Join-Path $pool.LocalPath 'pool-intent.git'
            [void](Invoke-RepoScript -Path (Join-Path $TestRoot 'New-Pool.ps1') `
                -Arguments @('-PoolId', 'default', '-IntentGitUrl', $script:intentGitUrl))
        })

        [void](Invoke-SetupStep -Name 'Validate the pool intent store' -Action {
            if (-not $intentGitUrl) { throw 'no intent store URL was resolved' }
            [void](Invoke-RepoScript -Path (Join-Path $TestRoot 'Test-PoolIntent.ps1') -Arguments @('-IntentGitUrl', $intentGitUrl))
        })
    } else {
        Add-SkippedStep -Description "The 'default' pool (not requested)"
    }
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
        if ($isLab) { $doc['lab'] = [ordered]@{ name = $labName; createDefaultPool = $createDefaultPool } }
        Import-YamlModule
        ConvertTo-Yaml $doc | Set-Content -LiteralPath $answerOut -Encoding utf8
        Write-SetupMessage ''
        Write-SetupMessage "Answers written to $answerOut -- pass it with -AnswerFile to set up the next machine the same way."
    } catch {
        Write-SetupVerbose "could not write the answer file: $($_.Exception.Message)"
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
Write-SetupMessage ''

# The config gate is deliberately non-critical -- a validation failure should not
# throw away a proxy VM that came up correctly -- but it must not be reported as
# success either.
Exit-Setup $(if ($hadFailures) { 1 } else { 0 })
