<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42430431-3a59-45e7-9caa-8e653f023904
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test remediation pester
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
    Pester coverage for Invoke-Remediation's inner-cause routing and the
    enriched handler Context (Test.Remediation.psm1).
.DESCRIPTION
    Throw-based assertions (Pester 5+). Uses the real
    built-in recovery handlers so the routing decision is exercised end to end.
#>

BeforeAll {
Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking
$script:PriorRemediationLog = Save-YurunaTestEnvironment -Name 'YURUNA_LOG_DIR'
$env:YURUNA_LOG_DIR = Join-Path $TestDrive 'remediation-log'
$null = New-Item -ItemType Directory -Path $env:YURUNA_LOG_DIR -Force
$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.Remediation.psm1'
Import-Module (Join-Path $here 'Test.FailureTaxonomy.psm1') -Force -DisableNameChecking -Global -ErrorAction SilentlyContinue
Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue
if (Get-Command Register-BuiltinRecoveryHandler -ErrorAction SilentlyContinue) { Register-BuiltinRecoveryHandler }


}

AfterAll {
    Restore-YurunaTestEnvironment -Saved $script:PriorRemediationLog
}

Describe 'Invoke-Remediation inner-cause routing' {
    It 'routes past retry_exhausted to the inner failureClass when an inner handler exists' {
        $rec = @{
            failureClass = 'retry_exhausted'; severity = 'hard'
            innerFailureClass = 'ocr_timeout'; innerSeverity = 'hard'
            innerSuggestedRecoveries = @('reconnect')
            stepNumber = 3; actionVerb = 'retry'
        }
        $r = Invoke-Remediation -FailureRecord $rec
        Assert-Equal -Expected 'ocr_timeout' -Actual $r.FailureClass -Because 'routed to inner class'
        Assert-Equal -Expected 'retry_exhausted' -Actual $r.RoutedFromFailureClass -Because 'outer class preserved'
    }
    It 'stays on the outer class when no inner cause is present' {
        $r = Invoke-Remediation -FailureRecord @{ failureClass = 'retry_exhausted'; severity = 'hard'; stepNumber = 1; actionVerb = 'retry' }
        Assert-Equal -Expected 'retry_exhausted' -Actual $r.FailureClass -Because 'no inner -> outer'
        Assert-True (-not $r.Contains('RoutedFromFailureClass')) 'no routing audit when not routed'
    }
    It 'leaves a non-retry failure class untouched' {
        $r = Invoke-Remediation -FailureRecord @{ failureClass = 'ocr_timeout'; severity = 'hard'; stepNumber = 2 }
        Assert-Equal -Expected 'ocr_timeout' -Actual $r.FailureClass -Because 'plain class unchanged'
    }
    It 'severity follows the routed class (unknown, not the outer value) when innerSeverity is absent' {
        $r = Invoke-Remediation -FailureRecord @{ failureClass = 'retry_exhausted'; severity = 'soft'; innerFailureClass = 'ocr_timeout'; stepNumber = 3 }
        Assert-Equal -Expected 'ocr_timeout' -Actual $r.FailureClass -Because 'routed to inner class'
        Assert-Equal -Expected 'unknown' -Actual $r.Severity -Because 'severity must NOT inherit the outer wrapper value'
    }
    It 'does not self-route when the inner class equals the outer class' {
        $r = Invoke-Remediation -FailureRecord @{ failureClass = 'retry_exhausted'; severity = 'hard'; innerFailureClass = 'retry_exhausted'; stepNumber = 1 }
        Assert-Equal -Expected 'retry_exhausted' -Actual $r.FailureClass -Because 'inner==outer stays outer'
        Assert-True (-not $r.Contains('RoutedFromFailureClass')) 'no misleading routed-audit when inner==outer'
    }
}

