<#PSScriptInfo
.VERSION 2026.09.30
.GUID 426b2ade-32fc-41ee-bab9-d00d395635bd
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test status service host diagnostic worker pester
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
    The detached host-diagnostic worker: one bounded run at a time, a report
    and a state record in the private worker directory, and nothing anywhere
    the listener serves.
.DESCRIPTION
    Each case runs the real worker as its own process with a scratch HOME, so
    the private state root, the single-flight lock and the bounded native
    call are the real ones. The diagnostic script is a stand-in that prints,
    sleeps, floods or fails on request.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.SingleFlightLock.psm1') -Force -Global -DisableNameChecking

$script:Worker = Join-Path $here 'Invoke-HostDiagnosticWorker.ps1'
$script:Pwsh = (Get-Process -Id $PID).Path

function New-DiagnosticScratch {
    <#
    .SYNOPSIS
        A scratch HOME, runtime and log directory, and a stand-in diagnostic.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates a throwaway test tree.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$DiagnosticBody)
    $root = New-YurunaTestTempDir -Prefix 'yuruna-diag-worker'
    $homeDir = Join-Path $root 'home'
    $runtime = Join-Path $root 'runtime'
    $log = Join-Path $root 'log'
    $null = New-Item -ItemType Directory -Path $homeDir, $runtime, $log
    $diagnostic = Join-Path $root 'Get-SystemDiagnostic.ps1'
    [IO.File]::WriteAllText($diagnostic, $DiagnosticBody)
    return [pscustomobject]@{
        Root = $root; Home = $homeDir; Runtime = $runtime; Log = $log; Diagnostic = $diagnostic
        WorkDirectory = (Join-Path $homeDir '.yuruna/host-refresh/host-diagnostic')
    }
}

function Invoke-DiagnosticWorker {
    <#
    .SYNOPSIS
        Run the worker as its own process under the scratch HOME.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Scratch,
        [string]$RunId = [Guid]::NewGuid().ToString('D'),
        [string]$WorkDirectory,
        [string]$DiagnosticScriptPath,
        [int]$TimeoutSeconds = 30,
        [int]$MaxReportBytes = 4194304
    )
    $workDir = if ($WorkDirectory) { $WorkDirectory } else { $Scratch.WorkDirectory }
    $script = if ($DiagnosticScriptPath) { $DiagnosticScriptPath } else { $Scratch.Diagnostic }
    $saved = @{}
    foreach ($name in @('HOME', 'USERPROFILE', 'YURUNA_RUNTIME_DIR', 'YURUNA_LOG_DIR')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        # Windows derives the home directory from USERPROFILE, not HOME.
        $env:HOME = $Scratch.Home
        $env:USERPROFILE = $Scratch.Home
        $env:YURUNA_RUNTIME_DIR = $Scratch.Runtime
        $env:YURUNA_LOG_DIR = $Scratch.Log
        $output = & $script:Pwsh -NoProfile -NonInteractive -File $script:Worker -RunId $RunId -DiagnosticScriptPath $script `
            -WorkDirectory $workDir -WorkingDirectory $Scratch.Root -TimeoutSeconds $TimeoutSeconds -MaxReportChars 65536 -MaxReportBytes $MaxReportBytes 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        foreach ($name in $saved.Keys) {
            if ($null -eq $saved[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        }
    }
    $state = $null
    $statePath = Join-Path $Scratch.WorkDirectory 'state.json'
    if (Test-Path -LiteralPath $statePath) { $state = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($statePath)) }
    $resultPath = Join-Path $Scratch.WorkDirectory 'result.txt'
    $result = if (Test-Path -LiteralPath $resultPath) { [IO.File]::ReadAllText($resultPath) } else { $null }
    return [pscustomobject]@{ ExitCode = $code; State = $state; Result = $result; Output = ($output -replace "`e\[[0-9;]*[A-Za-z]", ''); RunId = $RunId }
}

function Get-ServedWrite {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)]$Scratch)
    return [string[]]@(Get-ChildItem -LiteralPath $Scratch.Runtime, $Scratch.Log -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
}
}

