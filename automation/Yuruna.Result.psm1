<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42f6c5d4-e3b2-4a0b-7890-1c2d3e4f5a62
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Yuruna.Result
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# --- REGION: https://yuruna.link/memory#why-the-yuruna-result-manifest-is-shaped-this-way

function New-YurunaResultManifest {
    <#
    .SYNOPSIS
        Build a Yuruna result manifest hashtable.
    .DESCRIPTION
        Pure builder for the canonical result manifest shape (success,
        skipped, errorMessage, failureClass, exitCode, durationMs,
        artifacts). All keys default so callers may set only what they
        know; the rest carry the documented neutral values.
    .OUTPUTS
        [hashtable] with the canonical result-manifest keys populated.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure builder: returns a hashtable. Does not touch disk, processes, or any external state.')]
    param(
        [Parameter()][bool]$Success = $true,
        [Parameter()][bool]$Skipped = $false,
        [Parameter()][string]$ErrorMessage = '',
        [Parameter()][ValidateSet('ok','config_error','cluster_unreachable','chart_invalid','tool_failed','unknown')]
        [string]$FailureClass = 'ok',
        [Parameter()][int]$ExitCode = 0,
        [Parameter()][long]$DurationMs = 0,
        [Parameter()][hashtable[]]$Artifacts = @()
    )
    return @{
        success      = $Success
        skipped      = $Skipped
        errorMessage = $ErrorMessage
        failureClass = $FailureClass
        exitCode     = $ExitCode
        durationMs   = $DurationMs
        artifacts    = $Artifacts
    }
}

function ConvertTo-CanonicalFailureClass {
    <#
    .SYNOPSIS
        Translate an automation-domain failureClass into the canonical
        machine-routable failure class the remediation dispatcher understands.
    .DESCRIPTION
        The automation result manifest emits a small deploy-side vocabulary
        (ok, config_error, cluster_unreachable, chart_invalid, tool_failed,
        unknown). The remediation dispatcher routes on a larger canonical
        taxonomy whose values name recovery-shaped categories. Without a
        translation a deploy-phase failure carries a class the dispatcher has no
        handler for, so it either drops to the generic 'unknown' fallback or, if
        forwarded to the schema validator, reads as an out-of-enum value.

        This is a pure lookup: it does not change what the manifest emits. A
        caller that bridges an automation result into the dispatcher / event
        stream runs the manifest's failureClass through here first.

        Mapping rationale (each lands on the canonical class whose remediation
        recommendation matches the automation failure's real recovery shape):
          config_error        -> plan_invalid          (unsatisfiable config; operator fixes it)
          chart_invalid       -> plan_invalid          (helm lint rejected the chart; a config error)
          cluster_unreachable -> network_timeout       (target cluster not reachable; often transient)
          tool_failed         -> provisioning_failure  (a deploy tool -- helm/docker/tofu -- exited non-zero)
          unknown             -> unknown               (catch-all preserved)
          ok                  -> ok                    (not a failure; passed through so a caller can gate on it)

        An input outside the automation vocabulary (already a canonical value, a
        typo, empty, $null) returns 'unknown' -- the dispatcher's catch-all --
        so an unrecognized class is never silently dropped.
    .PARAMETER FailureClass
        The automation-domain failureClass string (from a result manifest's
        `failureClass` key).
    .OUTPUTS
        [string] a canonical FailureClass value (or 'ok' for the non-failure input).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)]
        [string]$FailureClass
    )
    # Ordinal-comparer map: '@{}' literals are case-insensitive, which would
    # collide distinct spellings; the automation enum is all-lowercase and the
    # match must be exact.
    $map = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $map['ok']                  = 'ok'
    $map['config_error']        = 'plan_invalid'
    $map['cluster_unreachable'] = 'network_timeout'
    $map['chart_invalid']       = 'plan_invalid'
    $map['tool_failed']         = 'provisioning_failure'
    $map['unknown']             = 'unknown'
    if ($null -ne $FailureClass -and $map.ContainsKey($FailureClass)) {
        return $map[$FailureClass]
    }
    return 'unknown'
}

