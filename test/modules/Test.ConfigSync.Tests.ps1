<#PSScriptInfo
.VERSION 2026.06.19
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
        Assert-Equal 99 $m.a 'current scalar wins'
        Assert-Equal 11 $m.b.x 'current nested scalar wins'
        Assert-Equal 20 $m.b.y 'template fills missing nested'
        Assert-Equal 'def' $m.z 'template fills missing top-level'
        Assert-Equal 2 $m.arr.Count 'current array value wins'
        Assert-True (-not $m.b.Contains('orphan')) 'nested current-only key dropped'
        Assert-True (-not $m.Contains('extra')) 'top-level current-only key dropped'
    }
    It 'returns the template unchanged when current is not a dictionary' {
        $tmpl = [ordered]@{ a = 1 }
        $m = ConvertTo-MergedHashtable -Template $tmpl -Current 'scalar'
        Assert-Equal 1 $m.a 'template default used when current is scalar'
    }
}

Describe 'ConvertTo-AdditiveMergedHashtable' {
    It 'fills missing template nodes/leaves, current value wins, current-only keys preserved' {
        $tmpl = [ordered]@{ a = 1; b = [ordered]@{ x = 10; y = 20 }; net = [ordered]@{ p = ''; q = '' }; z = 'def' }
        $cur  = [ordered]@{ a = 99; b = [ordered]@{ x = 11 }; legacy = 'keep'; oldNode = [ordered]@{ k = 'keep2' } }
        $m = ConvertTo-AdditiveMergedHashtable -Template $tmpl -Current $cur
        Assert-Equal 99 $m.a 'current scalar wins'
        Assert-Equal 11 $m.b.x 'current nested scalar wins'
        Assert-Equal 20 $m.b.y 'template fills missing nested leaf'
        Assert-Equal 'def' $m.z 'template fills missing top-level leaf'
        Assert-True ($m.Contains('net')) 'whole missing template node added'
        Assert-Equal '' $m.net.p 'added node carries empty template default'
        Assert-Equal 'keep'  $m.legacy 'current-only top-level key PRESERVED (not dropped)'
        Assert-Equal 'keep2' $m.oldNode.k 'current-only nested node PRESERVED'
    }
    It 'preserves an operator scalar where the template has a node (shape conflict, no clobber)' {
        $tmpl = [ordered]@{ node = [ordered]@{ x = 1 } }
        $cur  = [ordered]@{ node = 'operatorScalar' }
        $m = ConvertTo-AdditiveMergedHashtable -Template $tmpl -Current $cur
        Assert-Equal 'operatorScalar' $m.node 'operator scalar kept, not overwritten with template sub-fields'
    }
    It 'deep-copies the added template subtree so later edits do not alias the template' {
        $tmpl = [ordered]@{ net = [ordered]@{ p = '' } }
        $cur  = [ordered]@{ a = 1 }
        $m = ConvertTo-AdditiveMergedHashtable -Template $tmpl -Current $cur
        $m.net.p = 'mutated'
        Assert-Equal '' $tmpl.net.p 'mutating the merged result did not bleed into the template'
    }
    It 'returns current unchanged when current is not a dictionary' {
        Assert-Equal 'scalar' (ConvertTo-AdditiveMergedHashtable -Template ([ordered]@{ a = 1 }) -Current 'scalar') 'non-dict current passthrough'
    }
}

