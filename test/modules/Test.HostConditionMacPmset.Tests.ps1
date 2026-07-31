<#PSScriptInfo
.VERSION 2026.07.31
.GUID 42d7f083-96ba-4c21-8e5d-3a49c7f1e605
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test macos pmset sleep pester
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
    Pester coverage for the macOS pmset guard rule in Test.HostCondition.Mac.psm1:
    Get-MacPmsetGuardList (the data) and Get-MacPmsetGuardPending (the decision
    about which guards still need `sudo pmset -a <key> <value>`).
.DESCRIPTION
    The decision is a pure function of `pmset -g custom` output precisely so it
    can be tested here, off a Mac. The cases below pin the two halves of the
    absence rule, which pull in opposite directions:

      * a key macOS renamed or dropped must NOT be written -- otherwise every
        host prep burns a sudo prompt on a name pmset no longer knows;
      * `disablesleep` must be written even when absent -- macOS omits it until
        something writes it, so "not listed" cannot be read as "already 1", and
        a MacBook left at 0 suspends the whole cycle the moment its lid closes.

    Also asserts that Set-MacHostConditionSet routes through the helper, so the
    absence rule cannot be replaced by an inline loop that treats a missing key
    as compliant.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -File test/modules/Test.HostConditionMacPmset.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
$macModulePath = Join-Path $here 'Test.HostCondition.Mac.psm1'
$macModule = Import-Module $macModulePath -Force -PassThru -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

# Get-MacPmsetGuardList / Get-MacPmsetGuardPending are module-private (the
# facade exports only the Set/Assert surface), so reach them in module scope.
function Get-Guard {
    return @(& $macModule { Get-MacPmsetGuardList })
}
function Get-PendingKey {
    param([string[]]$PmsetCustom)
    $pending = & $macModule { param($p) Get-MacPmsetGuardPending -PmsetCustom $p } $PmsetCustom
    return @(@($pending) | ForEach-Object { $_.Key })
}

# Fixtures at FILE scope: a Describe body runs during discovery and its
# variables are gone before any It executes.
$guards = Get-Guard

# One `pmset -g custom` block with every guard at its wanted value. Built from
# the guard list itself so a new guard doesn't silently make these fixtures
# describe a non-compliant host.
function Get-CompliantGuardBlock {
    param([string]$Header, [string[]]$Omit = @())
    $lines = @("$Header")
    foreach ($g in $guards) {
        if ($Omit -contains $g.Key) { continue }
        $lines += (' {0,-20} {1}' -f $g.Key, $g.Want)
    }
    return $lines
}

# A laptop that has never had disablesleep written: macOS does not print the
# key at all. This is the host the guard exists for.
$freshLaptop  = Get-CompliantGuardBlock -Header 'Battery Power:' -Omit @('disablesleep')
# Fully compliant, both power blocks.
$compliant    = (Get-CompliantGuardBlock -Header 'Battery Power:') + (Get-CompliantGuardBlock -Header 'AC Power:')

