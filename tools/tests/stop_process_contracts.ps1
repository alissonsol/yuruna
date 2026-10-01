<#PSScriptInfo
.VERSION 2026.09.30
.GUID 4258c050-6380-4115-a3fa-d4c318889f35
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test contracts
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'The extracted production scriptblock consumes the deployment variable dynamically.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Harmless fixtures implement the production command signatures.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'This standalone fixture shadows process commands so it cannot stop real host processes.')]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source = Get-Content (Join-Path $root 'test/service/Stop-ExtensionService.ps1') -Raw
$start = $source.IndexOf('$m = Read-ExtensionServiceMarker')
$end = $source.IndexOf('# --- REGION: Publish the service withdrawal', $start)
$body = $source.Substring($start, $end-$start).Replace('exit $ExitFailure', "throw 'stop-incomplete'")
. ([scriptblock]::Create('function Invoke-StopFixture { [CmdletBinding(SupportsShouldProcess)] param() ' + $body + ' }'))
function Format-YurunaOperatorMessage { param($Key, $Arguments) $Key }
function Read-ExtensionServiceMarker { return @{ Pid=42 } }
function Remove-ExtensionServiceMarker { [CmdletBinding(SupportsShouldProcess)] param($Area,$RuntimeDir) if ($PSCmdlet.ShouldProcess('fixture', 'remove marker')) { $script:removed++; return $script:mode -ne 'marker-denied' } }
function Get-ExtensionServiceHostProcessState {
    param($ProcessId,$ProcessStartUnixMs,$ExpectedName)
    if ($script:mode -eq 'already-exited') { return @{IdentityVerified=$false;Alive=$false;Reason='not-running'} }
    if ($script:mode -eq 'lookup-denied') { return @{IdentityVerified=$false;Alive=$false;Reason='access-denied'} }
    return @{IdentityVerified=$true;Alive=$true;Reason='verified'}
}
function Get-Process {
    [CmdletBinding()] param($Id)
    $start = [DateTimeOffset]::FromUnixTimeMilliseconds($script:startMs).LocalDateTime
    if ($script:mode -eq 'pid-reused') { $start = $start.AddMinutes(1) }
    $p = [pscustomobject]@{SafeHandle=1;StartTime=$start;HasExited=($script:mode -eq 'exit-race')}
    $p | Add-Member ScriptMethod WaitForExit { param($Milliseconds) return $script:mode -ne 'still-alive' }
    $p | Add-Member ScriptMethod Dispose {}
    return $p
}
function Stop-Process { [CmdletBinding(SupportsShouldProcess)] param($InputObject,[switch]$Force) if ($PSCmdlet.ShouldProcess('fixture', 'stop process')) { $script:stopped++; if ($script:mode -in @('stop-denied','exit-race')) { throw 'denied' } } }
$script:startMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$deployment = @{Pid=42;ProcessStartUnixMs=$script:startMs};$Area='fixture';$runtimeDir='unused'
$count=0
foreach ($case in @('stop-denied','still-alive','pid-reused','lookup-denied','marker-denied','already-exited','exit-race','success')) {
    $script:mode=$case;$script:removed=0;$script:stopped=0;$failed=$false
    try { Invoke-StopFixture -Confirm:$false } catch { if ($_.Exception.Message -ne 'stop-incomplete') { throw };$failed=$true }
    $expectedFailure=$case -in @('stop-denied','still-alive','pid-reused','lookup-denied','marker-denied')
    if ($failed -ne $expectedFailure) { throw "$case returned incorrect stop result" }
    if ($case -in @('stop-denied','still-alive','pid-reused','lookup-denied') -and $script:removed -ne 0) { throw "$case cleared a live/uncertain marker" }
    if ($case -in @('pid-reused','lookup-denied') -and $script:stopped -ne 0) { throw "$case attempted unverified termination" }
    if (-not $expectedFailure -and $script:removed -ne 1) { throw "$case retained a stopped marker" }
    $count++
}
"Stop process contracts: $count cases passed."
