<#PSScriptInfo
.VERSION 2026.10.18.1
.GUID 420a1aa7-8b02-47f6-a89d-1a0d0b35585e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test diagnostics clocks hyper-v arm64 pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES Pester
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Diagnostic.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Test.HostSampling.psm1') -Global -Force
    Import-Module (Join-Path $PSScriptRoot 'Test.EventSchema.psm1') -Global -Force
    $script:clockModule = Get-Module Test.Diagnostic
    # Captured before any Mock: a filtered mock alone fails the calls its
    # filter does not match, and this suite relies on the real command there.
    $script:RealTestPath = Get-Command Test-Path -CommandType Cmdlet
    # --- REGION: Get-ClockFixtureText
    function Get-ClockFixtureText {
        param([string]$Boot='11111111-1111-1111-1111-111111111111', [double]$Uptime=100,
            [long]$Idle0=4000, [long]$Idle1=5000, [long]$User=1000, [long]$Iowait=100, [double]$Epoch=1700000000, [long]$Guest=0)
        return @"
--- YURUNA CLOCK SAMPLE ---
guestEvidenceSchema=2
guestBootId=$Boot
guestClockEpochSeconds=$($Epoch.ToString([Globalization.CultureInfo]::InvariantCulture))
guestClockUptimeSeconds=$($Uptime.ToString([Globalization.CultureInfo]::InvariantCulture))
guestClockTicksPerSecond=100
guestOnlineCpus=0-1
--- /proc/stat ---
state=read (bounded prefix)
cpu 2000 0 1000 $($Idle0+$Idle1) $($Iowait*2) 0 0 0 0 0
cpu0 $User 0 500 $Idle0 $Iowait 0 0 0 $Guest 0
cpu1 $User 0 500 $Idle1 $Iowait 0 0 0 $Guest 0
btime 1699999900
procs_running 1
procs_blocked 0
--- /proc/uptime ---
$Uptime 90
"@
    }
    # --- REGION: Read-ClockFixture
    function Read-ClockFixture {
        param([string]$Text)
        return & $script:clockModule { param($t) ConvertFrom-GuestClockEvidence -Text $t } $Text
    }
    # --- REGION: Get-ClockFixtureAnalysis
    function Get-ClockFixtureAnalysis {
        param([hashtable[]]$Samples,[hashtable]$Previous,[hashtable]$Clock)
        return & $script:clockModule { param($s,$p,$c) Get-GuestClockAccountingAnalysis -Samples $s -Previous $p -HostClock $c } $Samples $Previous $Clock
    }
    $script:handlerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Test.SequenceHandler.psm1'),[ref]$null,[ref]$null)
}

