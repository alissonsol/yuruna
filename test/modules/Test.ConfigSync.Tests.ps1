<#PSScriptInfo
.VERSION 2026.07.07
.GUID 42b593af-6071-4283-9d94-0f1a2b3c4d5e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test config pester
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

<#
.SYNOPSIS
    Pester coverage for Test.ConfigSync.psm1 (test.config.yml <-> template
    reconciliation), including Update-TestConfigFromTemplate's merge, deprecated-
    key drop, keystroke-mechanism normalization, and structure-departure backup.
.DESCRIPTION
    Throw-based assertions so the file runs under the OS-bundled Pester 3.4 and
    Pester 5+. Run: Invoke-Pester -Path test/modules/Test.ConfigSync.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Prelude.psm1')   -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.ConfigSync.psm1') -Force -DisableNameChecking
try { Import-Module powershell-yaml -Force -ErrorAction Stop } catch { Write-Warning "powershell-yaml unavailable; YAML tests will fail." }

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

$script:MinimalTemplate = @"
vmStart:
  startTimeoutSeconds: 120
  bootDelaySeconds: 15
vmImage:
  refreshHours: 24
vmCommunication:
  keystrokeMechanism: GUI
testCycle:
  shouldStopOnFailure: false
  cycleDelaySeconds: 30
repositories:
  frameworkUrl: https://example/framework
"@

function New-TempDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test helper: creates a throwaway temp directory the calling It block deletes in its finally.')]
    [CmdletBinding()] [OutputType([string])] param()
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("yrn-cfgsync-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $d
    return $d
}

Describe 'ConvertTo-MergedHashtable' {
    It 'template shape wins, current scalars win, current-only keys dropped, template fills gaps' {
        $tmpl = [ordered]@{ a = 1; b = [ordered]@{ x = 10; y = 20 }; arr = @('t'); z = 'def' }
        $cur  = [ordered]@{ a = 99; b = [ordered]@{ x = 11; orphan = 'drop' }; arr = @('c1','c2'); extra = 'drop' }
        $m = ConvertTo-MergedHashtable -Template $tmpl -Current $cur
        Assert-Equal -Expected 99 -Actual $m.a -Because 'current scalar wins'
        Assert-Equal -Expected 11 -Actual $m.b.x -Because 'current nested scalar wins'
        Assert-Equal -Expected 20 -Actual $m.b.y -Because 'template fills missing nested'
        Assert-Equal -Expected 'def' -Actual $m.z -Because 'template fills missing top-level'
        Assert-Equal -Expected 2 -Actual $m.arr.Count -Because 'current array value wins'
        Assert-True (-not $m.b.Contains('orphan')) 'nested current-only key dropped'
        Assert-True (-not $m.Contains('extra')) 'top-level current-only key dropped'
    }
    It 'returns the template unchanged when current is not a dictionary' {
        $tmpl = [ordered]@{ a = 1 }
        $m = ConvertTo-MergedHashtable -Template $tmpl -Current 'scalar'
        Assert-Equal -Expected 1 -Actual $m.a -Because 'template default used when current is scalar'
    }
}

