<#PSScriptInfo
.VERSION 2026.11.05
.GUID 4276a748-cfa3-4a04-8af7-f29a0d4ab830
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna runner attempt history
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

Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -DisableNameChecking

function Initialize-RunnerAttemptDirectory {
    <# .SYNOPSIS
        Create the attempt's hashed directory without following artifact-directory links.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$AttemptGeneration
    )
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($AttemptGeneration))).ToLowerInvariant()
    $relative = 'runner-attempts/' + $digest.Substring(0, 24)
    if (-not $PSCmdlet.ShouldProcess($relative, 'Create runner attempt artifact directory')) { return $relative }
    foreach ($path in @((Join-Path $RuntimeDir 'runner-attempts'), (Join-Path $RuntimeDir $relative))) {
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($item -and (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or -not $item.PSIsContainer)) {
            throw "Runner attempt artifact directory is not a regular directory: $path"
        }
        $null = [IO.Directory]::CreateDirectory($path)
    }
    return $relative
}

function Get-RunnerAttemptHistoryEntry {
    <# .SYNOPSIS
        Read retained evidence, deriving public links only from verified artifact names.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][IO.DirectoryInfo]$Directory)
    if ($Directory.Name -notmatch '^[0-9a-f]{24}$' -or ($Directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $null }
    foreach ($name in @('runner-fault.json', 'config-gate.json')) {
        try {
            $file = Get-Item -LiteralPath (Join-Path $Directory.FullName $name) -Force -ErrorAction Stop
            if ($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            $record = [IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($record -isnot [System.Collections.IDictionary] -or -not $record['attemptGeneration'] -or
                $record['passed'] -isnot [bool] -or $record['skipped'] -isnot [bool]) { continue }
            $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes([string]$record['attemptGeneration']))).ToLowerInvariant()
            if ($digest.Substring(0, 24) -cne $Directory.Name) { continue }
            $started = ([datetime]$record['startedAtUtc']).ToUniversalTime()
            $finished = ([datetime]$record['finishedAtUtc']).ToUniversalTime()
            if ($started -eq [datetime]::MinValue -or $finished -lt $started) { continue }
            $relative = 'runner-attempts/' + $Directory.Name
            $transcriptPath = ''
            if ($name -eq 'config-gate.json' -or [string]$record['transcriptPath'] -ceq ($relative + '/config-gate.log')) {
                $transcript = Get-Item -LiteralPath (Join-Path $Directory.FullName 'config-gate.log') -Force -ErrorAction SilentlyContinue
                if ($transcript -and -not $transcript.PSIsContainer -and -not ($transcript.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    $transcriptPath = $relative + '/config-gate.log'
                }
            }
            $description = [string]$record['description']
            if (-not $description -and -not $record['passed']) {
                $description = (@($record['failureLines']) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`n"
                if (-not $description) { $description = [string]$record['failureClass'] }
            }
            return @{
                attemptGeneration = [string]$record['attemptGeneration']
                startedAtUtc = $started.ToString('o')
                finishedAtUtc = $finished.ToString('o')
                frameworkCommitSha = [string]$record['frameworkCommitSha']
                passed = [bool]$record['passed']
                skipped = [bool]$record['skipped']
                exitCode = [int]$record['exitCode']
                failureClass = [string]$record['failureClass']
                stage = [string]$record['stage']
                description = $description
                recordPath = $relative + '/' + $name
                transcriptPath = $transcriptPath
            }
        } catch { Write-Verbose "Ignoring unreadable runner attempt artifact $($Directory.Name)/${name}: $($_.Exception.Message)" }
    }
    return $null
}

function Update-RunnerAttemptHistory {
    <# .SYNOPSIS
        Atomically rebuild bounded history from retained evidence, then retire old artifacts.
    .DESCRIPTION
        The index is derived data: rebuilding also recovers missing or corrupt indexes
        and includes evidence written by older runners. Publish first so readers never
        receive new index entries whose artifacts have already been removed.

        attempts holds the latest MaxAttempts attempts. Every cycle is an attempt, so
        on a host that recovers, the passing attempts after a failure push it out of
        that window within hours. A failure older than the window that a later attempt
        passed after is kept in olderFailures, up to MaxOlderFailures, with its
        artifacts; it leaves when newer recovered failures take its place. A failure
        no attempt has passed after yet stays bounded by the window, so retrying one
        failure without end keeps only its latest MaxAttempts tries.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [ValidateRange(1, 1000)][int]$MaxAttempts = 20,
        [ValidateRange(0, 1000)][int]$MaxOlderFailures = 30
    )
    $root = Join-Path $RuntimeDir 'runner-attempts'
    if (-not $PSCmdlet.ShouldProcess($root, 'Publish retained runner attempt history')) { return }
    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Runner attempt history must be a regular directory.'
    }
    $entries = @(foreach ($directory in Get-ChildItem -LiteralPath $root -Directory -Force) {
        $entry = Get-RunnerAttemptHistoryEntry -Directory $directory
        if ($entry) { $entry }
    })
    $ordered = @($entries | Sort-Object -Property @{ Expression = { $_.finishedAtUtc }; Descending = $true }, @{ Expression = { $_.attemptGeneration }; Descending = $true })
    $olderFailures = [System.Collections.Generic.List[object]]::new()
    $retired = [System.Collections.Generic.List[object]]::new()
    $laterPass = $false
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        $entry = $ordered[$i]
        if ($i -ge $MaxAttempts) {
            if (-not $entry.passed -and $laterPass -and $olderFailures.Count -lt $MaxOlderFailures) { $olderFailures.Add($entry) }
            else { $retired.Add($entry) }
        }
        if ($entry.passed) { $laterPass = $true }
    }
    # Readers bound attempts to the window -- the pool aggregator refuses a longer
    # list -- so the older failures are a list of their own.
    $index = [ordered]@{ schemaVersion = 1; attempts = @($ordered | Select-Object -First $MaxAttempts); olderFailures = @($olderFailures) }
    if (-not (Write-YurunaStateFileJson -Path (Join-Path $root 'index.json') -InputObject $index -Depth 8 -Confirm:$false)) {
        throw 'Runner attempt history index could not be saved.'
    }
    foreach ($entry in $retired) {
        $directory = Get-Item -LiteralPath (Split-Path -Parent (Join-Path $RuntimeDir $entry.recordPath)) -Force -ErrorAction SilentlyContinue
        if (-not $directory -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
        # Attempt artifacts are flat files. Unexpected subdirectories or links
        # are not ours to recursively remove, even under an otherwise valid name.
        $children = @(Get-ChildItem -LiteralPath $directory.FullName -Force)
        if (@($children | Where-Object { $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }).Count) { continue }
        Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Write-RunnerAttemptFaultArtifact {
    <# .SYNOPSIS
        Preserve an outer-loop fault and its evidence independently of mutable pointers.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$AttemptGeneration,
        [Parameter(Mandatory)][string]$FailureClass,
        [string]$Description = '',
        [datetime]$StartedAtUtc = [datetime]::UtcNow,
        [string]$FrameworkCommitSha = '',
        [int]$ExitCode = 1,
        [AllowNull()][hashtable]$Evidence = $null
    )
    if (-not $PSCmdlet.ShouldProcess($RuntimeDir, 'Preserve runner fault evidence')) { return @{} }
    $relative = Initialize-RunnerAttemptDirectory -RuntimeDir $RuntimeDir -AttemptGeneration $AttemptGeneration -Confirm:$false
    $directory = Get-Item -LiteralPath (Join-Path $RuntimeDir $relative)
    $existing = Get-RunnerAttemptHistoryEntry -Directory $directory
    # A failed gate already owns a durable record. Fault -> paused transitions
    # likewise keep the first outer-fault evidence and timestamp unchanged.
    if ($existing -and (-not $existing.passed) -and
        ($existing.failureClass -eq $FailureClass -or $existing.recordPath.EndsWith('/runner-fault.json'))) {
        Update-RunnerAttemptHistory -RuntimeDir $RuntimeDir -Confirm:$false
        return $existing
    }
    $recordPath = $relative + '/runner-fault.json'
    $record = [ordered]@{
        schemaVersion = 1
        attemptGeneration = $AttemptGeneration
        startedAtUtc = $StartedAtUtc.ToUniversalTime().ToString('o')
        finishedAtUtc = [DateTime]::UtcNow.ToString('o')
        frameworkCommitSha = $FrameworkCommitSha
        passed = $false
        skipped = $false
        exitCode = $ExitCode
        failureClass = $FailureClass
        stage = if ($Evidence) { [string]$Evidence['stage'] } else { '' }
        description = $Description
        recordPath = $recordPath
        transcriptPath = if ($existing) { [string]$existing.transcriptPath } else { '' }
        evidence = $Evidence
    }
    if (-not (Write-YurunaStateFileJson -Path (Join-Path $RuntimeDir $recordPath) -InputObject $record -Depth 32 -Confirm:$false)) {
        throw 'Runner fault evidence could not be saved.'
    }
    Update-RunnerAttemptHistory -RuntimeDir $RuntimeDir -Confirm:$false
    return (Get-RunnerAttemptHistoryEntry -Directory $directory)
}

Export-ModuleMember -Function Initialize-RunnerAttemptDirectory, Update-RunnerAttemptHistory, Write-RunnerAttemptFaultArtifact