Describe 'Invoke-Remediation forwards the enriched Context' {
    It 'returns a recommendation in the canonical vocabulary for an enriched record' {
        $rec = @{
            failureClass = 'ocr_timeout'; severity = 'hard'; stepNumber = 4; actionVerb = 'waitForText'
            sequenceName = 'wl.test'
            repro = @{ command = 'pwsh test/Debug-TestSequence.ps1 -SequenceName "wl.test"' }
            context = @{ sequencePath = 'x/wl.test.yml'; matchedFailurePattern = 'kernel panic' }
        }
        $vocab = @(Get-RecoveryRecommendationName)
        $r = Invoke-Remediation -FailureRecord $rec
        Assert-True ($vocab -contains [string]$r.Recommendation) "recommendation '$($r.Recommendation)' in canonical vocabulary"
    }
}

Describe 'Invoke-Remediation persists last_remediation.json' {
    It 'writes the durable decision record into YURUNA_LOG_DIR' {
        $tmp = New-YurunaTestTempDir -Prefix 'yrn-remediation'
        $savedLogDir = Save-YurunaTestEnvironment -Name 'YURUNA_LOG_DIR'
        try {
            $env:YURUNA_LOG_DIR = $tmp
            $rec = @{
                failureClass = 'ocr_timeout'; severity = 'hard'; stepNumber = 4
                actionVerb = 'waitForText'; sequenceName = 'wl.test'; vmName = 'vm1'; guestKey = 'guest.x'
            }
            $r = Invoke-Remediation -FailureRecord $rec
            $path = Join-Path $tmp 'last_remediation.json'
            Assert-True (Test-Path -LiteralPath $path) 'last_remediation.json written to the log dir'
            $doc = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
            Assert-Equal -Expected 1 -Actual $doc.schemaVersion -Because 'schema-versioned record'
            Assert-Equal -Expected 'ocr_timeout' -Actual $doc.failureClass -Because 'failureClass captured'
            Assert-Equal -Expected ([string]$r.Recommendation) -Actual ([string]$doc.recommendation) -Because 'recommendation matches the returned decision'
            Assert-Equal -Expected 'vm1' -Actual $doc.vmName -Because 'correlation field captured'
            Assert-Equal -Expected $false -Actual $doc.autoApply -Because 'advisory-only: autoApply stays false'
            # No BOM: the first byte must be the JSON open-brace, not EF BB BF.
            $bytes = [System.IO.File]::ReadAllBytes($path)
            Assert-True ($bytes[0] -ne 0xEF) 'record is written without a UTF-8 BOM'
        } finally {
            Restore-YurunaTestEnvironment -Saved $savedLogDir
            Remove-YurunaTestTempDir $tmp
        }
    }
    It 'records the outer class when routing past a retry wrapper' {
        $tmp = New-YurunaTestTempDir -Prefix 'yrn-remediation'
        $savedLogDir = Save-YurunaTestEnvironment -Name 'YURUNA_LOG_DIR'
        try {
            $env:YURUNA_LOG_DIR = $tmp
            $null = Invoke-Remediation -FailureRecord @{ failureClass = 'retry_exhausted'; severity = 'hard'; innerFailureClass = 'ocr_timeout'; stepNumber = 3 }
            $doc = Get-Content -Raw -LiteralPath (Join-Path $tmp 'last_remediation.json') | ConvertFrom-Json
            Assert-Equal -Expected 'ocr_timeout' -Actual $doc.failureClass -Because 'routed inner class recorded'
            Assert-Equal -Expected 'retry_exhausted' -Actual $doc.outerFailureClass -Because 'masked outer class preserved in the record'
        } finally {
            Restore-YurunaTestEnvironment -Saved $savedLogDir
            Remove-YurunaTestTempDir $tmp
        }
    }
}

Describe 'Invoke-Remediation quotes the fields the producers record' {
    It 'names the switch and its verdict for host_network_degraded' {
        $r = Invoke-Remediation -FailureRecord @{ failureClass = 'host_network_degraded'; severity = 'hard'; hostNetworkSwitch = 'LabBridge'; hostNetworkVerdict = 'no-uplink' }
        $r.Recommendation | Should -Be 'operator_intervention_required'
        ($r.Actions -join ' ') | Should -Match 'LabBridge'
        ($r.Actions -join ' ') | Should -Match 'no-uplink'
    }

    It 'names both addresses for dhcp_identity_unbounded' {
        $r = Invoke-Remediation -FailureRecord @{ failureClass = 'dhcp_identity_unbounded'; severity = 'hard'; previousAddress = '192.0.2.10'; currentAddress = '192.0.2.11' }
        $r.Rationale | Should -Match '192\.0\.2\.10'
        $r.Rationale | Should -Match '192\.0\.2\.11'
    }
}

