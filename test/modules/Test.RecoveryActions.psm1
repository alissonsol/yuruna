<#PSScriptInfo
.VERSION 2026.10.18.1
.GUID 424332a3-0599-4bf6-b2b3-ef2842f9fe93
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test recovery actions git-lock reclone failure-pause
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
    The three repairs the runner may make on its own, registered on the recovery
    ledger.
.DESCRIPTION
    Each repair is small, idempotent and takes no action beyond a bounded git
    command, the runner's own project clone, or ending a wait early. They are
    registered in the order they should be tried:

      clear_stale_git_lock    A killed git leaves .git/index.lock (and a few
                              siblings) that fail every later pull or clone with
                              "File exists". Old locks are moved, never deleted,
                              into <runtime>/recovery.quarantine/<attemptId>/.
      reclone_project         Retry the project clone now, with its health check,
                              instead of waiting out the failure pause.
      end_failure_pause_early The failure classes the remediation dispatcher
                              already treats as clearly safe to retry end the
                              pause early.

    The context a repair receives carries RepoRoot, ProjectDir, ProjectUrl,
    ConfigPath and RuntimeDir, besides what the ledger adds. A test can replace
    each outside dependency by putting a scriptblock under the key named for it:

      UpdateProjectClone      -RepoRoot -ProjectUrl, returns the clone result
                              (success, skipped, errorMessage, revision)
      TestProjectCloneHealth  -Path, returns an object with Healthy and Reason
      RestoreProjectCloneSwap -RepoRoot, returns the actions it took
      GitStatusProbe          -RepoPath, returns ExitCode and Output
      GitProcessProbe         no arguments, returns $true when git is running

    Without an override the real command is used: Update-ProjectClone,
    Test-ProjectCloneHealth and Restore-ProjectCloneSwap from Test.HostGit, loaded
    on first use, and a bounded git status for the probe.
#>

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.RecoveryContract.psm1') -DisableNameChecking -Global
Import-Module (Join-Path $PSScriptRoot 'Test.RecoveryLedger.psm1') -Force -DisableNameChecking -Global

# --- REGION: Constants
# A lock younger than this may belong to a git that is still working.
$script:StaleLockMinutes = 10
$script:StatusTimeoutSeconds = 30
$script:QuarantineDirName = 'recovery.quarantine'
# Directory levels searched below .git/refs; branch names with slashes nest.
$script:RefsLockDepth = 3

# --- REGION: Context helpers
function Get-RecoveryValueText {
    <#
    .SYNOPSIS
        A field of a dictionary or object as text, or '' when it has none.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]$Source,
        [Parameter(Mandatory)][string]$Key
    )
    if ($Source -is [System.Collections.IDictionary]) {
        if ($Source.Contains($Key) -and $null -ne $Source[$Key]) { return [string]$Source[$Key] }
        return ''
    }
    if ($null -ne $Source -and $null -ne $Source.PSObject.Properties[$Key] -and $null -ne $Source.PSObject.Properties[$Key].Value) {
        return [string]$Source.PSObject.Properties[$Key].Value
    }
    return ''
}

function Get-RecoveryContextNow {
    <#
    .SYNOPSIS
        The moment a repair measures ages against: Context.Now when a caller pinned
        it, otherwise the current time.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param([AllowNull()]$Context)
    if ($Context -is [System.Collections.IDictionary] -and $Context.Contains('Now') -and $Context['Now'] -is [datetime]) {
        return $Context['Now'].ToUniversalTime()
    }
    return [datetime]::UtcNow
}

function Get-RecoveryProjectDir {
    <#
    .SYNOPSIS
        The project checkout: Context.ProjectDir, else <RepoRoot>/project.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Context)
    $dir = Get-RecoveryValueText -Source $Context -Key 'ProjectDir'
    if ($dir) { return $dir }
    $root = Get-RecoveryValueText -Source $Context -Key 'RepoRoot'
    if ($root) { return (Join-Path $root 'project') }
    return ''
}

