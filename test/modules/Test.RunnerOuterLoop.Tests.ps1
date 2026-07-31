<#PSScriptInfo
.VERSION 2026.07.31
.GUID 428c1a6d-4b29-4e07-9d51-7a2c8e0b5f31
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner outer-loop pester
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
    Pester coverage for the per-pool testCycle override merge in Test.RunnerOuterLoop.psm1:
    Get-OuterPoolTestCycleOverride (pure extraction) and the override-WINS precedence in
    Get-OuterAutoRemediation / Get-OuterStepTimeoutSeconds (pool > test.config.yml > default).
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Config.psm1')          -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.RunnerOuterLoop.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.InnerSpawn.psm1')      -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.PoolSync.psm1')        -Force -DisableNameChecking -ErrorAction SilentlyContinue
# Loaded because the outer entry point loads it too: Get-OuterStatusBaseUrl
# resolves the status-service gate + port through it.
Import-Module (Join-Path $here 'Test.Prelude.psm1')         -Force -DisableNameChecking -ErrorAction SilentlyContinue
try { Import-Module powershell-yaml -Force -ErrorAction Stop } catch { Write-Warning 'powershell-yaml unavailable.' }

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-False { param($Condition, [string]$Because = '') if ($Condition) { throw "Expected false. $Because" } }

function New-TempConfig {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes a throwaway temp config file, removed in finally; not user-facing state.')]
    [CmdletBinding()]
    param([string]$Yaml)
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ("ol-" + [guid]::NewGuid().ToString('N') + '.yml')
    Set-Content -LiteralPath $p -Value $Yaml -Encoding utf8
    return $p
}

# Pure value fixtures belong at file scope, above the first Describe: a Describe body is
# evaluated during the discovery pass and everything it declares is torn down before the
# first It runs, so a path declared inside one reaches the assertion as $null. Fixtures
# that write temp files go in BeforeAll/AfterAll instead (see below), which run in the
# run phase and so are still standing when the It executes.
$InnerScriptPath = 'C:\repo\test\modules\Invoke-TestRunnerInnerLoop.ps1'

Describe 'Test-OuterNoStatusServiceForwarded (embedded -NoStatusService detection)' {
    It 'is TRUE when -NoStatusService is forwarded (real New-InnerRunnerArgList shape)' {
        $al = New-InnerRunnerArgList -ScriptPath $InnerScriptPath -Parameters ([ordered]@{ ConfigPath = 'C:\x.yml'; NoStatusService = ([switch]$true); HostType = 'host.windows.hyper-v' })
        Assert-True (Test-OuterNoStatusServiceForwarded -ArgList $al) 'the embedded -NoStatusService token in the combined -Command element is detected'
    }
    It 'is FALSE when -NoStatusService is NOT forwarded' {
        $al = New-InnerRunnerArgList -ScriptPath $InnerScriptPath -Parameters ([ordered]@{ ConfigPath = 'C:\x.yml'; HostType = 'host.windows.hyper-v' })
        Assert-False (Test-OuterNoStatusServiceForwarded -ArgList $al) 'no -NoStatusService forwarded'
    }
    It 'does not false-match a longer -NoStatusServiceFoo token' {
        Assert-False (Test-OuterNoStatusServiceForwarded -ArgList @('-NoLogo', '-Command', "& 'x' -NoStatusServiceFoo 'bar'")) 'whole-token match only'
    }
    It 'is FALSE for null or empty ArgList' {
        Assert-False (Test-OuterNoStatusServiceForwarded -ArgList $null) 'null'
        Assert-False (Test-OuterNoStatusServiceForwarded -ArgList @())   'empty'
    }
}