Describe 'Invoke-Remediation tells a wedged guest kernel from a stalled mirror' {
    BeforeAll {
        function New-FetchTimeoutRecord {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: returns an in-memory failure record.')]
            [OutputType([hashtable])]
            param([string[]]$KernelFaults = @(), [string[]]$SilentProcessors = @())
            return @{
                failureClass = 'wait_timeout'; severity = 'hard'; actionVerb = 'fetchAndExecute'; vmName = 'test-guest-01'
                context = @{ causeDetail = @{
                    progressAdvisory = @{ verdict = 'progress-suspect'; kernelFaults = $KernelFaults }
                    guestLivelock = @{ verdict = 'not-livelocked'; processorWindow = @{ NoInterruptsServicedProcessors = $SilentProcessors } }
                } }
            }
        }
    }

    It 'names the kernel''s reports and the silent processors instead of the package mirror' {
        $r = Invoke-Remediation -FailureRecord (New-FetchTimeoutRecord -KernelFaults @('rcu-stall', 'hung-task') -SilentProcessors @('0', '1'))
        $r.Recommendation | Should -Be 'retry_with_backoff' -Because 'only the text changes; the next cycle builds a new guest either way'
        $r.Rationale | Should -Match 'rcu-stall, hung-task'
        $r.Rationale | Should -Match 'serviced no interrupt: 0, 1'
        $r.Rationale | Should -Not -Match 'most often blocked on a slow or stalled package mirror'
        ($r.Actions -join ' ') | Should -Match 'serial-console\.log'
        ($r.Actions -join ' ') | Should -Not -Match 'NETWORK section'
    }

    It 'takes a processor that serviced no interrupt as enough, with no kernel report on record' {
        $r = Invoke-Remediation -FailureRecord (New-FetchTimeoutRecord -SilentProcessors @('0'))
        $r.Rationale | Should -Match 'kernel reports: -;'
        $r.Rationale | Should -Match 'serviced no interrupt: 0\)'
    }

    It 'keeps the mirror advice for a timeout whose record shows neither' {
        $r = Invoke-Remediation -FailureRecord (New-FetchTimeoutRecord)
        $r.Recommendation | Should -Be 'retry_with_backoff'
        $r.Rationale | Should -Match 'package mirror'
        ($r.Actions -join ' ') | Should -Match 'NETWORK section'
    }
}