Describe 'the host diagnostic runs detached, bounded and single flight' {

    It 'completes, writing the report and a completed state in the private directory only' {
        $scratch = New-DiagnosticScratch -DiagnosticBody "Write-Output 'host report line'`n[Console]::Error.WriteLine('a warning line')`nexit 3"
        try {
            $run = Invoke-DiagnosticWorker -Scratch $scratch
            Assert-Equal 0 $run.ExitCode "the worker failed: $($run.Output)"
            Assert-StringEqual 'completed' $run.State.phase
            Assert-StringEqual $run.RunId $run.State.runId
            Assert-Equal 3 ([int]$run.State.exitCode) 'the diagnostic exit code is recorded, and a non-zero one still serves its report'
            Assert-False $run.State.timedOut
            Assert-Match 'host report line' $run.Result
            Assert-Match 'a warning line' $run.Result 'stderr is part of the report'
            Assert-True ($null -ne $run.State.completedUtc -and $null -ne $run.State.startedUtc)
            Assert-Equal 0 @(Get-ServedWrite -Scratch $scratch).Count 'nothing is written under the runtime or log directories'
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }

    It 'fails with timedOut when the diagnostic outlives its bound' {
        $scratch = New-DiagnosticScratch -DiagnosticBody "Write-Output 'started'`nStart-Sleep -Seconds 60"
        try {
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $run = Invoke-DiagnosticWorker -Scratch $scratch -TimeoutSeconds 10
            $watch.Stop()
            Assert-Equal 1 $run.ExitCode
            Assert-StringEqual 'failed' $run.State.phase
            Assert-StringEqual 'timeout' $run.State.reason
            Assert-True $run.State.timedOut
            Assert-True ($watch.Elapsed.TotalSeconds -lt 40) "the bounded run took $([int]$watch.Elapsed.TotalSeconds) s"
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }

    It 'marks a report cut at its cap as truncated' {
        $scratch = New-DiagnosticScratch -DiagnosticBody "[Console]::Out.Write(('x' * 5242880))"
        try {
            $run = Invoke-DiagnosticWorker -Scratch $scratch
            Assert-Equal 0 $run.ExitCode "the worker failed: $($run.Output)"
            Assert-True $run.State.truncated 'a 5 MB report over a 64 KB cap is truncated'
            Assert-True ($run.Result.Length -lt 200000) "the stored report is $($run.Result.Length) characters"
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }

    It 'keeps the stored report within the byte cap the listener serves, cutting between characters' {
        # Two streams, each under the per-stream character cap, of two-byte
        # characters: together about 160 KB of UTF-8 against a 64 KiB cap.
        $scratch = New-DiagnosticScratch -DiagnosticBody "[Console]::Out.Write(([string][char]0xE9) * 40000)`n[Console]::Error.Write(([string][char]0xE9) * 40000)"
        try {
            $run = Invoke-DiagnosticWorker -Scratch $scratch -MaxReportBytes 65536
            Assert-Equal 0 $run.ExitCode "the worker failed: $($run.Output)"
            Assert-StringEqual 'completed' $run.State.phase
            Assert-True $run.State.truncated 'a report cut to the byte cap is marked truncated'
            $bytes = [IO.File]::ReadAllBytes((Join-Path $scratch.WorkDirectory 'result.txt'))
            Assert-True ($bytes.Length -le 65536) "the stored report is $($bytes.Length) bytes"
            Assert-True ($bytes.Length -gt 60000) "the cap is used, not wasted: $($bytes.Length) bytes"
            $strict = [System.Text.UTF8Encoding]::new($false, $true)
            $text = $strict.GetString($bytes)
            Assert-Match 'runner\.host_diagnostic_worker_truncated|truncated' $text 'the report ends with its truncation notice'
            Assert-True ($text.IndexOf([char]0xFFFD) -lt 0) 'no character was split by the cut'
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }

    It 'fails with script_missing when the diagnostic script is absent' {
        $scratch = New-DiagnosticScratch -DiagnosticBody ''
        try {
            $run = Invoke-DiagnosticWorker -Scratch $scratch -DiagnosticScriptPath (Join-Path $scratch.Root 'absent.ps1')
            Assert-Equal 1 $run.ExitCode
            Assert-StringEqual 'failed' $run.State.phase
            Assert-StringEqual 'script_missing' $run.State.reason
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }

    It 'writes nothing when another run holds the diagnostic' {
        $scratch = New-DiagnosticScratch -DiagnosticBody "Write-Output 'should not run'"
        try {
            $null = New-Item -ItemType Directory -Path $scratch.WorkDirectory -Force
            if (-not $IsWindows) { [IO.File]::SetUnixFileMode($scratch.WorkDirectory, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute') }
            $held = Enter-YurunaSingleFlightLock -Path (Join-Path $scratch.WorkDirectory 'host-diagnostic.lock')
            Assert-True $held.Held "the test could not take the lock: $($held.Reason)"
            try {
                $run = Invoke-DiagnosticWorker -Scratch $scratch
            } finally { Exit-YurunaSingleFlightLock -Lock $held }
            Assert-Equal 0 $run.ExitCode 'a second worker is not a failure'
            Assert-Null $run.State 'a second worker writes no state'
            Assert-Null $run.Result 'a second worker writes no report'
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }

    It 'refuses a run id that is not canonical and a directory that is not the private one' {
        $scratch = New-DiagnosticScratch -DiagnosticBody "Write-Output 'should not run'"
        try {
            $badId = Invoke-DiagnosticWorker -Scratch $scratch -RunId '../../etc/passwd'
            Assert-Equal 1 $badId.ExitCode
            Assert-Null $badId.State
            $elsewhere = Join-Path $scratch.Runtime 'diag'
            $null = New-Item -ItemType Directory -Path $elsewhere
            $moved = Invoke-DiagnosticWorker -Scratch $scratch -WorkDirectory $elsewhere
            Assert-Equal 1 $moved.ExitCode
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $elsewhere -Force).Count 'nothing is written to a directory the listener did not resolve'
        } finally { Remove-YurunaTestTempDir $scratch.Root }
    }
}
