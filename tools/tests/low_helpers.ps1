<#PSScriptInfo
.VERSION 2026.09.30
.GUID 421b72b3-1b95-4a2f-a951-2add0fb977c6
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
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'The fixture implements the web request signature without making network calls.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'This standalone fixture replaces web requests to count resolutions without network access.')]
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
Import-Module (Join-Path $root 'host/modules/Yuruna.Image.psm1') -Force -DisableNameChecking
$count=0
foreach($case in @(@{ Record=$null; Want=0 },@{Record=[pscustomobject]@{Exception=[pscustomobject]@{Response=[pscustomobject]@{StatusCode=[Net.HttpStatusCode]::NotFound};Message=''} };Want=404},@{Record=[pscustomobject]@{Exception=[Exception]::new('HTTP 410 gone')};Want=410},@{Record=[pscustomobject]@{Exception=[Exception]::new('unknown')};Want=0})) {
 if ((Get-YurunaHttpErrorStatus $case.Record) -ne $case.Want) {throw 'HTTP status mismatch'};$count++
}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'automation/Check-DependencyVersion.ps1'),[ref]$tokens,[ref]$errors)
$function=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-GitHubLatestTag'},$true)
. ([scriptblock]::Create($function.Extent.Text))
function Invoke-WebRequest { param($Uri,$Method,$MaximumRedirection,$TimeoutSec,$ErrorAction) $script:calls++; if ($Uri -like '*bad*') {throw 'fixture failure'};[pscustomobject]@{BaseResponse=[pscustomobject]@{RequestMessage=[pscustomobject]@{RequestUri='https://github.com/test/repo/releases/tag/v1.2.3'}}} }
$script:GitHubLatestTagCache=@{};$script:calls=0
1..3|ForEach-Object {if((Get-GitHubLatestTag 'test/repo') -ne '1.2.3'){throw 'version mismatch'}}
1..3|ForEach-Object {try {Get-GitHubLatestTag 'test/bad';throw 'missing error'}catch{if($_.Exception.Message -ne 'fixture failure'){throw}}}
if($script:calls -ne 2){throw "Requests not cached: $script:calls"}
"Shared helper contracts: $count HTTP cases; success and failure each fetched once."
