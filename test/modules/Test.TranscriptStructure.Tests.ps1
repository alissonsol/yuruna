<#PSScriptInfo
.VERSION 2026.09.08
.GUID 42e7a1d5-3b90-4c68-8f24-05c6b93e1a7d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization transcript outline structured pester
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
    Keep the transcript's structure from depending on the words it prints.
.DESCRIPTION
    A cycle transcript is tens of kilobytes inside one <pre>, and the step
    rules are its only landmarks. Those landmarks were produced by one module
    writing a line of dashes and recovered by another matching a regex against
    the rendered text -- two copies of one format, in different files, with
    nothing holding them together.

    That drifts, and it drifts silently in the worst available way. The
    transcript still renders; it simply stops having headings. A sighted reader
    scrolls further and a screen-reader user loses every landmark, and no gate
    reports anything, because nothing failed.

    Two things fix it, and they are different in kind. The shape now has one
    definition, so a builder and a recognizer cannot disagree. And the boundary
    is emitted as data on the event stream the aggregator already ships off the
    host, so a consumer building an outline never reads prose at all -- the
    rendered rule goes back to being what it always was, a line for a person.

    Run: Invoke-Pester -Path test/modules/Test.TranscriptStructure.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:LogModule = Join-Path $script:RepoRoot 'automation/Yuruna.Log.psm1'
$script:Orchestrator = Join-Path $script:RepoRoot 'test/modules/Test.Orchestrator.psm1'

Import-Module $script:LogModule -Force -Global -DisableNameChecking

# The cycle-folder anchor is a global by design: Start-LogFile sets it and the
# log writers read it. A test that redirects the writer at a sandbox has to
# touch it, so the two accesses live here rather than being repeated inline.
function Get-CycleFolderAnchor {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Reads the cycle-folder anchor the log module defines as a global.')]
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return [string]$global:__YurunaCycleFolder
}

function Set-CycleFolderAnchor {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Points the log writer at a sandbox for the duration of one test.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Sets an in-process variable that the same test restores in its finally block.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$Path)
    $global:__YurunaCycleFolder = $Path
}
}

