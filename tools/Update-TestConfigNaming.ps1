<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 42f97555-078b-4a8e-8eef-1fac4bd333c4
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
    taken). Registered obsolete comments can restore a replacement whose value
    is blank. Duplicate forms with matching values are reconciled; conflicting
    populated values stop before any file changes. Existing migration backups
    are preserved with an additional unique backup for each changed input.
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
$config = ConvertFrom-Yaml -Yaml $rawText -Ordered
$migration = ConvertTo-ConfigNamingMigration -Config $config -ObsoleteEntry (Get-ObsoleteConfigEntry -Text $rawText)
if ($migration.Changes.Count -eq 0) {
    Write-Information "$ConfigPath already uses the current key names -- nothing to convert." -InformationAction Continue
    exit 0
}
$changes = @($migration.Changes | ForEach-Object {
    $suffix = if ($_.Factor -ne 1) { " (value x $($_.Factor))" } else { '' }
    "  $($_.Old) -> $($_.New)$suffix"
})

Write-Information "Converting $ConfigPath ($($changes.Count) key(s)):" -InformationAction Continue
foreach ($c in $changes) { Write-Information $c -InformationAction Continue }

$sorted = ConvertTo-SortedConfig $migration.Config
$newYaml = $sorted | ConvertTo-Yaml
$obsoleteText = Format-ObsoleteConfigEntry -ObsoleteEntry $migration.Obsolete
if ($obsoleteText) { $newYaml = $newYaml.TrimEnd() + "`n`n" + $obsoleteText + "`n" }

if (-not $PSCmdlet.ShouldProcess($ConfigPath, "Rewrite with current key names and preserve a migration backup")) {
    Write-Information "-WhatIf: nothing written." -InformationAction Continue
    exit 0
}

$backup = New-ConfigNamingBackup -ConfigPath $ConfigPath -Confirm:$false
if (-not (Write-YurunaStateFile -Path $ConfigPath -Content $newYaml -Confirm:$false)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'exceptions.config_naming_save_failed' -Arguments @{ configPath = $ConfigPath })
    exit 1
}
Write-Information "Wrote $ConfigPath (previous file kept as $backup)." -InformationAction Continue
exit 0
