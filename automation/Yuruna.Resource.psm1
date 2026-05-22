<#PSScriptInfo
.VERSION 2026.05.22
.GUID 42e3a5b6-c7d8-4901-2345-6e7f80910213
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Yuruna.Resource
.LICENSEURI https://yuruna.com
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

$yuruna_root = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")
$validationModulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Yuruna.Validation.psm1"
Import-Module -Name $validationModulePath
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Invoke-DynamicExpression")

$globalVariables = [ordered]@{}

# --- See https://yuruna.link/memory#why-tofu-failure-throws-include-the-stderr-tail
$script:tofuStderrTailLines = 30

function Get-TofuStderrTail {
    [OutputType([string])]
    param([string] $tofuLogFile)
    if ([string]::IsNullOrEmpty($tofuLogFile) -or -Not (Test-Path -LiteralPath $tofuLogFile)) {
        return ""
    }
    $tail = Get-Content -LiteralPath $tofuLogFile -Tail $script:tofuStderrTailLines -ErrorAction SilentlyContinue
    if ($null -eq $tail) { return "" }
    return "`n--- tail of $tofuLogFile (last $script:tofuStderrTailLines lines) ---`n" + ($tail -join "`n")
}

function Publish-ResourceListHelper {
    [OutputType([Boolean])]
    [CmdletBinding(PositionalBinding=$false)]
    param (
        [string] $project_root,
        [string] $config_subfolder,
        [bool] $isInitialization
    )

    Write-Debug "     isInitialization: $isInitialization"
    # For each resource in resources.yml: copy template to .yuruna work folder,
    # apply variables, run tofu apply there (creates local .terraform that
    # tofu destroy will reuse).

    $resourcesFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/resources.yml"
    if (-Not (Test-Path -Path $resourcesFile)) { Write-Information "File not found: $resourcesFile"; return $false; }
    $yaml = ConvertFrom-File $resourcesFile

    if ($isInitialization) {
        # Global variables are saved expanded after first time so resources.output
        # can re-use them.
        if ((-Not ($null -eq $yaml.globalVariables)) -and (-Not ($null -eq $yaml.globalVariables.Keys))) {
            $keys = @($yaml.globalVariables.Keys)
            foreach ($key in $keys) {
                $value = $ExecutionContext.InvokeCommand.ExpandString($yaml.globalVariables[$key])
                Write-Debug "resources.globalVariables[$key] = $value"
                Set-Item -Path Env:$key -Value ${value}
                $yaml.globalVariables[$key] = $value
                $globalVariables.Add($key, $value)
            }
        }
    }
    else {
        $yamlExpanded = @{ }
        $yamlExpanded.Add("globalVariables", $globalVariables)
        $resourcesOutputFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/resources.output.yml"
        $null = New-Item -Path $resourcesOutputFile -ItemType File -Force
        Add-Content -Path $resourcesOutputFile -Value $(ConvertTo-Yaml $yamlExpanded)
    }

    if ($null -eq $yaml.resources) { Write-Information "Resources null or empty in file: $resourcesFile"; return $true; }
    foreach ($resource in $yaml.resources) {
        $resourceName = $resource['name']
        $resourceNameExpanded = $ExecutionContext.InvokeCommand.ExpandString($resourceName)
        Write-Verbose "$resourceName = $resourceNameExpanded"
        $resourceName = $resourceNameExpanded
        $resourceTemplate = $resource['template']
        if ([string]::IsNullOrEmpty($resourceName)) { Write-Information "Resource without name in file: $resourcesFile"; return $false; }
        # Empty template: just naming an already-existing resource
        if (![string]::IsNullOrEmpty($resourceTemplate)) {
            $templateFolder = Join-Path -Path $project_root -ChildPath "resources/$resourceTemplate" -ErrorAction SilentlyContinue
            if (($null -eq $templateFolder) -or (-Not (Test-Path -Path $templateFolder))) {
                $templateFolder = Join-Path -Path $yuruna_root  -ChildPath "global/resources/$resourceTemplate" -ErrorAction SilentlyContinue
                if (($null -eq $templateFolder) -or (-Not (Test-Path -Path $templateFolder))) {
                    Write-Information "Resources template not found locally or globally: $resourceTemplate`nUsed in file: $resourcesFile";
                    return $false;
                }
            }
            if ($isInitialization) {
                Write-Information "-- Initializing: $resourceName from template $templateFolder"
            }
            else {
                Write-Information "-- Creating: $resourceName from template $templateFolder"
            }
            $workFolder = Join-Path -Path $project_root -ChildPath ".yuruna/$config_subfolder/resources/$resourceName"
            $null = New-Item -ItemType Directory -Force -Path $workFolder -ErrorAction SilentlyContinue
            $workFolder = Resolve-Path -Path $workFolder
            Get-ChildItem -Path "$workFolder/*.tf" | Remove-Item -Force -ErrorAction SilentlyContinue
            Copy-Item "$templateFolder/*" -Destination $workFolder -Recurse -Container -ErrorAction SilentlyContinue

            Set-Item -Path Env:resourceName -Value ${resourceName}
            $terraformVarsFile = Join-Path -Path $workFolder -ChildPath "terraform.tfvars"
            $null = New-Item -Path $terraformVarsFile -ItemType File -Force
            $terraformVars = [ordered]@{}
            foreach ($key in $globalVariables.Keys) {
                $value = $globalVariables[$key]
                $terraformVars[$key] = $value
                Set-Item -Path Env:$key -Value ${value}
            }
            if (-Not ($null -eq $resource.variables)) {
                foreach ($key in $resource.variables.Keys) {
                    $value = $resource.variables[$key]
                    $terraformVars[$key] = $value
                    Write-Verbose "resourceVariables[$key] = $value"
                    Set-Item -Path Env:$key -Value ${value}
                }
            }
            foreach ($key in $terraformVars.Keys) {
                $value = $ExecutionContext.InvokeCommand.ExpandString($terraformVars[$key])
                if ([string]::IsNullOrEmpty($value)) { Write-Debug "WARNING: empty value for $key" }
                $line = "$key = `"$value`""
                Add-Content -Path $terraformVarsFile -Value $line
                Set-Item -Path Env:$key -Value ${value}
                Write-Debug "$line"
            }
            Push-Location $workFolder

            $terraformPath = Join-Path -Path $workFolder -ChildPath ".terraform"
            if ($isInitialization -and (Test-Path -Path $terraformPath)) {
                Write-Information "-- WARNING: tofu already initialized: $terraformPath `n   Resource may not be created. Use 'yuruna clear' to clear tofu state.";
                Pop-Location;
                return $false;
            }
            # Per-resource tofu stderr/stdout log. Stable path so re-runs
            # overwrite -- the latest attempt is what matters.
            $tofuLogFile = Join-Path -Path $workFolder -ChildPath "tofu.stderr.log"
            Remove-Item -LiteralPath $tofuLogFile -Force -ErrorAction SilentlyContinue

            Write-Debug "OpenTofu init"
            # --- See https://yuruna.link/memory#why-tofu-init-retries-before-failing
            $initMaxAttempts = 3
            $initBackoffSeconds = @(5, 10)
            for ($initAttempt = 1; $initAttempt -le $initMaxAttempts; $initAttempt++) {
                $initLog = & tofu init -input=false 2>&1
                $initExit = $LASTEXITCODE
                Add-Content -LiteralPath $tofuLogFile -Value "=== tofu init -input=false (attempt $initAttempt/$initMaxAttempts, exit=$initExit) ==="
                $initLog | ForEach-Object { Add-Content -LiteralPath $tofuLogFile -Value ([string]$_); Write-Verbose ([string]$_) }
                if ($initExit -eq 0) { break }
                if ($initAttempt -lt $initMaxAttempts) {
                    $sleep = $initBackoffSeconds[$initAttempt - 1]
                    Write-Information "-- tofu init failed (exit $initExit) for resource '$resourceName', retrying in ${sleep}s..."
                    Start-Sleep -Seconds $sleep
                }
            }
            if ($initExit -ne 0) {
                Pop-Location
                throw ("tofu init failed for resource '$resourceName' after $initMaxAttempts attempts (final exit $initExit). Inspect $tofuLogFile for the underlying error (often a 5xx from registry.opentofu.org or a provider checksum mismatch)." + (Get-TofuStderrTail $tofuLogFile))
            }

            Write-Debug "Executing tofu command from $workFolder"
            # --- See https://yuruna.link/memory#why-set-resource-uses-a-saved-planfile-for-apply
            $planFile = Join-Path -Path $workFolder -ChildPath "tofu.planfile"
            if ($isInitialization) {
                $resolvedCommand = "tofu plan -input=false -compact-warnings -out=`"$planFile`""
            }
            else {
                if (Test-Path -LiteralPath $planFile) {
                    $resolvedCommand = "tofu apply -input=false -auto-approve `"$planFile`""
                }
                else {
                    # Missing planfile: fall back to a refreshing apply.
                    Write-Verbose "Planfile not found at $planFile; falling back to refreshing apply."
                    $resolvedCommand = "tofu apply -input=false -auto-approve"
                }
            }
            $applyLog = Invoke-DynamicExpression -Command $resolvedCommand 2>&1
            $applyExit = $LASTEXITCODE
            Add-Content -LiteralPath $tofuLogFile -Value "=== $resolvedCommand (exit=$applyExit) ==="
            $applyLog | ForEach-Object { Add-Content -LiteralPath $tofuLogFile -Value ([string]$_); Write-Verbose ([string]$_) }
            if ($applyExit -ne 0) {
                Pop-Location
                throw ("tofu command '$resolvedCommand' failed for resource '$resourceName' (exit $applyExit). Inspect $tofuLogFile for the underlying error (often a null_resource provisioner returning non-zero, or a data-source program failing)." + (Get-TofuStderrTail $tofuLogFile))
            }

            if (-Not $isInitialization) {
                $jsonOutput = "$(tofu output -json)"
                $outputExit = $LASTEXITCODE
                Add-Content -LiteralPath $tofuLogFile -Value "=== tofu output -json (exit=$outputExit) ==="
                Add-Content -LiteralPath $tofuLogFile -Value $jsonOutput
                if ($outputExit -ne 0) {
                    Pop-Location
                    throw ("tofu output -json failed for resource '$resourceName' (exit $outputExit). Inspect $tofuLogFile." + (Get-TofuStderrTail $tofuLogFile))
                }
                if ([string]::IsNullOrWhiteSpace($jsonOutput)) {
                    Pop-Location
                    throw "tofu output -json returned empty for resource '$resourceName' -- this codebase requires every resource to define at least one `output` block. Add one in $templateFolder/*.tf, or remove the resource from resources.yml if it is no longer needed."
                }
                $terraformYaml = $jsonOutput | ConvertFrom-Json
                # --- See https://yuruna.link/memory#why-set-resource-fails-fast-on-empty-tofu-outputs
                $propsList = @($terraformYaml.PSObject.Properties)
                if ($propsList.Count -eq 0) {
                    Pop-Location
                    throw ("tofu output -json returned {} for resource '$resourceName' -- apply succeeded but every `output` block evaluated to empty. The null_resource provisioner under $templateFolder almost certainly failed silently (no exit code, no stdout). Check $tofuLogFile and the provisioner scripts in $templateFolder." + (Get-TofuStderrTail $tofuLogFile))
                }
                $tuple = @{ }
                $tuple."$resourceName" = $terraformYaml
                Add-Content -Path $resourcesOutputFile -Value $(ConvertTo-Yaml $tuple)
            }
            Pop-Location
        }
    }

    if (-Not $isInitialization) {
        if ((Get-Item $resourcesOutputFile).Length -gt 0) { Write-Information "Resources output file: $resourcesOutputFile"; }
    }

    return $true;
}