Describe 'the transcript outline has one definition' {

    It 'recognizes exactly what the builder produces' {
        # The property that stops the drift: whatever shape the rule takes, the
        # thing that reads it is built from the same definition.
        $findings = @()
        $cases = @(
            @{ Index = 1;  Total = 1;   Name = 'workload.guest.example'; Outcome = '' }
            @{ Index = 2;  Total = 11;  Name = 'workload.guest.example'; Outcome = 'PASS' }
            @{ Index = 11; Total = 11;  Name = 'host.action.thing';      Outcome = 'FAIL' }
            @{ Index = 7;  Total = 120; Name = 'a.name.with.dots-and-dashes'; Outcome = 'SKIPPED' }
        )
        foreach ($c in $cases) {
            $line = New-YurunaStepRuleLine -Index $c.Index -Total $c.Total -Name $c.Name -Outcome $c.Outcome
            if (-not (Test-YurunaStepRuleLine -Text $line)) {
                $findings += "the recognizer does not see its own builder's output: '$line'"
            }
        }
        Assert-NoFinding $findings 'a step rule would render without becoming a heading'
    }

    It 'does not mistake ordinary output for a landmark' {
        # A transcript carries arbitrary tool output, and a line that merely
        # mentions a counter is not a section boundary. Promoting one would put
        # a false landmark in the outline, which is worse than a missing one:
        # a reader jumps to it and lands nowhere.
        $findings = @()
        foreach ($line in @(
                'ordinary output that happens to mention [2/11]',
                '----- not a step rule -----',
                '[2/11] no dashes at all',
                'note',
                '',
                '--- [2/11] trailing text after the dashes --- and more')) {
            if (Test-YurunaStepRuleLine -Text $line) { $findings += "promoted a non-boundary: '$line'" }
        }
        Assert-NoFinding $findings 'ordinary output is being turned into an outline entry'
    }

    It 'builds its rules through the shared definition, not a literal' {
        # The recognizer can only stay in step with lines the builder made.
        $text = [IO.File]::ReadAllText($script:Orchestrator)
        $literals = [regex]::Matches($text, '(?m)^\s*Write-OrchestratorLine\s+"-{3,}')
        Assert-True ($literals.Count -le 2) `
            "the orchestrator writes $($literals.Count) step rules as literals; each one is a copy of the format"
    }

    It 'derives the heading from the shared recognizer' {
        $text = [IO.File]::ReadAllText($script:LogModule)
        Assert-True ($text -match 'Test-YurunaStepRuleLine -Text \$Text') `
            'the tee still carries its own copy of the step-rule pattern'
        $addFn = [regex]::Match($text, '(?s)function Add-YurunaLogLine \{.*?\n\}')
        Assert-True $addFn.Success 'the tee has no Add-YurunaLogLine'
        Assert-True ($addFn.Value -notmatch "\^-\+ \\\[") `
            'the tee still matches the rule shape inline rather than through the definition'
    }
}

Describe 'a step boundary is available as data, not only as a line' {


    It 'emits a structured event at both ends of a step' {
        $text = [IO.File]::ReadAllText($script:Orchestrator)
        Assert-True ($text -match "Write-CycleStepEvent -Phase 'start'") 'no structured event marks a step starting'
        Assert-True ($text -match "Write-CycleStepEvent -Phase 'end'") 'no structured event marks a step ending'
    }

    It 'carries the outcome as a stable token, not the printed word' {
        # PASS and FAIL are what a reader sees. A consumer matching on them
        # would be reading a rendered value, which is the shape this exists to
        # stop -- so the event carries a lower-case token instead.
        $fn = [regex]::Match([IO.File]::ReadAllText($script:Orchestrator),
            '(?s)function Write-CycleStepEvent \{.*?\n\}')
        Assert-True $fn.Success 'the orchestrator has no Write-CycleStepEvent'
        Assert-True ($fn.Value -match 'ToLowerInvariant') `
            'the outcome is recorded as the word the transcript prints'
        # Whole literals, not composed at run time: a code assembled from a
        # fragment cannot be grepped for, and the registry cannot verify that
        # this file carries the code it claims to.
        Assert-True ($fn.Value -match "'step\.start'") 'the opening code is not written out whole'
        Assert-True ($fn.Value -match "'step\.end'") 'the closing code is not written out whole'
    }

    It 'never fails a cycle to record a boundary' {
        # Telemetry, not a verdict. A cycle that could not append a line must
        # still run, and a module set without the writer must not throw.
        $fn = [regex]::Match([IO.File]::ReadAllText($script:Orchestrator),
            '(?s)function Write-CycleStepEvent \{.*?\n\}')
        Assert-True ($fn.Value -match 'Get-Command Write-CycleNdjsonEvent -ErrorAction SilentlyContinue') `
            'the event writer is called without checking that it exists'
        Assert-True ($fn.Value -match 'try \{.*\} catch') `
            'a failed telemetry append could take the cycle down'
    }

    It 'writes an event a consumer can actually read back' {
        # The cycle-folder anchor is a global by design in Test.Log, and this
        # test has to point the writer at a sandbox rather than a real cycle.

        # Run the real writer against a temp cycle folder and parse what lands.
        Import-Module (Join-Path $here 'Test.Log.psm1') -Force -Global -DisableNameChecking
        Import-Module $script:Orchestrator -Force -Global -DisableNameChecking

        $sandbox = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-steps-" + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $sandbox -Force
        $priorFolder = Get-CycleFolderAnchor
        try {
            Set-CycleFolderAnchor -Path $sandbox
            Write-CycleStepEvent -Phase 'start' -Index 2 -Total 11 -Name 'workload.guest.example' -Kind 'guest'
            Write-CycleStepEvent -Phase 'end' -Index 2 -Total 11 -Name 'workload.guest.example' -Kind 'guest' -Outcome 'FAIL'

            $path = Join-Path $sandbox 'cycle.events.ndjson'
            Assert-True (Test-Path -LiteralPath $path -PathType Leaf) 'no event file was written'
            $records = @(
                foreach ($line in [IO.File]::ReadAllLines($path)) {
                    if ($line.Trim()) { ConvertFrom-Json -InputObject $line }
                })
            $steps = @($records | Where-Object { "$($_.event)" -like 'step.*' })
            Assert-Equal -Expected 2 -Actual $steps.Count 'both boundaries should be on the stream'
            Assert-StringEqual -Expected 'step.start' -Actual ([string]$steps[0].event) 'the opening event is misnamed'
            Assert-StringEqual -Expected 'step.end' -Actual ([string]$steps[1].event) 'the closing event is misnamed'
            Assert-Equal -Expected 2 -Actual ([int]$steps[0].index) 'the index did not survive'
            Assert-Equal -Expected 11 -Actual ([int]$steps[0].total) 'the total did not survive'
            Assert-StringEqual -Expected 'workload.guest.example' -Actual ([string]$steps[1].name) 'the name did not survive'
            Assert-StringEqual -Expected 'fail' -Actual ([string]$steps[1].outcome) `
                'the outcome should be a stable token, lower-case, not the printed word'
        } finally {
            Set-CycleFolderAnchor -Path $priorFolder
            Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
