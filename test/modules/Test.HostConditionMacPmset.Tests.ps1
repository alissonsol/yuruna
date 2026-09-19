<#PSScriptInfo
.VERSION 2026.09.18
.GUID 421185fc-300c-4e42-9cb0-2d84ae9be9cc
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

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
$macModulePath = Join-Path $here 'Test.HostCondition.Mac.psm1'
$macModule = Import-Module $macModulePath -Force -PassThru -DisableNameChecking

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

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
$script:freshLaptop  = Get-CompliantGuardBlock -Header 'Battery Power:' -Omit @('disablesleep')
# Fully compliant, both power blocks.
$script:compliant    = (Get-CompliantGuardBlock -Header 'Battery Power:') + (Get-CompliantGuardBlock -Header 'AC Power:')

function Get-SleepPendingKey {
    param([string[]]$PmsetCustom)
    $pending = & $macModule { param($p) Get-MacPmsetGuardPending -PmsetCustom $p -Guard (Get-MacSleepGuardList) } $PmsetCustom
    return @(@($pending) | ForEach-Object { $_.Key })
}
function Get-KeyValue {
    param([string[]]$PmsetCustom, [string]$Key)
    return @(& $macModule { param($p, $k) Get-MacPmsetKeyValue -PmsetCustom $p -Key $k } $PmsetCustom $Key)
}

# A Mac that has already had system sleep disabled and still sleeps its disk.
# Every value here is one an operator would read as healthy except the one that
# matters, which is why the gate and the apply path have to agree on it.
$script:diskSleepOnly = @(
    'Battery Power:',
    ' sleep                0',
    ' disksleep            10',
    ' displaysleep         0',
    '',
    'AC Power:',
    ' sleep                0',
    ' disksleep            10',
    ' displaysleep         0'
)

}

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
        Assert-Equal -Expected 'disablesleep' -Actual ((Get-PendingKey -PmsetCustom $script:freshLaptop) -join ',')
    }
    It 'writes disablesleep on a host that drifted back to 0' {
        $drifted = @(' disablesleep         0') + $script:freshLaptop
        Assert-True ((Get-PendingKey -PmsetCustom $drifted) -contains 'disablesleep') `
            'a listed-but-wrong value is drift and must be re-applied'
    }
    It 'asks for nothing on a fully compliant host' {
        Assert-Equal -Expected '' -Actual ((Get-PendingKey -PmsetCustom $script:compliant) -join ',') `
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
        $mdm = @($script:compliant -replace '^(\s*powernap\s+)0$', '${1}1')
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
        $pending = & $macModule { param($p, $g) Get-MacPmsetGuardPending -PmsetCustom $p -Guard $g } $script:compliant $custom
        Assert-Equal -Expected 'hibernatemode' -Actual ((@($pending) | ForEach-Object { $_.Key }) -join ',')
    }
}

Describe 'Get-MacPmsetKeyValue' {
    It 'reports the value every power block holds for a key' {
        # One value per block, in block order. A caller that sees only the first
        # cannot tell a host that is compliant everywhere from one that is
        # compliant on battery and blanks the display the moment it is plugged in.
        Assert-Equal -Expected '10,0' -Actual ((Get-KeyValue -PmsetCustom @(
            'Battery Power:', ' disksleep            10',
            'AC Power:',      ' disksleep            0') -Key 'disksleep') -join ',')
    }
    It 'does not read disksleep or displaysleep as sleep' {
        # Three keys end in "sleep" and hold unrelated values; matching loosely
        # would drive a decision about one of them from another's number.
        # Two blocks, so two zeroes -- and neither of the 10s that disksleep
        # holds in the same fixture.
        Assert-Equal -Expected '0,0' -Actual ((Get-KeyValue -PmsetCustom $script:diskSleepOnly -Key 'sleep') -join ',') `
            'only the sleep lines may answer for sleep'
    }
    It 'returns nothing for a key this macOS does not list' {
        Assert-Equal -Expected 0 -Actual (Get-KeyValue -PmsetCustom $script:diskSleepOnly -Key 'lowpowermode').Count
    }
}

Describe 'Get-MacSleepGuardList' {
    It 'drives sleep and disksleep to 0' {
        $sleepGuards = @(& $macModule { Get-MacSleepGuardList })
        Assert-Equal -Expected 'sleep,disksleep' -Actual (($sleepGuards | ForEach-Object { $_.Key }) -join ',')
        foreach ($g in $sleepGuards) { Assert-Equal -Expected 0 -Actual $g.Want "guard '$($g.Key)' must be driven to 0 (Never)" }
    }
    It 'writes disksleep on a host whose system sleep is already 0' {
        # The regression this list exists for: one decision read from `sleep`
        # reported "already Never" and wrote nothing, on the exact host the gate
        # then refused -- a loop that re-running the setup script cannot break.
        Assert-Equal -Expected 'disksleep' -Actual ((Get-SleepPendingKey -PmsetCustom $script:diskSleepOnly) -join ',')
    }
    It 'asks for nothing when both keys are already 0' {
        $bothOff = @($script:diskSleepOnly -replace '^(\s*disksleep\s+)10$', '${1}0')
        Assert-Equal -Expected '' -Actual ((Get-SleepPendingKey -PmsetCustom $bothOff) -join ',') `
            'a compliant host must not be charged a sudo prompt'
    }
    It 'catches disksleep left behind in one power block' {
        $batteryOnly = @(
            'Battery Power:', ' sleep                0', ' disksleep            10',
            'AC Power:',      ' sleep                0', ' disksleep            0')
        Assert-Equal -Expected 'disksleep' -Actual ((Get-SleepPendingKey -PmsetCustom $batteryOnly) -join ',') `
            'the writes go out with -a, so one drifted block is still drift'
    }
}

Describe 'Set-MacHostConditionSet wiring' {
    It 'decides the sleep writes from the shared sleep guard list' {
        # Both halves have to read the same list, or the apply path can call a
        # host ready that the gate refuses. Pinned in the AST because neither
        # half can be exercised off a Mac.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($macModulePath, [ref]$null, [ref]$null)
        foreach ($fnName in @('Set-MacHostConditionSet', 'Get-MacScreenLockIssue')) {
            $fn = $ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $n.Name -eq $fnName }, $true)
            Assert-Equal -Expected 1 -Actual @($fn).Count "$fnName must be defined once"
            $calls = $fn[0].Body.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.CommandAst] -and
                $n.GetCommandName() -eq 'Get-MacSleepGuardList' }, $true)
            Assert-True (@($calls).Count -ge 1) "$fnName must read the sleep guards from Get-MacSleepGuardList"
        }
    }
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
