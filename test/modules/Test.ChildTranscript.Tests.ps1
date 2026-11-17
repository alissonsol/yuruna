<#PSScriptInfo
.VERSION 2026.11.16
.GUID 427f1267-e087-42e4-ad77-aab3e3216101
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
if (-not (Get-Command -Name BeforeAll -ErrorAction SilentlyContinue)) { throw 'This suite requires Pester; run it with Invoke-Pester or Invoke-TestSuite.ps1.' }

BeforeAll {


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

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

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

    $work = New-YurunaTestTempDir -Prefix 'yuruna-transcript'
    $tdir = Join-Path $work 'transcript'
    New-Item -ItemType Directory -Force -Path $tdir | Out-Null
    $childScript = Join-Path $work 'child.ps1'
    $resultPath  = Join-Path $work 'result.txt'
    Set-Content -LiteralPath $childScript -Value $Body -Encoding utf8

    # The directory is the only switch that turns the transcript on and it is
    # read from the environment, so it has to be set around the launch and put
    # back exactly as it was for whatever runs after this test.
    $previous = Save-YurunaTestEnvironment -Name 'YURUNA_CHILD_TRANSCRIPT_DIR'
    try {
        $env:YURUNA_CHILD_TRANSCRIPT_DIR = $tdir
        $out = & (Get-PwshPath) -NoProfile -File $childScript -ModulePath $script:LogModule -ResultPath $resultPath 2>&1
        $code = $LASTEXITCODE
    } finally { Restore-YurunaTestEnvironment -Saved $previous }

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
    Remove-YurunaTestTempDir $work
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

}

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

Describe 'Read-only callers apply log levels without opening a child transcript' {
    It 'preserves an <Case> transcript directory and applies the inherited level' -ForEach @(
        @{ Case = 'absent'; Existing = $false }, @{ Case = 'existing'; Existing = $true }
    ) {
        $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $work)
        $transcripts = Join-Path $work 'transcripts'
        if ($Existing) {
            [void](New-Item -ItemType Directory -Path $transcripts)
            [IO.File]::WriteAllText((Join-Path $transcripts 'kept.log'), 'existing transcript bytes')
        }
        $before = @(Get-ChildItem -LiteralPath $transcripts -File -ErrorAction SilentlyContinue | ForEach-Object {
                "$($_.Name)|$((Get-FileHash -LiteralPath $_.FullName).Hash)|$($_.LastWriteTimeUtc.Ticks)"
            })
        $child = Join-Path $work 'readonly-child.ps1'
        $result = Join-Path $work 'level.txt'
        [IO.File]::WriteAllText($child, @'
param([string]$ModulePath, [string]$ResultPath)
Import-Module $ModulePath -Force -DisableNameChecking
Use-LogLevelFromEnv -NoTranscript
[IO.File]::WriteAllText($ResultPath, [string]$global:InformationPreference)
'@)
        $saved = Save-YurunaTestEnvironment -Name 'YURUNA_CHILD_TRANSCRIPT_DIR', 'YURUNA_LOG_LEVEL'
        try {
            $env:YURUNA_CHILD_TRANSCRIPT_DIR = $transcripts
            $env:YURUNA_LOG_LEVEL = 'Error'
            $output = & (Get-PwshPath) -NoProfile -File $child -ModulePath $script:LogModule -ResultPath $result 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because $output
        } finally { Restore-YurunaTestEnvironment -Saved $saved }
        (Get-Content -LiteralPath $result -Raw) | Should -Be 'SilentlyContinue'
        (Test-Path -LiteralPath $transcripts) | Should -Be $Existing
        $after = @(Get-ChildItem -LiteralPath $transcripts -File -ErrorAction SilentlyContinue | ForEach-Object {
                "$($_.Name)|$((Get-FileHash -LiteralPath $_.FullName).Hash)|$($_.LastWriteTimeUtc.Ticks)"
            })
        $after | Should -Be $before
    }

    It 'still starts the requested transcript when NoTranscript is omitted' {
        $run = Invoke-TranscriptChild -Body @'
param([string]$ModulePath, [string]$ResultPath)
Import-Module $ModulePath -Force -DisableNameChecking
Use-LogLevelFromEnv
Write-Output 'normal-transcript-marker'
Set-Content -LiteralPath $ResultPath -Value 'completed'
'@
        $run.ExitCode | Should -Be 0
        $run.TranscriptFile.Count | Should -Be 1
        $run.TranscriptText | Should -Match 'normal-transcript-marker'
    }
}

