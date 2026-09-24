<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42a6bdf9-496a-46e5-9f44-7ae4c1d0e643
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host performance diagnostics arm64
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
<#
.SYNOPSIS
    Capture bounded read-only host counters and configuration into one evidence ZIP.
.DESCRIPTION
    Run on the Windows host during a slow phase. No VM or host settings change.
    Optional WPR recording uses memory mode and refuses to start when an existing
    recording cannot be ruled out. See https://yuruna.link/42dc5bb9-0010.
.PARAMETER DurationSeconds
    Sampling window, normally 60 seconds, with an additional bounded startup allowance.
.PARAMETER IntervalSeconds
    Counter interval; the operator capture defaults to two seconds.
.PARAMETER OutputDirectory
    New evidence directory. Defaults to a unique directory under the temporary folder.
.PARAMETER Trace
    Also capture an available CPU WPR profile, preserving any existing recording.
.PARAMETER Phase
    Label describing the observed slow phase; retained with UTC and monotonic anchors.
.PARAMETER GuestAddress
    Optional reachable Linux guest to include through existing SSH key authentication.
.PARAMETER GuestUser
    Existing guest account used with GuestAddress; no passwords are accepted.
.PARAMETER Worker
    Internal dedicated sampler mode used by the outer runner and this script.
.PARAMETER OwnerProcessId
    Internal lifetime owner for a dedicated sampler process.
.EXAMPLE
    pwsh automation/Collect-HostPerformance.ps1 -Phase prerequisite-packages
#>
[CmdletBinding()]
param(
    [ValidateRange(1,86400)][int]$DurationSeconds = 60,
    [ValidateRange(1,300)][int]$IntervalSeconds = 2,
    [string]$OutputDirectory,
    [switch]$Trace,
    [string]$Phase = 'unspecified',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.:%_-]*$')][string]$GuestAddress,
    [ValidatePattern('^[A-Za-z0-9_][A-Za-z0-9_.-]*$')][string]$GuestUser,
    [switch]$Worker,
    [int]$OwnerProcessId = 0
)