Describe 'Raw guest clock evidence parsing' {
    It 'emits one typed array for <InputCount> input samples without flattening or losing an empty result' -ForEach @(
        @{ InputCount=0 }, @{ InputCount=1 }, @{ InputCount=2 }, @{ InputCount=5 }
    ) {
        $blocks=for ($index=0; $index -lt $InputCount; $index++) {
            Get-ClockFixtureText -Uptime (100+$index)
        }
        $text=$blocks -join "`n"
        $emissions=@(& $script:clockModule { param($t) ConvertFrom-GuestClockEvidence -Text $t } $text)
        $emissions.Count | Should -Be 1
        ($emissions[0] -is [hashtable[]]) | Should -BeTrue
        $expectedCount=[math]::Min($InputCount,4)
        $emissions[0].Count | Should -Be $expectedCount
        for ($index=0; $index -lt $expectedCount; $index++) {
            $emissions[0][$index].valid | Should -BeTrue
            $emissions[0][$index].uptimeSeconds | Should -Be (100+$index)
        }
    }

    It 'retains per-CPU raw ticks and numeric clock values under a non-English culture' {
        $oldCulture=[Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo('pt-BR')
            $samples=Read-ClockFixture (Get-ClockFixtureText -Uptime 100.25)
            $samples.Count | Should -Be 1
            $samples[0].valid | Should -BeTrue
            $samples[0].uptimeSeconds | Should -Be 100.25
            $samples[0].cpus.cpu1[3] | Should -Be 5000
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture=$oldCulture }
    }

    It 'accepts historical missing schema as unavailable evidence without inventing counters' {
        $samples=Read-ClockFixture "snapshotUtc=old`n--- /proc/stat ---`ncpu0 10 0 0 20 0"
        $samples.Count | Should -Be 0
        $analysis=Get-ClockFixtureAnalysis $samples
        $analysis.sampleCount | Should -Be 0
        $analysis.validSampleCount | Should -Be 0
        $analysis.comparison | Should -Be unavailable
    }

    It 'rejects incomplete, malformed, non-finite and duplicate metadata' {
        foreach ($text in @(
            ((Get-ClockFixtureText) -replace 'guestBootId=[^\n]+','guestBootId=not-a-boot'),
            ((Get-ClockFixtureText) -replace 'guestClockUptimeSeconds=100','guestClockUptimeSeconds=NaN'),
            ((Get-ClockFixtureText) -replace 'guestClockTicksPerSecond=100','guestClockTicksPerSecond=0'),
            ((Get-ClockFixtureText) -replace '--- /proc/stat ---[\s\S]*','--- /proc/stat ---'),
            ((Get-ClockFixtureText)+"`nguestClockTicksPerSecond=100"),
            ((Get-ClockFixtureText) -replace '(?m)^cpu1.*\n',''),
            ((Get-ClockFixtureText) -replace '(?m)^procs_running.*\n',''),
            ((Get-ClockFixtureText) -replace 'guestOnlineCpus=0-1','guestOnlineCpus=0-9999999999')
        )) {
            $samples=Read-ClockFixture $text
            $samples[0].valid | Should -BeFalse
            ((Get-ClockFixtureAnalysis $samples).warnings.code) | Should -Contain clock-evidence-incomplete
        }
    }

    It 'reads flight-recorder samples by their sampleUtc boundary and sorts the ring into time order' {
        $late = (Get-ClockFixtureText -Uptime 347 -Idle0 4040050 -Idle1 16662) -replace '^--- YURUNA CLOCK SAMPLE ---', 'sampleUtc=2026-10-14T22:30:08Z'
        $early = (Get-ClockFixtureText -Uptime 314 -Idle0 17515 -Idle1 15227) -replace '^--- YURUNA CLOCK SAMPLE ---', 'sampleUtc=2026-10-14T22:29:36Z'
        # Ring slots wrap, so the newer sample can sit first in the upload.
        $upload = "recorderSchema=1`nheartbeatUtc=2026-10-14T22:32:32Z`n" + $late + "`n" + $early + "`n--- independent kernel evidence ---`n[  508.780691] rcu: INFO`n"
        # The parser emits one array object; assign rather than wrap, as the
        # production readers do, so the count is the samples and not the array.
        $samples = Read-ClockFixture -Text $upload
        @($samples).Count | Should -Be 2
        $samples[0].uptimeSeconds | Should -Be 347
        $samples[1].valid | Should -BeTrue
        $path = Join-Path $TestDrive 'execution.system.diagnostic.recorder.txt'
        [IO.File]::WriteAllText($path, $upload)
        $analysis = & $script:clockModule { param($p) Get-GuestRecorderClockAnalysis -Path $p } $path
        $analysis.sampleCount | Should -Be 2
        $analysis.comparison | Should -Be 'same-boot'
        @($analysis.warnings | ForEach-Object { $_.code }) | Should -Contain 'cpu-idle-exceeds-boot-uptime'
        $analysis.advisoryOnly | Should -BeTrue
        (& $script:clockModule { param($p) Get-GuestRecorderClockAnalysis -Path $p } (Join-Path $TestDrive 'absent.txt')).sampleCount | Should -Be 0
    }
    It 'does not parse cpu-looking lines outside the raw stat section' {
        $samples=Read-ClockFixture ((Get-ClockFixtureText)+"`n--- thread command ---`ncpu9 1 2 3 9999999999")
        $samples[0].cpus.Count | Should -Be 2
    }
}

