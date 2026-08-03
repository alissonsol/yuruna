<#PSScriptInfo
.VERSION 2026.08.03
.GUID 42b5c7d9-1e08-4a3f-9b26-5c8d0e1f2a37
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna config migration naming
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

<#
.SYNOPSIS
    Convert a test.config.yml from the retired key names to the current ones.
.DESCRIPTION
    Renames every key in the retired-key table (test/modules/Test.ConfigNaming.psm1),
    converts the values whose UNIT changed (minutes and hours both become seconds),
    and moves the two flat auto-remediation keys under the nested
    `autoRemediation` block. Operator values are preserved; only names, units and
    nesting change.

    The previous file is kept alongside as `<config>.pre-renaming`. That name is
    deliberately not `.backup` -- the runner's own template reconciliation writes
    `test.config.yml.backup`, and a migration must not overwrite the artifact an
    operator may still need from a reset.

    Re-running is safe: a config that carries no retired key is reported as
    already converted and left untouched (nothing is written, no backup is
    taken). A config that carries BOTH forms of a key -- an interrupted or
    hand-edited migration -- stops with the conflicting pairs listed, because
    only the operator knows which value is the live one.
.PARAMETER ConfigPath
    test.config.yml to convert. Default: test/test.config.yml next to this repo.
.PARAMETER WhatIf
    Report what would change without writing.
.EXAMPLE
    pwsh tools/Update-TestConfigNaming.ps1
.EXAMPLE
    pwsh tools/Update-TestConfigNaming.ps1 -ConfigPath /path/to/test.config.yml -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot 'test/test.config.yml' }

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Error "Config not found: $ConfigPath"
    exit 2
}

$modulesDir = Join-Path $RepoRoot 'test/modules'
Import-Module (Join-Path $modulesDir 'Test.ConfigNaming.psm1') -Force -DisableNameChecking
# ConvertTo-SortedConfig gives the migrated file the same alphabetical shape the
# runner's template reconciliation writes, so the first cycle after a migration
# does not rewrite the file again just to reorder it.
Import-Module (Join-Path $modulesDir 'Test.ConfigSync.psm1') -Force -DisableNameChecking

if (-not (Get-Module -ListAvailable powershell-yaml)) {
    Write-Error "powershell-yaml is not installed. Install-Module powershell-yaml -Scope CurrentUser"
    exit 2
}
Import-Module powershell-yaml -DisableNameChecking

$rawText = Get-Content -Raw -LiteralPath $ConfigPath
$retired = @(Get-RetiredConfigKeyPresent -Text $rawText)

if ($retired.Count -eq 0) {
    Write-Information "$ConfigPath already uses the current key names -- nothing to convert." -InformationAction Continue
    exit 0
}

# A key present in BOTH forms cannot be resolved here: renaming the old one over
# the new one would silently discard whichever value the operator meant to keep.
$conflicts = @($retired | Where-Object { Test-RetiredConfigKeyLine -Text $rawText -DottedPath $_.New })
if ($conflicts.Count -gt 0) {
    foreach ($c in $conflicts) {
        Write-Warning "Both '$($c.Old)' and '$($c.New)' are present -- keep one and delete the other."
    }
    Write-Error "Conversion stopped: $($conflicts.Count) key(s) present in both the retired and the current form."
    exit 1
}

function Get-ConfigNode {
    <#
    .SYNOPSIS
        The dictionary holding $DottedPath's leaf, or $null when a parent level
        is missing. -Create builds missing parents as ordered dictionaries.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$DottedPath,
        [switch]$Create
    )
    $parts = $DottedPath.Split('.')
    $node  = $Config
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $seg = $parts[$i]
        if (-not ($node -is [System.Collections.IDictionary])) { return $null }
        if (-not $node.Contains($seg)) {
            if (-not $Create) { return $null }
            $node[$seg] = [ordered]@{}
        } elseif (-not ($node[$seg] -is [System.Collections.IDictionary])) {
            if (-not $Create) { return $null }
            $node[$seg] = [ordered]@{}
        }
        $node = $node[$seg]
    }
    if (-not ($node -is [System.Collections.IDictionary])) { return $null }
    return $node
}

$config = ConvertFrom-Yaml -Yaml $rawText -Ordered

$changes = [System.Collections.Generic.List[string]]::new()
foreach ($r in $retired) {
    $oldLeaf   = $r.Old.Split('.')[-1]
    $newLeaf   = $r.New.Split('.')[-1]
    $oldParent = Get-ConfigNode -Config $config -DottedPath $r.Old
    if ($null -eq $oldParent -or -not $oldParent.Contains($oldLeaf)) { continue }

    $value = $oldParent[$oldLeaf]
    if ($r.Factor -ne 1 -and $null -ne $value) {
        # A duration whose unit changed. Ints stay ints -- a float here would
        # serialize as "2700.0" and read back as a different YAML type.
        $value = [int]([double]$value * $r.Factor)
    }
    $oldParent.Remove($oldLeaf)
    $newParent = Get-ConfigNode -Config $config -DottedPath $r.New -Create
    $newParent[$newLeaf] = $value
    $suffix = if ($r.Factor -ne 1) { " (value x $($r.Factor) -> $value)" } else { "" }
    [void]$changes.Add("  $($r.Old) -> $($r.New)$suffix")
}

Write-Information "Converting $ConfigPath ($($changes.Count) key(s)):" -InformationAction Continue
foreach ($c in $changes) { Write-Information $c -InformationAction Continue }

$sorted   = ConvertTo-SortedConfig $config
$newYaml  = $sorted | ConvertTo-Yaml
$backup   = "$ConfigPath.pre-renaming"

if (-not $PSCmdlet.ShouldProcess($ConfigPath, "Rewrite with current key names (backup -> $backup)")) {
    Write-Information "-WhatIf: nothing written." -InformationAction Continue
    exit 0
}

Copy-Item -LiteralPath $ConfigPath -Destination $backup -Force
Set-Content -LiteralPath $ConfigPath -Value $newYaml -NoNewline -Encoding utf8
Write-Information "Wrote $ConfigPath (previous file kept as $backup)." -InformationAction Continue
exit 0
