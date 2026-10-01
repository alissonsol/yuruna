<#PSScriptInfo
.VERSION 2026.09.30
.GUID 425737dc-81c1-4d1d-8e15-006de1ba8931
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test diagnostic deadline sequence pester
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
    Exercises bounded diagnostic collection and its nonfatal sequence contract.
.DESCRIPTION
    The registered sequence handler runs with fixture capture and event sinks.
    No host, guest, network service, or saved credential is required.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Diagnostic.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Log.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.SequenceHandler.psm1') -Force -Global -DisableNameChecking
    $script:diagnosticModule = Get-Module Test.Diagnostic

    function New-DiagnosticStepContext {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory fixture context without changing external state.')]
        param([string]$Id = 'website')
        return @{
            Step = @{ action = 'saveSystemDiagnostic'; id = $Id }
            Vars = @{}
            VMName = 'fixture-vm'
            GuestKey = 'guest.ubuntu.server.26'
            StepInvocationId = 'step-fixture'
            SequenceInvocationId = 'sequence-fixture'
            ExpandVariable = { param($Value, $Variables) $null = $Variables; return $Value }
        }
    }

    function New-DiagnosticWorkerFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Writes only a fixture script within the Pester TestDrive.')]
        param([Parameter(Mandatory)][string]$Directory)
        $fixturePath = Join-Path $Directory "diagnostic worker `u{e9}.ps1"
        $source = @'
param([Parameter(Mandatory)][string]$RequestPath)
$ErrorActionPreference = 'Stop'
$request = [IO.File]::ReadAllText($RequestPath) | ConvertFrom-Json -AsHashtable
[IO.File]::WriteAllText((Join-Path $request.OutputFolder 'worker.pid'), [string]$PID)
$capturePath = Join-Path $request.OutputFolder "capture-`u{8a3a}`u{65ad}.txt"
$manifest = @{
    success = $true; outPath = $capturePath; mechanism = 'key'; attempted = @('key-ssh')
    exitCode = 0; bytes = 0L; skipped = $false; reason = $null; diagnosticOutcome = 'complete'
    hostSnapshot = @{ Status = 'available'; Path = 'host.json' }
    guestSnapshot = @{ diagnosticOutcome = 'partial'; outPath = 'sample.txt' }
    stepInvocationId = $request.StepInvocationId; sequenceInvocationId = $request.SequenceInvocationId
    observedVmName = $request.VMName; observedLocale = $request.OperatorLocaleContext
}
$envelope = @{ captureId = $request.CaptureId; manifest = $manifest }
switch ($request.FixtureMode) {
    'complete' {
        [IO.File]::WriteAllText($capturePath, "Hostname : m`u{e1}quina`nDiagnostics complete.", [Text.UTF8Encoding]::new($false))
        $manifest.bytes = [IO.FileInfo]::new($capturePath).Length
        [IO.File]::WriteAllText($request.ResultPath, ($envelope | ConvertTo-Json -Depth 10))
    }
    'complete-noisy' {
        [Console]::Write([string]::new('x', 600000))
        [IO.File]::WriteAllText($capturePath, 'Diagnostics complete.')
        [IO.File]::WriteAllText($request.ResultPath, ($envelope | ConvertTo-Json -Depth 10))
    }
    'checkpoint-timeout' {
        [IO.File]::WriteAllText($capturePath, "========`nPartial `u{8a3a}`u{65ad}", [Text.UTF8Encoding]::new($false))
        $manifest.success = $false
        $manifest.diagnosticOutcome = 'partial'
        $manifest.bytes = [IO.FileInfo]::new($capturePath).Length
        [IO.File]::WriteAllText($request.CheckpointPath, ($envelope | ConvertTo-Json -Depth 10))
        Start-Sleep -Seconds 30
    }
    'result-then-timeout' {
        [IO.File]::WriteAllText($capturePath, 'Diagnostics complete.')
        [IO.File]::WriteAllText($request.ResultPath, ($envelope | ConvertTo-Json -Depth 10))
        Start-Sleep -Seconds 30
    }
    'stale-checkpoint-timeout' {
        $envelope.captureId = 'another-capture'
        [IO.File]::WriteAllText($request.CheckpointPath, ($envelope | ConvertTo-Json -Depth 10))
        Start-Sleep -Seconds 30
    }
    'no-output-timeout' { Start-Sleep -Seconds 30 }
    'malformed' { [IO.File]::WriteAllText($request.ResultPath, '{broken-json') }
    'wrong-result-type' {
        $manifest.success = 'true'
        [IO.File]::WriteAllText($request.ResultPath, ($envelope | ConvertTo-Json -Depth 10))
    }
    'stale-result' {
        $envelope.captureId = 'another-capture'
        [IO.File]::WriteAllText($request.ResultPath, ($envelope | ConvertTo-Json -Depth 10))
    }
    'exception' { throw 'Fixture worker cannot collect diagnostics.' }
    default { throw 'Unknown fixture mode.' }
}
'@
        [IO.File]::WriteAllText($fixturePath, $source, [Text.UTF8Encoding]::new($false))
        return $fixturePath
    }

    function Invoke-DiagnosticWorkerFixture {
        param(
            [Parameter(Mandatory)][string]$Directory,
            [Parameter(Mandatory)][string]$Mode,
            [int]$TimeoutSeconds = 5
        )
        $fixturePath = New-DiagnosticWorkerFixture -Directory $Directory
        return & $script:diagnosticModule {
            param($FixturePath, $Directory, $Mode, $TimeoutSeconds)
            $priorWorkerPath = $script:GuestDiagnosticWorkerPath
            try {
                $script:GuestDiagnosticWorkerPath = $FixturePath
                Invoke-GuestDiagnosticWorker -Request @{
                    VMName = "m`u{e1}quina-`u{8a3a}`u{65ad}"; GuestKey = 'guest.ubuntu.server.26'
                    OutputFolder = $Directory; Id = 'fixture'; FixtureMode = $Mode
                    StepInvocationId = 'step-worker'; SequenceInvocationId = 'sequence-worker'
                    OperatorLocaleContext = @{ EffectiveLocale = 'pt-BR'; RequestedLocale = 'pt-BR'; Direction = 'ltr' }
                } -TimeoutSeconds $TimeoutSeconds
            } finally {
                $script:GuestDiagnosticWorkerPath = $priorWorkerPath
            }
        } $fixturePath $Directory $Mode $TimeoutSeconds
    }

    function New-DiagnosticHostFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Writes only fixture files within the Pester TestDrive.')]
        param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Mode)
        [IO.File]::WriteAllText((Join-Path $Directory 'host-fixture.mode'), $Mode)
        $modulePath = Join-Path $Directory 'DiagnosticHostFixture.psm1'
        $source = @'
