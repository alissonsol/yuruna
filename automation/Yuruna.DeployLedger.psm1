<#PSScriptInfo
.VERSION 2026.10.31
.GUID 42be787f-fe6c-471b-a4b6-e323d4d78dea
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Yuruna.DeployLedger
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
    The deploy phase ledger: a retry of a deployment runs again only the phase
    that failed and the phases after it.
.DESCRIPTION
    A project deploys with three separate processes -- Set-Resource,
    Set-Component and Set-Workload, in that order -- so a script that failed in
    the workloads phase, run again, would provision and rebuild everything
    before it reached the phase that failed. The ledger, the file
    .yuruna/<config>/deploy-ledger.json under the project, records each phase's
    outcome, and a phase that passed is skipped when all of these hold:

      * a later phase failed after it passed (a run with no failure behind it
        is an ordinary run, and runs every phase as before);
      * the hash of its inputs -- its configuration file, the folders it reads
        and the outputs of the phases before it -- is the one it passed with;
      * its outputs are still in place, by a check the phase supplies;
      * it has not been skipped already since it passed. A retry that skipped
        a phase and failed again forgets the skipped phases, so an output no
        check can see costs one retry at most, never a loop.

    The last phase passing ends the run and deletes the ledger. Deleting the
    file by hand runs every phase again. The ledger only ever saves work: one
    that cannot be read is treated as absent, and one that cannot be written
    leaves every phase to run.
#>

Import-Module (Join-Path $PSScriptRoot 'Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Yuruna.Result.psm1') -Global -Force

$script:DeployPhaseOrder = @('resources', 'components', 'workloads')
$script:LedgerSchema = 'yuruna.deploy-ledger/v1'
# Hashing stops past these and the phase is not reused: a tree that large is
# not a deployment input, and reading it at every phase start would cost more
# than the skip saves.
$script:InputHashFileLimit = 20000
$script:InputHashByteLimit = 512MB

<#
.SYNOPSIS
    Where the deploy ledger of a configuration lives: deploy-ledger.json in the
    configuration's work folder under the project's .yuruna folder.
#>
function Get-YurunaDeployLedgerPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ConfigSubfolder
    )
    return (Join-Path -Path $ProjectRoot -ChildPath ".yuruna/$ConfigSubfolder/deploy-ledger.json")
}

function Read-YurunaDeployLedger {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Path)
    $empty = @{ schema = $script:LedgerSchema; sequence = 0; phases = @{} }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $empty }
    try {
        $ledger = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {
        Write-Verbose "Deploy ledger ${Path} is unreadable and is ignored: $($_.Exception.Message)"
        return $empty
    }
    if ($ledger -isnot [System.Collections.IDictionary] -or [string]$ledger['schema'] -cne $script:LedgerSchema -or
        $ledger['phases'] -isnot [System.Collections.IDictionary]) {
        Write-Verbose "Deploy ledger ${Path} has an unknown shape and is ignored."
        return $empty
    }
    $sequence = 0
    if (-not [int]::TryParse([string]$ledger['sequence'], [ref]$sequence)) { $sequence = 0 }
    $ledger['sequence'] = $sequence
    return $ledger
}

function Save-YurunaDeployLedger {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal ledger persistence under the project work folder; the deploy phase owns the mutation.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Ledger
    )
    $folder = Split-Path -Parent $Path
    $null = New-Item -ItemType Directory -Force -Path $folder -ErrorAction Stop
    $temporaryPath = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporaryPath, ($Ledger | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporaryPath, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue }
    }
}

<#
.SYNOPSIS
    SHA-256 over a phase's inputs: each labeled file, or every file under a
    labeled folder, by relative path, length and content.
.DESCRIPTION
    Labels, not absolute paths, enter the hash, so the same project extracted
    to the same layout hashes the same. A missing input is part of the hash as
    missing. Returns $null when the inputs pass the file or byte limit, which
    makes the phase ineligible for reuse.
.PARAMETER InputPath
    Label -> file or folder path.