Describe 'Advisory clock and CPU accounting analysis' {
    It 'accepts normal two-CPU sums, overlapping guest time, and decreasing Linux iowait' {
        $samples=Read-ClockFixture ((Get-ClockFixtureText -Idle0 8000 -Idle1 9000)+"`n"+(Get-ClockFixtureText -Uptime 110 -Idle0 8800 -Idle1 9800 -User 1100 -Iowait 50 -Epoch 1700000010))
        $analysis=Get-ClockFixtureAnalysis $samples
        $analysis.warnings.Count | Should -Be 0
        $analysis.comparison | Should -Be same-boot
        $analysis.advisoryOnly | Should -BeTrue
    }

    It 'validates each CPU total separately and does not double-count overlapping guest time' {
        $samples=Read-ClockFixture ((Get-ClockFixtureText -User 8000 -Guest 8000 -Idle0 1000 -Idle1 2000)+"`n"+
            (Get-ClockFixtureText -Uptime 110 -User 8900 -Guest 8900 -Idle0 1050 -Idle1 2050 -Epoch 1700000010))
        $analysis=Get-ClockFixtureAnalysis $samples
        $analysis.warnings.Count | Should -Be 0
    }

    It 'detects excessive accounted CPU time even when no individual idle delta is excessive' {
        $samples=Read-ClockFixture ((Get-ClockFixtureText)+"`n"+
            (Get-ClockFixtureText -Uptime 110 -User 1800 -Idle0 4800 -Idle1 5800 -Epoch 1700000010))
        $analysis=Get-ClockFixtureAnalysis $samples
        $analysis.warnings.code | Should -Contain cpu-accounted-delta-exceeds-elapsed
        $analysis.warnings.code | Should -Not -Contain cpu-idle-delta-exceeds-elapsed
    }

    It 'allows suspend time to advance boottime faster than monotonic and skips unavailable optional clocks' {
        $first=(Get-ClockFixtureText)+"`nguestClockMonotonicSeconds=98`nguestClockBoottimeSeconds=100"
        $second=(Get-ClockFixtureText -Uptime 110 -Idle0 4500 -Idle1 5500 -Epoch 1700000010)+"`nguestClockMonotonicSeconds=99`nguestClockBoottimeSeconds=110"
        (Get-ClockFixtureAnalysis (Read-ClockFixture ($first+"`n"+$second))).warnings.Count | Should -Be 0
        $unavailable=(Get-ClockFixtureText)+"`nguestClockMonotonicSeconds=unavailable`nguestClockBoottimeSeconds=unavailable"
        (Get-ClockFixtureAnalysis (Read-ClockFixture $unavailable)).warnings.Count | Should -Be 0
    }

    It 'reports optional clock decreases and disagreement with boottime uptime' {
        $first=(Get-ClockFixtureText)+"`nguestClockMonotonicSeconds=98`nguestClockBoottimeSeconds=100"
        $second=(Get-ClockFixtureText -Uptime 110 -Idle0 4500 -Idle1 5500 -Epoch 1700000010)+"`nguestClockMonotonicSeconds=97`nguestClockBoottimeSeconds=120"
        $analysis=Get-ClockFixtureAnalysis (Read-ClockFixture ($first+"`n"+$second))
        $analysis.warnings.code | Should -Contain guest-monotonic-clock-decreased
        $analysis.warnings.code | Should -Contain guest-boottime-uptime-mismatch
        $analysis.warnings.code | Should -Contain guest-boottime-clock-delta-inconsistent
    }

    It 'detects impossible per-CPU idle and idle deltas captured in the same boot' {
        $samples=Read-ClockFixture ((Get-ClockFixtureText -Uptime 472.21 -Idle0 67369420 -Idle1 27879)+"`n"+
            (Get-ClockFixtureText -Uptime 503.63 -Idle0 67369420 -Idle1 67369435 -Epoch 1700000031.42))
        $analysis=Get-ClockFixtureAnalysis $samples
        $analysis.warnings.code | Should -Contain cpu-idle-exceeds-boot-uptime
        $analysis.warnings.code | Should -Contain cpu-idle-delta-exceeds-elapsed
        ($analysis.warnings | Where-Object code -eq cpu-idle-delta-exceeds-elapsed).cpu | Should -Be cpu1
    }

    It 'reports monotonic CPU counter resets and uptime decreases without failing a workload' {
        $samples=Read-ClockFixture ((Get-ClockFixtureText)+"`n"+(Get-ClockFixtureText -Uptime 90 -Idle0 1000 -User 500))
        $analysis=Get-ClockFixtureAnalysis $samples
        $analysis.warnings.code | Should -Contain cpu-counter-decreased
        $analysis.warnings.code | Should -Contain guest-uptime-decreased
        $analysis.advisoryOnly | Should -BeTrue
    }

    It 'never subtracts CPU counters or uptime across a reboot, and still checks the new boot' {
        $previous=@{samples=(Read-ClockFixture (Get-ClockFixtureText -Uptime 2000 -Idle0 90000 -Idle1 95000))}
        $boot='22222222-2222-2222-2222-222222222222'
        $samples=Read-ClockFixture ((Get-ClockFixtureText -Boot $boot -Uptime 10 -Idle0 300 -Idle1 400)+"`n"+
            (Get-ClockFixtureText -Boot $boot -Uptime 11 -Idle0 67369420 -Idle1 500 -Epoch 1700000001))
        $analysis=Get-ClockFixtureAnalysis $samples $previous
        $analysis.comparison | Should -Be reboot-boundary
        $analysis.warnings.code | Should -Not -Contain cpu-counter-decreased
        $analysis.warnings.code | Should -Not -Contain guest-uptime-decreased
        $analysis.warnings.code | Should -Contain cpu-idle-delta-exceeds-elapsed
    }

    It 'compares the same boot against the host QPC bracket and isolates wall-clock steps' {
        $previous=@{samples=(Read-ClockFixture (Get-ClockFixtureText));hostClock=@{beforeTicks=1000;afterTicks=1200;frequency=100}}
        $samples=Read-ClockFixture (Get-ClockFixtureText -Uptime 130 -Idle0 5000 -Idle1 6000 -Epoch 1700000200)
        $analysis=Get-ClockFixtureAnalysis -Samples $samples -Previous $previous -Clock @{beforeTicks=2200;afterTicks=2400;frequency=100}
        $analysis.warnings.code | Should -Contain guest-host-monotonic-discontinuity
        $analysis.warnings.code | Should -Contain guest-wall-clock-discontinuity
    }
}