function Get-RecoveryRepoTarget {
    <#
    .SYNOPSIS
        The repositories a git repair may touch, each with the label that names it
        in the quarantine: the framework checkout and the project checkout.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([AllowNull()]$Context)
    $targets = [Collections.Generic.List[object]]::new()
    $framework = Get-RecoveryValueText -Source $Context -Key 'RepoRoot'
    if ($framework) { $targets.Add([pscustomobject]@{ Label = 'framework'; Path = $framework }) }
    $project = Get-RecoveryProjectDir -Context $Context
    if ($project) { $targets.Add([pscustomobject]@{ Label = 'project'; Path = $project }) }
    return @($targets)
}

function Get-RecoveryQuarantinePath {
    <#
    .SYNOPSIS
        Where this attempt's quarantined locks live.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Context)
    $runtime = Get-RecoveryValueText -Source $Context -Key 'RuntimeDir'
    $attempt = Get-RecoveryValueText -Source $Context -Key 'AttemptId'
    return (Join-Path (Join-Path $runtime $script:QuarantineDirName) $attempt)
}

# --- REGION: Stale git locks
function Find-StaleGitLock {
    <#
    .SYNOPSIS
        The *.lock files in a repository's .git that are old enough to have been
        left by a killed git.
    .DESCRIPTION
        Looks directly in .git and in .git/refs down to three directory levels,
        where git keeps index.lock, HEAD.lock, packed-refs.lock and the ref locks.
        Only regular files count: a directory that happens to be named like a lock
        is not one. A repository whose .git is a file -- a linked worktree or a
        submodule pointer -- keeps its locks elsewhere, so it yields nothing rather
        than a guess.
    .PARAMETER MinAgeMinutes
        A lock must be older than this to be reported.
    .PARAMETER Now
        For tests; defaults to the current time.
    .OUTPUTS
        Objects with Path, RelativePath (to the repository, with forward slashes)
        and AgeMinutes, ordered by RelativePath. Wrap the call in @(...).
    #>
    [CmdletBinding()]
    [OutputType([object[]], [pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [ValidateRange(0, 10080)][int]$MinAgeMinutes = $script:StaleLockMinutes,
        [datetime]$Now
    )
    $nowUtc = if ($PSBoundParameters.ContainsKey('Now')) { $Now.ToUniversalTime() } else { [datetime]::UtcNow }
    $gitDir = Join-Path $RepoPath '.git'
    if (-not (Test-Path -LiteralPath $gitDir -PathType Container)) { return @() }
    $candidates = [Collections.Generic.List[IO.FileInfo]]::new()
    foreach ($item in @(Get-ChildItem -LiteralPath $gitDir -Filter '*.lock' -File -Force -ErrorAction SilentlyContinue)) { $candidates.Add($item) }
    $refs = Join-Path $gitDir 'refs'
    if (Test-Path -LiteralPath $refs -PathType Container) {
        foreach ($item in @(Get-ChildItem -LiteralPath $refs -Filter '*.lock' -File -Recurse -Depth $script:RefsLockDepth -Force -ErrorAction SilentlyContinue)) { $candidates.Add($item) }
    }
    $root = [IO.Path]::GetFullPath($RepoPath)
    $found = foreach ($file in $candidates) {
        $age = ($nowUtc - $file.LastWriteTimeUtc).TotalMinutes
        if ($age -le $MinAgeMinutes) { continue }
        [pscustomobject]@{
            Path         = $file.FullName
            RelativePath = ([IO.Path]::GetRelativePath($root, $file.FullName) -replace '\\', '/')
            AgeMinutes   = [math]::Round($age, 1)
        }
    }
    return @($found | Sort-Object -Property RelativePath)
}

function Get-RecoveryGitProcess {
    <#
    .SYNOPSIS
        The running git processes. Split out so a test can supply any answer.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return @([Diagnostics.Process]::GetProcessesByName('git'))
}

function Test-GitProcessRunning {
    <#
    .SYNOPSIS
        Whether a git process is running on this machine.
    .DESCRIPTION
        Moving a lock out from under a live git corrupts what it was about to
        commit, so a process list that cannot be read answers $true: not knowing is
        not permission. A git that stays resident on purpose -- the file system
        monitor daemon -- also answers $true, which only ever withholds a repair.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    try {
        $processes = @(Get-RecoveryGitProcess)
    } catch {
        Write-Verbose "Test-GitProcessRunning: the process list cannot be read, so git is assumed to be running: $($_.Exception.Message)"
        return $true
    }
    foreach ($process in $processes) {
        if ($process -is [IDisposable]) { $process.Dispose() }
    }
    return ($processes.Count -gt 0)
}

function Test-RecoveryGitRunning {
    <#
    .SYNOPSIS
        Whether git is running, by the context's probe when it carries one.
    .DESCRIPTION
        Only an explicit $false from a probe means "not running"; no answer, or an
        answer that is not a boolean, is read as running.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()]$Context)
    $probe = if ($Context -is [System.Collections.IDictionary] -and $Context.Contains('GitProcessProbe')) { $Context['GitProcessProbe'] } else { $null }
    if ($probe -isnot [scriptblock]) { return (Test-GitProcessRunning) }
    $answer = @(& $probe)
    return (-not (($answer.Count -gt 0) -and ($answer[-1] -is [bool]) -and (-not $answer[-1])))
}

