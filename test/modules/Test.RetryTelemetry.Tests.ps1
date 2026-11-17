<#PSScriptInfo
.VERSION 2026.11.16
.GUID 429c8653-8e15-44cd-9478-80a69f7afe99
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test retry telemetry ndjson pester
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
    Pester coverage for the host-side retry telemetry: Yuruna.Retry emits
    retry_attempt / retry_recovered / retry_exhausted NDJSON, and
    Publish-GuestRetryMarker turns the guest bash lib's YURUNA_RETRY stdout
    markers into the same events. Both are validated against the real event
    schema.
.DESCRIPTION
    Test.EventSchema is imported for Test-CycleEventSchema. The NDJSON sink is a
    global Send-CycleEventSafely stub (the module + the extracted function resolve
    it from the global table, Get-Command-guarded). Publish-GuestRetryMarker is
    lifted out of Test.SequenceHandler.psm1 via the parser (no heavy module
    import), the same discipline as the sibling fetch-execute test.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The NDJSON sink is resolved from the global command table at call time, so the collector stub and its assertions must straddle the global scope.')]
param()

BeforeAll {

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)

Import-Module (Join-Path $here 'Test.EventSchema.psm1')        -Force -DisableNameChecking
Import-Module (Join-Path $repoRoot 'automation/Yuruna.Retry.psm1') -Force -DisableNameChecking

# Lift the guest-marker functions out of the module via the parser (its module
# pulls a heavy dep chain; these functions need only each other).
$shModPath = Join-Path $here 'Test.SequenceHandler.psm1'
$modAst = [System.Management.Automation.Language.Parser]::ParseFile($shModPath, [ref]$null, [ref]$null)
foreach ($name in 'ConvertFrom-GuestRetryMarker', 'Get-GuestRetryExhausted', 'Publish-GuestRetryMarker') {
    $fnAst = $modAst.Find({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and $n.Name -eq $name }, $true)
    if (-not $fnAst) { throw "$name not found in Test.SequenceHandler.psm1" }
    . ([scriptblock]::Create($fnAst.Extent.Text))
}

function Invoke-RetryCapturingStderr {
    <# .SYNOPSIS
        Runs a scriptblock and returns the YURUNA_RETRY lines it wrote to the
        process's stderr.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([scriptblock]$ScriptBlock)
    $writer = [IO.StringWriter]::new()
    $previous = [Console]::Error
    [Console]::SetError($writer)
    try { $null = & $ScriptBlock } finally { [Console]::SetError($previous) }
    return [string[]]@($writer.ToString() -split "`r?`n" | Where-Object { $_ -like 'YURUNA_RETRY *' })
}

function Get-GuestExecutionLogFixture {
    <# .SYNOPSIS
        A wrapper log's shape: its header, then each payload line stamped with
        the seconds since that wrapper started.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Script, [string]$PayloadScript, [string[]]$Line)
    return (@('# Yuruna fetch-and-execute log', "# script:    $Script", "# payload-script: $PayloadScript",
        '# started:   2026-01-01T00:00:00Z', '# stepInvocationId: failed-step', '# sequenceInvocationId: failed-sequence',
        '# ---', '# phase: executing-payload', '# ---') + $Line) -join "`n"
}

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

}