Describe 'Add-MissingTestConfigField' {
    It 'adds missing schema fields, keeps the renamed-section orphan, writes no backup' {
        $d = New-TempDir
        try {
            # Template renamed the old top-level poolStorage block to networkStorage.*
            $tmpl = Join-Path $d 'template.yml'
            Set-Content $tmpl "logLevel: Information`nnetworkStorage:`n  poolLocalPath: ''`n  poolNetworkPath: ''`n  poolNetworkUser: ''`n"
            $cfg = Join-Path $d 'test.config.yml'
            Set-Content $cfg "logLevel: Information`npoolStorage:`n  localPath: 'y:'`n  networkPath: '\\\\nas\\work'`n  networkUser: yuruna-pool`n"
            $res = Add-MissingTestConfigField -Template (Get-Content -Raw $tmpl | ConvertFrom-Yaml -Ordered) `
                                              -Current  (Get-Content -Raw $cfg  | ConvertFrom-Yaml -Ordered) `
                                              -ConfigPath $cfg
            Assert-True $res.Wrote 'file was rewritten (fields were missing)'
            Assert-True ($res.Added -contains 'networkStorage.poolLocalPath') 'new schema field reported as added'
            Assert-True ($res.Orphans -contains 'poolStorage.localPath') 'renamed-section old key reported as orphan'
            Assert-True (-not (Test-Path "$cfg.backup")) 'additive enforcement leaves NO backup'

            $onDisk = Get-Content -Raw $cfg | ConvertFrom-Yaml -Ordered
            Assert-True ($onDisk.Contains('networkStorage')) 'new node written to disk'
            Assert-Equal '' $onDisk.networkStorage.poolLocalPath 'new field is the empty default to fill in'
            Assert-True ($onDisk.Contains('poolStorage')) 'operator old keys LEFT in place for hand-migration'
            Assert-Equal 'y:' $onDisk.poolStorage.localPath 'old value preserved on disk (recoverable to copy across)'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'is a no-op (no rewrite) when the file already carries every schema field' {
        $d = New-TempDir
        try {
            $tmpl = Join-Path $d 'template.yml'
            Set-Content $tmpl "logLevel: Information`nnetworkStorage:`n  poolLocalPath: ''`n"
            $cfg = Join-Path $d 'test.config.yml'
            Set-Content $cfg "logLevel: Information`nnetworkStorage:`n  poolLocalPath: 'y:'`n"
            $before = Get-Item -LiteralPath $cfg
            $res = Add-MissingTestConfigField -Template (Get-Content -Raw $tmpl | ConvertFrom-Yaml -Ordered) `
                                              -Current  (Get-Content -Raw $cfg  | ConvertFrom-Yaml -Ordered) `
                                              -ConfigPath $cfg
            Assert-True (-not $res.Wrote) 'nothing missing -> no rewrite'
            Assert-Equal 0 $res.Added.Count 'no fields added'
            Assert-Equal 0 $res.Orphans.Count 'no orphans'
            Assert-Equal $before.LastWriteTimeUtc (Get-Item -LiteralPath $cfg).LastWriteTimeUtc 'file untouched on disk'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Copy-HashtableWithoutSecretNode' {
    It 'drops the secrets node, keeps the rest, passes non-dict through' {
        $c = [ordered]@{ a = 1; secrets = @{ k = 'v' }; b = 2 }
        $copy = Copy-HashtableWithoutSecretNode $c
        Assert-True (-not $copy.Contains('secrets')) 'secrets dropped'
        Assert-Equal 1 $copy.a 'a kept'
        Assert-Equal 2 $copy.b 'b kept'
        Assert-Equal 'scalar' (Copy-HashtableWithoutSecretNode 'scalar') 'non-dict passthrough'
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
        Assert-Equal 0 $c.secrets.Keys.Count 'secrets emptied'
        Assert-Equal 1 $c.a 'non-secret kept'
        $noSec = [ordered]@{ a = 1 }
        Hide-SecretsInConfig $noSec   # must not throw
        Assert-Equal 1 $noSec.a 'no-secrets no-op'
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
            Assert-Equal 120 $r.vmStart.startTimeoutSeconds 'template value present'
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
            Assert-Equal 300 $r.vmStart.startTimeoutSeconds 'operator override preserved'
            Assert-Equal 24  $r.vmImage.refreshHours 'missing template key filled'
            $onDisk = Get-Content -Raw $cfg | ConvertFrom-Yaml -Ordered
            Assert-Equal 24 $onDisk.vmImage.refreshHours 'rewrite persisted the merge'
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
            Assert-Equal 'SSH' $rLower.vmCommunication.keystrokeMechanism 'lowercase normalized to upper'
            $cfgBad = Join-Path $d 'bad.yml'
            Set-Content $cfgBad ($script:MinimalTemplate -replace 'keystrokeMechanism: GUI', 'keystrokeMechanism: hypervisor')
            $rBad = Update-TestConfigFromTemplate -ConfigPath $cfgBad -TemplatePath $tmpl
            Assert-Equal 'GUI' $rBad.vmCommunication.keystrokeMechanism 'invalid reset to template default'
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
            Assert-Equal 300 $r.vmStart.startTimeoutSeconds 'operator override carried forward'
            Assert-Equal 'https://operator/fork' $r.repositories.frameworkUrl 'operator url carried forward'
            Assert-True ($r.Contains('pool')) 'new template node added'
            Assert-True (Test-Path "$cfg.backup") 'previous file backed up'
            $onDisk = Get-Content -Raw $cfg | ConvertFrom-Yaml -Ordered
            Assert-Equal 300 $onDisk.vmStart.startTimeoutSeconds 'carried value persisted to disk'
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
            Assert-Equal 300 $onDisk.vmStart.startTimeoutSeconds 'matching value carried forward into the new file'
            Assert-True (-not $onDisk.Contains('legacyOrphan')) 'unmappable orphan dropped from the new file'
            $bak = Get-Content -Raw "$cfg.backup" | ConvertFrom-Yaml -Ordered
            Assert-Equal 'keepme' $bak.legacyOrphan 'orphan value recoverable from the .backup'
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
        Assert-Equal 0 (@(Get-DroppedConfigField -Current $c -Merged $c)).Count 'identical -> none dropped'
    }
}
