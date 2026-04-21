<#PSScriptInfo
.VERSION 0.1
.GUID 42aa1b2c-3d4e-4f56-a789-0b1c2d3e4f56
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2019-2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# yuruna helper: copy context
# As a result, this code creates copies of those entries with the same name of the destinationContext

param (
    [string]$sourceContext=$null,
    [string]$destinationContext=$null
)

$global:DebugPreference = "Continue"
$global:VerbosePreference = "Continue"

if ([string]::IsNullOrEmpty($sourceContext)) { Write-Information "Source context cannot be empty"; return $false; }
if ([string]::IsNullOrEmpty($destinationContext)) { Write-Information "Destination context cannot be empty"; return $false; }

$yuruna_root = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")
Write-Information "yuruna_root: $yuruna_root"
Write-Information "sourceContext: $sourceContext"
Write-Information "destinationContext: $destinationContext"

$modulePath = Join-Path -Path $yuruna_root -ChildPath "automation/import-yaml"
Import-Module -Name $modulePath

$currentConfig =  Resolve-Path -Path "~/.kube/config"
if (-Not (Test-Path -Path $currentConfig)) { Write-Information "K8S configuration not found: $currentConfig"; return $false; }
if ((Get-Item $currentConfig).Length -eq 0) { Write-Information "K8S current configuration is empty: $currentConfig"; return $false; }

# Remove destination context if already exists
kubectl config unset contexts.$destinationContext *>&1 | Write-Verbose

# Save originalContext and confirm sourceContext exists
$originalContext = kubectl config current-context
kubectl config use-context $sourceContext *>&1 | Write-Verbose
$currentContext = kubectl config current-context
if ($currentContext -ne $sourceContext) { Write-Information "K8S source context not found: $sourceContext`n"; return $false; }

# --minify narrows the kubectl view to a single user/cluster/context,
# so index 0 is always the source entry being renamed below.
Write-Debug "`n==== ********* Copying context '$sourceContext' to '$destinationContext' ************** =======";
$yamlContent = $(kubectl config view --minify --raw=true -o yaml)
# Write-Verbose $(ConvertTo-Yaml $yamlContent)
$yaml = ConvertFrom-Content $yamlContent
$yaml.users[0].name = $destinationContext
$yaml.clusters[0].name = $destinationContext
$yaml.contexts[0].name = $destinationContext
$yaml.contexts[0].context.cluster = $destinationContext
$yaml.contexts[0].context.user = $destinationContext

$tempFile = New-TemporaryFile
Add-Content -Path $tempFile.FullName -Value $(ConvertTo-Yaml $yaml)

$kubeConfig = "${currentConfig}:${tempFile}"
if ($IsWindows) { $kubeConfig = "${currentConfig};${tempFile}"; }
Write-Verbose "KUBECONFIG: $kubeConfig"
$originalKubeConfig = (Test-Path Env:KUBECONFIG) ? $env:KUBECONFIG : $null
Set-Item -Path Env:KUBECONFIG -Value $kubeConfig
$combinedConfig = "${HOME}/.kube/config.yuruna"
Remove-Item -Path $combinedConfig -Force -ErrorAction SilentlyContinue
$result = $(kubectl config view --flatten >> $combinedConfig)
if (![string]::IsNullOrEmpty($result)) { Write-Debug "$result"; }

Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
if (-Not (Test-Path -Path $combinedConfig)) { Write-Information "K8S configuration problems. Try deleting invalid contexts: $currentConfig"; return $false; }
if ((Get-Item $combinedConfig).Length -eq 0) { Write-Information "K8S configuration problems. Try deleting invalid contexts: $currentConfig"; return $false; }

Move-Item -Path $combinedConfig -Destination $currentConfig -Force

# Back to original values
if ($null -ne $originalKubeConfig) {
    Set-Item -Path Env:KUBECONFIG -Value $originalKubeConfig
} else {
    Remove-Item -Path Env:KUBECONFIG -ErrorAction SilentlyContinue
}
kubectl config use-context $originalContext *>&1 | Write-Verbose