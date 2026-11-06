<#PSScriptInfo
.VERSION 2026.11.05
.GUID 423c8376-a989-4f09-aa00-2e5a728ffa76
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test prelude statusservice pester
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
    Pester coverage for Test.Prelude.psm1's shared status-service gate
    (Resolve-StatusServiceStart + Start-YurunaStatusServiceIfEnabled) -- the one
    place the entry-point trio decides whether/how to start the status service.
.DESCRIPTION
    Throw-based assertions for Pester 5+.
    Start-YurunaStatusServiceIfEnabled is exercised against a stub start script
    so the gate is verified without launching a real server.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Prelude.psm1') -Force -DisableNameChecking

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# File scope, above the first Describe: a Describe body is evaluated during the discovery
# pass and everything it declares is torn down before the first It runs, so a path
# declared inside one reaches the assertion as $null.
$script:EntryPointDir = Split-Path -Parent $here   # test/ (this test lives in test/modules)

}

Describe 'Resolve-StatusServiceStart' {
    It 'starts on enabled config and resolves the configured port' {
        $cfg = @{ statusService = @{ enabled = $true; port = 9090 } }
        $d = Resolve-StatusServiceStart -Config $cfg
        Assert-True $d.ShouldStart 'enabled -> ShouldStart'
        Assert-Equal -Expected 9090 -Actual $d.Port -Because 'configured port honored'
    }
    It 'defaults the port to 8080 when absent' {
        $d = Resolve-StatusServiceStart -Config @{ statusService = @{ enabled = $true } }
        Assert-True $d.ShouldStart 'enabled -> ShouldStart'
        Assert-Equal -Expected 8080 -Actual $d.Port -Because 'default port'
    }
    It 'does not start when -NoStatusService is requested even if enabled' {
        $cfg = @{ statusService = @{ enabled = $true; port = 9090 } }
        $d = Resolve-StatusServiceStart -Config $cfg -NoStatusService
        Assert-True (-not $d.ShouldStart) '-NoStatusService overrides enabled'
        Assert-Equal -Expected 9090 -Actual $d.Port -Because 'port still resolved (for diagnostics)'
    }
    It 'does not start when statusService is disabled, missing, or config is null' {
        Assert-True (-not (Resolve-StatusServiceStart -Config @{ statusService = @{ enabled = $false } }).ShouldStart) 'disabled'
        Assert-True (-not (Resolve-StatusServiceStart -Config @{}).ShouldStart) 'no statusService node'
        Assert-True (-not (Resolve-StatusServiceStart -Config $null).ShouldStart) 'null config'
        Assert-Equal -Expected 8080 -Actual (Resolve-StatusServiceStart -Config $null).Port -Because 'null config -> default port'
    }
}

Describe 'Resolve-ConfigServiceStart' {
    It 'defaults to ENABLED on port 8443 when the node/flag is absent' {
        # Backward-compatible: existing configs without configService still serve
        # NAS creds (matches Start-ConfigService.ps1's in-code defaults).
        $d = Resolve-ConfigServiceStart -Config @{}
        Assert-True $d.ShouldStart 'absent node -> enabled by default'
        Assert-Equal -Expected 8443 -Actual $d.Port -Because 'default config port'
        $dn = Resolve-ConfigServiceStart -Config $null
        Assert-True $dn.ShouldStart 'null config -> enabled by default'
        Assert-Equal -Expected 8443 -Actual $dn.Port -Because 'null config -> default port'
    }
    It 'honors enabled and the configured port' {
        $d = Resolve-ConfigServiceStart -Config @{ configService = @{ enabled = $true; port = 9443 } }
        Assert-True $d.ShouldStart 'enabled'
        Assert-Equal -Expected 9443 -Actual $d.Port -Because 'configured port honored'
    }
    It 'does not start when explicitly disabled' {
        Assert-True (-not (Resolve-ConfigServiceStart -Config @{ configService = @{ enabled = $false } }).ShouldStart) 'enabled false -> off'
    }
}

