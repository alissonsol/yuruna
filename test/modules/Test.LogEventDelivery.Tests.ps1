<#PSScriptInfo
.VERSION 2026.10.18.1
.GUID 4265798a-3d2b-45d8-a5ad-6776ff4a2ad9
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test telemetry event delivery pester
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
    Pins that losing a cycle event is never silent: every emission is counted, and
    every loss is recorded with its reason beside the stream.
.DESCRIPTION
    Telemetry is best-effort by design -- a cycle never fails because an event
    could not be written -- and on its own that policy makes a lost event invisible: a
    writer that was not loaded, or a call that throws, returns without a trace. A
    remediation loop reading a quiet stream cannot tell "nothing happened" from
    "the writer broke". These cases drive Send-CycleEventSafely through each way an
    event can be lost and check the ledger (Get-CycleEventDelivery and
    cycle.events.delivery.json), the single warning, and that the emit site itself
    never throws.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The logging module reads the open cycle folder from a global handle that Start-LogFile sets; the fixtures set and clear that same handle.')]
param()

BeforeAll {
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Log.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.EventSchema.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.HostSampling.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.SequenceFailureState.psm1') -Force -DisableNameChecking

function Reset-DeliveryLedger {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: reseeds the module-scope ledger a new cycle would start empty.')]
    param()
    InModuleScope Test.Log {
        $script:CycleEventDelivery = [ordered]@{ attempted = 0; delivered = 0; dropped = 0; lastDroppedEvent = ''; lastDropReason = ''; lastDropAtUtc = '' }
        $script:CycleEventDropWarned = $false
    }
}
}

