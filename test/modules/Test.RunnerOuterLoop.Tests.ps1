<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42305b75-dbdd-448e-8c59-ffaf93235629
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
    Also the host-refresh gate at the dispatch and cycle sites, the refresh
    outcomes of the loop, and its automatic-refresh call sites.
#>

# The loop resolves Set-RunnerState and the automatic-refresh trigger commands
# from the global command table at call time (Get-Command-guarded), so their
# stubs, and the lists those stubs record into, must live in the global scope.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The global command table is the resolution contract under test: the loop finds Set-RunnerState and the trigger commands there, so the recording stubs and their lists straddle that scope.')]
param()

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Config.psm1')          -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.RunnerOuterLoop.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.InnerSpawn.psm1')      -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.PoolSync.psm1')        -Force -DisableNameChecking -ErrorAction SilentlyContinue
# Loaded because the outer entry point loads it too: Get-OuterStatusBaseUrl
# resolves the status-service gate + port through it.
Import-Module (Join-Path $here 'Test.Prelude.psm1')         -Force -DisableNameChecking -ErrorAction SilentlyContinue
try { Import-Module powershell-yaml -Force -ErrorAction Stop } catch { Write-Warning 'powershell-yaml unavailable.' }

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

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
$script:InnerScriptPath = 'C:\repo\test\modules\Invoke-TestRunnerInnerLoop.ps1'

}