Describe 'Yuruna.Retry structured telemetry' {
    It 'emits retry_attempt then retry_exhausted (schema-valid) for a failing scriptblock' {
        $global:__RetryEv = @()
        function global:Send-CycleEventSafely { param($EventRecord) $global:__RetryEv += , $EventRecord }
        try {
            $r = Invoke-WithYurunaRetry -Label 'unit-test' -MaxAttempts 2 -InitialDelaySeconds 1 -ScriptBlock { $global:LASTEXITCODE = 7; 'boom' }
            Assert-StringEqual -Actual $r.Success -Expected $false -Because 'the scriptblock always exits 7'
            Assert-StringEqual -Actual $global:__RetryEv.Count -Expected 2 -Because 'one retry_attempt + one retry_exhausted'
            Assert-StringEqual -Actual $global:__RetryEv[0].event -Expected 'retry_attempt'
            Assert-StringEqual -Actual $global:__RetryEv[0].attempt -Expected 1
            Assert-StringEqual -Actual $global:__RetryEv[0].exitCode -Expected 7
            Assert-StringEqual -Actual $global:__RetryEv[0].stack -Expected 'pwsh'
            Assert-StringEqual -Actual $global:__RetryEv[1].event -Expected 'retry_exhausted'
            Assert-StringEqual -Actual $global:__RetryEv[1].permanent -Expected $false
            foreach ($ev in $global:__RetryEv) {
                $v = @(Test-CycleEventSchema -Record ([hashtable]$ev))
                Assert-StringEqual -Actual $v.Count -Expected 0 -Because "schema violations on $($ev.event): $($v -join '; ')"
            }
        } finally {
            Remove-Item Function:\Send-CycleEventSafely -ErrorAction SilentlyContinue
            Remove-Variable -Name __RetryEv -Scope Global -ErrorAction SilentlyContinue
        }
    }
    It 'emits retry_attempt then retry_recovered (schema-valid), and no retry_exhausted, when a later attempt is accepted as already applied' {
        $global:__RetryEv = @()
        function global:Send-CycleEventSafely { param($EventRecord) $global:__RetryEv += , $EventRecord }
        try {
            $r = Invoke-WithYurunaRetry -Label 'applied' -MaxAttempts 3 -InitialDelaySeconds 1 `
                -ScriptBlock { $global:LASTEXITCODE = 1; 'Error from server (AlreadyExists): namespaces "website" already exists' } `
                -SucceedWhen { param($x) $null = $x; $true }
            Assert-StringEqual -Actual $r.Success -Expected $true -Because 'the second attempt was accepted as the completion of the first'
            Assert-StringEqual -Actual $global:__RetryEv.Count -Expected 2 -Because 'one retry_attempt for the failed first attempt + one retry_recovered'
            Assert-StringEqual -Actual $global:__RetryEv[0].event -Expected 'retry_attempt'
            Assert-StringEqual -Actual $global:__RetryEv[0].attempt -Expected 1
            Assert-StringEqual -Actual $global:__RetryEv[1].event -Expected 'retry_recovered'
            Assert-StringEqual -Actual $global:__RetryEv[1].stack -Expected 'pwsh'
            Assert-StringEqual -Actual $global:__RetryEv[1].description -Expected 'applied'
            Assert-StringEqual -Actual $global:__RetryEv[1].attempt -Expected 2
            Assert-StringEqual -Actual $global:__RetryEv[1].maxAttempts -Expected 3
            Assert-StringEqual -Actual $global:__RetryEv[1].exitCode -Expected 1 -Because 'the event keeps the attempt''s own exit code'
            Assert-StringEqual -Actual $global:__RetryEv[1].basis -Expected 'already-applied'
            Assert-StringEqual -Actual @($global:__RetryEv | Where-Object { $_.event -eq 'retry_exhausted' }).Count -Expected 0 -Because 'nothing was exhausted'
            foreach ($ev in $global:__RetryEv) {
                $v = @(Test-CycleEventSchema -Record ([hashtable]$ev))
                Assert-StringEqual -Actual $v.Count -Expected 0 -Because "schema violations on $($ev.event): $($v -join '; ')"
            }
        } finally {
            Remove-Item Function:\Send-CycleEventSafely -ErrorAction SilentlyContinue
            Remove-Variable -Name __RetryEv -Scope Global -ErrorAction SilentlyContinue
        }
    }
    It 'fail-fasts with a retry_exhausted(permanent) when the predicate says not-retryable' {
        $global:__RetryEv = @()
        function global:Send-CycleEventSafely { param($EventRecord) $global:__RetryEv += , $EventRecord }
        try {
            $null = Invoke-WithYurunaRetry -Label 'perm' -MaxAttempts 5 -InitialDelaySeconds 1 `
                -ScriptBlock { $global:LASTEXITCODE = 22; 'nope' } -ShouldRetry { param($x) $null = $x; $false }
            Assert-StringEqual -Actual $global:__RetryEv.Count -Expected 1 -Because 'fail-fast emits exactly one terminal event'
            Assert-StringEqual -Actual $global:__RetryEv[0].event -Expected 'retry_exhausted'
            Assert-StringEqual -Actual $global:__RetryEv[0].permanent -Expected $true
        } finally {
            Remove-Item Function:\Send-CycleEventSafely -ErrorAction SilentlyContinue
            Remove-Variable -Name __RetryEv -Scope Global -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Yuruna.Retry in a guest payload' {
    BeforeEach {
        Remove-Item Function:\Send-CycleEventSafely -ErrorAction SilentlyContinue
        $script:savedWrapper = Save-YurunaTestEnvironment -Name 'FAE_INVOCATION_SCRIPT'
    }
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:savedWrapper }

    It 'prints each record as a YURUNA_RETRY marker in the bash library''s shape under the fetch wrapper' {
        $env:FAE_INVOCATION_SCRIPT = 'project/example/workload.sh'
        $lines = Invoke-RetryCapturingStderr {
            Invoke-WithYurunaRetry -Label 'kubectl create namespace example' -MaxAttempts 2 -InitialDelaySeconds 1 -WindowSeconds 600 `
                -ScriptBlock { $global:LASTEXITCODE = 1; 'Error from server: etcdserver: request timed out' }
            Invoke-WithYurunaRetry -Label 'applied' -MaxAttempts 3 -InitialDelaySeconds 1 `
                -ScriptBlock { $global:LASTEXITCODE = 1; 'Error from server (AlreadyExists): namespaces "example" already exists' } `
                -SucceedWhen { param($x) $null = $x; $true }
            Invoke-WithYurunaRetry -Label 'perm' -MaxAttempts 5 -InitialDelaySeconds 1 `
                -ScriptBlock { $global:LASTEXITCODE = 22; 'nope' } -ShouldRetry { param($x) $null = $x; $false }
        }
        $records = @($lines | ForEach-Object { $_.Substring('YURUNA_RETRY '.Length) | ConvertFrom-Json })
        Assert-StringEqual -Actual (($records | ForEach-Object { "$($_.label)/$($_.event)/$($_.outcome)" }) -join '|') -Expected (@(
            'kubectl create namespace example/attempt/', 'kubectl create namespace example/outcome/exhausted',
            'applied/attempt/', 'applied/outcome/recovered', 'perm/outcome/permanent') -join '|')
        foreach ($record in $records) {
            Assert-StringEqual -Actual $record.stack -Expected 'pwsh'
            Assert-True ($null -ne $record.elapsedSeconds) "every record carries elapsedSeconds: $($record | ConvertTo-Json -Compress)"
        }
        Assert-Equal -Expected 1 -Actual ([int]$records[0].attempt)
        Assert-Equal -Expected 2 -Actual ([int]$records[0].maxAttempts)
        Assert-Equal -Expected 1 -Actual ([int]$records[0].rc)
        Assert-True ([bool]$records[0].transient) 'the etcd timeout is a transient failure'
        Assert-Equal -Expected 1 -Actual ([int]$records[0].sleepSeconds)
        Assert-Equal -Expected 600 -Actual ([int]$records[0].windowSeconds)
        Assert-Equal -Expected 2 -Actual ([int]$records[1].attempt) -Because 'the exhausted outcome names the last attempt'
        Assert-StringEqual -Actual $records[3].basis -Expected 'already-applied'
        Assert-Equal -Expected 1 -Actual ([int]$records[3].rc) -Because 'the recovered outcome keeps the attempt''s own exit code'
        Assert-True ([bool]$records[4].permanent) 'a fail-fast predicate ends the retry as permanent'
        Assert-False ($records[2].PSObject.Properties.Name -contains 'windowSeconds') 'windowSeconds appears only on a windowed retry'
    }

    It 'prints nothing outside the fetch wrapper, and sends the event instead of a marker where the cycle stream exists' {
        $env:FAE_INVOCATION_SCRIPT = $null
        $lines = Invoke-RetryCapturingStderr {
            Invoke-WithYurunaRetry -Label 'standalone' -MaxAttempts 2 -InitialDelaySeconds 1 -ScriptBlock { $global:LASTEXITCODE = 7; 'boom' }
        }
        Assert-Equal -Expected 0 -Actual @($lines).Count -Because 'a host-side standalone tool prints no marker'

        $env:FAE_INVOCATION_SCRIPT = 'project/example/workload.sh'
        $global:__RetryEv = @()
        function global:Send-CycleEventSafely { param($EventRecord) $global:__RetryEv += , $EventRecord }
        try {
            $lines = Invoke-RetryCapturingStderr {
                Invoke-WithYurunaRetry -Label 'in-cycle' -MaxAttempts 2 -InitialDelaySeconds 1 -ScriptBlock { $global:LASTEXITCODE = 7; 'boom' }
            }
            Assert-Equal -Expected 0 -Actual @($lines).Count -Because 'a process with a cycle stream sends the event and prints no marker'
            Assert-Equal -Expected 2 -Actual $global:__RetryEv.Count
        } finally {
            Remove-Item Function:\Send-CycleEventSafely -ErrorAction SilentlyContinue
            Remove-Variable -Name __RetryEv -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'is told apart by a variable the fetch wrapper exports to its payload' {
        $wrapper = Get-Content -Raw -LiteralPath (Join-Path $repoRoot 'automation/fetch-and-execute.sh')
        Assert-Match -Pattern '(?m)^export FAE_INVOCATION_SCRIPT\s*$' -Actual $wrapper `
            -Because 'Yuruna.Retry prints its markers only where the wrapper exported this variable'
    }
}

Describe 'Publish-GuestRetryMarker (guest bash marker -> NDJSON)' {
    It 'parses YURUNA_RETRY markers, emits schema-valid retry_attempt events, and skips malformed lines' {
        $global:__RetryEv = @()
        function global:Send-CycleEventSafely { param($EventRecord) $global:__RetryEv += , $EventRecord }
        try {
            $out = @(
                'Installing PowerShell ...',
                'YURUNA_RETRY {"stack":"bash","label":"curl_retry","attempt":2,"maxAttempts":5,"rc":22,"permanent":false}',
                'some other guest output',
                'YURUNA_RETRY {"stack":"bash","label":"apt_retry","attempt":1,"maxAttempts":5,"rc":100,"permanent":false}',
                'YURUNA_RETRY {bad json here',
                '  YURUNA_RETRY {"stack":"bash","label":"curl_retry","attempt":3,"maxAttempts":5,"rc":6,"permanent":true}'
            )
            $n = Publish-GuestRetryMarker -Output $out -GuestKey 'guest.ubuntu.server.26' -VmName 'test-a'
            Assert-StringEqual -Actual $n -Expected 3 -Because 'three well-formed markers; the malformed line is skipped'
            Assert-StringEqual -Actual $global:__RetryEv.Count -Expected 3
            Assert-StringEqual -Actual $global:__RetryEv[0].event -Expected 'retry_attempt'
            Assert-StringEqual -Actual $global:__RetryEv[0].stack -Expected 'bash'
            Assert-StringEqual -Actual $global:__RetryEv[0].description -Expected 'curl_retry'
            Assert-StringEqual -Actual $global:__RetryEv[0].exitCode -Expected 22
            Assert-StringEqual -Actual $global:__RetryEv[0].guestKey -Expected 'guest.ubuntu.server.26'
            Assert-StringEqual -Actual $global:__RetryEv[2].permanent -Expected $true
            foreach ($ev in $global:__RetryEv) {
                $v = @(Test-CycleEventSchema -Record ([hashtable]$ev))
                Assert-StringEqual -Actual $v.Count -Expected 0 -Because "schema violations: $($v -join '; ')"
            }
        } finally {
            Remove-Item Function:\Send-CycleEventSafely -ErrorAction SilentlyContinue
            Remove-Variable -Name __RetryEv -Scope Global -ErrorAction SilentlyContinue
        }
    }
    It 'returns 0 for null output' {
        function global:Send-CycleEventSafely { param($EventRecord) $null = $EventRecord }
        try { Assert-StringEqual -Actual (Publish-GuestRetryMarker -Output $null) -Expected 0 }
        finally { Remove-Item Function:\Send-CycleEventSafely -ErrorAction SilentlyContinue }
    }

    It 'maps each record''s event to its retry event and carries the guest''s fields' {
        $global:__RetryEv = @()
        function global:Send-CycleEventSafely { param($EventRecord) $global:__RetryEv += , $EventRecord }
        try {
            $url = 'https://github.com/example-org/example-tool/releases/download/v1.2.3/tool.tar.gz'
            $out = @(
                'YURUNA_RETRY {"stack":"bash","label":"curl_retry","event":"attempt","attempt":1,"maxAttempts":34,"rc":22,"permanent":false,"windowSeconds":1800,"url":"__URL__","httpStatus":504,"elapsedSeconds":16}',
                'YURUNA_RETRY {"stack":"bash","label":"curl_retry","event":"outcome","outcome":"exhausted","attempt":31,"maxAttempts":31,"rc":22,"windowSeconds":1800,"url":"__URL__","httpStatus":504,"elapsedSeconds":1812}',
                'YURUNA_RETRY {"stack":"bash","label":"wget_try","event":"outcome","outcome":"permanent","attempt":1,"maxAttempts":5,"rc":8,"url":"https://downloads.example.org/missing.tar.gz","httpStatus":404,"elapsedSeconds":2}',
                'YURUNA_RETRY {"stack":"pwsh","label":"kubectl create namespace example","event":"attempt","attempt":1,"maxAttempts":5,"rc":1,"transient":true,"sleepSeconds":9,"elapsedSeconds":30}',
                'YURUNA_RETRY {"stack":"pwsh","label":"kubectl create namespace example","event":"outcome","outcome":"recovered","attempt":2,"maxAttempts":5,"rc":1,"basis":"already-applied","elapsedSeconds":41}'
            )
            $out = @($out | ForEach-Object { $_.Replace('__URL__', $url) })
            $n = Publish-GuestRetryMarker -Output $out -GuestKey 'guest.ubuntu.server.26' -VmName 'test-a' -StepInvocationId 'step-7'
            Assert-Equal -Expected 5 -Actual $n
            Assert-StringEqual -Actual (($global:__RetryEv | ForEach-Object { $_.event }) -join ',') `
                -Expected 'retry_attempt,retry_exhausted,retry_exhausted,retry_attempt,retry_recovered'
            $attempt, $exhausted, $permanent, $pwshAttempt, $recovered = $global:__RetryEv
            Assert-StringEqual -Actual $attempt.url -Expected $url
            Assert-Equal -Expected 504 -Actual $attempt.httpStatus
            Assert-Equal -Expected 16 -Actual $attempt.elapsedSeconds
            Assert-Equal -Expected 1800 -Actual $attempt.windowSeconds
            Assert-Equal -Expected 31 -Actual $exhausted.attempt
            Assert-Equal -Expected 1812 -Actual $exhausted.elapsedSeconds
            Assert-Equal -Expected $false -Actual $exhausted.permanent -Because 'the window ran out; nothing classified the failure as permanent'
            Assert-Equal -Expected $true -Actual $permanent.permanent -Because 'a classified 404 ends the retry as permanent'
            Assert-Equal -Expected 404 -Actual $permanent.httpStatus
            Assert-StringEqual -Actual $pwshAttempt.stack -Expected 'pwsh'
            Assert-Equal -Expected $true -Actual $pwshAttempt.transient
            Assert-Equal -Expected 9 -Actual $pwshAttempt.sleepSeconds
            Assert-StringEqual -Actual $recovered.basis -Expected 'already-applied'
            Assert-StringEqual -Actual $recovered.description -Expected 'kubectl create namespace example'
            foreach ($ev in $global:__RetryEv) {
                Assert-StringEqual -Actual $ev.origin -Expected 'guest'
                Assert-StringEqual -Actual $ev.stepInvocationId -Expected 'step-7'
                Assert-StringEqual -Actual $ev.vmName -Expected 'test-a'
                $v = @(Test-CycleEventSchema -Record ([hashtable]$ev))
                Assert-StringEqual -Actual $v.Count -Expected 0 -Because "schema violations on $($ev.event): $($v -join '; ')"
            }
        } finally {
            Remove-Item Function:\Send-CycleEventSafely -ErrorAction SilentlyContinue
            Remove-Variable -Name __RetryEv -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'publishes the record a guest pwsh retry printed' {
        $saved = Save-YurunaTestEnvironment -Name 'FAE_INVOCATION_SCRIPT'
        Remove-Item Function:\Send-CycleEventSafely -ErrorAction SilentlyContinue
        try {
            $env:FAE_INVOCATION_SCRIPT = 'project/example/workload.sh'
            $printed = Invoke-RetryCapturingStderr {
                Invoke-WithYurunaRetry -Label 'kubectl create namespace example' -MaxAttempts 3 -InitialDelaySeconds 1 `
                    -ScriptBlock { $global:LASTEXITCODE = 1; 'Error from server (AlreadyExists): namespaces "example" already exists' } `
                    -SucceedWhen { param($x) $null = $x; $true }
            }
        } finally { Restore-YurunaTestEnvironment -Saved $saved }
        $global:__RetryEv = @()
        function global:Send-CycleEventSafely { param($EventRecord) $global:__RetryEv += , $EventRecord }
        try {
            $null = Publish-GuestRetryMarker -Output $printed -VmName 'test-a'
            Assert-StringEqual -Actual (($global:__RetryEv | ForEach-Object { "$($_.stack)/$($_.event)" }) -join ',') -Expected 'pwsh/retry_attempt,pwsh/retry_recovered'
            Assert-StringEqual -Actual $global:__RetryEv[1].basis -Expected 'already-applied'
        } finally {
            Remove-Item Function:\Send-CycleEventSafely -ErrorAction SilentlyContinue
            Remove-Variable -Name __RetryEv -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'reads a wrapper log''s stamped lines, once per record when a nested wrapper wrote each line twice' {
        $attempt1 = 'YURUNA_RETRY {"stack":"bash","label":"apt_retry","event":"attempt","attempt":1,"maxAttempts":5,"rc":100,"permanent":false,"elapsedSeconds":0}'
        $attempt2 = 'YURUNA_RETRY {"stack":"bash","label":"apt_retry","event":"attempt","attempt":2,"maxAttempts":5,"rc":100,"permanent":false,"elapsedSeconds":8}'
        # Two apt_retry calls whose first attempts failed alike: a genuine
        # repeat, which each wrapper wrote once more in its own stamped copy.
        $nested = Get-GuestExecutionLogFixture -Script 'guest/ubuntu.server.26/ubuntu.server.26.update.sh' -PayloadScript 'guest/shared/ubuntu.update.sh' -Line @(
            "[  10.100] $attempt1", "[  10.389] $attempt1", '[  18.200] !! apt_retry: sleeping 8s', "[  18.300] $attempt2",
            "[  18.589] $attempt2", "[  40.000] $attempt1", "[  40.289] $attempt1")
        $single = Get-GuestExecutionLogFixture -Script 'project/example/workload.sh' -PayloadScript 'project/example/workload.sh' -Line @(
            "[  10.100] $attempt1", "[  40.000] $attempt1")
        Assert-Equal -Expected 3 -Actual @(ConvertFrom-GuestRetryMarker -Output $nested -FromExecutionLog).Count -Because 'each record once, the genuine repeat kept'
        Assert-StringEqual -Actual ((ConvertFrom-GuestRetryMarker -Output $nested -FromExecutionLog | ForEach-Object { $_.attempt }) -join ',') -Expected '1,2,1'
        Assert-StringEqual -Actual ((ConvertFrom-GuestRetryMarker -Output $nested -FromExecutionLog | ForEach-Object { $_.logSeconds }) -join ',') `
            -Expected '10.389,18.589,40.289' -Because 'a nested pair keeps the later stamp, the outer wrapper''s'
        # The outer wrapper's copy can reach the log before the nested one's.
        $raced = Get-GuestExecutionLogFixture -Script 'guest/ubuntu.server.26/ubuntu.server.26.update.sh' -PayloadScript 'guest/shared/ubuntu.update.sh' -Line @(
            "[  18.589] $attempt2", "[  18.300] $attempt2")
        Assert-Equal -Expected 18.589 -Actual (ConvertFrom-GuestRetryMarker -Output $raced -FromExecutionLog).logSeconds
        Assert-Equal -Expected 2 -Actual @(ConvertFrom-GuestRetryMarker -Output $single -FromExecutionLog).Count -Because 'a log one wrapper wrote keeps every line'
        Assert-StringEqual -Actual ((ConvertFrom-GuestRetryMarker -Output $single -FromExecutionLog | ForEach-Object { $_.logSeconds }) -join ',') -Expected '10.1,40'
        Assert-Equal -Expected 0 -Actual @(ConvertFrom-GuestRetryMarker -Output $single).Count -Because 'SSH output is never stamped, so a stamped line there is not a record'
    }

    It 'names the last retry that gave up in a log, when it gave up and when the log ended, and nothing for a log without one' {
        $url = 'https://github.com/example-org/example-tool/releases/download/v1.2.3/tool.tar.gz'
        $log = Get-GuestExecutionLogFixture -Script 'guest/ubuntu.server.26/ubuntu.server.26.update.sh' -PayloadScript 'guest/shared/ubuntu.update.sh' -Line @(
            '[   5.000] YURUNA_RETRY {"stack":"bash","label":"curl_retry","event":"attempt","attempt":1,"maxAttempts":34,"rc":22,"permanent":false,"windowSeconds":1800,"url":"https://github.com/example-org/example-tool/releases/latest","httpStatus":504,"elapsedSeconds":16}',
            '[   5.289] YURUNA_RETRY {"stack":"bash","label":"curl_retry","event":"attempt","attempt":1,"maxAttempts":34,"rc":22,"permanent":false,"windowSeconds":1800,"url":"https://github.com/example-org/example-tool/releases/latest","httpStatus":504,"elapsedSeconds":16}',
            '[ 900.000] YURUNA_RETRY {"stack":"bash","label":"curl_retry","event":"outcome","outcome":"exhausted","attempt":31,"maxAttempts":31,"rc":22,"windowSeconds":1800,"url":"__URL__","httpStatus":504,"elapsedSeconds":1812}',
            '[ 900.289] YURUNA_RETRY {"stack":"bash","label":"curl_retry","event":"outcome","outcome":"exhausted","attempt":31,"maxAttempts":31,"rc":22,"windowSeconds":1800,"url":"__URL__","httpStatus":504,"elapsedSeconds":1812}',
            '[ 950.000] YURUNA_RETRY {"stack":"pwsh","label":"kubectl create namespace example","event":"outcome","outcome":"recovered","attempt":2,"maxAttempts":5,"rc":1,"basis":"already-applied","elapsedSeconds":41}',
            '[ 950.289] YURUNA_RETRY {"stack":"pwsh","label":"kubectl create namespace example","event":"outcome","outcome":"recovered","attempt":2,"maxAttempts":5,"rc":1,"basis":"already-applied","elapsedSeconds":41}')
        $priorCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            # pt-BR reads '900.289' as 900289, so a stamp must parse invariantly.
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('pt-BR')
            $exhausted = Get-GuestRetryExhausted -ExecutionLog $log.Replace('__URL__', $url)
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $priorCulture }
        Assert-StringEqual -Actual (($exhausted.Keys) -join ',') -Expected 'label,outcome,url,httpStatus,rc,attempts,maxAttempts,windowSeconds,elapsedSeconds,atSeconds,logEndSeconds'
        Assert-StringEqual -Actual $exhausted.label -Expected 'curl_retry'
        Assert-StringEqual -Actual $exhausted.outcome -Expected 'exhausted'
        Assert-StringEqual -Actual $exhausted.url -Expected $url
        Assert-Equal -Expected 504 -Actual $exhausted.httpStatus
        Assert-Equal -Expected 22 -Actual $exhausted.rc
        Assert-Equal -Expected 31 -Actual $exhausted.attempts
        Assert-Equal -Expected 31 -Actual $exhausted.maxAttempts
        Assert-Equal -Expected 1800 -Actual $exhausted.windowSeconds
        Assert-Equal -Expected 1812 -Actual $exhausted.elapsedSeconds
        Assert-Equal -Expected 900.289 -Actual $exhausted.atSeconds -Because 'the outcome record''s later copy, the outer wrapper''s'
        Assert-Equal -Expected 950.289 -Actual $exhausted.logEndSeconds -Because 'the log went on 50 seconds past the retry that gave up'

        $pwsh = Get-GuestRetryExhausted -ExecutionLog (Get-GuestExecutionLogFixture -Script 'a.sh' -PayloadScript 'a.sh' -Line @(
            '[   9.000] YURUNA_RETRY {"stack":"pwsh","label":"tofu init (example)","event":"outcome","outcome":"permanent","attempt":1,"maxAttempts":5,"rc":1,"permanent":true,"elapsedSeconds":3}'))
        Assert-StringEqual -Actual $pwsh.outcome -Expected 'permanent'
        Assert-Null -Actual $pwsh.url -Because 'a record without a URL leaves it null'
        Assert-Null -Actual $pwsh.httpStatus
        Assert-Null -Actual $pwsh.windowSeconds
        Assert-Equal -Expected 9 -Actual $pwsh.atSeconds
        Assert-Equal -Expected 9 -Actual $pwsh.logEndSeconds

        # A wrapper without a high-resolution clock writes its log unstamped.
        $unstamped = Get-GuestRetryExhausted -ExecutionLog (Get-GuestExecutionLogFixture -Script 'a.sh' -PayloadScript 'a.sh' -Line @(
            'YURUNA_RETRY {"stack":"bash","label":"apt_retry","event":"outcome","outcome":"exhausted","attempt":5,"maxAttempts":5,"rc":100,"elapsedSeconds":151}'))
        Assert-StringEqual -Actual $unstamped.label -Expected 'apt_retry'
        Assert-Null -Actual $unstamped.atSeconds
        Assert-Null -Actual $unstamped.logEndSeconds

        $recoveredOnly = Get-GuestExecutionLogFixture -Script 'a.sh' -PayloadScript 'a.sh' -Line @(
            '[   9.000] YURUNA_RETRY {"stack":"bash","label":"apt_retry","event":"attempt","attempt":1,"maxAttempts":5,"rc":100,"permanent":false,"elapsedSeconds":0}',
            '[  20.000] YURUNA_RETRY {"stack":"pwsh","label":"kubectl create namespace example","event":"outcome","outcome":"recovered","attempt":2,"maxAttempts":5,"rc":1,"elapsedSeconds":41}')
        Assert-Null -Actual (Get-GuestRetryExhausted -ExecutionLog $recoveredOnly) -Because 'a retry that recovered gave nothing up'
        Assert-Null -Actual (Get-GuestRetryExhausted -ExecutionLog $null)
    }
}