#>
function Get-YurunaDeployInputHash {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][System.Collections.IDictionary]$InputPath
    )
    $hash = [System.Security.Cryptography.IncrementalHash]::CreateHash([System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $encoding = [Text.UTF8Encoding]::new($false)
    $buffer = [byte[]]::new(81920)
    try {
        $hash.AppendData($encoding.GetBytes("phase $Phase`n"))
        $labels = [string[]]@($InputPath.Keys | ForEach-Object { [string]$_ })
        [Array]::Sort($labels, [StringComparer]::Ordinal)
        $fileCount = 0
        $byteCount = 0L
        foreach ($label in $labels) {
            $path = [string]$InputPath[$label]
            $entries = [System.Collections.Generic.List[object]]::new()
            if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                $entries.Add(@{ Name = $label; Path = $path })
            } elseif ($path -and (Test-Path -LiteralPath $path -PathType Container)) {
                $root = (Resolve-Path -LiteralPath $path).ProviderPath
                $items = [object[]]@(foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction Stop) {
                    @{ Name = "$label/" + ([IO.Path]::GetRelativePath($root, $file.FullName) -replace '\\', '/'); Path = $file.FullName }
                })
                # Ordinal, not Sort-Object's culture order: the hash needs the
                # same file order on every host.
                $names = [string[]]@($items | ForEach-Object { $_.Name })
                [Array]::Sort($names, $items, [StringComparer]::Ordinal)
                foreach ($item in $items) { $entries.Add($item) }
            } else {
                $hash.AppendData($encoding.GetBytes("missing $label`n"))
                continue
            }
            foreach ($entry in $entries) {
                $length = ([IO.FileInfo]::new($entry.Path)).Length
                $fileCount++
                $byteCount += $length
                if ($fileCount -gt $script:InputHashFileLimit -or $byteCount -gt $script:InputHashByteLimit) {
                    Write-Verbose "Deploy phase ${Phase}: inputs exceed $($script:InputHashFileLimit) files or $($script:InputHashByteLimit) bytes; the phase is not reused."
                    return $null
                }
                $hash.AppendData($encoding.GetBytes("file $($entry.Name) $length`n"))
                $stream = [IO.File]::OpenRead($entry.Path)
                try {
                    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) { $hash.AppendData($buffer, 0, $read) }
                } finally { $stream.Dispose() }
            }
        }
        return ([Convert]::ToHexString($hash.GetHashAndReset())).ToLowerInvariant()
    } finally {
        $hash.Dispose()
    }
}

<#
.SYNOPSIS
    The phase whose recorded failure lets this phase be reused, or $null when
    the phase must run.
#>
function Get-YurunaDeployPhaseReuse {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Ledger,
        [Parameter(Mandatory)][string]$Phase,
        [AllowNull()][AllowEmptyString()][string]$InputHash,
        [scriptblock]$OutputTest
    )
    if ([string]::IsNullOrEmpty($InputHash) -or -not $OutputTest) { return $null }
    $entry = $Ledger.phases[$Phase]
    if ($entry -isnot [System.Collections.IDictionary] -or [string]$entry['outcome'] -cne 'pass') { return $null }
    if ([string]$entry['inputHash'] -cne $InputHash -or [bool]$entry['reused']) { return $null }
    $index = [Array]::IndexOf($script:DeployPhaseOrder, $Phase)
    $failedPhase = $null
    foreach ($later in @($script:DeployPhaseOrder | Select-Object -Skip ($index + 1))) {
        $laterEntry = $Ledger.phases[$later]
        if ($laterEntry -is [System.Collections.IDictionary] -and [string]$laterEntry['outcome'] -ceq 'fail' -and
            [int]$laterEntry['sequence'] -gt [int]$entry['sequence']) {
            $failedPhase = $later
            break
        }
    }
    if (-not $failedPhase) { return $null }
    $present = $false
    try { $present = [bool](& $OutputTest $entry['evidence']) } catch { Write-Verbose "Deploy phase ${Phase}: the output check failed: $($_.Exception.Message)" }
    if (-not $present) {
        Write-Verbose "Deploy phase ${Phase}: its recorded outputs are not all in place; it runs."
        return $null
    }
    return $failedPhase
}

<#
.SYNOPSIS
    Run one deploy phase through the ledger: skip it when a retry may reuse
    it, otherwise run it and record its outcome.
.DESCRIPTION
    A reused phase returns a passing manifest with skipped set. A phase that
    throws a TimeoutException (a tool call stopped at its deadline) returns a
    tool_timeout manifest instead of the throw; any other throw is recorded as
    a failure and passes through unchanged.
.PARAMETER Operation
    The phase itself; its output is returned as it was.
.PARAMETER InputPath
    Label -> path of the phase's inputs. Without it the phase is never reused.
.PARAMETER OutputTest
    param($Evidence) -> $true when the outputs the phase recorded are still in
    place. Without it the phase is never reused.
.PARAMETER Evidence
    Run after a pass; returns the hashtable OutputTest receives later.
