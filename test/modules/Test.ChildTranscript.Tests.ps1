<#PSScriptInfo
.VERSION 2026.08.07
.GUID 4267af85-3ccc-4ef7-a368-55560cfd0f65
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test transcript loglevel pester
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
# Pester supplies Describe/It/Should here. Without it every one of those calls
# raises CommandNotFoundException, the engine keeps going, and the file reaches
# its end and exits 0 -- so a harness that shells this out records a PASS for a
# suite that executed no assertion at all. A test that cannot run must say so in
# its exit code; silence that reads as success is worse than no test.
if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error ("Pester is not available, so this suite cannot run. Install it with " +
                 "'Install-Module Pester -Scope CurrentUser', then re-run with " +
                 "Invoke-Pester -Path '$PSCommandPath'.")
    exit 1
}

<#
.SYNOPSIS
    Pester guard on Test.LogLevel.psm1: one transcript writer per process, and
    the state the log-level cascade holds survives a forced re-import.
.DESCRIPTION
    A service bring-up runs its per-guest Get-Image.ps1 / New-VM.ps1 with the
    in-process call operator, and a nested script is free to re-import the
    log-level module. `Import-Module -Force` builds a fresh module instance, so
    anything the module kept in its own scope is gone by the time that script
    asks for a transcript -- and PowerShell 7 grants the second Start-Transcript
    rather than refusing it. Both writers then hold the same file open in Append
    mode, each seeking to end-of-file once at construction and advancing its own
    offset from there, so the later one writes over the earlier one's lines: the
    file ends with one start block, N end blocks and half-overwritten text
    exactly where the failure being diagnosed was recorded.

    The same reset pins ProgressPreference. The cascade suppresses the progress
    bar at Verbose/Debug and stores the caller's value to put back afterwards;
    on a fresh module instance that store is empty again, so the next
    suppression records the ALREADY-suppressed value as the caller's choice and
    the restore has nothing left to restore.

    The transcript scenario has to run in a CHILD pwsh and be asserted after
    that process exits: an end block is written at Stop-Transcript or at process
    exit, so an in-process count sees zero of them and would pass against
    correct and broken code alike. The path handed back is not enough on its own
    either -- every writer returns the same string, because the name is derived
    from $PID. The number of end blocks in the finished file is what separates
    one writer from three.

    Throw-based assertions (no Should) and temp-directory fixtures, so nothing
    here touches the repo's own log tree.
    Run: Invoke-Pester -Path test/modules/Test.ChildTranscript.Tests.ps1
#>

$here             = Split-Path -Parent $PSCommandPath
$script:LogModule = Join-Path $here 'Test.LogLevel.psm1'

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

# Fixtures at FILE scope: a Describe body runs during discovery and its
# variables and functions are discarded before any It executes.

function Get-PwshPath {
    <#
    .SYNOPSIS
        The pwsh that is running this file, so a child starts on the same
        edition rather than on whatever 'pwsh' resolves to on PATH.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $exe = (Get-Process -Id $PID).Path
    if (-not $exe) { $exe = 'pwsh' }
    return $exe
}

function Invoke-TranscriptChild {
    <#
    .SYNOPSIS
        Run a scenario body in a child pwsh with YURUNA_CHILD_TRANSCRIPT_DIR
        pointed at a throwaway directory, and return everything the assertions
        need once that process has exited.
    .DESCRIPTION
        The body is given -ModulePath (the module under test) and -ResultPath (a
        file it writes its own observations to). Observations go to a file
        rather than to stdout because stdout is also being transcribed, and a
        test that parsed the transcript for its inputs could not then use the
        transcript as its evidence.
    .OUTPUTS
        [hashtable] ExitCode, Output, Result (string[]), TranscriptFile (FileInfo[]),
        TranscriptText.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$Body)

    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('yuruna-transcript-' + [guid]::NewGuid().ToString('N'))
    $tdir = Join-Path $work 'transcript'
    New-Item -ItemType Directory -Force -Path $tdir | Out-Null
    $childScript = Join-Path $work 'child.ps1'
    $resultPath  = Join-Path $work 'result.txt'
    Set-Content -LiteralPath $childScript -Value $Body -Encoding utf8

    # The directory is the only switch that turns the transcript on and it is
    # read from the environment, so it has to be set around the launch and put
    # back exactly as it was for whatever runs after this test.
    $hadVar   = Test-Path -LiteralPath 'Env:\YURUNA_CHILD_TRANSCRIPT_DIR'
    $previous = $env:YURUNA_CHILD_TRANSCRIPT_DIR
    try {
        $env:YURUNA_CHILD_TRANSCRIPT_DIR = $tdir
        $out = & (Get-PwshPath) -NoProfile -File $childScript -ModulePath $script:LogModule -ResultPath $resultPath 2>&1
        $code = $LASTEXITCODE
    } finally {
        if ($hadVar) { $env:YURUNA_CHILD_TRANSCRIPT_DIR = $previous }
        else { Remove-Item -LiteralPath 'Env:\YURUNA_CHILD_TRANSCRIPT_DIR' -ErrorAction SilentlyContinue }
    }

    $files = @(Get-ChildItem -LiteralPath $tdir -Filter '*.log' -File -ErrorAction SilentlyContinue)
    $text  = ''
    if ($files.Count -ge 1) {
        $text = ($files | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join ''
    }
    $result = @()
    if (Test-Path -LiteralPath $resultPath) {
        $result = @(Get-Content -LiteralPath $resultPath)
    }
    # Everything an assertion (or its failure message) needs is now in memory --
    # the FileInfo entries keep their paths after the directory goes -- so the
    # fixture leaves nothing behind in the system temp directory.
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    return @{
        ExitCode       = $code
        Output         = ($out -join "`n")
        Result         = $result
        TranscriptFile = $files
        TranscriptText = $text
    }
}