$script:HostTag = 'child-driver-context'
function Get-DiagnosticFixtureHostTag { return $script:HostTag }
Export-ModuleMember -Function Get-DiagnosticFixtureHostTag
$mode = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'host-fixture.mode'))
& (Get-Module Test.Diagnostic) {
    param($Mode)
    $script:FixtureMode = $Mode
    function script:Save-GuestPerformanceSnapshot {
        param($VMName, $GuestKey, $OutputFolder, $Id, $StepInvocationId, $SequenceInvocationId)
        [IO.File]::WriteAllText((Join-Path $OutputFolder 'sampling.started'), [string]$PID)
        if ($script:FixtureMode -eq 'sampling-timeout') { Start-Sleep -Seconds 30 }
        return @{ diagnosticOutcome = 'partial'; outPath = 'short-fixture.txt' }
    }
    if ($Mode -eq 'complete') {
        function script:Invoke-GuestDiagnosticCapture {
            param($VMName, $GuestKey, $OutputFolder, $Id)
            $capturePath = Join-Path $OutputFolder $script:GuestDiagnosticFileName
            [IO.File]::WriteAllText($capturePath, 'Diagnostics complete.')
            return @{
                success = $true; outPath = $capturePath; mechanism = 'key'; attempted = @('key-ssh')
                exitCode = 0; bytes = [IO.FileInfo]::new($capturePath).Length; skipped = $false
                fixtureHostTag = Get-DiagnosticFixtureHostTag
                fixtureLocale = Get-YurunaOperatorLocale
                fixtureUser = Test.Ssh\Get-GuestSshUser -GuestKey $GuestKey
                fixtureAddress = Test.Ssh\Get-ProvenGuestAddress -VMName $VMName
            }
        }
    }
    if ($Mode -in @('console-timeout', 'console-after-ssh', 'console-late')) {
        function script:Update-GuestNeighborCache { param($VMName) }
        function script:Resolve-StoredPassword { param($Username) return @{ password = $null; reason = 'no-entry' } }
        function script:Resolve-StatusServiceEndpoint { param($VMName) return @{ url = 'http://192.0.2.1:8080' } }
        function script:Invoke-RemoteDiagnosticsKeySsh {
            param($VMName, $GuestKey, $TimeoutSeconds, $BootstrapUrl)
            return @{ success = $false; output = "========`nPartial SSH fixture"; mechanism = 'key'; exitCode = 124; timedOut = $true }
        }
    }
    if ($Mode -eq 'console-timeout') {
        function script:Invoke-RemoteDiagnosticsConsole {
            param($VMName, $FailureFolderPath, $DiagnosticsFileName, $TimeoutSeconds)
            [IO.File]::WriteAllText((Join-Path $FailureFolderPath 'console.started'), [string]$PID)
            Start-Sleep -Seconds 30
        }
    }
    # The guest uploads under the name the rung hands it; the status service
    # writes that file. 'console-late' is an upload that lands after the rung
    # has already given up waiting for it.
    if ($Mode -in @('console-after-ssh', 'console-late')) {
        function script:Invoke-RemoteDiagnosticsConsole {
            param($VMName, $FailureFolderPath, $DiagnosticsFileName, $TimeoutSeconds)
            [IO.File]::WriteAllText((Join-Path $FailureFolderPath 'console.upload-name'), $DiagnosticsFileName)
            [IO.File]::WriteAllText((Join-Path $FailureFolderPath $DiagnosticsFileName), "========`nConsole capture fixture`nDiagnostics complete.")
            if ($script:FixtureMode -eq 'console-late') { return @{ success = $false; output = ''; exitCode = -1; mechanism = 'console'; timedOut = $true } }
            return @{ success = $true; output = ''; exitCode = 0; mechanism = 'console' }
        }
    }
} $mode
if ($mode -in @('console-timeout', 'console-after-ssh', 'console-late')) {
    & (Get-Module Test.Ssh) {
        function script:Wait-SshReady { param($VMName, $GuestKey, $TimeoutSeconds, $PollSeconds) return $true }
        function script:Get-GuestAddress { param($VMName) return '192.0.2.10' }
    }
}
'@
        [IO.File]::WriteAllText($modulePath, $source, [Text.UTF8Encoding]::new($false))
        return $modulePath
    }

    function Invoke-ProductionDiagnosticWorkerFixture {
        param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Mode, [int]$TimeoutSeconds = 10)
        $hostModulePath = New-DiagnosticHostFixture -Directory $Directory -Mode $Mode
        $workerPath = Join-Path $PSScriptRoot '../Invoke-GuestDiagnosticWorker.ps1'
        $workingDirectory = (Get-Location).ProviderPath
        $context = Get-YurunaOperatorLocale
        return & $script:diagnosticModule {
            param($WorkerPath, $HostModulePath, $Directory, $WorkingDirectory, $LocaleContext, $TimeoutSeconds)
            $priorWorkerPath = $script:GuestDiagnosticWorkerPath
            try {
                $script:GuestDiagnosticWorkerPath = $WorkerPath
                Invoke-GuestDiagnosticWorker -Request @{
                    VMName = 'fixture-vm'; GuestKey = 'guest.ubuntu.server.26'; OutputFolder = $Directory; Id = 'actual'
                    StepInvocationId = 'step-actual'; SequenceInvocationId = 'sequence-actual'
                    HostSnapshot = @{ Status = 'available'; Path = 'host-fixture.json' }
                    WorkingDirectory = $WorkingDirectory; HostModulePath = $HostModulePath
                    GuestSshUserOverrides = @{ 'guest.ubuntu.server.26' = 'fixture-user' }
                    ProvenGuestAddress = @{ 'fixture-vm' = @{ Address = '192.0.2.10'; AtUtc = [datetime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture) } }
                    OperatorLocaleContext = $LocaleContext; DiagnosticsFileName = 'fixture.system.diagnostic.actual.txt'
                    TimeoutSeconds = $TimeoutSeconds; PerCommandTimeoutSeconds = 2
                } -TimeoutSeconds $TimeoutSeconds
            } finally {
                $script:GuestDiagnosticWorkerPath = $priorWorkerPath
            }
        } $workerPath $hostModulePath $Directory $workingDirectory $context $TimeoutSeconds
    }
}