function Invoke-RecoveryGitStatus {
    <#
    .SYNOPSIS
        git status --porcelain on one repository under a wall-clock bound.
    .DESCRIPTION
        A status that hangs would stop the outer loop for good, and nothing else
        guards that process, so the bound has to hold whatever the host has loaded.
        Invoke-GitNetworkCommand is bounded only when the pool-sync runner happens
        to be loaded, and it adds credential plumbing a local command does not
        need; this runs git itself and kills its process tree at the limit.
        --no-optional-locks keeps the probe read-only: a plain status takes
        index.lock to refresh the index, which would race the next git and
        recreate the very file that was just moved away.

        The wait is always the timed overload. The parameterless WaitForExit also
        waits for the output pipes to close, and a daemon git starts for a file
        system monitor holds them open for as long as it lives.
    .OUTPUTS
        Hashtable: ExitCode (124 on timeout, -1 when git could not be started) and
        Output (trimmed, possibly empty).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 30
    )
    $git = (Get-Command -CommandType Application -Name git -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $git) { return @{ ExitCode = -1; Output = 'git is missing' } }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $git
    foreach ($argument in @('-C', $RepoPath, '--no-optional-locks', 'status', '--porcelain')) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Environment['GIT_TERMINAL_PROMPT'] = '0'
    $info.Environment['LC_ALL'] = 'C'
    $process = $null
    try {
        $process = [Diagnostics.Process]::Start($info)
    } catch {
        return @{ ExitCode = -1; Output = "git could not be started: $($_.Exception.Message)" }
    }
    try {
        $process.StandardInput.Close()
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { Write-Verbose "Invoke-RecoveryGitStatus: the kill failed: $($_.Exception.Message)" }
            return @{ ExitCode = 124; Output = "git status did not finish within $TimeoutSeconds seconds" }
        }
        $drained = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($outTask, $errTask), 2000)
        $text = if ($drained) { ($outTask.Result + $errTask.Result).Trim() } else { '' }
        return @{ ExitCode = $process.ExitCode; Output = $text }
    } finally {
        $process.Dispose()
    }
}

