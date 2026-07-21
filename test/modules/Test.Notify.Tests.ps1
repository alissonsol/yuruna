<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42759f4b-9143-4909-b379-0ff23a9fc154
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test notification dispatch pester
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
    Pester coverage for Test.Notify.psm1: the extension dispatch loop and its
    delivery ledger, the failure-message body plus its machine-readable
    trailer, the schema-v2 payload builder, and the cycle-failure envelope.
.DESCRIPTION
    The delivery ledger (notification.delivery.json) is the only evidence that
    an escalation actually left the host, so the dispatch tests assert the
    RECORD, not just the absence of an exception -- a notification that fails
    silently reads exactly like one that was delivered.

    Every dispatch here uses an event code with no subscribers, so no transport
    is ever contacted; the extension resolves the code, finds nobody to mail,
    and returns.

    Throw-based assertions rather than Should.
    Run: pwsh -NoProfile -File test/modules/Test.Notify.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module powershell-yaml -Force -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.Notify.psm1') -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

# Helpers and path fixtures live at FILE scope, above the first Describe: a
# Describe body runs during discovery and its variables and functions are
# discarded before any It executes, and the run pass stops descending top-level
# statements at the first Describe. Only PATHS are computed here -- creating the
# directories is a side effect and the file body runs twice (discovery, then
# run), so the New-Item calls stay in BeforeAll.

function Initialize-TestCycleFolder {
    <#
    .SYNOPSIS
        Set the cross-module cycle-folder anchor the notifier reads when no
        -CycleFolder argument is passed.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'global:__YurunaCycleFolder is the cycle-folder anchor Test.Log sets and Test.Notify reads; the test has to drive it to exercise the fallback.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    $global:__YurunaCycleFolder = $Path
}

function Initialize-NotifyCapture {
    <#
    .SYNOPSIS
        Stash what the mocked dispatcher was handed, so the It can assert on it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'A mock body and the It that asserts on it are separate scopes; a global is the one channel both can reach.')]
    [CmdletBinding()]
    param($Value)
    $global:YurunaNotifyCapture = $Value
}

function Get-NotifyCapture {
    <#
    .SYNOPSIS
        Read back what Initialize-NotifyCapture stashed.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reads the capture slot Initialize-NotifyCapture writes.')]
    [CmdletBinding()]
    param()
    return $global:YurunaNotifyCapture
}