Describe 'saveSystemDiagnostic preserves successful workload progress' {
    BeforeEach {
        $script:diagnosticEvents = [Collections.Generic.List[object]]::new()
        Mock Get-CycleGuestDataFolder -ModuleName Test.SequenceHandler { return $TestDrive }
        Mock Send-CycleEventSafely -ModuleName Test.SequenceHandler {
            param($EventRecord)
            $script:diagnosticEvents.Add($EventRecord)
        }
    }

    It 'returns success after a diagnostic timeout and preserves partial evidence identity' {
        Mock Save-GuestDiagnostic -ModuleName Test.SequenceHandler {
            return @{
                success = $false; diagnosticOutcome = 'timeout'; mechanism = 'key'
                attempted = @('key-ssh'); exitCode = -1; bytes = 42L; skipped = $false
                reason = "Tempo esgotado `u{2014} `u{8a3a}`u{65ad}"; outPath = "partial-`u{e9}.txt"
                hostSnapshot = @{ Status = 'available'; Path = 'host.json' }
                guestSnapshot = @{ diagnosticOutcome = 'partial'; outPath = 'sample.txt' }
            }
        }
        $context = New-DiagnosticStepContext

        $result = Invoke-SequenceActionHandler -Name saveSystemDiagnostic -Context $context

        Assert-True $result 'An incomplete diagnostic must allow the next sequence step to run.'
        Assert-Equal 'timeout' $context.DiagnosticOutcome 'The diagnostic outcome is independent of workload success.'
        Assert-Equal 1 $script:diagnosticEvents.Count 'A capture publishes exactly one event.'
        $captureEvent = $script:diagnosticEvents[0]
        Assert-Equal 'guest_diagnostic' $captureEvent.event
        Assert-False $captureEvent.success 'The event must retain the failed capture result.'
        Assert-Equal 'timeout' $captureEvent.diagnosticOutcome
        Assert-Equal 42L $captureEvent.bytes
        Assert-Equal "partial-`u{e9}.txt" $captureEvent.outPath
        Assert-Equal "Tempo esgotado `u{2014} `u{8a3a}`u{65ad}" $captureEvent.reason
        Assert-Equal 'step-fixture' $captureEvent.stepInvocationId
        Assert-Equal 'sequence-fixture' $captureEvent.sequenceInvocationId
        Assert-Equal 'available' $captureEvent.hostSnapshot.Status
        Assert-Equal 'partial' $captureEvent.guestSnapshot.diagnosticOutcome
        Should -Invoke Save-GuestDiagnostic -ModuleName Test.SequenceHandler -Times 1 -Exactly -ParameterFilter {
            $StepInvocationId -eq 'step-fixture' -and $SequenceInvocationId -eq 'sequence-fixture'
        }
    }

    It 'continues when diagnostic collection throws and does not reuse a prior outcome' {
        Mock Save-GuestDiagnostic -ModuleName Test.SequenceHandler { throw 'fixture diagnostic unavailable' }
        $context = New-DiagnosticStepContext
        $context.DiagnosticOutcome = 'complete'

        $result = Invoke-SequenceActionHandler -Name saveSystemDiagnostic -Context $context -WarningAction SilentlyContinue

        Assert-True $result 'Capture exceptions must remain nonfatal.'
        Assert-Equal 'unavailable' $context.DiagnosticOutcome
        Assert-Equal 0 $script:diagnosticEvents.Count 'An exception must not fabricate a completed capture.'
    }

    It 'continues when the cycle has no artifact folder' {
        Mock Get-CycleGuestDataFolder -ModuleName Test.SequenceHandler { return $null }
        Mock Save-GuestDiagnostic -ModuleName Test.SequenceHandler { throw 'Capture must not run without an artifact folder.' }
        $context = New-DiagnosticStepContext

        $result = Invoke-SequenceActionHandler -Name saveSystemDiagnostic -Context $context -WarningAction SilentlyContinue

        Assert-True $result
        Assert-Equal 'unavailable' $context.DiagnosticOutcome
        Should -Invoke Save-GuestDiagnostic -ModuleName Test.SequenceHandler -Times 0 -Exactly
    }

    It 'retains a complete capture outcome without changing the step result' {
        Mock Save-GuestDiagnostic -ModuleName Test.SequenceHandler {
            return @{
                success = $true; diagnosticOutcome = 'complete'; mechanism = 'key'
                attempted = @('key-ssh'); exitCode = 0; bytes = 512L; skipped = $false
                reason = $null; outPath = 'complete.txt'
            }
        }
        $context = New-DiagnosticStepContext

        $result = Invoke-SequenceActionHandler -Name saveSystemDiagnostic -Context $context

        Assert-True $result
        Assert-Equal 'complete' $context.DiagnosticOutcome
        Assert-Equal 1 $script:diagnosticEvents.Count
        Assert-True $script:diagnosticEvents[0].success
    }

    It 'rejects a missing capture identifier without starting collection' {
        Mock Save-GuestDiagnostic -ModuleName Test.SequenceHandler { throw 'Capture must not run without an identifier.' }
        $context = New-DiagnosticStepContext -Id ''

        $result = Invoke-SequenceActionHandler -Name saveSystemDiagnostic -Context $context -WarningAction SilentlyContinue

        Assert-False $result 'A malformed step remains a configuration failure.'
        Should -Invoke Save-GuestDiagnostic -ModuleName Test.SequenceHandler -Times 0 -Exactly
    }
}