function Measure-Occurrence {
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [Parameter(Mandatory)][string]$Needle)
    return ([regex]::Matches($Text, [regex]::Escape($Needle))).Count
}

# Three imports and three Start-YurunaChildTranscript calls in one process: the
# shape a caching-proxy bring-up produces when it runs Get-Image.ps1 and
# New-VM.ps1 in-process and each of them re-imports the module.
$script:ForcedReimportBody = @'
param([Parameter(Mandatory)][string]$ModulePath, [Parameter(Mandatory)][string]$ResultPath)
$paths = [System.Collections.Generic.List[string]]::new()
foreach ($i in 1..3) {
    Import-Module $ModulePath -Global -Force -DisableNameChecking
    $paths.Add((Start-YurunaChildTranscript))
    Write-Output "child-marker-$i"
}
Set-Content -LiteralPath $ResultPath -Value ($paths -join [Environment]::NewLine) -Encoding utf8
'@

# The caller sets ProgressPreference, the cascade suppresses it twice across a
# forced re-import, and the level then drops back below Verbose. What the caller
# chose is what has to be standing at the end.
$script:ProgressBody = @'
param([Parameter(Mandatory)][string]$ModulePath, [Parameter(Mandatory)][string]$ResultPath)
$global:ProgressPreference = 'Continue'
Import-Module $ModulePath -Global -Force -DisableNameChecking
Set-LogLevelPreference -Level Debug
Import-Module $ModulePath -Global -Force -DisableNameChecking
Set-LogLevelPreference -Level Debug
Set-LogLevelPreference -Level Information
Set-Content -LiteralPath $ResultPath -Value ([string]$global:ProgressPreference) -Encoding utf8
'@

Describe 'Start-YurunaChildTranscript -- one writer per process across forced re-imports' {

    It 'opens a single transcript that survives two forced re-imports of the module' {
        $run = Invoke-TranscriptChild -Body $script:ForcedReimportBody
        Assert-Equal -Expected 0 -Actual $run.ExitCode -Because "the scenario child must exit clean: $($run.Output)"
        Assert-Equal -Expected 1 -Actual $run.TranscriptFile.Count `
            'the name is derived from $PID, so one process must leave exactly one transcript file'

        # A second writer is invisible while the process lives -- it announces
        # itself only by the end block it flushes on the way out.
        Assert-Equal -Expected 1 -Actual (Measure-Occurrence -Text $run.TranscriptText -Needle 'PowerShell transcript start') `
            'one writer opens the file once'
        Assert-Equal -Expected 1 -Actual (Measure-Occurrence -Text $run.TranscriptText -Needle 'PowerShell transcript end') `
            'a second Start-Transcript on the same path is what an extra end block means, and its writer overwrites this one at its own offset'
    }

    It 'hands every caller in the process the same path' {
        $run = Invoke-TranscriptChild -Body $script:ForcedReimportBody
        Assert-Equal -Expected 3 -Actual $run.Result.Count 'the child records one path per call'
        Assert-True ($run.Result[0]) 'the first call must start a transcript when the directory is set'
        Assert-Equal -Expected $run.Result[0] -Actual $run.Result[1] 'a re-imported module must report the transcript already open'
        Assert-Equal -Expected $run.Result[0] -Actual $run.Result[2] 'and keep reporting it'
        Assert-Equal -Expected $run.TranscriptFile[0].FullName -Actual $run.Result[0] `
            'the reported path is the file that was actually written'
    }

    It 'records every line once, in order' {
        $run = Invoke-TranscriptChild -Body $script:ForcedReimportBody
        foreach ($i in 1..3) {
            Assert-Equal -Expected 1 -Actual (Measure-Occurrence -Text $run.TranscriptText -Needle "child-marker-$i") `
                "marker $i belongs in the transcript exactly once"
        }
        $one = $run.TranscriptText.IndexOf('child-marker-1')
        $two = $run.TranscriptText.IndexOf('child-marker-2')
        $three = $run.TranscriptText.IndexOf('child-marker-3')
        Assert-True ($one -lt $two -and $two -lt $three) 'the transcript is a record of what happened in the order it happened'
    }
}

Describe 'Set-LogLevelPreference -- the captured ProgressPreference survives a forced re-import' {

    It 'restores the value the caller chose, not the one the cascade suppressed' {
        $run = Invoke-TranscriptChild -Body $script:ProgressBody
        Assert-Equal -Expected 0 -Actual $run.ExitCode -Because "the scenario child must exit clean: $($run.Output)"
        Assert-Equal -Expected 'Continue' -Actual ($run.Result -join '') `
            'a capture slot that a re-import empties records SilentlyContinue as the caller value and pins the progress bar off for the rest of the run'
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
