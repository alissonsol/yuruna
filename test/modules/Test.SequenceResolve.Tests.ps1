<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42c94790-0880-4f88-b0b7-07f2de824904
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence snippet pester
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
    Pester guard on the step-snippet expansion in Test.SequenceResolve.psm1
    (Expand-SequenceSnippet, reached via Read-SequenceFile).
.DESCRIPTION
    Verifies: top-level + nested-retry splicing; project-overrides-framework
    layering; unknown-name / duplicate-project / cycle fatals; and that a
    snippet-free sequence is returned unchanged. Each case uses a unique temp
    dir so the path-keyed library cache never collides across cases.

    Fixtures and helpers live in BeforeAll for Pester 6.x discovery/run scope.
    See https://yuruna.link/42d38664-000b for suite execution.
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.SequenceResolve.psm1'
Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# Unqualified file-scope fixtures. An It body resolves an unqualified file-level
# variable but not a $script:-qualified one: the run pass re-enters the file in a
# fresh scope, so $script: writes land in a script scope the It bodies never see
# and the value would arrive as $null -- silently skipping every yaml case and
# handing New-SnippetTestDir a null root.
$script:yamlAvailable = [bool](Get-Module -ListAvailable -Name powershell-yaml)
$tmpRoot = Join-Path $TestDrive 'snippet-tests'

function New-SnippetTestDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test temp dir.')]
    [CmdletBinding()]
    param()
    # Returns a fresh, empty test root unique to this case (so the path-keyed
    # snippet-library cache never serves a stale parse from a prior case). The
    # counter is $script:-scoped inside the function, where it does persist
    # across calls, so each case gets its own directory.
    $script:caseSeq++
    $dir = Join-Path $tmpRoot ("case{0:D3}" -f $script:caseSeq)
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Write-TextFile {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Set-Content -LiteralPath $Path -Value $Content -Encoding utf8
}

}

