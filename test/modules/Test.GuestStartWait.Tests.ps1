<#PSScriptInfo
.VERSION 2026.10.14
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