Describe 'Get-OuterRemoteSha (bounded ls-remote parsing)' {
    It 'parses the SHA from the ls-remote line returned by the bounded runner' {
        Mock -ModuleName Test.RunnerOuterLoop Invoke-PoolSyncGitCapture { @{ ExitCode = 0; StdOut = "abc123def4567890`tHEAD`n"; StdErr = '' } }
        Assert-Equal 'abc123def4567890' (Get-OuterRemoteSha -RemoteUrl 'https://example/repo.git')
    }
    It 'returns $null on a non-zero exit (timeout/failure/no-git)' {
        Mock -ModuleName Test.RunnerOuterLoop Invoke-PoolSyncGitCapture { @{ ExitCode = 124; StdOut = ''; StdErr = '' } }
        Assert-Equal $null (Get-OuterRemoteSha -RemoteUrl 'https://example/repo.git')
    }
    It 'returns $null for an empty remote URL without invoking git' {
        Mock -ModuleName Test.RunnerOuterLoop Invoke-PoolSyncGitCapture { throw 'ls-remote must not run for an empty URL' }
        Assert-Equal $null (Get-OuterRemoteSha -RemoteUrl '')
    }
}

Describe 'Invoke-OuterNetworkGit (bounded, credential-chained runner)' {
    # Execution must stay on Invoke-PoolSyncGitCapture (wall-clock cap +
    # process-tree kill), whatever credential sources are loaded -- these pin
    # that, plus the immediate surfacing of credential-independent failures.
    It 'returns the bounded runner result with a combined Output' {
        Mock -ModuleName Test.RunnerOuterLoop Invoke-PoolSyncGitCapture { @{ ExitCode = 0; StdOut = "ok`n"; StdErr = '' } }
        $r = Invoke-OuterNetworkGit -ArgumentList @('fetch')
        Assert-Equal -Expected 0 -Actual $r.ExitCode -Because 'the bounded runner exit code is surfaced'
        Assert-Equal -Expected 'ok' -Actual $r.Output -Because 'StdOut+StdErr are combined and trimmed into Output'
    }
    It 'surfaces a credential-independent failure (timeout) from a single bounded run' {
        Mock -ModuleName Test.RunnerOuterLoop Invoke-PoolSyncGitCapture { @{ ExitCode = 124; StdOut = ''; StdErr = '' } }
        $r = Invoke-OuterNetworkGit -ArgumentList @('fetch') -TimeoutSeconds 5
        Assert-Equal -Expected 124 -Actual $r.ExitCode -Because 'the timeout exit code is surfaced as-is'
        Assert-MockCalled -ModuleName Test.RunnerOuterLoop Invoke-PoolSyncGitCapture -Exactly -Times 1 -Scope It
    }
}

Describe 'Get-OuterPoolTestCycleOverride (pure extraction)' {
    It 'returns an empty map for null / no-config / no-testCycle pools' {
        Assert-Equal -Expected 0 -Actual (Get-OuterPoolTestCycleOverride -Pool $null).Count -Because 'null -> empty'
        Assert-Equal -Expected 0 -Actual (Get-OuterPoolTestCycleOverride -Pool ([ordered]@{ poolId = 'lab' })).Count -Because 'no config -> empty'
        Assert-Equal -Expected 0 -Actual (Get-OuterPoolTestCycleOverride -Pool ([ordered]@{ config = [ordered]@{} })).Count -Because 'no testCycle -> empty'
    }
    It 'returns the testCycle map when present' {
        $pool = [ordered]@{ config = [ordered]@{ testCycle = [ordered]@{ autoRemediation = [ordered]@{ enabled = $true }; stepTimeoutSeconds = 12 } } }
        $tc = Get-OuterPoolTestCycleOverride -Pool $pool
        Assert-True  $tc['autoRemediation']['enabled'] 'nested block carried'
        Assert-Equal -Expected 12 -Actual $tc['stepTimeoutSeconds'] -Because 'value carried'
    }
}

