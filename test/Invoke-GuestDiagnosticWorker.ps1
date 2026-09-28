<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42825670-92b0-42e5-b870-019a40a7b0be
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna diagnostics worker
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
<#
.SYNOPSIS
    Collects guest diagnostics inside the supervisor's process deadline.
.DESCRIPTION
    Receives non-secret invocation context through a private request file.
    Host drivers and vault extensions execute only in this child process, so
    a blocked provider cannot prevent the runner from reaching its next step.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Restores the shared SSH session anchors inside this isolated worker process.')]
param([Parameter(Mandatory)][string]$RequestPath)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$request = [System.IO.File]::ReadAllText($RequestPath) | ConvertFrom-Json -AsHashtable
Set-Location -LiteralPath $request.WorkingDirectory
$global:YurunaGuestSshUserOverrides = $request.GuestSshUserOverrides
$global:YurunaProvenGuestAddress = $request.ProvenGuestAddress
# JSON dates remain strings on some PowerShell versions. Preserve the original
# observation time instead of refreshing the age of a cached guest address.
foreach ($entry in $global:YurunaProvenGuestAddress.Values) {
    if ($entry.AtUtc -isnot [datetime]) {
        $entry.AtUtc = [datetime]::Parse([string]$entry.AtUtc, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
    }
}
Import-Module (Join-Path $PSScriptRoot '../automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking
$localeModule = Get-Module Yuruna.Globalization
if ($request.OperatorLocaleContext) {
    # Pass the resolved locale directly, including pseudo-locales which have
    # no operating-system CultureInfo representation.
    & $localeModule { param($Context) $script:OperatorContext = $Context } $request.OperatorLocaleContext
    Import-Module (Join-Path $PSScriptRoot 'modules/Test.Catalog.psm1') -Global -DisableNameChecking
}
Import-Module (Join-Path $PSScriptRoot 'modules/Test.Diagnostic.psm1') -Global -DisableNameChecking
# The host driver imports shared modules too; load it after the diagnostic
# module to leave its console dispatchers bound to the correct host.
if ($request.HostModulePath) { Import-Module $request.HostModulePath -Global -DisableNameChecking }
$diagnosticModule = Get-Module Test.Diagnostic
$manifest = & $diagnosticModule {
    param($Context)
    $script:SaveGuestDiagnosticTotalTimeoutSeconds = [int]$Context.TimeoutSeconds
    $script:SaveGuestDiagnosticPerCommandTimeoutSeconds = [int]$Context.PerCommandTimeoutSeconds
    $script:GuestDiagnosticDeadline = New-YurunaDeadlineFromExpiry -ExpiryTick ([long]$Context.ExpiryTick)
    $script:GuestDiagnosticFileName = [string]$Context.DiagnosticsFileName
    $script:GuestDiagnosticCaptureId = [string]$Context.CaptureId
    $script:GuestDiagnosticCheckpointPath = [string]$Context.CheckpointPath
    $script:GuestDiagnosticCheckpointManifest = @{
        success=$false; outPath=$null; mechanism='none'; attempted=@(); exitCode=-1
        bytes=0L; skipped=$false; stepInvocationId=$Context.StepInvocationId
        sequenceInvocationId=$Context.SequenceInvocationId; hostSnapshot=$Context.HostSnapshot
    }
    Update-GuestDiagnosticCheckpoint -Values @{}
    Save-GuestDiagnosticCore -VMName $Context.VMName -GuestKey $Context.GuestKey `
        -OutputFolder $Context.OutputFolder -Id $Context.Id -HostSnapshot $Context.HostSnapshot `
        -StepInvocationId $Context.StepInvocationId -SequenceInvocationId $Context.SequenceInvocationId
} $request
$envelope = @{ captureId=$request.CaptureId; manifest=$manifest }
$tempPath = "$($request.ResultPath).tmp"
[System.IO.File]::WriteAllText($tempPath, ($envelope | ConvertTo-Json -Depth 12))
[System.IO.File]::Move($tempPath, $request.ResultPath, $true)
