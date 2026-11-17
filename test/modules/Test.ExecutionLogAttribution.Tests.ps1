<#PSScriptInfo
.VERSION 2026.11.16
.GUID 42a2e5eb-3669-4a46-8c83-b6e76b040378
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test diagnostic execution provenance pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:diagnosticAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'Test.Diagnostic.psm1'), [ref]$null, [ref]$null)
    $script:runnerAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'Test.RunnerInnerLoop.psm1'), [ref]$null, [ref]$null)
    function Get-AttributionFunction {
        param($Ast, [string]$Name)
        $node = $Ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
        if (-not $node) { throw "Missing function $Name" }
        return $node.Extent.Text
    }
    $script:verdictSource = Get-AttributionFunction $script:diagnosticAst 'Get-GuestExecutionLogVerdict'
    $script:contextSource = Get-AttributionFunction $script:runnerAst 'Get-FailureExecutionLogContext'
    $script:invocationSource = Get-AttributionFunction $script:runnerAst 'Get-FailureDiagnosticInvocation'
    $script:writerSource = Get-AttributionFunction $script:runnerAst 'Write-CycleFailureExecutionTail'
    $script:failurePublishSource = Get-AttributionFunction $script:runnerAst 'Publish-FailureGuestRetryMarker'
    # The guest retry records' reader and publisher live with the sequence verbs.
    $handlerAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $PSScriptRoot 'Test.SequenceHandler.psm1'), [ref]$null, [ref]$null)
    $script:markerSource = @('ConvertFrom-GuestRetryMarker', 'Get-GuestRetryExhausted', 'Publish-GuestRetryMarker' |
        ForEach-Object { Get-AttributionFunction $handlerAst $_ }) -join "`n"
    . ([scriptblock]::Create($script:verdictSource))
    . ([scriptblock]::Create($script:contextSource))
    . ([scriptblock]::Create($script:invocationSource))
    . ([scriptblock]::Create($script:writerSource))
    . ([scriptblock]::Create($script:markerSource))
    # A nested wrapper's log: every payload line twice, once per wrapper.
    function New-RetryAttributionLog {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Constructs an in-memory log fixture without changing state.')]
        param([string]$Step='failed-step', [string[]]$Line, [int]$ExitCode=22)
        $attempt = 'YURUNA_RETRY {"stack":"bash","label":"curl_retry","event":"attempt","attempt":1,"maxAttempts":2,"rc":22,"permanent":false,"url":"https://downloads.example.org/pool/tool.tar.gz","httpStatus":504,"elapsedSeconds":16}'
        $outcome = 'YURUNA_RETRY {"stack":"bash","label":"curl_retry","event":"outcome","outcome":"exhausted","attempt":2,"maxAttempts":2,"rc":22,"url":"https://downloads.example.org/pool/tool.tar.gz","httpStatus":504,"elapsedSeconds":40}'
        if (-not $Line) { $Line = "[  16.100] $attempt", "[  16.389] $attempt", "[  40.100] $outcome", "[  40.389] $outcome" }
        return (@('# Yuruna fetch-and-execute log', '# script:    project/example/workload.sh', '# payload-script: project/shared/workload.sh',
            '# started:   2026-10-10T12:44:00Z', "# stepInvocationId: $Step", '# sequenceInvocationId: failed-sequence', '# ---') +
            $Line + "# exit code: $ExitCode") -join "`n"
    }
    function New-AttributionLog {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Constructs an in-memory log fixture without changing state.')]
        param([string]$ScriptPath='project/example/workload.sh', [string]$Step='failed-step', [string]$Sequence='failed-sequence')
        return @('# Yuruna fetch-and-execute log', "# script:    $ScriptPath", '# started:   2026-10-10T12:44:00Z',
            "# stepInvocationId: $Step", "# sequenceInvocationId: $Sequence", '# ---', '# phase: fetch',
            '# url: https://example.invalid/pinned/workload.sh', '!! FETCH FAILED', '# exit code: 2') -join "`n"
    }
    function New-AttributionFailure {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Constructs an in-memory failure record without changing state.')]
        param()
        return @{ reason='step'; vmName='vm'; guestKey='guest'; stepInvocationId='failed-step'; sequenceInvocationId='failed-sequence';
            action='fetchAndExecute: "/usr/local/lib/yuruna/fetch-and-execute.sh project/example/workload.sh"';
            context=@{causeDetail=@{ocrTail='current fetch failed'; executionTail='obsolete tail'; executionLogPath='obsolete.log';
                retryExhausted=@{label='obsolete'}}} }
    }
    function Write-YurunaStateFile {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Stub mirrors the writer signature the producers bind by name; it writes whatever it is given.')]
        [CmdletBinding(SupportsShouldProcess)]
        param([string]$Path, [string]$Content, [switch]$WarnOnFailure)
        if ($PSCmdlet.ShouldProcess($Path, 'Write test state')) { [IO.File]::WriteAllText($Path, $Content) }
    }
    function Copy-CycleFailureRecord { }
    function Format-YurunaOperatorMessage {
        param([string]$Key, [hashtable]$Arguments)
        return "$Key $($Arguments.count)"
    }
    $script:priorLogDir = Save-YurunaTestEnvironment -Name 'YURUNA_LOG_DIR'
}