Import-Module (Join-Path $PSScriptRoot 'Yuruna.Globalization.psm1') -DisableNameChecking

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../test/modules/Test.HostSampling.psm1') -Force
if (-not $OutputDirectory) { $OutputDirectory = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-host-performance-' + [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N')) }
if ($Worker) {
    Invoke-YurunaHostSampling -Directory $OutputDirectory -DurationSeconds $DurationSeconds -IntervalSeconds $IntervalSeconds -OwnerProcessId $OwnerProcessId
    return
}
if (($GuestAddress -and -not $GuestUser) -or ($GuestUser -and -not $GuestAddress)) { throw (Format-YurunaOperatorMessage -Key 'automation.operator_ee4c81412b67b1c2') }
if (Test-Path -LiteralPath $OutputDirectory) { throw (Format-YurunaOperatorMessage -Key 'automation.operator_b5362b267131b912') }
$null = [IO.Directory]::CreateDirectory($OutputDirectory)
$traceOwned = $false
$traceInfo = [ordered]@{ Requested=[bool]$Trace; Status='not-requested'; Reason='' }
$workerProcess = $null
$started = [Diagnostics.Stopwatch]::StartNew()
$manifest = [ordered]@{ Utc=[datetime]::UtcNow.ToString('o'); MonotonicTicks=[Diagnostics.Stopwatch]::GetTimestamp(); MonotonicFrequency=[Diagnostics.Stopwatch]::Frequency; ClockDomain='host-qpc'; Phase=$Phase; DurationSeconds=$DurationSeconds; IntervalSeconds=$IntervalSeconds; Status='partial'; Trace=$traceInfo }
try {
    if ($Trace) {
        $wpr = Get-Command wpr.exe -ErrorAction SilentlyContinue
        if (-not $wpr) { $traceInfo.Status='unavailable'; $traceInfo.Reason=(Format-YurunaOperatorMessage -Key 'automation.operator_eac08d333d18b400') }
        else {
            $status = Invoke-YurunaHostBoundedCommand -FilePath $wpr.Source -ArgumentList @('-status') -TimeoutSeconds 5
            $profiles = Invoke-YurunaHostBoundedCommand -FilePath $wpr.Source -ArgumentList @('-profiles') -TimeoutSeconds 5
            $status.Output | Set-Content (Join-Path $OutputDirectory 'wpr-status.txt')
            $profiles.Output | Set-Content (Join-Path $OutputDirectory 'wpr-profiles.txt')
            if ($status.Status -eq 'complete' -and $status.Output -match '(?im)^\s*WPR is not recording\.?\s*$' -and $profiles.Output -match '(?im)^\s*CPU\s') {
                $start = Invoke-YurunaHostBoundedCommand -FilePath $wpr.Source -ArgumentList @('-start','CPU') -TimeoutSeconds 10
                $traceOwned = ($start.Status -eq 'complete' -and $start.ExitCode -eq 0)
                $traceInfo.Status = if ($traceOwned) { 'recording' } else { 'unavailable' }
                $traceInfo.Reason = $start.Output
                if ($start.Status -eq 'timeout') { $traceInfo.Status='uncertain'; $traceInfo.Reason=(Format-YurunaOperatorMessage -Key 'automation.operator_f250b44132d70fac') }
                if ($traceOwned) { $null = Invoke-YurunaHostBoundedCommand -FilePath $wpr.Source -ArgumentList @('-marker', "Yuruna phase: $Phase") -TimeoutSeconds 5 }
            } else { $traceInfo.Status='preserved'; $traceInfo.Reason=(Format-YurunaOperatorMessage -Key 'automation.operator_db72b63273de3023') }
        }
    }
    $info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    foreach ($arg in @('-NoLogo','-NoProfile','-NonInteractive','-File',$PSCommandPath,'-Worker','-OutputDirectory',$OutputDirectory,'-DurationSeconds',"$DurationSeconds",'-IntervalSeconds',"$IntervalSeconds",'-OwnerProcessId',"$PID")) { $info.ArgumentList.Add($arg) }
    $workerProcess = [Diagnostics.Process]::Start($info)
    $capture = [Diagnostics.Stopwatch]::StartNew()
    $progress = [Diagnostics.Stopwatch]::StartNew()
    $lastToken = ''
    while (-not $workerProcess.WaitForExit(500)) {
        $last = @(Get-ChildItem -LiteralPath $OutputDirectory -Filter 'samples.*.ndjson' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
        $token = if ($last.Count) { "$($last[0].Name):$($last[0].Length):$($last[0].LastWriteTimeUtc.Ticks)" } else { '' }
        if ($token -ne $lastToken) { $progress.Restart(); $lastToken = $token }
        if ($GuestAddress -and -not $manifest.Contains('Guest') -and $last.Count -and $capture.Elapsed.TotalSeconds -ge ($DurationSeconds / 2)) {
            $sampleReady = try { (Get-Content -LiteralPath $last[0].FullName -Tail 1 | ConvertFrom-Json).Kind -eq 'sample' } catch { $false }
            if ($sampleReady) {
                $guest = [ordered]@{ Address=$GuestAddress; BeforeUtc=[datetime]::UtcNow.ToString('o'); BeforeMonotonicTicks=[Diagnostics.Stopwatch]::GetTimestamp(); MonotonicFrequency=[Diagnostics.Stopwatch]::Frequency; Status='unavailable' }
                $ssh = Get-Command ssh -ErrorAction SilentlyContinue
                if ($ssh) {
                    $scriptText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'guest-performance-snapshot.sh') -Raw
                    $result = Invoke-YurunaHostBoundedCommand -FilePath $ssh.Source -ArgumentList @('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=5','-l',$GuestUser,'--',$GuestAddress,'bash -s') -InputText $scriptText -TimeoutSeconds 20
                    $result.Output | Set-Content -LiteralPath (Join-Path $OutputDirectory 'guest-performance.txt') -Encoding utf8
                    $guest.Status=if ($result.Status -eq 'complete' -and $result.ExitCode -ne 0) { 'failed' } else { $result.Status }
                    $guest.ExitCode=$result.ExitCode
                } else { $guest.Reason='SSH executable unavailable.' }
                $guest.AfterUtc=[datetime]::UtcNow.ToString('o'); $guest.AfterMonotonicTicks=[Diagnostics.Stopwatch]::GetTimestamp()
                $manifest.Guest=$guest
            }
        }
        if ($capture.Elapsed.TotalSeconds -gt $DurationSeconds + 45 -or $progress.Elapsed.TotalSeconds -gt [math]::Max(45, $IntervalSeconds * 3)) {
            $workerProcess.Kill($true)
            $manifest.Status='timeout'
            break
        }
    }
    if ($manifest.Status -ne 'timeout') { $manifest.Status=if ($workerProcess.ExitCode -eq 0) { 'complete' } else { 'partial' }; $manifest.WorkerExitCode=$workerProcess.ExitCode }
    if ($GuestAddress -and -not $manifest.Contains('Guest')) { $manifest.Guest=@{Status='unavailable'; Reason=(Format-YurunaOperatorMessage -Key 'automation.operator_de580b5b7b4a75be')} }

} finally {
    if ($workerProcess -and -not $workerProcess.HasExited) { $workerProcess.Kill($true) }
    if ($traceOwned) {
        $stop = Invoke-YurunaHostBoundedCommand -FilePath $wpr.Source -ArgumentList @('-stop',(Join-Path $OutputDirectory 'host.etl'),"Yuruna phase: $Phase") -TimeoutSeconds 30
        $traceInfo.Status=if ($stop.Status -eq 'complete' -and $stop.ExitCode -eq 0) { 'complete' } else { 'partial' }
        $traceInfo.Reason=$stop.Output
    }
    $manifest.ElapsedSeconds=$started.Elapsed.TotalSeconds
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'capture.json') -Encoding utf8
    Compress-Archive -LiteralPath $OutputDirectory -DestinationPath ($OutputDirectory + '.zip')
    Write-Output ($OutputDirectory + '.zip')
}
