# yuruna helper: copy context
# As a result, this code creates copies of those entries with the same name of the destinationContext
#
# Debug
# Set-Item -Path Env:yuruna_root -Value ../../../.. (Just above automation)
# Set-Item -Path Env:sourceContext -Value docker-desktop
# Set-Item -Path Env:destinationContext -Value value

$yuruna_root = ${env:yuruna_root}
Write-Information "yuruna_root: $yuruna_root"
$sourceContext = ${env:SOURCE_CONTEXT}
Write-Information "sourceContext: $sourceContext"
$destinationContext = ${env:DESTINATION_CONTEXT}
Write-Information "destinationContext: $destinationContext"

$modulePath = Join-Path -Path $yuruna_root -ChildPath "automation/import-yaml"
Import-Module -Name $modulePath

# Basic checks for initial configuration
$currentConfig =  Resolve-Path -Path "~/.kube/config"
if (-Not (Test-Path -Path $currentConfig)) { Write-Information "K8S configuration not found: $currentConfig"; return $false; }
if ((Get-Item $currentConfig).Length -eq 0) { Write-Information "K8S current configuration is empty: $currentConfig"; return $false; }

# Save originalContext and confirm sourceContext exists
$originalContext = kubectl config current-context
kubectl config use-context $sourceContext *>&1 | Write-Verbose
$currentContext = kubectl config current-context
if ($currentContext -ne $sourceContext) { Write-Information "K8S source context not found: $sourceContext`n"; return $false; }

# Remove destination context if already exists
kubectl config unset contexts.$destinationContext *>&1 | Write-Verbose

# Copy sourceContext to destinationContext
Write-Debug "`n==== ********* Copying context '$sourceContext' to '$destinationContext' ************** =======";
$yamlContent = $(kubectl config view --minify --raw=true -o yaml)
$yaml = ConvertFrom-Content $yamlContent
$yaml.users[0].name = $destinationContext
$yaml.clusters[0].name = $destinationContext
$yaml.contexts[0].name = $destinationContext
$yaml.contexts[0].context.cluster = $destinationContext
$yaml.contexts[0].context.user = $destinationContext

# Create temporary file with information
$tempFile = New-TemporaryFile
Add-Content -Path $tempFile.FullName -Value $(ConvertTo-Yaml $yaml)

$kubeConfig = "${currentConfig}:${tempFile}"
if ($IsWindows) { $kubeConfig = "${currentConfig};${tempFile}"; }
Write-Verbose "KUBECONFIG: $kubeConfig"
$originalKubeConfig = Get-Item -Path Env:KUBECONFIG -ErrorAction SilentlyContinue
Set-Item -Path Env:KUBECONFIG -Value $kubeConfig
$combinedConfig = "${HOME}/.kube/config.yuruna"
Remove-Item -Path $combinedConfig -Force -ErrorAction SilentlyContinue
$result = $(kubectl config view --flatten >> $combinedConfig)
if (![string]::IsNullOrEmpty($result)) { Write-Debug "$result"; }

# Basic checks for combined configuration
Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
if (-Not (Test-Path -Path $combinedConfig)) { Write-Information "K8S configuration problems. Try deleting invalid contexts: $currentConfig"; return $false; }
if ((Get-Item $combinedConfig).Length -eq 0) { Write-Information "K8S configuration problems. Try deleting invalid contexts: $currentConfig"; return $false; }

# Replace current configuration
Move-Item -Path $combinedConfig -Destination $currentConfig -Force

# Back to original values
Set-Item -Path Env:KUBECONFIG -Value $originalKubeConfig
kubectl config use-context $originalContext *>&1 | Write-Verbose