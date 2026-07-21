<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42f4b6c7-d8e9-4012-3456-7f8091021324
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Yuruna.Requirement
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

$yuruna_root = Resolve-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath "..")
$modulePath = Join-Path -Path $yuruna_root -ChildPath "automation/Import.Yaml.psm1"
Import-Module -Name $modulePath
Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath "Invoke-DynamicExpression")
# New-YurunaValidationResult decorates a boxed [bool] with a Reason so the
# missing/below-version tool list travels with the pass/fail decision instead
# of reaching only Write-Information (silenced at Error/Warning). -Global -Force
# per feedback_module_force_import_evicts_global.md.
Import-Module (Join-Path $PSScriptRoot 'Yuruna.Result.psm1') -Global -Force

function Confirm-RequirementList {
    [CmdletBinding()]
    [OutputType([bool])]
    param ()

    $requirementsFile = Join-Path -Path $PSScriptRoot -ChildPath "Yuruna.Requirement.yml"
    if (-Not (Test-Path -Path $requirementsFile)) { $r = "File not found: $requirementsFile"; Write-Information $r; return (New-YurunaValidationResult $false $r); }
    $requirementsYaml = ConvertFrom-File $requirementsFile
    if ($null -eq $requirementsYaml) { Write-Information "Requirements null or empty in file: $requirementsFile"; return (New-YurunaValidationResult $true); }
    if ($null -eq $requirementsYaml.requirements) { Write-Information "Requirements null or empty in file: $requirementsFile"; return (New-YurunaValidationResult $true); }

    $anyFailure = $false
    # Collect the per-tool failure lines so the aggregate reason names every
    # missing/below-version tool, not just a pass/fail; each element mirrors the
    # Write-Information line so the machine-readable reason matches the report.
    $failureReasons = [System.Collections.Generic.List[string]]::new()
    if (-Not ($null -eq $requirementsYaml.requirements)) {
        $output = "{0,20}" -f "Tool" + "{0,16}" -f "Required" + "  {0}" -f "Found"
        Write-Information $output
        foreach ($tool in $requirementsYaml.requirements) {
            $toolName = $tool['tool']
            $toolCommand = $tool['command']
            $toolVersion = $tool['version']
            # An absent tool raises a terminating CommandNotFoundException that
            # *>&1 (error-stream only) does not capture; catch it so the missing
            # tool becomes a MISSING row below instead of aborting the report.
            try { $toolFound = Invoke-DynamicExpression -Command $toolCommand *>&1 }
            catch { $toolFound = $_.Exception.Message }
            $toolReleases = $tool['releases']
            $output = "{0,20}" -f $toolName + "{0,16}" -f $toolVersion + "  {0}" -f $toolFound
            Write-Information $output
            $output = "{0,36}" -f "" + "  {0}" -f $toolReleases
            Write-Information $output

            # A required tool must be present and, when a required version is
            # given, at least meet it. The found version is the first dotted
            # number token in the command output; its absence means the tool is
            # missing or its probe errored. An unparseable-but-present output is
            # accepted (can't compare, don't spuriously fail).
            $foundText = (@($toolFound) | Out-String).Trim()
            $foundVer  = [regex]::Match($foundText, '\d+(\.\d+){1,3}').Value
            if ([string]::IsNullOrWhiteSpace($foundVer)) {
                Write-Information ("{0,36}  MISSING: no version detected (tool absent or probe failed)." -f "")
                $failureReasons.Add("$toolName MISSING: no version detected (tool absent or probe failed).")
                $anyFailure = $true
            }
            else {
                $reqVer = [regex]::Match([string]$toolVersion, '\d+(\.\d+){1,3}').Value
                if (-not [string]::IsNullOrWhiteSpace($reqVer)) {
                    try {
                        if ([version]$foundVer -lt [version]$reqVer) {
                            Write-Information ("{0,36}  BELOW: found $foundVer is older than required $reqVer." -f "")
                            $failureReasons.Add("$toolName BELOW: found $foundVer is older than required $reqVer.")
                            $anyFailure = $true
                        }
                    } catch {
                        Write-Debug "Version compare skipped for '$toolName' ($foundVer vs $reqVer): $($_.Exception.Message)"
                    }
                }
            }
        }
    }

    return (New-YurunaValidationResult (-not $anyFailure) ($failureReasons -join "`n"))
}

Export-ModuleMember -Function * -Alias *
