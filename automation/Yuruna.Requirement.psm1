<#PSScriptInfo
.VERSION 2026.08.21
.GUID 425681a0-b84a-453d-9df2-fb0f85f547f8
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
    param (
        # Restrict the report to these tools (by their `tool:` name). An
        # installer passes the set it actually manages: reporting on a cloud CLI
        # the bootstrapper never installs would bury the one real problem in a
        # dozen expected absences.
        [Parameter()][string[]]$Tool
    )

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
        # $requirement, not $tool: PowerShell variable names are case-INSENSITIVE,
        # so a loop variable named $tool IS the -Tool parameter, and the first
        # iteration would overwrite the filter with a row -- silently skipping
        # every tool rather than filtering to the named ones.
        foreach ($requirement in $requirementsYaml.requirements) {
            $toolName = $requirement['tool']
            if ($Tool -and ($Tool -notcontains $toolName)) { continue }
            $toolCommand = $requirement['command']
            $toolVersion = $requirement['version']
            # An absent tool raises a terminating CommandNotFoundException that
            # *>&1 (error-stream only) does not capture; catch it so the missing
            # tool becomes a MISSING row below instead of aborting the report.
            try { $toolFound = Invoke-DynamicExpression -Command $toolCommand *>&1 }
            catch { $toolFound = $_.Exception.Message }
            $toolReleases = $requirement['releases']
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

    # --- REGION: Runtime capabilities
    # A tool version says what is installed; this says what the runtime can DO.
    # The two are not the same question, and the gap between them is where the
    # expensive failures live: a host can satisfy every version floor above and
    # still lack an algorithm the framework needs, and it then fails at the
    # moment of use with an error that describes the symptom rather than the
    # cause. Checking here costs nothing and turns that into one line, before
    # an operator is holding a rotating code.
    $output = "{0,20}" -f "Capability" + "{0,16}" -f "Required" + "  {0}" -f "Found"
    Write-Information $output
    foreach ($capability in (Get-RuntimeCapabilityList)) {
        $found = if ($capability.Available) { "yes" } else { "NO" }
        Write-Information ("{0,20}" -f $capability.Name + "{0,16}" -f "yes" + "  {0}" -f $found)
        if (-not $capability.Available) {
            Write-Information ("{0,36}  MISSING: {1}" -f "", $capability.Reason)
            $failureReasons.Add("$($capability.Name) MISSING: $($capability.Reason)")
            $anyFailure = $true
        }
    }

    return (New-YurunaValidationResult (-not $anyFailure) ($failureReasons -join "`n"))
}

<#
.SYNOPSIS
    Classifies observed runtime capabilities into requirement rows. Pure (no
    I/O); Get-RuntimeCapabilityList feeds it what the runtime reported.
.DESCRIPTION
    Split from the probe so the decision is testable on a host where the
    algorithm IS present -- which is every host that would run the suite. A
    $null probe means the runtime does not expose the question; that is treated
    as available, because absence of the property is not evidence of absence of
    the algorithm and failing a working host on it would be worse than missing
    a broken one.
.OUTPUTS
    [object[]] Name, Available [bool], Reason [string].
#>
function Get-RuntimeCapability {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter()][AllowNull()]$AesGcmSupported)

    # AES-GCM backs every credential envelope the lab exchanges: the Lab token
    # an enrolling host redeems, and the config-sync credentials the status
    # service seals for its peers. A runtime without it can neither join a lab
    # nor serve one, and both failures surface far from the cause -- as a
    # rejected code, and as a peer that cannot read what this host sent.
    $available = ($null -eq $AesGcmSupported) -or [bool]$AesGcmSupported
    $reason = ''
    if (-not $available) {
        $reason = ("this runtime has no AES-GCM, so Lab token enrollment and config-sync credential " +
                   "exchange both fail on this host until PowerShell is upgraded (found " +
                   "$($PSVersionTable.PSVersion) on " +
                   "$([System.Runtime.InteropServices.RuntimeInformation]::OSDescription.Trim()))")
    }
    return @(
        [pscustomobject]@{ Name = 'AES-GCM'; Available = $available; Reason = $reason }
    )
}

<#
.SYNOPSIS
    The runtime capabilities the framework depends on, each with a verdict.
.DESCRIPTION
    Capabilities, not tools: nothing here is installed or upgraded on its own,
    and each is a property of the PowerShell runtime itself. A missing one is
    fixed by changing the runtime, which is why the reason says so rather than
    naming a package to install.
.OUTPUTS
    [object[]] Name, Available [bool], Reason [string].
#>
function Get-RuntimeCapabilityList {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    $probe = $null
    try { $probe = [System.Security.Cryptography.AesGcm]::IsSupported }
    catch { Write-Debug "AesGcm.IsSupported is not exposed here ($($_.Exception.Message)); assuming present." }
    return Get-RuntimeCapability -AesGcmSupported $probe
}