# A wedge is filed as guest_kernel_stalled whichever verb was waiting, so the
# advice cannot depend on the verb the way wait_timeout's does.
Describe 'Invoke-Remediation names the wedged kernel for guest_kernel_stalled' {
    BeforeAll {
        function New-KernelStalledRecord {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test helper: returns an in-memory failure record.')]
            [OutputType([hashtable])]
            param([string]$ActionVerb, [string[]]$KernelFaults = @(), [string[]]$SilentProcessors = @(), [int]$LivelockedSeconds = 0)
            return @{
                failureClass = 'guest_kernel_stalled'; severity = 'hard'; vmName = 'test-guest-01'; actionVerb = $ActionVerb
                context = @{ causeDetail = @{
                    progressAdvisory = @{ verdict = 'insufficient-evidence'; kernelFaults = $KernelFaults }
                    guestLivelock = @{ verdict = $(if ($LivelockedSeconds) { 'livelocked' } else { 'not-livelocked' }); livelockedSeconds = $LivelockedSeconds
                        processorWindow = @{ NoInterruptsServicedProcessors = $SilentProcessors } }
                } }
            }
        }
    }

    It 'names the wedged kernel on every wait verb (<Verb>)' -TestCases @(
        @{ Verb = 'fetchAndExecute' }, @{ Verb = 'waitForText' }, @{ Verb = 'waitForTextWithNudge' }
        @{ Verb = 'waitForAndEnter' }, @{ Verb = 'passwdPrompt' }, @{ Verb = 'retry' }
    ) {
        param($Verb)
        $r = Invoke-Remediation -FailureRecord (New-KernelStalledRecord -ActionVerb $Verb -KernelFaults @('rcu-stall') -SilentProcessors @('1'))
        $r.FailureClass | Should -BeExactly 'guest_kernel_stalled'
        $r.Recommendation | Should -BeExactly 'retry_with_backoff' -Because 'the next attempt boots the guest again'
        $r.Rationale | Should -Match 'test-guest-01'
        $r.Rationale | Should -Match 'rcu-stall'
        $r.Rationale | Should -Match 'serviced no interrupt: 1;'
        $r.Rationale | Should -Not -Match 'most often blocked on a slow or stalled package mirror' -Because 'a wedged kernel is no package mirror to wait out'
        ($r.Actions -join ' ') | Should -Not -Match 'NETWORK section'
        ($r.Actions -join ' ') | Should -Match 'guestKernelStallEnd'
        ($r.Actions -join ' ') | Should -Match 'docs/host-hyperv\.md'
    }

    It 'names how long every processor was held in the hypervisor' {
        $r = Invoke-Remediation -FailureRecord (New-KernelStalledRecord -ActionVerb 'fetchAndExecute' -LivelockedSeconds 345)
        $r.Rationale | Should -Match 'kernel reports: -;'
        $r.Rationale | Should -Match 'held in the hypervisor: 345\)'
    }
}