AfterAll {
    Restore-YurunaTestEnvironment -Saved $script:priorLogDir
}

Describe 'execution log identity' {
    It 'accepts a complete current early fetch-failure log before a command profile exists' {
        $result = Get-GuestExecutionLogVerdict -ExecutionLog (New-AttributionLog) -ScriptPath project/example/workload.sh `
            -StepInvocationId failed-step -SequenceInvocationId failed-sequence
        $result.state | Should -Be current
        $result.reasonCode | Should -Be execution-log-current
    }

    It 'accepts CRLF and line-array transport without changing case-sensitive script identity' {
        foreach ($variant in 0,1) {
            $log = if ($variant -eq 0) { (New-AttributionLog).Replace("`n", "`r`n") } else { (New-AttributionLog) -split "`n" }
            $result = Get-GuestExecutionLogVerdict -ExecutionLog $log -ScriptPath project/example/workload.sh `
                -StepInvocationId failed-step -SequenceInvocationId failed-sequence
            $result.state | Should -Be current
        }
    }

    It 'rejects <Name> rather than attributing an unrelated successful log' -ForEach @(
        @{Name='another script with identical invocation IDs'; Script='guest/prior.sh'; Step='failed-step'; Sequence='failed-sequence'; Reason='execution-script-mismatch'}
        @{Name='a nested fetch with identical invocation IDs'; Script='project/example/child.sh'; Step='failed-step'; Sequence='failed-sequence'; Reason='execution-script-mismatch'}
        @{Name='script name differing only by case'; Script='project/example/Workload.sh'; Step='failed-step'; Sequence='failed-sequence'; Reason='execution-script-mismatch'}
        @{Name='another step running the same script'; Script='project/example/workload.sh'; Step='prior-step'; Sequence='failed-sequence'; Reason='execution-step-mismatch'}
        @{Name='another sequence running the same step'; Script='project/example/workload.sh'; Step='failed-step'; Sequence='prior-sequence'; Reason='execution-sequence-mismatch'}
    ) {
        $result = Get-GuestExecutionLogVerdict -ExecutionLog (New-AttributionLog -ScriptPath $Script -Step $Step -Sequence $Sequence) `
            -ScriptPath project/example/workload.sh -StepInvocationId failed-step -SequenceInvocationId failed-sequence
        $result.state | Should -Be stale
        $result.reasonCode | Should -Be $Reason
    }

    It 'leaves <Name> unavailable' -ForEach @(
        @{Name='an absent log'; Transform={param($log) $null=$log; ''}; Reason='execution-log-absent'}
        @{Name='a tail without the header'; Transform={param($log) $null=$log; '# exit code: 0'}; Reason='execution-header-invalid'}
        @{Name='a truncated header'; Transform={param($log) ($log -split '# ---')[0]}; Reason='execution-header-incomplete'}
        @{Name='a missing script'; Transform={param($log) $log -replace '(?m)^# script:.*\n',''}; Reason='execution-header-incomplete'}
        @{Name='a missing step ID'; Transform={param($log) $log -replace '(?m)^# stepInvocationId:.*\n',''}; Reason='execution-header-incomplete'}
        @{Name='a missing sequence ID'; Transform={param($log) $log -replace '(?m)^# sequenceInvocationId:.*\n',''}; Reason='execution-header-incomplete'}
        @{Name='a legacy blank step ID'; Transform={param($log) $log.Replace('failed-step','')}; Reason='execution-header-incomplete'}
        @{Name='a legacy blank sequence ID'; Transform={param($log) $log.Replace('failed-sequence','')}; Reason='execution-header-incomplete'}
        @{Name='duplicate identity fields'; Transform={param($log) $log.Replace('# ---',"# stepInvocationId: failed-step`n# ---")}; Reason='execution-header-incomplete'}
        @{Name='identity fields forged in output'; Transform={param($log) "# Yuruna fetch-and-execute log`n# ---`n$log"}; Reason='execution-header-incomplete'}
        @{Name='an invalid script path'; Transform={param($log) $log.Replace('project/example/workload.sh','../workload.sh')}; Reason='execution-header-invalid'}
        @{Name='an invalid invocation ID'; Transform={param($log) $log.Replace('failed-step','failed step')}; Reason='execution-header-invalid'}
    ) {
        $result = Get-GuestExecutionLogVerdict -ExecutionLog (& $Transform (New-AttributionLog)) -ScriptPath project/example/workload.sh `
            -StepInvocationId failed-step -SequenceInvocationId failed-sequence
        $result.state | Should -Be unavailable
        $result.reasonCode | Should -Be $Reason
    }

    It 'does not infer missing expected identity from the captured log' -ForEach @(
        @{Script=''; Step='failed-step'; Sequence='failed-sequence'; Reason='execution-script-unavailable'}
        @{Script='project/example/workload.sh'; Step=''; Sequence='failed-sequence'; Reason='execution-invocation-unavailable'}
        @{Script='project/example/workload.sh'; Step='failed-step'; Sequence=''; Reason='execution-invocation-unavailable'}
    ) {
        $result = Get-GuestExecutionLogVerdict -ExecutionLog (New-AttributionLog) -ScriptPath $Script -StepInvocationId $Step -SequenceInvocationId $Sequence
        $result.state | Should -Be unavailable
        $result.reasonCode | Should -Be $Reason
    }
}

Describe 'failure record joins' {
    It 'resolves a retry leaf command and leaf IDs while preserving outer crash identity' {
        $record=New-AttributionFailure
        $record.action='retry exhausted (2 attempts): retry exhausted (3 attempts): '+$record.action
        $record.originatingStepInvocationId='leaf-step'; $record.originatingSequenceInvocationId='leaf-sequence'
        $result=Get-FailureExecutionLogContext -Record $record -VMName vm -GuestKey guest
        $result.ScriptPath | Should -BeExactly project/example/workload.sh
        $result.StepInvocationId | Should -Be leaf-step
        $result.SequenceInvocationId | Should -Be leaf-sequence
        $record.reason='crash'
        $result=Get-FailureExecutionLogContext -Record $record -VMName vm -GuestKey guest
        $result.StepInvocationId | Should -Be failed-step
        $result.SequenceInvocationId | Should -Be failed-sequence
    }

    It 'keeps the outer pair when leaf IDs are incomplete' {
        $record=New-AttributionFailure
        $record.originatingStepInvocationId='leaf-step'
        $result=Get-FailureExecutionLogContext -Record $record -VMName vm -GuestKey guest
        $result.StepInvocationId | Should -Be failed-step
        $result.SequenceInvocationId | Should -Be failed-sequence
    }

    It 'does not guess a script for <Name>' -ForEach @(
        @{Name='redacted action'; Action='fetchAndExecute: "***"'}
        @{Name='multiple distinct commands'; Action='fetch-and-execute.sh guest/a.sh and fetch-and-execute.sh guest/b.sh'}
        @{Name='another action'; Action='waitText: "ready"'}
    ) {
        $record=New-AttributionFailure; $record.action=$Action
        (Get-FailureExecutionLogContext -Record $record -VMName vm -GuestKey guest).ScriptPath | Should -BeNullOrEmpty
    }

    It 'ignores another guest or infrastructure record' {
        foreach ($field in 'vmName','guestKey','reason') {
            $record=New-AttributionFailure; $record[$field]='other'
            $result=Get-FailureExecutionLogContext -Record $record -VMName vm -GuestKey guest
            $result.ScriptPath | Should -BeNullOrEmpty
            $result.StepInvocationId | Should -BeNullOrEmpty
            $result.SequenceInvocationId | Should -BeNullOrEmpty
        }
    }
}

Describe 'failure execution-tail enrichment' {
    BeforeEach {
        $env:YURUNA_LOG_DIR=$TestDrive
        $script:failurePath=Join-Path $TestDrive last_failure.json
        New-AttributionFailure | ConvertTo-Json -Depth 8 | Set-Content $script:failurePath
    }

    It 'keeps OCR and adds the bounded current execution tail' {
        $log=(New-AttributionLog)+"`n"+((1..60 | ForEach-Object { "line $_" }) -join "`n")
        Write-CycleFailureExecutionTail -ExecutionLog $log -LogPath ./current.log -VMName vm -GuestKey guest | Out-Null
        $cause=(Get-Content $script:failurePath -Raw | ConvertFrom-Json).context.causeDetail
        $cause.ocrTail | Should -Be 'current fetch failed'
        $cause.executionLog.state | Should -Be current
        $cause.executionLogPath | Should -Be ./current.log
        @($cause.executionTail -split "`n").Count | Should -Be 40
        $cause.executionTail | Should -Match 'line 60'
        $cause.executionTail | Should -Not -Match 'obsolete|line 20\b'
        $cause.PSObject.Properties.Name | Should -Not -Contain 'retryExhausted' -Because 'a log whose retries all held gave nothing up'
    }

    It 'names the last guest retry that gave up during the failed step, from the current log' {
        Write-CycleFailureExecutionTail -ExecutionLog (New-RetryAttributionLog) -LogPath ./current.log -VMName vm -GuestKey guest | Out-Null
        $cause=(Get-Content $script:failurePath -Raw | ConvertFrom-Json -AsHashtable).context.causeDetail
        $cause.executionLog.state | Should -Be current
        $retry=$cause.retryExhausted
        $retry.label | Should -BeExactly curl_retry
        $retry.outcome | Should -BeExactly exhausted
        $retry.url | Should -BeExactly 'https://downloads.example.org/pool/tool.tar.gz'
        $retry.httpStatus | Should -Be 504
        $retry.rc | Should -Be 22
        $retry.attempts | Should -Be 2
        $retry.maxAttempts | Should -Be 2
        $retry.windowSeconds | Should -BeNullOrEmpty
        $retry.elapsedSeconds | Should -Be 40
        # The retry that ended the step gave up as the log ended.
        $retry.atSeconds | Should -Be 40.389
        $retry.logEndSeconds | Should -Be 40.389
    }

    It 'names a retry the payload continued past too, stamped long before the log ended' {
        # The script fell back when its download gave up, then failed on
        # something else; the stamps show the retry did not end the step.
        $outcome='YURUNA_RETRY {"stack":"bash","label":"curl_retry","event":"outcome","outcome":"exhausted","attempt":31,"maxAttempts":31,"rc":22,"windowSeconds":1800,"url":"https://github.com/example-org/example-tool/releases/download/v1.2.3/tool-linux-amd64","httpStatus":504,"elapsedSeconds":1805}'
        $fallback='WARNING: the pinned release could not be fetched or verified. Falling back to the distribution package...'
        $notReady='ERROR: node did not reach Ready within 180s; the CNI plugin never initialized.'
        $log=New-RetryAttributionLog -ExitCode 1 -Line @("[ 900.100] $outcome", "[ 900.389] $outcome",
            "[ 900.200] $fallback", "[ 900.489] $fallback", "[2400.000] $notReady", "[2400.289] $notReady")
        Write-CycleFailureExecutionTail -ExecutionLog $log -LogPath ./current.log -VMName vm -GuestKey guest | Out-Null
        $cause=(Get-Content $script:failurePath -Raw | ConvertFrom-Json -AsHashtable).context.causeDetail
        $cause.executionLog.state | Should -Be current
        $cause.retryExhausted.label | Should -BeExactly curl_retry
        $cause.retryExhausted.outcome | Should -BeExactly exhausted
        $cause.retryExhausted.atSeconds | Should -Be 900.389 -Because 'a nested pair keeps the outer wrapper''s stamp, the clock of the log''s last line'
        $cause.retryExhausted.logEndSeconds | Should -Be 2400.289
    }

    It 'removes old enrichment and records <Name> explicitly' -ForEach @(
        @{Name='stale script'; Log={New-AttributionLog -ScriptPath guest/prior.sh}; State='stale'; Reason='execution-script-mismatch'}
        @{Name='stale step'; Log={New-AttributionLog -Step prior}; State='stale'; Reason='execution-step-mismatch'}
        @{Name='stale sequence'; Log={New-AttributionLog -Sequence prior}; State='stale'; Reason='execution-sequence-mismatch'}
        @{Name='incomplete header'; Log={"# Yuruna fetch-and-execute log`n# script: project/example/workload.sh"}; State='unavailable'; Reason='execution-header-incomplete'}
        @{Name='missing capture'; Log={''}; State='unavailable'; Reason='execution-ssh-unavailable'}
    ) {
        Write-CycleFailureExecutionTail -ExecutionLog (& $Log) -LogPath ./wrong.log -VMName vm -GuestKey guest `
            -UnavailableReasonCode execution-ssh-unavailable | Out-Null
        $cause=(Get-Content $script:failurePath -Raw | ConvertFrom-Json -AsHashtable).context.causeDetail
        $cause.ocrTail | Should -Be 'current fetch failed'
        $cause.executionLog.state | Should -Be $State
        $cause.executionLog.reasonCode | Should -Be $Reason
        $cause.ContainsKey('executionTail') | Should -BeFalse
        $cause.ContainsKey('executionLogPath') | Should -BeFalse
        $cause.ContainsKey('retryExhausted') | Should -BeFalse
    }

    It 'replaces the screen''s apt-get update stall with the one a current log names, sources included' {
        $handlerAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Test.SequenceHandler.psm1'), [ref]$null, [ref]$null)
        . ([scriptblock]::Create((Get-AttributionFunction $handlerAst 'Get-GuestAptUpdateStall')))
        $stallLines = @(
            '[ 284.882] Ign:4 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
            '[ 326.039] !! apt_retry: attempt 1/1 stalled; killed by the 300s per-attempt bound (rc=124): sudo env apt-get update'
        ) -join "`n"
        $screenReading = 'attempt 1 of 1 killed at 300s (rc=124)'
        foreach ($case in @(@{ Step = 'failed-step'; Expected = "$screenReading; pending archive.ubuntu.com/ubuntu resolute-backports" },
                @{ Step = 'prior-step'; Expected = $screenReading })) {
            $record = New-AttributionFailure
            $record.context.causeDetail.aptUpdateStall = @{ summary = $screenReading }
            $record | ConvertTo-Json -Depth 8 | Set-Content $script:failurePath
            Write-CycleFailureExecutionTail -ExecutionLog ((New-AttributionLog -Step $case.Step) + "`n" + $stallLines) -LogPath ./current.log -VMName vm -GuestKey guest | Out-Null
            $stall = (Get-Content $script:failurePath -Raw | ConvertFrom-Json).context.causeDetail.aptUpdateStall
            $stall.summary | Should -Be $case.Expected -Because 'only the failed invocation''s own log can refine the screen''s reading'
        }
    }

    It 'records no apt-get update stall from a current log whose next attempt recovered' {
        $handlerAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Test.SequenceHandler.psm1'), [ref]$null, [ref]$null)
        . ([scriptblock]::Create((Get-AttributionFunction $handlerAst 'Get-GuestAptUpdateStall')))
        $recovered = @(
            '[ 284.882] Ign:4 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
            '[ 326.039] !! apt_retry: attempt 1/2 stalled; killed by the 300s per-attempt bound (rc=124): sudo env apt-get update'
            '[ 336.263] >> apt_retry: attempt 2/2 for: sudo env apt-get update'
            '[ 341.756] Hit:4 http://archive.ubuntu.com/ubuntu resolute-backports InRelease'
            '[ 480.100] project git clone failed after 3 attempts'
        ) -join "`n"
        $record = New-AttributionFailure
        $record.context.causeDetail.aptUpdateStall = $null
        $record | ConvertTo-Json -Depth 8 | Set-Content $script:failurePath
        Write-CycleFailureExecutionTail -ExecutionLog ((New-AttributionLog -Step 'failed-step') + "`n" + $recovered) -LogPath ./current.log -VMName vm -GuestKey guest | Out-Null
        $cause = (Get-Content $script:failurePath -Raw | ConvertFrom-Json).context.causeDetail
        $cause.aptUpdateStall | Should -BeNullOrEmpty -Because 'the step failed after the update recovered'
        $cause.executionLogPath | Should -Be './current.log' -Because 'the log was the failed invocation''s own'
    }

    It 'does not mutate another guest failure record' {
        $before=Get-Content $script:failurePath -Raw
        Write-CycleFailureExecutionTail -ExecutionLog (New-AttributionLog) -LogPath ./wrong.log -VMName another -GuestKey guest | Out-Null
        (Get-Content $script:failurePath -Raw) | Should -BeExactly $before
    }

    It 'does not invent a cause block on a crash record' {
        @{reason='crash';vmName='vm';guestKey='guest';context=@{crash=@{error='failure'}}} |
            ConvertTo-Json -Depth 5 | Set-Content $script:failurePath
        Write-CycleFailureExecutionTail -ExecutionLog (New-AttributionLog) -LogPath ./wrong.log -VMName vm -GuestKey guest | Out-Null
        (Get-Content $script:failurePath -Raw | ConvertFrom-Json -AsHashtable).context.ContainsKey('causeDetail') | Should -BeFalse
    }
}

