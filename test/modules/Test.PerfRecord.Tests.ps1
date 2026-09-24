<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42fa6f61-9143-4a1d-9bdb-005d250ec17e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna performance pester
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

<#
.SYNOPSIS
    Exercise emitted invocation identity, legacy aggregation, retries and rendered runs.
#>
BeforeAll {
    $script:Root = Split-Path (Split-Path $PSScriptRoot)
    Import-Module (Join-Path $script:Root 'automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Perf.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Test.PerfAggregate.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'Test.Config.psm1') -Force
    function Get-PerfTestRow {
        param([int]$Ordinal = 1, [long]$Start = 0, [long]$End = 1000,
            [int]$Parent = 0, [string]$Outcome = 'pass', [string]$Invocation = '')
        $origin = [DateTime]::Parse('2026-09-11T00:00:00Z').ToUniversalTime()
        return [ordered]@{
            sequenceName = 'startup'; cycleStartUtc = '2026-09-11T00:00:00Z'
            cycleStartedAtUtc = '2026-09-11T00:00:00Z'; hostUuid = 'host-one'
            vmName = 'temporary-vm'; guestKey = 'guest.ubuntu.server.24'
            sequenceInvocationId = $Invocation
            stepOrdinal = $Ordinal; stepName = "step $Ordinal"; stepKind = 'waitForText'
            parentStepOrdinal = $Parent; outcome = $Outcome
            startedAtUtc = $origin.AddMilliseconds($Start).ToString('o')
            endedAtUtc = $origin.AddMilliseconds($End).ToString('o'); durationMs = $End - $Start
        }
    }
}

Describe 'Performance invocation aggregation' {
    It 'counts a passing retry wrapper once and retains failed attempt detail' {
        $wrapper = Get-PerfTestRow -Ordinal 2 -End 2993500
        $wrapper.stepKind = 'retry'
        $child = Get-PerfTestRow -Parent 2 -End 2400000 -Outcome fail
        $success = Get-PerfTestRow -Parent 2 -Start 2401000 -End 2993300
        $success.parentAttempt = 2
        $final = Get-PerfTestRow -Ordinal 3 -Start 3000000 -End 4613900
        $agg = (ConvertTo-PerfSequenceAggregate -Row @($child, $success, $wrapper, $final)).startup[0]
        $agg.durationMs | Should -Be 4607400
        $agg.elapsedMs | Should -Be 4613900
        $agg.stepCount | Should -Be 2
        $agg.failCount | Should -Be 0
        $agg.retryFailureCount | Should -Be 1
        $agg.steps.Count | Should -Be 4
        $agg.incompleteStepCount | Should -Be 0
    }
    It 'counts an exhausted retry once while retaining all failed attempts' {
        $wrapper = Get-PerfTestRow -End 3000 -Outcome fail
        $wrapper.stepKind = 'retry'
        $children = @(Get-PerfTestRow -Parent 1 -End 900 -Outcome fail; Get-PerfTestRow -Parent 1 -Start 1000 -End 2900 -Outcome timeout)
        $agg = (ConvertTo-PerfSequenceAggregate -Row @($children + $wrapper)).startup[0]
        $agg.stepCount | Should -Be 1
        $agg.failCount | Should -Be 1
        $agg.retryFailureCount | Should -Be 2
        $agg.durationMs | Should -Be 3000
    }
    It 'splits four old sequential invocations even when the VM name is reused' {
        $rows = foreach ($run in 0..3) {
            Get-PerfTestRow -Start ($run * 10000) -End ($run * 10000 + 1000)
            Get-PerfTestRow -Ordinal 2 -Start ($run * 10000 + 1000) -End ($run * 10000 + 2000)
        }
        $aggs = (ConvertTo-PerfSequenceAggregate -Row @($rows)).startup
        $aggs.Count | Should -Be 4
        @($aggs.sequenceInvocationId | Sort-Object -Unique).Count | Should -Be 4
        @($aggs | Where-Object { $_.durationMs -ne 2000 -or $_.elapsedMs -ne 2000 }).Count | Should -Be 0
        @($aggs | Where-Object invocationIdentitySource -ne 'legacy-inferred').Count | Should -Be 0
    }
    It 'keeps overlapping recorded invocations separate and preserves diagnostic outcomes' {
        $first = Get-PerfTestRow -Invocation 'first'
        $second = Get-PerfTestRow -Invocation 'second' -Start 200 -End 800
        $second.diagnosticOutcome = 'timeout'
        $aggs = (ConvertTo-PerfSequenceAggregate -Row @($first, $second)).startup
        $aggs.Count | Should -Be 2
        $aggs[1].steps[0].diagnosticOutcome | Should -Be 'timeout'
        $aggs[1].diagnosticIncompleteCount | Should -Be 1
        $aggs[1].failCount | Should -Be 0
    }
    It 'does not split one recorded invocation when top-level ordinals repeat' {
        $a = Get-PerfTestRow -Invocation 'same'
        $b = Get-PerfTestRow -Invocation 'same' -Start 2000 -End 3000
        (ConvertTo-PerfSequenceAggregate -Row @($a, $b)).startup.Count | Should -Be 1
    }
    It 'separates hosts with coincident cycle and sequence identities' {
        $a = Get-PerfTestRow -Invocation 'same'
        $b = Get-PerfTestRow -Invocation 'same'; $b.hostUuid = 'other'
        (ConvertTo-PerfSequenceAggregate -Row @($a, $b)).startup.Count | Should -Be 2
    }
    It 'keeps incomplete legacy timing visible without inventing an enclosing pass' {
        $row = Get-PerfTestRow -Parent 2 -Outcome fail
        $agg = (ConvertTo-PerfSequenceAggregate -Row @($row)).startup[0]
        $agg.stepCount | Should -Be 0
        $agg.incompleteStepCount | Should -Be 1
        $agg.retryFailureCount | Should -Be 1
    }
    It 'reads old rows with absent parent fields and missing timestamps' {
        $row = Get-PerfTestRow
        $row.Remove('parentStepOrdinal'); $row.Remove('startedAtUtc'); $row.Remove('endedAtUtc')
        $agg = (ConvertTo-PerfSequenceAggregate -Row @($row)).startup[0]
        $agg.durationMs | Should -Be 1000
        $agg.stepCount | Should -Be 1
        $agg.elapsedMs | Should -BeNullOrEmpty
    }
    It 'uses 64-bit sums rather than overflowing long-running histories' {
        $row = Get-PerfTestRow; $row.durationMs = 3000000000L
        (ConvertTo-PerfSequenceAggregate -Row @($row)).startup[0].durationMs | Should -Be 3000000000L
    }
    It 'normalizes DateTime timestamps without depending on host culture' {
        $row = Get-PerfTestRow
        $row.startedAtUtc = [DateTime]::Parse($row.startedAtUtc).ToUniversalTime()
        $row.endedAtUtc = [DateTime]::Parse($row.endedAtUtc).ToUniversalTime()
        $oldCulture = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = 'pt-BR'
            (ConvertTo-PerfSequenceAggregate -Row @($row)).startup[0].elapsedMs | Should -Be 1000
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $oldCulture }
    }
}