Describe 'Invoke-Remediation routes the infra-stage failure classes' {
    It 'requires capacity repair instead of retrying a measured storage shortage' {
        $record = @{ failureClass = 'provisioning_failure'; severity = 'hard'; vmName = 'core'; description = 'C: needs 14 GiB, 10 GiB available'; context = @{ hostStorage = @{ status = 'insufficient'; errorCode = '0x80070070' } } }
        $r = Invoke-Remediation -FailureRecord $record
        $r.Recommendation | Should -Be 'operator_intervention_required'
        $r.AutoApply | Should -BeFalse
        $r.Rationale | Should -Match 'C:'
    }

    It 'does not infer a storage shortage from an unavailable capacity probe' {
        $record = @{ failureClass = 'provisioning_failure'; severity = 'hard'; context = @{ hostStorage = @{ status = 'unknown' } } }
        (Invoke-Remediation -FailureRecord $record).Recommendation | Should -Be 'retry_with_backoff'
    }

    It 'requires capacity repair for measured dependency storage shortages in <Shape> records' -ForEach @(
        @{ Shape = 'inline' }
        @{ Shape = 'persisted' }
    ) {
        $record = @{ failureClass = 'provisioning_failure'; severity = 'hard'; description = 'Edge runtime allocation has insufficient storage' }
        $rows = @(@{ vmName = 'edge'; hostStorage = @{ status = 'insufficient' } })
        if ($Shape -eq 'inline') { $record.dependencyFailures = $rows }
        else { $record.context = @{ dependencyFailures = $rows } }
        $result = Invoke-Remediation -FailureRecord $record
        $result.Recommendation | Should -Be 'operator_intervention_required'
        $result.Rationale | Should -Be $record.description
    }

    It 'requires capacity repair for an older driver dependency carrying only <ErrorCode>' -ForEach @(
        @{ ErrorCode = '0x80070070' }
        @{ ErrorCode = '0x80070027' }
    ) {
        $record = @{ failureClass = 'provisioning_failure'; severity = 'hard'; description = 'VM runtime allocation failed'; context = @{
            hostStorage = @{ status = 'unknown' }
            dependencyFailures = @(@{ vmName = 'core'; errorCode = $ErrorCode })
        } }
        (Invoke-Remediation -FailureRecord $record).Recommendation | Should -Be 'operator_intervention_required'
    }

    It 'recognizes a dependency disk-full error even when its earlier capacity reading was ready' {
        $record = @{ failureClass = 'provisioning_failure'; severity = 'hard'; context = @{
            dependencyFailures = @(@{ vmName = 'edge'; hostStorage = @{ status = 'ready'; errorCode = '0x80070070' } })
        } }
        (Invoke-Remediation -FailureRecord $record).Recommendation | Should -Be 'operator_intervention_required'
    }

    It 'keeps retry guidance for unavailable and malformed dependency capacity evidence' {
        $record = @{ failureClass = 'provisioning_failure'; severity = 'hard'; context = @{
            dependencyFailures = @($null, '0x80070070', @{ hostStorage = @{ status = 'unknown' } }, @{ errorCode = '0x80004005' })
        } }
        (Invoke-Remediation -FailureRecord $record).Recommendation | Should -Be 'retry_with_backoff'
    }

    It 'routes a numeric disk-full failure even when the later capacity reading is ready' {
        $record = @{ failureClass = 'provisioning_failure'; severity = 'hard'; description = 'VM runtime allocation failed'; context = @{ hostStorage = @{ status = 'ready'; errorCode = '0x80070070' } } }
        (Invoke-Remediation -FailureRecord $record).Recommendation | Should -Be 'operator_intervention_required'
    }

    It 'routes provisioning_failure to retry_with_backoff (transient host provisioning)' {
        $r = Invoke-Remediation -FailureRecord @{ failureClass = 'provisioning_failure'; severity = 'hard'; vmName = 'vm1' }
        Assert-Equal -Expected 'retry_with_backoff' -Actual $r.Recommendation -Because 'provisioning is retryable'
    }
    It 'routes bootstrap_sync and plan_invalid to operator_intervention_required' {
        $r1 = Invoke-Remediation -FailureRecord @{ failureClass = 'bootstrap_sync'; severity = 'hard'; vmName = '(bootstrap)' }
        Assert-Equal -Expected 'operator_intervention_required' -Actual $r1.Recommendation -Because 'git divergence needs an operator'
        $r2 = Invoke-Remediation -FailureRecord @{ failureClass = 'plan_invalid'; severity = 'hard'; vmName = '(planner)' }
        Assert-Equal -Expected 'operator_intervention_required' -Actual $r2.Recommendation -Because 'plan errors need an operator'
    }
    It 'routes hypervisor_unresponsive to operator_intervention_required and quotes the record' {
        $record = @{ failureClass = 'hypervisor_unresponsive'; severity = 'hard'; vmName = ''
            description = 'The hypervisor control channel stopped acting on start requests (first seen on amisad-edge-b)' }
        $r = Invoke-Remediation -FailureRecord $record
        Assert-Equal -Expected 'operator_intervention_required' -Actual $r.Recommendation -Because 'only a restart of the hypervisor application repairs it'
        Assert-False $r.AutoApply 'nothing is applied unattended'
        Assert-Match 'first seen on amisad-edge-b' $r.Rationale 'the record description is quoted'
        Assert-True (@($r.Actions).Count -ge 3) 'restart, evidence and resume steps are named'
        Assert-True ([bool](@($r.Actions) -match 'utm-control-snapshot')) 'the reader is sent to the control snapshot'
    }
    It 'requires source integrity inspection and never applies a repair automatically' {
        $r = Invoke-Remediation -FailureRecord @{failureClass='source_integrity';severity='hard';description='fixture receipt rejected'}
        $r.Recommendation | Should -BeExactly 'operator_intervention_required'
        $r.AutoApply | Should -BeFalse
        $r.Rationale | Should -Match 'fixture receipt rejected'
        ($r.Actions -join ' ') | Should -Match 'key IDs|receipt|selected SHA'
        Test-AutoRemediationAllowed -FailureClass 'source_integrity' | Should -BeFalse
    }
    It 'advises a host power-off for vm_not_stopped, not a cold-power-cycle retry the engine refuses around stopVm' {
        # Test-SequenceColdPowerCyclePolicy admits a cold restart only after a
        # login-wait timeout, so advice naming that retry sends the operator to
        # a sequence the engine rejects as cold-power-cycle-unsafe-step-shape.
        $r = Invoke-Remediation -FailureRecord @{ failureClass = 'vm_not_stopped'; severity = 'hard'; vmName = 'test-guest-01'; actionVerb = 'stopVm' }
        $r.Recommendation | Should -BeExactly 'retry_with_backoff'
        $r.Rationale | Should -Match 'test-guest-01'
        $advice = (@($r.Rationale) + @($r.Actions)) -join ' '
        $advice | Should -Not -Match 'coldPowerCycle|restartVmBeforeRetry|cold power cycle'
        $actions = $r.Actions -join ' '
        $actions | Should -Match 'Power the VM off from the host'
        $actions | Should -Match 'stopVm'
        $actions | Should -Match 'forceOnTimeout: true'
        $actions | Should -Match 'hypervisor'
    }
    It 'has a registered handler for every canonical FailureClass (no unrouted class)' {
        $enum = @(Get-FailureClassEnum)
        $registered = @(Get-RegisteredFailureClass)
        $missing = @($enum | Where-Object { $registered -notcontains $_ })
        Assert-Equal -Expected 0 -Actual $missing.Count -Because "every enum class must have a handler; missing: $($missing -join ', ')"
    }
}