Describe 'Get-MacPmsetGuardList' {
    It 'gives every guard a key and a wanted value' {
        Assert-True ($guards.Count -gt 0) 'the guard list must not be empty'
        foreach ($g in $guards) {
            Assert-True (-not [string]::IsNullOrWhiteSpace([string]$g.Key)) 'a guard with no Key cannot be written or verified'
            Assert-True ($null -ne $g.Want) "guard '$($g.Key)' has no wanted value"
        }
    }
    It 'names each key once' {
        $keys = @($guards | ForEach-Object { $_.Key })
        Assert-Equal -Expected $keys.Count -Actual (@($keys | Sort-Object -Unique).Count) `
            'a duplicated key means two rows disagree about the wanted value'
    }
    It 'keeps disablesleep at 1 and marks it AlwaysApply' {
        # The clamshell guard: with disablesleep 0 a MacBook suspends when its
        # lid closes, taking every running guest with it.
        $lid = @($guards | Where-Object { $_.Key -eq 'disablesleep' })
        Assert-Equal -Expected 1 -Actual $lid.Count 'disablesleep must be one of the guards'
        Assert-Equal -Expected 1 -Actual $lid[0].Want 'disablesleep must be driven to 1'
        Assert-True ($lid[0].AlwaysApply -eq $true) 'disablesleep absence proves nothing, so it must be force-written'
    }
}

Describe 'Get-MacPmsetGuardPending' {
    It 'writes disablesleep on a host that does not list it' {
        # The regression this rule exists for: reading "not listed" as "already
        # 1" left the write undone on exactly the hosts that needed it.
        Assert-Equal -Expected 'disablesleep' -Actual ((Get-PendingKey -PmsetCustom $freshLaptop) -join ',')
    }
    It 'writes disablesleep on a host that drifted back to 0' {
        $drifted = @(' disablesleep         0') + $freshLaptop
        Assert-True ((Get-PendingKey -PmsetCustom $drifted) -contains 'disablesleep') `
            'a listed-but-wrong value is drift and must be re-applied'
    }
    It 'asks for nothing on a fully compliant host' {
        Assert-Equal -Expected '' -Actual ((Get-PendingKey -PmsetCustom $compliant) -join ',') `
            'a compliant host must not be charged a sudo prompt'
    }
    It 'leaves a key this macOS release no longer surfaces alone' {
        # Sonoma split standbydelay into standbydelaylow/high; writing the old
        # name achieves nothing, so absence of a non-AlwaysApply key is not drift.
        $renamed = (Get-CompliantGuardBlock -Header 'Battery Power:' -Omit @('standbydelay')) +
                   (Get-CompliantGuardBlock -Header 'AC Power:'      -Omit @('standbydelay'))
        Assert-Equal -Expected '' -Actual ((Get-PendingKey -PmsetCustom $renamed) -join ',')
    }
    It 'catches a single guard re-enabled underneath us' {
        $mdm = @($compliant -replace '^(\s*powernap\s+)0$', '${1}1')
        Assert-Equal -Expected 'powernap' -Actual ((Get-PendingKey -PmsetCustom $mdm) -join ',')
    }
    It 'catches a value that is wrong in only one power block' {
        # The writes go out with `-a`, so right-on-battery / wrong-on-AC is still
        # drift -- checking only the first block would call this host compliant.
        $acOnly = (Get-CompliantGuardBlock -Header 'Battery Power:') +
                  (@(Get-CompliantGuardBlock -Header 'AC Power:') -replace '^(\s*standby\s+)0$', '${1}1')
        Assert-True ((Get-PendingKey -PmsetCustom $acOnly) -contains 'standby') `
            'a mismatch in the AC block must be reported'
    }
    It 'falls back to the force-written guards when pmset returns nothing' {
        # pmset missing or failing: guessing compliance for keys we cannot read
        # would be the same silent skip, so only the AlwaysApply keys go out.
        $expected = @($guards | Where-Object { $_.AlwaysApply } | ForEach-Object { $_.Key }) -join ','
        Assert-Equal -Expected $expected -Actual ((Get-PendingKey -PmsetCustom @()) -join ',')
    }
    It 'evaluates a caller-supplied guard set' {
        $custom = @(@{ Key = 'hibernatemode'; Want = 25 })
        $pending = & $macModule { param($p, $g) Get-MacPmsetGuardPending -PmsetCustom $p -Guard $g } $compliant $custom
        Assert-Equal -Expected 'hibernatemode' -Actual ((@($pending) | ForEach-Object { $_.Key }) -join ',')
    }
}

Describe 'Set-MacHostConditionSet wiring' {
    It 'decides the pmset writes through Get-MacPmsetGuardPending' {
        # Pins the absence rule to the apply path: an inline "no listed mismatch
        # -> skip" loop here is what left disablesleep unwritten.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($macModulePath, [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $n.Name -eq 'Set-MacHostConditionSet' }, $true)
        Assert-Equal -Expected 1 -Actual @($fn).Count 'Set-MacHostConditionSet must be defined once'
        $calls = $fn[0].Body.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Get-MacPmsetGuardPending' }, $true)
        Assert-True (@($calls).Count -ge 1) 'Set-MacHostConditionSet must call Get-MacPmsetGuardPending'
    }
}