Describe 'Test-OuterNoStatusServiceForwarded (embedded -NoStatusService detection)' {
    It 'is TRUE when -NoStatusService is forwarded (real New-InnerRunnerArgList shape)' {
        $al = New-InnerRunnerArgList -ScriptPath $script:InnerScriptPath -Parameters ([ordered]@{ ConfigPath = 'C:\x.yml'; NoStatusService = ([switch]$true); HostType = 'host.windows.hyper-v' })
        Assert-True (Test-OuterNoStatusServiceForwarded -ArgList $al) 'the embedded -NoStatusService token in the combined -Command element is detected'
    }
    It 'is FALSE when -NoStatusService is NOT forwarded' {
        $al = New-InnerRunnerArgList -ScriptPath $script:InnerScriptPath -Parameters ([ordered]@{ ConfigPath = 'C:\x.yml'; HostType = 'host.windows.hyper-v' })
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
    It 'honors an operator-published base URL and drops its trailing slash' {
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
            $al = New-InnerRunnerArgList -ScriptPath $script:InnerScriptPath -Parameters ([ordered]@{ NoStatusService = ([switch]$true) })
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
        # The automatic host-refresh calls read and write per-user private
        # state; this case is about the failure pause, so they stay off.
        Mock -ModuleName Test.RunnerOuterLoop Import-OuterRefreshTriggerModule { $false }
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

Describe 'Refresh gate at the cycle dispatch (mocked spawn)' {
    BeforeAll {
        Import-Module (Join-Path $here '../../automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
        Import-Module (Join-Path $here 'Test.StateFile.psm1') -Force -Global -DisableNameChecking
    }
    BeforeEach {
        $script:DispatchDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ol-dispatch-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:DispatchDir -Force | Out-Null
        $script:SavedRuntime = $env:YURUNA_RUNTIME_DIR
        $env:YURUNA_RUNTIME_DIR = $script:DispatchDir
        $script:CycleScriptPath = Join-Path $script:DispatchDir 'cycle.ps1'
        Set-Content -LiteralPath $script:CycleScriptPath -Value '# fixture' -Encoding utf8
        $script:Seen = @{}
        Mock -ModuleName Test.RunnerOuterLoop Start-Process {
            $script:Seen.Args = [string[]]$ArgumentList
            $script:Seen.Token = $env:YURUNA_REFRESH_HANDOFF_TOKEN
            $script:Seen.Preflight = $env:YURUNA_REFRESH_PREFLIGHT
            $script:Seen.Barrier = $env:YURUNA_REFRESH_BARRIER
            [pscustomobject]@{ Id = $PID; HasExited = $true; ExitCode = 0 }
        }
        Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog { }
    }
    AfterEach {
        if ($null -eq $script:SavedRuntime) { Remove-Item Env:YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue } else { $env:YURUNA_RUNTIME_DIR = $script:SavedRuntime }
        Remove-Item -LiteralPath $script:DispatchDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'spawns the preflight chain with its token in the child environment only, and clears it afterwards' {
        Mock -ModuleName Test.RunnerOuterLoop Test-YurunaRunnerHandoffToken { [pscustomobject]@{ Valid = $true; RequestId = 'r-1'; Purpose = 'new-outer'; Generation = 'g' } }
        $state = @{ CycleScript = $script:CycleScriptPath; PwshExe = 'pwsh'; ShutdownState = @{ Requested = $false }
            RefreshHandoff = @{ TokenId = ('a' * 32); RequestId = 'r-1'; Purpose = 'new-outer' } }
        $r = Invoke-OuterCycleDispatch -State $state -Cycle 4
        Assert-Equal -Expected 'preflight' -Actual $r.Refresh
        Assert-Equal -Expected ('a' * 32) -Actual $script:Seen.Token
        Assert-Equal -Expected '1' -Actual $script:Seen.Preflight
        Assert-True ([string]::IsNullOrEmpty($script:Seen.Barrier)) 'no barrier on the preflight'
        Assert-True ([string]::IsNullOrEmpty($env:YURUNA_REFRESH_HANDOFF_TOKEN)) 'the token does not outlive the spawn'
        Assert-True ([string]::IsNullOrEmpty($env:YURUNA_REFRESH_PREFLIGHT)) 'the preflight flag does not outlive the spawn'
        Assert-False (Test-Path -LiteralPath (Join-Path $script:DispatchDir 'runner.cycle.json')) 'the cycle record goes when the cycle exits'
        Assert-Equal -Expected $PID -Actual $r.Cycle.Pid -Because 'the spawned cycle identity is returned for the resident-outer check'
        Assert-Equal -Expected ('a' * 32) -Actual $r.Handoff.TokenId
        Assert-Equal -Expected 'new-outer' -Actual $r.Handoff.Purpose
    }
    It 'returns the purpose the gate validated, not the one the handoff record carries' {
        Mock -ModuleName Test.RunnerOuterLoop Test-YurunaRunnerHandoffToken { [pscustomobject]@{ Valid = $true; RequestId = 'r-6'; Purpose = 'resident-outer'; Generation = 'g' } }
        $state = @{ CycleScript = $script:CycleScriptPath; PwshExe = 'pwsh'; ShutdownState = @{ Requested = $false }
            RefreshHandoff = @{ tokenId = ('e' * 32) } }
        $r = Invoke-OuterCycleDispatch -State $state -Cycle 5
        Assert-Equal -Expected 'preflight' -Actual $r.Refresh
        Assert-Equal -Expected 'resident-outer' -Actual $r.Handoff.Purpose -Because 'a handoff record without a purpose still dispatches as the gate recorded it'
        Assert-Equal -Expected 'r-6' -Actual $r.Handoff.RequestId
    }
    It 'holds without spawning while the gate is closed, with or without a stale handoff' {
        Mock -ModuleName Test.RunnerOuterLoop Test-YurunaRunnerHandoffToken { [pscustomobject]@{ Valid = $false; Reason = 'not-handoff' } }
        Mock -ModuleName Test.RunnerOuterLoop Get-YurunaRefreshGateState { [pscustomobject]@{ State = 'closed'; SpawnAllowed = $false; RequestId = 'r-2'; Orphaned = $false; Reason = 'closed' } }
        foreach ($handoff in @($null, @{ TokenId = ('b' * 32); RequestId = 'r-2'; Purpose = 'new-outer' })) {
            $state = @{ CycleScript = $script:CycleScriptPath; PwshExe = 'pwsh'; ShutdownState = @{ Requested = $false }; RefreshHandoff = $handoff }
            $r = Invoke-OuterCycleDispatch -State $state -Cycle 1
            Assert-Equal -Expected 'refresh-gated' -Actual $r.Outcome
            Assert-Equal -Expected 'closed' -Actual $r.Gate.State
            Assert-Null $r.Handoff
        }
        Assert-MockCalled -CommandName Start-Process -ModuleName Test.RunnerOuterLoop -Times 0 -Exactly -Scope It
    }
    It 'turns a stale handoff into the barrier once the gate is open, and forwards the cycle generation' {
        Mock -ModuleName Test.RunnerOuterLoop Test-YurunaRunnerHandoffToken { [pscustomobject]@{ Valid = $false; Reason = 'not-handoff' } }
        Mock -ModuleName Test.RunnerOuterLoop Get-YurunaRefreshGateState { [pscustomobject]@{ State = 'open'; SpawnAllowed = $true; RequestId = 'r-3' } }
        $generation = ('c' * 32) + ':9'
        $state = @{ CycleScript = $script:CycleScriptPath; PwshExe = 'pwsh'; ShutdownState = @{ Requested = $false }
            RefreshHandoff = @{ TokenId = ('c' * 32); RequestId = 'r-3'; Purpose = 'new-outer' }; CycleGeneration = $generation }
        $r = Invoke-OuterCycleDispatch -State $state -Cycle 9
        Assert-Equal -Expected 'barrier' -Actual $r.Refresh
        Assert-Equal -Expected 'r-3' -Actual $script:Seen.Barrier
        Assert-Null $state.RefreshHandoff
        Assert-Equal -Expected 'r-3' -Actual $state.RefreshBarrierRequestId
        $i = [array]::IndexOf($script:Seen.Args, '-CycleGeneration')
        Assert-True ($i -ge 0 -and $script:Seen.Args[$i + 1] -eq $generation) 'the generation reaches the cycle process argv'
        Assert-Equal -Expected $generation -Actual $r.CycleGeneration
    }
}

Describe 'Invoke-RunnerOuterCycle at its refresh sites (in-process, stand-in inner)' {
    BeforeAll {
        Import-Module (Join-Path $here '../../automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
        Import-Module (Join-Path $here 'Test.StateFile.psm1') -Force -Global -DisableNameChecking
        Import-Module (Join-Path $here 'Test.RunnerWatchdog.psm1') -Force -Global -DisableNameChecking
        function New-CycleFixture {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: throwaway runtime and log directories with sentinel files.')]
            param([string]$InnerScript)
            $root = Join-Path ([System.IO.Path]::GetTempPath()) ('ol-site-' + [guid]::NewGuid().ToString('N'))
            $runtime = Join-Path $root 'runtime'; $log = Join-Path $root 'log'
            New-Item -ItemType Directory -Path $runtime, $log -Force | Out-Null
            foreach ($name in @('inner.pid', 'inner.start', 'break-active.json')) { Set-Content -LiteralPath (Join-Path $runtime $name) -Value 'x' -Encoding utf8 }
            Set-Content -LiteralPath (Join-Path $log 'last_failure.json') -Value '{}' -Encoding utf8
            $envFile = Join-Path $root 'inner-env.json'
            $inner = $InnerScript.Replace('ENVFILE', $envFile.Replace("'", "''")).Replace('RUNTIME', $runtime.Replace("'", "''"))
            $state = @{
                RepoRoot = $root; ConfigPath = (Join-Path $root 'missing.yml'); InnerScript = 'x'; PwshExe = [Environment]::ProcessPath
                ArgList = @('-NoProfile', '-NonInteractive', '-Command', $inner); ForwardEnvSnapshot = @{}; ShutdownState = @{ Requested = $false }
                NoGitPull = $false; FailurePauseMaxSeconds = 1; FailureCommitPollSeconds = 1; OuterPullErrorSleepSeconds = 1
                InnerSpawnErrorSleepSeconds = 1; StepTimeoutSecondsDefault = 60; WatchdogPollSeconds = 30
            }
            return @{ Root = $root; Runtime = $runtime; Log = $log; EnvFile = $envFile; State = $state }
        }
        $script:EnvInner = "[ordered]@{ preflight = `$env:YURUNA_REFRESH_PREFLIGHT; token = `$env:YURUNA_REFRESH_HANDOFF_TOKEN; generation = `$env:YURUNA_CYCLE_GENERATION; barrier = `$env:YURUNA_REFRESH_BARRIER } | ConvertTo-Json | Set-Content -LiteralPath 'ENVFILE'; exit 0"
    }
    BeforeEach {
        $script:SavedRuntime = $env:YURUNA_RUNTIME_DIR; $script:SavedLog = $env:YURUNA_LOG_DIR
        Mock -ModuleName Test.RunnerOuterLoop Start-Watchdog { [pscustomobject]@{ State = 'Running' } }
        Mock -ModuleName Test.RunnerOuterLoop Stop-Watchdog { }
        Mock -ModuleName Test.RunnerOuterLoop Invoke-OuterGitPull { $true }
        Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog { }
    }
    AfterEach {
        if ($null -eq $script:SavedRuntime) { Remove-Item Env:YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue } else { $env:YURUNA_RUNTIME_DIR = $script:SavedRuntime }
        if ($null -eq $script:SavedLog) { Remove-Item Env:YURUNA_LOG_DIR -ErrorAction SilentlyContinue } else { $env:YURUNA_LOG_DIR = $script:SavedLog }
    }

    It 'runs a preflight cycle: no pull, failure record and break marker kept, inner records wiped, token and generation handed to the inner' {
        $f = New-CycleFixture -InnerScript $script:EnvInner
        try {
            $env:YURUNA_RUNTIME_DIR = $f.Runtime; $env:YURUNA_LOG_DIR = $f.Log
            Mock -ModuleName Test.RunnerOuterLoop Get-YurunaRefreshGateState { [pscustomobject]@{ State = 'handoff'; SpawnAllowed = $false; PreflightAllowed = $true; RequestId = 'r' } }
            $f.State.RefreshPreflightTokenId = ('d' * 32); $f.State.RefreshPreflightRequested = $true
            $f.State.CycleGeneration = ('e' * 32) + ':2'
            $r = Invoke-RunnerOuterCycle -State $f.State -Cycle 2 | Select-Object -Last 1
            Assert-Equal -Expected 'refresh-preflight' -Actual $r.Outcome
            Assert-Equal -Expected 0 -Actual $r.ExitCode
            Assert-MockCalled -CommandName Invoke-OuterGitPull -ModuleName Test.RunnerOuterLoop -Times 0 -Exactly -Scope It
            Assert-True (Test-Path -LiteralPath (Join-Path $f.Log 'last_failure.json')) 'the last failure record is kept'
            Assert-True (Test-Path -LiteralPath (Join-Path $f.Runtime 'break-active.json')) 'the break marker is kept'
            Assert-False (Test-Path -LiteralPath (Join-Path $f.Runtime 'inner.pid')) 'inner.pid wiped'
            Assert-False (Test-Path -LiteralPath (Join-Path $f.Runtime 'inner.start')) 'inner.start wiped'
            $seen = Get-Content -LiteralPath $f.EnvFile -Raw | ConvertFrom-Json
            Assert-Equal -Expected '1' -Actual $seen.preflight
            Assert-Equal -Expected ('d' * 32) -Actual $seen.token
            Assert-Equal -Expected (('e' * 32) + ':2') -Actual $seen.generation
            Assert-True ([string]::IsNullOrEmpty($env:YURUNA_CYCLE_GENERATION)) 'cleared after the spawn'
        } finally { Remove-Item -LiteralPath $f.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'holds a cycle before the pull and changes nothing while the gate is closed' {
        $f = New-CycleFixture -InnerScript $script:EnvInner
        try {
            $env:YURUNA_RUNTIME_DIR = $f.Runtime; $env:YURUNA_LOG_DIR = $f.Log
            Mock -ModuleName Test.RunnerOuterLoop Get-YurunaRefreshGateState { [pscustomobject]@{ State = 'closed'; SpawnAllowed = $false; PreflightAllowed = $false } }
            $r = Invoke-RunnerOuterCycle -State $f.State -Cycle 3 | Select-Object -Last 1
            Assert-Equal -Expected 'refresh-gated' -Actual $r.Outcome
            Assert-MockCalled -CommandName Invoke-OuterGitPull -ModuleName Test.RunnerOuterLoop -Times 0 -Exactly -Scope It
            foreach ($name in @('inner.pid', 'inner.start', 'break-active.json')) {
                Assert-True (Test-Path -LiteralPath (Join-Path $f.Runtime $name)) "$name untouched"
            }
            Assert-True (Test-Path -LiteralPath (Join-Path $f.Log 'last_failure.json')) 'the failure record is untouched'
            Assert-False (Test-Path -LiteralPath $f.EnvFile) 'no inner ran'
        } finally { Remove-Item -LiteralPath $f.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'reports refresh-gated when its own inner was held at an inner site, and carries the barrier to the inner' {
        $gatedInner = "`$parent = (Get-Process -Id `$PID).Parent.Id; [ordered]@{ schemaVersion = 1; site = 'git-pull'; innerParentPid = `$parent; observedUtc = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path 'RUNTIME' 'runner.refresh-gated.json'); " + $script:EnvInner
        $f = New-CycleFixture -InnerScript $gatedInner
        try {
            $env:YURUNA_RUNTIME_DIR = $f.Runtime; $env:YURUNA_LOG_DIR = $f.Log
            Mock -ModuleName Test.RunnerOuterLoop Get-YurunaRefreshGateState { [pscustomobject]@{ State = 'open'; SpawnAllowed = $true; PreflightAllowed = $false } }
            $f.State.NoGitPull = $true
            $f.State.RefreshBarrierRequestId = 'r-9'
            $r = Invoke-RunnerOuterCycle -State $f.State -Cycle 5 | Select-Object -Last 1
            Assert-Equal -Expected 'refresh-gated' -Actual $r.Outcome
            Assert-False (Test-Path -LiteralPath (Join-Path $f.Runtime 'runner.refresh-gated.json')) 'the sidecar is consumed'
            Assert-Equal -Expected 'r-9' -Actual (Get-Content -LiteralPath $f.EnvFile -Raw | ConvertFrom-Json).barrier
            Assert-False (Test-Path -LiteralPath (Join-Path $f.Runtime 'break-active.json')) 'an ordinary cycle still clears a stale break marker'
        } finally { Remove-Item -LiteralPath $f.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Invoke-RunnerOuterLoop refresh outcomes and automatic-refresh call sites (mocked dispatch)' {
    BeforeAll {
        function New-LoopState {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: builds an in-memory State hashtable; no system state.')]
            param([hashtable]$Extra = @{})
            $state = @{
                CycleScript = ''; RepoRoot = $here; ConfigPath = (Join-Path $here 'missing.yml'); InnerScript = 'x'; PwshExe = 'pwsh'
                ArgList = @(); ForwardEnvSnapshot = @{}; ShutdownState = @{ Requested = $false }; NoGitPull = $true
                FailurePauseMaxSeconds = 1; FailureCommitPollSeconds = 1; OuterPullErrorSleepSeconds = 1; InnerSpawnErrorSleepSeconds = 1
                StepTimeoutSecondsDefault = 1; WatchdogPollSeconds = 1
            }
            foreach ($key in $Extra.Keys) { $state[$key] = $Extra[$key] }
            return $state
        }
    }
    BeforeEach {
        $script:LoopDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ol-loop-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:LoopDir -Force | Out-Null
        $script:SavedRuntime = $env:YURUNA_RUNTIME_DIR; $script:SavedLog = $env:YURUNA_LOG_DIR
        $env:YURUNA_RUNTIME_DIR = $script:LoopDir; $env:YURUNA_LOG_DIR = $script:LoopDir
        $script:Logged = [System.Collections.Generic.List[string]]::new()
        $script:Dispatches = [System.Collections.Generic.List[hashtable]]::new()
        $script:Outcomes = [System.Collections.Generic.Queue[object]]::new()
        Mock -ModuleName Test.RunnerOuterLoop Format-YurunaOperatorMessage { "KEY:$Key" }
        Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog { $script:Logged.Add($Message) }
        Mock -ModuleName Test.RunnerOuterLoop Wait-OuterInterruptible { $false }
        Mock -ModuleName Test.RunnerOuterLoop Import-OuterRefreshTriggerModule { $false }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterCommitSha { 'sha' }
        Mock -ModuleName Test.RunnerOuterLoop Update-RunnerCrashGating { [pscustomobject]@{ Updated = $false } }
        Mock -ModuleName Test.RunnerOuterLoop Update-RunnerFaultStatus { $true }
        Mock -ModuleName Test.RunnerOuterLoop Invoke-OuterCycleDispatch {
            $script:Dispatches.Add(@{ Generation = $State['CycleGeneration']; Barrier = $State['RefreshBarrierRequestId']; Handoff = $State['RefreshHandoff'] })
            $next = $script:Outcomes.Dequeue()
            if ($script:Outcomes.Count -eq 0) { $State.ShutdownState['Requested'] = $true }
            return $next
        }
        $global:__loopStates = [System.Collections.Generic.List[string]]::new()
        function global:Set-RunnerState { [CmdletBinding(SupportsShouldProcess)] param($To, $Reason) if ($PSCmdlet.ShouldProcess("$To ($Reason)")) { $global:__loopStates.Add($To) } }
    }
    AfterEach {
        if ($null -eq $script:SavedRuntime) { Remove-Item Env:YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue } else { $env:YURUNA_RUNTIME_DIR = $script:SavedRuntime }
        if ($null -eq $script:SavedLog) { Remove-Item Env:YURUNA_LOG_DIR -ErrorAction SilentlyContinue } else { $env:YURUNA_LOG_DIR = $script:SavedLog }
        Remove-Item -LiteralPath $script:LoopDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item function:global:Set-RunnerState, function:global:Update-HostRefreshAutoEvidence, function:global:Invoke-HostRefreshAutoDecision, `
            function:global:Stop-HostRefreshAutoQueuedRequest, function:global:Set-HostRefreshCallerAck, function:global:Resolve-StatusServiceStart -ErrorAction SilentlyContinue
        Remove-Variable __loopStates, __trigger -Scope Global -ErrorAction SilentlyContinue
    }

    It 'does not count a pre-spawn storage refusal as an inner crash' {
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'storage-full'; ExitCode = 1 })
        $null = Invoke-RunnerOuterLoop -State (New-LoopState) 3>$null 6>$null
        Assert-MockCalled -CommandName Update-RunnerCrashGating -ModuleName Test.RunnerOuterLoop -Times 0 -Exactly -Scope It
    }
    It 'holds a gated runner without fault accounting, logging the hold once and the release once' {
        $gate = [pscustomobject]@{ State = 'closed'; RequestId = 'r1'; Orphaned = $false; SpawnAllowed = $false; Reason = 'closed' }
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'refresh-gated'; ExitCode = 0; Gate = $gate })
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'refresh-gated'; ExitCode = 0; Gate = $gate })
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'completed'; ExitCode = 0 })
        $null = Invoke-RunnerOuterLoop -State (New-LoopState) 3>$null
        Assert-Equal -Expected 1 -Actual @($script:Logged | Where-Object { $_ -eq 'KEY:runner.refresh_gate_hold' }).Count -Because 'once per transition'
        Assert-Equal -Expected 1 -Actual @($script:Logged | Where-Object { $_ -eq 'KEY:runner.refresh_gate_released' }).Count
        Assert-MockCalled -CommandName Wait-OuterInterruptible -ModuleName Test.RunnerOuterLoop -Times 2 -Exactly -Scope It
        Assert-MockCalled -CommandName Update-RunnerCrashGating -ModuleName Test.RunnerOuterLoop -Times 0 -Exactly -Scope It
        Assert-MockCalled -CommandName Update-RunnerFaultStatus -ModuleName Test.RunnerOuterLoop -Times 0 -Exactly -Scope It
        Assert-False ($global:__loopStates -contains 'fault') 'a held cycle is not a fault'
    }
    It 'arms the barrier for exactly one ordinary cycle after a new-outer preflight, and keeps the handoff when the preflight fails' {
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'refresh-preflight'; ExitCode = 0; Handoff = @{ TokenId = ('a' * 32); RequestId = 'r2'; Purpose = 'new-outer' } })
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'completed'; ExitCode = 0 })
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'completed'; ExitCode = 0 })
        $state = New-LoopState -Extra @{ RefreshHandoff = @{ TokenId = ('a' * 32); RequestId = 'r2'; Purpose = 'new-outer' } }
        $null = Invoke-RunnerOuterLoop -State $state 3>$null
        Assert-Equal -Expected 'r2' -Actual $script:Dispatches[1].Barrier
        Assert-Null $script:Dispatches[2].Barrier
        Assert-Null $state.RefreshHandoff
        $script:Dispatches.Clear()
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'refresh-preflight'; ExitCode = 1; Handoff = @{ TokenId = ('b' * 32); RequestId = 'r3'; Purpose = 'new-outer' } })
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'refresh-gated'; ExitCode = 0 })
        $failed = New-LoopState -Extra @{ RefreshHandoff = @{ TokenId = ('b' * 32); RequestId = 'r3'; Purpose = 'new-outer' } }
        $null = Invoke-RunnerOuterLoop -State $failed 3>$null
        Assert-NotNull $failed.RefreshHandoff
        Assert-Null $script:Dispatches[1].Barrier
    }
    It 'verifies a resident-outer preflight itself, completes the handoff as the designated outer and reports readiness' {
        Mock -ModuleName Test.RunnerOuterLoop Wait-YurunaRunnerReadiness { [pscustomobject]@{ State = 'ready'; Reason = 'ok' } }
        Mock -ModuleName Test.RunnerOuterLoop Test-YurunaRunnerHandoffToken { [pscustomobject]@{ Valid = $false; Generation = 'gen-1' } }
        Mock -ModuleName Test.RunnerOuterLoop Complete-YurunaRunnerHandoff { [pscustomobject]@{ Completed = $true; State = 'released'; Reason = 'completed' } }
        $global:__trigger = [System.Collections.Generic.List[string]]::new()
        function global:Set-HostRefreshCallerAck { [CmdletBinding(SupportsShouldProcess)] param($RequestId, $Readiness, $CallerPid, $CallerStartTimeUnixMs, $Reason) $null = $CallerPid, $CallerStartTimeUnixMs, $Reason; if ($PSCmdlet.ShouldProcess($RequestId)) { $global:__trigger.Add("$RequestId|$Readiness") } }
        # The handoff record the trigger returned carries no purpose; the
        # purpose the gate validated at dispatch is what decides.
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'refresh-preflight'; ExitCode = 0; Cycle = [pscustomobject]@{ Pid = 5; StartTimeUnixMs = [long]6 }
            Handoff = @{ TokenId = ('c' * 32); RequestId = 'r4'; Purpose = 'resident-outer' } })
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'completed'; ExitCode = 0 })
        $state = New-LoopState -Extra @{ RefreshHandoff = @{ tokenId = ('c' * 32); requestId = 'r4' } }
        $null = Invoke-RunnerOuterLoop -State $state 3>$null 6>$null
        Assert-MockCalled -CommandName Complete-YurunaRunnerHandoff -ModuleName Test.RunnerOuterLoop -Times 1 -Exactly -Scope It -ParameterFilter {
            $AsDesignatedOuter -and $Verdict -eq 'released' -and $ExpectedGeneration -eq 'gen-1' -and $TokenId -eq ('c' * 32) }
        Assert-MockCalled -CommandName Wait-YurunaRunnerReadiness -ModuleName Test.RunnerOuterLoop -Times 1 -Exactly -Scope It -ParameterFilter { $ExpectedCycle.Pid -eq 5 }
        Assert-Equal -Expected 'r4|ready' -Actual ($global:__trigger -join ',')
        Assert-Equal -Expected 'r4' -Actual $script:Dispatches[1].Barrier
    }
    It 'completes an unverifiable resident-outer preflight as recovery-pending and holds' {
        Mock -ModuleName Test.RunnerOuterLoop Wait-YurunaRunnerReadiness { [pscustomobject]@{ State = 'identity-mismatch'; Reason = 'cycle-mismatch' } }
        Mock -ModuleName Test.RunnerOuterLoop Test-YurunaRunnerHandoffToken { [pscustomobject]@{ Valid = $false; Generation = 'gen-2' } }
        Mock -ModuleName Test.RunnerOuterLoop Complete-YurunaRunnerHandoff { [pscustomobject]@{ Completed = $true; State = 'recovery-pending'; Reason = 'completed' } }
        $global:__trigger = [System.Collections.Generic.List[string]]::new()
        function global:Set-HostRefreshCallerAck { [CmdletBinding(SupportsShouldProcess)] param($RequestId, $Readiness, $CallerPid, $CallerStartTimeUnixMs, $Reason) $null = $CallerPid, $CallerStartTimeUnixMs; if ($PSCmdlet.ShouldProcess($RequestId)) { $global:__trigger.Add("$RequestId|$Readiness|$Reason") } }
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'refresh-preflight'; ExitCode = 0; Cycle = [pscustomobject]@{ Pid = 5; StartTimeUnixMs = [long]6 }
            Handoff = @{ TokenId = ('d' * 32); RequestId = 'r5'; Purpose = 'resident-outer' } })
        $state = New-LoopState -Extra @{ RefreshHandoff = @{ TokenId = ('d' * 32); RequestId = 'r5'; Purpose = 'resident-outer' } }
        $null = Invoke-RunnerOuterLoop -State $state 3>$null
        Assert-MockCalled -CommandName Complete-YurunaRunnerHandoff -ModuleName Test.RunnerOuterLoop -Times 1 -Exactly -Scope It -ParameterFilter { $Verdict -eq 'recovery-pending' -and $AsDesignatedOuter }
        Assert-Equal -Expected 'r5|failed|cycle-mismatch' -Actual ($global:__trigger -join ',')
        Assert-MockCalled -CommandName Wait-OuterInterruptible -ModuleName Test.RunnerOuterLoop -Times 1 -Exactly -Scope It
        Assert-True (@($script:Logged) -contains 'KEY:runner.refresh_handoff_unverified') 'logged'
    }
    It 'ends an expired resident-outer handoff designating this outer, reports it failed, and names the resume path' {
        Mock -ModuleName Test.RunnerOuterLoop Complete-YurunaRunnerExpiredHandoff { [pscustomobject]@{ Completed = $true; Reason = 'completed'; RequestId = 'r7'; State = 'recovery-pending' } }
        Mock -ModuleName Test.RunnerOuterLoop Get-YurunaRefreshGateState {
            [pscustomobject]@{ State = 'recovery-pending'; RequestId = 'r7'; Orphaned = $false; SpawnAllowed = $false; Reason = 'recovery-pending'
                Owner = @{ pid = $PID; startTimeUnixMs = [long]12345; role = 'resident-outer' } }
        }
        $global:__trigger = [System.Collections.Generic.List[string]]::new()
        function global:Set-HostRefreshCallerAck { [CmdletBinding(SupportsShouldProcess)] param($RequestId, $Readiness, $CallerPid, $CallerStartTimeUnixMs, $Reason) $null = $CallerPid, $CallerStartTimeUnixMs; if ($PSCmdlet.ShouldProcess($RequestId)) { $global:__trigger.Add("$RequestId|$Readiness|$Reason") } }
        $expired = [pscustomobject]@{ State = 'handoff'; Purpose = 'resident-outer'; RequestId = 'r7'; Orphaned = $false; SpawnAllowed = $false; Reason = 'handoff'
            DesignatedOuter = @{ pid = $PID; startTimeUnixMs = [long]12345 } }
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'refresh-gated'; ExitCode = 0; Gate = $expired })
        $state = New-LoopState -Extra @{ RefreshHandoff = @{ tokenId = ('f' * 32); requestId = 'r7'; purpose = 'resident-outer' }; OuterStartTimeUnixMs = [long]12345 }
        $null = Invoke-RunnerOuterLoop -State $state 3>$null
        Assert-MockCalled -CommandName Complete-YurunaRunnerExpiredHandoff -ModuleName Test.RunnerOuterLoop -Times 1 -Exactly -Scope It
        Assert-Null $state.RefreshHandoff
        Assert-Equal -Expected 'r7|failed|handoff-expired' -Actual ($global:__trigger -join ',')
        Assert-True (@($script:Logged) -contains 'KEY:runner.refresh_handoff_unverified') 'the expired handoff is logged'
        Assert-True (@($script:Logged) -contains 'KEY:runner.refresh_gate_orphaned') 'the hold names the resume path, not a plain hold'
        Assert-False (@($script:Logged) -contains 'KEY:runner.refresh_gate_hold') 'no plain hold line'
    }
    It 'leaves a live resident-outer handoff alone and holds' {
        Mock -ModuleName Test.RunnerOuterLoop Complete-YurunaRunnerExpiredHandoff { [pscustomobject]@{ Completed = $false; Reason = 'token-live' } }
        $live = [pscustomobject]@{ State = 'handoff'; Purpose = 'resident-outer'; RequestId = 'r8'; Orphaned = $false; SpawnAllowed = $false; Reason = 'handoff'
            DesignatedOuter = @{ pid = $PID; startTimeUnixMs = [long]12345 }; Owner = @{ pid = $PID; startTimeUnixMs = [long]12345 } }
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'refresh-gated'; ExitCode = 0; Gate = $live })
        $handoff = @{ tokenId = ('9' * 32); requestId = 'r8'; purpose = 'resident-outer' }
        $state = New-LoopState -Extra @{ RefreshHandoff = $handoff; OuterStartTimeUnixMs = [long]12345 }
        $null = Invoke-RunnerOuterLoop -State $state 3>$null
        Assert-MockCalled -CommandName Complete-YurunaRunnerExpiredHandoff -ModuleName Test.RunnerOuterLoop -Times 1 -Exactly -Scope It
        Assert-Equal -Expected ('9' * 32) -Actual $state.RefreshHandoff.tokenId -Because 'a usable handoff is kept'
        Assert-True (@($script:Logged) -contains 'KEY:runner.refresh_gate_hold') 'a handoff in flight is a plain hold'
    }
    It 'never completes a handoff designating another outer, or a new-outer handoff' {
        Mock -ModuleName Test.RunnerOuterLoop Complete-YurunaRunnerExpiredHandoff { [pscustomobject]@{ Completed = $true; Reason = 'completed' } }
        $other = [pscustomobject]@{ State = 'handoff'; Purpose = 'resident-outer'; RequestId = 'r9'; Orphaned = $false; DesignatedOuter = @{ pid = ($PID + 1); startTimeUnixMs = [long]1 } }
        $newOuter = [pscustomobject]@{ State = 'handoff'; Purpose = 'new-outer'; RequestId = 'r9'; Orphaned = $false; DesignatedOuter = $null }
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'refresh-gated'; ExitCode = 0; Gate = $other })
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'refresh-gated'; ExitCode = 0; Gate = $newOuter })
        $null = Invoke-RunnerOuterLoop -State (New-LoopState) 3>$null
        Assert-MockCalled -CommandName Complete-YurunaRunnerExpiredHandoff -ModuleName Test.RunnerOuterLoop -Times 0 -Exactly -Scope It
    }
    It 'reports a gate this outer owns itself as orphaned, and another owner''s as a hold' {
        $own = [pscustomobject]@{ State = 'recovery-pending'; RequestId = 'r10'; Orphaned = $false; SpawnAllowed = $false; Reason = 'recovery-pending'
            Owner = @{ pid = $PID; startTimeUnixMs = [long]12345; role = 'resident-outer' } }
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'refresh-gated'; ExitCode = 0; Gate = $own })
        $null = Invoke-RunnerOuterLoop -State (New-LoopState -Extra @{ OuterStartTimeUnixMs = [long]12345 }) 3>$null
        Assert-Equal -Expected 'KEY:runner.refresh_gate_orphaned' -Actual (@($script:Logged) -join ',')
        $script:Logged.Clear()
        $recycled = [pscustomobject]@{ State = 'recovery-pending'; RequestId = 'r11'; Orphaned = $false; SpawnAllowed = $false; Reason = 'recovery-pending'
            Owner = @{ pid = $PID; startTimeUnixMs = [long]99999999; role = 'resident-outer' } }
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'refresh-gated'; ExitCode = 0; Gate = $recycled })
        $null = Invoke-RunnerOuterLoop -State (New-LoopState -Extra @{ OuterStartTimeUnixMs = [long]12345 }) 3>$null
        Assert-Equal -Expected 'KEY:runner.refresh_gate_hold' -Actual (@($script:Logged) -join ',') -Because 'an owner with this PID but another start time is not this outer'
    }
    It 'issues one generation per cycle and runs each automatic-refresh call site' {
        Mock -ModuleName Test.RunnerOuterLoop Import-OuterRefreshTriggerModule { $true }
        $global:__trigger = [System.Collections.Generic.List[string]]::new()
        function global:Update-HostRefreshAutoEvidence { [CmdletBinding(SupportsShouldProcess)] param($RuntimeDir, $Generation, $Outcome) if ($PSCmdlet.ShouldProcess($RuntimeDir)) { $global:__trigger.Add("evidence|$Generation|$Outcome") }; [pscustomobject]@{ Counted = $false } }
        function global:Invoke-HostRefreshAutoDecision { [CmdletBinding(SupportsShouldProcess)] param($State, $Cycle, $Branch, $Accounting) $null = $State, $Accounting; if ($PSCmdlet.ShouldProcess("$Cycle")) { $global:__trigger.Add("decision|$Cycle|$Branch") }; [pscustomobject]@{ Action = 'none' } }
        function global:Stop-HostRefreshAutoQueuedRequest { [CmdletBinding(SupportsShouldProcess)] param($Reason, $Cycle) if ($PSCmdlet.ShouldProcess("$Cycle")) { $global:__trigger.Add("stop|$Cycle|$Reason") }; $true }
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'completed'; ExitCode = 0 })
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'refresh-gated'; ExitCode = 0 })
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'drain'; ExitCode = 0 })
        $state = New-LoopState -Extra @{ RunnerInstanceId = 'not-valid' }
        $null = Invoke-RunnerOuterLoop -State $state 3>$null
        Assert-Match -Pattern '^[0-9a-f]{32}$' -Actual $state.RunnerInstanceId
        Assert-Equal -Expected "$($state.RunnerInstanceId):1,$($state.RunnerInstanceId):2,$($state.RunnerInstanceId):3" -Actual (($script:Dispatches | ForEach-Object { $_.Generation }) -join ',')
        $calls = @($global:__trigger)
        Assert-Equal -Expected "evidence|$($state.RunnerInstanceId):1|completed" -Actual $calls[0]
        Assert-Equal -Expected 'decision|1|success' -Actual $calls[1]
        Assert-Equal -Expected "evidence|$($state.RunnerInstanceId):2|refresh-gated" -Actual $calls[2]
        Assert-Equal -Expected 'decision|2|gated' -Actual $calls[3]
        Assert-Equal -Expected "evidence|$($state.RunnerInstanceId):3|drain" -Actual $calls[4]
        Assert-Equal -Expected 'stop|3|pool-drain' -Actual $calls[5]
        Assert-Equal -Expected 6 -Actual $calls.Count
        $kept = New-LoopState -Extra @{ RunnerInstanceId = ('f' * 32) }
        $script:Dispatches.Clear()
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'shutdown'; ExitCode = 0 })
        $null = Invoke-RunnerOuterLoop -State $kept 3>$null
        Assert-Equal -Expected (('f' * 32) + ':1') -Actual $script:Dispatches[0].Generation -Because 'a valid instance id is kept'
    }
    It 'continues straight to the preflight on a handoff, skips the failure pause on a repair, and skips the status re-ensure while the gate holds' {
        Mock -ModuleName Test.RunnerOuterLoop Import-OuterRefreshTriggerModule { $true }
        Mock -ModuleName Test.RunnerOuterLoop Test-YurunaRefreshSpawnAllowed { $false }
        $global:__trigger = [System.Collections.Generic.List[string]]::new()
        function global:Update-HostRefreshAutoEvidence { [CmdletBinding(SupportsShouldProcess)] param($RuntimeDir, $Generation, $Outcome) $null = $Generation, $Outcome; if ($PSCmdlet.ShouldProcess($RuntimeDir)) { $null } }
        function global:Invoke-HostRefreshAutoDecision {
            [CmdletBinding(SupportsShouldProcess)] param($State, $Cycle, $Branch, $Accounting) $null = $State, $Accounting, $Branch
            if (-not $PSCmdlet.ShouldProcess("$Cycle")) { return $null }
            if ($Cycle -eq 1) { return [pscustomobject]@{ Action = 'attempted'; Handoff = @{ tokenId = ('a' * 32); purpose = 'resident-outer' } } }
            if ($Cycle -eq 2) { return [pscustomobject]@{ Action = 'attempted'; SkipFailurePause = $true } }
            return [pscustomobject]@{ Action = 'none' }
        }
        function global:Resolve-StatusServiceStart { param($Config) $null = $Config; $global:__trigger.Add('status-start'); @{ ShouldStart = $false } }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterProjectUrl { '' }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterConfigMtime { $null }
        Mock -ModuleName Test.RunnerOuterLoop Test-OuterNewCommitsAvailable { $false }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterAutoRemediation { [pscustomobject]@{ Enabled = $false; MaxAttempts = 0 } }
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'completed'; ExitCode = 1 })
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'completed'; ExitCode = 1 })
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'completed'; ExitCode = 1 })
        $state = New-LoopState
        $null = Invoke-RunnerOuterLoop -State $state 3>$null 6>$null
        Assert-Equal -Expected ('a' * 32) -Actual $script:Dispatches[1].Handoff.tokenId -Because 'the handoff reaches the next dispatch'
        Assert-MockCalled -CommandName Get-OuterCommitSha -ModuleName Test.RunnerOuterLoop -Times 1 -Exactly -Scope It
        Assert-True (@($script:Logged) -contains 'KEY:runner.host_refresh_auto_pause_skipped') 'the skipped pause is logged'
        Assert-True (@($script:Logged) -contains 'KEY:runner.refresh_status_ensure_skipped') 'the re-ensure was skipped'
        Assert-False ($global:__trigger -contains 'status-start') 'the status starter was not consulted'
    }
    It 'logs a failing trigger call and carries on unchanged' {
        Mock -ModuleName Test.RunnerOuterLoop Import-OuterRefreshTriggerModule { $true }
        function global:Update-HostRefreshAutoEvidence { [CmdletBinding(SupportsShouldProcess)] param($RuntimeDir, $Generation, $Outcome) $null = $Generation, $Outcome; if ($PSCmdlet.ShouldProcess($RuntimeDir)) { throw 'evidence store unavailable' } }
        function global:Invoke-HostRefreshAutoDecision { [CmdletBinding(SupportsShouldProcess)] param($State, $Cycle, $Branch, $Accounting) $null = $State, $Branch, $Accounting; if ($PSCmdlet.ShouldProcess("$Cycle")) { throw 'decision failed' } }
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'completed'; ExitCode = 0 })
        $script:Outcomes.Enqueue([pscustomobject]@{ Outcome = 'completed'; ExitCode = 0 })
        $null = Invoke-RunnerOuterLoop -State (New-LoopState) 3>$null
        Assert-Equal -Expected 2 -Actual $script:Dispatches.Count -Because 'the loop kept dispatching'
        Assert-True (@($script:Logged | Where-Object { $_ -eq 'KEY:runner.refresh_trigger_call_failed' }).Count -ge 2) 'each failure is logged'
    }
}

Describe 'Notifier job isolation' {
    It 'loads its dependencies in a fresh thread runspace and returns a no-op summary without configured storage' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $here 'Test.RunnerOuterLoop.psm1'), [ref]$null, [ref]$null)
        $command = $ast.Find({param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Start-ThreadJob' -and $n.Extent.Text.Contains('pool-notifier-')}, $true)
        $body = @($command.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.ScriptBlockExpressionAst] })[0]
        $notifierModulesDir = $here
        $notifierCfg = @{ poolStorage = @{ enabled = $false } }
        $null = $notifierModulesDir, $notifierCfg # Captured by the extracted production job.
        $job = Start-ThreadJob -ScriptBlock $body.ScriptBlock.GetScriptBlock()
        try {
            Assert-NotNull (Wait-Job -Job $job -Timeout 20) 'notifier completed within its budget'
            $result = Receive-Job -Job $job -ErrorAction Stop
            Assert-NotNull $result
            Assert-False $result.ran
            Assert-Equal 0 $result.delivered
        } finally { Remove-Job -Job $job -Force }
    }
}