Describe 'failure capture copies only attributed evidence' {
    BeforeAll {
        $copySource=Get-AttributionFunction $script:runnerAst 'Copy-FailureArtifactsToStatusLog'
        $script:sshFixture=New-Module -Name Test.Ssh -ScriptBlock {
            function Invoke-GuestSsh {
                <# .SYNOPSIS
                    Return controlled execution-log and profile evidence without SSH.
                #>
                param($VMName,$GuestKey,$Command,$TimeoutSeconds)
                $null=$VMName,$GuestKey,$TimeoutSeconds
                if ($Command -match 'yuruna-last-fetch-and-execute') {
                    return @{success=$true;exitCode=0;output=$script:log}
                }
                $script:profileReads++
                return @{success=$true;exitCode=0;output='profile evidence'}
            }
            Export-ModuleMember Invoke-GuestSsh
        }
        Import-Module $script:sshFixture -Global -Force
        $fixture=@'
function Import-Module { [CmdletBinding()] param($Name,[switch]$Force,[switch]$Global) $null=$Name,$Force,$Global }
function Get-CycleGuestDataFolder { param($VMName) $null=$VMName; return $script:folder }
function Get-CycleScreenDir { param($VMName,[switch]$WhatIf) $null=$VMName,$WhatIf; return (Join-Path $script:folder 'screens') }
function Get-StableCycleBaseName { return 'cycle' }
function Save-YurunaHostSampleSnapshot { param($DestinationDirectory,$RuntimeDirectory) $null=$DestinationDirectory,$RuntimeDirectory; return @{Status='unavailable'} }
function Save-GuestDiagnostic { param($VMName,$GuestKey,$OutputFolder,$Id,$HostSnapshot,$StepInvocationId,$SequenceInvocationId) $null=$VMName,$GuestKey,$OutputFolder,$Id,$HostSnapshot,$StepInvocationId,$SequenceInvocationId; return @{diagnosticOutcome='unavailable'} }
function Send-CycleEventSafely { param($EventRecord) $script:events += ,$EventRecord }
function Protect-GuestEvidenceText { param($Text) return $Text.Replace('fixture-secret','[REDACTED]') }
function Format-YurunaOperatorMessage { param($Key,$Arguments) $null=$Arguments; return $Key }
function Write-CycleFailureExecutionTail { param($ExecutionLog,$VMName,$GuestKey,$UnavailableReasonCode,$LogPath) $null=$ExecutionLog,$VMName,$GuestKey,$LogPath; $script:reason=$UnavailableReasonCode }
function Set-GuestFailureArtifact { param($GuestKey,$RelativeUrl) $null=$GuestKey,$RelativeUrl }
'@
        $script:copyFixture=New-Module -Name AttributionCapture -ScriptBlock ([scriptblock]::Create(
            $script:verdictSource+"`n"+$script:contextSource+"`n"+$script:invocationSource+"`n"+$copySource+"`n"+
            $script:failurePublishSource+"`n"+$script:markerSource+"`n"+$fixture))
    }

    AfterAll {
        Remove-Module $script:sshFixture -Force
        Remove-Module $script:copyFixture -Force -ErrorAction SilentlyContinue
    }

    It 'copies the current log and profile, with credentials redacted' {
        $env:YURUNA_LOG_DIR=$TestDrive
        $folder=Join-Path $TestDrive current
        [void][IO.Directory]::CreateDirectory($folder)
        New-AttributionFailure | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $folder last_failure.json)
        $log=(New-AttributionLog).Replace('# ---',"# profile: /tmp/yuruna-fae-profile.fixture`n# ---")+"`nfixture-secret"
        & $script:sshFixture {param($text) $script:log=$text; $script:profileReads=0} $log
        & $script:copyFixture {
            param($path) $script:folder=$path
            Copy-FailureArtifactsToStatusLog -VMName vm -GuestKey guest -RepoRoot $path -ModulesDir $path -LogFile fixture
        } $folder | Out-Null
        (Get-Content (Join-Path $folder last-fetch-and-execute.log) -Raw) | Should -Match '\[REDACTED\]'
        (Get-Content (Join-Path $folder last-fetch-and-execute.log) -Raw) | Should -Not -Match 'fixture-secret'
        Test-Path (Join-Path $folder fetch-and-execute-profile.log) | Should -BeTrue
        (& $script:sshFixture {$script:profileReads}) | Should -Be 1
    }

    It 'does not copy a <Name> log or request its profile' -ForEach @(
        @{Name='previous script'; Script='guest/prior.sh'; Step='failed-step'; Sequence='failed-sequence'; Reason='execution-script-mismatch'}
        @{Name='previous invocation'; Script='project/example/workload.sh'; Step='prior-step'; Sequence='failed-sequence'; Reason='execution-step-mismatch'}
        @{Name='previous sequence'; Script='project/example/workload.sh'; Step='failed-step'; Sequence='prior-sequence'; Reason='execution-sequence-mismatch'}
    ) {
        $env:YURUNA_LOG_DIR=$TestDrive
        $folder=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($folder)
        New-AttributionFailure | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $folder last_failure.json)
        $log=(New-AttributionLog -ScriptPath $Script -Step $Step -Sequence $Sequence).Replace(
            '# ---',"# profile: /tmp/yuruna-fae-profile.fixture`n# ---")
        & $script:sshFixture {param($text) $script:log=$text; $script:profileReads=0} $log
        & $script:copyFixture {
            param($path) $script:folder=$path
            Copy-FailureArtifactsToStatusLog -VMName vm -GuestKey guest -RepoRoot $path -ModulesDir $path -LogFile fixture
        } $folder | Out-Null
        Test-Path (Join-Path $folder last-fetch-and-execute.log) | Should -BeFalse
        Test-Path (Join-Path $folder fetch-and-execute-profile.log) | Should -BeFalse
        (& $script:sshFixture {$script:profileReads}) | Should -Be 0
        (& $script:copyFixture {$script:reason}) | Should -Be $Reason
    }

    It '<Name>' -ForEach @(
        @{Name='publishes a failed console fetch''s guest retry records once each'; Verb='fetchAndExecute'; Inner=$null; Step='failed-step'; Expected='retry_attempt,retry_exhausted'}
        @{Name='publishes them for a console fetch that failed inside a retry'; Verb='retry'; Inner='fetchAndExecute'; Step='failed-step'; Expected='retry_attempt,retry_exhausted'}
        @{Name='publishes none from a log another invocation wrote'; Verb='fetchAndExecute'; Inner=$null; Step='prior-step'; Expected=''}
        @{Name='leaves an SSH step''s records to the verb that published them from its output'; Verb='sshFetchAndExecute'; Inner=$null; Step='failed-step'; Expected=''}
        @{Name='leaves an SSH step''s records inside a retry to that verb too'; Verb='retry'; Inner='sshFetchAndExecute'; Step='failed-step'; Expected=''}
    ) {
        $env:YURUNA_LOG_DIR=$TestDrive
        $folder=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($folder)
        $record=New-AttributionFailure; $record.actionVerb=$Verb
        if ($Inner) { $record.innerActionVerb=$Inner }
        $record | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $folder last_failure.json)
        & $script:sshFixture {param($text) $script:log=$text; $script:profileReads=0} (New-RetryAttributionLog -Step $Step)
        $events=& $script:copyFixture {
            param($path) $script:folder=$path; $script:events=@()
            $null=Copy-FailureArtifactsToStatusLog -VMName vm -GuestKey guest -RepoRoot $path -ModulesDir $path -LogFile fixture
            $script:events
        } $folder
        $retry=@($events | Where-Object { [string]$_.event -like 'retry_*' })
        ($retry | ForEach-Object { $_.event }) -join ',' | Should -Be $Expected
        foreach ($ev in $retry) {
            $ev.origin | Should -Be guest
            $ev.stepInvocationId | Should -Be failed-step
            $ev.vmName | Should -Be vm
            $ev.url | Should -Be 'https://downloads.example.org/pool/tool.tar.gz'
            $ev.httpStatus | Should -Be 504
        }
    }
}

