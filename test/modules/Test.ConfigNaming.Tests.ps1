<#PSScriptInfo
.VERSION 2026.10.18
.GUID 42acc4f5-2748-4b33-95f6-25b431645860
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test config naming migration pester
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
    Retired-key detection and the test.config.yml conversion it drives.
.DESCRIPTION
    Test.ConfigNaming is the single table behind two consumers -- Test-Config.ps1's
    rejection and tools/Update-TestConfigNaming.ps1's rewrite -- so a gap here means
    an operator either meets a rejection with no migration behind it, or a migration
    the validator still rejects.

    The cases that matter are the ones a naive implementation gets wrong:

      * A leaf name alone is ambiguous. `enabled` lives under pool, guestQuarantine,
        warmResume, perfLog, statusService and configService; detection has to match
        the whole dotted path or `pool.enabled` reads as `statusService.isEnabled`.
      * `cachingProxyIP` and `cachingProxyIp` differ only in acronym casing. The YAML
        parser returns case-INSENSITIVE dictionaries, so detection has to be
        case-sensitive and text-based to see the difference at all.
      * A unit change is not a rename: minutes and hours have to be multiplied, and
        the result has to stay an integer (a float serializes as "2700.0" and reads
        back as a different YAML type).
      * Running the converter twice must not double-convert, and a file carrying BOTH
        forms of a key must stop rather than guess which value the operator meant.

    The throw-based Assert-* helpers live in the file's BeforeAll, which is the
    scope Pester 5 shares with the It blocks; defining them at script scope
    instead makes every It fail on a missing command rather than on an
    assertion.
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$repoRoot   = Split-Path -Parent (Split-Path -Parent $here)
$modulePath = Join-Path $here 'Test.ConfigNaming.psm1'
$script:MigrateTool = Join-Path $repoRoot 'tools/Update-TestConfigNaming.ps1'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue

# A config in the retired form, with the sibling `enabled` keys that make
# leaf-only detection wrong and the acronym key that makes a case-insensitive
# lookup wrong.
$script:OldConfig = @'
configService:
  isEnabled: true
  port: 8443
networkStorage:
  poolLocalPath: /mnt/ypool-nas
  poolNetworkPath: //ypool-nas/work/yuruna.pool
  poolNetworkUser: yuruna-pool
pool:
  enabled: false
  networkReplicate: true
repositories:
  frameworkUrl: https://example/framework
  GH_TOKEN: "tok"
statusService:
  isEnabled: true
  port: 8080
testCycle:
  autoRemediationEnabled: true
  autoRemediationMaxAttemptsPerCycle: 4
  guestQuarantine:
    enabled: true
  shouldStopOnFailure: false
  stepTimeoutMinutes: 45
vmCommunication:
  characterDelayMs: 20
vmImage:
  refreshHours: 168
vmStart:
  cachingProxyIP: 192.168.7.42
'@

# Run the tool the way an operator does -- a child pwsh -File -- so the test sees
# the real exit code. Dot-invoking it in-process would surface its Write-Error as a
# thrown exception instead ($ErrorActionPreference is Stop inside the tool).
function Invoke-MigrateTool {
    param([string]$ConfigPath)
    $pwshExe = (Get-Process -Id $PID).Path
    if (-not $pwshExe) { $pwshExe = 'pwsh' }
    $out = & $pwshExe -NoProfile -File $script:MigrateTool -ConfigPath $ConfigPath 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = ($out -join "`n") }
}

function New-TempConfig {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes a throwaway temp config file, removed in AfterAll/finally; not user-facing state.')]
    [CmdletBinding()]
    param([string]$Content)
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ("yrn-naming-" + [guid]::NewGuid().ToString('N') + ".yml")
    Set-Content -LiteralPath $p -Value $Content -Encoding utf8NoBOM
    return $p
}

}