Describe 'Get-OuterAutoRemediation (pool override WINS over config > default)' {
    # As a try/finally around the It blocks, these temp configs were written AND deleted
    # during the discovery pass, so every It below then read a config path that no longer
    # existed -- the override precedence would silently resolve against defaults instead of
    # the authored file. BeforeAll/AfterAll run in the run phase, which keeps them alive.
    BeforeAll {
        $script:CfgRemediationOn  = New-TempConfig "testCycle:`n  autoRemediation:`n    enabled: true`n    maxAttemptsPerCycle: 4`n"
        $script:CfgRemediationOff = New-TempConfig "testCycle:`n  autoRemediation:`n    enabled: false`n"
    }
    AfterAll { Remove-Item -LiteralPath $script:CfgRemediationOn, $script:CfgRemediationOff -Force -ErrorAction SilentlyContinue }

    It 'reads the local config when there is no pool override' {
        $r = Get-OuterAutoRemediation -ConfigPath $script:CfgRemediationOn
        Assert-True  $r.Enabled 'config enabled'
        Assert-Equal -Expected 4 -Actual $r.MaxAttempts -Because 'config maxAttempts'
    }
    It 'defaults to off / 2 when the config omits the keys' {
        $r = Get-OuterAutoRemediation -ConfigPath $script:CfgRemediationOff
        Assert-False $r.Enabled 'config off'
        Assert-Equal -Expected 2 -Actual $r.MaxAttempts -Because 'default maxAttempts'
    }
    It 'lets a pool override ENGAGE remediation over a config that is off' {
        $r = Get-OuterAutoRemediation -ConfigPath $script:CfgRemediationOff -PoolTestCycleOverride @{ autoRemediation = @{ enabled = $true; maxAttemptsPerCycle = 3 } }
        Assert-True  $r.Enabled 'override engages'
        Assert-Equal -Expected 3 -Actual $r.MaxAttempts -Because 'override maxAttempts wins'
    }
    It 'lets a pool override DISABLE remediation over a config that is on' {
        $r = Get-OuterAutoRemediation -ConfigPath $script:CfgRemediationOn -PoolTestCycleOverride @{ autoRemediation = @{ enabled = $false } }
        Assert-False $r.Enabled 'override disables'
    }
}