Describe 'Emitted performance identities' {
    BeforeEach {
        $script:RowsFile = Join-Path $TestDrive 'rows.jsonl'
        Remove-Item $script:RowsFile -Force -ErrorAction SilentlyContinue
        & (Get-Module Test.Perf) {
            param($File)
            $script:Cycle = @{ cycleStartUtc = '2026-09-11T00:00:00Z'; cycleFile = $File }
            $script:Sequence = $null; $script:Guest = $null
        } $script:RowsFile
    }
    It 'mints one ID per call, keeps nested rows on it, and sends it through aggregation' {
        $ids = foreach ($invocation in 1..2) {
            $id = Set-PerfSequenceContext -SequenceName 'startup' -PassThru -Confirm:$false
            Set-PerfGuestContext -GuestKey 'guest.ubuntu.server.24' -VMName 'temporary-vm' -Confirm:$false
            $now = [DateTime]::UtcNow
            Write-PerfStepRow -StepName 'retry' -StepOrdinal 1 -StepKind retry -StartedAtUtc $now -EndedAtUtc $now.AddSeconds(1) -DurationMs 1000 -Outcome pass -StepInvocationId "step-$invocation"
            Write-PerfStepRow -StepName 'child' -StepOrdinal 1 -ParentStepOrdinal 1 -ParentAttempt 1 -StartedAtUtc $now -EndedAtUtc $now.AddSeconds(1) -DurationMs 1000 -Outcome fail -DiagnosticOutcome timeout
            $id
        }
        $ids[0] | Should -Match '^[a-f0-9]{32}$'
        $ids[0] | Should -Not -Be $ids[1]
        $rows = @(Get-Content $script:RowsFile | ConvertFrom-Json)
        $rows[0].schema | Should -Be 2
        $rows[0].sequenceInvocationId | Should -Be $rows[1].sequenceInvocationId
        $rows[0].stepInvocationId | Should -Be 'step-1'
        $rows[1].diagnosticOutcome | Should -Be timeout
        $aggs = (ConvertTo-PerfSequenceAggregate -Row $rows).startup
        $aggs.Count | Should -Be 2
        $aggs[0].failCount | Should -Be 0
    }
    It 'does not add diagnostic outcomes to ordinary rows or output an ID without PassThru' {
        @(Set-PerfSequenceContext -SequenceName 'ordinary' -Confirm:$false).Count | Should -Be 0
        $now = [DateTime]::UtcNow
        Write-PerfStepRow -StepName 'ordinary' -StepOrdinal 1 -StartedAtUtc $now -EndedAtUtc $now -DurationMs 0 -Outcome pass
        $row = Get-Content $script:RowsFile | ConvertFrom-Json
        $row.PSObject.Properties.Name | Should -Not -Contain 'diagnosticOutcome'
    }
}