Describe 'ConvertTo-SortedConfig' {
    It 'sorts map keys at every level and scalar-array elements, preserving values' {
        $in = [ordered]@{ z = 1; a = [ordered]@{ y = 2; x = 3 }; arr = @('c','a','b') }
        $m = ConvertTo-SortedConfig $in
        Assert-Equal -Expected 'a, arr, z' -Actual (($m.Keys) -join ', ') -Because 'top-level keys sorted'
        Assert-Equal -Expected 'x, y' -Actual (($m.a.Keys) -join ', ') -Because 'nested keys sorted'
        Assert-Equal -Expected 'a|b|c' -Actual ($m.arr -join '|') -Because 'scalar array elements sorted'
        Assert-Equal -Expected 1 -Actual $m.z -Because 'scalar value preserved'
        Assert-Equal -Expected 3 -Actual $m.a.x -Because 'nested value preserved'
    }
    It 'keeps array-of-maps element order but sorts each map element keys' {
        $in = [ordered]@{ list = @( [ordered]@{ b = 2; a = 1 }, [ordered]@{ d = 4; c = 3 } ) }
        $m = ConvertTo-SortedConfig $in
        Assert-Equal -Expected 'a, b' -Actual (($m.list[0].Keys) -join ', ') -Because 'first element keys sorted'
        Assert-Equal -Expected 1 -Actual $m.list[0].a -Because 'first element value preserved, order kept'
        Assert-Equal -Expected 3 -Actual $m.list[1].c -Because 'second element order kept (not reordered by value)'
    }
    It 'passes a scalar through unchanged' {
        Assert-Equal -Expected 'scalar' -Actual (ConvertTo-SortedConfig 'scalar') -Because 'non-collection passthrough'
    }
    It 'keeps a single-element scalar array AS AN ARRAY (no list -> scalar unwrap) and an empty array empty' {
        $in = [ordered]@{ one = @('solo'); none = @() }
        $m = ConvertTo-SortedConfig $in
        Assert-True (($m.one -is [System.Collections.IEnumerable]) -and ($m.one -isnot [string])) 'single-element array stays an array, not a bare scalar'
        Assert-Equal -Expected 'solo' -Actual $m.one[0] -Because 'single element preserved'
        Assert-True (($m.none -is [System.Collections.IEnumerable]) -and ($m.none -isnot [string])) 'empty array stays an array (serializes as []), not null'
        # Round-trip through YAML: a one-element list must reparse as a list, not a string.
        $rt = ($m | ConvertTo-Yaml) | ConvertFrom-Yaml -Ordered
        Assert-True (($rt.one -is [System.Collections.IEnumerable]) -and ($rt.one -isnot [string])) 'one-element list round-trips as a YAML block sequence'
    }
}