Describe 'diagnostic timeout outcomes are independent of display language' {
    It 'classifies a typed timeout with localized details and preserved UTF-8 output' {
        $capturePath = Join-Path $TestDrive "diagn`u{f3}stico-`u{8a3a}`u{65ad}.txt"
        $content = "========`nHostname : m`u{e1}quina`n`u{c9}chantillon partiel `u{2014} `u{8a3a}`u{65ad}"
        [IO.File]::WriteAllText($capturePath, $content, [Text.UTF8Encoding]::new($false))
        $oldCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        $oldUiCulture = [Threading.Thread]::CurrentThread.CurrentUICulture
        try {
            foreach ($cultureName in @('en-US', 'pt-BR', 'tr-TR', 'ar-SA', 'zh-CN')) {
                [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($cultureName)
                [Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::GetCultureInfo($cultureName)
                $outcome = & $script:diagnosticModule {
                    param($CapturePath)
                    Get-GuestDiagnosticOutcome -Manifest @{
                        success = $false; timedOut = $true; outPath = $CapturePath
                        reason = "Tempo esgotado `u{2014} `u{8a3a}`u{65ad}"; reasonCode = 'timeout'
                    }
                } $capturePath
                Assert-Equal 'timeout' $outcome "Typed timeout classification must survive culture $cultureName."
            }
            Assert-Equal $content ([IO.File]::ReadAllText($capturePath)) 'Classification must not rewrite evidence.'
        } finally {
            [Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture
            [Threading.Thread]::CurrentThread.CurrentUICulture = $oldUiCulture
        }
    }

    It 'classifies an exceeded total budget without requiring an English reason' {
        $outcome = & $script:diagnosticModule {
            Get-GuestDiagnosticOutcome -Manifest @{
                success = $false; budgetExceeded = $true; outPath = $null
                reason = "`u{8a3a}`u{65ad}`u{3092}`u{4e2d}`u{6b62}`u{3057}`u{307e}`u{3057}`u{305f}"; reasonCode = 'timeout'
            }
        }
        Assert-Equal 'timeout' $outcome
    }

    It 'uses invariant Gregorian UTC filenames across host cultures' {
        $oldCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            foreach ($cultureName in @('en-US', 'tr-TR', 'ar-SA', 'th-TH', 'zh-CN')) {
                [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($cultureName)
                $before = [datetime]::UtcNow.ToString('yyyy-MM-dd.HH-mm', [Globalization.CultureInfo]::InvariantCulture)
                $fileName = Get-DiagnosticsFileName -Id fixture
                $after = [datetime]::UtcNow.ToString('yyyy-MM-dd.HH-mm', [Globalization.CultureInfo]::InvariantCulture)
                Assert-True ($fileName -in @("$before.system.diagnostic.fixture.txt", "$after.system.diagnostic.fixture.txt")) `
                    "Host culture $cultureName must not change artifact identifiers or their calendar."
            }
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture }
    }

    It 'classifies short samples from typed transport flags rather than localized output' {
        Mock Invoke-GuestEvidenceSsh -ModuleName Test.Diagnostic { return $script:sampleFixture }
        foreach ($case in @(
            @{ TimedOut = $true; DrainTimedOut = $false; Expected = 'timeout'; Text = "Tempo esgotado `u{8a3a}`u{65ad}" },
            @{ TimedOut = $false; DrainTimedOut = $true; Expected = 'timeout'; Text = "`u{8a3a}`u{65ad}" },
            @{ TimedOut = $false; DrainTimedOut = $false; Expected = 'partial'; Text = 'application timeout counter=2' }
        )) {
            $script:sampleFixture = @{
                success = $false; timedOut = $case.TimedOut; drainTimedOut = $case.DrainTimedOut
                exitCode = 124; output = "snapshotUtc=fixture`n$($case.Text)"
            }

            $result = Save-GuestPerformanceSnapshot -VMName fixture-vm -GuestKey guest.ubuntu.server.26 -OutputFolder $TestDrive -TimeoutSeconds 3

            Assert-Equal $case.Expected $result.diagnosticOutcome
            Assert-True ([IO.File]::ReadAllText($result.outPath).Contains($case.Text)) 'Typed classification must preserve original partial output.'
        }
    }

    It 'recognizes a completed localized diagnostic from its invariant problem summary' {
        $capturePath = Join-Path $TestDrive 'localized-summary.txt'
        $summary = @{
            schema = 'yuruna.diagnostic.problems/v1'; count = 1
            byClass = @{ 'DISK.high-usage' = 1 }
            problems = @(@{ class = 'DISK.high-usage'; message = "Disco cheio `u{8a3a}`u{65ad}" })
        } | ConvertTo-Json -Depth 5 -Compress
        $body = "Resumo`n===YURUNA-DIAG-JSON-BEGIN===`n$summary`n===YURUNA-DIAG-JSON-END===`nDiagn`u{f3}stico conclu`u{ed}do."
        [IO.File]::WriteAllText($capturePath, $body, [Text.UTF8Encoding]::new($false))

        $complete = & $script:diagnosticModule {
            param($Path)
            Get-GuestDiagnosticOutcome -Manifest @{ success = $true; timedOut = $false; outPath = $Path }
        } $capturePath
        $partial = & $script:diagnosticModule {
            param($Path)
            Get-GuestDiagnosticOutcome -Manifest @{ success = $false; timedOut = $false; outPath = $Path }
        } $capturePath

        Assert-Equal 'complete' $complete 'Reported guest problems must not make a fully collected diagnostic incomplete.'
        Assert-Equal 'partial' $partial 'A summary must not hide a failed transport.'
    }

    It 'reports an aborted diagnostic section from its stable class with localized error text' {
        $capturePath = Join-Path $TestDrive 'aborted-summary.txt'
        $summary = @{
            schema = 'yuruna.diagnostic.problems/v1'; count = 1
            byClass = @{ 'DIAG.section-aborted' = 1 }
            problems = @(@{ class = 'DIAG.section-aborted'; message = "`u{8a3a}`u{65ad}`u{5931}`u{6557}" })
        } | ConvertTo-Json -Depth 5 -Compress
        [IO.File]::WriteAllText($capturePath, "===YURUNA-DIAG-JSON-BEGIN===`n$summary`n===YURUNA-DIAG-JSON-END===`n`u{8a3a}`u{65ad}`u{5b8c}`u{4e86}")

        $outcome = & $script:diagnosticModule {
            param($Path)
            Get-GuestDiagnosticOutcome -Manifest @{ success = $true; timedOut = $false; outPath = $Path }
        } $capturePath

        Assert-Equal 'partial' $outcome 'A translated footer must not conceal an aborted collection section.'
    }

    It 'rejects malformed or unsupported summaries even when an English completion footer is present' {
        $capturePath = Join-Path $TestDrive 'invalid-summary.txt'
        foreach ($summary in @(
            '{malformed-json',
            '{"schema":"unrecognized/v1","count":0,"byClass":{},"problems":[]}',
            '{"schema":"yuruna.diagnostic.problems/v1","count":0,"byClass":"invalid","problems":[]}'
        )) {
            [IO.File]::WriteAllText($capturePath, "===YURUNA-DIAG-JSON-BEGIN===`n$summary`n===YURUNA-DIAG-JSON-END===`nDiagnostics complete.")

            $outcome = & $script:diagnosticModule {
                param($Path)
                Get-GuestDiagnosticOutcome -Manifest @{ success = $true; timedOut = $false; outPath = $Path }
            } $capturePath

            Assert-Equal 'partial' $outcome 'An invalid machine summary cannot fall back to a success sentence.'
        }
    }

    It 'gives typed timeout priority over a valid completed diagnostic summary' {
        $capturePath = Join-Path $TestDrive 'timedout-summary.txt'
        $summary = '{"schema":"yuruna.diagnostic.problems/v1","count":0,"byClass":{},"problems":[]}'
        [IO.File]::WriteAllText($capturePath, "===YURUNA-DIAG-JSON-BEGIN===`n$summary`n===YURUNA-DIAG-JSON-END===`nDiagnostics complete.")

        $outcome = & $script:diagnosticModule {
            param($Path)
            Get-GuestDiagnosticOutcome -Manifest @{ success = $true; timedOut = $true; outPath = $Path }
        } $capturePath

        Assert-Equal 'timeout' $outcome 'Completion text or summary cannot erase a transport or cleanup timeout.'
    }
}

Describe 'diagnostic collection is isolated behind an enforced process deadline' {
    It 'accepts a completed capture and preserves Unicode context and evidence' {
        $result = Invoke-DiagnosticWorkerFixture -Directory $TestDrive -Mode complete

        Assert-True $result.success
        Assert-Equal 'complete' $result.diagnosticOutcome
        Assert-Equal "m`u{e1}quina-`u{8a3a}`u{65ad}" $result.observedVmName
        Assert-Equal 'pt-BR' $result.observedLocale.EffectiveLocale
        Assert-Equal 'step-worker' $result.stepInvocationId
        Assert-Equal 'sequence-worker' $result.sequenceInvocationId
        Assert-True ($result.bytes -gt 0) 'A completed capture retains its artifact size.'
        Assert-Match 'Diagnostics complete\.' ([IO.File]::ReadAllText($result.outPath))
        Assert-False ([bool]$result.timedOut)
    }

    It 'returns partial artifacts when a real worker stops responding and terminates that worker' {
        $clock = [Diagnostics.Stopwatch]::StartNew()

        $result = Invoke-DiagnosticWorkerFixture -Directory $TestDrive -Mode checkpoint-timeout -TimeoutSeconds 2

        Assert-True ($clock.Elapsed.TotalSeconds -lt 6) 'A hung worker must not hold the sequence beyond bounded cleanup.'
        Assert-False $result.success
        Assert-True $result.timedOut
        Assert-True $result.budgetExceeded
        Assert-Equal 'diagnostic-deadline-exceeded' $result.reasonCode
        Assert-Equal 'timeout' $result.diagnosticOutcome
        Assert-Match 'Partial' ([IO.File]::ReadAllText($result.outPath))
        Assert-Equal 'available' $result.hostSnapshot.Status
        Assert-Equal 'partial' $result.guestSnapshot.diagnosticOutcome
        Assert-Equal 'step-worker' $result.stepInvocationId
        $workerProcessId = [int][IO.File]::ReadAllText((Join-Path $TestDrive 'worker.pid'))
        Assert-Null (Get-Process -Id $workerProcessId -ErrorAction SilentlyContinue) 'The timed-out worker must not continue alongside later sequence steps.'
    }

    It 'accepts a valid capture even when unrelated worker logging reaches the output limit' {
        $result = Invoke-DiagnosticWorkerFixture -Directory $TestDrive -Mode complete-noisy

        Assert-True $result.success
        Assert-Equal 'complete' $result.diagnosticOutcome
        Assert-True $result.worker.outputTruncated 'The fixture must exercise truncated worker logging.'
        Assert-Match 'Diagnostics complete\.' ([IO.File]::ReadAllText($result.outPath))
    }

    It 'reports timeout even if a worker writes a successful result before hanging during cleanup' {
        $result = Invoke-DiagnosticWorkerFixture -Directory $TestDrive -Mode result-then-timeout -TimeoutSeconds 2

        Assert-False $result.success
        Assert-True $result.timedOut
        Assert-Equal 'timeout' $result.diagnosticOutcome
        Assert-Equal 'diagnostic-deadline-exceeded' $result.reasonCode
    }

    It 'returns an explicit timeout when no checkpoint was produced' {
        $result = Invoke-DiagnosticWorkerFixture -Directory $TestDrive -Mode no-output-timeout -TimeoutSeconds 2

        Assert-False $result.success
        Assert-True $result.timedOut
        Assert-Equal 'timeout' $result.diagnosticOutcome
        Assert-Null $result.outPath
    }

    It 'rejects a checkpoint belonging to another capture after timing out' {
        $result = Invoke-DiagnosticWorkerFixture -Directory $TestDrive -Mode stale-checkpoint-timeout -TimeoutSeconds 2

        Assert-False $result.success
        Assert-True $result.timedOut
        Assert-Null $result.outPath 'A stale capture must not be attached to this invocation.'
    }

    It 'returns unavailable for a malformed worker response' {
        $result = Invoke-DiagnosticWorkerFixture -Directory $TestDrive -Mode malformed

        Assert-False $result.success
        Assert-Equal 'diagnostic-worker-failed' $result.reasonCode
        Assert-Equal 'unavailable' $result.diagnosticOutcome
        Assert-Null $result.outPath
    }

    It 'rejects a completed response belonging to another capture' {
        $result = Invoke-DiagnosticWorkerFixture -Directory $TestDrive -Mode stale-result

        Assert-False $result.success
        Assert-Equal 'diagnostic-worker-failed' $result.reasonCode
        Assert-Equal 'unavailable' $result.diagnosticOutcome
        Assert-Null $result.outPath
    }

    It 'rejects a worker response whose success value has the wrong type' {
        $result = Invoke-DiagnosticWorkerFixture -Directory $TestDrive -Mode wrong-result-type

        Assert-False $result.success
        Assert-Equal 'diagnostic-worker-failed' $result.reasonCode
        Assert-Equal 'unavailable' $result.diagnosticOutcome
        Assert-Null $result.outPath
    }

    It 'contains worker exceptions as an unavailable diagnostic' {
        $result = Invoke-DiagnosticWorkerFixture -Directory $TestDrive -Mode exception

        Assert-False $result.success
        Assert-Equal 'diagnostic-worker-failed' $result.reasonCode
        Assert-Equal 'unavailable' $result.diagnosticOutcome
    }

    It 'can repeat timed-out captures without accumulating worker processes' {
        $processIds = [Collections.Generic.List[int]]::new()
        foreach ($attempt in 1..3) {
            $folder = Join-Path $TestDrive "attempt-$attempt"
            [void][IO.Directory]::CreateDirectory($folder)
            $result = Invoke-DiagnosticWorkerFixture -Directory $folder -Mode no-output-timeout -TimeoutSeconds 2
            Assert-True $result.timedOut
            $processIds.Add([int][IO.File]::ReadAllText((Join-Path $folder 'worker.pid')))
        }
        foreach ($workerProcessId in $processIds) {
            Assert-Null (Get-Process -Id $workerProcessId -ErrorAction SilentlyContinue) 'Every expired capture must release its worker process.'
        }
    }
}

Describe 'password diagnostics use a bounded native client with a child-only credential' {
    It 'keeps the credential out of arguments and preserves the parent environment' {
        $oldPasswordEnvironment = [Environment]::GetEnvironmentVariable('SSHPASS', 'Process')
        $script:nativeInvocation = $null
        Mock Invoke-BoundedNativeCommand -ModuleName Test.Diagnostic {
            param($FilePath, $ArgumentList, $Environment, $TimeoutSeconds, $StreamEncoding)
            $script:nativeInvocation = @{
                FilePath = $FilePath; ArgumentList = $ArgumentList; Environment = $Environment
                TimeoutSeconds = $TimeoutSeconds; Encoding = $StreamEncoding.WebName
                ParentPassword = [System.Environment]::GetEnvironmentVariable('SSHPASS', 'Process')
            }
            return @{ Started = $true; ExitCode = 0; StdOut = 'diagnostic output'; StdErr = '' }
        }
        try {
            [Environment]::SetEnvironmentVariable('SSHPASS', 'parent-fixture-value', 'Process')
            $result = & $script:diagnosticModule {
                Invoke-RemoteDiagnosticsPasswordSsh -User fixture -Address 192.0.2.10 `
                    -Password "secret with spaces `u{8a3a}`u{65ad} `" ' `$ ;" -SshpassPath 'fixture sshpass' -TimeoutSeconds 7 `
                    -BootstrapUrl 'http://192.0.2.1:8080'
            }

            Assert-True $result.success
            Assert-Equal 'password' $result.mechanism
            Assert-Equal 'diagnostic output' $result.output
            Assert-Equal 'fixture sshpass' $script:nativeInvocation.FilePath
            Assert-Equal 7 $script:nativeInvocation.TimeoutSeconds
            Assert-Equal 'utf-8' $script:nativeInvocation.Encoding
            Assert-Equal 'parent-fixture-value' $script:nativeInvocation.ParentPassword
            Assert-Equal 'parent-fixture-value' ([Environment]::GetEnvironmentVariable('SSHPASS', 'Process'))
            Assert-Equal "secret with spaces `u{8a3a}`u{65ad} `" ' `$ ;" $script:nativeInvocation.Environment.SSHPASS
            Assert-False (($script:nativeInvocation.ArgumentList -join '|').Contains('secret with spaces')) 'The secret belongs only to the spawned client environment.'
            Assert-Equal '-e' $script:nativeInvocation.ArgumentList[0]
            Assert-Equal 'ssh' $script:nativeInvocation.ArgumentList[1]
            Assert-Equal 'fixture@192.0.2.10' $script:nativeInvocation.ArgumentList[-2]
            Assert-Match 'http://192\.0\.2\.1:8080/yuruna-repo/' $script:nativeInvocation.ArgumentList[-1]
        } finally {
            [Environment]::SetEnvironmentVariable('SSHPASS', $oldPasswordEnvironment, 'Process')
        }
    }

    It 'preserves partial stdout and stderr when password SSH times out' {
        Mock Invoke-BoundedNativeCommand -ModuleName Test.Diagnostic {
            return @{
                Started = $true; ExitCode = 124; StdOut = "partial stdout`n"; StdErr = 'partial stderr'
                TimedOut = $true; DrainTimedOut = $false; KillFailed = $false; OutputTruncated = $false
            }
        }

        $result = & $script:diagnosticModule {
            Invoke-RemoteDiagnosticsPasswordSsh -User fixture -Address 192.0.2.10 -Password fixture-value `
                -SshpassPath fixture-sshpass -TimeoutSeconds 1
        }

        Assert-False $result.success
        Assert-True $result.timedOut
        Assert-Match 'partial stdout' $result.output
        Assert-Match 'partial stderr' $result.output
    }

    It 'does not report a complete capture when inherited output pipes remain open' {
        Mock Invoke-BoundedNativeCommand -ModuleName Test.Diagnostic {
            return @{
                Started = $true; ExitCode = 0; StdOut = 'partial stdout'; StdErr = ''
                TimedOut = $false; DrainTimedOut = $true; KillFailed = $false; OutputTruncated = $false
            }
        }

        $result = & $script:diagnosticModule {
            Invoke-RemoteDiagnosticsPasswordSsh -User fixture -Address 192.0.2.10 -Password fixture-value `
                -SshpassPath fixture-sshpass -TimeoutSeconds 1
        }

        Assert-False $result.success
        Assert-True $result.drainTimedOut
        Assert-Equal 'partial stdout' $result.output
    }
}

Describe 'the supervised capture retains invocation identity in its final manifest' {
    It 'passes the locale and sample context to the worker and writes an invocation-specific timeout manifest' {
        $script:workerRequest = $null
        Mock Get-YurunaOperatorLocale -ModuleName Test.Diagnostic {
            return @{ EffectiveLocale = 'pt-BR'; RequestedLocale = 'pt-BR'; Direction = 'ltr' }
        }
        Mock Invoke-GuestDiagnosticWorker -ModuleName Test.Diagnostic {
            param($Request, $TimeoutSeconds)
            $script:workerRequest = $Request
            Assert-True ($TimeoutSeconds -gt 0)
            return @{
                success = $false; diagnosticOutcome = 'timeout'; timedOut = $true; budgetExceeded = $true
                outPath = $null; reasonCode = 'diagnostic-deadline-exceeded'; reason = "Tempo esgotado `u{8a3a}`u{65ad}"
                hostSnapshot = $Request.HostSnapshot; guestSnapshot = @{ diagnosticOutcome = 'partial'; outPath = 'short.txt' }
            }
        }
        $sample = @{ Status = 'available'; Path = 'host.json' }

        $result = Save-GuestDiagnostic -VMName "m`u{e1}quina" -GuestKey guest.ubuntu.server.26 -OutputFolder $TestDrive `
            -Id fixture -StepInvocationId step-final -SequenceInvocationId sequence-final -HostSnapshot $sample

        Assert-False $result.success
        Assert-Equal 'timeout' $result.diagnosticOutcome
        Assert-Equal 'pt-BR' $script:workerRequest.OperatorLocaleContext.EffectiveLocale
        Assert-Equal 'host.json' $script:workerRequest.HostSnapshot.Path
        Assert-Equal 'step-final' $script:workerRequest.StepInvocationId
        Assert-Equal 'sequence-final' $script:workerRequest.SequenceInvocationId
        $path = Join-Path $TestDrive ($script:workerRequest.DiagnosticsFileName -replace '\.txt$', '.manifest.json')
        $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable
        Assert-Equal 'step-final' $saved.stepInvocationId
        Assert-Equal 'sequence-final' $saved.sequenceInvocationId
        Assert-Equal 'diagnostic-deadline-exceeded' $saved.reasonCode
        Assert-Equal "Tempo esgotado `u{8a3a}`u{65ad}" $saved.reason
        Assert-True $saved.budgetExceeded
        Assert-Equal 'partial' $saved.guestSnapshot.diagnosticOutcome
    }
}

Describe 'the production diagnostic worker starts without a host or guest dependency' {
    It 'loads its real modules and returns a skipped capture for an unsupported guest' {
        $workerPath = Join-Path $PSScriptRoot '../Invoke-GuestDiagnosticWorker.ps1'
        $workingDirectory = (Get-Location).ProviderPath
        $localeContext = Get-YurunaOperatorLocale

        $result = & $script:diagnosticModule {
            param($WorkerPath, $Directory, $WorkingDirectory, $LocaleContext)
            $priorWorkerPath = $script:GuestDiagnosticWorkerPath
            try {
                $script:GuestDiagnosticWorkerPath = $WorkerPath
                Invoke-GuestDiagnosticWorker -Request @{
                    VMName = 'fixture-unsupported'; GuestKey = 'guest.windows.fixture'
                    OutputFolder = $Directory; Id = 'unsupported'
                    StepInvocationId = 'step-bootstrap'; SequenceInvocationId = 'sequence-bootstrap'
                    HostSnapshot = @{ Status = 'available'; Path = 'host-fixture.json' }
                    WorkingDirectory = $WorkingDirectory; HostModulePath = $null
                    GuestSshUserOverrides = @{}; ProvenGuestAddress = @{}
                    OperatorLocaleContext = $LocaleContext
                    DiagnosticsFileName = 'fixture.system.diagnostic.unsupported.txt'
                    TimeoutSeconds = 15; PerCommandTimeoutSeconds = 5
                } -TimeoutSeconds 15
            } finally {
                $script:GuestDiagnosticWorkerPath = $priorWorkerPath
            }
        } $workerPath $TestDrive $workingDirectory $localeContext

        Assert-False $result.success
        Assert-True $result.skipped "An unsupported guest must return the normal precondition result: $($result.reason)"
        Assert-Equal 0 $result.worker.exitCode 'The real worker must exit cleanly after returning its manifest.'
        Assert-False $result.worker.timedOut
        Assert-Equal 'unavailable' $result.diagnosticOutcome
        Assert-Equal 'unavailable' $result.guestSnapshot.diagnosticOutcome
        Assert-Equal 'host-fixture.json' $result.hostSnapshot.Path
        Assert-Equal 'step-bootstrap' $result.stepInvocationId
        Assert-Equal 'sequence-bootstrap' $result.sequenceInvocationId
    }

    It 'rehydrates driver locale user and address context without changing the parent driver' {
        $parentDriver = New-Module -Name DiagnosticParentDriver -ScriptBlock {
            $script:HostTag = 'parent-driver-context'
            function Get-DiagnosticFixtureHostTag {
                <# .SYNOPSIS
                    Returns the parent driver's in-memory context for isolation checks.
                #>
                return $script:HostTag
            }
            Export-ModuleMember -Function Get-DiagnosticFixtureHostTag
        }
        Import-Module $parentDriver -Global
        try {
            $result = Invoke-ProductionDiagnosticWorkerFixture -Directory $TestDrive -Mode complete

            Assert-True $result.success "The real worker must complete: $($result.reason)"
            Assert-Equal 'complete' $result.diagnosticOutcome
            Assert-Equal 'child-driver-context' $result.fixtureHostTag
            Assert-Equal (Get-YurunaOperatorLocale).EffectiveLocale $result.fixtureLocale.EffectiveLocale
            Assert-Equal 'fixture-user' $result.fixtureUser
            Assert-Equal '192.0.2.10' $result.fixtureAddress
            Assert-Equal 'parent-driver-context' (Get-DiagnosticFixtureHostTag)
            Assert-Null (Get-Module DiagnosticHostFixture) 'The child driver must not be imported into the sequence process.'
        } finally { Remove-Module $parentDriver -Force }
    }

    It 'bounds a sampling provider that stops responding before the full diagnostic begins' {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-ProductionDiagnosticWorkerFixture -Directory $TestDrive -Mode sampling-timeout -TimeoutSeconds 4

        Assert-True ($clock.Elapsed.TotalSeconds -lt 7)
        Assert-True (Test-Path -LiteralPath (Join-Path $TestDrive 'sampling.started')) "The fixture must reach the blocking sample provider: $($result.reason)"
        Assert-True $result.timedOut
        Assert-Equal 'timeout' $result.diagnosticOutcome
        Assert-Equal 'host-fixture.json' $result.hostSnapshot.Path
        Assert-Equal 'step-actual' $result.stepInvocationId
    }

    It 'preserves failed SSH output before a later console fallback stops responding' {
        $result = Invoke-ProductionDiagnosticWorkerFixture -Directory $TestDrive -Mode console-timeout -TimeoutSeconds 4

        Assert-True (Test-Path -LiteralPath (Join-Path $TestDrive 'console.started')) "The real capture ladder must reach its console fallback: $($result.reason)"
        Assert-True $result.timedOut
        Assert-Equal 'timeout' $result.diagnosticOutcome
        Assert-Equal 'key' $result.mechanism
        Assert-Match 'Partial SSH fixture' ([IO.File]::ReadAllText($result.outPath))
        Assert-Equal 'fixture.system.diagnostic.actual.key-ssh.txt' (Split-Path -Leaf $result.outPath) 'Failed SSH output lives in that rung''s own file.'
        Assert-Equal 'key-ssh' $result.rungEvidence[0].rung
        Assert-Equal 'host-fixture.json' $result.hostSnapshot.Path
        Assert-Equal 'partial' $result.guestSnapshot.diagnosticOutcome
        Assert-Equal 'key-ssh,console' ($result.attempted -join ',')
    }
}

Describe 'a later rung cannot overwrite the evidence an earlier rung left' {
    It 'keeps failed SSH output beside the console capture that succeeded after it' {
        $result = Invoke-ProductionDiagnosticWorkerFixture -Directory $TestDrive -Mode console-after-ssh

        $mainPath = Join-Path $TestDrive 'fixture.system.diagnostic.actual.txt'
        $evidencePath = Join-Path $TestDrive 'fixture.system.diagnostic.actual.key-ssh.txt'
        $uploadName = 'fixture.system.diagnostic.actual.console.txt'
        Assert-True $result.success "The console rung must succeed after the SSH rung failed: $($result.reason)"
        Assert-Equal 'console' $result.mechanism
        Assert-Equal 'complete' $result.diagnosticOutcome
        Assert-Equal 'key-ssh,console' ($result.attempted -join ',')
        Assert-Equal $uploadName ([IO.File]::ReadAllText((Join-Path $TestDrive 'console.upload-name'))) 'The guest must upload under the console rung''s own name.'
        Assert-False (Test-Path -LiteralPath (Join-Path $TestDrive $uploadName)) 'A capture that arrived in time is promoted to the main name.'
        Assert-Equal $mainPath $result.outPath
        Assert-Match 'Console capture fixture' ([IO.File]::ReadAllText($mainPath))
        Assert-Equal "========`nPartial SSH fixture" ([IO.File]::ReadAllText($evidencePath)) 'The console capture must not replace the SSH rung''s output.'
        Assert-Equal 1 @($result.rungEvidence).Count
        Assert-Equal 'key-ssh' $result.rungEvidence[0].rung
        Assert-Equal $evidencePath $result.rungEvidence[0].path
        Assert-Equal 124 $result.rungEvidence[0].exitCode
        Assert-True $result.rungEvidence[0].timedOut
    }

    It 'leaves a console upload that arrives after the rung gave up out of the main capture' {
        $result = Invoke-ProductionDiagnosticWorkerFixture -Directory $TestDrive -Mode console-late

        $mainPath = Join-Path $TestDrive 'fixture.system.diagnostic.actual.txt'
        $uploadPath = Join-Path $TestDrive 'fixture.system.diagnostic.actual.console.txt'
        $evidencePath = Join-Path $TestDrive 'fixture.system.diagnostic.actual.key-ssh.txt'
        Assert-False $result.success
        Assert-Equal 'key' $result.mechanism 'With every rung failed, the fuller SSH output is the capture.'
        Assert-Equal $mainPath $result.outPath
        Assert-Match 'Partial SSH fixture' ([IO.File]::ReadAllText($mainPath))
        Assert-False ([IO.File]::ReadAllText($mainPath).Contains('Console capture fixture')) 'A late upload must not replace the main capture.'
        Assert-Match 'Console capture fixture' ([IO.File]::ReadAllText($uploadPath)) 'The late upload is kept under its own name.'
        Assert-Equal "========`nPartial SSH fixture" ([IO.File]::ReadAllText($evidencePath))
    }
}

Describe 'diagnostic SSH rungs keep a report larger than the partial-output default' {
    BeforeAll {
        $script:DiagnosticCap = & $script:diagnosticModule { $script:GuestDiagnosticMaxCapturedChars }
        # Larger than the 524288-character partial-output default, as the
        # report of a guest running Kubernetes is.
        $script:LargeReport = "========`n" + [string]::new([char]120, 600000)
    }

    It 'sets a cap the bounded runner accepts and a real report fits inside' {
        Assert-True ($script:DiagnosticCap -ge 4096 -and $script:DiagnosticCap -le 67108864) 'Invoke-BoundedNativeCommand validates this range.'
        Assert-True ($script:DiagnosticCap -gt $script:LargeReport.Length)
    }

    It 'passes the cap to the key SSH rung and keeps the whole report' {
        Mock Get-YurunaSshPrivateKeyPath -ModuleName Test.Ssh { return 'fixture-key' }
        Mock Get-GuestSshUser -ModuleName Test.Ssh { return 'fixture-user' }
        Mock Get-GuestAddress -ModuleName Test.Ssh { return '192.0.2.10' }
        Mock Set-ProvenGuestAddress -ModuleName Test.Ssh { }
        Mock Invoke-BoundedNativeCommand -ModuleName Test.Ssh {
            return @{
                Started = $true; ExitCode = 0; StdOut = $script:LargeReport; StdErr = ''
                TimedOut = $false; DrainTimedOut = $false; OutputTruncated = $false; KillFailed = $false
            }
        }

        $result = & $script:diagnosticModule {
            Invoke-RemoteDiagnosticsKeySsh -VMName fixture-vm -GuestKey guest.ubuntu.server.26 -TimeoutSeconds 5
        }

        Assert-True $result.success
        Assert-Equal $script:LargeReport.Length $result.output.Length
        Should -Invoke Invoke-BoundedNativeCommand -ModuleName Test.Ssh -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'ssh' -and $MaxCapturedChars -gt 524288 -and $MaxCapturedChars -eq $script:DiagnosticCap
        }
    }

    It 'passes the cap to the password SSH rung and keeps the whole report' {
        Mock Invoke-BoundedNativeCommand -ModuleName Test.Diagnostic {
            return @{
                Started = $true; ExitCode = 0; StdOut = $script:LargeReport; StdErr = ''
                TimedOut = $false; DrainTimedOut = $false; OutputTruncated = $false; KillFailed = $false
            }
        }

        $result = & $script:diagnosticModule {
            Invoke-RemoteDiagnosticsPasswordSsh -User fixture -Address 192.0.2.10 -Password fixture-value `
                -SshpassPath fixture-sshpass -TimeoutSeconds 5
        }

        Assert-True $result.success
        Assert-Equal $script:LargeReport.Length $result.output.Length
        Should -Invoke Invoke-BoundedNativeCommand -ModuleName Test.Diagnostic -Times 1 -Exactly -ParameterFilter {
            $MaxCapturedChars -gt 524288 -and $MaxCapturedChars -eq $script:DiagnosticCap
        }
    }
}