Describe 'execution profile attribution' {
    BeforeAll {
        $profileSource=Get-AttributionFunction $script:diagnosticAst 'Save-GuestExecutionProfile'
        # The profile capture classifies the SSH client's own text before it
        # judges the log's identity, so the classifier travels with it.
        $transportSource=Get-AttributionFunction $script:diagnosticAst 'Get-GuestTransportVerdict'
        $fixture=@'
function Invoke-GuestEvidenceSsh { param($VMName,$GuestKey,$Command,$TimeoutSeconds,$MaxCapturedChars) $null=$VMName,$GuestKey,$TimeoutSeconds,$MaxCapturedChars; $script:command=$Command; return $script:response }
function Protect-GuestEvidenceText { param($Text,$Variables) $null=$Variables; return $Text.Replace('fixture-secret','[REDACTED]') }
'@
        $script:profileFixture=New-Module -Name AttributionProfile -ScriptBlock ([scriptblock]::Create(
            $script:verdictSource+"`n"+$transportSource+"`n"+$profileSource+"`n"+$fixture))
    }

    AfterAll { Remove-Module $script:profileFixture -Force -ErrorAction SilentlyContinue }

    It 'retains a current profile with a separate original header and bounded body tail' {
        $body="--- YURUNA EXECUTION LOG ---`n--- YURUNA EXECUTION HEADER ---`n"+(New-AttributionLog)+
            "`n--- YURUNA EXECUTION LOG BODY ---`nbody tail without header`n--- YURUNA COMMAND PROFILE (last 400000 bytes) ---`nfixture-secret"
        & $script:profileFixture {param($text) $script:response=@{success=$true;exitCode=0;output=$text}} $body
        $result=& $script:profileFixture {
            param($folder) Save-GuestExecutionProfile -VMName vm -GuestKey guest -OutputFolder $folder `
                -StepInvocationId failed-step -SequenceInvocationId failed-sequence -ScriptPath project/example/workload.sh
        } $TestDrive
        $result.success | Should -BeTrue
        $result.executionLog.state | Should -Be current
        (Get-Content $result.outPath -Raw) | Should -Match '\[REDACTED\]'
        (& $script:profileFixture {$script:command}) | Should -Match 'head -n 64.*\$f'
    }

    It 'retains a current early fetch-failure execution log as partial without a profile' {
        $body="--- YURUNA EXECUTION LOG ---`n--- YURUNA EXECUTION HEADER ---`n"+(New-AttributionLog)+
            "`n--- YURUNA EXECUTION LOG BODY ---`n!! FETCH FAILED"
        & $script:profileFixture {param($text) $script:response=@{success=$false;exitCode=66;output=$text}} $body
        $result=& $script:profileFixture {
            param($folder) Save-GuestExecutionProfile -VMName vm -GuestKey guest -OutputFolder $folder `
                -StepInvocationId failed-step -SequenceInvocationId failed-sequence -ScriptPath project/example/workload.sh
        } $TestDrive
        $result.success | Should -BeFalse
        $result.diagnosticOutcome | Should -Be partial
        $result.executionLog.state | Should -Be current
        $result.outPath | Should -Not -BeNullOrEmpty
    }

    It 'rejects a profile with <Name>' -ForEach @(
        @{Name='another script'; Script='guest/prior.sh'; Step='failed-step'; Sequence='failed-sequence'; Reason='profile-execution-script-mismatch'}
        @{Name='a nested script'; Script='project/example/child.sh'; Step='failed-step'; Sequence='failed-sequence'; Reason='profile-execution-script-mismatch'}
        @{Name='another step'; Script='project/example/workload.sh'; Step='prior-step'; Sequence='failed-sequence'; Reason='profile-execution-step-mismatch'}
        @{Name='another sequence'; Script='project/example/workload.sh'; Step='failed-step'; Sequence='prior-sequence'; Reason='profile-execution-sequence-mismatch'}
        @{Name='a missing script'; Script=''; Step='failed-step'; Sequence='failed-sequence'; Reason='profile-execution-header-incomplete'}
        @{Name='a missing sequence'; Script='project/example/workload.sh'; Step='failed-step'; Sequence=''; Reason='profile-execution-header-incomplete'}
    ) {
        $body="--- YURUNA EXECUTION LOG ---`n--- YURUNA EXECUTION HEADER ---`n"+
            (New-AttributionLog -ScriptPath $Script -Step $Step -Sequence $Sequence)+
            "`n--- YURUNA EXECUTION LOG BODY ---`n--- YURUNA COMMAND PROFILE (last 400000 bytes) ---`nold profile"
        & $script:profileFixture {param($text) $script:response=@{success=$true;exitCode=0;output=$text}} $body
        $result=& $script:profileFixture {
            param($folder) Save-GuestExecutionProfile -VMName vm -GuestKey guest -OutputFolder $folder `
                -StepInvocationId failed-step -SequenceInvocationId failed-sequence -ScriptPath project/example/workload.sh
        } $TestDrive
        $result.success | Should -BeFalse
        $result.diagnosticOutcome | Should -Be unavailable
        $result.outPath | Should -BeNullOrEmpty
        $result.reasonCode | Should -Be $Reason
    }

    It 'fails closed when the header or one expected identity field is missing' {
        $body="--- YURUNA EXECUTION LOG ---`n--- YURUNA COMMAND PROFILE (last 400000 bytes) ---`nold profile"
        & $script:profileFixture {param($text) $script:response=@{success=$true;exitCode=0;output=$text}} $body
        foreach ($parameters in @(@{ScriptPath='project/example/workload.sh'}, @{SequenceInvocationId='failed-sequence'},
            @{ScriptPath='project/example/workload.sh';SequenceInvocationId='failed-sequence'})) {
            $result=& $script:profileFixture {
                param($folder,$identity) Save-GuestExecutionProfile -VMName vm -GuestKey guest -OutputFolder $folder `
                    -StepInvocationId failed-step @identity
            } $TestDrive $parameters
            $result.success | Should -BeFalse
            $result.outPath | Should -BeNullOrEmpty
            $result.executionLog.state | Should -Be unavailable
        }
    }

    It 'preserves legacy callers that supply neither new identity field' {
        $body="--- YURUNA EXECUTION LOG ---`n# stepInvocationId: failed-step`n--- YURUNA COMMAND PROFILE (last 400000 bytes) ---`nprofile"
        & $script:profileFixture {param($text) $script:response=@{success=$true;exitCode=0;output=$text}} $body
        foreach ($positional in $false,$true) {
            $result=& $script:profileFixture {
                param($folder,$usePositions)
                if ($usePositions) { Save-GuestExecutionProfile vm guest $folder failed-step 20 @{} }
                else { Save-GuestExecutionProfile -VMName vm -GuestKey guest -OutputFolder $folder -StepInvocationId failed-step }
            } $TestDrive $positional
            $result.success | Should -BeTrue
            $result.diagnosticOutcome | Should -Be complete
            (& $script:profileFixture {$script:command}) | Should -Not -Match 'YURUNA EXECUTION HEADER|__IDENTITY_HEADER__'
        }
    }
}