Describe 'Test-RetiredConfigKeyLine (whole-path, case-sensitive)' {
    It 'matches a retired key at its own path' {
        Assert-True (Test-RetiredConfigKeyLine -Text $script:OldConfig -DottedPath 'statusService.isEnabled') 'nested retired key'
        Assert-True (Test-RetiredConfigKeyLine -Text $script:OldConfig -DottedPath 'testCycle.stepTimeoutMinutes') 'duration key'
    }
    It 'does not confuse a same-named leaf under a different parent' {
        # pool.enabled and guestQuarantine.enabled are current keys and must not
        # read as statusService.enabled / configService.enabled.
        Assert-True  (Test-RetiredConfigKeyLine -Text $script:OldConfig -DottedPath 'pool.enabled') 'pool.enabled really is there'
        Assert-False (Test-RetiredConfigKeyLine -Text $script:OldConfig -DottedPath 'statusService.enabled') 'the new form is NOT present'
        Assert-False (Test-RetiredConfigKeyLine -Text $script:OldConfig -DottedPath 'configService.enabled') 'the new form is NOT present'
    }
    It 'is case-sensitive, which is what makes an acronym-only rename detectable' {
        Assert-True  (Test-RetiredConfigKeyLine -Text $script:OldConfig -DottedPath 'vmStart.cachingProxyIP') 'retired casing found'
        Assert-False (Test-RetiredConfigKeyLine -Text $script:OldConfig -DottedPath 'vmStart.cachingProxyIp') 'current casing absent'
    }
    It 'returns false for an empty document' {
        Assert-False (Test-RetiredConfigKeyLine -Text '' -DottedPath 'testCycle.stepTimeoutMinutes') 'empty text'
    }
}

Describe 'Get-RetiredConfigKeyPresent' {
    It 'reports every retired key with its replacement and conversion factor' {
        $found = @(Get-RetiredConfigKeyPresent -Text $script:OldConfig)
        Assert-Equal -Expected 13 -Actual $found.Count -Because 'every retired key in the fixture'
        $step = $found | Where-Object { $_.Old -eq 'testCycle.stepTimeoutMinutes' }
        Assert-Equal -Expected 'testCycle.stepTimeoutSeconds' -Actual $step.New -Because 'replacement named'
        Assert-Equal -Expected 60 -Actual $step.Factor -Because 'minutes -> seconds'
        $nested = $found | Where-Object { $_.Old -eq 'testCycle.autoRemediationEnabled' }
        Assert-Equal -Expected 'testCycle.autoRemediation.enabled' -Actual $nested.New -Because 'flat key moves into the block'
    }
    It 'reports nothing for a config already in the current form' {
        $current = "statusService:`n  enabled: true`ntestCycle:`n  stepTimeoutSeconds: 2700`n"
        Assert-Equal -Expected 0 -Actual (@(Get-RetiredConfigKeyPresent -Text $current)).Count -Because 'nothing retired'
    }
}

Describe 'Update-TestConfigNaming.ps1 (converts, then no-ops)' {
    BeforeAll {
        $script:Cfg = New-TempConfig $script:OldConfig
        $script:Run1 = Invoke-MigrateTool -ConfigPath $script:Cfg
        $script:Exit1 = $script:Run1.ExitCode
        $script:Doc  = Get-Content -Raw -LiteralPath $script:Cfg
    }
    AfterAll {
        Remove-Item -LiteralPath $script:Cfg, "$($script:Cfg).pre-renaming" -Force -ErrorAction SilentlyContinue
    }

    It 'exits clean and leaves no retired key behind' {
        Assert-Equal -Expected 0 -Actual $script:Exit1 -Because 'conversion succeeded'
        Assert-Equal -Expected 0 -Actual (@(Get-RetiredConfigKeyPresent -Text $script:Doc)).Count -Because 'all keys converted'
    }
    It 'converts the values whose unit changed, as integers' {
        Assert-True ($script:Doc -match '(?m)^\s+stepTimeoutSeconds:\s*2700\s*$') "45 minutes -> 2700 seconds; got: $script:Doc"
        Assert-True ($script:Doc -match '(?m)^\s+refreshSeconds:\s*604800\s*$')   '168 hours -> 604800 seconds'
    }
    It 'moves the flat auto-remediation keys into the nested block' {
        Assert-True (Test-RetiredConfigKeyLine -Text $script:Doc -DottedPath 'testCycle.autoRemediation.enabled') 'nested enabled'
        Assert-True (Test-RetiredConfigKeyLine -Text $script:Doc -DottedPath 'testCycle.autoRemediation.maxAttemptsPerCycle') 'nested cap'
        Assert-True ($script:Doc -match '(?m)^\s+maxAttemptsPerCycle:\s*4\s*$') 'operator value carried'
    }
    It 'keeps operator values, including the secret' {
        Assert-True ($script:Doc -match '(?m)^\s+ghToken:\s*"?tok"?\s*$') 'token carried under the new key'
        Assert-True ($script:Doc -match '(?m)^\s+cachingProxyIp:\s*192\.168\.7\.42\s*$') 'acronym-cased key carries the address'
    }
    It 'leaves the previous file alongside, not in the .backup the runner owns' {
        Assert-True (Test-Path -LiteralPath "$($script:Cfg).pre-renaming") 'migration backup written'
        Assert-False (Test-Path -LiteralPath "$($script:Cfg).backup") 'the runner reconciliation backup is untouched'
    }
    It 'is a no-op on the second run' {
        $before = Get-Content -Raw -LiteralPath $script:Cfg
        $again = Invoke-MigrateTool -ConfigPath $script:Cfg
        Assert-Equal -Expected 0 -Actual $again.ExitCode -Because 'already-converted is success, not failure'
        Assert-Equal -Expected $before -Actual (Get-Content -Raw -LiteralPath $script:Cfg) -Because 'file untouched'
    }
}