Describe 'Invoke-Remediation guards a parsed-but-non-object last_failure.json' {
    # A last_failure.json that is valid JSON but not an object (a bare string /
    # number / array, or most subtly a literal `null`) must route to the
    # parse-error fallback, never NRE at the first .Contains(). The `null` case
    # is the load-bearing one: the [hashtable] parameter type coerces-and-throws
    # for the scalar/array cases, but a JSON `null` assigns cleanly as $null and
    # would otherwise reach .Contains() on a $null record.

    It 'routes a JSON null last_failure.json to the parse-error fallback without throwing' {
        $dir = New-YurunaTestTempDir -Prefix 'yrn-rem-nonobj'
        try {
            $lf = Join-Path $dir 'last_failure.json'
            Set-Content -LiteralPath $lf -Value 'null' -Encoding utf8
            $r = Invoke-Remediation -LastFailurePath $lf
            Assert-Equal -Expected '(parse-error fallback)' -Actual ([string]$r.HandledBy) -Because 'a JSON null must route to the fallback, not throw at .Contains() on $null'
            Assert-Equal -Expected 'operator_intervention_required' -Actual ([string]$r.Recommendation) -Because 'the parse-error fallback recommends operator intervention'
        } finally { Remove-YurunaTestTempDir $dir }
    }

    It 'routes valid-but-non-object JSON (string / number / array) to the parse-error fallback' {
        $dir = New-YurunaTestTempDir -Prefix 'yrn-rem-nonobj'
        try {
            $lf = Join-Path $dir 'last_failure.json'
            foreach ($content in @('"a string"', '42', '[1,2,3]')) {
                Set-Content -LiteralPath $lf -Value $content -Encoding utf8
                $r = Invoke-Remediation -LastFailurePath $lf
                Assert-Equal -Expected '(parse-error fallback)' -Actual ([string]$r.HandledBy) -Because "non-object JSON ($content) must route to the fallback"
            }
        } finally { Remove-YurunaTestTempDir $dir }
    }

    It 'still reads a valid JSON-object last_failure.json normally' {
        $dir = New-YurunaTestTempDir -Prefix 'yrn-rem-nonobj'
        try {
            $lf = Join-Path $dir 'last_failure.json'
            Set-Content -LiteralPath $lf -Value '{"failureClass":"ocr_timeout","severity":"hard","stepNumber":2}' -Encoding utf8
            $r = Invoke-Remediation -LastFailurePath $lf
            Assert-Equal -Expected 'ocr_timeout' -Actual ([string]$r.FailureClass) -Because 'a real object is parsed and classified normally'
            Assert-True ([string]$r.HandledBy -ne '(parse-error fallback)') 'a valid object does NOT hit the parse-error fallback'
        } finally { Remove-YurunaTestTempDir $dir }
    }
}
