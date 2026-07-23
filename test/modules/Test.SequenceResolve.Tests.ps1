<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42b9e1c4-7a3d-4f52-8e16-9c4d2a7b3e58
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

    Pester 4 style (top-level Assert-* helpers used inside It): the repo's
    *.Tests.ps1 share this idiom -- under Pester 5 the Discovery/Run scope split
    hides top-level functions from It blocks. Run with Pester 4.10.1.
#>

$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.SequenceResolve.psm1'
Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Throw {
    param([scriptblock]$Script, [string]$Match = '', [string]$Because = '')
    $threw = $false
    try { & $Script } catch {
        $threw = $true
        if ($Match -and ($_.Exception.Message -notmatch $Match)) {
            throw "Threw, but message '$($_.Exception.Message)' did not match '$Match'. $Because"
        }
    }
    if (-not $threw) { throw "Expected a throw. $Because" }
}

# Unqualified file-scope fixtures. An It body resolves an unqualified file-level
# variable but not a $script:-qualified one: the run pass re-enters the file in a
# fresh scope, so $script: writes land in a script scope the It bodies never see
# and the value would arrive as $null -- silently skipping every yaml case and
# handing New-SnippetTestDir a null root.
$yamlAvailable = [bool](Get-Module -ListAvailable -Name powershell-yaml)
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'yuruna-snippet-tests'

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

Describe 'Test.SequenceResolve step-snippet expansion' {

    It 'splices a top-level snippet reference into its steps' {
        if (-not $yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
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
        if (-not $yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
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
        if (-not $yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
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
        if (-not $yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
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
        if (-not $yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
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
        if (-not $yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
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
        if (-not $yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
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
        if (-not $yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
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
        if (-not $yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
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
        if (-not $yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
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
        if (-not $yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
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
        if (-not $yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
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
        if (-not $yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
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
        if (-not $yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
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
        if (-not $yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
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
