<#PSScriptInfo
.VERSION 2026.10.22
.GUID 420b7b98-2589-4376-880f-0fbafee4bca6
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
<#
.SYNOPSIS
    Validate native mirror evidence against independently measured release inputs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CandidateManifestPath,
    [Parameter(Mandatory)][string]$EvidencePath,
    [Parameter(Mandatory)][string]$FrameworkRoot,
    [Parameter(Mandatory)][string]$ProjectRoot,
    [Parameter(Mandatory)][string]$SourceFrameworkCommit,
    [Parameter(Mandatory)][string]$SourceProjectCommit,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GitMirror.Qualification.psm1') -Force
try {
    $candidate = Test-GitMirrorCandidate -CandidateManifestPath $CandidateManifestPath -FrameworkRoot $FrameworkRoot `
        -ProjectRoot $ProjectRoot -SourceFrameworkCommit $SourceFrameworkCommit -SourceProjectCommit $SourceProjectCommit
    $contract = Get-GitMirrorQualificationContract -FrameworkRoot $FrameworkRoot
    $evidence = Get-Content -Raw -LiteralPath $EvidencePath | ConvertFrom-Json -AsHashtable
    $result = Test-GitMirrorQualificationEvidence -Candidate $candidate -Contract $contract -Evidence $evidence `
        -EvidenceDirectory (Split-Path -Parent ([IO.Path]::GetFullPath($EvidencePath)))
    if (-not $Quiet) { Write-Output "Git mirror qualification: $($result.rows) native rows passed for $($result.candidateId)." }
    exit 0
} catch {
    Write-Error -ErrorAction Continue "Git mirror qualification refused: $($_.Exception.Message)"
    exit 1
}