Describe 'Bounded observe-only CPU restart capture' {
    It 'runs the native two-sample clock collector through the real SSH transport within its five-second budget' -Skip:(-not $IsLinux) {
        $bin=Join-Path $TestDrive 'clock-ssh-bin'
        [void][IO.Directory]::CreateDirectory($bin)
        $ssh=Join-Path $bin 'ssh'
        [IO.File]::WriteAllText($ssh, @'
#!/bin/bash
exec bash -c "${@: -1}"
'@)
        & chmod +x $ssh
        Mock 'Test.Ssh\Get-ProvenGuestAddress' -ModuleName Test.Diagnostic { return '127.0.0.1' }
        Mock Test-Path -ModuleName Test.Diagnostic { & $script:RealTestPath @PesterBoundParameters }
        Mock Test-Path -ModuleName Test.Diagnostic -ParameterFilter { $LiteralPath -like '*yuruna_ed25519' } { return $true }
        Mock Save-HyperVCpuRestartHostContext -ModuleName Test.Diagnostic { return @{status='complete';settings=@{processorCount=2}} }
        $oldPath=$env:PATH
        try {
            $env:PATH=$bin+[IO.Path]::PathSeparator+$oldPath
            $clock=[Diagnostics.Stopwatch]::StartNew()
            $capture=Save-GuestCpuRestartEvidence -VMName clock-vm -GuestKey guest.ubuntu.server.26 -OutputFolder $TestDrive -Phase after-cpu-restart
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 5
            $capture.diagnosticOutcome | Should -Be complete
            $capture.analysis.validSampleCount | Should -Be 2
            $capture.analysis.warnings.Count | Should -Be 0
            $capture.samples[1].uptimeSeconds | Should -BeGreaterThan $capture.samples[0].uptimeSeconds
        } finally { $env:PATH=$oldPath }
    }

    It 'uses the existing address only and retains raw and structured evidence alongside effective host settings' {
        $script:clockOutput=(Get-ClockFixtureText)+"`n"+(Get-ClockFixtureText -Uptime 101 -Idle0 4050 -Idle1 5050 -Epoch 1700000001)+"`nsnapshotCompleteUtc=fixture"
        Mock Invoke-GuestEvidenceSsh -ModuleName Test.Diagnostic {
            param($VMName,$GuestKey,$Command,$TimeoutSeconds,$MaxCapturedChars,$ProvenAddressOnly)
            $null=$VMName;$null=$GuestKey;$null=$MaxCapturedChars
            $script:observedClockCommand=$Command; $script:clockTimeout=$TimeoutSeconds; $script:provenOnly=$ProvenAddressOnly
            return @{success=$true;exitCode=0;output=$script:clockOutput}
        }
        Mock Save-HyperVCpuRestartHostContext -ModuleName Test.Diagnostic { return @{status='complete';settings=@{processorCount=2}} }
        $capture=Save-GuestCpuRestartEvidence -VMName fixture-vm -GuestKey guest.ubuntu.server.26 -OutputFolder $TestDrive -Phase after-cpu-restart
        $capture.diagnosticOutcome | Should -Be complete
        $capture.samples.Count | Should -Be 2
        $script:clockTimeout | Should -Be 5
        $script:provenOnly | Should -BeTrue
        $script:observedClockCommand | Should -Match 'E_CLOCK_ONLY=1 bash'
        (Get-Content $capture.outPath -Raw) | Should -Match 'cpu0 1000'
        (Get-Content (Join-Path $TestDrive 'guest.cpu-clock.after-cpu-restart.json') -Raw | ConvertFrom-Json).hostContext.settings.processorCount | Should -Be 2
    }

    It 'does not discover an address when no prior SSH address exists' {
        Mock 'Test.Ssh\Get-ProvenGuestAddress' -ModuleName Test.Diagnostic { return '' }
        Mock Test-Path -ModuleName Test.Diagnostic { & $script:RealTestPath @PesterBoundParameters }
        Mock Test-Path -ModuleName Test.Diagnostic -ParameterFilter { $LiteralPath -like '*yuruna_ed25519' } { return $true }
        Mock Invoke-YurunaHostBoundedCommand -ModuleName Test.Diagnostic { throw 'Discovery must not run' }
        $result=& $script:clockModule { Invoke-GuestEvidenceSsh -VMName fixture-vm -GuestKey guest.ubuntu.server.26 -Command true -TimeoutSeconds 3 -ProvenAddressOnly }
        $result.success | Should -BeFalse
        $result.output | Should -Match 'no previously proven'
        Should -Invoke Invoke-YurunaHostBoundedCommand -ModuleName Test.Diagnostic -Times 0
    }

    It 'bounds and safely encodes the read-only Hyper-V settings query and preserves timeout outcomes' {
        Mock Invoke-YurunaHostBoundedCommand -ModuleName Test.Diagnostic {
            param($FilePath,$ArgumentList,$TimeoutSeconds)
            $null=$FilePath
            $script:settingsTimeout=$TimeoutSeconds
            $script:settingsQuery=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgumentList[-1]))
            return [pscustomobject]@{Status='timeout';ExitCode=$null;Output='fixture partial'}
        }
        $context=Save-HyperVCpuRestartHostContext -VMName ("VM 'literal'; "+'$sensitive') -OutputFolder $TestDrive -Phase offline-before-resize
        $context.status | Should -Be timeout
        $script:settingsTimeout | Should -Be 3
        $script:settingsQuery | Should -Match 'Hyper-V\\Get-VMProcessor'
        $script:settingsQuery | Should -Not -Match 'Set-VM|Start-VM|Stop-VM'
        $script:settingsQuery | Should -Not -Match "VM 'literal'"
        Test-Path (Join-Path $TestDrive 'guest.cpu-clock.offline-before-resize.host.json') | Should -BeTrue
    }

    It 'emits a schema-valid advisory event with the cycle envelope and invocation identities' {
        $helper=$script:handlerAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Save-SequenceCpuRestartEvidence'},$true).Extent.Text
        $module=New-Module -ScriptBlock ([scriptblock]::Create(@'
function Test-SequenceCpuClockApplicable { param($Context) $null=$Context; return $true }
function Get-CycleGuestDataFolder { param($VMName) $null=$VMName; return 'fixture-folder' }
function Save-GuestCpuRestartEvidence { return @{diagnosticOutcome='complete';analysis=@{advisoryOnly=$true;warnings=@()};outPath='clock.txt'} }
function Send-CycleEventSafely { param($EventRecord) $script:clockEvent=$EventRecord }
'@+"`n"+$helper))
        $context=@{VMName='fixture-vm';GuestKey='guest.ubuntu.server.26';StepInvocationId='step-fixture';SequenceInvocationId='sequence-fixture'}
        & $module {param($c) Save-SequenceCpuRestartEvidence -Context $c -Phase after-cpu-restart} $context
        $clockEventRecord=& $module { $script:clockEvent }
        $clockEventRecord.event | Should -Be guest_clock_accounting
        $clockEventRecord.advisoryOnly | Should -BeTrue
        $clockEventRecord.stepInvocationId | Should -Be step-fixture
        @(Test-CycleEventSchema -Record $clockEventRecord).Count | Should -Be 0
    }

    It 'keeps the clock action successful when capture throws, with no VM restart or workload replay' {
        $registration=$script:handlerAst.Find({param($n) $n -is [Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Register-SequenceAction' -and $n.Extent.Text.StartsWith("Register-SequenceAction -Name 'saveGuestClockSnapshot'")},$true)
        $handler=($registration.CommandElements | Where-Object {$_ -is [Management.Automation.Language.ScriptBlockExpressionAst]} | Select-Object -Last 1).ScriptBlock.Extent.Text
        $helper=$script:handlerAst.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Save-SequenceCpuRestartEvidence'},$true).Extent.Text
        $module=New-Module -ScriptBlock ([scriptblock]::Create(@'
function Test-SequenceCpuClockApplicable { param($Context) $null=$Context; return $true }
function Get-CycleGuestDataFolder { param($VMName) $null=$VMName; return 'fixture-folder' }
function Save-GuestCpuRestartEvidence { throw 'Owned fixture capture failure' }
'@+"`n"+$helper+"`n"+'function Invoke-ClockAction '+$handler))
        $context=@{Step=@{phase='after-cpu-restart'}}
        (& $module { param($c) Invoke-ClockAction $c } $context) | Should -BeTrue
        $registration.Extent.Text | Should -Match "ReplaySafety 'observe'"
        $handler | Should -Not -Match 'Start-VM|Stop-VM|InvokeStepBlock'
    }
}