Describe 'Test.SequenceResolve step-snippet expansion' {
    It 'returns null for an empty YAML sequence with and without caching' {
        $path = Join-Path $TestDrive 'empty.yml'
        Set-Content -LiteralPath $path -Value ''
        foreach ($noCache in @($false, $true)) {
            $null -eq (Read-SequenceFile -Path $path -NoCache:$noCache) | Should -BeTrue
        }
    }


    It 'splices a top-level snippet reference into its steps' {
        if (-not $script:yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
        $root = New-SnippetTestDir
        Write-TextFile (Join-Path $root '_snippets.yml') @"
prime:
  - action: pressKey
    name: Enter
  - action: waitForSeconds
    seconds: 2
"@
        $seqPath = Join-Path $root 'seq.yml'
        Write-TextFile $seqPath @"
description: t
steps:
  - snippet: prime
  - action: waitForText
    pattern: "x"
"@
        $seq = Read-SequenceFile -Path $seqPath -NoCache
        Assert-Equal -Expected 3 -Actual (@($seq.steps).Count) -Because 'snippet (2 steps) + 1 inline = 3'
        Assert-Equal 'pressKey'      $seq.steps[0].action
        Assert-Equal 'waitForSeconds' $seq.steps[1].action
        Assert-Equal 'waitForText'   $seq.steps[2].action
    }

    It 'splices a snippet referenced inside retry.steps' {
        if (-not $script:yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
        $root = New-SnippetTestDir
        Write-TextFile (Join-Path $root '_snippets.yml') @"
prime:
  - action: pressKey
    name: Enter
"@
        $seqPath = Join-Path $root 'seq.yml'
        Write-TextFile $seqPath @"
description: t
steps:
  - action: retry
    maxAttempts: 2
    steps:
      - snippet: prime
      - action: passwdPrompt
        pattern: "login:"
        text: "u"
"@
        $seq = Read-SequenceFile -Path $seqPath -NoCache
        $inner = @($seq.steps[0].steps)
        Assert-Equal -Expected 2 -Actual $inner.Count -Because 'snippet (1) + passwdPrompt (1)'
        Assert-Equal 'pressKey'     $inner[0].action
        Assert-Equal 'passwdPrompt' $inner[1].action
    }

    It 'expands a snippet that references another snippet' {
        if (-not $script:yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
        $root = New-SnippetTestDir
        Write-TextFile (Join-Path $root '_snippets.yml') @"
outer:
  - snippet: inner
  - action: waitForSeconds
    seconds: 1
inner:
  - action: pressKey
    name: Enter
"@
        $seqPath = Join-Path $root 'seq.yml'
        Write-TextFile $seqPath @"
description: t
steps:
  - snippet: outer
"@
        $seq = Read-SequenceFile -Path $seqPath -NoCache
        Assert-Equal 2 (@($seq.steps).Count)
        Assert-Equal 'pressKey'       $seq.steps[0].action
        Assert-Equal 'waitForSeconds' $seq.steps[1].action
    }

    It 'throws on an unknown snippet name' {
        if (-not $script:yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
        $root = New-SnippetTestDir
        Write-TextFile (Join-Path $root '_snippets.yml') @"
known:
  - action: pressKey
    name: Enter
"@
        $seqPath = Join-Path $root 'seq.yml'
        Write-TextFile $seqPath @"
description: t
steps:
  - snippet: missing
"@
        Assert-Throw { Read-SequenceFile -Path $seqPath -NoCache } 'snippet ''missing'' .* not found'
    }

    It 'throws on a snippet reference cycle' {
        if (-not $script:yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
        $root = New-SnippetTestDir
        Write-TextFile (Join-Path $root '_snippets.yml') @"
a:
  - snippet: b
b:
  - snippet: a
"@
        $seqPath = Join-Path $root 'seq.yml'
        Write-TextFile $seqPath @"
description: t
steps:
  - snippet: a
"@
        Assert-Throw { Read-SequenceFile -Path $seqPath -NoCache } 'cycle'
    }

    It 'returns a snippet-free sequence with its steps unchanged' {
        if (-not $script:yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
        $root = New-SnippetTestDir
        $seqPath = Join-Path $root 'seq.yml'
        Write-TextFile $seqPath @"
description: t
steps:
  - action: waitForText
    pattern: "x"
  - action: pressKey
    name: Enter
"@
        $seq = Read-SequenceFile -Path $seqPath -NoCache
        Assert-Equal 2 (@($seq.steps).Count)
        Assert-Equal 'waitForText' $seq.steps[0].action
        Assert-Equal 'pressKey'    $seq.steps[1].action
    }

    It 'lets a project snippet override a framework snippet of the same name' {
        if (-not $script:yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
        $root = New-SnippetTestDir
        # Flat framework library + sequence under test/sequences/.
        Write-TextFile (Join-Path $root 'test/sequences/_snippets.yml') @"
greet:
  - action: inputText
    text: "framework"
"@
        # Project library overriding 'greet' under project/ex/test/.
        Write-TextFile (Join-Path $root 'project/ex/test/_snippets.yml') @"
greet:
  - action: inputText
    text: "project"
"@
        $seqPath = Join-Path $root 'test/sequences/seq.yml'
        Write-TextFile $seqPath @"
description: t
steps:
  - snippet: greet
"@
        $seq = Read-SequenceFile -Path $seqPath -NoCache
        Assert-Equal 1 (@($seq.steps).Count)
        Assert-Equal -Expected 'project' -Actual $seq.steps[0].text -Because 'project library wins over framework'
    }

    It 'resolves the flat framework snippet lib from a flat project sequence' {
        if (-not $script:yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
        $root = New-SnippetTestDir
        Write-TextFile (Join-Path $root 'test/sequences/_snippets.yml') @"
firstLoginPrime:
  - action: inputText
    text: "framework-flat"
"@
        $seqPath = Join-Path $root 'project/ex/test/seq.yml'
        Write-TextFile $seqPath @"
description: t
steps:
  - snippet: firstLoginPrime
"@
        $seq = Read-SequenceFile -Path $seqPath -NoCache
        Assert-Equal 1 (@($seq.steps).Count)
        Assert-Equal -Expected 'framework-flat' -Actual $seq.steps[0].text -Because 'flat project sequence resolves the flat framework snippet'
    }

    It 'throws when two project libraries define the same snippet name' {
        if (-not $script:yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
        $root = New-SnippetTestDir
        Write-TextFile (Join-Path $root 'project/a/test/_snippets.yml') @"
dup:
  - action: pressKey
    name: Enter
"@
        Write-TextFile (Join-Path $root 'project/b/test/_snippets.yml') @"
dup:
  - action: pressKey
    name: Enter
"@
        $seqPath = Join-Path $root 'project/a/test/seq.yml'
        Write-TextFile $seqPath @"
description: t
steps:
  - snippet: dup
"@
        Assert-Throw { Read-SequenceFile -Path $seqPath -NoCache } 'two project libraries'
    }
}

Describe 'Resolve-SequencePath literal-path probing (Test-Path -LiteralPath)' {

    # A sequence name can contain PowerShell wildcard metacharacters; brackets are
    # a character-class. These guard that the framework-tier probes match the name
    # literally rather than glob-expanding it. RepoRoot points at a project-free
    # temp dir so resolution falls through to the framework SequencesDir tier.

    It 'resolves a bracketed sequence name to its literal file' {
        $root = New-SnippetTestDir
        $seqDir = Join-Path $root 'sequences'
        $file = Join-Path $seqDir 'odd[1].yml'
        Write-TextFile $file 'x'
        $resolved = Resolve-SequencePath -SequencesDir $seqDir -Name 'odd[1]' -RepoRoot $root
        Assert-Equal -Expected $file -Actual $resolved -Because 'odd[1] must resolve to its literal odd[1].yml'
    }

    It 'does not glob-match a different file when the literal name is absent' {
        $root = New-SnippetTestDir
        $seqDir = Join-Path $root 'sequences'
        # Only the literal-digit file exists; a bracketed query [1] must NOT match
        # it (a bare Test-Path would glob odd[1].yml onto odd1.yml).
        Write-TextFile (Join-Path $seqDir 'odd1.yml') 'x'
        $resolved = Resolve-SequencePath -SequencesDir $seqDir -Name 'odd[1]' -RepoRoot $root
        Assert-True ($null -eq $resolved) 'odd[1] must not glob-match odd1.yml'
    }
}

Describe 'ConvertTo-NormalizedSequence (F2 resource/component/workload bridge)' {

    It 'aliases resource -> baseline and concatenates component ++ workload into steps' {
        if (-not $script:yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
        $root = New-SnippetTestDir
        $seqPath = Join-Path $root 'seq.yml'
        Write-TextFile $seqPath @"
description: t
keystrokeMechanism: gui
resource:
  ubuntu.server.24:
    - start.guest.ubuntu.server.24
component:
  - action: pressKey
    name: Enter
workload:
  - action: fetchAndExecute
    text: "x"
    waitPattern: "y"
"@
        $seq = Read-SequenceFile -Path $seqPath -NoCache
        Assert-True ($seq.Contains('baseline')) 'resource must be aliased onto baseline'
        Assert-True ($seq.baseline.Contains('ubuntu.server.24')) 'baseline keeps the resource OS key'
        Assert-Equal -Expected 2 -Actual (@($seq.steps).Count) -Because 'component (1) + workload (1) = 2 steps'
        Assert-Equal 'pressKey'        $seq.steps[0].action
        Assert-Equal 'fetchAndExecute' $seq.steps[1].action
    }

    It 'expands a snippet referenced inside the component list' {
        if (-not $script:yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
        $root = New-SnippetTestDir
        Write-TextFile (Join-Path $root '_snippets.yml') @"
prime:
  - action: pressKey
    name: Enter
  - action: waitForSeconds
    seconds: 1
"@
        $seqPath = Join-Path $root 'seq.yml'
        Write-TextFile $seqPath @"
description: t
keystrokeMechanism: gui
resource:
  ubuntu.server.24:
    - start.guest.ubuntu.server.24
component:
  - snippet: prime
workload:
  - action: waitForText
    pattern: "z"
"@
        $seq = Read-SequenceFile -Path $seqPath -NoCache
        Assert-Equal -Expected 3 -Actual (@($seq.steps).Count) -Because 'prime (2) + workload (1) = 3'
        Assert-Equal 'pressKey'       $seq.steps[0].action
        Assert-Equal 'waitForSeconds' $seq.steps[1].action
        Assert-Equal 'waitForText'    $seq.steps[2].action
    }

    It 'defaults a missing keystrokeMechanism to gui' {
        if (-not $script:yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
        $root = New-SnippetTestDir
        $seqPath = Join-Path $root 'seq.yml'
        Write-TextFile $seqPath @"
description: t
resource:
  ubuntu.server.24: []
workload:
  - action: pressKey
    name: Enter
"@
        $seq = Read-SequenceFile -Path $seqPath -NoCache
        Assert-Equal -Expected 'gui' -Actual $seq.keystrokeMechanism -Because 'missing keystrokeMechanism loads as gui'
    }

    It 'rejects the legacy baseline: key with a migration error' {
        if (-not $script:yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
        $root = New-SnippetTestDir
        $seqPath = Join-Path $root 'seq.yml'
        Write-TextFile $seqPath @"
description: t
baseline:
  ubuntu.server.24: []
steps:
  - action: pressKey
    name: Enter
"@
        Assert-Throw { Read-SequenceFile -Path $seqPath -NoCache } "Legacy 'baseline:' is no longer supported"
    }

    It 'rejects top-level steps: on a guest (resource) sequence' {
        if (-not $script:yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
        $root = New-SnippetTestDir
        $seqPath = Join-Path $root 'seq.yml'
        Write-TextFile $seqPath @"
description: t
keystrokeMechanism: gui
resource:
  ubuntu.server.24: []
steps:
  - action: pressKey
    name: Enter
"@
        Assert-Throw { Read-SequenceFile -Path $seqPath -NoCache } "must not use top-level 'steps:'"
    }

    It 'leaves an orchestration (steps, no resource) sequence untouched' {
        if (-not $script:yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
        $root = New-SnippetTestDir
        $seqPath = Join-Path $root 'seq.yml'
        Write-TextFile $seqPath @"
name: orch
description: t
steps:
  - action: InvokeTestSequence
    sequence: something
"@
        $seq = Read-SequenceFile -Path $seqPath -NoCache
        Assert-True (-not $seq.Contains('resource')) 'no resource on an orchestration'
        Assert-True (-not $seq.Contains('baseline')) 'no baseline synthesized for an orchestration'
        Assert-Equal 1 (@($seq.steps).Count)
        Assert-Equal 'InvokeTestSequence' $seq.steps[0].action
    }
}

Describe 'Resolve-SequencePath flat (post-flatten) tier' {

    It 'resolves a flat framework sequence by exact name' {
        $root = New-SnippetTestDir
        $seqDir = Join-Path $root 'sequences'
        $file = Join-Path $seqDir 'flat.one.yml'
        Write-TextFile $file 'description: t'
        $resolved = Resolve-SequencePath -SequencesDir $seqDir -Name 'flat.one' -RepoRoot $root
        Assert-Equal -Expected $file -Actual $resolved -Because 'flat framework file resolves without a mode subfolder'
    }

    It 'resolves a flat project sequence under any test/ folder' {
        $root = New-SnippetTestDir
        $seqDir = Join-Path $root 'sequences'
        $file = Join-Path $root 'project/example/website/test/flat.proj.yml'
        Write-TextFile $file 'description: t'
        $resolved = Resolve-SequencePath -SequencesDir $seqDir -Name 'flat.proj' -RepoRoot $root
        Assert-Equal -Expected $file -Actual $resolved -Because 'flat project file resolves under project/.../test/'
    }

    It 'resolves an explicit .ssh name to its .ssh.yml file' {
        $root = New-SnippetTestDir
        $seqDir = Join-Path $root 'sequences'
        Write-TextFile (Join-Path $seqDir 'dual.yml') 'description: gui'
        Write-TextFile (Join-Path $seqDir 'dual.ssh.yml') 'description: ssh'
        $resolvedGui = Resolve-SequencePath -SequencesDir $seqDir -Name 'dual' -RepoRoot $root
        Assert-Equal -Expected (Join-Path $seqDir 'dual.yml') -Actual $resolvedGui -Because 'plain name -> dual.yml'
        $resolvedSsh = Resolve-SequencePath -SequencesDir $seqDir -Name 'dual.ssh' -RepoRoot $root
        Assert-Equal -Expected (Join-Path $seqDir 'dual.ssh.yml') -Actual $resolvedSsh -Because 'explicit .ssh name -> dual.ssh.yml'
    }
}

Describe 'Get-StepLeadAction (what a step actually leads with)' {
    # Nesting is detected structurally, by a `steps` key, so a wrapper verb added
    # later is read correctly without this function learning its name.
    It 'returns a plain step own action' {
        Assert-Equal -Expected 'loadDiskSnapshot' -Actual (Get-StepLeadAction -Step @{ action = 'loadDiskSnapshot' })
    }
    It 'reads through a wrapper to its first inner step' {
        $step = @{ action = 'retry'; steps = @(@{ action = 'loadDiskSnapshot' }, @{ action = 'sshWaitReady' }) }
        Assert-Equal -Expected 'loadDiskSnapshot' -Actual (Get-StepLeadAction -Step $step)
    }
    It 'reads through nested wrappers' {
        $step = @{ action = 'retry'; steps = @(@{ action = 'retry'; steps = @(@{ action = 'loadDiskSnapshot' }) }) }
        Assert-Equal -Expected 'loadDiskSnapshot' -Actual (Get-StepLeadAction -Step $step)
    }
    It 'reports a wrapper that wraps nothing by its own name' {
        # The retry handler fails an empty block itself, so `retry` is what runs.
        Assert-Equal -Expected 'retry' -Actual (Get-StepLeadAction -Step @{ action = 'retry' })
        Assert-Equal -Expected 'retry' -Actual (Get-StepLeadAction -Step @{ action = 'retry'; steps = @() })
    }
    It 'coerces a missing action to an empty string, matching nothing' {
        Assert-Equal -Expected '' -Actual (Get-StepLeadAction -Step @{ description = 'no action here' })
        Assert-Equal -Expected '' -Actual (Get-StepLeadAction -Step $null)
    }
    It 'reads an OrderedDictionary step, the shape the YAML loader produces' {
        $inner = [ordered]@{ action = 'loadDiskSnapshot'; id = 'probe' }
        $step  = [ordered]@{ action = 'retry'; steps = @($inner) }
        Assert-Equal -Expected 'loadDiskSnapshot' -Actual (Get-StepLeadAction -Step $step)
    }
}

Describe 'planner failure identity is independent of diagnostic text' {
    BeforeAll {
        function Invoke-ActualPlannerCatch {
            param([string]$Owner, [Exception]$Failure)
            $path = Join-Path $PSScriptRoot ('Test.' + $Owner + '.psm1')
            $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
            if ($Owner -eq 'SequencePlanner') {
                $ast = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Add-CyclePlanEntriesForTopLevel' }, $true)
            }
            $catches = @($ast.FindAll({
                param($node)
                $node -is [Management.Automation.Language.CatchClauseAst] -and
                    $node.Body.Extent.Text.Contains('Test-SequencePlannerFailure -ErrorObject $_') -and
                    @($node.Body.FindAll({ param($child) $child -is [Management.Automation.Language.CatchClauseAst] }, $true)).Count -eq 0
            }, $true))
            Assert-Equal 1 $catches.Count 'the actual owner must have one planner-routing catch'
            $body = $catches[0].Body.Extent.Text
            $harness = [scriptblock]::Create(@'
param([Exception]$Failure)
function Format-YurunaOperatorMessage { param($Key, $Arguments) $null = $Arguments; return $Key }
function Write-CycleInfraFailure { param($Stage, $FailureClass, $GuestKey, $ErrorMessage, $HostType)
    $null = @($Stage, $GuestKey, $ErrorMessage, $HostType); $records.Add($FailureClass)
}
$records = [Collections.Generic.List[string]]::new()
$plannerFatal = $false
$reThrown = $false
$HostType = 'fixture'
try {
    foreach ($iteration in 1) {
        $null = $iteration
        try { throw $Failure }
        catch __BODY__
    }
} catch { $reThrown = $true }
[pscustomobject]@{ ReThrown = $reThrown; PlannerFatal = $plannerFatal; Codes = $records.ToArray() }
'@.Replace('__BODY__', $body))
            $results = @(& $harness $Failure 3>$null)
            return $results[-1]
        }
    }

    It 'recognizes typed nested failures in both actual catches regardless of their language' {
        $failure = [InvalidOperationException]::new(([char]0x627).ToString() + ' arbitrary diagnostic')
        $failure.Data['YurunaFailureCode'] = 'sequence.plan_invalid'
        $wrapped = [Exception]::new('invocation wrapper', $failure)
        Assert-True (Test-SequencePlannerFailure -ErrorObject $wrapped)
        $record = [Management.Automation.ErrorRecord]::new($wrapped, 'fixture', [Management.Automation.ErrorCategory]::InvalidData, $null)
        Assert-True (Test-SequencePlannerFailure -ErrorObject $record)
        $planner = Invoke-ActualPlannerCatch -Owner 'SequencePlanner' -Failure $wrapped
        Assert-True $planner.ReThrown 'the planner swallowed a classified invalid plan'
        $runner = Invoke-ActualPlannerCatch -Owner 'RunnerInnerLoop' -Failure $wrapped
        Assert-True $runner.PlannerFatal 'the runner fell back to a guest list for an invalid plan'
        Assert-Equal 'plan_invalid' ($runner.Codes -join ',') 'the infrastructure failure lost its stable class'
    }

    It 'does not classify an untyped English prefix as an invalid plan' {
        $failure = [InvalidOperationException]::new('PlannerFatal: unclassified external prose')
        Assert-False (Test-SequencePlannerFailure -ErrorObject $failure)
        $planner = Invoke-ActualPlannerCatch -Owner 'SequencePlanner' -Failure $failure
        Assert-False $planner.ReThrown 'the planner classified display text as control state'
        $runner = Invoke-ActualPlannerCatch -Owner 'RunnerInnerLoop' -Failure $failure
        Assert-False $runner.PlannerFatal 'the runner classified display text as control state'
        Assert-Equal 0 $runner.Codes.Count 'an untyped exception acquired a classified failure event'
    }

    It 'preserves typed snippet failures through the real sequence reader' {
        if (-not $script:yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
        $root = New-SnippetTestDir
        $path = Join-Path $root 'typed.yml'
        Write-TextFile $path "steps:`n  - snippet: missing_snippet`n"
        $caught = $null
        try { $null = Read-SequenceFile -Path $path -NoCache } catch { $caught = $_ }
        Assert-NotNull $caught 'the invalid snippet was accepted'
        Assert-True (Test-SequencePlannerFailure -ErrorObject $caught) 'the YAML error wrapper discarded the planner classification'
        Assert-True ($caught.Exception.Data['YurunaMessageCode'] -like 'exceptions.*') 'the reader lost the catalog message identity'
    }
}

Describe 'step sentences through Read-SequenceFile' {
    BeforeAll {
        Import-Module powershell-yaml -ErrorAction Stop
        $script:SentenceRepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
        $script:SentenceSchemaJson = Get-Content -Raw -LiteralPath (Join-Path $script:SentenceRepoRoot 'test/schemas/sequence.schema.yml') |
            ConvertFrom-Yaml -Ordered | ConvertTo-Json -Depth 32
        $script:SentenceCase = 0
        $script:FakePhrases = @'
phrases:
  press-key:
    sentence: "press <key:key>"
    screen:
      - action: pressKey
        name: "<key>"
  wait-for-text:
    sentence: "wait for text <text>"
    screen:
      - action: waitForText
        pattern: "<text>"
  greet:
    sentence: "greet <name>"
    screen:
      - action: inputTextAndEnter
        text: "hello <name>"
      - action: waitForText
        pattern: "<name>"
  probe:
    sentence: "probe"
    screen:
      - action: pressKey
        name: Enter
    page:
      - action: waitForSeconds
        seconds: 1
'@

        function New-SentenceRoot {
            <#
            .SYNOPSIS
                A fresh fake framework root with the fixture phrase library and a project test folder.
            #>
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Creates a test folder under TestDrive.')]
            [CmdletBinding()]
            [OutputType([string])]
            param()
            $script:SentenceCase++
            $root = Join-Path $TestDrive ('sentence{0:D3}' -f $script:SentenceCase)
            foreach ($folder in 'test/sequences', 'project/ex/test') { New-Item -ItemType Directory -Path (Join-Path $root $folder) -Force | Out-Null }
            [IO.File]::WriteAllText((Join-Path $root 'test/sequences/_phrases.yml'), $script:FakePhrases)
            return $root
        }

        function Write-SentenceFile {
            <#
            .SYNOPSIS
                Write a fixture file and move its write time past any earlier write.
            #>
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
            $previous = if (Test-Path -LiteralPath $Path) { (Get-Item -LiteralPath $Path).LastWriteTimeUtc } else { $null }
            [IO.File]::WriteAllText($Path, $Content)
            if ($previous) { (Get-Item -LiteralPath $Path).LastWriteTimeUtc = $previous.AddSeconds(2) }
        }

        function Get-GuestSequenceText {
            <#
            .SYNOPSIS
                A guest sequence with the given component and workload entries.
            #>
            [CmdletBinding()]
            [OutputType([string])]
            param([string]$Component = '', [string]$Workload = '', [string]$Extra = '')
            $text = "description: t`nkeystrokeMechanism: gui`nresource:`n  ubuntu.server.26: []`n$Extra"
            if ($Component) { $text += "component:`n$Component" }
            if ($Workload) { $text += "workload:`n$Workload" }
            return $text
        }

        function Get-FlatAction {
            <#
            .SYNOPSIS
                Action names in order, each step followed by its steps and then its stepsAfterVmRestart.
            #>
            [CmdletBinding()]
            [OutputType([string])]
            param([AllowEmptyCollection()][object[]]$Step)
            foreach ($entry in $Step) {
                [string]$entry['action']
                if ($entry.Contains('steps')) { Get-FlatAction -Step @($entry['steps']) }
                if ($entry.Contains('stepsAfterVmRestart')) { Get-FlatAction -Step @($entry['stepsAfterVmRestart']) }
            }
        }

        function Get-ReadFailure {
            <#
            .SYNOPSIS
                The error a read throws; fails the case when the read succeeds.
            #>
            [CmdletBinding()]
            [OutputType([Management.Automation.ErrorRecord])]
            param([Parameter(Mandatory)][string]$Path, [switch]$NoCache)
            try { $null = Read-SequenceFile -Path $Path -NoCache:$NoCache } catch { return $_ }
            throw "Expected the read of $Path to fail."
        }
    }

    It 'expands a file of step entries on the fresh and the cached read' {
        $root = New-SentenceRoot
        $path = Join-Path $root 'test/sequences/workload.fixture.yml'
        Write-SentenceFile -Path $path -Content (Get-GuestSequenceText -Component "  - step: ""press Enter""`n" -Workload "  - step: ""greet Ann""`n")
        foreach ($read in 1, 2) {
            $steps = @((Read-SequenceFile -Path $path).steps)
            Assert-StringEqual -Expected 'pressKey,inputTextAndEnter,waitForText' -Actual (@($steps | ForEach-Object { $_['action'] }) -join ',') -Because "read $read"
            foreach ($step in $steps) { Assert-False $step.Contains('step') "read $read left a sentence entry" }
        }
    }

    It 'expands sentences under retry steps, stepsAfterVmRestart and snippets in place and in order' {
        $root = New-SentenceRoot
        [IO.File]::WriteAllText((Join-Path $root 'test/sequences/_snippets.yml'), "prime:`n  - step: ""press Tab""`n  - action: waitForSeconds`n    seconds: 1`n")
        $path = Join-Path $root 'test/sequences/workload.fixture.yml'
        $component = @'
  - action: retry
    restartVmBeforeRetry: coldPowerCycle
    steps:
      - step: "press Enter"
      - action: retry
        steps:
          - step: "wait for text ready"
    stepsAfterVmRestart:
      - step: "greet Ann"
  - snippet: prime
'@
        Write-SentenceFile -Path $path -Content (Get-GuestSequenceText -Component ($component + "`n"))
        $flat = @(Get-FlatAction -Step @((Read-SequenceFile -Path $path -NoCache).steps)) -join ','
        Assert-StringEqual -Expected 'retry,pressKey,retry,waitForText,inputTextAndEnter,waitForText,pressKey,waitForSeconds' -Actual $flat
    }

    It 'expands a snippet placed under stepsAfterVmRestart' {
        $root = New-SentenceRoot
        [IO.File]::WriteAllText((Join-Path $root 'test/sequences/_snippets.yml'), "prime:`n  - action: pressKey`n    name: Tab`n  - action: waitForSeconds`n    seconds: 1`n")
        $path = Join-Path $root 'test/sequences/workload.fixture.yml'
        $component = "  - action: retry`n    restartVmBeforeRetry: coldPowerCycle`n    steps:`n      - action: pressKey`n        name: Enter`n    stepsAfterVmRestart:`n      - snippet: prime`n"
        Write-SentenceFile -Path $path -Content (Get-GuestSequenceText -Component $component)
        $after = @((Read-SequenceFile -Path $path -NoCache).steps[0]['stepsAfterVmRestart'])
        Assert-StringEqual -Expected 'pressKey,waitForSeconds' -Actual (@($after | ForEach-Object { $_['action'] }) -join ',')
    }

    It 'uses defaultSurface for a sentence without on' {
        $root = New-SentenceRoot
        $path = Join-Path $root 'test/sequences/workload.fixture.yml'
        Write-SentenceFile -Path $path -Content (Get-GuestSequenceText -Extra "defaultSurface: page`n" -Component "  - step: ""probe""`n")
        $steps = @((Read-SequenceFile -Path $path -NoCache).steps)
        Assert-Equal -Expected 1 -Actual $steps.Count
        Assert-StringEqual -Expected 'waitForSeconds' -Actual $steps[0]['action']
    }

    It 'rejects a defaultSurface that is neither screen nor page' {
        $root = New-SentenceRoot
        foreach ($surfaceValue in 'web', 'Page') {
            $path = Join-Path $root "test/sequences/workload.fixture.$surfaceValue.yml"
            Write-SentenceFile -Path $path -Content (Get-GuestSequenceText -Extra "defaultSurface: $surfaceValue`n" -Component "  - action: pressKey`n    name: Enter`n")
            $caught = Get-ReadFailure -Path $path -NoCache
            Assert-StringEqual -Expected 'runner.step_sentence_invalid' -Actual $caught.Exception.Data['YurunaMessageCode'] -Because $surfaceValue
            Assert-True $caught.Exception.Message.Contains('default-surface') $caught.Exception.Message
        }
    }

    It 'lets on win over defaultSurface' {
        $root = New-SentenceRoot
        $toScreen = Join-Path $root 'test/sequences/workload.fixture.screen.yml'
        Write-SentenceFile -Path $toScreen -Content (Get-GuestSequenceText -Extra "defaultSurface: page`n" -Component "  - step: ""probe""`n    on: screen`n")
        Assert-StringEqual -Expected 'pressKey' -Actual @((Read-SequenceFile -Path $toScreen -NoCache).steps)[0]['action']
        $toPage = Join-Path $root 'test/sequences/workload.fixture.page.yml'
        Write-SentenceFile -Path $toPage -Content (Get-GuestSequenceText -Extra "defaultSurface: screen`n" -Component "  - step: ""probe""`n    on: page`n")
        Assert-StringEqual -Expected 'waitForSeconds' -Actual @((Read-SequenceFile -Path $toPage -NoCache).steps)[0]['action']
    }

    It 'refuses a sentence in a document without resource' {
        $root = New-SentenceRoot
        [IO.File]::WriteAllText((Join-Path $root 'test/sequences/_snippets.yml'), "prime:`n  - step: ""press Enter""`n")
        $direct = Join-Path $root 'test/sequences/orchestration.direct.yml'
        Write-SentenceFile -Path $direct -Content "description: t`nsteps:`n  - step: ""press Enter""`n"
        $viaSnippet = Join-Path $root 'test/sequences/orchestration.snippet.yml'
        Write-SentenceFile -Path $viaSnippet -Content "description: t`nsteps:`n  - snippet: prime`n"
        foreach ($case in @(@{ Path = $direct; Position = 'steps[1]' }, @{ Path = $viaSnippet; Position = 'steps[1].snippet(prime)[1]' })) {
            $caught = Get-ReadFailure -Path $case.Path -NoCache
            Assert-StringEqual -Expected 'runner.step_sentence_invalid' -Actual $caught.Exception.Data['YurunaMessageCode']
            Assert-True $caught.Exception.Message.Contains('not-guest-sequence') $caught.Exception.Message
            Assert-True $caught.Exception.Message.Contains("$($case.Path): $($case.Position)") $caught.Exception.Message
        }
        $plain = Join-Path $root 'test/sequences/orchestration.plain.yml'
        Write-SentenceFile -Path $plain -Content "description: t`ndefaultSurface: web`nsteps:`n  - action: InvokeTestSequence`n    sequence: x`n"
        $read = Read-SequenceFile -Path $plain -NoCache
        Assert-StringEqual -Expected 'InvokeTestSequence' -Actual @($read.steps)[0]['action']
        Assert-StringEqual -Expected 'web' -Actual $read['defaultSurface']
    }

    It 'loads a library once when the project folder is also the sequence folder' {
        $root = New-SentenceRoot
        [IO.File]::WriteAllText((Join-Path $root 'project/ex/test/_phrases.yml'), "phrases:`n  hello:`n    sentence: ""hello <name>""`n    screen:`n      - action: inputText`n        text: ""<name>""`n")
        $path = Join-Path $root 'project/ex/test/workload.fixture.yml'
        Write-SentenceFile -Path $path -Content (Get-GuestSequenceText -Component "  - step: ""hello Bob""`n")
        $steps = @((Read-SequenceFile -Path $path -NoCache).steps)
        Assert-StringEqual -Expected 'inputText' -Actual $steps[0]['action']
        Assert-StringEqual -Expected 'Bob' -Actual $steps[0]['text']
    }

    It 'sees a library edit, an added library and a removed library on the next cached read' {
        $root = New-SentenceRoot
        $framework = Join-Path $root 'test/sequences/_phrases.yml'
        $project = Join-Path $root 'project/ex/test/_phrases.yml'
        $path = Join-Path $root 'test/sequences/workload.fixture.yml'
        Write-SentenceFile -Path $path -Content (Get-GuestSequenceText -Component "  - step: ""probe""`n")
        Assert-StringEqual -Expected 'Enter' -Actual @((Read-SequenceFile -Path $path).steps)[0]['name']
        Write-SentenceFile -Path $framework -Content $script:FakePhrases.Replace("        name: Enter`n    page:", "        name: Tab`n    page:")
        Assert-StringEqual -Expected 'Tab' -Actual @((Read-SequenceFile -Path $path).steps)[0]['name'] -Because 'a library edit is seen'
        Write-SentenceFile -Path $project -Content "phrases:`n  hello:`n    sentence: ""hello <name>""`n    screen:`n      - action: inputText`n        text: ""<name>""`n"
        Write-SentenceFile -Path $path -Content (Get-GuestSequenceText -Component "  - step: ""probe""`n  - step: ""hello Bob""`n")
        Assert-StringEqual -Expected 'inputText' -Actual @((Read-SequenceFile -Path $path).steps)[1]['action'] -Because 'an added library is seen'
        Remove-Item -LiteralPath $project
        $caught = Get-ReadFailure -Path $path
        Assert-StringEqual -Expected 'runner.step_phrase_no_match' -Actual $caught.Exception.Data['YurunaMessageCode'] -Because 'a removed library is seen'
    }

    It 'returns new step objects on every read of a sequence with a sentence' {
        $root = New-SentenceRoot
        $path = Join-Path $root 'test/sequences/workload.fixture.yml'
        Write-SentenceFile -Path $path -Content (Get-GuestSequenceText -Component "  - step: ""press Enter""`n")
        $first = @((Read-SequenceFile -Path $path).steps)
        $first[0]['name'] = 'Escape'
        $second = @((Read-SequenceFile -Path $path).steps)
        Assert-StringEqual -Expected 'Enter' -Actual $second[0]['name']
        Assert-False ([object]::ReferenceEquals($first[0], $second[0])) 'each read builds new steps'
    }

    It 'returns a sequence of plain action steps untouched' {
        $root = New-SentenceRoot
        $path = Join-Path $root 'test/sequences/workload.fixture.yml'
        Write-SentenceFile -Path $path -Content (Get-GuestSequenceText -Component "  - action: pressKey`n    name: Enter`n")
        $first = @((Read-SequenceFile -Path $path).steps)
        $second = @((Read-SequenceFile -Path $path).steps)
        Assert-True ([object]::ReferenceEquals($first[0], $second[0])) 'a plain sequence is not rebuilt'
    }

    It 'rejects <Case> in the schema and in the reader' -TestCases @(
        @{ Case = 'step with action'; Code = 'runner.step_form_invalid'; Entry = "  - step: ""press Enter""`n    action: pressKey`n    name: Enter`n" }
        @{ Case = 'step with snippet'; Code = 'runner.step_form_invalid'; Entry = "  - step: ""press Enter""`n    snippet: prime`n" }
        @{ Case = 'action with snippet'; Code = 'runner.step_form_invalid'; Entry = "  - action: pressKey`n    name: Enter`n    snippet: prime`n" }
        @{ Case = 'no discriminator'; Code = 'runner.step_form_invalid'; Entry = "  - description: x`n" }
        @{ Case = 'an unknown key on a sentence step'; Code = 'runner.step_sentence_invalid'; Entry = "  - step: ""press Enter""`n    nudge: 1`n" }
        @{ Case = 'the key spelled Step'; Code = 'runner.step_sentence_invalid'; Entry = "  - Step: ""press Enter""`n" }
        @{ Case = 'on web'; Code = 'runner.step_sentence_invalid'; Entry = "  - step: ""press Enter""`n    on: web`n" }
        @{ Case = 'on Page'; Code = 'runner.step_sentence_invalid'; Entry = "  - step: ""press Enter""`n    on: Page`n" }
        @{ Case = 'timeoutSeconds 0'; Code = 'runner.step_sentence_invalid'; Entry = "  - step: ""wait for text ready""`n    timeoutSeconds: 0`n" }
        @{ Case = 'timeoutSeconds 3000000000'; Code = 'runner.step_sentence_invalid'; Entry = "  - step: ""wait for text ready""`n    timeoutSeconds: 3000000000`n" }
        @{ Case = 'descriptionLocalized without description'; Code = 'runner.step_sentence_invalid'; Entry = "  - step: ""press Enter""`n    descriptionLocalized:`n      pt-BR: x`n" }
        @{ Case = 'a blank step'; Code = 'runner.step_sentence_invalid'; Entry = "  - step: "" ""`n" }
    ) {
        $root = New-SentenceRoot
        [IO.File]::WriteAllText((Join-Path $root 'test/sequences/_snippets.yml'), "prime:`n  - action: pressKey`n    name: Enter`n")
        $path = Join-Path $root 'test/sequences/workload.fixture.yml'
        Write-SentenceFile -Path $path -Content (Get-GuestSequenceText -Component $Entry)
        $json = Get-Content -Raw -LiteralPath $path | ConvertFrom-Yaml -Ordered | ConvertTo-Json -Depth 32
        Assert-False (Test-Json -Json $json -Schema $script:SentenceSchemaJson -ErrorAction SilentlyContinue) 'the schema refuses it'
        $caught = Get-ReadFailure -Path $path -NoCache
        Assert-StringEqual -Expected $Code -Actual $caught.Exception.Data['YurunaMessageCode']
        Assert-True (Test-SequencePlannerFailure -ErrorObject $caught) 'a planner error'
    }

    It 'accepts <Case> in the schema and in the reader' -TestCases @(
        @{ Case = 'a bare sentence'; Entry = "  - step: ""press Enter""`n"; Expected = 'pressKey' }
        @{ Case = 'a sentence with every key'; Entry = "  - step: ""wait for text ready""`n    on: screen`n    timeoutSeconds: 30`n    description: Wait`n    descriptionLocalized:`n      pt-BR: Esperar`n"; Expected = 'waitForText' }
        @{ Case = 'a sentence inside retry.steps'; Entry = "  - action: retry`n    steps:`n      - step: ""press Enter""`n"; Expected = 'retry,pressKey' }
    ) {
        $root = New-SentenceRoot
        $path = Join-Path $root 'test/sequences/workload.fixture.yml'
        Write-SentenceFile -Path $path -Content (Get-GuestSequenceText -Component $Entry)
        $json = Get-Content -Raw -LiteralPath $path | ConvertFrom-Yaml -Ordered | ConvertTo-Json -Depth 32
        Assert-True (Test-Json -Json $json -Schema $script:SentenceSchemaJson -ErrorAction SilentlyContinue) 'the schema accepts it'
        $flat = @(Get-FlatAction -Step @((Read-SequenceFile -Path $path -NoCache).steps)) -join ','
        Assert-StringEqual -Expected $Expected -Actual $flat
    }

    It 'names the file and position of a rejected sentence and never its text' {
        $root = New-SentenceRoot
        [IO.File]::WriteAllText((Join-Path $root 'test/sequences/_snippets.yml'), "prime:`n  - step: ""dance wildly now""`n")
        $sentence = 'dance wildly now'
        $cases = @(
            @{ Name = 'second'; Text = (Get-GuestSequenceText -Component "  - step: ""press Enter""`n  - step: ""$sentence""`n"); Position = 'component[2]' }
            @{ Name = 'retry'; Text = (Get-GuestSequenceText -Component "  - step: ""press Enter""`n" -Workload "  - action: retry`n    steps:`n      - step: ""$sentence""`n"); Position = 'workload[1].steps[1]' }
            @{ Name = 'snippet'; Text = (Get-GuestSequenceText -Component "  - snippet: prime`n"); Position = 'component[1].snippet(prime)[1]' }
        )
        foreach ($case in $cases) {
            $path = Join-Path $root "test/sequences/workload.fixture.$($case.Name).yml"
            Write-SentenceFile -Path $path -Content $case.Text
            $caught = Get-ReadFailure -Path $path -NoCache
            Assert-StringEqual -Expected 'runner.step_phrase_no_match' -Actual $caught.Exception.Data['YurunaMessageCode']
            Assert-True $caught.Exception.Message.Contains("$path`: $($case.Position)") $caught.Exception.Message
            Assert-False $caught.Exception.Message.Contains($sentence) 'the sentence is not echoed'
        }
    }

    It 'fails a bad sentence on the cached read as a planner error' {
        $root = New-SentenceRoot
        $path = Join-Path $root 'test/sequences/workload.fixture.yml'
        Write-SentenceFile -Path $path -Content (Get-GuestSequenceText -Component "  - step: ""dance wildly now""`n")
        foreach ($read in 1, 2) {
            $caught = Get-ReadFailure -Path $path
            Assert-True (Test-SequencePlannerFailure -ErrorObject $caught) "read $read"
            Assert-StringEqual -Expected 'runner.step_phrase_no_match' -Actual $caught.Exception.Data['YurunaMessageCode'] -Because "read $read"
        }
    }

    It 'returns a phrase library and a runner configuration unchanged when read as files' {
        $root = New-SentenceRoot
        $runner = Join-Path $root 'project/ex/test/test.runner.yml'
        Write-SentenceFile -Path $runner -Content "sequences:`n  - workload.guest.ubuntu.server.26`n  - workload.guest.windows.11`n"
        foreach ($file in (Join-Path $script:SentenceRepoRoot 'test/sequences/_phrases.yml'), $runner) {
            $raw = Get-Content -Raw -LiteralPath $file | ConvertFrom-Yaml -Ordered
            $read = Read-SequenceFile -Path $file -NoCache
            Assert-StringEqual -Expected (ConvertTo-Json -InputObject $raw -Depth 32 -Compress) -Actual (ConvertTo-Json -InputObject $read -Depth 32 -Compress) -Because $file
        }
    }

    It 'reads every framework sequence without generating a step' {
        $findings = @(foreach ($file in Get-ChildItem -LiteralPath (Join-Path $script:SentenceRepoRoot 'test/sequences') -Filter '*.yml' -File) {
            $read = Read-SequenceFile -Path $file.FullName -NoCache
            if ($read -isnot [System.Collections.IDictionary] -or -not $read.Contains('steps')) { continue }
            $pending = [System.Collections.Generic.Stack[object]]::new()
            foreach ($step in @($read['steps'])) { $pending.Push($step) }
            while ($pending.Count -gt 0) {
                $step = $pending.Pop()
                if ($step -isnot [System.Collections.IDictionary]) { continue }
                if ($step.Contains('fromStep')) { "$($file.Name): '$($step['action'])' was generated from '$($step['fromStep'])'" }
                foreach ($nestedKey in 'steps', 'stepsAfterVmRestart') {
                    if ($step.Contains($nestedKey)) { foreach ($nested in @($step[$nestedKey])) { $pending.Push($nested) } }
                }
            }
        })
        Assert-NoFinding $findings 'no shipped sequence is written in sentences'
    }

    It 'finds the framework library from a folder with no framework above it' {
        $dir = Join-Path $TestDrive 'bare-sentence'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $path = Join-Path $dir 'workload.fixture.yml'
        Write-SentenceFile -Path $path -Content (Get-GuestSequenceText -Component "  - step: ""press Enter""`n")
        $steps = @((Read-SequenceFile -Path $path -NoCache).steps)
        Assert-Equal -Expected 1 -Actual $steps.Count
        Assert-StringEqual -Expected 'pressKey' -Actual $steps[0]['action']
        Assert-StringEqual -Expected 'Enter' -Actual $steps[0]['name']
    }

    It 'validates a library no sequence uses' {
        $dir = Join-Path $TestDrive 'unused-library'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $library = Join-Path $dir '_phrases.yml'
        [IO.File]::WriteAllText($library, "phrases:`n  go:`n    sentence: ""go now""`n    screen:`n      - action: fly`n")
        $caught = $null
        try { $null = Get-SequencePhraseLibrary -SequencePath $library } catch { $caught = $_ }
        Assert-NotNull $caught 'a broken library loaded'
        Assert-StringEqual -Expected 'runner.step_phrase_library_invalid' -Actual $caught.Exception.Data['YurunaMessageCode']
    }

    It 'reads on as an ordinary key' {
        $root = New-SentenceRoot
        $path = Join-Path $root 'test/sequences/document.yml'
        Write-SentenceFile -Path $path -Content "step: ""press Enter""`non: screen`n"
        $read = Read-SequenceFile -Path $path -NoCache
        Assert-True (@($read.Keys) -ccontains 'on') "keys: $(@($read.Keys) -join ', ')"
        Assert-True ($read['on'] -is [string] -and $read['on'] -ceq 'screen') "on is '$($read['on'])'"
    }

    It 'treats _phrases.yml as a library in Test-Config and Debug-TestSequence' {
        $config = Get-YurunaTestSourceText (Join-Path $script:SentenceRepoRoot 'test/Test-Config.ps1')
        $region = [regex]::Match($config, '(?s)# --- REGION: Section 9b2.*?(?=# --- REGION: Section 9b3)').Value
        Assert-True ($region -match "-notin @\([^)]*'_phrases\.yml'") 'Section 9b2 lists _phrases.yml as a library, not a sequence'
        Assert-True ($region -match 'Get-SequencePhraseLibrary') 'Section 9b2 validates each phrase library'
        $debug = Get-YurunaTestSourceText (Join-Path $script:SentenceRepoRoot 'test/Debug-TestSequence.ps1')
        Assert-True ($debug -match "-notin @\([^)]*'_phrases\.yml'") 'Debug-TestSequence does not offer _phrases as a sequence name'
    }
}