#>
function Invoke-YurunaDeployPhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$ConfigSubfolder,
        [Parameter(Mandatory)][ValidateSet('resources', 'components', 'workloads')][string]$Phase,
        [Parameter(Mandatory)][scriptblock]$Operation,
        [System.Collections.IDictionary]$InputPath,
        [scriptblock]$OutputTest,
        [scriptblock]$Evidence
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $ledgerPath = Get-YurunaDeployLedgerPath -ProjectRoot $ProjectRoot -ConfigSubfolder $ConfigSubfolder
    $inputHash = $null
    try {
        if ($InputPath) { $inputHash = Get-YurunaDeployInputHash -Phase $Phase -InputPath $InputPath }
        $ledger = Read-YurunaDeployLedger -Path $ledgerPath
        $failedPhase = Get-YurunaDeployPhaseReuse -Ledger $ledger -Phase $Phase -InputHash $inputHash -OutputTest $OutputTest
        if ($failedPhase) {
            $ledger.phases[$Phase]['reused'] = $true
            Save-YurunaDeployLedger -Path $ledgerPath -Ledger $ledger
            Write-Information (Format-YurunaOperatorMessage -Key 'automation.deploy_phase_reused' -Arguments @{ phase = $Phase; failedPhase = $failedPhase; ledgerPath = $ledgerPath })
            return (New-YurunaResultManifest -Success $true -Skipped $true -DurationMs $watch.ElapsedMilliseconds)
        }
    } catch {
        Write-Warning "Deploy ledger ${ledgerPath}: the $Phase phase runs without it: $($_.Exception.Message)"
        $inputHash = $null
    }

    $result = $null
    try {
        $result = & $Operation
    } catch [System.TimeoutException] {
        $result = New-YurunaResultManifest -Success $false -ErrorMessage $_.Exception.Message -FailureClass 'tool_timeout' -ExitCode 124 -DurationMs $watch.ElapsedMilliseconds
    } finally {
        $manifest = @($result | Where-Object { $_ -is [System.Collections.IDictionary] }) | Select-Object -Last 1
        $passed = ($null -ne $manifest) -and $manifest.Contains('success') -and [bool]$manifest['success']
        try {
            Write-YurunaDeployPhaseOutcome -Path $ledgerPath -Phase $Phase -Passed $passed -InputHash $inputHash -Evidence $Evidence -FailureClass ([string]$(if ($manifest) { $manifest['failureClass'] } else { 'unknown' }))
        } catch {
            Write-Warning "Deploy ledger ${ledgerPath}: the $Phase phase outcome was not recorded: $($_.Exception.Message)"
        }
    }
    return $result
}

function Write-YurunaDeployPhaseOutcome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][bool]$Passed,
        [AllowNull()][AllowEmptyString()][string]$InputHash,
        [scriptblock]$Evidence,
        [AllowEmptyString()][string]$FailureClass
    )
    if ($Passed -and $Phase -ceq $script:DeployPhaseOrder[-1]) {
        # The last phase passing ends the run: nothing is left to retry.
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        return
    }
    $ledger = Read-YurunaDeployLedger -Path $Path
    $ledger['sequence'] = [int]$ledger['sequence'] + 1
    $stamp = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    if ($Passed) {
        $recorded = $null
        if ($Evidence) {
            try { $recorded = & $Evidence } catch { Write-Verbose "Deploy phase ${Phase}: no output evidence recorded: $($_.Exception.Message)" }
        }
        $ledger.phases[$Phase] = @{ outcome = 'pass'; sequence = $ledger['sequence']; utc = $stamp; inputHash = $InputHash; reused = $false; evidence = $recorded }
    } else {
        $ledger.phases[$Phase] = @{ outcome = 'fail'; sequence = $ledger['sequence']; utc = $stamp; failureClass = $FailureClass }
        # A retry that skipped phases and still failed forgets the skipped
        # ones: whatever made it fail may be an output of theirs that no check
        # can see.
        $index = [Array]::IndexOf($script:DeployPhaseOrder, $Phase)
        foreach ($earlier in @($script:DeployPhaseOrder | Select-Object -First $index)) {
            $entry = $ledger.phases[$earlier]
            if ($entry -is [System.Collections.IDictionary] -and [bool]$entry['reused']) { $ledger.phases.Remove($earlier) }
        }
    }
    Save-YurunaDeployLedger -Path $Path -Ledger $ledger
}

Export-ModuleMember -Function 'Invoke-YurunaDeployPhase', 'Get-YurunaDeployLedgerPath', 'Get-YurunaDeployInputHash'
