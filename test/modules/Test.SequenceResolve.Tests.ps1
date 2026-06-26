<#PSScriptInfo
.VERSION 2026.06.26
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

$script:yamlAvailable = [bool](Get-Module -ListAvailable -Name powershell-yaml)
$script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'yuruna-snippet-tests'
$script:caseSeq = 0

function New-SnippetTestDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test temp dir.')]
    [CmdletBinding()]
    param()
    # Returns a fresh, empty test root unique to this case (so the path-keyed
    # snippet-library cache never serves a stale parse from a prior case).
    $script:caseSeq++
    $dir = Join-Path $script:tmpRoot ("case{0:D3}" -f $script:caseSeq)
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
        Assert-Equal 3 (@($seq.steps).Count) 'snippet (2 steps) + 1 inline = 3'
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
        Assert-Equal 2 $inner.Count 'snippet (1) + passwdPrompt (1)'
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
        # Framework library + sequence under test/sequences/gui/.
        Write-TextFile (Join-Path $root 'test/sequences/gui/_snippets.yml') @"
greet:
  - action: inputText
    text: "framework"
"@
        # Project library overriding 'greet' under project/ex/test/gui/.
        Write-TextFile (Join-Path $root 'project/ex/test/gui/_snippets.yml') @"
greet:
  - action: inputText
    text: "project"
"@
        $seqPath = Join-Path $root 'test/sequences/gui/seq.yml'
        Write-TextFile $seqPath @"
description: t
steps:
  - snippet: greet
"@
        $seq = Read-SequenceFile -Path $seqPath -NoCache
        Assert-Equal 1 (@($seq.steps).Count)
        Assert-Equal 'project' $seq.steps[0].text 'project library wins over framework'
    }

    It 'throws when two project libraries define the same snippet name' {
        if (-not $script:yamlAvailable) { Set-ItResult -Skipped -Because 'powershell-yaml not installed'; return }
        $root = New-SnippetTestDir
        Write-TextFile (Join-Path $root 'project/a/test/gui/_snippets.yml') @"
dup:
  - action: pressKey
    name: Enter
"@
        Write-TextFile (Join-Path $root 'project/b/test/gui/_snippets.yml') @"
dup:
  - action: pressKey
    name: Enter
"@
        $seqPath = Join-Path $root 'project/a/test/gui/seq.yml'
        Write-TextFile $seqPath @"
description: t
steps:
  - snippet: dup
"@
        Assert-Throw { Read-SequenceFile -Path $seqPath -NoCache } 'two project libraries'
    }
}