Describe 'Start-YurunaStatusServiceIfEnabled' {
    # Stub start script records its args to a marker file, so the gate is
    # verified end-to-end without launching a real status service.
    #
    # The stub is written in BeforeAll and removed in AfterAll because only those run in
    # the run phase. Authored straight into the Describe body -- which is evaluated during
    # the discovery pass -- the stub was created and then deleted by the trailing
    # Remove-Item before a single It executed, so the gate was handed a -StartScript path
    # that no longer existed and the "was it invoked" marker could never appear.
    BeforeAll {
        $script:StubDir = New-YurunaTestTempDir -Prefix 'yrn-startstub'
        $script:StubScript = Join-Path $script:StubDir 'start-stub.ps1'
        $script:StubMarker = "$($script:StubScript).invoked"
        Set-Content -Path $script:StubScript -Value "param([int]`$Port,[switch]`$Restart) Set-Content -LiteralPath '$($script:StubMarker)' -Value (`"port=`$Port restart=`$Restart`")"
    }
    AfterAll {
        Remove-YurunaTestTempDir $script:StubDir
    }

    It 'invokes the start script with the resolved port when enabled' {
        Remove-Item -LiteralPath $script:StubMarker -Force -ErrorAction SilentlyContinue
        $d = Start-YurunaStatusServiceIfEnabled -Config @{ statusService = @{ enabled = $true; port = 8123 } } -StartScript $script:StubScript
        Assert-True $d.ShouldStart 'decision says start'
        Assert-True (Test-Path $script:StubMarker) 'start script was invoked'
        Assert-True ([bool]((Get-Content $script:StubMarker -Raw) -match 'port=8123')) 'port forwarded'
        Assert-True ([bool]((Get-Content $script:StubMarker -Raw) -match 'restart=False')) 'no -Restart by default'
    }
    It 'passes -Restart through when requested' {
        Remove-Item -LiteralPath $script:StubMarker -Force -ErrorAction SilentlyContinue
        $null = Start-YurunaStatusServiceIfEnabled -Config @{ statusService = @{ enabled = $true } } -StartScript $script:StubScript -Restart
        Assert-True ([bool]((Get-Content $script:StubMarker -Raw) -match 'restart=True')) '-Restart forwarded'
    }
    It 'does NOT invoke the start script when disabled or -NoStatusService' {
        Remove-Item -LiteralPath $script:StubMarker -Force -ErrorAction SilentlyContinue
        $null = Start-YurunaStatusServiceIfEnabled -Config @{ statusService = @{ enabled = $false } } -StartScript $script:StubScript
        Assert-True (-not (Test-Path $script:StubMarker)) 'disabled -> not invoked'
        $null = Start-YurunaStatusServiceIfEnabled -Config @{ statusService = @{ enabled = $true } } -StartScript $script:StubScript -NoStatusService
        Assert-True (-not (Test-Path $script:StubMarker)) '-NoStatusService -> not invoked'
    }

    It 'aborts the entry point when the start script reports a tagged port conflict' {
        # Start-StatusService.ps1 throws a YurunaPortConflict-tagged exception
        # when the status port is held by another user / checkout; the gate must
        # `exit` so the cycle refuses instead of running blind. `exit` cannot be
        # asserted in-process (it would kill the test host), so drive it through
        # a child pwsh and assert on the exit code + the absence of a marker the
        # child writes only if the gate wrongly returned.
        $preludePath = (Resolve-Path (Join-Path $here 'Test.Prelude.psm1')).Path
        Assert-True (Test-Path $preludePath) 'prelude module resolves (guards against a false pass)'

        $tmp           = New-YurunaTestTempDir -Prefix 'yrn-confstub'
        $conflictStub  = Join-Path $tmp 'conflict-stub.ps1'
        $childScript   = Join-Path $tmp 'conflict-child.ps1'
        $continuedFlag = Join-Path $tmp 'continued'

        Set-Content -LiteralPath $conflictStub -Value @'
param([int]$Port,[switch]$Restart)
$ex = [System.InvalidOperationException]::new("Status-service port $Port held; refusing to start.")
$ex.Data['YurunaPortConflict'] = $true
throw $ex
'@
        Set-Content -LiteralPath $childScript -Value @"
Import-Module '$preludePath' -Force -DisableNameChecking
`$null = Start-YurunaStatusServiceIfEnabled -Config @{ statusService = @{ enabled = `$true; port = 8123 } } -StartScript '$conflictStub' -Restart
Set-Content -LiteralPath '$continuedFlag' -Value 'CONTINUED'
"@
        try {
            & pwsh -NoProfile -File $childScript *> $null
            $rc = $LASTEXITCODE
            Assert-True ($rc -ne 0) "gate exits non-zero on conflict (rc=$rc)"
            Assert-True (-not (Test-Path $continuedFlag)) 'gate did not return/continue past the conflict'
        } finally {
            Remove-YurunaTestTempDir $tmp
        }
    }
}

Describe 'Register-EntryPointCancelHandler (shared Ctrl+C handler)' {
    # The entry points share one CancelKeyPress registration. It returns a reference
    # hashtable whose 'Requested' flag the caller polls at safe points, and threads the
    # exit-after label (outer='cycle', single-sequence='step') onto the shared
    # MessageData so the event-thread action -- which cannot see the function's locals --
    # reads it back into its warning. A test-unique SourceIdentifier avoids colliding
    # with a live runner's 'YurunaCancelKey' subscription. The label is set on the state
    # before registration, so these assertions hold even in a headless host where the
    # Register-ObjectEvent bind falls through to the catch.
    It 'returns a shared hashtable with Requested=$false and threads -ExitAfterLabel' {
        $sid = 'YurunaTestCancel-A'
        try {
            $s = Register-EntryPointCancelHandler -SourceIdentifier $sid -ExitAfterLabel 'cycle'
            Assert-True ($s -is [hashtable]) 'returns a hashtable'
            Assert-True ($s['Requested'] -eq $false) "Requested starts `$false (got $($s['Requested']))"
            Assert-Equal -Expected 'cycle' -Actual $s['ExitAfterLabel'] -Because '-ExitAfterLabel threads onto the shared state'
        } finally {
            Unregister-EntryPointCancelHandler -SourceIdentifier $sid
        }
    }
    It 'defaults the exit-after label to step' {
        $sid = 'YurunaTestCancel-B'
        try {
            $s = Register-EntryPointCancelHandler -SourceIdentifier $sid
            Assert-Equal -Expected 'step' -Actual $s['ExitAfterLabel'] -Because 'default label'
        } finally {
            Unregister-EntryPointCancelHandler -SourceIdentifier $sid
        }
    }
    It 'Unregister-EntryPointCancelHandler is safe for a never-registered id (any exit path)' {
        Unregister-EntryPointCancelHandler -SourceIdentifier 'YurunaTestCancel-NeverRegistered'
        Assert-True $true 'did not throw'
    }
}

Describe 'entry-point Ctrl+C handlers delegate to the shared helper' {
    # Start-TestRunner.ps1 and Debug-TestSequence.ps1 must register/tear down the cancel
    # handler through Register-/Unregister-EntryPointCancelHandler, not a hand-rolled
    # inline Register-ObjectEvent -EventName CancelKeyPress, so the pipeline-thread
    # subscription cannot drift between entry points.
    # The entry point under test is threaded in as test-case data rather than captured from
    # an enclosing foreach. The loop would run during the discovery pass and its iteration
    # variable would be gone by the time the It body executed, leaving $entry null and the
    # assertion reading an empty path; -TestCases binds the value into the It's own scope.
    It "<Entry> delegates to the shared cancel handler with no inline CancelKeyPress registration" -TestCases @(
        @{ Entry = 'Start-TestRunner.ps1' }
        @{ Entry = 'Debug-TestSequence.ps1' }
        @{ Entry = 'Invoke-TestProject.ps1' }
    ) {
        param($Entry)
        $path = Join-Path $script:EntryPointDir $Entry
        Assert-True (Test-Path -LiteralPath $path) "entry point exists: $Entry"
        $src = Get-Content -Raw -LiteralPath $path
        Assert-True ($src -match 'Register-EntryPointCancelHandler') "$Entry must call Register-EntryPointCancelHandler"
        Assert-True ($src -match 'Unregister-EntryPointCancelHandler') "$Entry must call Unregister-EntryPointCancelHandler"
        Assert-True (-not ($src -match '-EventName CancelKeyPress')) "$Entry must not hand-roll an inline CancelKeyPress registration"
    }
}

Describe 'Assert-NoOtherRunner returns exactly one boolean' {
    BeforeAll {
        Import-Module (Join-Path $here '../../automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
        Import-Module (Join-Path $here 'Test.SingleInstance.psm1') -Force -Global -DisableNameChecking
    }
    BeforeEach {
        $script:NoOtherDir = New-YurunaTestTempDir -Prefix 'yrn-noother'
        Mock -ModuleName Test.Prelude Get-YurunaRefreshGateState { [pscustomobject]@{ SpawnAllowed = $true; State = 'open'; RequestId = $null } }
    }
    AfterEach { Remove-YurunaTestTempDir $script:NoOtherDir }

    It 'is a single $true on an unowned runtime' {
        $out = @(Assert-NoOtherRunner -RuntimeDir $script:NoOtherDir -CallerName 'unit' 6>$null)
        Assert-Equal -Expected 1 -Actual $out.Count -Because 'the success stream carries only the verdict'
        Assert-True ($out[0] -is [bool] -and $out[0]) 'a single $true'
    }
    It 'is a single $false, with the banner off the success stream, beside a live runner' {
        $runner = Start-Process -FilePath ([Environment]::ProcessPath) -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 60' -PassThru
        try {
            Start-Sleep -Milliseconds 300
            Set-Content -LiteralPath (Join-Path $script:NoOtherDir 'runner.pid') -Value "$($runner.Id)" -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $script:NoOtherDir 'runner.start') -Value ((Get-Process -Id $runner.Id).StartTime.ToUniversalTime().ToString('o')) -Encoding utf8NoBOM
            $info = $null
            $out = @(Assert-NoOtherRunner -RuntimeDir $script:NoOtherDir -CallerName 'unit' -InformationVariable info 6>$null)
            Assert-Equal -Expected 1 -Actual $out.Count
            Assert-True ($out[0] -is [bool] -and -not $out[0]) 'a single $false'
            Assert-True (@($info).Count -ge 5) 'the banner went to the Information stream'
        } finally {
            if (-not $runner.HasExited) { $runner.Kill() }
        }
    }
    It 'is a single $false while a host refresh holds the runner, even with no runner record' {
        Mock -ModuleName Test.Prelude Get-YurunaRefreshGateState { [pscustomobject]@{ SpawnAllowed = $false; State = 'closed'; RequestId = 'r' } }
        $out = @(Assert-NoOtherRunner -RuntimeDir $script:NoOtherDir -CallerName 'unit' 6>$null)
        Assert-Equal -Expected 1 -Actual $out.Count
        Assert-True ($out[0] -is [bool] -and -not $out[0]) 'a single $false'
    }
    It 'is a single $false while another live one-shot run holds the lease' {
        $oneShot = Start-Process -FilePath ([Environment]::ProcessPath) -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 60' -PassThru
        try {
            Start-Sleep -Milliseconds 300
            Set-Content -LiteralPath (Join-Path $script:NoOtherDir 'oneshot.pid') -Value "$($oneShot.Id)" -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $script:NoOtherDir 'oneshot.start') -Value ((Get-Process -Id $oneShot.Id).StartTime.ToUniversalTime().ToString('o')) -Encoding utf8NoBOM
            $info = $null
            $out = @(Assert-NoOtherRunner -RuntimeDir $script:NoOtherDir -CallerName 'unit' -InformationVariable info 6>$null)
            Assert-Equal -Expected 1 -Actual $out.Count
            Assert-True ($out[0] -is [bool] -and -not $out[0]) 'a single $false'
            Assert-Match -Pattern ([regex]::Escape("$($oneShot.Id)")) -Actual (@($info) -join ' ') -Because 'the banner names the holder'
        } finally {
            if (-not $oneShot.HasExited) { $oneShot.Kill() }
        }
    }
}