function Invoke-RecoveryGitStatusProbe {
    <#
    .SYNOPSIS
        Runs the status probe for one repository: the context's override when it has
        one, the bounded git status otherwise. Always returns an integer ExitCode.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]$Context,
        [Parameter(Mandatory)][string]$RepoPath
    )
    $probe = if ($Context -is [System.Collections.IDictionary] -and $Context.Contains('GitStatusProbe')) { $Context['GitStatusProbe'] } else { $null }
    if ($probe -isnot [scriptblock]) { return (Invoke-RecoveryGitStatus -RepoPath $RepoPath -TimeoutSeconds $script:StatusTimeoutSeconds) }
    $answer = $null
    foreach ($item in @(& $probe -RepoPath $RepoPath)) {
        if ($item -is [System.Collections.IDictionary] -and $item.Contains('ExitCode')) { $answer = $item }
    }
    $code = 0
    if ($null -eq $answer -or -not [int]::TryParse([string]$answer['ExitCode'], [ref]$code)) {
        return @{ ExitCode = -1; Output = 'the status probe gave no result' }
    }
    return @{ ExitCode = $code; Output = (Get-RecoveryValueText -Source $answer -Key 'Output') }
}

# --- REGION: Project clone
function Resolve-RecoveryHostGitCommand {
    <#
    .SYNOPSIS
        A command of Test.HostGit, loading the module on first use; $null when it
        cannot be found.
    .DESCRIPTION
        The outer loop's module set does not carry Test.HostGit, and a repair that
        needs it must not depend on whoever called it having imported it. The
        command is returned as a CommandInfo so it runs the same way whichever
        scope the module landed in.
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.CommandInfo], [object])]
    param([Parameter(Mandatory)][string]$Name)
    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        $module = Join-Path $PSScriptRoot 'Test.HostGit.psm1'
        if (Test-Path -LiteralPath $module) { Import-Module $module -Global -DisableNameChecking -ErrorAction SilentlyContinue }
        $command = Get-Command -Name $Name -ErrorAction SilentlyContinue
    }
    return $command
}

function Read-RecoveryProjectAccess {
    <#
    .SYNOPSIS
        The status and url of runtime/project.access.json, or empty text for each
        when the record is absent or unreadable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowEmptyString()][string]$RuntimeDir)
    $none = @{ Status = ''; Url = '' }
    if (-not $RuntimeDir) { return $none }
    $path = Join-Path $RuntimeDir 'project.access.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $none }
    try {
        $doc = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -NoEnumerate -ErrorAction Stop
    } catch {
        Write-Verbose "Read-RecoveryProjectAccess: unreadable: $($_.Exception.Message)"
        return $none
    }
    if ($doc -isnot [System.Collections.IDictionary]) { return $none }
    return @{
        Status = (Get-RecoveryValueText -Source $doc -Key 'status').Trim().ToLowerInvariant()
        Url    = (Get-RecoveryValueText -Source $doc -Key 'url').Trim()
    }
}

function Resolve-RecoveryProjectUrl {
    <#
    .SYNOPSIS
        The project URL a reclone may use, or why there is none.
    .DESCRIPTION
        An access record that says 'denied' ends the question: the pool handed
        this host a project its credential cannot read, and cloning anything else
        in its place would report a coverage the pool did not assign. Otherwise the
        URL in the context wins, then the URL of an access record that says 'ok'.
        With neither there is no URL: the project then ships inside the framework
        checkout, and there is nothing to clone.
    .OUTPUTS
        Hashtable: Url and Reason (a kebab-case token).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()]$Context)
    $access = Read-RecoveryProjectAccess -RuntimeDir (Get-RecoveryValueText -Source $Context -Key 'RuntimeDir')
    if ($access.Status -ceq 'denied') { return @{ Url = ''; Reason = 'project-access-denied' } }
    $url = (Get-RecoveryValueText -Source $Context -Key 'ProjectUrl').Trim()
    if ($url) { return @{ Url = $url; Reason = 'project-url-configured' } }
    if ($access.Status -ceq 'ok' -and $access.Url) { return @{ Url = $access.Url; Reason = 'project-url-from-access-record' } }
    return @{ Url = ''; Reason = 'no-project-url' }
}

