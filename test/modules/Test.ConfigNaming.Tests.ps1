<#PSScriptInfo
.VERSION 2026.08.03
.GUID 42c1d5e8-7a30-4b96-8f21-0d4e6a9b2c58
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

    The throw-based Assert-* helpers are defined at script scope and referenced from
    It blocks, so this runs under Pester 4.10.1 (Pester 5's scope split hides
    top-level helpers from It blocks).
#>

$here       = Split-Path -Parent $PSCommandPath
$repoRoot   = Split-Path -Parent (Split-Path -Parent $here)
$modulePath = Join-Path $here 'Test.ConfigNaming.psm1'
$script:MigrateTool = Join-Path $repoRoot 'tools/Update-TestConfigNaming.ps1'

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-False { param($Condition, [string]$Because='') if ($Condition) { throw "Expected false. $Because" } }

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
            Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue
        }
    }
}