Describe 'Sync-TestConfigToTemplate' {
    It 'adds missing fields, drops the renamed-section orphan, sorts, and backs up the dropped value' {
        $d = New-TempDir
        try {
            # Template renamed the old top-level poolStorage block to networkStorage.*
            # and is deliberately authored out of alphabetical order.
            $tmpl = Join-Path $d 'template.yml'
            Set-Content $tmpl "networkStorage:`n  poolLocalPath: ''`n  poolNetworkPath: ''`nlogLevel: Information`n"
            $cfg = Join-Path $d 'test.config.yml'
            Set-Content $cfg "logLevel: Information`npoolStorage:`n  localPath: 'y:'`n"
            $res = Sync-TestConfigToTemplate -Template (Get-Content -Raw $tmpl | ConvertFrom-Yaml -Ordered) `
                                             -Current  (Get-Content -Raw $cfg  | ConvertFrom-Yaml -Ordered) `
                                             -ConfigPath $cfg
            Assert-True $res.Wrote 'file rewritten'
            Assert-True ($res.Added -contains 'networkStorage.poolLocalPath') 'new schema field reported as added'
            Assert-True ($res.Removed -contains 'poolStorage.localPath') 'renamed-section old key reported as removed'
            Assert-True (Test-Path "$cfg.backup") 'populated dropped key triggers a backup'
            Assert-Equal -Expected "$cfg.backup" -Actual $res.BackupPath -Because 'backup path reported'

            $onDisk = Get-Content -Raw $cfg | ConvertFrom-Yaml -Ordered
            Assert-True ($onDisk.Contains('networkStorage')) 'new node written'
            Assert-True (-not $onDisk.Contains('poolStorage')) 'orphan node REMOVED from the file'
            Assert-Equal -Expected 'logLevel, networkStorage' -Actual (($onDisk.Keys) -join ', ') -Because 'top-level keys written in alphabetical order'
            $bak = Get-Content -Raw "$cfg.backup" | ConvertFrom-Yaml -Ordered
            Assert-Equal -Expected 'y:' -Actual $bak.poolStorage.localPath -Because 'removed value recoverable from .backup'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'adds a missing field with NO backup when nothing populated is dropped' {
        $d = New-TempDir
        try {
            $tmpl = Join-Path $d 'template.yml'
            Set-Content $tmpl "logLevel: Information`nnetworkStorage:`n  poolLocalPath: ''`n  poolNetworkPath: ''`n"
            $cfg = Join-Path $d 'test.config.yml'
            Set-Content $cfg "logLevel: Information`nnetworkStorage:`n  poolLocalPath: 'y:'`n"
            $res = Sync-TestConfigToTemplate -Template (Get-Content -Raw $tmpl | ConvertFrom-Yaml -Ordered) `
                                             -Current  (Get-Content -Raw $cfg  | ConvertFrom-Yaml -Ordered) `
                                             -ConfigPath $cfg
            Assert-True $res.Wrote 'file rewritten (field added)'
            Assert-True ($res.Added -contains 'networkStorage.poolNetworkPath') 'missing field added'
            Assert-Equal -Expected 0 -Actual $res.Removed.Count -Because 'nothing populated dropped'
            Assert-True (-not (Test-Path "$cfg.backup")) 'pure add/sort writes NO backup'
            Assert-Equal -Expected $null -Actual $res.BackupPath -Because 'no backup path when nothing dropped'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'is a no-op when the file is already canonical (sorted, every field, no orphan)' {
        $d = New-TempDir
        try {
            $tmpl = Join-Path $d 'template.yml'
            Set-Content $tmpl "logLevel: Information`nnetworkStorage:`n  poolLocalPath: ''`n"
            $cfg = Join-Path $d 'test.config.yml'
            Set-Content $cfg "logLevel: Information`nnetworkStorage:`n  poolLocalPath: 'y:'`n"
            $before = Get-Item -LiteralPath $cfg
            $res = Sync-TestConfigToTemplate -Template (Get-Content -Raw $tmpl | ConvertFrom-Yaml -Ordered) `
                                             -Current  (Get-Content -Raw $cfg  | ConvertFrom-Yaml -Ordered) `
                                             -ConfigPath $cfg
            Assert-True (-not $res.Wrote) 'no rewrite when already canonical'
            Assert-Equal -Expected 0 -Actual $res.Added.Count -Because 'nothing added'
            Assert-Equal -Expected 0 -Actual $res.Removed.Count -Because 'nothing removed'
            Assert-Equal -Expected $before.LastWriteTimeUtc -Actual (Get-Item -LiteralPath $cfg).LastWriteTimeUtc -Because 'file untouched on disk'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'preserves the out-of-band secrets node, never reporting it as removed' {
        $d = New-TempDir
        try {
            $tmpl = Join-Path $d 'template.yml'
            Set-Content $tmpl "logLevel: Information`n"
            $cfg = Join-Path $d 'test.config.yml'
            Set-Content $cfg "logLevel: Information`nsecrets:`n  apiKey: SHHH`n"
            $res = Sync-TestConfigToTemplate -Template (Get-Content -Raw $tmpl | ConvertFrom-Yaml -Ordered) `
                                             -Current  (Get-Content -Raw $cfg  | ConvertFrom-Yaml -Ordered) `
                                             -ConfigPath $cfg
            Assert-True (-not ($res.Removed -contains 'secrets.apiKey')) 'secrets never reported as removed'
            Assert-True ($res.Config.Contains('secrets')) 'secrets node preserved in the result'
            Assert-Equal -Expected 'SHHH' -Actual $res.Config.secrets.apiKey -Because 'secret value untouched'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Copy-HashtableWithoutSecretNode' {
    It 'drops the secrets node, keeps the rest, passes non-dict through' {
        $c = [ordered]@{ a = 1; secrets = @{ k = 'v' }; b = 2 }
        $copy = Copy-HashtableWithoutSecretNode $c
        Assert-True (-not $copy.Contains('secrets')) 'secrets dropped'
        Assert-Equal -Expected 1 -Actual $copy.a -Because 'a kept'
        Assert-Equal -Expected 2 -Actual $copy.b -Because 'b kept'
        Assert-Equal -Expected 'scalar' -Actual (Copy-HashtableWithoutSecretNode 'scalar') -Because 'non-dict passthrough'
    }
}

Describe 'Test-ConfigMatchesTemplateShape' {
    $tmpl = [ordered]@{ a = 1; node = [ordered]@{ x = 1 } }
    It 'true when nested node shape matches' {
        Assert-True (Test-ConfigMatchesTemplateShape -Template $tmpl -Current ([ordered]@{ a = 5; node = [ordered]@{ x = 9 } })) 'same shape'
    }
    It 'false when a required nested node is missing or flattened' {
        Assert-True (-not (Test-ConfigMatchesTemplateShape -Template $tmpl -Current ([ordered]@{ a = 5 }))) 'missing node'
        Assert-True (-not (Test-ConfigMatchesTemplateShape -Template $tmpl -Current ([ordered]@{ a = 5; node = 'flat' }))) 'flattened node'
    }
    It 'false on an unexpected top-level key, but secrets is exempt' {
        Assert-True (-not (Test-ConfigMatchesTemplateShape -Template $tmpl -Current ([ordered]@{ a = 5; node = [ordered]@{ x = 9 }; extra = 1 }))) 'extra key rejected'
        Assert-True (Test-ConfigMatchesTemplateShape -Template $tmpl -Current ([ordered]@{ a = 5; node = [ordered]@{ x = 9 }; secrets = @{} })) 'secrets exempt'
    }
}

Describe 'Hide-SecretsInConfig' {
    It 'empties the secrets node in place and no-ops without one' {
        $c = [ordered]@{ a = 1; secrets = [ordered]@{ apiKey = 'XYZ'; pw = 'p' } }
        Hide-SecretsInConfig $c
        Assert-Equal -Expected 0 -Actual $c.secrets.Keys.Count -Because 'secrets emptied'
        Assert-Equal -Expected 1 -Actual $c.a -Because 'non-secret kept'
        $noSec = [ordered]@{ a = 1 }
        Hide-SecretsInConfig $noSec   # must not throw
        Assert-Equal -Expected 1 -Actual $noSec.a -Because 'no-secrets no-op'
    }
}

Describe 'Update-TestConfigFromTemplate' {
    It 'bootstraps a missing config by copying the template' {
        $d = New-TempDir
        try {
            $tmpl = Join-Path $d 'template.yml'; Set-Content $tmpl $script:MinimalTemplate
            $cfg  = Join-Path $d 'test.config.yml'
            $r = Update-TestConfigFromTemplate -ConfigPath $cfg -TemplatePath $tmpl
            Assert-True (Test-Path $cfg) 'config created from template'
            Assert-True ($r -is [System.Collections.IDictionary]) 'returns dictionary'
            Assert-Equal -Expected 120 -Actual $r.vmStart.startTimeoutSeconds -Because 'template value present'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'overlays new template keys onto an existing config and rewrites on diff' {
        $d = New-TempDir
        try {
            $tmpl = Join-Path $d 'template.yml'; Set-Content $tmpl $script:MinimalTemplate
            $cfg  = Join-Path $d 'test.config.yml'
            # Config matches the nested SHAPE but is missing vmImage.refreshHours and
            # carries an operator override for startTimeoutSeconds.
            Set-Content $cfg "vmStart:`n  startTimeoutSeconds: 300`n  bootDelaySeconds: 15`nvmImage: {}`nvmCommunication:`n  keystrokeMechanism: GUI`ntestCycle:`n  shouldStopOnFailure: false`n  cycleDelaySeconds: 30`nrepositories:`n  frameworkUrl: https://example/framework`n"
            $r = Update-TestConfigFromTemplate -ConfigPath $cfg -TemplatePath $tmpl
            Assert-Equal -Expected 300 -Actual $r.vmStart.startTimeoutSeconds -Because 'operator override preserved'
            Assert-Equal -Expected 24  -Actual $r.vmImage.refreshHours -Because 'missing template key filled'
            $onDisk = Get-Content -Raw $cfg | ConvertFrom-Yaml -Ordered
            Assert-Equal -Expected 24 -Actual $onDisk.vmImage.refreshHours -Because 'rewrite persisted the merge'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'drops the deprecated hostSshServer top-level key' {
        $d = New-TempDir
        try {
            $tmpl = Join-Path $d 'template.yml'; Set-Content $tmpl $script:MinimalTemplate
            $cfg  = Join-Path $d 'test.config.yml'
            Set-Content $cfg "hostSshServer: legacy`nvmStart:`n  startTimeoutSeconds: 120`n  bootDelaySeconds: 15`nvmImage:`n  refreshHours: 24`nvmCommunication:`n  keystrokeMechanism: GUI`ntestCycle:`n  shouldStopOnFailure: false`n  cycleDelaySeconds: 30`nrepositories:`n  frameworkUrl: https://example/framework`n"
            $r = Update-TestConfigFromTemplate -ConfigPath $cfg -TemplatePath $tmpl
            Assert-True (-not $r.Contains('hostSshServer')) 'deprecated key dropped'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'normalizes a lowercase keystrokeMechanism and resets an invalid one' {
        $d = New-TempDir
        try {
            $tmpl = Join-Path $d 'template.yml'; Set-Content $tmpl $script:MinimalTemplate
            $cfgLower = Join-Path $d 'lower.yml'
            Set-Content $cfgLower ($script:MinimalTemplate -replace 'keystrokeMechanism: GUI', 'keystrokeMechanism: ssh')
            $rLower = Update-TestConfigFromTemplate -ConfigPath $cfgLower -TemplatePath $tmpl
            Assert-Equal -Expected 'SSH' -Actual $rLower.vmCommunication.keystrokeMechanism -Because 'lowercase normalized to upper'
            $cfgBad = Join-Path $d 'bad.yml'
            Set-Content $cfgBad ($script:MinimalTemplate -replace 'keystrokeMechanism: GUI', 'keystrokeMechanism: hypervisor')
            $rBad = Update-TestConfigFromTemplate -ConfigPath $cfgBad -TemplatePath $tmpl
            Assert-Equal -Expected 'GUI' -Actual $rBad.vmCommunication.keystrokeMechanism -Because 'invalid reset to template default'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'backs up and exits non-zero when the on-disk config departs from the nested shape' {
        $d = New-TempDir
        try {
            $tmpl = Join-Path $d 'template.yml'; Set-Content $tmpl $script:MinimalTemplate
            $cfg  = Join-Path $d 'test.config.yml'
            Set-Content $cfg "vmBootDelaySeconds: 15`nframeworkRepoUrl: https://legacy`n"   # flat (pre-nesting) layout
            # Runs in a child pwsh because the structure-departure path calls exit
            # (a flat layout has no fields that map to the nested schema).
            $childScript = "Import-Module '$here\Test.Prelude.psm1' -Global -Force -DisableNameChecking; Import-Module powershell-yaml -Global -Force; Import-Module '$here\Test.ConfigSync.psm1' -Global -Force -DisableNameChecking; Update-TestConfigFromTemplate -ConfigPath '$cfg' -TemplatePath '$tmpl' -WarningAction SilentlyContinue | Out-Null"
            $sf = Join-Path $d 'child.ps1'; Set-Content $sf $childScript
            & pwsh -NoProfile -NonInteractive -File $sf 2>&1 | Out-Null
            Assert-True ($LASTEXITCODE -ne 0) "structure-departure exits non-zero (was $LASTEXITCODE)"
            Assert-True (Test-Path "$cfg.backup") 'previous config backed up to .backup'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'carries every matching value forward and continues when the schema only adds a node' {
        $d = New-TempDir
        try {
            # Template = minimal + a new 'pool' node the existing file predates.
            $tmpl = Join-Path $d 'template.yml'
            Set-Content $tmpl ($script:MinimalTemplate + "`npool:`n  enabled: false`n  intentGitUrl: ''`n")
            $cfg = Join-Path $d 'test.config.yml'
            # Shape-valid for the OLD schema (no 'pool'), with operator overrides.
            Set-Content $cfg "vmStart:`n  startTimeoutSeconds: 300`n  bootDelaySeconds: 15`nvmImage:`n  refreshHours: 24`nvmCommunication:`n  keystrokeMechanism: GUI`ntestCycle:`n  shouldStopOnFailure: false`n  cycleDelaySeconds: 30`nrepositories:`n  frameworkUrl: https://operator/fork`n"
            $r = Update-TestConfigFromTemplate -ConfigPath $cfg -TemplatePath $tmpl -InformationAction SilentlyContinue
            Assert-True ($r -is [System.Collections.IDictionary]) 'returns merged config (did not exit)'
            Assert-Equal -Expected 300 -Actual $r.vmStart.startTimeoutSeconds -Because 'operator override carried forward'
            Assert-Equal -Expected 'https://operator/fork' -Actual $r.repositories.frameworkUrl -Because 'operator url carried forward'
            Assert-True ($r.Contains('pool')) 'new template node added'
            Assert-True (Test-Path "$cfg.backup") 'previous file backed up'
            $onDisk = Get-Content -Raw $cfg | ConvertFrom-Yaml -Ordered
            Assert-Equal -Expected 300 -Actual $onDisk.vmStart.startTimeoutSeconds -Because 'carried value persisted to disk'
            Assert-True ($onDisk.Contains('pool')) 'new node persisted to disk'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'carries matching values forward into the new file even when it must stop for an unmappable field' {
        $d = New-TempDir
        try {
            $tmpl = Join-Path $d 'template.yml'; Set-Content $tmpl $script:MinimalTemplate
            $cfg  = Join-Path $d 'test.config.yml'
            # Shape-valid nested fields (carryable) + an orphan top-level key with a value (unmappable).
            Set-Content $cfg "vmStart:`n  startTimeoutSeconds: 300`n  bootDelaySeconds: 15`nvmImage:`n  refreshHours: 24`nvmCommunication:`n  keystrokeMechanism: GUI`ntestCycle:`n  shouldStopOnFailure: false`n  cycleDelaySeconds: 30`nrepositories:`n  frameworkUrl: https://example/framework`nlegacyOrphan: keepme`n"
            # Child pwsh: the unmappable orphan makes it stop for operator review.
            $childScript = "Import-Module '$here\Test.Prelude.psm1' -Global -Force -DisableNameChecking; Import-Module powershell-yaml -Global -Force; Import-Module '$here\Test.ConfigSync.psm1' -Global -Force -DisableNameChecking; Update-TestConfigFromTemplate -ConfigPath '$cfg' -TemplatePath '$tmpl' -WarningAction SilentlyContinue -InformationAction SilentlyContinue | Out-Null"
            $sf = Join-Path $d 'child.ps1'; Set-Content $sf $childScript
            & pwsh -NoProfile -NonInteractive -File $sf 2>&1 | Out-Null
            Assert-True ($LASTEXITCODE -ne 0) "unmappable field stops the run (was $LASTEXITCODE)"
            Assert-True (Test-Path "$cfg.backup") 'previous config backed up'
            $onDisk = Get-Content -Raw $cfg | ConvertFrom-Yaml -Ordered
            Assert-Equal -Expected 300 -Actual $onDisk.vmStart.startTimeoutSeconds -Because 'matching value carried forward into the new file'
            Assert-True (-not $onDisk.Contains('legacyOrphan')) 'unmappable orphan dropped from the new file'
            $bak = Get-Content -Raw "$cfg.backup" | ConvertFrom-Yaml -Ordered
            Assert-Equal -Expected 'keepme' -Actual $bak.legacyOrphan -Because 'orphan value recoverable from the .backup'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-DroppedConfigField' {
    It 'flags only non-empty current leaves absent from the merge' {
        $current = [ordered]@{ a = 1; node = [ordered]@{ x = 'keep'; gone = 'lost' }; orphan = 'lost2'; blank = ''; emptyArr = @() }
        $merged  = [ordered]@{ a = 1; node = [ordered]@{ x = 'keep' } }
        $dropped = @(Get-DroppedConfigField -Current $current -Merged $merged)
        Assert-True ($dropped -contains 'node.gone') 'nested unmapped value flagged'
        Assert-True ($dropped -contains 'orphan') 'top-level orphan flagged'
        Assert-True (-not ($dropped -contains 'a')) 'carried scalar not flagged'
        Assert-True (-not ($dropped -contains 'node.x')) 'carried nested not flagged'
        Assert-True (-not ($dropped -contains 'blank')) 'empty string not flagged'
        Assert-True (-not ($dropped -contains 'emptyArr')) 'empty array not flagged'
    }
    It 'returns nothing when every leaf was carried' {
        $c = [ordered]@{ a = 1; b = [ordered]@{ x = 2 } }
        Assert-Equal -Expected 0 -Actual (@(Get-DroppedConfigField -Current $c -Merged $c)).Count -Because 'identical -> none dropped'
    }
}