Describe 'Update-TestConfigNaming.ps1 (refuses to guess)' {
    It 'renames the pool URL key without rewriting an operator supplied URL' {
        $cfg = New-TempConfig "pool:`n  intentGitUrl: https://example.invalid/custom/pool-intent.git`n"
        try {
            (Invoke-MigrateTool -ConfigPath $cfg).ExitCode | Should -Be 0
            $doc = Get-Content -Raw -LiteralPath $cfg | ConvertFrom-Yaml
            $doc.pool.configurationGitUrl | Should -Be 'https://example.invalid/custom/pool-intent.git'
            $doc.pool.ContainsKey('intentGitUrl') | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $cfg, "$cfg.pre-renaming" -Force -ErrorAction SilentlyContinue
        }
    }

    It 'stops when a key is present in BOTH the retired and the current form' {
        $both = "statusService:`n  isEnabled: true`n  enabled: false`n"
        $cfg  = New-TempConfig $both
        try {
            # Compare against what landed on disk, not the here-string: Set-Content
            # appends its own line terminator.
            $onDisk = Get-Content -Raw -LiteralPath $cfg
            $run = Invoke-MigrateTool -ConfigPath $cfg
            Assert-Equal -Expected 1 -Actual $run.ExitCode -Because 'ambiguous input is an operator decision'
            Assert-Equal -Expected $onDisk -Actual (Get-Content -Raw -LiteralPath $cfg) -Because 'nothing rewritten'
            Assert-False (Test-Path -LiteralPath "$cfg.pre-renaming") 'no backup taken when nothing was written'
        } finally {
            # The backup too: a regression that does write one fails the assert
            # above, and must not then leave it behind.
            Remove-Item -LiteralPath $cfg, "$cfg.pre-renaming" -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'strict local key migration preparation' {
    BeforeAll { Import-Module powershell-yaml -ErrorAction Stop }

    It 'restores a blank canonical value and leaves the original config untouched' {
        $inputConfig = [ordered]@{ pool = [ordered]@{ intentGitUrl = 'https://example.invalid/Original.git'; configurationGitUrl = ' ' } }
        $result = ConvertTo-ConfigNamingMigration -Config $inputConfig
        $result.Config.pool.configurationGitUrl | Should -BeExactly 'https://example.invalid/Original.git'
        $result.Config.pool.Contains('intentGitUrl') | Should -BeFalse
        $inputConfig.pool.configurationGitUrl | Should -BeExactly ' '
        $inputConfig.pool.intentGitUrl | Should -BeExactly 'https://example.invalid/Original.git'
    }

    It 'accepts duplicate values after unit conversion and converts a parked duration once' {
        $config = [ordered]@{ testCycle = [ordered]@{ stepTimeoutMinutes = 45; stepTimeoutSeconds = 2700 } }
        $first = ConvertTo-ConfigNamingMigration -Config $config -ObsoleteEntry ([ordered]@{ 'vmImage.refreshHours' = '1.5' })
        $first.Config.testCycle.stepTimeoutSeconds | Should -Be 2700
        $first.Config.vmImage.refreshSeconds | Should -Be 5400
        $first.Config.testCycle.Contains('stepTimeoutMinutes') | Should -BeFalse
        $first.Obsolete.Count | Should -Be 0
        (ConvertTo-ConfigNamingMigration -Config $first.Config -ObsoleteEntry $first.Obsolete).Changes.Count | Should -Be 0
    }

    It 'preserves false and zero as meaningful canonical values rather than empty defaults' {
        $boolean = [ordered]@{ statusService = [ordered]@{ isEnabled = $true; enabled = $false } }
        { ConvertTo-ConfigNamingMigration -Config $boolean } | Should -Throw '*conflict*'
        $duration = [ordered]@{ testCycle = [ordered]@{ stepTimeoutMinutes = 45; stepTimeoutSeconds = 0 } }
        { ConvertTo-ConfigNamingMigration -Config $duration } | Should -Throw '*conflict*'
        $boolean.statusService.enabled | Should -BeFalse
        $duration.testCycle.stepTimeoutSeconds | Should -Be 0
    }

    It 'preserves a meaningful canonical value when the retired copy is empty' {
        $config = [ordered]@{ pool = [ordered]@{ intentGitUrl = ''; configurationGitUrl = 'https://example.invalid/current.git' } }
        (ConvertTo-ConfigNamingMigration -Config $config).Config.pool.configurationGitUrl | Should -Be 'https://example.invalid/current.git'
    }

    It 'migrates exact acronym casing without disturbing a current key on a repeated pass' {
        $config = [ordered]@{ vmStart = [ordered]@{ cachingProxyIP = '192.0.2.42' } }
        $first = ConvertTo-ConfigNamingMigration -Config $config
        @($first.Config.vmStart.Keys)[0] | Should -BeExactly 'cachingProxyIp'
        $first.Config.vmStart.cachingProxyIp | Should -Be '192.0.2.42'
        (ConvertTo-ConfigNamingMigration -Config $first.Config).Changes.Count | Should -Be 0
    }

    It 'rejects a blocked destination without partially migrating the caller config' {
        $config = [ordered]@{
            pool = [ordered]@{ intentGitUrl = 'https://example.invalid/keep.git' }
            testCycle = [ordered]@{ autoRemediationEnabled = $true; autoRemediation = 'invalid scalar' }
        }
        { ConvertTo-ConfigNamingMigration -Config $config } | Should -Throw '*scalar blocks*'
        $config.pool.intentGitUrl | Should -Be 'https://example.invalid/keep.git'
        $config.pool.Contains('configurationGitUrl') | Should -BeFalse
        $config.testCycle.autoRemediationEnabled | Should -BeTrue
    }

    It 'rejects an invalid duration without silently moving it into seconds' {
        $config = [ordered]@{ testCycle = [ordered]@{ stepTimeoutMinutes = 'not a number' } }
        { ConvertTo-ConfigNamingMigration -Config $config } | Should -Throw '*numeric duration*'
        $config.testCycle.stepTimeoutMinutes | Should -Be 'not a number'
    }

    It 'rejects a parked YAML collection rather than treating it as a scalar URL' {
        $parked = [ordered]@{ 'pool.intentGitUrl' = '[one, two]' }
        { ConvertTo-ConfigNamingMigration -Config ([ordered]@{}) -ObsoleteEntry $parked } | Should -Throw '*valid YAML scalar*'
        $parked.Contains('pool.intentGitUrl') | Should -BeTrue
    }
}

Describe 'naming tool recovery of an already reconciled configuration' {
    It 'recovers parked registered values, preserves unrelated evidence, and then no-ops' {
        $cfg = New-TempConfig "pool:`n  enabled: true`n  configurationGitUrl: ''`n# --- Obsolete keys ---`n#   pool.intentGitUrl: https://Example.invalid/Custom/pool-intent.git`n#   unregistered.savedPath: /mnt/keep-me`n"
        try {
            $inputText = [IO.File]::ReadAllText($cfg)
            (Invoke-MigrateTool -ConfigPath $cfg).ExitCode | Should -Be 0
            $firstText = [IO.File]::ReadAllText($cfg)
            $doc = ConvertFrom-Yaml -Yaml $firstText -Ordered
            $doc.pool.enabled | Should -BeTrue
            $doc.pool.configurationGitUrl | Should -BeExactly 'https://Example.invalid/Custom/pool-intent.git'
            $firstText | Should -Match '#   unregistered.savedPath: /mnt/keep-me'
            $firstText | Should -Not -Match '#   pool.intentGitUrl:'
            [IO.File]::ReadAllText("$cfg.pre-renaming") | Should -BeExactly $inputText
            (Invoke-MigrateTool -ConfigPath $cfg).ExitCode | Should -Be 0
            [IO.File]::ReadAllText($cfg) | Should -BeExactly $firstText
        } finally { Remove-Item -LiteralPath $cfg, "$cfg.pre-renaming" -Force -ErrorAction SilentlyContinue }
    }

    It 'leaves conflicting parked values untouched with no migration backup' {
        $cfg = New-TempConfig "pool:`n  configurationGitUrl: https://example.invalid/current.git`n# --- Obsolete keys ---`n#   pool.intentGitUrl: https://example.invalid/other.git`n"
        try {
            $inputText = [IO.File]::ReadAllText($cfg)
            (Invoke-MigrateTool -ConfigPath $cfg).ExitCode | Should -Be 1
            [IO.File]::ReadAllText($cfg) | Should -BeExactly $inputText
            Test-Path "$cfg.pre-renaming" | Should -BeFalse
        } finally { Remove-Item -LiteralPath $cfg, "$cfg.pre-renaming" -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'naming tool preservation of YAML scalar content' {
    It 'preserves multiline credentials while renaming and retaining parked evidence' {
        $cfg = New-TempConfig "repositories:`n  GH_TOKEN: |`n    line-one`n    line-two`n# --- Obsolete keys ---`n#   unregistered.keep: evidence`n"
        try {
            $before = Get-Content -Raw $cfg | ConvertFrom-Yaml -Ordered
            (Invoke-MigrateTool -ConfigPath $cfg).ExitCode | Should -Be 0
            $after = Get-Content -Raw $cfg | ConvertFrom-Yaml -Ordered
            $after.repositories.ghToken | Should -BeExactly $before.repositories.GH_TOKEN
            [IO.File]::ReadAllText($cfg) | Should -Match '#   unregistered.keep: evidence'
        } finally { Remove-Item -LiteralPath $cfg, "$cfg.pre-renaming" -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'validator reconciliation before retired-key validation' {
    BeforeAll {
        Import-Module (Join-Path $here 'Test.ConfigSync.psm1') -DisableNameChecking
        $script:ValidatorNamingRoot = New-YurunaTestTempDir -Prefix 'yrn-validator-naming'
        $script:ValidatorNamingHarness = Join-Path $script:ValidatorNamingRoot 'gate-sections.ps1'
        $script:ValidatorNamingModules = $here
        $script:ValidatorNamingTemplate = Join-Path $repoRoot 'test/test.config.yml.template'
        $production = [IO.File]::ReadAllText((Join-Path $repoRoot 'test/Test-Config.ps1'))
        $start = $production.IndexOf('# --- REGION: Section 2a:')
        $end = $production.IndexOf('# --- REGION: Section 3:')
        if ($start -lt 0 -or $end -le $start) { throw 'Validator configuration section boundaries are missing.' }
        $header = @'
param([string]$ConfigPath, [string]$TemplatePath, [string]$ReportPath, [string]$ModulesDir)
$ErrorActionPreference = 'Stop'
$script:ModulesDir = $ModulesDir
Import-Module powershell-yaml -DisableNameChecking
Import-Module (Join-Path $ModulesDir '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Import-Module (Join-Path $ModulesDir 'Test.Output.psm1') -Global -DisableNameChecking
Import-Module (Join-Path $ModulesDir 'Test.Config.psm1') -Global -DisableNameChecking
Initialize-OutputState
$Config = Read-TestConfig -Path $ConfigPath -ThrowOnError
$ApplyConfigMigration = $false
$OnConfigSchemaDrift = 'Fail'
'@
        $footer = @'
$state = Get-OutputState
$report = @{ failCount = $state.FailCount; failures = $state.Failures; configuredUrl = $Config.pool.configurationGitUrl }
[IO.File]::WriteAllText($ReportPath, ($report | ConvertTo-Json -Depth 10))
if ($state.FailCount -gt 0) { exit 1 }
exit 0
'@
        # Exercise the production blocks in their actual order in a fresh child;
        # host provisioning and network validation are outside these boundaries.
        [IO.File]::WriteAllText($script:ValidatorNamingHarness, $header + "`n" + $production.Substring($start, $end - $start) + "`n" + $footer)
        function Invoke-ValidatorNamingGate {
            param([string]$ConfigPath)
            $reportPath = "$ConfigPath.gate-report.json"
            $output = & ([Environment]::ProcessPath) -NoProfile -File $script:ValidatorNamingHarness `
                -ConfigPath $ConfigPath -TemplatePath $script:ValidatorNamingTemplate `
                -ReportPath $reportPath -ModulesDir $script:ValidatorNamingModules 2>&1
            $exitCode = $LASTEXITCODE
            $report = if (Test-Path -LiteralPath $reportPath) { Get-Content -Raw $reportPath | ConvertFrom-Json -AsHashtable } else { $null }
            return @{ ExitCode = $exitCode; Output = ($output -join "`n"); Report = $report }
        }
    }
    AfterAll { Remove-Item -LiteralPath $script:ValidatorNamingRoot -Recurse -Force -ErrorAction SilentlyContinue }

    It 'accepts an active retired pool URL on the first gate after successful migration' {
        $cfg = Join-Path $script:ValidatorNamingRoot 'active-old.yml'
        $templateText = [IO.File]::ReadAllText($script:ValidatorNamingTemplate)
        $oldText = $templateText -creplace 'configurationGitUrl:', 'intentGitUrl:'
        $previous = ConvertFrom-Yaml -Yaml $oldText -Ordered
        $previous.pool.enabled = $true
        $previous.pool.intentGitUrl = 'https://Example.invalid/Operator/pool-intent.git'
        $inputText = ConvertTo-DocumentedConfigYaml -TemplateText $oldText -Config $previous
        [IO.File]::WriteAllText($cfg, $inputText)

        $first = Invoke-ValidatorNamingGate -ConfigPath $cfg
        $first.ExitCode | Should -Be 0 -Because $first.Output
        $first.Report.failCount | Should -Be 0
        $first.Report.configuredUrl | Should -BeExactly 'https://Example.invalid/Operator/pool-intent.git'
        [IO.File]::ReadAllText("$cfg.pre-renaming") | Should -BeExactly $inputText
        $landed = [IO.File]::ReadAllText($cfg)
        (Invoke-ValidatorNamingGate -ConfigPath $cfg).ExitCode | Should -Be 0
        [IO.File]::ReadAllText($cfg) | Should -BeExactly $landed
    }

    It 'accepts a repaired parked pool URL on the first gate' {
        $cfg = Join-Path $script:ValidatorNamingRoot 'parked-old.yml'
        $templateText = [IO.File]::ReadAllText($script:ValidatorNamingTemplate)
        $current = ConvertFrom-Yaml -Yaml $templateText -Ordered
        $current.pool.enabled = $true
        $current.pool.configurationGitUrl = ''
        $inputText = ConvertTo-DocumentedConfigYaml -TemplateText $templateText -Config $current `
            -ObsoleteEntry ([ordered]@{ 'pool.intentGitUrl' = 'https://Example.invalid/Original/pool-intent.git' })
        [IO.File]::WriteAllText($cfg, $inputText)
        $first = Invoke-ValidatorNamingGate -ConfigPath $cfg
        $first.ExitCode | Should -Be 0 -Because $first.Output
        $first.Report.failCount | Should -Be 0
        $first.Report.configuredUrl | Should -BeExactly 'https://Example.invalid/Original/pool-intent.git'
        [IO.File]::ReadAllText("$cfg.pre-renaming") | Should -BeExactly $inputText
    }

    It 'fails conflicting active values without changing the file or creating a backup' {
        $cfg = Join-Path $script:ValidatorNamingRoot 'conflicting.yml'
        $templateText = [IO.File]::ReadAllText($script:ValidatorNamingTemplate)
        $current = ConvertFrom-Yaml -Yaml $templateText -Ordered
        $current.pool.enabled = $true
        $current.pool.configurationGitUrl = 'https://example.invalid/current.git'
        $inputText = ConvertTo-DocumentedConfigYaml -TemplateText $templateText -Config $current
        $inputText = $inputText -creplace '(?m)^(  configurationGitUrl:.*)$', "`$1`n  intentGitUrl: https://example.invalid/conflicting.git"
        [IO.File]::WriteAllText($cfg, $inputText)
        $result = Invoke-ValidatorNamingGate -ConfigPath $cfg
        $result.ExitCode | Should -Be 1 -Because $result.Output
        $result.Report.failCount | Should -BeGreaterThan 0
        ($result.Report.failures.Message -join ' ') | Should -Match 'conflict'
        [IO.File]::ReadAllText($cfg) | Should -BeExactly $inputText
        Test-Path "$cfg.pre-renaming" | Should -BeFalse
        Test-Path "$cfg.backup" | Should -BeFalse
    }
}
