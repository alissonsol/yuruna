<#PSScriptInfo
.VERSION 2026.10.11.1
.GUID 42994830-6205-4cf7-a39c-84254b1669c3
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test recovery contract typed-result pester
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
    Pins the shared recovery contract: one typed result for every entry point, a
    fingerprint that identifies a failure across restarts, redaction of what gets
    persisted, and the step functions that wrap checkout, admission and replay.
.DESCRIPTION
    The three entry points reported how a cycle went in three shapes, so a recovery
    decision could not be compared or audited across them. These cases cover the
    vocabulary and its validation, the persistence of results, the builders that
    turn what an entry point knows into a result, and each step function against
    stand-ins for the commands it wraps. Nothing here starts a VM or touches a
    real runtime directory.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The step functions resolve the wrapped host and git commands from the global scope; the fixtures install and remove stand-ins there.')]
param()

BeforeAll {
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.RecoveryContract.psm1') -Force -Global -DisableNameChecking

function New-Scratch {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: creates a throwaway directory under the OS temp directory.')]
    param([string]$Prefix = 'rc')
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Write-Json {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes a throwaway file under a temp directory.')]
    param([string]$Path, $Object)
    Set-Content -LiteralPath $Path -Value ($Object | ConvertTo-Json -Depth 8) -Encoding utf8
}

function Get-Generation { return ('a' * 32) + ':7' }
}

Describe 'ConvertTo-RecoverySafeText' {
    It 'removes credentials embedded in a URL' {
        ConvertTo-RecoverySafeText -Text "fatal: unable to access 'https://user:s3cr3t@github.com/x/y.git/'" | Should -Be "fatal: unable to access 'https://***@github.com/x/y.git/'"
    }
    It 'removes the value after a key that names a secret' -TestCases @(
        @{ Text = 'password=hunter2 next'; Expect = 'password=*** next' }
        @{ Text = 'Token: abc123, retry'; Expect = 'Token: ***, retry' }
        @{ Text = 'api_key=ZZZ; done'; Expect = 'api_key=***; done' }
    ) {
        param($Text, $Expect)
        ConvertTo-RecoverySafeText -Text $Text | Should -Be $Expect
    }
    It 'removes a bearer token' {
        ConvertTo-RecoverySafeText -Text 'sent Authorization: Bearer abcdefghijklmnop.qrstuvwx' | Should -Not -Match 'abcdefghijklmnop'
    }
    It 'removes a generated secret and keeps a 40-character commit id' {
        $secret = 'f3cb61c570a2e8b44c1f6a1d459b010b96c55b0b2e736010859ed57c568f8b07'
        $commit = '0123456789abcdef0123456789abcdef01234567'
        $text = ConvertTo-RecoverySafeText -Text "key $secret at $commit"
        $text | Should -Not -Match $secret
        $text | Should -Match $commit
    }
    It 'leaves ordinary paths and sequence names alone' {
        $text = 'C:\git\yuruna\test\modules\Test.RecoveryContract.psm1 and workload.guest.ubuntu.server.24.amisad-core.s001.fulfillment'
        ConvertTo-RecoverySafeText -Text $text | Should -Be $text
    }
    It 'folds control characters and line breaks into single spaces' {
        ConvertTo-RecoverySafeText -Text "one`r`ntwo`tthree`u{0007}four" | Should -Be 'one two three four'
    }
    It 'cuts to the limit and says so with three dots' {
        $cut = ConvertTo-RecoverySafeText -Text ('word ' * 100) -MaxLength 40
        $cut.Length | Should -Be 40
        $cut | Should -Match '\.\.\.$'
    }
    It 'reads null and empty as empty' {
        ConvertTo-RecoverySafeText -Text $null | Should -Be ''
        ConvertTo-RecoverySafeText -Text '' | Should -Be ''
    }
}

Describe 'Get-FailureFingerprint' {
    It 'has the documented shape' {
        Get-FailureFingerprint -FailureClass 'bootstrap_sync' -Stage 'ProjectClone' | Should -Match '^fp1-[0-9a-f]{16}$'
    }
    It 'is the same for the same failure however it is cased or padded' {
        $a = Get-FailureFingerprint -FailureClass 'bootstrap_sync' -Stage 'ProjectClone' -SequenceName 'Seq' -ActionVerb 'Verb'
        $b = Get-FailureFingerprint -FailureClass ' BOOTSTRAP_SYNC ' -Stage 'projectclone' -SequenceName ' seq' -ActionVerb 'VERB '
        $b | Should -Be $a
    }
    It 'differs when any input differs' {
        $base = Get-FailureFingerprint -FailureClass 'wait_timeout' -Stage 's' -SequenceName 'q' -ActionVerb 'v'
        (Get-FailureFingerprint -FailureClass 'ocr_timeout' -Stage 's' -SequenceName 'q' -ActionVerb 'v') | Should -Not -Be $base
        (Get-FailureFingerprint -FailureClass 'wait_timeout' -Stage 'other' -SequenceName 'q' -ActionVerb 'v') | Should -Not -Be $base
        (Get-FailureFingerprint -FailureClass 'wait_timeout' -Stage 's' -SequenceName 'other' -ActionVerb 'v') | Should -Not -Be $base
        (Get-FailureFingerprint -FailureClass 'wait_timeout' -Stage 's' -SequenceName 'q' -ActionVerb 'other') | Should -Not -Be $base
    }
    It 'has nothing to key on without a class' {
        Get-FailureFingerprint -FailureClass '' -Stage 'ProjectClone' | Should -Be ''
        Get-FailureFingerprint | Should -Be ''
    }
    It 'does not let one field bleed into the next' {
        (Get-FailureFingerprint -FailureClass 'wait_timeout' -Stage 'ab' -SequenceName 'c') | Should -Not -Be (Get-FailureFingerprint -FailureClass 'wait_timeout' -Stage 'a' -SequenceName 'bc')
    }
}

Describe 'Vocabulary' {
    It 'accepts the shared taxonomy, the runner fault classes and the empty class, and nothing else' {
        Test-RecoveryFailureClass -FailureClass '' | Should -BeTrue
        Test-RecoveryFailureClass -FailureClass 'wait_timeout' | Should -BeTrue
        foreach ($fault in Get-RunnerFaultClassEnum) { Test-RecoveryFailureClass -FailureClass $fault | Should -BeTrue -Because $fault }
        Test-RecoveryFailureClass -FailureClass 'a_class_from_the_future' | Should -BeFalse
        Test-RecoveryFailureClass -FailureClass 'WAIT_TIMEOUT' | Should -BeFalse -Because 'class names are case sensitive'
    }
    It 'keeps the runner fault classes out of the shared taxonomy' {
        foreach ($fault in Get-RunnerFaultClassEnum) { @(Get-FailureClassEnum) | Should -Not -Contain $fault }
    }
    It 'lists every fault class the builders can emit' {
        foreach ($class in 'outcome_unrecorded', 'vm_admission_occupied', 'vm_admission_unknown', 'cycle_killed', 'cycle_spawn_failed', 'preamble_stall') {
            @(Get-RunnerFaultClassEnum) | Should -Contain $class
        }
    }
}

Describe 'Cycle generation' {
    BeforeEach { $script:SavedGeneration = $env:YURUNA_CYCLE_GENERATION }
    AfterEach {
        if ($null -eq $script:SavedGeneration) { Remove-Item Env:YURUNA_CYCLE_GENERATION -ErrorAction SilentlyContinue } else { $env:YURUNA_CYCLE_GENERATION = $script:SavedGeneration }
    }
    It 'mints <instance>:1 for a one-shot entry point' {
        New-CycleGeneration | Should -Match '^[0-9a-f]{32}:1$'
    }
    It 'keeps the generation the runner issued' {
        $env:YURUNA_CYCLE_GENERATION = Get-Generation
        Get-CycleGeneration | Should -Be (Get-Generation)
    }
    It 'mints one and exports it when there is none, so what it starts shares it' {
        Remove-Item Env:YURUNA_CYCLE_GENERATION -ErrorAction SilentlyContinue
        $minted = Get-CycleGeneration
        $minted | Should -Match '^[0-9a-f]{32}:1$'
        $env:YURUNA_CYCLE_GENERATION | Should -Be $minted
        Get-CycleGeneration | Should -Be $minted
    }
    It 'replaces a malformed value instead of passing it on' {
        $env:YURUNA_CYCLE_GENERATION = 'not-a-generation'
        Get-CycleGeneration | Should -Match '^[0-9a-f]{32}:1$'
    }
}

Describe 'Evidence and step results' {
    It 'builds evidence with a known kind and redacts what it carries' {
        $e = New-RecoveryEvidence -Kind file -Ref 'C:\x\last_failure.json' -Note 'password=hunter2'
        $e['kind'] | Should -Be 'file'
        $e['note'] | Should -Be 'password=***'
    }
    It 'refuses an unknown evidence kind' {
        { New-RecoveryEvidence -Kind 'rumor' -Ref 'x' } | Should -Throw '*not one of*'
    }
    It 'builds a step result with the common fields first and the extras after' {
        $s = New-RecoveryStepResult -Step checkout -Ok $false -FailureClass bootstrap_sync -Reason 'clone failed' -Extra @{ Revision = 'abc' }
        $s.Step | Should -Be 'checkout'
        $s.Ok | Should -BeFalse
        $s.Skipped | Should -BeFalse
        $s.FailureClass | Should -Be 'bootstrap_sync'
        $s.Reason | Should -Be 'clone failed'
        $s.Revision | Should -Be 'abc'
        @($s.PSObject.Properties.Name)[0..5] | Should -Be @('Step', 'Ok', 'Skipped', 'FailureClass', 'Reason', 'Evidence')
    }
    It 'refuses a step or a class outside the vocabulary' {
        { New-RecoveryStepResult -Step 'teardown' -Ok $true } | Should -Throw '*not one of*'
        { New-RecoveryStepResult -Step checkout -Ok $false -FailureClass 'nope' } | Should -Throw '*known failure class*'
    }
    It 'redacts the reason it carries' {
        (New-RecoveryStepResult -Step admission -Ok $false -Reason 'https://u:p@host/x failed').Reason | Should -Be 'https://***@host/x failed'
    }
}

Describe 'New-RecoveryResult and Test-RecoveryResult' {
    It 'builds a result that validates, with every documented field' {
        $r = New-RecoveryResult -EntryPoint runner -CycleGeneration (Get-Generation) -Outcome failed -ExitCode 1 -FailureClass wait_timeout -Stage s -Reason 'x'
        (Test-RecoveryResult -Result $r).Valid | Should -BeTrue
        @($r.Keys) | Should -Be @('schemaVersion', 'resultId', 'entryPoint', 'cycleGeneration', 'recordedAtUtc', 'outcome', 'exitCode', 'failureClass', 'fingerprint', 'stage', 'reason', 'evidence', 'steps', 'recovery')
        $r['schemaVersion'] | Should -Be 1
        $r['resultId'] | Should -Match '^[0-9a-f]{32}$'
    }
    It 'computes a fingerprint for a failure and none for a pass' {
        (New-RecoveryResult -EntryPoint runner -CycleGeneration (Get-Generation) -Outcome failed -ExitCode 1 -FailureClass wait_timeout)['fingerprint'] | Should -Match '^fp1-'
        (New-RecoveryResult -EntryPoint runner -CycleGeneration (Get-Generation) -Outcome passed -ExitCode 0)['fingerprint'] | Should -Be ''
        (New-RecoveryResult -EntryPoint runner -CycleGeneration (Get-Generation) -Outcome failed -ExitCode 1)['fingerprint'] | Should -Be ''
    }
    It 'refuses a value outside the vocabulary' -TestCases @(
        @{ Splat = @{ EntryPoint = 'nope' }; Message = '*entry point*' }
        @{ Splat = @{ Outcome = 'maybe' }; Message = '*outcome*' }
        @{ Splat = @{ CycleGeneration = 'x:1' }; Message = '*cycle generation*' }
        @{ Splat = @{ FailureClass = 'nope' }; Message = '*failure class*' }
        @{ Splat = @{ Recovery = @{ state = 'healed' } }; Message = '*recovery state*' }
    ) {
        param($Splat, $Message)
        $arguments = @{ EntryPoint = 'runner'; CycleGeneration = (Get-Generation); Outcome = 'failed'; ExitCode = 1 }
        foreach ($key in $Splat.Keys) { $arguments[$key] = $Splat[$key] }
        { New-RecoveryResult @arguments } | Should -Throw $Message
    }
    It 'refuses evidence that did not come from New-RecoveryEvidence' {
        { New-RecoveryResult -EntryPoint runner -CycleGeneration (Get-Generation) -Outcome failed -ExitCode 1 -Evidence @(@{ kind = 'file' }, 'loose text') } | Should -Throw '*New-RecoveryEvidence*'
    }
    It 'keeps a single advised action an array through JSON' {
        $r = New-RecoveryResult -EntryPoint runner -CycleGeneration (Get-Generation) -Outcome failed -ExitCode 1 -Recovery @{ state = 'advised'; advised = @('reclone_project') }
        $back = $r | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
        $back['recovery']['advised'] -is [array] | Should -BeTrue
        @($back['recovery']['advised']).Count | Should -Be 1
    }
    It 'rolls the steps up to step, ok, failureClass and reason' {
        $step = New-RecoveryStepResult -Step checkout -Ok $false -FailureClass bootstrap_sync -Reason 'no' -Extra @{ Revision = '' }
        $r = New-RecoveryResult -EntryPoint project -CycleGeneration (Get-Generation) -Outcome infrastructure-fault -ExitCode 1 -Steps @($step)
        @($r['steps']).Count | Should -Be 1
        @($r['steps'][0].Keys) | Should -Be @('step', 'ok', 'failureClass', 'reason')
    }
    It 'names each way a stored result can be malformed' -TestCases @(
        @{ Mutate = { param($d) $d['schemaVersion'] = 2 }; Problem = 'schemaVersion' }
        @{ Mutate = { param($d) $d['resultId'] = 'zz' }; Problem = 'resultId' }
        @{ Mutate = { param($d) $d['entryPoint'] = 'cron' }; Problem = 'entryPoint' }
        @{ Mutate = { param($d) $d['cycleGeneration'] = 'nope' }; Problem = 'cycleGeneration' }
        @{ Mutate = { param($d) $d['recordedAtUtc'] = 'yesterday' }; Problem = 'recordedAtUtc' }
        @{ Mutate = { param($d) $d['outcome'] = 'meh' }; Problem = 'outcome' }
        @{ Mutate = { param($d) $d['exitCode'] = 'one' }; Problem = 'exitCode' }
        @{ Mutate = { param($d) $d['failureClass'] = 'nope' }; Problem = 'failureClass' }
        @{ Mutate = { param($d) $d['fingerprint'] = 'abc' }; Problem = 'fingerprint' }
        @{ Mutate = { param($d) $d['reason'] = 5 }; Problem = 'reason' }
        @{ Mutate = { param($d) $d['evidence'] = @(@{ kind = 'rumor' }) }; Problem = 'evidence' }
        @{ Mutate = { param($d) $d['steps'] = @(@{ step = 'teardown' }) }; Problem = 'step' }
        @{ Mutate = { param($d) $d['recovery'] = 'fine' }; Problem = 'recovery' }
        @{ Mutate = { param($d) $d['recovery']['state'] = 'healed' }; Problem = 'recovery.state' }
    ) {
        param($Mutate, $Problem)
        $d = New-RecoveryResult -EntryPoint runner -CycleGeneration (Get-Generation) -Outcome failed -ExitCode 1 -FailureClass wait_timeout | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
        & $Mutate $d
        $check = Test-RecoveryResult -Result $d
        $check.Valid | Should -BeFalse
        ($check.Problems -join '; ') | Should -Match ([regex]::Escape($Problem))
    }
    It 'rejects what is not an object' {
        (Test-RecoveryResult -Result $null).Valid | Should -BeFalse
        (Test-RecoveryResult -Result 'text').Valid | Should -BeFalse
    }
    It 'accepts a timestamp that JSON parsing turned into a date' {
        $d = New-RecoveryResult -EntryPoint runner -CycleGeneration (Get-Generation) -Outcome passed -ExitCode 0 | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
        $d['recordedAtUtc'] | Should -BeOfType ([datetime])
        (Test-RecoveryResult -Result $d).Valid | Should -BeTrue
    }
}

Describe 'Persistence of results' {
    BeforeEach { $script:Dir = New-Scratch }
    AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'replaces the latest file and reads it back with the timestamp as text' {
        $r = New-RecoveryResult -EntryPoint sequence -CycleGeneration (Get-Generation) -Outcome failed -ExitCode 1 -FailureClass wait_timeout -Reason 'x'
        Write-RecoveryResult -Result $r -RuntimeDir $script:Dir | Should -BeTrue
        $back = Read-RecoveryResult -RuntimeDir $script:Dir
        $back['failureClass'] | Should -Be 'wait_timeout'
        $back['fingerprint'] | Should -Be $r['fingerprint']
        $back['recordedAtUtc'] | Should -BeOfType ([string])
        $back['recordedAtUtc'] | Should -Be $r['recordedAtUtc']
    }
    It 'replaces rather than appends the latest file' {
        foreach ($i in 1..3) { $null = Write-RecoveryResult -Result (New-RecoveryResult -EntryPoint project -CycleGeneration (Get-Generation) -Outcome passed -ExitCode 0) -RuntimeDir $script:Dir }
        (Get-Content -LiteralPath (Get-RecoveryResultPath -RuntimeDir $script:Dir).Latest -Raw | ConvertFrom-Json).entryPoint | Should -Be 'project'
        @(Get-ChildItem -LiteralPath $script:Dir -Filter 'recovery.result.json*').Count | Should -Be 1 -Because 'no temporary files are left behind'
    }
    It 'appends one history line per result' {
        foreach ($i in 1..4) { $null = Write-RecoveryResult -Result (New-RecoveryResult -EntryPoint runner -CycleGeneration (Get-Generation) -Outcome passed -ExitCode 0) -RuntimeDir $script:Dir }
        @(Get-RecoveryResultHistory -RuntimeDir $script:Dir -Last 50).Count | Should -Be 4
    }
    It 'trims the history to the newest 200 once it passes 240' {
        $history = (Get-RecoveryResultPath -RuntimeDir $script:Dir).History
        $lines = foreach ($i in 1..240) { (New-RecoveryResult -EntryPoint runner -CycleGeneration (Get-Generation) -Outcome passed -ExitCode 0 -Reason "old $i" | ConvertTo-Json -Depth 8 -Compress) }
        [IO.File]::WriteAllLines($history, [string[]]$lines)
        $null = Write-RecoveryResult -Result (New-RecoveryResult -EntryPoint runner -CycleGeneration (Get-Generation) -Outcome passed -ExitCode 0 -Reason 'newest') -RuntimeDir $script:Dir
        $kept = @([IO.File]::ReadAllLines($history))
        $kept.Count | Should -Be 200
        $kept[-1] | Should -Match 'newest'
        $kept[0] | Should -Match 'old 42"' -Because 'the oldest 41 of 241 lines went'
    }
    It 'skips history lines that do not parse' {
        $history = (Get-RecoveryResultPath -RuntimeDir $script:Dir).History
        [IO.File]::WriteAllText($history, "not json`n")
        $null = Write-RecoveryResult -Result (New-RecoveryResult -EntryPoint runner -CycleGeneration (Get-Generation) -Outcome passed -ExitCode 0) -RuntimeDir $script:Dir
        @(Get-RecoveryResultHistory -RuntimeDir $script:Dir).Count | Should -Be 1
    }
    It 'does not throw and reports false when the directory is missing' {
        $r = New-RecoveryResult -EntryPoint runner -CycleGeneration (Get-Generation) -Outcome passed -ExitCode 0
        { Write-RecoveryResult -Result $r -RuntimeDir (Join-Path $script:Dir 'absent') } | Should -Not -Throw
        Write-RecoveryResult -Result $r -RuntimeDir (Join-Path $script:Dir 'absent') | Should -BeFalse
    }
    It 'does not write a result that fails validation' {
        $r = New-RecoveryResult -EntryPoint runner -CycleGeneration (Get-Generation) -Outcome passed -ExitCode 0
        $r['outcome'] = 'meh'
        Write-RecoveryResult -Result $r -RuntimeDir $script:Dir | Should -BeFalse
        Test-Path -LiteralPath (Get-RecoveryResultPath -RuntimeDir $script:Dir).Latest | Should -BeFalse
    }
    It 'reads nothing from a missing, garbled or invalid latest file' {
        Read-RecoveryResult -RuntimeDir $script:Dir | Should -BeNullOrEmpty
        $latest = (Get-RecoveryResultPath -RuntimeDir $script:Dir).Latest
        Set-Content -LiteralPath $latest -Value 'not json'
        Read-RecoveryResult -RuntimeDir $script:Dir | Should -BeNullOrEmpty
        Set-Content -LiteralPath $latest -Value '{"schemaVersion": 1}'
        Read-RecoveryResult -RuntimeDir $script:Dir | Should -BeNullOrEmpty
    }
}

Describe 'Cycle outcome record: the optional fields' {
    BeforeEach {
        $script:Dir = New-Scratch
        $script:File = Join-Path $script:Dir 'runner.cycle.outcome.json'
        Mock -ModuleName Test.RecoveryContract Write-Warning { }
    }
    AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'carries a failure class and a redacted detail through the publisher and the reader' {
        $result = [pscustomobject]@{ Outcome = 'pull-error'; ExitCode = 0; FailureClass = 'bootstrap_sync'; Detail = "fatal: Unable to create '.git/index.lock': File exists. password=hunter2" }
        $null = Publish-CycleOutcomeRecord -Result $result -OutcomeFile $script:File -CycleGeneration (Get-Generation)
        $r = Read-CycleOutcomeRecord -Path $script:File -ExpectedGeneration (Get-Generation)
        $r.Valid | Should -BeTrue
        $r.FailureClass | Should -Be 'bootstrap_sync'
        $r.RecordDetail | Should -Match 'index.lock'
        $r.RecordDetail | Should -Not -Match 'hunter2'
    }
    It 'writes neither field when the cycle did not supply them' {
        $null = Publish-CycleOutcomeRecord -Result ([pscustomobject]@{ Outcome = 'completed'; ExitCode = 0 }) -OutcomeFile $script:File
        $doc = Get-Content -LiteralPath $script:File -Raw | ConvertFrom-Json
        $doc.PSObject.Properties.Name | Should -Not -Contain 'failureClass'
        $doc.PSObject.Properties.Name | Should -Not -Contain 'detail'
    }
    It 'refuses to record a class outside the vocabulary' {
        $null = Publish-CycleOutcomeRecord -Result ([pscustomobject]@{ Outcome = 'completed'; ExitCode = 1; FailureClass = 'nope' }) -OutcomeFile $script:File
        (Get-Content -LiteralPath $script:File -Raw | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'failureClass'
    }
    It 'never lets the optional fields decide validity' -TestCases @(
        @{ Extra = '"failureClass": "nope"' }
        @{ Extra = '"failureClass": 5, "detail": 7' }
        @{ Extra = '"detail": ["a"]' }
    ) {
        param($Extra)
        Set-Content -LiteralPath $script:File -Value ('{"outcome":"completed","exitCode":0,"cycleGeneration":"' + (Get-Generation) + '",' + $Extra + '}') -Encoding utf8
        $r = Read-CycleOutcomeRecord -Path $script:File -ExpectedGeneration (Get-Generation)
        $r.Valid | Should -BeTrue
        $r.FailureClass | Should -Be ''
        $r.RecordDetail | Should -Be ''
    }
}

Describe 'Get-LastFailureFact' {
    BeforeEach { $script:Dir = New-Scratch }
    AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'reads a sequence-step record' {
        Write-Json (Join-Path $script:Dir 'last_failure.json') ([ordered]@{ failureClass = 'wait_timeout'; sequenceName = 'workload.x'; actionVerb = 'waitForText'; description = 'timed out'; reason = 'timeout' })
        $f = Get-LastFailureFact -LogDir $script:Dir
        $f.FailureClass | Should -Be 'wait_timeout'
        $f.SequenceName | Should -Be 'workload.x'
        $f.ActionVerb | Should -Be 'waitForText'
        $f.Infra | Should -BeFalse
        $f.Stage | Should -Be ''
    }
    It 'reads an infrastructure-stage record and takes the stage from its context' {
        Write-Json (Join-Path $script:Dir 'last_failure.json') ([ordered]@{ failureClass = 'bootstrap_sync'; reason = 'infra'; action = 'ProjectClone'; actionVerb = 'ProjectClone'; description = 'clone failed'; context = [ordered]@{ stage = 'ProjectClone' } })
        $f = Get-LastFailureFact -LogDir $script:Dir
        $f.Infra | Should -BeTrue
        $f.Stage | Should -Be 'ProjectClone'
    }
    It 'falls back to the action when an infra record has no context' {
        Write-Json (Join-Path $script:Dir 'last_failure.json') ([ordered]@{ failureClass = 'bootstrap_sync'; reason = 'infra'; action = 'GitPull' })
        (Get-LastFailureFact -LogDir $script:Dir).Stage | Should -Be 'GitPull'
    }
    It 'reads a class outside the vocabulary as unknown instead of invalidating the result' {
        Write-Json (Join-Path $script:Dir 'last_failure.json') ([ordered]@{ failureClass = 'from_the_future' })
        (Get-LastFailureFact -LogDir $script:Dir).FailureClass | Should -Be 'unknown'
    }
    It 'redacts the description' {
        Write-Json (Join-Path $script:Dir 'last_failure.json') ([ordered]@{ failureClass = 'unknown'; description = 'token=abc123' })
        (Get-LastFailureFact -LogDir $script:Dir).Description | Should -Be 'token=***'
    }
    It 'returns nothing for a missing, garbled or non-object file' {
        Get-LastFailureFact -LogDir $script:Dir | Should -BeNullOrEmpty
        Set-Content -LiteralPath (Join-Path $script:Dir 'last_failure.json') -Value 'garbage'
        Get-LastFailureFact -LogDir $script:Dir | Should -BeNullOrEmpty
        Set-Content -LiteralPath (Join-Path $script:Dir 'last_failure.json') -Value '[1,2]'
        Get-LastFailureFact -LogDir $script:Dir | Should -BeNullOrEmpty
        Get-LastFailureFact -LogDir '' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-RunnerRecoveryResult' {
    BeforeAll {
        # Defined here, not in the Describe body: Pester 5 runs the body at
        # discovery, and a function defined there is gone by the time a case runs.
        function Convert-Dispatch {
            param($Dispatch)
            ConvertTo-RunnerRecoveryResult -Dispatch ([pscustomobject]$Dispatch) -CycleGeneration (Get-Generation) -LogDir $script:Log -RuntimeDir $script:Runtime -SpawnedAtUtc $script:Spawned
        }
    }
    BeforeEach {
        $script:Log = New-Scratch 'rl'
        $script:Runtime = New-Scratch 'rr'
        $script:Spawned = [datetime]::UtcNow.AddMinutes(-3)
    }
    AfterEach { Remove-Item -LiteralPath $script:Log, $script:Runtime -Recurse -Force -ErrorAction SilentlyContinue }

    It 'is a pass for a completed cycle that exited 0' {
        $r = Convert-Dispatch @{ Outcome = 'completed'; ExitCode = 0 }
        $r['outcome'] | Should -Be 'passed'
        $r['entryPoint'] | Should -Be 'runner'
        $r['cycleGeneration'] | Should -Be (Get-Generation)
        $r['fingerprint'] | Should -Be ''
        (Test-RecoveryResult -Result $r).Valid | Should -BeTrue
    }
    It 'reads a failed cycle from its failure record' {
        Write-Json (Join-Path $script:Log 'last_failure.json') ([ordered]@{ failureClass = 'wait_timeout'; sequenceName = 'workload.x'; actionVerb = 'waitForText'; description = 'timed out'; reason = 'timeout' })
        $r = Convert-Dispatch @{ Outcome = 'completed'; ExitCode = 1 }
        $r['outcome'] | Should -Be 'failed'
        $r['failureClass'] | Should -Be 'wait_timeout'
        $r['fingerprint'] | Should -Be (Get-FailureFingerprint -FailureClass wait_timeout -SequenceName 'workload.x' -ActionVerb 'waitForText')
        @($r['evidence'] | Where-Object { $_['ref'] -like '*last_failure.json' }).Count | Should -Be 1
    }
    It 'calls a failed infrastructure stage an infrastructure fault' {
        Write-Json (Join-Path $script:Log 'last_failure.json') ([ordered]@{ failureClass = 'bootstrap_sync'; reason = 'infra'; action = 'ProjectClone'; description = 'clone failed'; context = [ordered]@{ stage = 'ProjectClone' } })
        $r = Convert-Dispatch @{ Outcome = 'completed'; ExitCode = 1 }
        $r['outcome'] | Should -Be 'infrastructure-fault'
        $r['stage'] | Should -Be 'ProjectClone'
    }
    It 'files a failure with no record as an unknown class instead of guessing' {
        $r = Convert-Dispatch @{ Outcome = 'completed'; ExitCode = 3 }
        $r['outcome'] | Should -Be 'failed'
        $r['failureClass'] | Should -Be 'unknown'
        $r['reason'] | Should -Match 'exited 3'
    }
    It 'reports a refused VM admission as cannot-run, with its class' -TestCases @(
        @{ State = 'unknown'; Class = 'vm_admission_unknown' }
        @{ State = 'occupied'; Class = 'vm_admission_occupied' }
    ) {
        param($State, $Class)
        Write-Json (Join-Path $script:Runtime 'vm-admission.json') ([ordered]@{ state = $State; reason = 'inventory-failed'; detail = 'utmctl did not answer'; occupants = @(); observedUtc = [datetime]::UtcNow.ToString('o') })
        $r = Convert-Dispatch @{ Outcome = 'completed'; ExitCode = 2 }
        $r['outcome'] | Should -Be 'cannot-run'
        $r['failureClass'] | Should -Be $Class
        $r['stage'] | Should -Be 'VmAdmission'
    }
    It 'ignores an admission record from before the cycle was spawned' {
        Write-Json (Join-Path $script:Runtime 'vm-admission.json') ([ordered]@{ state = 'unknown'; reason = 'x'; detail = 'y'; occupants = @(); observedUtc = [datetime]::UtcNow.AddHours(-2).ToString('o') })
        (Convert-Dispatch @{ Outcome = 'completed'; ExitCode = 1 })['outcome'] | Should -Be 'failed'
    }
    It 'files an unrecorded outcome as the runner''s own fault and keeps the rejected record as evidence' {
        Set-Content -LiteralPath (Join-Path $script:Runtime 'runner.cycle.outcome.rejected.json') -Value '{}'
        $r = Convert-Dispatch @{ Outcome = 'outcome-unrecorded'; ExitCode = 70; OutcomeReason = 'stale-generation'; OutcomeDetail = 'record carries generation none' }
        $r['outcome'] | Should -Be 'infrastructure-fault'
        $r['failureClass'] | Should -Be 'outcome_unrecorded'
        $r['reason'] | Should -Match 'stale-generation'
        @($r['evidence'] | Where-Object { $_['ref'] -like '*rejected.json' }).Count | Should -Be 1
    }
    It 'maps every other non-verdict-carrying outcome' -TestCases @(
        @{ Dispatch = @{ Outcome = 'no-cycle-result'; ExitCode = 1 }; Outcome = 'infrastructure-fault'; Class = 'outcome_unrecorded'; Stage = 'CycleOutcome' }
        @{ Dispatch = @{ Outcome = 'cycle-aborted'; ExitCode = 64 }; Outcome = 'aborted'; Class = 'cycle_killed'; Stage = 'CycleStart' }
        @{ Dispatch = @{ Outcome = 'pull-error'; ExitCode = 0; RecordDetail = "Unable to create '.git/index.lock': File exists" }; Outcome = 'infrastructure-fault'; Class = 'bootstrap_sync'; Stage = 'FrameworkPull' }
        @{ Dispatch = @{ Outcome = 'spawn-failed'; ExitCode = 0 }; Outcome = 'infrastructure-fault'; Class = 'cycle_spawn_failed'; Stage = 'CycleSpawn' }
        @{ Dispatch = @{ Outcome = 'storage-full'; ExitCode = 1 }; Outcome = 'infrastructure-fault'; Class = 'pool_storage_full'; Stage = 'PoolStorage' }
    ) {
        param($Dispatch, $Outcome, $Class, $Stage)
        $r = Convert-Dispatch $Dispatch
        $r['outcome'] | Should -Be $Outcome
        $r['failureClass'] | Should -Be $Class
        $r['stage'] | Should -Be $Stage
        (Test-RecoveryResult -Result $r).Valid | Should -BeTrue
    }
    It 'carries the pull failure text, so a stale git lock can be told from a network failure' {
        $r = Convert-Dispatch @{ Outcome = 'pull-error'; ExitCode = 0; RecordDetail = "Unable to create '.git/index.lock': File exists" }
        $r['reason'] | Should -Match 'index\.lock'
    }
    It 'produces no result for an outcome that is not a verdict' -TestCases @(
        @{ Name = 'drain' }, @{ Name = 'refresh-gated' }, @{ Name = 'refresh-preflight' }, @{ Name = 'paused' }, @{ Name = 'shutdown' }
    ) {
        param($Name)
        Convert-Dispatch @{ Outcome = $Name; ExitCode = 0 } | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-ExitRecoveryResult and Save-RecoveryResult' {
    BeforeEach {
        $script:Log = New-Scratch 'el'
        $script:Runtime = New-Scratch 'er'
        $script:SavedGeneration = $env:YURUNA_CYCLE_GENERATION
    }
    AfterEach {
        Remove-Item -LiteralPath $script:Log, $script:Runtime -Recurse -Force -ErrorAction SilentlyContinue
        if ($null -eq $script:SavedGeneration) { Remove-Item Env:YURUNA_CYCLE_GENERATION -ErrorAction SilentlyContinue } else { $env:YURUNA_CYCLE_GENERATION = $script:SavedGeneration }
    }

    It 'is a pass for exit 0 with no failed step' {
        $r = ConvertTo-ExitRecoveryResult -EntryPoint sequence -ExitCode 0 -LogDir $script:Log -CycleGeneration (Get-Generation)
        $r['outcome'] | Should -Be 'passed'
        $r['entryPoint'] | Should -Be 'sequence'
    }
    It 'names a failed checkout first, whatever the exit code says' {
        $step = New-RecoveryStepResult -Step checkout -Ok $false -FailureClass bootstrap_sync -Reason 'git clone failed' -Extra @{ Stage = 'ProjectClone' }
        $r = ConvertTo-ExitRecoveryResult -EntryPoint project -ExitCode 1 -Steps @($step) -LogDir $script:Log -CycleGeneration (Get-Generation)
        $r['outcome'] | Should -Be 'infrastructure-fault'
        $r['failureClass'] | Should -Be 'bootstrap_sync'
        $r['stage'] | Should -Be 'ProjectClone'
        $r['reason'] | Should -Be 'git clone failed'
        @($r['steps']).Count | Should -Be 1
    }
    It 'names a refused admission as cannot-run' {
        $step = New-RecoveryStepResult -Step admission -Ok $false -FailureClass vm_admission_unknown -Reason 'inventory-failed' -Extra @{ Stage = 'VmAdmission' }
        $r = ConvertTo-ExitRecoveryResult -EntryPoint sequence -ExitCode 2 -Steps @($step) -LogDir $script:Log -CycleGeneration (Get-Generation)
        $r['outcome'] | Should -Be 'cannot-run'
        $r['failureClass'] | Should -Be 'vm_admission_unknown'
    }
    It 'does not blame a skipped step' {
        $step = New-RecoveryStepResult -Step checkout -Ok $true -Skipped
        (ConvertTo-ExitRecoveryResult -EntryPoint project -ExitCode 0 -Steps @($step) -LogDir $script:Log -CycleGeneration (Get-Generation))['outcome'] | Should -Be 'passed'
    }
    It 'reads the cannot-run exit code as cannot-run' {
        (ConvertTo-ExitRecoveryResult -EntryPoint sequence -ExitCode 2 -LogDir $script:Log -CycleGeneration (Get-Generation))['outcome'] | Should -Be 'cannot-run'
    }
    It 'reads any other failing exit code from the failure record' {
        Write-Json (Join-Path $script:Log 'last_failure.json') ([ordered]@{ failureClass = 'ocr_timeout'; sequenceName = 'workload.x'; actionVerb = 'waitForText'; description = 'no text' })
        $r = ConvertTo-ExitRecoveryResult -EntryPoint sequence -ExitCode 1 -LogDir $script:Log -CycleGeneration (Get-Generation)
        $r['outcome'] | Should -Be 'failed'
        $r['failureClass'] | Should -Be 'ocr_timeout'
    }
    It 'uses the process generation when none is passed' {
        $env:YURUNA_CYCLE_GENERATION = Get-Generation
        (ConvertTo-ExitRecoveryResult -EntryPoint project -ExitCode 0 -LogDir $script:Log)['cycleGeneration'] | Should -Be (Get-Generation)
    }
    It 'saves a result under the runtime directory' {
        $env:YURUNA_CYCLE_GENERATION = Get-Generation
        Save-RecoveryResult -EntryPoint sequence -ExitCode 0 -RuntimeDir $script:Runtime | Should -BeTrue
        (Read-RecoveryResult -RuntimeDir $script:Runtime)['entryPoint'] | Should -Be 'sequence'
    }
    It 'never throws and never changes an exit code, whatever goes wrong' {
        { Save-RecoveryResult -EntryPoint sequence -ExitCode 1 -RuntimeDir (Join-Path $script:Runtime 'absent') } | Should -Not -Throw
        Save-RecoveryResult -EntryPoint sequence -ExitCode 1 -RuntimeDir (Join-Path $script:Runtime 'absent') | Should -BeFalse
        { Save-RecoveryResult -EntryPoint sequence -ExitCode 1 -RuntimeDir '' } | Should -Not -Throw
    }
}

Describe 'The step functions' {
    BeforeAll {
        function global:Update-ProjectClone {
            [CmdletBinding(SupportsShouldProcess)]
            param([string]$RepoRoot, [string]$ProjectUrl)
            $global:__rcSteps.Seen['clone'] = @{ RepoRoot = $RepoRoot; ProjectUrl = $ProjectUrl }
            if ($global:__rcSteps.CloneThrows) { throw 'the clone helper blew up' }
            if ($PSCmdlet.ShouldProcess($ProjectUrl, 'clone')) { return $global:__rcSteps.Clone }
        }
        function global:Invoke-HostVmAdmission {
            param([string]$HostType, [string]$ExceptVmName)
            $global:__rcSteps.Seen['admission'] = @{ HostType = $HostType; ExceptVmName = $ExceptVmName }
            return $global:__rcSteps.Admission
        }
        function Install-PlanStub {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: installs a stand-in planner in the global scope; the suite removes it afterwards.')]
            param()
            function global:Resolve-WarmResumeReplayPlan {
                param($Decision, $Checkpoint, $SequencesDir, $HostType, $RepoRoot, $VMName)
                $global:__rcSteps.Seen['plan'] = @{ Decision = $Decision; Checkpoint = $Checkpoint; SequencesDir = $SequencesDir; HostType = $HostType; RepoRoot = $RepoRoot; VMName = $VMName }
                return $global:__rcSteps.Plan
            }
        }
    }
    AfterAll {
        # The path form: the scope-qualified spelling removes nothing.
        Remove-Item -Path Function:\Update-ProjectClone, Function:\Invoke-HostVmAdmission, Function:\Resolve-WarmResumeReplayPlan -ErrorAction SilentlyContinue
        Remove-Variable __rcSteps -Scope Global -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $global:__rcSteps = @{ Clone = $null; CloneThrows = $false; Admission = $null; Plan = $null; Seen = @{} }
        Remove-Item -Path Function:\Resolve-WarmResumeReplayPlan -ErrorAction SilentlyContinue
    }

    Context 'Invoke-CycleCheckoutStep' {
        It 'passes a successful refresh through with its revision, and hands the helper what it was given' {
            $global:__rcSteps.Clone = @{ success = $true; skipped = $false; errorMessage = $null; revision = 'abc123' }
            $s = Invoke-CycleCheckoutStep -RepoRoot 'R' -ProjectUrl 'https://example.invalid/p.git'
            $s.Step | Should -Be 'checkout'
            $s.Ok | Should -BeTrue
            $s.FailureClass | Should -Be ''
            $s.Revision | Should -Be 'abc123'
            $s.Stage | Should -Be 'ProjectClone'
            $global:__rcSteps.Seen['clone'].RepoRoot | Should -Be 'R'
            $global:__rcSteps.Seen['clone'].ProjectUrl | Should -Be 'https://example.invalid/p.git'
        }
        It 'passes a skipped refresh through as ok and skipped' {
            $global:__rcSteps.Clone = @{ success = $true; skipped = $true; errorMessage = $null }
            $s = Invoke-CycleCheckoutStep -RepoRoot 'R' -ProjectUrl ''
            $s.Ok | Should -BeTrue
            $s.Skipped | Should -BeTrue
        }
        It 'classes a failed refresh bootstrap_sync, redacts the persisted reason and keeps the operator text whole' {
            $global:__rcSteps.Clone = @{ success = $false; skipped = $false; errorMessage = 'fatal: could not read from https://u:p@host/x.git' }
            $s = Invoke-CycleCheckoutStep -RepoRoot 'R' -ProjectUrl 'https://u:p@host/x.git'
            $s.Ok | Should -BeFalse
            $s.FailureClass | Should -Be 'bootstrap_sync'
            $s.Reason | Should -Be 'fatal: could not read from https://***@host/x.git'
            $s.ErrorMessage | Should -Match 'u:p@host' -Because 'the caller shows the operator the unredacted text'
        }
        It 'turns an exception from the wrapped helper into a failed step' {
            $global:__rcSteps.CloneThrows = $true
            $s = Invoke-CycleCheckoutStep -RepoRoot 'R' -ProjectUrl 'x'
            $s.Ok | Should -BeFalse
            $s.Reason | Should -Match 'blew up'
        }
        It 'gives a failure with no message a message' {
            $global:__rcSteps.Clone = @{ success = $false; skipped = $false; errorMessage = $null }
            (Invoke-CycleCheckoutStep -RepoRoot 'R' -ProjectUrl 'x').ErrorMessage | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Invoke-CycleAdmissionStep' {
        It 'is ok and exits 0 when the host is clear, and hands the wrapped check what it was given' {
            $global:__rcSteps.Admission = [pscustomobject]@{ State = 'clear'; Reason = 'ok'; Occupants = @(); Probes = 1; Detail = '' }
            $s = Invoke-CycleAdmissionStep -HostType 'host.test' -ExceptVmName 'dev-vm'
            $s.Ok | Should -BeTrue
            $s.ExitCode | Should -Be 0
            $s.FailureClass | Should -Be ''
            $global:__rcSteps.Seen['admission'].HostType | Should -Be 'host.test'
            $global:__rcSteps.Seen['admission'].ExceptVmName | Should -Be 'dev-vm'
        }
        It 'refuses an occupied host with exit 1 and names the VMs' {
            $global:__rcSteps.Admission = [pscustomobject]@{ State = 'occupied'; Reason = 'running-vm'; Occupants = @('vm-a'); Probes = 1; Detail = '' }
            $s = Invoke-CycleAdmissionStep -HostType 'host.test'
            $s.Ok | Should -BeFalse
            $s.ExitCode | Should -Be 1
            $s.FailureClass | Should -Be 'vm_admission_occupied'
            $s.Reason | Should -Match 'vm-a'
            @($s.Occupants) | Should -Be @('vm-a')
        }
        It 'refuses an unknown host with the cannot-run exit code' {
            $global:__rcSteps.Admission = [pscustomobject]@{ State = 'unknown'; Reason = 'inventory-failed'; Occupants = @(); Probes = 3; Detail = 'utmctl did not answer' }
            $s = Invoke-CycleAdmissionStep -HostType 'host.test'
            $s.Ok | Should -BeFalse
            $s.ExitCode | Should -Be 2
            $s.FailureClass | Should -Be 'vm_admission_unknown'
            $s.Stage | Should -Be 'VmAdmission'
            $s.Probes | Should -Be 3
        }
    }

    Context 'Resolve-CycleReplayStep' {
        It 'declines, safely, when the planner is not loaded' {
            $s = Resolve-CycleReplayStep -Decision ([pscustomobject]@{ ResumeSequence = 's' }) -Checkpoint ([pscustomobject]@{ ResumeFromStep = 4; FailureClass = 'wait_timeout' })
            $s.Ok | Should -BeFalse
            $s.Reason | Should -Be 'safety-check-unavailable'
            $s.DeclineReason | Should -Be 'safety-check-unavailable'
            $s.ResumeFromStep | Should -Be 4
        }
        It 'is ok when the plan has nothing to decline, and hands the planner what it was given' {
            Install-PlanStub
            $global:__rcSteps.Plan = [pscustomobject]@{ ResumeFromStep = 2; Rewound = $true; BoundaryStep = 2; Actions = @('loadDiskSnapshot'); Classes = @('restore-point'); DeclineReason = ''; ReplayClass = '' }
            $s = Resolve-CycleReplayStep -Decision ([pscustomobject]@{ ResumeSequence = 's' }) -Checkpoint ([pscustomobject]@{ ResumeFromStep = 4; FailureClass = 'wait_timeout' }) -SequencesDir 'D' -HostType 'H' -RepoRoot 'R' -VMName 'V'
            $s.Ok | Should -BeTrue
            $s.Reason | Should -Be 'ok'
            $s.Rewound | Should -BeTrue
            $s.ResumeFromStep | Should -Be 2
            $s.BoundaryStep | Should -Be 2
            $seen = $global:__rcSteps.Seen['plan']
            @($seen.SequencesDir, $seen.HostType, $seen.RepoRoot, $seen.VMName) | Should -Be @('D', 'H', 'R', 'V')
        }
        It 'carries the reason and class of a declined plan' {
            Install-PlanStub
            $global:__rcSteps.Plan = [pscustomobject]@{ ResumeFromStep = 4; Rewound = $false; BoundaryStep = 0; Actions = @('inputTextAndEnter'); Classes = @('input'); DeclineReason = 'no-restore-point'; ReplayClass = 'input' }
            $s = Resolve-CycleReplayStep -Decision ([pscustomobject]@{ ResumeSequence = 's' }) -Checkpoint ([pscustomobject]@{ ResumeFromStep = 4; FailureClass = 'wait_timeout' })
            $s.Ok | Should -BeFalse
            $s.Reason | Should -Be 'no-restore-point'
            $s.ReplayClass | Should -Be 'input'
        }
    }
}

Describe 'The shared module is the only home of the moved code' {
    It 'no longer defines the outcome record functions in the outer loop module' {
        $text = Get-Content -LiteralPath (Join-Path $here 'Test.RunnerOuterLoop.psm1') -Raw
        foreach ($name in 'Read-OuterCycleOutcomeRecord', 'Publish-OuterCycleOutcome', 'Get-OuterUnrecordedOutcomeExitCode', 'Read-OuterVmAdmissionRecord') {
            $text | Should -Not -Match ([regex]::Escape($name)) -Because "$name moved to the contract module"
        }
    }
}
