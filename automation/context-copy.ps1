<#PSScriptInfo
.VERSION 2026.07.03
.GUID 42aa1b2c-3d4e-4f56-a789-0b1c2d3e4f56
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
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

$modulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Import.Yaml.psm1"
Import-Module -Name $modulePath

$currentConfig =  Resolve-Path -Path "~/.kube/config"
if (-Not (Test-Path -Path $currentConfig)) { Write-Information "K8S configuration not found: $currentConfig"; return $false; }
if ((Get-Item $currentConfig).Length -eq 0) { Write-Information "K8S current configuration is empty: $currentConfig"; return $false; }

kubectl config unset contexts.$destinationContext *>&1 | Write-Verbose

# Capture originalContext now; use-context confirms sourceContext exists before we mutate the config.
# Capture KUBECONFIG before any mutation so the finally below can restore it
# even on an early-return path that aborts before it is overwritten.
$originalContext = kubectl config current-context
$originalKubeConfig = (Test-Path Env:KUBECONFIG) ? $env:KUBECONFIG : $null
kubectl config use-context $sourceContext *>&1 | Write-Verbose

# Restore both the kube context and the KUBECONFIG env var in a finally so
# every early-return failure path leaves the operator's shell on the context
# and KUBECONFIG it started with. Bare try/finally with NO catch so message-
# prefix control-flow markers still propagate to any caller.
try {
    if ($LASTEXITCODE -ne 0) { Write-Information "kubectl config use-context failed (exit $LASTEXITCODE) for: $sourceContext"; return $false; }
    $currentContext = kubectl config current-context
    if ($currentContext -ne $sourceContext) { Write-Information "K8S source context not found: $sourceContext`n"; return $false; }

    # --minify narrows the kubectl view to a single user/cluster/context,
    # so index 0 is always the source entry being renamed below.
    Write-Debug "`n==== ********* Copying context '$sourceContext' to '$destinationContext' ************** =======";
    $yamlContent = $(kubectl config view --minify --raw=true -o yaml)
    if ($LASTEXITCODE -ne 0) { Write-Information "kubectl config view failed (exit $LASTEXITCODE) for: $sourceContext"; return $false; }
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
    Set-Item -Path Env:KUBECONFIG -Value $kubeConfig
    $combinedConfig = "${HOME}/.kube/config.yuruna"
    Remove-Item -Path $combinedConfig -Force -ErrorAction SilentlyContinue
    kubectl config view --flatten >> $combinedConfig
    # Partial output before a kubectl failure would still pass the
    # downstream file-exists/non-empty checks and clobber ~/.kube/config
    # on Move-Item, so a non-zero exit here MUST short-circuit.
    if ($LASTEXITCODE -ne 0) { Write-Information "kubectl config view --flatten failed (exit $LASTEXITCODE)"; return $false; }

    Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
    if (-Not (Test-Path -Path $combinedConfig)) { Write-Information "K8S configuration problems. Try deleting invalid contexts: $currentConfig"; return $false; }
    if ((Get-Item $combinedConfig).Length -eq 0) { Write-Information "K8S configuration problems. Try deleting invalid contexts: $currentConfig"; return $false; }

    Move-Item -Path $combinedConfig -Destination $currentConfig -Force
}
finally {
    if ($null -ne $originalKubeConfig) {
        Set-Item -Path Env:KUBECONFIG -Value $originalKubeConfig
    } else {
        Remove-Item -Path Env:KUBECONFIG -ErrorAction SilentlyContinue
    }
    kubectl config use-context $originalContext *>&1 | Write-Verbose
}