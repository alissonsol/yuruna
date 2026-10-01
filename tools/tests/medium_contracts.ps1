<#PSScriptInfo
.VERSION 2026.09.30
.GUID 421d4450-b529-4d80-a244-126649692f4f
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
# Native regression contracts; no VM, firewall, or provider is modified.
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are consumed by the production writer scriptblock extracted at runtime.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fixture functions retain the production command parameter contract.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'New-YurunaResultManifest is a pure fixture that returns a hashtable.')]
param([string]$Tofu = 'tofu')
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$count = 0
function Assert-Contract($Condition, $Message) {
    if (-not $Condition) { throw $Message }
    $script:count++
}
function Read-FunctionSource($Path, $Names) {
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    ($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in $Names }.GetNewClosure(), $true) | ForEach-Object { $_.Extent.Text }) -join "`n"
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-contract-' + [guid]::NewGuid())
$null = New-Item -ItemType Directory $temp
$original = Get-Location
try {
    Import-Module powershell-yaml
    . ([scriptblock]::Create((Read-FunctionSource (Join-Path $root 'automation/Yuruna.Workload.psm1') @('Invoke-WorkloadChartDeployment','Invoke-WorkloadToolDeployment'))))
    function Format-YurunaOperatorMessage { param($Key, $Arguments) $Key }
    function New-YurunaResultManifest { param($Success) @{ Success = $Success } }
    function helm {
        if ($args[0] -eq $script:failAt) { throw "injected $script:failAt" }
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'status') { 'STATUS: pending-upgrade' }
    }
    $chart = Join-Path $temp 'workloads/sample'
    $null = New-Item -ItemType Directory $chart -Force
    Set-Content (Join-Path $chart 'Chart.yaml') "apiVersion: v2`nname: sample`nversion: 1.0.0"
    $values = @{ quoted = 'a"b'; slash = 'C:\a\b'; multiline = "a`nb"; unicode = [char]0x05e9 + ' ' + [char]0x4e2d; empty = ''; template = '${literal}%{text}'; boolean = 'true'; number = '001' }
    foreach ($failure in @('lint','status','rollback','upgrade','')) {
        $script:failAt = $failure
        try { $null = Invoke-WorkloadChartDeployment $temp 'test' 'lab' @{ chart='sample'; variables=@{installName='fixture'} } $values 'fixture.yml' ([Diagnostics.Stopwatch]::StartNew()) }
        catch { Assert-Contract ($_.Exception.Message -eq "injected $failure") 'Unexpected chart exception' }
        Assert-Contract ((Get-Location).Path -eq $original.Path) "Location leaked after $failure"
    }
    $roundTrip = Get-Content (Join-Path $temp '.yuruna/test/workloads/lab/fixture/values.yaml') -Raw | ConvertFrom-Yaml
    foreach ($key in $values.Keys) { Assert-Contract ($roundTrip[$key] -ceq $values[$key]) "YAML roundtrip: $key" }
    function Get-YurunaTransientPattern { 'network' }
    function Invoke-DynamicExpression { throw 'tool fixture' }
    function Invoke-WithYurunaRetry { throw 'retry fixture' }
    try { $null = Invoke-WorkloadToolDeployment @{Field='shell';ToolName='shell';Name='shell';CommandPrefix='';Retryable=$false} $temp 'test' 'lab' @{shell='exit 1'} @{} ([Diagnostics.Stopwatch]::StartNew()) }
    catch { Assert-Contract ($_.Exception.Message -eq 'retry fixture') 'Unexpected tool exception' }
    Assert-Contract ((Get-Location).Path -eq $original.Path) 'Tool location leaked'
    $workFolder = Join-Path $temp 'tofu'; $null = New-Item -ItemType Directory $workFolder
    Set-Content (Join-Path $workFolder 'terraform.tfvars') 'stale = true'
    $globalVariables = $values; $resource = @{variables=@{}}; $resourceName='fixture'
    $source = Get-Content (Join-Path $root 'automation/Yuruna.Resource.psm1') -Raw
    $start = $source.IndexOf('            $terraformVarsFile =')
    $end = $source.IndexOf('            Push-Location', $start)
    . ([scriptblock]::Create($source.Substring($start, $end-$start)))
    Assert-Contract (-not (Test-Path (Join-Path $workFolder 'terraform.tfvars'))) 'Legacy tfvars remains'
    $json = Get-Content (Join-Path $workFolder 'terraform.tfvars.json') -Raw | ConvertFrom-Json -AsHashtable
    foreach ($key in $values.Keys) { Assert-Contract ($json[$key] -ceq $values[$key]) "JSON roundtrip: $key" }
    $configuration = @{variable=@{};output=@{}}
    foreach ($key in $values.Keys) { $configuration.variable[$key]=@{type='string'}; $configuration.output[$key]=@{value=('${var.'+$key+'}')} }
    $configuration | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $workFolder 'main.tf.json')
    Push-Location $workFolder
    try {
        & $Tofu init -backend=false -input=false *> (Join-Path $temp 'init.log')
        Assert-Contract ($LASTEXITCODE -eq 0) 'Tofu init failed'
        & $Tofu apply -auto-approve -input=false *> (Join-Path $temp 'apply.log')
        Assert-Contract ($LASTEXITCODE -eq 0) 'Tofu apply failed'
        $outputs = (& $Tofu output -json) | ConvertFrom-Json -AsHashtable
        foreach ($key in $values.Keys) { Assert-Contract ($outputs[$key].value -ceq $values[$key]) "Tofu interpretation: $key" }
    } finally { Pop-Location }
    Write-Output "Automation contracts: $count assertions passed."
} finally {
    Set-Location $original
    Remove-Item $temp -Recurse -Force
}
