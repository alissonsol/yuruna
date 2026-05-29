<#PSScriptInfo
.VERSION 2026.05.29
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456728
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

# Validation primitives lifted out of Test-Config.ps1. These are the
# reusable pieces — schema validation, emptiness check, git-tree
# freshness — that any future check script can call without
# re-implementing.
#
# All callers reach Write-Pass / Write-Fail / Write-Warn / Write-Info
# from Test.Output.psm1, which this module imports at load time. The
# PASS/FAIL counters survive across Test.Output's $global: anchor so
# Test-Config's summary at end-of-run reflects every Test-AgainstSchema
# and Test-RepoFreshness call regardless of import order.

Import-Module (Join-Path $PSScriptRoot 'Test.Output.psm1') -Global -Force

function Test-IsSet {
    <#
    .SYNOPSIS
        $true when $Value is a non-empty string (after trim). Used as a
        guard before -match / Test-Path calls so a $null or '' field does
        not silently pass the check.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][Parameter(Position=0)]$Value)
    return ($null -ne $Value -and "$Value".Trim() -ne '')
}

function Test-AgainstSchema {
    <#
    .SYNOPSIS
        Best-effort JSON-Schema validation of a YAML config. When
        Test-Json (PS 7.4+) is unavailable, falls back to a parse-only
        check so the validator still surfaces malformed YAML. Never
        blocks the cycle on missing schema tooling — only on actual
        content errors.
    .DESCRIPTION
        Resolves YamlPath to an absolute path so every FAIL row carries
        an operator-actionable location. The original message used to
        say just "vault.yml" — forcing the operator to guess which of
        the several vault.yml locations was meant.
    .PARAMETER Label
        Display label for the section (e.g. 'vault.yml', 'users.yml').
    .PARAMETER YamlPath
        Path to the YAML document under test.
    .PARAMETER SchemaPath
        Path to the JSON-Schema-compatible YAML schema.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Writes PASS/FAIL via Test.Output; no externally observable state change.')]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$YamlPath,
        [Parameter(Mandatory)][string]$SchemaPath
    )
    $YamlFull = try { [System.IO.Path]::GetFullPath($YamlPath) } catch { $YamlPath }
    if (-not (Test-Path $YamlPath))   { Write-Fail "${Label}: file not found ($YamlFull)" -FullPath $YamlFull; return }
    if (-not (Test-Path $SchemaPath)) { Write-Warn "${Label}: schema not found ($SchemaPath)"; return }
    try {
        $doc = Get-Content -Raw $YamlPath | ConvertFrom-Yaml -Ordered
    } catch {
        Write-Fail "${Label}: YAML parse error in ${YamlFull} -- $($_.Exception.Message)" -FullPath $YamlFull
        return
    }
    $hasTestJson = Get-Command Test-Json -ErrorAction SilentlyContinue
    if ($hasTestJson) {
        try {
            $schemaJson = Get-Content -Raw $SchemaPath | ConvertFrom-Yaml -Ordered | ConvertTo-Json -Depth 20
            $docJson    = $doc | ConvertTo-Json -Depth 20
            if (Test-Json -Json $docJson -Schema $schemaJson -ErrorAction Stop) {
                Write-Pass "${Label}: schema-valid ($YamlFull)"
            } else {
                Write-Fail "${Label}: schema-invalid -- ${YamlFull}" -FullPath $YamlFull
            }
        } catch {
            Write-Fail "${Label}: schema validation failed in ${YamlFull} -- $($_.Exception.Message)" -FullPath $YamlFull
        }
    } else {
        Write-Pass "${Label}: parse-only check passed (Test-Json unavailable; schema not enforced)"
    }
}

function Test-RepoFreshness {
    <#
    .SYNOPSIS
        Report a git working tree's relation to its upstream: up-to-date,
        ahead, behind, diverged, or no-upstream. Fetches first so the
        comparison is meaningful; tolerates offline (`git fetch` failure
        becomes a WARN, not a FAIL).
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions',
        '', Justification = 'Writes PASS/WARN via Test.Output; no externally observable state change beyond a git fetch (read-only).')]
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Path
    )
    if (-not (Test-Path (Join-Path $Path '.git'))) {
        Write-Warn "${Label}: not a git working tree ($Path) -- skipping freshness check."
        return
    }
    try {
        $null = & git -C $Path fetch --quiet 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "${Label}: git fetch failed (offline?); cannot determine staleness."
            return
        }
        $local  = (& git -C $Path rev-parse HEAD 2>$null).Trim()
        $remote = (& git -C $Path rev-parse '@{u}' 2>$null).Trim()
        if (-not $remote) {
            Write-Info "${Label}: no upstream tracking branch -- skipping ahead/behind."
            return
        }
        if ($local -eq $remote) {
            Write-Pass "${Label}: up to date with $remote."
            return
        }
        $behind = (& git -C $Path rev-list --count "$local..$remote" 2>$null).Trim()
        $ahead  = (& git -C $Path rev-list --count "$remote..$local" 2>$null).Trim()
        if ([int]$behind -gt 0 -and [int]$ahead -eq 0) {
            Write-Warn "${Label}: $behind commit(s) behind upstream -- 'git pull --ff-only' before next cycle."
        } elseif ([int]$ahead -gt 0 -and [int]$behind -eq 0) {
            Write-Pass "${Label}: $ahead commit(s) ahead of upstream (unpushed local work)."
        } else {
            Write-Warn "${Label}: diverged ($ahead ahead, $behind behind). Rebase or merge manually."
        }
    } catch {
        Write-Warn "${Label}: freshness check threw -- $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function Test-IsSet, Test-AgainstSchema, Test-RepoFreshness
