<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42a8d418-346c-4b29-bf3f-051073afc17f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
<#
.SYNOPSIS
    Control a bounded worker fault through an authenticated disposable proxy.
.DESCRIPTION
    SSH uses existing verified host keys and noninteractive sudo. Outage
    injection appends a private unit environment file, preserves existing Git
    configuration and schedules automatic restoration after fifteen minutes.
    A caller must still use RestoreOutage in finally to restore immediately.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('EnableOutage', 'RestoreOutage', 'NoUpstream', 'Populate', 'KillMidFetch')][string]$Action,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.@:-]*$')][string]$ProxyHost,
    [Parameter(Mandatory)][string]$SshKeyPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string]$RunId,
    [ValidateSet('Reset', 'Unauthorized')][string]$Mode = 'Reset',
    [string]$Repository,
    [string]$Ref = 'HEAD',
    [Parameter(Mandatory)][string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$request = @{ action = $Action; runId = $RunId; mode = $Mode; repository = $Repository; ref = $Ref }
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($request | ConvertTo-Json -Compress))).Replace('+', '-').Replace('/', '_')
$start = [Diagnostics.ProcessStartInfo]::new((Get-Command ssh -CommandType Application).Source)
foreach ($argument in @('-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=10',
        '-i', [IO.Path]::GetFullPath($SshKeyPath), $ProxyHost,
        "sudo -n python3 -c 'import sys; s=sys.stdin.read(); exec(compile(s,`"native-worker`",`"exec`"),{`"__name__`":`"__main__`",`"_PROGRAM`":s})' $encoded")) {
    $start.ArgumentList.Add($argument)
}
$start.UseShellExecute = $false
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$process = [Diagnostics.Process]::Start($start)
try {
    $out = $process.StandardOutput.ReadToEndAsync()
    $errors = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write([IO.File]::ReadAllText((Join-Path $PSScriptRoot git_mirror_native_worker.py)))
    $process.StandardInput.Close()
    $timeout = if ($Action -ceq 'Populate') { 1950000 } elseif ($Action -ceq 'KillMidFetch') { 360000 } else { 180000 }
    if (-not $process.WaitForExit($timeout)) { $process.Kill($true); throw 'Native worker control timed out; its restoration timer remains armed.' }
    if ($process.ExitCode) { throw "Native worker control failed: $($errors.GetAwaiter().GetResult())" }
    $result = $out.GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), ($result | ConvertTo-Json -Depth 20) + "`n")
    if (-not $result.passed) { throw 'Native worker observation did not satisfy the scenario.' }
} finally {
    if (-not $process.HasExited) { $process.Kill($true) }
    $process.Dispose()
}