# The one-shot entry points ran their checkout swap and status-service restart
# before they looked for another runner, and held nothing while they ran.
Describe 'Initialize-YurunaOneShotEntryPoint' {
    BeforeAll {
        Import-Module (Join-Path $here '../../automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
        Import-Module (Join-Path $here 'Test.SingleInstance.psm1') -Force -Global -DisableNameChecking
        Import-Module (Join-Path $here 'Test.YurunaDir.psm1') -Force -Global -DisableNameChecking
        $script:SavedRuntimeEnv = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR', 'YURUNA_LOG_DIR'
    }
    AfterAll { Restore-YurunaTestEnvironment -Saved $script:SavedRuntimeEnv }
    BeforeEach {
        $script:OneShotDir = New-YurunaTestTempDir -Prefix 'yrn-oneshot'
        $env:YURUNA_RUNTIME_DIR = Join-Path $script:OneShotDir 'runtime'
        $env:YURUNA_LOG_DIR = Join-Path $script:OneShotDir 'log'
        Mock -ModuleName Test.Prelude Get-YurunaRefreshGateState { [pscustomobject]@{ SpawnAllowed = $true; State = 'open'; RequestId = $null } }
    }
    AfterEach {
        $null = Exit-YurunaOneShotLease -RuntimeDir $env:YURUNA_RUNTIME_DIR -Confirm:$false
        Remove-YurunaTestTempDir $script:OneShotDir
    }

    It 'publishes the runtime, takes the lease, and lets the holder release it' {
        Assert-True (Initialize-YurunaOneShotEntryPoint -CallerName 'unit' -Confirm:$false 6>$null) 'an unowned runtime is claimed'
        Assert-Equal -Expected 'Self' -Actual (Get-YurunaOneShotLeaseState -RuntimeDir $env:YURUNA_RUNTIME_DIR).State
        Assert-True (Test-Path -LiteralPath $env:YURUNA_LOG_DIR) 'the log directory is published too'
        Assert-True (Exit-YurunaOneShotLease -RuntimeDir $env:YURUNA_RUNTIME_DIR -Confirm:$false) 'the caller releases it'
    }
    It 'refuses beside a live runner and gives the lease back' {
        $runner = Start-Process -FilePath ([Environment]::ProcessPath) -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 60' -PassThru
        try {
            Start-Sleep -Milliseconds 300
            $null = New-Item -ItemType Directory -Path $env:YURUNA_RUNTIME_DIR -Force
            Set-Content -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'runner.pid') -Value "$($runner.Id)" -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'runner.start') -Value ((Get-Process -Id $runner.Id).StartTime.ToUniversalTime().ToString('o')) -Encoding utf8NoBOM
            Assert-False (Initialize-YurunaOneShotEntryPoint -CallerName 'unit' -Confirm:$false 6>$null) 'a live runner owns the runtime'
            Assert-Equal -Expected 'Missing' -Actual (Get-YurunaOneShotLeaseState -RuntimeDir $env:YURUNA_RUNTIME_DIR).State -Because 'a refused run holds nothing'
        } finally {
            if (-not $runner.HasExited) { $runner.Kill() }
        }
    }
    It 'refuses while another live one-shot run holds the lease' {
        $oneShot = Start-Process -FilePath ([Environment]::ProcessPath) -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 60' -PassThru
        try {
            Start-Sleep -Milliseconds 300
            $null = New-Item -ItemType Directory -Path $env:YURUNA_RUNTIME_DIR -Force
            Set-Content -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'oneshot.pid') -Value "$($oneShot.Id)" -Encoding utf8NoBOM
            Set-Content -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'oneshot.start') -Value ((Get-Process -Id $oneShot.Id).StartTime.ToUniversalTime().ToString('o')) -Encoding utf8NoBOM
            $info = $null
            Assert-False (Initialize-YurunaOneShotEntryPoint -CallerName 'unit' -Confirm:$false -InformationVariable info 6>$null) 'the other run keeps the runtime'
            Assert-Match -Pattern ([regex]::Escape("$($oneShot.Id)")) -Actual (@($info) -join ' ') -Because 'the refusal names the holder'
            Assert-Equal -Expected "$($oneShot.Id)" -Actual ([IO.File]::ReadAllText((Join-Path $env:YURUNA_RUNTIME_DIR 'oneshot.pid')).Trim()) -Because 'its lease is untouched'
        } finally {
            if (-not $oneShot.HasExited) { $oneShot.Kill() }
        }
    }
    It '<Script> claims the runtime before its first side effect, and every later exit releases the lease' -TestCases @(
        @{ Script = 'Debug-TestSequence.ps1' }
        @{ Script = 'Invoke-TestProject.ps1' }
    ) {
        param($Script)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:EntryPointDir $Script), [ref]$null, [ref]$null)
        $commands = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
        $claim = @($commands | Where-Object { $_.GetCommandName() -eq 'Initialize-YurunaOneShotEntryPoint' })
        Assert-Equal -Expected 1 -Actual $claim.Count -Because "$Script claims the runtime once"
        foreach ($effect in 'Invoke-CycleCheckoutStep', 'Start-YurunaStatusServiceIfEnabled', 'Invoke-GitSourceGate', 'Clear-StaleControlState', 'Invoke-OuterCycleDispatch') {
            foreach ($call in @($commands | Where-Object { $_.GetCommandName() -eq $effect })) {
                Assert-True ($call.Extent.StartOffset -gt $claim[0].Extent.EndOffset) "$Script claims the runtime before $effect (line $($call.Extent.StartLineNumber))"
            }
        }
        $claimIf = $claim[0]
        while ($claimIf -isnot [System.Management.Automation.Language.IfStatementAst]) { $claimIf = $claimIf.Parent }
        # The release is Exit-YurunaOneShotLease, called directly or through a
        # helper the script defines for it.
        $releasers = @('Exit-YurunaOneShotLease') + @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Body.Extent.Text -match 'Exit-YurunaOneShotLease' }, $true) | ForEach-Object { $_.Name })
        $callsRelease = { param($Node) @($Node.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in $releasers }, $true)).Count -gt 0 }
        $releasing = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.TryStatementAst] -and $n.Finally }, $true) | Where-Object { & $callsRelease $_.Finally })
        Assert-True ($releasing.Count -ge 1) "$Script releases the lease in a finally block"
        foreach ($exitAst in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true))) {
            if ($exitAst.Extent.StartOffset -le $claimIf.Extent.EndOffset) { continue }
            $covered = @($releasing | Where-Object {
                $exitAst.Extent.StartOffset -ge $_.Body.Extent.StartOffset -and $exitAst.Extent.EndOffset -le $_.Body.Extent.EndOffset }).Count -gt 0
            Assert-True $covered "$Script line $($exitAst.Extent.StartLineNumber): an exit after the claim must pass the finally that releases the lease"
        }
        $stop = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Stop-WithReason' }, $true))
        foreach ($fn in $stop) {
            Assert-True (& $callsRelease $fn.Body) "$Script's Stop-WithReason releases the lease before it exits"
        }
    }
    It 'Start-TestRunner reads the lease before it reclaims anything, and again once runner.pid is written' {
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:EntryPointDir 'Start-TestRunner.ps1')
        $refusalsAt = $text.IndexOf('$refuseStart = {')
        $freshCallAt = $text.IndexOf('if (-not $RefreshResume) { . $refuseStart }')
        $pidAt = $text.IndexOf('$pidWritten = Write-RunnerPidFile')
        Assert-True ($refusalsAt -gt 0 -and $pidAt -gt 0) 'fixture sanity: the startup refusals and the pidfile write are where this test looks'
        $inRefusals = $text.IndexOf('& $refuseOneShot', $refusalsAt)
        Assert-True ($inRefusals -gt $refusalsAt -and $inRefusals -lt $freshCallAt) 'the startup refusals, which run before boot recovery and the takeover, read the lease'
        $afterPid = $text.IndexOf('& $refuseOneShot', $pidAt)
        $resumeRecoveryAt = $text.IndexOf('if ($RefreshResume) { & $runStartupRecovery }')
        Assert-True ($pidAt -gt 0 -and $afterPid -gt $pidAt -and $afterPid -lt $resumeRecoveryAt) 'the lease is read again after runner.pid is published'
    }
}