Describe 'Service builder logging supports an already-loaded legacy helper' {
    It '<Builder> preserves <Kind> logger behavior when PlanOnly is <Preview>' -ForEach @(
        foreach ($platform in 'ubuntu.kvm', 'macos.utm', 'windows.hyper-v') {
            foreach ($service in 'caching-proxy-service', 'stash-service', 'pool-control-service', 'download-agent-service') {
                foreach ($kind in 'legacy unbound', 'legacy advanced', 'modern') {
                    foreach ($preview in $true, $false) {
                        @{ Builder = "host/$platform/guest.$service/New-VM.ps1"; Kind = $kind; Preview = $preview }
                    }
                }
            }
        }
    ) {
        $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $script:LogModule))
        $builderAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $Builder), [ref]$null, [ref]$null)
        $prelude = @($builderAst.EndBlock.Statements | Where-Object { $_.Extent.Text -match '\bUse-LogLevelFromEnv\b' } |
                ForEach-Object { $_.Extent.Text }) -join "`n"
        $prelude | Should -Not -BeNullOrEmpty
        $definition = @'
function Use-LogLevelFromEnv {
    if ($env:YURUNA_LOG_LEVEL -and $script:LogLevelRank.Contains($env:YURUNA_LOG_LEVEL)) {
        Set-LogLevelPreference -Level $env:YURUNA_LOG_LEVEL
    }
    [void](Start-YurunaChildTranscript)
}
'@
        if ($Kind -eq 'legacy advanced') {
            $definition = $definition.Replace("function Use-LogLevelFromEnv {", "function Use-LogLevelFromEnv {`n    [CmdletBinding()]param()")
        } elseif ($Kind -eq 'modern') {
            $moduleAst = [Management.Automation.Language.Parser]::ParseFile($script:LogModule, [ref]$null, [ref]$null)
            $definition = $moduleAst.Find({ param($node)
                    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Use-LogLevelFromEnv'
                }, $true).Extent.Text
        }
        $saved = Save-YurunaTestEnvironment -Name 'YURUNA_LOG_LEVEL'
        try {
            $env:YURUNA_LOG_LEVEL = 'Error'
            $result = & {
                param($Definition, $Prelude, $Preview)
                Set-Variable -Name PlanOnly -Value $Preview
                $script:LogLevelRank = @{ Error = 1 }
                $script:TranscriptCalls = 0
                $script:PreferenceCalls = 0
                $script:ReloadCalls = 0
                Set-Item -Path Function:Start-YurunaChildTranscript -Value { $script:TranscriptCalls++ }
                Set-Item -Path Function:Set-LogLevelPreference -Value { $script:PreferenceCalls++ }
                Set-Item -Path Function:Import-Module -Value { $script:ReloadCalls++ }
                . ([scriptblock]::Create($Definition))
                . ([scriptblock]::Create($Prelude))
                @{ Transcripts = $script:TranscriptCalls; Preferences = $script:PreferenceCalls; Reloads = $script:ReloadCalls }
            } $definition $prelude $Preview
        } finally { Restore-YurunaTestEnvironment -Saved $saved }
        $result.Transcripts | Should -Be ([int](-not $Preview))
        $result.Reloads | Should -Be 0
        $expectedPreferences = if ($Preview -and $Kind -ne 'modern') { 0 } else { 1 }
        $result.Preferences | Should -Be $expectedPreferences
    }
}