Describe 'Elapsed sequence labels' {
    It 'truncates minute boundaries instead of rounding up' {
        $tokens = $null; $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'test/modules/Test.SequenceEngine.psm1'), [ref]$tokens, [ref]$errors)
        $assignments = @($ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -in @('$elapsedTotalSeconds', '$elapsedTimeIsMinutes')
        }, $true))
        $code = [scriptblock]::Create('param($sequenceStopwatch)' + "`n" + ($assignments.Extent.Text -join "`n") + "`n" + '$elapsedTimeIsMinutes')
        foreach ($case in @(@(4608, '76 min and 48 s'), @(4621, '77 min and 1 s'), @(59, '0 min and 59 s'), @(60, '1 min and 0 s'))) {
            $sequenceStopwatch = [pscustomobject]@{ Elapsed = [TimeSpan]::FromSeconds($case[0]) }
            & $code $sequenceStopwatch | Should -Be $case[1]
        }
    }
}

Describe 'Performance checkpoint identity' {
    BeforeEach {
        $script:Step = @{ stepInvocationId = 'step-current'; sequenceInvocationId = 'run-current'
            startedAtUtc = '2026-09-11T00:00:00Z'; endedAtUtc = '2026-09-11T00:00:10Z' }
    }
    It 'joins a tagged checkpoint by execution even when reception falls outside its interval' {
        $candidate = @{ StepInvocationId = 'step-current'; SequenceInvocationId = 'run-current'; ReceivedAt = '2026-09-11T01:00:00Z' }
        Find-PerfCheckpoint -Step $script:Step -Sidecar @($candidate) | Should -Be $candidate
    }
    It 'never time-matches a checkpoint bearing another execution ID' {
        $candidate = @{ StepInvocationId = 'step-other'; SequenceInvocationId = 'run-current'; ReceivedAt = '2026-09-11T00:00:05Z' }
        Find-PerfCheckpoint -Step $script:Step -Sidecar @($candidate) | Should -BeNullOrEmpty
    }
    It 'requires both IDs for an identified checkpoint' {
        $candidate = @{ StepInvocationId = 'step-current'; ReceivedAt = '2026-09-11T00:00:05Z' }
        Find-PerfCheckpoint -Step $script:Step -Sidecar @($candidate) | Should -BeNullOrEmpty
    }
    It 'still joins untagged legacy sidecars by host reception time' {
        $candidate = @{ ReceivedAt = '2026-09-11T00:00:05Z' }
        Find-PerfCheckpoint -Step $script:Step -Sidecar @($candidate) | Should -Be $candidate
    }
    It 'does not reuse a consumed checkpoint or rescale a reattached execution' {
        $candidate = @{ StepInvocationId = 'step-current'; SequenceInvocationId = 'run-current'; Consumed = $true }
        Find-PerfCheckpoint -Step $script:Step -Sidecar @($candidate) | Should -BeNullOrEmpty
        $candidate.Consumed = $false
        $script:Step.checkpointSourceStepInvocationId = 'step-original'
        Find-PerfCheckpoint -Step $script:Step -Sidecar @($candidate) | Should -BeNullOrEmpty
    }
}

