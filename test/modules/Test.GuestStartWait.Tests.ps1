<#PSScriptInfo
.VERSION 2026.11.23
.GUID 4276cc15-f279-45c9-88c0-ffee0bd5b030
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner guest provisioning performance pester
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
    Verify the two fixed waits dropped from guest start stay dropped: the
    invariant that made the boot delay redundant, and the call shape that
    removed it.
.DESCRIPTION
    `Invoke-GuestProvisionIteration` used to sleep up to 30 s for an IP that
    only labels an operator line, then sleep a flat boot delay before the
    workload sequences run. Both are gone because every sequence that is not
    itself a start sequence already opens with a step that waits for the
    guest -- directly, or after a bounded nudge-then-pause prefix a retry
    sends blind on purpose (see `_snippets.yml`'s `firstLoginPrime`). The
    first Describe pins that invariant against the actual sequence files
    (framework and, when checked out beside it, project); the second pins
    the call shape in `Invoke-GuestProvisionIteration` itself; the third
    drives the IP probe's own resolver-call bound.
#>

if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error "Run this suite with Invoke-Pester -Path '$PSCommandPath'."
    exit 1
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:ProjectRoot = Join-Path (Split-Path -Parent $script:RepoRoot) 'yuruna-project'
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -DisableNameChecking
    Import-Module powershell-yaml -Global -Verbose:$false
    Import-Module (Join-Path $PSScriptRoot 'Test.SequenceResolve.psm1') -Force -Global -DisableNameChecking

    function Confirm-SiblingCheckout {
        param([Parameter(Mandatory)][string]$Path)
        $Path | Should -Exist -Because "the $(Split-Path -Leaf $Path) checkout has to sit beside the framework checkout; clone it there and run this suite again"
    }

    # A retry opens with a blind nudge on purpose (press Enter to redraw a
    # stale console, then a timed pause) before its real wait; that nudge
    # never depends on guest readiness, so it does not make the boot delay
    # load-bearing either. See _snippets.yml's firstLoginPrime.
    $script:SafePrefixActions = @('pressKey', 'waitForSeconds')
    $script:GuestWaitActions = @('sshWaitReady', 'loadDiskSnapshot', 'waitForText', 'waitForTextWithNudge', 'waitForAndEnter', 'passwdPrompt')
    $script:SnippetLibraryCache = @{}

    function Resolve-GuestStartWaitSnippet {
        <# .SYNOPSIS
            The named snippet's step list, from the sequence's own directory
            or the framework library, or $null when neither defines it.
        #>
        param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$SequenceDir)
        foreach ($libDir in @($SequenceDir, (Join-Path $script:RepoRoot 'test/sequences'))) {
            $libPath = Join-Path $libDir '_snippets.yml'
            if (-not (Test-Path -LiteralPath $libPath)) { continue }
            if (-not $script:SnippetLibraryCache.ContainsKey($libPath)) {
                $script:SnippetLibraryCache[$libPath] = Get-Content -Raw -LiteralPath $libPath | ConvertFrom-Yaml -Ordered
            }
            $lib = $script:SnippetLibraryCache[$libPath]
            if ($lib.Contains($Name)) { return @($lib[$Name]) }
        }
        return $null
    }

    function Confirm-GuestSequenceOpensWithWait {
        <# .SYNOPSIS
            $null when $Path's opening already waits for the guest (or has no
            opening to wait in); otherwise a one-line finding naming the file
            and what it opens with instead.
        .DESCRIPTION
            Scoped to sequences that are not start sequences: start.* files
            run before the removed boot delay, through New-VM.Resource's own
            Wait-VMRunning poll, so they are not what made the delay
            redundant. Get-CyclePlanSequencesForGuest draws the same line by
            the same test (`$s -match '^start\.'`), not by a file's own
            component/workload YAML shape -- both file kinds carry that
            shape; only the name says which role a file plays.
        #>
        param([Parameter(Mandatory)][string]$Path)
        $parsed = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Yaml -Ordered
        if ($parsed -isnot [System.Collections.IDictionary] -or -not $parsed.Contains('resource')) { return $null }
        if ((Split-Path -Leaf $Path) -match '^start\.') { return $null }
        $opening = @()
        if ($parsed.Contains('component') -and $parsed['component']) { $opening = @($parsed['component']) }
        elseif ($parsed.Contains('workload') -and $parsed['workload']) { $opening = @($parsed['workload']) }
        if ($opening.Count -eq 0) { return $null }
        $first = $opening[0]
        $steps = @($first)
        if ([string]$first['action'] -eq 'retry') { $steps = @($first['steps'] | Where-Object { $null -ne $_ }) }
        $dir = Split-Path -Parent $Path
        $index = 0
        while ($index -lt $steps.Count) {
            $step = $steps[$index]
            if ($step.Contains('snippet')) {
                $name = [string]$step['snippet']
                $resolved = Resolve-GuestStartWaitSnippet -Name $name -SequenceDir $dir
                if (-not $resolved) { return "$Path references unknown snippet '$name'" }
                $tail = if ($index + 1 -le $steps.Count - 1) { @($steps[($index + 1)..($steps.Count - 1)]) } else { @() }
                $steps = @($resolved) + $tail
                continue
            }
            if ($step.Contains('step')) {
                # A sentence is judged by the steps it becomes. The loop restarts
                # at the first of them: the entries before this one were prefix
                # steps already passed, and keeping $index would skip the first
                # generated step of a sentence that is not the first entry.
                $surface = if ($step.Contains('on')) { [string]$step['on'] } elseif ($parsed.Contains('defaultSurface')) { [string]$parsed['defaultSurface'] } else { 'screen' }
                $generated = @()
                try {
                    $generated = @(Resolve-StepPhrase -Sentence ([string]$step['step']) -Surface $surface -Library (Get-SequencePhraseLibrary -SequencePath $Path))
                } catch {
                    return "$Path opens with a sentence that does not resolve"
                }
                if ($generated.Count -eq 0) { return "$Path opens with a sentence that does not resolve" }
                $tail = if ($index + 1 -le $steps.Count - 1) { @($steps[($index + 1)..($steps.Count - 1)]) } else { @() }
                $steps = @($generated) + $tail
                $index = 0
                continue
            }
            $action = [string]$step['action']
            if ($script:GuestWaitActions -contains $action) { return $null }
            if ($script:SafePrefixActions -contains $action) { $index++; continue }
            return "$Path opens with '$action', not a guest wait"
        }
        return "$Path's opening never reaches a guest wait"
    }
}