Describe 'Cycle event delivery ledger' {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('evdel-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:SavedFolder = $global:__YurunaCycleFolder
        $script:SavedLogDir = $env:YURUNA_LOG_DIR
        $global:__YurunaCycleFolder = $script:Dir
        Remove-Item Env:YURUNA_LOG_DIR -ErrorAction SilentlyContinue
        Mock -ModuleName Test.Log Write-Warning { }
        Reset-DeliveryLedger
        $script:Event = @{ timestamp = '2026-10-01T00:00:00Z'; event = 'step_end'; ok = $true }
    }
    AfterEach {
        $global:__YurunaCycleFolder = $script:SavedFolder
        if ($null -ne $script:SavedLogDir) { $env:YURUNA_LOG_DIR = $script:SavedLogDir }
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'counts a delivered event' {
        Send-CycleEventSafely -EventRecord $script:Event
        $d = Get-CycleEventDelivery
        $d.attempted | Should -Be 1
        $d.delivered | Should -Be 1
        $d.dropped | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $script:Dir 'cycle.events.ndjson') -Raw) | Should -Match '"event":"step_end"'
        Test-Path -LiteralPath (Join-Path $script:Dir 'cycle.events.delivery.json') | Should -BeFalse -Because 'a ledger file is written for losses, not for every event'
    }

    It 'keeps per-processor measurements and unavailable counters as structured event JSON' {
        $now = [datetime]::UtcNow
        $sample = [pscustomobject]@{
            Utc = $now
            VMs = @{ fixture = @{ '0' = @{ '% Guest Run Time'=66.01; '% Hypervisor Run Time'=33.11; 'Total Intercepts/sec'=1282000.0 } } }
            CounterCapabilities = @([pscustomobject]@{ Counter='SysReg Accesses/sec'; Status='absent'; Reason='not published' })
        }
        $failureState = Get-SequenceFailureState
        $previousVerdict = $failureState.WaitForTextGuestLivelock
        try {
            $failureState.WaitForTextGuestLivelock = Get-YurunaVmLivelockVerdict -VMName fixture -Sample @($sample) -NowUtc $now
            $record = New-SequenceFailureRecord -Reason step -VMName fixture -GuestKey guest.ubuntu.server.26 -HostType host.windows.hyper-v -SequencePath fixture.yml -LogDir $script:Dir
            Send-CycleEventSafely -EventRecord $record.Event
        } finally { $failureState.WaitForTextGuestLivelock = $previousVerdict }

        $events = @(Get-Content -LiteralPath (Join-Path $script:Dir 'cycle.events.ndjson') |
            ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
        $captureEvent = $events | Where-Object event -EQ step_failure
        $captureEvent.guestProcessorWindow.Processors[0].Counters['% Guest Run Time'].Average | Should -Be 66.01
        $unavailable = $captureEvent.guestProcessorWindow.Processors[0].Counters['SysReg Accesses/sec']
        $unavailable.Status | Should -Be unavailable
        $unavailable.ContainsKey('Average') | Should -BeTrue
        $unavailable.Average | Should -BeNullOrEmpty
        $captureEvent.guestProcessorWindow.CounterCapabilities[0].Status | Should -Be absent
        $captureEvent.causeGuestLivelocked | Should -BeFalse
        $captureEvent.guestProcessorWindow.Processors[0].UnaccountedEstimatePerSecond | Should -BeNullOrEmpty
        (Get-CycleEventDelivery).delivered | Should -BeGreaterOrEqual 1
    }

    It 'counts an event emitted with no cycle open as dropped, without a warning or a file' {
        $global:__YurunaCycleFolder = $null
        { Send-CycleEventSafely -EventRecord $script:Event } | Should -Not -Throw
        $d = Get-CycleEventDelivery
        $d.dropped | Should -Be 1
        $d.lastDropReason | Should -Be 'no-cycle-folder'
        $d.lastDroppedEvent | Should -Be 'step_end'
        Should -Invoke -CommandName Write-Warning -ModuleName Test.Log -Times 0 -Exactly -Scope It
        Test-Path -LiteralPath (Join-Path $script:Dir 'cycle.events.delivery.json') | Should -BeFalse
    }

    It 'records a failed write with its reason and warns once, however many follow' {
        # A directory where the stream file belongs makes every append fail.
        New-Item -ItemType Directory -Path (Join-Path $script:Dir 'cycle.events.ndjson') -Force | Out-Null
        { Send-CycleEventSafely -EventRecord $script:Event } | Should -Not -Throw
        { Send-CycleEventSafely -EventRecord @{ timestamp = '2026-10-01T00:00:01Z'; event = 'retry_attempt' } } | Should -Not -Throw
        $d = Get-CycleEventDelivery
        $d.dropped | Should -Be 2
        $d.delivered | Should -Be 0
        $d.lastDroppedEvent | Should -Be 'retry_attempt'
        $d.lastDropReason | Should -Match '^write-failed:'
        $ledger = Get-Content -LiteralPath (Join-Path $script:Dir 'cycle.events.delivery.json') -Raw | ConvertFrom-Json
        $ledger.dropped | Should -Be 2
        $ledger.lastDropReason | Should -Match '^write-failed:'
        Should -Invoke -CommandName Write-Warning -ModuleName Test.Log -Times 1 -Exactly -Scope It
        Test-Path -LiteralPath (Join-Path $script:Dir 'cycle.events.gaps') | Should -BeTrue -Because 'the existing gap sentinel is still written'
    }

    It 'records a writer that throws, and does not let it escape the emit site' {
        Mock -ModuleName Test.Log Write-CycleNdjsonEvent { throw 'handle table exhausted' }
        { Send-CycleEventSafely -EventRecord $script:Event } | Should -Not -Throw
        $d = Get-CycleEventDelivery
        $d.dropped | Should -Be 1
        $d.lastDropReason | Should -Be 'writer-threw: handle table exhausted'
        (Get-Content -LiteralPath (Join-Path $script:Dir 'cycle.events.delivery.json') -Raw | ConvertFrom-Json).lastDropReason | Should -Match 'handle table exhausted'
    }

    It 'records a writer that is not available' {
        Mock -ModuleName Test.Log Get-Command { $null } -ParameterFilter { $Name -eq 'Write-CycleNdjsonEvent' }
        { Send-CycleEventSafely -EventRecord $script:Event } | Should -Not -Throw
        $d = Get-CycleEventDelivery
        $d.dropped | Should -Be 1
        $d.lastDropReason | Should -Be 'writer-unavailable'
        (Get-Content -LiteralPath (Join-Path $script:Dir 'cycle.events.delivery.json') -Raw | ConvertFrom-Json).lastDropReason | Should -Be 'writer-unavailable'
    }

    It 'leaves the event the caller handed in as it was' {
        New-Item -ItemType Directory -Path (Join-Path $script:Dir 'cycle.events.ndjson') -Force | Out-Null
        $record = @{ timestamp = '2026-10-01T00:00:00Z'; event = 'step_end'; failureClass = 'wait_timeout'; ok = $false }
        Send-CycleEventSafely -EventRecord $record
        $record.failureClass | Should -Be 'wait_timeout' -Because 'a lost delivery must not rewrite the failure it was reporting'
        $record.ok | Should -BeFalse
    }

    It 'catalogs the ledger in the cycle manifest under its own kind' {
        New-Item -ItemType Directory -Path (Join-Path $script:Dir 'cycle.events.ndjson') -Force | Out-Null
        Send-CycleEventSafely -EventRecord $script:Event
        Write-CycleManifest -CycleFolder $script:Dir -Confirm:$false
        $manifest = Get-Content -LiteralPath (Join-Path $script:Dir 'manifest.json') -Raw | ConvertFrom-Json
        $entry = @($manifest.artifacts | Where-Object { $_.path -eq 'cycle.events.delivery.json' })
        $entry.Count | Should -Be 1
        $entry[0].kind | Should -Be 'ndjson-delivery'
    }

    It 'starts every cycle with an empty ledger' {
        $text = Get-Content -LiteralPath (Join-Path $here 'Test.Log.psm1') -Raw
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
        $start = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-LogFile' }, $true))
        $start.Count | Should -Be 1
        $start[0].Extent.Text | Should -Match 'CycleEventDelivery\s*=\s*\[ordered\]'
        $start[0].Extent.Text | Should -Match 'CycleEventDropWarned\s*=\s*\$false'
    }
}