function Publish-ResourceList {
    param (
        $project_root,
        $config_subfolder
    )

    Write-Debug "---- Publishing Resources"
    # Two-pass tofu run; see
    # https://yuruna.link/memory#why-set-resource-uses-a-saved-planfile-for-apply
    if (!(Confirm-ResourceList $project_root $config_subfolder)) { return $false; }

    # Unattended-mode signal: silences tofu's interactive hints and the
    # curses progress UI (the latter trips pwsh-on-Linux Write-Progress).
    Set-Item -Path Env:TF_IN_AUTOMATION -Value "1"

    $resourcesFile = Join-Path -Path $project_root -ChildPath "config/$config_subfolder/resources.yml"
    if (-Not (Test-Path -Path $resourcesFile)) { Write-Information "File not found: $resourcesFile"; return $false; }
    $workFolder = Join-Path -Path $project_root -ChildPath ".yuruna/$config_subfolder/resources"
    $null = New-Item -ItemType Directory -Force -Path $workFolder -ErrorAction SilentlyContinue
    $workFolder = Resolve-Path -Path $workFolder
    $dtTime = '{0}' -f ([system.string]::format('{0:yyyy-MM-dd-HH-mm-ss}',(Get-Date)))
    $backupFile = Join-Path -Path $workFolder -ChildPath "resources.$dtTime.yml"
    Copy-Item "$resourcesFile" -Destination $backupFile -Recurse -Container -ErrorAction SilentlyContinue
    Write-Verbose "Backup of: $resourcesFile copied to: $backupFile"

    $result = Publish-ResourceListHelper -project_root $project_root -config_subfolder $config_subfolder -isInitialization $true
    if ($result) {
        return Publish-ResourceListHelper -project_root $project_root -config_subfolder $config_subfolder -isInitialization $false
    }

    return $false;
}

Export-ModuleMember -Function * -Alias *