Describe 'Initialize-YurunaEntryPointModuleSet -- the Refresh set' {
    BeforeAll {
        $fn = Get-YurunaTestFunctionAst -Path (Join-Path $here 'Test.Prelude.psm1') -Name 'Initialize-YurunaEntryPointModuleSet'
        $table = @($fn.Body.FindAll({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $true) |
            Where-Object { @($_.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text }) -contains 'Refresh' })[0]
        $script:Sets = @{}
        foreach ($pair in $table.KeyValuePairs) {
            $script:Sets[$pair.Item1.Extent.Text] = @($pair.Item2.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
                ForEach-Object { $_.Value })
        }
        $script:ForParam = @($fn.Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'For' })[0]
    }
    It 'lists the host-refresh closure in dependency order' {
        $expected = @('Test.HostContract.psm1', 'Test.YurunaDir.psm1', 'Test.Config.psm1', 'Test.StateFile.psm1', 'Test.OuterLog.psm1',
            'Test.SingleFlightLock.psm1', 'Test.CriticalRecord.psm1', 'Test.SingleInstance.psm1', 'Test.InnerSpawn.psm1',
            'Test.Recovery.psm1', 'Test.ServiceCensus.psm1', 'Test.ServiceVm.psm1', 'Test.HostRefreshIntent.psm1', 'Test.HostRefresh.psm1')
        Assert-Equal -Expected ($expected -join ',') -Actual ($script:Sets['Refresh'] -join ',')
        foreach ($excluded in @('Test.RunnerOuterLoop.psm1', 'Test.Log.psm1', 'Test.EventSchema.psm1', 'Test.SequenceFailureState.psm1')) {
            Assert-False ($script:Sets['Refresh'] -contains $excluded) "$excluded stays out of the Refresh set"
        }
        $validate = @($script:ForParam.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' })[0]
        Assert-True (@($validate.PositionalArguments | ForEach-Object { $_.Value }) -contains 'Refresh') '-For accepts Refresh'
    }
    It 'loads the outer.log writer before the outer loop in the Outer set' {
        $outer = [string[]]$script:Sets['Outer']
        $i = [array]::IndexOf($outer, 'Test.OuterLog.psm1')
        Assert-True ($i -ge 0) 'Test.OuterLog is in the Outer set'
        Assert-Equal -Expected 'Test.RunnerWatchdog.psm1' -Actual $outer[$i + 1]
        $loop = [array]::IndexOf($outer, 'Test.RunnerOuterLoop.psm1')
        Assert-True ($loop -gt $i + 1) 'the outer loop loads after the outer.log writer and the watchdog'
    }
    It 'loads the recovery contract, the ledger and the repairs, in that order, before the outer loop that calls them' {
        $outer = [string[]]$script:Sets['Outer']
        $contract = [array]::IndexOf($outer, 'Test.RecoveryContract.psm1')
        $ledger   = [array]::IndexOf($outer, 'Test.RecoveryLedger.psm1')
        $actions  = [array]::IndexOf($outer, 'Test.RecoveryActions.psm1')
        $loop     = [array]::IndexOf($outer, 'Test.RunnerOuterLoop.psm1')
        Assert-True ($contract -ge 0 -and $contract -lt $ledger -and $ledger -lt $actions -and $actions -lt $loop) `
            "the Outer set must list the contract, the ledger, the repairs and then the loop (found $contract, $ledger, $actions, $loop)"
    }
    It 'gives every entry point that records a result the recovery contract, and keeps it out of the Refresh set' {
        foreach ($kind in @('Outer', 'Inner', 'Project', 'Sequence')) {
            Assert-True ([string[]]$script:Sets[$kind] -contains 'Test.RecoveryContract.psm1') "the $kind set carries Test.RecoveryContract"
        }
        foreach ($module in @('Test.RecoveryContract.psm1', 'Test.RecoveryLedger.psm1', 'Test.RecoveryActions.psm1')) {
            Assert-False ([string[]]$script:Sets['Refresh'] -contains $module) "$module stays out of the Refresh set"
        }
    }
}