Describe 'Get-OuterCycleSummaryLine (per-cycle console line + shareable transcript link)' {
    BeforeAll {
        $script:SummaryDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ol-sum-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:SummaryDir -Force | Out-Null
        $script:SavedSummaryRuntime = $env:YURUNA_RUNTIME_DIR
        $script:SavedPublicUrl      = $env:YURUNA_STATUS_PUBLIC_URL
        $env:YURUNA_RUNTIME_DIR = $script:SummaryDir
        # Pinning the published base keeps the assertions off this machine's
        # live interface list; the address-discovery branch is covered below.
        $env:YURUNA_STATUS_PUBLIC_URL = 'http://10.1.2.3:8080/'
        $script:SummaryCfg = New-TempConfig "statusService:`n  port: 8080`n"
    }
    AfterAll {
        if ($null -eq $script:SavedSummaryRuntime) { Remove-Item Env:\YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue }
        else { $env:YURUNA_RUNTIME_DIR = $script:SavedSummaryRuntime }
        if ($null -eq $script:SavedPublicUrl) { Remove-Item Env:\YURUNA_STATUS_PUBLIC_URL -ErrorAction SilentlyContinue }
        else { $env:YURUNA_STATUS_PUBLIC_URL = $script:SavedPublicUrl }
        Remove-Item -LiteralPath $script:SummaryCfg -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:SummaryDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'names the cycle, the verdict, and the short /cycle/<number> link' {
        Set-Content -LiteralPath (Join-Path $script:SummaryDir 'status.json') -Encoding utf8 `
            -Value '{"cycle":4062,"cycleFolderUrl":"log/004062.2026-07-27.16-55-00.4287d16ff2c346a98ea90fd3a0c307da/"}'
        Assert-Equal -Expected 'Cycle 004062 - FAIL: http://10.1.2.3:8080/cycle/004062' `
            -Actual (Get-OuterCycleSummaryLine -ConfigPath $script:SummaryCfg -ExitCode 1) `
            -Because 'a non-zero inner exit reads FAIL'
        Assert-Equal -Expected 'Cycle 004062 - PASS: http://10.1.2.3:8080/cycle/004062' `
            -Actual (Get-OuterCycleSummaryLine -ConfigPath $script:SummaryCfg -ExitCode 0) `
            -Because 'exit 0 reads PASS'
    }
    It 'links by number alone, so a folder left mid-lifecycle still resolves' {
        # A killed cycle keeps its .incomplete folder name; the number in the
        # link is suffix-free, so the server resolves whatever is on disk.
        Set-Content -LiteralPath (Join-Path $script:SummaryDir 'status.json') -Encoding utf8 `
            -Value '{"cycle":4052,"cycleFolderUrl":"log/004052.2026-07-27.00-13-06.4287d16ff2c346a98ea90fd3a0c307da.incomplete/"}'
        Assert-Equal -Expected 'Cycle 004052 - FAIL: http://10.1.2.3:8080/cycle/004052' `
            -Actual (Get-OuterCycleSummaryLine -ConfigPath $script:SummaryCfg -ExitCode 1) `
            -Because 'the lifecycle suffix never reaches the link'
    }
    It 'still names the cycle when there is no server to link to' {
        $saved = $env:YURUNA_STATUS_PUBLIC_URL
        $cfgOff = New-TempConfig "statusService:`n  enabled: false`n"
        try {
            Remove-Item Env:\YURUNA_STATUS_PUBLIC_URL -ErrorAction SilentlyContinue
            Set-Content -LiteralPath (Join-Path $script:SummaryDir 'status.json') -Value '{"cycle":7}' -Encoding utf8
            Assert-Equal -Expected 'Cycle 000007 - PASS' `
                -Actual (Get-OuterCycleSummaryLine -ConfigPath $cfgOff -ExitCode 0) `
                -Because 'the verdict is still worth printing without a link'
        } finally {
            if ($null -ne $saved) { $env:YURUNA_STATUS_PUBLIC_URL = $saved }
            Remove-Item -LiteralPath $cfgOff -Force -ErrorAction SilentlyContinue
        }
    }
    It 'returns an empty string when the cycle left no status document' {
        Remove-Item -LiteralPath (Join-Path $script:SummaryDir 'status.json') -Force -ErrorAction SilentlyContinue
        Assert-Equal -Expected '' -Actual (Get-OuterCycleSummaryLine -ConfigPath $script:SummaryCfg -ExitCode 1) `
            -Because 'nothing to name means no line, not a broken one'
    }
    It 'returns an empty string when the status document is unparseable' {
        Set-Content -LiteralPath (Join-Path $script:SummaryDir 'status.json') -Value '{not json' -Encoding utf8
        Assert-Equal -Expected '' -Actual (Get-OuterCycleSummaryLine -ConfigPath $script:SummaryCfg -ExitCode 1) `
            -Because 'a half-written status document must not take the loop down'
    }
    It 'returns an empty string when the status document carries no cycle number' {
        Set-Content -LiteralPath (Join-Path $script:SummaryDir 'status.json') -Value '{"cycle":0}' -Encoding utf8
        Assert-Equal -Expected '' -Actual (Get-OuterCycleSummaryLine -ConfigPath $script:SummaryCfg -ExitCode 1) `
            -Because 'a one-shot run has no cycle to name'
    }
}

Describe 'Get-OuterStatusBaseUrl (never localhost)' {
    It 'honours an operator-published base URL and drops its trailing slash' {
        $saved = $env:YURUNA_STATUS_PUBLIC_URL
        try {
            $env:YURUNA_STATUS_PUBLIC_URL = 'https://dash.example/yuruna/'
            Assert-Equal -Expected 'https://dash.example/yuruna' `
                -Actual (Get-OuterStatusBaseUrl -ConfigPath 'nonexistent.yml') `
                -Because 'a reverse proxy is not discoverable from this process'
        } finally {
            if ($null -eq $saved) { Remove-Item Env:\YURUNA_STATUS_PUBLIC_URL -ErrorAction SilentlyContinue }
            else { $env:YURUNA_STATUS_PUBLIC_URL = $saved }
        }
    }
    It 'yields no base URL when the status service is gated off' {
        $saved = $env:YURUNA_STATUS_PUBLIC_URL
        $cfgOn = New-TempConfig "statusService:`n  enabled: true`n  port: 8080`n"
        $cfgOff = New-TempConfig "statusService:`n  enabled: false`n"
        try {
            Remove-Item Env:\YURUNA_STATUS_PUBLIC_URL -ErrorAction SilentlyContinue
            Assert-Equal -Expected '' -Actual (Get-OuterStatusBaseUrl -ConfigPath $cfgOff) `
                -Because 'statusService.enabled false means there is nothing to link to'
            $al = New-InnerRunnerArgList -ScriptPath $InnerScriptPath -Parameters ([ordered]@{ NoStatusService = ([switch]$true) })
            Assert-Equal -Expected '' -Actual (Get-OuterStatusBaseUrl -ConfigPath $cfgOn -ArgList $al) `
                -Because 'a forwarded -NoStatusService means no server was started'
        } finally {
            if ($null -ne $saved) { $env:YURUNA_STATUS_PUBLIC_URL = $saved }
            Remove-Item -LiteralPath $cfgOn, $cfgOff -Force -ErrorAction SilentlyContinue
        }
    }
    It 'discovers a routable address rather than loopback' {
        $saved = $env:YURUNA_STATUS_PUBLIC_URL
        try {
            Remove-Item Env:\YURUNA_STATUS_PUBLIC_URL -ErrorAction SilentlyContinue
            $url = Get-OuterStatusBaseUrl -ConfigPath 'nonexistent.yml'
            # A host with no default route legitimately yields '' -- what must
            # never happen is a link that resolves to the reader's own machine.
            Assert-False ($url -match 'localhost|127\.0\.0\.1') 'a shared link must not point at the reader'
            if ($url) { Assert-True ($url -match '^http://\d+\.\d+\.\d+\.\d+:\d+$') "shape was '$url'" }
        } finally {
            if ($null -ne $saved) { $env:YURUNA_STATUS_PUBLIC_URL = $saved }
        }
    }
}

Describe 'Invoke-RunnerOuterLoop failure pause (auto-remediation trigger is reachable)' {
    # The pause runs in the parent process; the per-cycle body runs in its own. Naming
    # one of the body's variables in the pause binds $null over a parameter default,
    # which throws inside the callee and leaves the gate below reading a null result --
    # the trigger then never fires and the only symptom is an error every poll tick.
    BeforeAll {
        $script:CfgAutoRem   = New-TempConfig "testCycle:`n  autoRemediation:`n    enabled: true`n"
        $script:PauseTempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ol-rt-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:PauseTempDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:PauseTempDir 'last_failure.json') `
            -Value '{"failureClass":"wait_timeout"}' -Encoding utf8
        # Both are joined unguarded on the pause path: the restart-flag probe reads
        # the runtime dir, Get-OuterLastFailureClass reads the log dir. Sandboxed so
        # the suite never touches the operator's live runtime.
        $script:SavedRuntimeDir = $env:YURUNA_RUNTIME_DIR
        $script:SavedLogDir     = $env:YURUNA_LOG_DIR
        $env:YURUNA_RUNTIME_DIR = $script:PauseTempDir
        $env:YURUNA_LOG_DIR     = $script:PauseTempDir
    }
    AfterAll {
        if ($null -eq $script:SavedRuntimeDir) { Remove-Item Env:\YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue }
        else { $env:YURUNA_RUNTIME_DIR = $script:SavedRuntimeDir }
        if ($null -eq $script:SavedLogDir) { Remove-Item Env:\YURUNA_LOG_DIR -ErrorAction SilentlyContinue }
        else { $env:YURUNA_LOG_DIR = $script:SavedLogDir }
        Remove-Item -LiteralPath $script:CfgAutoRem -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:PauseTempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'ends the pause early on a transient failure class when the config ENGAGES remediation' {
        Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog                { }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterCommitSha            { 'sha0' }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterProjectUrl           { '' }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterConfigMtime          { $null }
        Mock -ModuleName Test.RunnerOuterLoop Test-OuterNewCommitsAvailable { $false }
        # First cycle fails, which drives the pause; the second ends the loop. The
        # marker rides on ShutdownState because that is the one hashtable shared by
        # reference between this test and the loop.
        Mock -ModuleName Test.RunnerOuterLoop Invoke-OuterCycleDispatch {
            if ($State.ShutdownState.ContainsKey('Paused')) {
                $State.ShutdownState['Requested'] = $true
                return [pscustomobject]@{ Outcome = 'completed'; ExitCode = 0 }
            }
            $State.ShutdownState['Paused'] = $true
            return [pscustomobject]@{ Outcome = 'completed'; ExitCode = 1 }
        }

        $spoken = @(Invoke-RunnerOuterLoop -State @{
            CycleScript               = ''
            RepoRoot                  = $here
            ConfigPath                = $script:CfgAutoRem
            InnerScript               = 'x'
            PwshExe                   = 'pwsh'
            ArgList                   = @()
            ForwardEnvSnapshot        = @{}
            ShutdownState             = @{ Requested = $false }
            NoGitPull                 = $true
            FailurePauseMaxSeconds    = 1
            FailureCommitPollSeconds  = 1
            OuterPullErrorSleepSeconds    = 1
            InnerSpawnErrorSleepSeconds   = 1
            StepTimeoutSecondsDefault = 1
            WatchdogPollSeconds       = 1
        } 3>$null) -join "`n"

        Assert-True ($spoken -match "auto-remediation: transient 'wait_timeout'") `
            'the gate read a real result, so the transient class ended the pause early'
    }
}

Describe 'Get-OuterStepTimeoutSeconds (pool override WINS over config > default)' {
    BeforeAll {
        $script:CfgTimeout     = New-TempConfig "testCycle:`n  stepTimeoutSeconds: 20`n"
        $script:CfgTimeoutBare = New-TempConfig "testCycle: {}`n"
    }
    AfterAll { Remove-Item -LiteralPath $script:CfgTimeout, $script:CfgTimeoutBare -Force -ErrorAction SilentlyContinue }

    It 'reads the config value when there is no override' {
        Assert-Equal -Expected 20 -Actual (Get-OuterStepTimeoutSeconds -ConfigPath $script:CfgTimeout -DefaultSeconds 90) -Because 'config value'
    }
    It 'falls back to the default when the config omits the key' {
        Assert-Equal -Expected 90 -Actual (Get-OuterStepTimeoutSeconds -ConfigPath $script:CfgTimeoutBare -DefaultSeconds 90) -Because 'default'
    }
    It 'lets a pool override win over both config and default' {
        Assert-Equal -Expected 7 -Actual (Get-OuterStepTimeoutSeconds -ConfigPath $script:CfgTimeout -DefaultSeconds 90 -PoolTestCycleOverride @{ stepTimeoutSeconds = 7 }) -Because 'override wins'
    }
    It 'ignores a non-positive override (keeps the config value)' {
        Assert-Equal -Expected 20 -Actual (Get-OuterStepTimeoutSeconds -ConfigPath $script:CfgTimeout -DefaultSeconds 90 -PoolTestCycleOverride @{ stepTimeoutSeconds = 0 }) -Because 'zero override ignored'
    }
}