Describe 'Generated status service performance route' {
    It 'returns separate legacy runs with truthful totals from the actual generated handler' {
        Mock Read-TestConfig { @{ testCycle = @{ recentDisplayCount = 30 } } }
        $statusDir = Join-Path $TestDrive 'status'
        $cyclesDir = Join-Path $statusDir 'perf/cycles'
        $null = New-Item $cyclesDir -ItemType Directory -Force
        $rows = foreach ($run in 0..3) {
            $base = $run * 10000
            Get-PerfTestRow -Start $base -End ($base + 1000) -Parent 2 -Outcome fail
            Get-PerfTestRow -Ordinal 2 -Start $base -End ($base + 2000)
            Get-PerfTestRow -Ordinal 3 -Start ($base + 3000) -End ($base + 4000)
        }
        $rows | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content (Join-Path $cyclesDir 'cycle.jsonl')
        $source = [IO.File]::ReadAllText((Join-Path $script:Root 'test/service/Start-StatusService.ps1'))
        $raw = [regex]::Match($source, '(?ms)^\$serverScript = @"\r?\n(.*?)^"@').Groups[1].Value
        $server = $ExecutionContext.InvokeCommand.ExpandString($raw)
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($server, [ref]$null, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        $route = $ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '$path -eq ''control/perf-aggregates'''
        }, $true) | Select-Object -First 1
        $route | Should -Not -BeNullOrEmpty
        $res = @{ Headers = @{}; OutputStream = [IO.MemoryStream]::new() }
        $handler = [scriptblock]::Create('param($req, $res, $repoRoot, $path, $statusDir) $perfAggregatesCache = $null; foreach ($once in 1) {' + $route.Extent.Text + '}')
        & $handler @{ HttpMethod = 'GET' } $res $script:Root 'control/perf-aggregates' $statusDir
        $result = [Text.Encoding]::UTF8.GetString($res.OutputStream.ToArray()) | ConvertFrom-Json
        $result.sequences.startup.Count | Should -Be 4
        @($result.sequences.startup | Where-Object { $_.durationMs -ne 3000 -or $_.failCount -ne 0 }).Count | Should -Be 0
        @($result.sequences.startup.sequenceInvocationId | Sort-Object -Unique).Count | Should -Be 4
        $result.sequences.startup[0].sequenceInvocationId | Should -Be 'legacy-1'
        $result.sequences.startup[3].sequenceInvocationId | Should -Be 'legacy-4'
        $result | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $TestDrive 'performance.json')
        $node = Get-Command node -ErrorAction SilentlyContinue
        if ($node) {
            & $node.Source (Join-Path $script:Root 'test/status/performance.test.js') (Join-Path $TestDrive 'performance.json')
            $LASTEXITCODE | Should -Be 0
        }
    }
}

Describe 'Generated checkpoint ingestion' {
    It 'preserves bounded execution identities in the written sidecar' {
        $source = [IO.File]::ReadAllText((Join-Path $script:Root 'test/service/Start-StatusService.ps1'))
        $raw = [regex]::Match($source, '(?ms)^\$serverScript = @"\r?\n(.*?)^"@').Groups[1].Value
        $server = $ExecutionContext.InvokeCommand.ExpandString($raw)
        $ast = [Management.Automation.Language.Parser]::ParseInput($server, [ref]$null, [ref]$null)
        $route = $ast.FindAll({ param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
            $node.Clauses[0].Item1.Extent.Text -eq '$path -eq ''control/perf-checkpoints'''
        }, $true) | Select-Object -First 1
        $payload = @{ stepInvocationId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; sequenceInvocationId = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
            checkpoints = @(@{ name = 'packages'; offsetMs = 300 }); source = 'bash'; scriptPath = 'guest/install.sh' } | ConvertTo-Json -Depth 5
        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        $req = @{ HttpMethod = 'POST'; ContentLength64 = $bytes.Length; ContentEncoding = [Text.Encoding]::UTF8
            InputStream = [IO.MemoryStream]::new($bytes); RemoteEndPoint = @{ Address = [Net.IPAddress]::Loopback } }
        $res = @{ Headers = @{}; OutputStream = [IO.MemoryStream]::new() }
        $handler = [scriptblock]::Create('param($req, $res, $path, $statusDir) foreach ($once in 1) {' + $route.Extent.Text + '}')
        & $handler $req $res 'control/perf-checkpoints' $TestDrive
        $sidecar = Get-ChildItem (Join-Path $TestDrive 'perf/checkpoints') -Filter '*.json' | Get-Content -Raw | ConvertFrom-Json
        $sidecar.stepInvocationId | Should -Be 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $sidecar.sequenceInvocationId | Should -Be 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        $sidecar.checkpoints[0].offsetMs | Should -Be 300
    }
}