function New-YurunaValidationResult {
    <#
    .SYNOPSIS
        Build a validator result that behaves like a [bool] but carries a reason.
    .DESCRIPTION
        A bare [bool] from the Confirm-* validators cannot carry the actionable
        reason (which file / key / duplicate name failed): that reaches only
        Write-Information, which is silenced at Error/Warning log levels, so a
        machine consuming a validation failure gets a pass/fail with no pointer
        to the offending element.

        This returns a real boxed [bool] (the base object IS $Success) decorated
        with Success, OK, and Reason note-properties. Every boolean context a
        caller already uses -- `if (Confirm-X ...)`, `if (!(Confirm-X ...))`,
        `-Not $result`, `[bool]$result` -- reads the underlying [bool] value
        unchanged, so no call site changes its pass/fail decision. A caller that
        wants the diagnostic reads $result.Reason (or .Success / .OK). Attaching
        the members to a [pscustomobject]/[hashtable] instead would break every
        boolean caller, because a non-empty object coerces to $true regardless of
        its contents.
    .OUTPUTS
        [bool] (a boxed System.Boolean) carrying Success, OK, and Reason members.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure builder: decorates a boxed [bool]. Does not touch disk, processes, or any external state.')]
    param(
        [Parameter(Position = 0)][bool]$Success,
        [Parameter(Position = 1)][string]$Reason = ''
    )
    return ([bool]$Success |
        Add-Member -NotePropertyName Success -NotePropertyValue $Success -PassThru |
        Add-Member -NotePropertyName OK      -NotePropertyValue $Success -PassThru |
        Add-Member -NotePropertyName Reason  -NotePropertyValue $Reason  -PassThru)
}

function Test-YurunaResultManifestOk {
    <#
    .SYNOPSIS
        Convenience boolean test on a manifest's `success` key.
    .DESCRIPTION
        Callers that just want pass/fail can write
            if (Test-YurunaResultManifestOk $result) { ... }
        instead of
            if ($result.success) { ... }
        A $null manifest, a manifest missing the `success` key, or a
        manifest whose `success` is not $true returns $false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)]
        $Manifest
    )
    if ($null -eq $Manifest) { return $false }
    if ($Manifest -isnot [hashtable] -and $Manifest -isnot [System.Collections.IDictionary]) { return $false }
    if (-not $Manifest.Contains('success')) { return $false }
    return [bool]$Manifest['success']
}

function Complete-YurunaRun {
    <#
    .SYNOPSIS
        Shared failure-reporting tail for the Set-Resource / Set-Component /
        Set-Workload entrypoints: report the result manifest and exit non-zero on
        failure.
    .DESCRIPTION
        A non-empty result-manifest hashtable coerces to $true, so a bare
        `if (-Not $result)` would silently take the success branch on a failure
        manifest; this tests the `.success` key via Test-YurunaResultManifestOk. On
        failure it writes the compact result JSON and the transcript to the success
        stream (stdout) and exits 1, so bash wrappers using `set -e` observe the
        non-zero process exit instead of marching on with a missing image / failed
        deploy (a failed Publish-*List that printed the transcript but exited 0 would
        surface only later as a `kubectl wait` timeout). On success it writes only a
        Write-Debug pointer to the transcript.

        CALL AS A STATEMENT (not `$x = Complete-YurunaRun`): it streams the report to
        stdout and may terminate the process. $Result is intentionally not
        [Mandatory] so a $null / $false / non-hashtable result still routes through
        Test-YurunaResultManifestOk (which treats all of those as a failure).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Reporting tail: emits the manifest/transcript and exits the process. Not a resource mutation; ShouldProcess would not fit an exit-on-failure contract.')]
    param(
        [Parameter(Position = 0)]$Result,
        [Parameter(Position = 1)][string]$TranscriptFile
    )
    if (-Not (Test-YurunaResultManifestOk $Result)) {
        Write-Output ($Result | ConvertTo-Json -Depth 4 -Compress)
        Write-Output $(Get-Content -Path $TranscriptFile)
        exit 1
    }
    Write-Debug "`n-- See transcript with command: Write-Output `$(Get-Content -Path $TranscriptFile)"
}

Export-ModuleMember -Function New-YurunaResultManifest, New-YurunaValidationResult, Test-YurunaResultManifestOk, Complete-YurunaRun, ConvertTo-CanonicalFailureClass