function Get-DeliveryRecord {
    <#
    .SYNOPSIS
        Parse the JSON Lines delivery ledger of a cycle folder.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$CycleFolder)
    $path = Join-Path $CycleFolder 'notification.delivery.json'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    return @(Get-Content -LiteralPath $path | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-ActiveNotifyExtension {
    <#
    .SYNOPSIS
        Name of the first active notification extension, as the dispatcher
        resolves it -- the ledger records deliveries under this name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return @(Get-ActiveExtensionName -Area 'notification')[0]
}

# An event code no transports.yml subscribes to. The extension resolves it,
# finds no subscribers, and returns -- so the dispatch path is exercised end to
# end without any transport being contacted, on this host or an operator's.
$UnsubscribedEventCode = 'test.selfcheck.unit'

$SavedPublicUrl = $env:YURUNA_STATUS_PUBLIC_URL

$TempRoot = [System.IO.Path]::GetTempPath()
$PayloadDir = Join-Path $TempRoot ('yuruna-notify-payload-' + [guid]::NewGuid().ToString('N'))
$PayloadFailureFile = Join-Path $PayloadDir 'last_failure.json'
$LedgerDir = Join-Path $TempRoot ('yuruna-notify-ledger-' + [guid]::NewGuid().ToString('N'))
$LedgerMissingDir = Join-Path $LedgerDir 'no-such-subfolder'
$DispatchDir = Join-Path $TempRoot ('yuruna-notify-dispatch-' + [guid]::NewGuid().ToString('N'))
$EnvelopeDir = Join-Path $TempRoot ('yuruna-notify-envelope-' + [guid]::NewGuid().ToString('N'))
$ResolveDir = Join-Path $TempRoot ('yuruna-notify-resolve-' + [guid]::NewGuid().ToString('N'))

Describe 'Format-FailureMessage' {
    It 'builds a plain-text body from the scalar fields' {
        $body = Format-FailureMessage -HostType 'host.windows.hyper-v' -Hostname 'BOX-01' -GuestKey 'ubuntu-24' `
            -StepName 'waitForText' -ErrorMessage 'timed out waiting for login:' -CycleId 'cycle-000042' -GitCommit 'abc1234'
        Assert-True ($body -match '(?m)^Host:\s+host\.windows\.hyper-v$')
        Assert-True ($body -match '(?m)^Machine:\s+BOX-01$')
        Assert-True ($body -match '(?m)^Guest:\s+ubuntu-24$')
        Assert-True ($body -match '(?m)^Step:\s+waitForText$')
        Assert-True ($body -match '(?m)^Error:\s+timed out waiting for login:$')
        Assert-True ($body -match '(?m)^Cycle ID:\s+cycle-000042$')
        Assert-True ($body -match '(?m)^Commit:\s+abc1234$')
    }
    It 'appends no machine-readable trailer for a legacy caller with no payload' {
        $body = Format-FailureMessage -HostType 'ht' -Hostname 'h' -GuestKey 'g' -StepName 's' -ErrorMessage 'e' -CycleId 'c' -GitCommit 'gc'
        Assert-True ($body -notmatch 'yuruna-failure-json') 'the legacy body is untouched'
        Assert-True ($body -notmatch 'yuruna-failure-summary')
    }
    It 'appends the quick-scan summary and the full JSON dump when a payload is supplied' {
        $data = @{
            failureClass         = 'ssh_timeout'
            classificationSource = 'rules'
            severity             = 'hard'
            actionVerb           = 'sshWaitReady'
            cycleFolderUrl       = 'http://box:8080/status/log/cycle-000042/'
            suggestedRecoveries  = @('restart guest', 'recreate guest')
            repro                = @{ command = 'pwsh test/Test-Sequence.ps1 -Guest ubuntu-24' }
        }
        $body = Format-FailureMessage -HostType 'ht' -Hostname 'h' -GuestKey 'g' -StepName 's' -ErrorMessage 'e' -CycleId 'c' -GitCommit 'gc' -EventData $data
        Assert-True ($body -match '(?m)^failureClass:\s+ssh_timeout$')
        Assert-True ($body -match '(?m)^classificationSource:\s+rules$')
        Assert-True ($body -match '(?m)^severity:\s+hard$')
        Assert-True ($body -match '(?m)^cycleFolderUrl:\s+http://box:8080/status/log/cycle-000042/$')
        Assert-True ($body -match '(?m)^suggestedRecoveries:\s+restart guest, recreate guest$') 'the recovery list is flattened for the human reader'
        Assert-True ($body -match '(?m)^repro:\s+pwsh test/Test-Sequence\.ps1 -Guest ubuntu-24$') 'the nested repro.command is lifted out of the JSON'
        Assert-True ($body -match '--- yuruna-failure-json ---') 'the structured consumer still gets the whole payload'
        Assert-True ($body -match '--- end yuruna-failure-json ---')
        Assert-True ($body -match '"failureClass": "ssh_timeout"')
    }
    It 'lifts a flat reproCommand when the payload has no nested repro block' {
        $body = Format-FailureMessage -HostType 'ht' -Hostname 'h' -GuestKey 'g' -StepName 's' -ErrorMessage 'e' -CycleId 'c' -GitCommit 'gc' `
            -EventData @{ reproCommand = 'pwsh test/Test-Config.ps1' }
        Assert-True ($body -match '(?m)^repro:\s+pwsh test/Test-Config\.ps1$')
    }
    It 'leaves the summary fields blank rather than failing on a partial payload' {
        # A bootstrap failure ships before classification has run; the trailer
        # still has to render.
        $body = Format-FailureMessage -HostType 'ht' -Hostname 'h' -GuestKey 'g' -StepName 's' -ErrorMessage 'e' -CycleId 'c' -GitCommit 'gc' `
            -EventData @{ severity = 'hard' }
        Assert-True ($body -match '(?m)^severity:\s+hard$')
        Assert-True ($body -match '(?m)^failureClass:\s*$') 'a missing field renders empty, it does not throw'
        Assert-True ($body -match '(?m)^repro:\s*$')
    }
}

Describe 'Get-FailureEventData' {
    BeforeAll {
        $null = New-Item -ItemType Directory -Path $PayloadDir -Force
        Initialize-TestCycleFolder -Path ''
        Remove-Item Env:\YURUNA_STATUS_PUBLIC_URL -ErrorAction SilentlyContinue
    }
    AfterAll {
        Initialize-TestCycleFolder -Path ''
        if ($null -eq $SavedPublicUrl) { Remove-Item Env:\YURUNA_STATUS_PUBLIC_URL -ErrorAction SilentlyContinue }
        else { $env:YURUNA_STATUS_PUBLIC_URL = $SavedPublicUrl }
        Remove-Item -LiteralPath $PayloadDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    BeforeEach { Remove-Item -LiteralPath $PayloadFailureFile -Force -ErrorAction SilentlyContinue }

    It 'builds a minimal schema-v2 payload for a bootstrap failure with no cycle folder' {
        # GitPull / ProjectClone fire before Start-LogFile, so there is no
        # last_failure.json to classify from -- a partial payload still ships.
        $p = Get-FailureEventData -HostType 'host.ubuntu.kvm' -Hostname 'BOX' -StepName 'GitPull' `
            -ErrorMessage 'clone failed' -CycleId 'c1' -GitCommit 'abc' `
            -DefaultFailureClass 'git_failure' -DefaultSeverity 'hard'
        Assert-Equal -Expected 2 -Actual $p['schemaVersion']
        Assert-Equal -Expected 'git_failure' -Actual $p['failureClass']
        Assert-Equal -Expected 'hard' -Actual $p['severity']
        Assert-Equal -Expected 'GitPull' -Actual $p['actionVerb']
        Assert-Equal -Expected 'clone failed' -Actual $p['description']
        Assert-Equal -Expected 'BOX' -Actual $p['hostname']
        Assert-Equal -Expected 0 -Actual @($p['suggestedRecoveries']).Count
        Assert-True (-not $p.Contains('cycleFolderUrl')) 'with no cycle folder there is nothing to deep-link to'
    }
    It 'defaults an unclassified bootstrap failure to unknown' {
        $p = Get-FailureEventData -Hostname 'BOX' -StepName 'ProjectClone' -ErrorMessage 'boom'
        Assert-Equal -Expected 'unknown' -Actual $p['failureClass']
        Assert-Equal -Expected 'unknown' -Actual $p['severity']
    }
    It 'loads the cycle last_failure.json and augments it with cycle context' {
        @{
            schemaVersion       = 2
            failureClass        = 'ssh_timeout'
            severity            = 'hard'
            actionVerb          = 'sshWaitReady'
            action              = 'ssh connect'
            description         = 'no route to host'
            suggestedRecoveries = @('restart guest')
            guestKey            = 'guest-from-file'
            hostType            = 'host-from-file'
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $PayloadFailureFile -Encoding utf8NoBOM

        $p = Get-FailureEventData -CycleFolder $PayloadDir -Hostname 'BOX' -CycleId 'cycle-000042' -GitCommit 'g1' -ProjectCommit 'p1'
        Assert-Equal -Expected 'ssh_timeout' -Actual $p['failureClass'] -Because 'the classified failure, not a synthesised one'
        Assert-Equal -Expected 'restart guest' -Actual @($p['suggestedRecoveries'])[0]
        Assert-Equal -Expected 'cycle-000042' -Actual $p['cycleId']
        Assert-Equal -Expected 'g1' -Actual $p['gitCommit']
        Assert-Equal -Expected 'p1' -Actual $p['projectCommit']
        Assert-Equal -Expected $PayloadDir -Actual $p['cycleFolder']
    }
    It 'keeps the file values for identity fields the caller left empty' {
        @{ actionVerb = 'sshWaitReady'; action = 'ssh connect'; guestKey = 'guest-from-file'; hostType = 'host-from-file' } |
            ConvertTo-Json | Set-Content -LiteralPath $PayloadFailureFile -Encoding utf8NoBOM

        $p = Get-FailureEventData -CycleFolder $PayloadDir -Hostname 'BOX'
        Assert-Equal -Expected 'guest-from-file' -Actual $p['guestKey']
        Assert-Equal -Expected 'host-from-file' -Actual $p['hostType']
        Assert-Equal -Expected 'sshWaitReady' -Actual $p['stepName'] -Because 'an empty StepName falls back to the actionVerb'
        Assert-Equal -Expected 'ssh connect' -Actual $p['errorMessage'] -Because 'an empty ErrorMessage falls back to the action'
    }
    It 'lets the caller override the identity fields the file recorded' {
        @{ guestKey = 'guest-from-file'; hostType = 'host-from-file'; actionVerb = 'sshWaitReady' } |
            ConvertTo-Json | Set-Content -LiteralPath $PayloadFailureFile -Encoding utf8NoBOM

        $p = Get-FailureEventData -CycleFolder $PayloadDir -HostType 'host.macos.utm' -GuestKey 'ubuntu-26' -StepName 'waitForText'
        Assert-Equal -Expected 'host.macos.utm' -Actual $p['hostType']
        Assert-Equal -Expected 'ubuntu-26' -Actual $p['guestKey']
        Assert-Equal -Expected 'waitForText' -Actual $p['stepName']
    }
    It 'falls back to a synthesised payload when last_failure.json will not parse' {
        Set-Content -LiteralPath $PayloadFailureFile -Value 'not json {{' -Encoding utf8NoBOM
        $p = Get-FailureEventData -CycleFolder $PayloadDir -Hostname 'BOX' -StepName 'st' -ErrorMessage 'em' -DefaultFailureClass 'vm_start_failure'
        Assert-Equal -Expected 'vm_start_failure' -Actual $p['failureClass'] -Because 'a corrupt failure file must not lose the notification'
        Assert-Equal -Expected 'em' -Actual $p['description']
    }
    It 'deep-links the cycle folder through the published status URL when there is one' {
        $env:YURUNA_STATUS_PUBLIC_URL = 'https://yuruna.example/dash/'
        try {
            $p = Get-FailureEventData -CycleFolder $PayloadDir -Hostname 'BOX'
            $leaf = Split-Path -Leaf $PayloadDir
            Assert-Equal -Expected "https://yuruna.example/dash/status/log/$leaf/" -Actual $p['cycleFolderUrl'] -Because 'the trailing slash of the base URL is not doubled'
        } finally {
            Remove-Item Env:\YURUNA_STATUS_PUBLIC_URL -ErrorAction SilentlyContinue
        }
    }
    It 'guesses the status URL from the cycle hostname when none is published' {
        $p = Get-FailureEventData -CycleFolder $PayloadDir -Hostname 'BOX'
        $leaf = Split-Path -Leaf $PayloadDir
        Assert-Equal -Expected "http://BOX:8080/status/log/$leaf/" -Actual $p['cycleFolderUrl']
    }
    It 'falls back to localhost when it has no hostname either' {
        $p = Get-FailureEventData -CycleFolder $PayloadDir
        $leaf = Split-Path -Leaf $PayloadDir
        Assert-Equal -Expected "http://localhost:8080/status/log/$leaf/" -Actual $p['cycleFolderUrl']
    }
    It 'falls back to the cycle-folder anchor when no CycleFolder is passed' {
        Initialize-TestCycleFolder -Path $PayloadDir
        try {
            $p = Get-FailureEventData -Hostname 'BOX'
            Assert-Equal -Expected $PayloadDir -Actual $p['cycleFolder']
        } finally {
            Initialize-TestCycleFolder -Path ''
        }
    }
}

Describe 'Write-NotificationDelivery' {
    BeforeAll {
        $null = New-Item -ItemType Directory -Path $LedgerDir -Force
        Initialize-TestCycleFolder -Path ''
    }
    AfterAll {
        Initialize-TestCycleFolder -Path ''
        Remove-Item -LiteralPath $LedgerDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    BeforeEach { Remove-Item -LiteralPath (Join-Path $LedgerDir 'notification.delivery.json') -Force -ErrorAction SilentlyContinue }

    It 'appends one JSON Lines record per delivery' {
        Write-NotificationDelivery -ExtensionName 'default' -EventCode 'cycle.failure' -Status 'ok' -CycleFolder $LedgerDir
        Write-NotificationDelivery -ExtensionName 'webhook' -EventCode 'cycle.failure' -Status 'fail' -ErrorMessage 'HTTP 503' -ModeIsAsync $true -CycleFolder $LedgerDir

        $records = Get-DeliveryRecord -CycleFolder $LedgerDir
        Assert-Equal -Expected 2 -Actual $records.Count -Because 'the ledger is append-only, one line per extension per send'
        Assert-Equal -Expected 'default' -Actual $records[0].extension
        Assert-Equal -Expected 'ok' -Actual $records[0].status
        Assert-Equal -Expected 'sync' -Actual $records[0].mode
        Assert-Equal -Expected 'cycle.failure' -Actual $records[0].eventCode
        Assert-True ([bool]$records[0].timestamp) 'every record is timestamped'

        Assert-Equal -Expected 'fail' -Actual $records[1].status -Because 'a swallowed transport error must be visible in the ledger'
        Assert-Equal -Expected 'HTTP 503' -Actual $records[1].errorMessage
        Assert-Equal -Expected 'async' -Actual $records[1].mode
    }
    It 'writes to the cycle-folder anchor when no folder is passed' {
        Initialize-TestCycleFolder -Path $LedgerDir
        try {
            Write-NotificationDelivery -ExtensionName 'default' -EventCode 'e' -Status 'ok'
            Assert-Equal -Expected 1 -Actual (Get-DeliveryRecord -CycleFolder $LedgerDir).Count
        } finally {
            Initialize-TestCycleFolder -Path ''
        }
    }
    It 'writes nothing, and throws nothing, when there is no cycle folder at all' {
        # Bootstrap sends fire before the cycle folder exists.
        Write-NotificationDelivery -ExtensionName 'default' -EventCode 'e' -Status 'ok'
        Assert-Equal -Expected 0 -Actual (Get-DeliveryRecord -CycleFolder $LedgerDir).Count
    }
    It 'never throws back into the dispatch loop when the ledger cannot be written' {
        # Best-effort telemetry: a failed ledger write must not abort the send
        # (or the remaining extensions) that it is only recording.
        Write-NotificationDelivery -ExtensionName 'default' -EventCode 'e' -Status 'ok' -CycleFolder $LedgerMissingDir
        Assert-True $true 'an unwritable ledger path is swallowed'
    }
    It 'rejects a status outside the ok / fail set' {
        $threw = $false
        try { Write-NotificationDelivery -ExtensionName 'default' -EventCode 'e' -Status 'maybe' -CycleFolder $LedgerDir } catch { $threw = $true }
        Assert-True $threw 'the ledger has exactly two outcomes'
    }
}

Describe 'Send-Notification' {
    BeforeAll {
        $null = New-Item -ItemType Directory -Path $DispatchDir -Force
        Initialize-TestCycleFolder -Path $DispatchDir
    }
    AfterAll {
        Initialize-TestCycleFolder -Path ''
        Get-Job -Name 'Send-Notification-*' -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $DispatchDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    BeforeEach { Remove-Item -LiteralPath (Join-Path $DispatchDir 'notification.delivery.json') -Force -ErrorAction SilentlyContinue }

    # The dispatcher carries a name of its own, distinct from the Send-Notification
    # contract verb every extension exports. Extensions load -Global, so sharing
    # that verb would let the first-loaded transport shadow the dispatcher for every
    # unqualified caller -- see the resolution suite at the bottom of this file.
    It 'dispatches synchronously and records the delivery in the ledger' {
        Send-YurunaNotification -EventCode $UnsubscribedEventCode -EventMessage 'subject' -EventNote 'body' -Synchronous

        $records = Get-DeliveryRecord -CycleFolder $DispatchDir
        Assert-Equal -Expected 1 -Actual $records.Count -Because 'a send with no ledger record is indistinguishable from a send that never happened'
        Assert-Equal -Expected (Get-ActiveNotifyExtension) -Actual $records[0].extension
        Assert-Equal -Expected 'ok' -Actual $records[0].status
        Assert-Equal -Expected 'sync' -Actual $records[0].mode
        Assert-Equal -Expected $UnsubscribedEventCode -Actual $records[0].eventCode
    }
    It 'dispatches asynchronously by default and records the delivery from the thread job' {
        # The failure path must not block on a multi-second transport roundtrip,
        # but the outcome still has to land in the ledger.
        Send-YurunaNotification -EventCode $UnsubscribedEventCode -EventMessage 'subject' -EventNote 'body'

        $job = Get-Job -Name "Send-Notification-$(Get-ActiveNotifyExtension)" -ErrorAction SilentlyContinue | Select-Object -First 1
        Assert-True ($null -ne $job) 'the async path hands the send to a thread job'
        $null = Wait-Job -Job $job -Timeout 60
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

        $records = Get-DeliveryRecord -CycleFolder $DispatchDir
        Assert-Equal -Expected 1 -Actual $records.Count
        Assert-Equal -Expected 'async' -Actual $records[0].mode
        Assert-Equal -Expected 'ok' -Actual $records[0].status
    }
}

Describe 'Send-CycleFailureNotification' {
    BeforeAll {
        $null = New-Item -ItemType Directory -Path $EnvelopeDir -Force
        Initialize-TestCycleFolder -Path $EnvelopeDir
    }
    AfterAll {
        Initialize-TestCycleFolder -Path ''
        Initialize-NotifyCapture -Value $null
        Remove-Item -LiteralPath $EnvelopeDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    BeforeEach { Initialize-NotifyCapture -Value $null }

    It 'ships the cycle.failure envelope synchronously' {
        # Synchronous by contract: a bootstrap failure calls this immediately
        # before the process exits, and a fire-and-forget job would be killed on
        # exit with the escalation still in it.
        Mock -CommandName Send-YurunaNotification -ModuleName Test.Notify -MockWith {
            Initialize-NotifyCapture -Value @{
                EventCode    = $EventCode
                EventMessage = $EventMessage
                EventNote    = $EventNote
                EventData    = $EventData
                Synchronous  = [bool]$Synchronous
            }
        }
        Send-CycleFailureNotification -HostType 'host.windows.hyper-v' -SubjectSuffix 'ubuntu-24 / waitForText' `
            -GuestKey 'ubuntu-24' -StepName 'waitForText' -ErrorMessage 'timed out' -CycleId 'cycle-000042' -GitCommit 'abc1234' `
            -DefaultFailureClass 'ocr_timeout' -DefaultSeverity 'hard'

        $cap = Get-NotifyCapture
        Assert-True ($null -ne $cap) 'the dispatcher was called'
        Assert-Equal -Expected 'cycle.failure' -Actual $cap.EventCode
        Assert-Equal -Expected 'Yuruna Test: FAIL on host.windows.hyper-v / ubuntu-24 / waitForText' -Actual $cap.EventMessage
        Assert-Equal -Expected $true -Actual $cap.Synchronous
        Assert-True ($cap.EventNote -match '(?m)^Error:\s+timed out$') 'the body carries the failure'
        Assert-Equal -Expected 'ocr_timeout' -Actual $cap.EventData['failureClass'] -Because 'a bootstrap caller lets the helper build the payload'
        Assert-Equal -Expected 'hard' -Actual $cap.EventData['severity']
    }
    It 'ships the caller-supplied payload untouched rather than rebuilding it' {
        # The in-cycle sites run remediation against the payload BEFORE the send;
        # rebuilding it here would drop whatever the remediator wrote onto it.
        Mock -CommandName Send-YurunaNotification -ModuleName Test.Notify -MockWith {
            Initialize-NotifyCapture -Value @{ EventData = $EventData; EventNote = $EventNote }
        }
        $payload = @{ failureClass = 'ssh_timeout'; severity = 'hard'; remediationAttempted = 'restart-guest' }
        Send-CycleFailureNotification -HostType 'host.ubuntu.kvm' -SubjectSuffix 'g / s' -GuestKey 'g' -StepName 's' `
            -ErrorMessage 'boom' -CycleId 'c' -GitCommit 'gc' -EventData $payload

        $cap = Get-NotifyCapture
        Assert-True ([object]::ReferenceEquals($cap.EventData, $payload)) 'the remediated payload instance is the one that ships'
        Assert-Equal -Expected 'restart-guest' -Actual $cap.EventData['remediationAttempted']
        Assert-True ($cap.EventNote -match 'ssh_timeout') 'the body trailer is built from that same payload'
    }
    It 'feeds the body the raw scalars, not the payload fallbacks' {
        # Get-FailureEventData substitutes action / actionVerb for an empty
        # ErrorMessage. Reading the body's Error: line back out of the payload
        # would silently change the human text for an empty error.
        Mock -CommandName Send-YurunaNotification -ModuleName Test.Notify -MockWith {
            Initialize-NotifyCapture -Value @{ EventNote = $EventNote }
        }
        $payload = @{ failureClass = 'unknown'; action = 'FALLBACK-ACTION'; actionVerb = 'FALLBACK-VERB' }
        Send-CycleFailureNotification -HostType 'ht' -SubjectSuffix 'GitPull' -ErrorMessage '' -StepName '' `
            -CycleId 'c' -GitCommit 'gc' -EventData $payload

        $body = (Get-NotifyCapture).EventNote
        Assert-True ($body -match '(?m)^Error:\s*$') 'an empty error stays empty in the body'
        Assert-True ($body -match '(?m)^Step:\s*$')
        Assert-True ($body -match 'FALLBACK-ACTION') 'the payload itself still reaches the JSON trailer'
    }
}

Describe 'dispatcher command resolution' {
    BeforeAll {
        $null = New-Item -ItemType Directory -Path $ResolveDir -Force
        Initialize-TestCycleFolder -Path $ResolveDir
        # Load the extension, exactly as the first cycle-failure of a process
        # would. Everything below asserts what is true AFTER that has happened,
        # because that is when the shadowing hazard exists at all.
        Send-YurunaNotification -EventCode $UnsubscribedEventCode -EventMessage 'warm-up' -EventNote 'warm-up' -Synchronous
        Remove-Item -LiteralPath (Join-Path $ResolveDir 'notification.delivery.json') -Force -ErrorAction SilentlyContinue
    }
    AfterAll {
        Initialize-TestCycleFolder -Path ''
        Remove-Item -LiteralPath $ResolveDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Extensions are imported -Global and every one of them exports the contract
    # verb Send-Notification. A dispatcher sharing that name would be shadowed by
    # the first extension to load, and each later unqualified caller would reach a
    # transport that has no -Synchronous, no -EventData gate and no delivery
    # ledger -- silently, since the callers wrap the send in try/catch. The
    # dispatcher therefore owns a name no extension can take.
    It 'keeps a name the extension cannot shadow, even once the extension is loaded' {
        $dispatcher = Get-Command Send-YurunaNotification
        Assert-Equal -Expected 'Test.Notify' -Actual $dispatcher.Module.Name `
            -Because 'the dispatcher must still be what callers reach after an extension has been imported -Global'
        Assert-True ($dispatcher.Parameters.ContainsKey('Synchronous')) 'a caller that needs a synchronous send must be able to ask for one'
        Assert-True ($dispatcher.Parameters.ContainsKey('EventData'))   'the structured payload gate lives on the dispatcher'

        # And the contract verb is free for the extension to own, which is the
        # whole reason the two names must differ.
        $transport = Get-Command Send-Notification -ErrorAction SilentlyContinue
        if ($transport) {
            Assert-True ($transport.Module.Name -ne 'Test.Notify') `
                'Send-Notification belongs to the extension; if the dispatcher answered to it too, one of them would be unreachable'
        }
    }

    It 'records a delivery for a second dispatch in the same process' {
        # The outer runner is long-lived and dispatches many times. The failure
        # this guards is the second send onwards, not the first.
        $err = $null
        try {
            Send-YurunaNotification -EventCode $UnsubscribedEventCode -EventMessage 'subject' -EventNote 'body' -Synchronous
        } catch {
            $err = $_.Exception.Message
        }
        Assert-True ($null -eq $err) "a second dispatch in the same process must not throw: $err"
        Assert-Equal -Expected 1 -Actual (Get-DeliveryRecord -CycleFolder $ResolveDir).Count `
            -Because 'a dispatch that leaves no ledger record is an alert nobody can confirm was sent'
    }

    # A source guard, because the runtime one cannot see a caller that is never
    # exercised here. Any product code invoking the bare contract verb is talking
    # to a transport directly, skipping the dispatcher's gates and delivery
    # ledger; this source guard is what stops that from creeping back in.
    It 'has no product caller invoking the extension contract verb directly' {
        $root    = Split-Path -Parent (Split-Path -Parent $here)
        $sources = @(
            Get-ChildItem (Join-Path $root 'test')  -Recurse -Include *.ps1, *.psm1 -File -ErrorAction SilentlyContinue
            Get-ChildItem (Join-Path $root 'tools') -Recurse -Include *.ps1, *.psm1 -File -ErrorAction SilentlyContinue
        ) | Where-Object {
            # The extension itself defines the verb; the dispatcher's own module
            # names it when resolving each extension's command through its module
            # object. Test files are exercise, not product code.
            $_.FullName -notmatch '\\extension\\' -and
            $_.Name -ne 'Test.Notify.psm1' -and
            $_.Name -notlike '*.Tests.ps1'
        }
        $offenders = foreach ($f in $sources) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $calls = $ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Send-Notification'
            }, $true)
            foreach ($c in $calls) { "$($f.Name):$($c.Extent.StartLineNumber)" }
        }
        Assert-Equal -Expected 0 -Actual @($offenders).Count `
            -Because "these call the transport directly, bypassing the dispatch loop and the delivery ledger: $($offenders -join ', ')"
    }
}