Describe 'every workload sequence opens by waiting for the guest' {
    It 'frames every framework sequence this way' {
        $findings = @()
        foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'test/sequences') -Filter '*.yml' -File)) {
            $finding = Confirm-GuestSequenceOpensWithWait -Path $file.FullName
            if ($finding) { $findings += $finding }
        }
        Assert-NoFinding $findings 'the boot delay is redundant only because every sequence that is not a start sequence already waits for the guest before doing anything else'
    }
    It 'frames every project sequence this way, when the sibling checkout is present' {
        Confirm-SiblingCheckout -Path $script:ProjectRoot
        $findings = @()
        foreach ($file in (Get-ChildItem -LiteralPath $script:ProjectRoot -Filter '*.yml' -Recurse -File | Where-Object { $_.Directory.Name -eq 'test' })) {
            $finding = Confirm-GuestSequenceOpensWithWait -Path $file.FullName
            if ($finding) { $findings += $finding }
        }
        Assert-NoFinding $findings 'a project sequence that starts with a typing step would make the boot delay load-bearing there'
    }
}

Describe 'the provisioning iteration does not sleep on a running guest' {
    BeforeAll {
        $script:StartWaitAst = Get-YurunaTestFunctionAst -Path (Join-Path $PSScriptRoot 'Test.RunnerInnerLoop.psm1') -Name 'Invoke-GuestProvisionIteration'
    }
    It 'binds the one-probe Wait-VMIp call' {
        $calls = @($script:StartWaitAst.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Wait-VMIp' }, $true))
        $calls.Count | Should -Be 1
        (Get-YurunaTestCommandArgumentAst -Command $calls[0] -Name 'TimeoutSeconds').Extent.Text | Should -Be '1'
        (Get-YurunaTestCommandArgumentAst -Command $calls[0] -Name 'StableForSeconds').Extent.Text | Should -Be '0'
    }
    It 'binds no Wait-VMRunning call to a boot delay' {
        $calls = @($script:StartWaitAst.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Wait-VMRunning' }, $true))
        $calls.Count | Should -BeGreaterThan 0
        foreach ($call in $calls) {
            Get-YurunaTestCommandArgumentAst -Command $call -Name 'BootDelaySeconds' | Should -BeNullOrEmpty
        }
    }
}

Describe 'Invoke-WaitVmIp calls its resolver only as often as the one-probe arguments allow' {
    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.HostProvision.psm1') -Force -DisableNameChecking
    }
    It 'calls the resolver once when the address answers, and at most twice when it does not' {
        $state = [pscustomobject]@{ Calls = 0 }
        $answers = { $state.Calls++; '192.0.2.9' }.GetNewClosure()
        $answered = Invoke-WaitVmIp -VMName 'vm-fixture' -TimeoutSeconds 1 -PollSeconds 1 -StableForSeconds 0 -ResolveVmIp $answers
        $answered | Should -Be '192.0.2.9'
        $state.Calls | Should -Be 1

        $state.Calls = 0
        $silent = { $state.Calls++; '' }.GetNewClosure()
        $unanswered = Invoke-WaitVmIp -VMName 'vm-fixture' -TimeoutSeconds 1 -PollSeconds 1 -StableForSeconds 0 -ResolveVmIp $silent
        $unanswered | Should -BeNullOrEmpty
        $state.Calls | Should -BeLessOrEqual 2
    }
}

Describe 'an opening sentence is judged by the steps it becomes' {
    BeforeAll {
        $script:OpeningCase = 0
        function Write-OpeningSequence {
            <#
            .SYNOPSIS
                Write a guest sequence named workload.fixture.yml into a fresh folder; return its path.
            #>
            [CmdletBinding()]
            [OutputType([string])]
            param([Parameter(Mandatory)][string]$Component)
            $script:OpeningCase++
            $dir = Join-Path $TestDrive ('opening{0:D2}' -f $script:OpeningCase)
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $path = Join-Path $dir 'workload.fixture.yml'
            [IO.File]::WriteAllText($path, "description: t`nkeystrokeMechanism: gui`nresource:`n  ubuntu.server.26: []`ncomponent:`n$Component")
            return $path
        }
    }

    It 'accepts an opening sentence that expands to a guest wait' {
        $login = Write-OpeningSequence -Component "  - step: ""login `${username} with password `${ext:authentication.GetPassword(`${username})}""`n"
        Assert-Null (Confirm-GuestSequenceOpensWithWait -Path $login) 'a login sentence opens with passwdPrompt'
        $retry = Write-OpeningSequence -Component "  - action: retry`n    steps:`n      - step: ""press Enter""`n      - step: ""wait 2 seconds""`n      - step: ""wait for text login:""`n"
        Assert-Null (Confirm-GuestSequenceOpensWithWait -Path $retry) 'a nudge, a pause and a wait sentence open with a guest wait'
    }

    It 'reports an opening sentence that does not wait' {
        $typing = Write-OpeningSequence -Component "  - step: ""type ls and press Enter""`n"
        $retry = Write-OpeningSequence -Component "  - action: retry`n    steps:`n      - action: pressKey`n        name: Enter`n      - step: ""type ls and press Enter""`n      - action: waitForText`n        pattern: ""x""`n"
        foreach ($path in $typing, $retry) {
            $finding = Confirm-GuestSequenceOpensWithWait -Path $path
            Assert-NotNull $finding "$path was accepted"
            Assert-True $finding.EndsWith("opens with 'inputTextAndEnter', not a guest wait") "finding: $finding"
        }
    }
}