function Invoke-RecoveryProjectHealth {
    <#
    .SYNOPSIS
        Whether a checkout is a complete clone, by the context's override or by
        Test-ProjectCloneHealth.
    .OUTPUTS
        Hashtable: Available (the check could run), Healthy, Reason.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]$Context,
        [Parameter(Mandatory)][string]$Path
    )
    $override = if ($Context -is [System.Collections.IDictionary] -and $Context.Contains('TestProjectCloneHealth')) { $Context['TestProjectCloneHealth'] } else { $null }
    if ($override -is [scriptblock]) {
        $raw = @(& $override -Path $Path)
    } else {
        $command = Resolve-RecoveryHostGitCommand -Name 'Test-ProjectCloneHealth'
        if ($null -eq $command) { return @{ Available = $false; Healthy = $false; Reason = 'health-check-unavailable' } }
        $raw = @(& $command -Path $Path)
    }
    $verdict = $null
    foreach ($item in $raw) {
        if (($item -is [System.Collections.IDictionary] -and $item.Contains('Healthy')) -or
            ($null -ne $item -and $item -isnot [System.Collections.IDictionary] -and $null -ne $item.PSObject.Properties['Healthy'])) { $verdict = $item }
    }
    if ($null -eq $verdict) { return @{ Available = $false; Healthy = $false; Reason = 'health-check-no-answer' } }
    $healthy = if ($verdict -is [System.Collections.IDictionary]) { $verdict['Healthy'] } else { $verdict.Healthy }
    return @{
        Available = $true
        Healthy   = (($healthy -is [bool]) -and $healthy)
        Reason    = (Get-RecoveryValueText -Source $verdict -Key 'Reason')
    }
}

# --- REGION: Failure pause
function Test-RecoveryAutoRemediationAllowed {
    <#
    .SYNOPSIS
        Whether the remediation dispatcher lists a failure class as safe to retry
        unattended.
    .DESCRIPTION
        The allow-list lives with the registry that classifies failures. When the
        dispatcher module cannot be loaded the answer is $false: a class nobody
        could classify is the one that should stop and be looked at.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string]$FailureClass)
    if ([string]::IsNullOrWhiteSpace($FailureClass)) { return $false }
    if (-not (Get-Command -Name Test-AutoRemediationAllowed -ErrorAction SilentlyContinue)) {
        $module = Join-Path $PSScriptRoot 'Test.Remediation.psm1'
        if (Test-Path -LiteralPath $module) { Import-Module $module -Global -DisableNameChecking -ErrorAction SilentlyContinue }
    }
    $command = Get-Command -Name Test-AutoRemediationAllowed -ErrorAction SilentlyContinue
    if ($null -eq $command) { return $false }
    return [bool](& $command -FailureClass $FailureClass)
}

# --- REGION: Registration
function Register-BuiltinRecoveryAction {
    <#
    .SYNOPSIS
        Registers the three built-in repairs, in the order they are tried.
    .DESCRIPTION
        Idempotent: a name that is already registered is replaced in its place.
        Called once when the module loads; tests that cleared the registry call it
        again.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Registry mutation in session memory; nothing outside the process changes.')]
    param()

    $clearLock = @{
        Name        = 'clear_stale_git_lock'
        Description = 'Move the stale lock files a killed git left in .git into quarantine, then prove git works on each repository.'
        Applies     = {
            param($Result)
            ((Get-RecoveryValueText -Source $Result -Key 'failureClass') -ceq 'bootstrap_sync') -and
            ((Get-RecoveryValueText -Source $Result -Key 'stage') -in @('FrameworkPull', 'ProjectClone')) -and
            ((Get-RecoveryValueText -Source $Result -Key 'reason') -match '\.lock\b')
        }
        Precondition = {
            param($Context)
            $now = Get-RecoveryContextNow -Context $Context
            $evidence = [Collections.Generic.List[object]]::new()
            foreach ($target in @(Get-RecoveryRepoTarget -Context $Context)) {
                foreach ($lock in @(Find-StaleGitLock -RepoPath $target.Path -MinAgeMinutes $script:StaleLockMinutes -Now $now)) {
                    $evidence.Add((New-RecoveryEvidence -Kind file -Ref $lock.Path -Note "$($target.Label) lock, age $($lock.AgeMinutes) min"))
                }
            }
            if ($evidence.Count -eq 0) { return @{ Ok = $false; Reason = 'no-stale-lock'; Evidence = @() } }
            if (Test-RecoveryGitRunning -Context $Context) { return @{ Ok = $false; Reason = 'git-process-running'; Evidence = @($evidence) } }
            return @{ Ok = $true; Reason = 'stale-lock-found'; Evidence = @($evidence) }
        }
        Action = {
            param($Context)
            $now = Get-RecoveryContextNow -Context $Context
            $quarantine = Get-RecoveryQuarantinePath -Context $Context
            $evidence = [Collections.Generic.List[object]]::new()
            foreach ($target in @(Get-RecoveryRepoTarget -Context $Context)) {
                foreach ($lock in @(Find-StaleGitLock -RepoPath $target.Path -MinAgeMinutes $script:StaleLockMinutes -Now $now)) {
                    $destination = Join-Path (Join-Path $quarantine $target.Label) $lock.RelativePath
                    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
                    Move-Item -LiteralPath $lock.Path -Destination $destination -ErrorAction Stop
                    $evidence.Add((New-RecoveryEvidence -Kind file -Ref $destination -Note "quarantined from $($target.Label) $($lock.RelativePath)"))
                }
            }
            $reason = if ($evidence.Count -gt 0) { 'locks-quarantined' } else { 'no-lock-left' }
            return @{ Ok = $true; Reason = $reason; Evidence = @($evidence) }
        }
        Postcondition = {
            param($Context)
            $quarantine = Get-RecoveryQuarantinePath -Context $Context
            if (-not (Test-Path -LiteralPath $quarantine -PathType Container)) { return @{ Ok = $true; Reason = 'nothing-quarantined'; Evidence = @() } }
            $targets = @(Get-RecoveryRepoTarget -Context $Context)
            $evidence = [Collections.Generic.List[object]]::new()
            $failed = 0
            # A listing that fails must fail the step: an empty one would pass with no repository probed.
            foreach ($directory in @(Get-ChildItem -LiteralPath $quarantine -Directory -Force -ErrorAction Stop)) {
                $target = @($targets | Where-Object { $_.Label -ceq $directory.Name }) | Select-Object -First 1
                if ($null -eq $target) { $failed++; continue }
                $probe = Invoke-RecoveryGitStatusProbe -Context $Context -RepoPath $target.Path
                $note = if ($probe.ExitCode -eq 0) { 'exit 0' } else { "exit $($probe.ExitCode) $($probe.Output)" }
                $evidence.Add((New-RecoveryEvidence -Kind command -Ref "git -C $($target.Path) status --porcelain" -Note $note))
                if ($probe.ExitCode -ne 0) { $failed++ }
            }
            if ($failed -gt 0) { return @{ Ok = $false; Reason = 'git-status-failed'; Evidence = @($evidence) } }
            return @{ Ok = $true; Reason = 'git-status-ok'; Evidence = @($evidence) }
        }
        Rollback = {
            param($Context)
            $quarantine = Get-RecoveryQuarantinePath -Context $Context
            if (-not (Test-Path -LiteralPath $quarantine -PathType Container)) { return @{ Ok = $true; Reason = 'nothing-quarantined'; Evidence = @() } }
            # The quarantine is the record of what moved, so the rollback works
            # from it and stays correct when the action stopped half way.
            $targets = @(Get-RecoveryRepoTarget -Context $Context)
            $evidence = [Collections.Generic.List[object]]::new()
            $blocked = 0
            foreach ($file in @(Get-ChildItem -LiteralPath $quarantine -File -Recurse -Force -ErrorAction Stop)) {
                $parts = [IO.Path]::GetRelativePath($quarantine, $file.FullName) -split '[\\/]', 2
                $target = @($targets | Where-Object { $_.Label -ceq $parts[0] }) | Select-Object -First 1
                if ($null -eq $target -or $parts.Count -lt 2) { $blocked++; continue }
                $original = Join-Path $target.Path $parts[1]
                # A lock that has reappeared belongs to a live git now; it is not
                # overwritten, and the quarantined copy stays for the operator.
                if (Test-Path -LiteralPath $original) {
                    $blocked++
                    $evidence.Add((New-RecoveryEvidence -Kind file -Ref $original -Note 'a lock already exists here'))
                    continue
                }
                $null = New-Item -ItemType Directory -Path (Split-Path -Parent $original) -Force
                Move-Item -LiteralPath $file.FullName -Destination $original -ErrorAction Stop
                $evidence.Add((New-RecoveryEvidence -Kind file -Ref $original -Note 'restored'))
            }
            if ($blocked -gt 0) { return @{ Ok = $false; Reason = 'rollback-target-exists'; Evidence = @($evidence) } }
            # Only empty directories are left, so a failure to remove them loses nothing.
            Remove-Item -LiteralPath $quarantine -Recurse -Force -ErrorAction SilentlyContinue
            return @{ Ok = $true; Reason = 'locks-restored'; Evidence = @($evidence) }
        }
        MaxAttempts       = 2
        SkipsFailurePause = $true
    }
    Register-RecoveryAction @clearLock

    $reclone = @{
        Name        = 'reclone_project'
        Description = 'Retry the project clone now, with its health check, instead of waiting out the failure pause.'
        Applies     = {
            param($Result)
            ((Get-RecoveryValueText -Source $Result -Key 'failureClass') -ceq 'bootstrap_sync') -and
            ((Get-RecoveryValueText -Source $Result -Key 'stage') -ieq 'ProjectClone')
        }
        Precondition = {
            param($Context)
            $resolved = Resolve-RecoveryProjectUrl -Context $Context
            if (-not $resolved.Url) { return @{ Ok = $false; Reason = $resolved.Reason; Evidence = @() } }
            $projectDir = Get-RecoveryProjectDir -Context $Context
            if (-not (Get-RecoveryValueText -Source $Context -Key 'RepoRoot') -or -not $projectDir) { return @{ Ok = $false; Reason = 'no-repository'; Evidence = @() } }
            $health = Invoke-RecoveryProjectHealth -Context $Context -Path $projectDir
            if (-not $health.Available) { return @{ Ok = $false; Reason = $health.Reason; Evidence = @() } }
            $evidence = @(
                (New-RecoveryEvidence -Kind record -Ref 'project-url' -Note $resolved.Url),
                (New-RecoveryEvidence -Kind file -Ref $projectDir -Note $health.Reason)
            )
            # A checkout that is complete means the failure was somewhere else, and
            # replacing a good checkout cannot help.
            if ($health.Healthy) { return @{ Ok = $false; Reason = 'project-already-healthy'; Evidence = $evidence } }
            return @{ Ok = $true; Reason = 'project-unhealthy'; Evidence = $evidence }
        }
        Action = {
            param($Context)
            $url = (Resolve-RecoveryProjectUrl -Context $Context).Url
            $repoRoot = Get-RecoveryValueText -Source $Context -Key 'RepoRoot'
            $override = if ($Context.Contains('UpdateProjectClone')) { $Context['UpdateProjectClone'] } else { $null }
            if ($override -is [scriptblock]) {
                $raw = @(& $override -RepoRoot $repoRoot -ProjectUrl $url)
            } else {
                $command = Resolve-RecoveryHostGitCommand -Name 'Update-ProjectClone'
                if ($null -eq $command) { return @{ Ok = $false; Reason = 'clone-unavailable'; Evidence = @() } }
                $raw = @(& $command -RepoRoot $repoRoot -ProjectUrl $url -Confirm:$false)
            }
            $clone = $null
            foreach ($item in $raw) {
                if ($item -is [System.Collections.IDictionary] -and $item.Contains('success')) { $clone = $item }
            }
            if ($null -eq $clone) { return @{ Ok = $false; Reason = 'clone-no-answer'; Evidence = @() } }
            if (($clone['success'] -isnot [bool]) -or (-not $clone['success'])) {
                return @{ Ok = $false; Reason = "clone-failed: $(Get-RecoveryValueText -Source $clone -Key 'errorMessage')"; Evidence = @() }
            }
            $revision = Get-RecoveryValueText -Source $clone -Key 'revision'
            $evidence = [Collections.Generic.List[object]]::new()
            if ($revision) { $evidence.Add((New-RecoveryEvidence -Kind record -Ref 'project-revision' -Note $revision)) }
            return @{ Ok = $true; Reason = 'project-cloned'; Evidence = @($evidence) }
        }
        Postcondition = {
            param($Context)
            $projectDir = Get-RecoveryProjectDir -Context $Context
            $health = Invoke-RecoveryProjectHealth -Context $Context -Path $projectDir
            if (-not $health.Available -or -not $health.Healthy) {
                $reason = if ($health.Available) { "project-unhealthy: $($health.Reason)" } else { $health.Reason }
                return @{ Ok = $false; Reason = $reason; Evidence = @() }
            }
            return @{ Ok = $true; Reason = 'project-healthy'; Evidence = @() }
        }
        Rollback = {
            param($Context)
            $repoRoot = Get-RecoveryValueText -Source $Context -Key 'RepoRoot'
            $override = if ($Context.Contains('RestoreProjectCloneSwap')) { $Context['RestoreProjectCloneSwap'] } else { $null }
            if ($override -is [scriptblock]) {
                $taken = @(& $override -RepoRoot $repoRoot)
            } else {
                $command = Resolve-RecoveryHostGitCommand -Name 'Restore-ProjectCloneSwap'
                if ($null -eq $command) { return @{ Ok = $false; Reason = 'restore-unavailable'; Evidence = @() } }
                $taken = @(& $command -RepoRoot $repoRoot -Confirm:$false)
            }
            $evidence = @($taken | Where-Object { $_ } | ForEach-Object { New-RecoveryEvidence -Kind record -Ref 'project-swap' -Note ([string]$_) })
            $reason = if ($evidence.Count -gt 0) { 'swap-restored' } else { 'nothing-to-restore' }
            return @{ Ok = $true; Reason = $reason; Evidence = $evidence }
        }
        MaxAttempts       = 2
        SkipsFailurePause = $true
    }
    Register-RecoveryAction @reclone

    $endPause = @{
        Name        = 'end_failure_pause_early'
        Description = 'End the failure pause early for a failure class the remediation dispatcher lists as safe to retry.'
        Applies     = {
            param($Result)
            Test-RecoveryAutoRemediationAllowed -FailureClass (Get-RecoveryValueText -Source $Result -Key 'failureClass')
        }
        Precondition = {
            param($Context)
            $result = if ($Context.Contains('Result')) { $Context['Result'] } else { $null }
            $failureClass = Get-RecoveryValueText -Source $result -Key 'failureClass'
            if (-not (Test-RecoveryAutoRemediationAllowed -FailureClass $failureClass)) { return @{ Ok = $false; Reason = 'class-not-allowed'; Evidence = @() } }
            return @{ Ok = $true; Reason = 'class-allowed'; Evidence = @() }
        }
        Action        = { @{ Ok = $true; Reason = 'pause-ended-early'; Evidence = @() } }
        Postcondition = { @{ Ok = $true; Reason = 'ok'; Evidence = @() } }
        MaxAttempts       = 0
        SkipsFailurePause = $true
    }
    Register-RecoveryAction @endPause
}

Register-BuiltinRecoveryAction

Export-ModuleMember -Function Find-StaleGitLock, Test-GitProcessRunning, Register-BuiltinRecoveryAction
