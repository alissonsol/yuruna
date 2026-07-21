<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42e6a1d3-9b74-4c28-8f10-6a5b4c3d2e1f
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence engine registry pester
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
    Guards two engine seams in Invoke-Sequence.psm1 that used to hard-code
    verb-name lists, plus the cycle-restart control-flow marker's carrier.
.DESCRIPTION
    UsesWaitSignals / CapturesOwnFailureScreenshot: the sequence engine reads
    these per-verb registry flags instead of literal verb lists to decide
    (a) whether to append the matched-failurePattern annotation and (b) whether
    to skip the generic post-failure screenshot. This test pins the flag values
    to the exact verb sets the two former literal lists encoded, so a new verb
    that opts in/out cannot silently change engine behavior for the existing set.

    YurunaCycleRestart carrier: the mid-cycle abort marker must travel BOTH as an
    Exception.Data tag (survives a rewrap that strips the message) AND as the
    message prefix (fallback for an untagged throw), so the sequence catch
    re-throws it instead of counting a cycle-restart as a crash.

    Throw-based assertions so the file runs under OS-bundled Pester 3.4 / 4 / 5+.
#>

$here       = Split-Path -Parent $PSCommandPath
$handlerPsm = Join-Path $here 'Test.SequenceHandler.psm1'
$enginePsm  = Join-Path $here 'Invoke-Sequence.psm1'

# Loading the handler module registers every built-in verb (it imports
# Test.SequenceAction and calls Register-SequenceAction at load), so
# Get-SequenceAction below reads the live registry the engine reads.
Import-Module $handlerPsm -Force -DisableNameChecking -Global -ErrorAction SilentlyContinue -WarningAction SilentlyContinue

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

# Every fixture below lives at file scope: a Describe body is evaluated during
# the discovery pass and its scope is torn down before any It runs, so a variable
# declared inside one reaches the assertions as $null. For the same reason the
# per-verb cases are carried into each It as -TestCases data rather than closed
# over from the generating foreach -- the loop variable does not survive the pass
# boundary, and a $null verb would silently exercise the empty-name path.

# Original literal annotation gate: waitForText / waitForAndEnter / passwdPrompt / sshWaitReady.
$usesWaitSignals = 'waitForText','waitForAndEnter','passwdPrompt','sshWaitReady'
$notWaitSignals  = 'fetchAndExecute','sshExec','sshFetchAndExecute','pressKey','retry','tapOn','waitForSeconds'

# Original literal screenshot-skip gate: waitForText / waitForAndEnter / passwdPrompt / fetchAndExecute.
$selfCapture = 'waitForText','waitForAndEnter','passwdPrompt','fetchAndExecute'
# sshWaitReady writes a screenshot on its slow path but was NOT in the skip
# list -- the engine still captures for it, so its flag stays off.
$engineCapture = 'sshWaitReady','sshExec','pressKey','retry','tapOn','waitForSeconds'

# Source guard: the literal list pattern must not reappear alongside the flag read.
$engineText = Get-Content -Raw $enginePsm

# Rebuild the exact exception the engine's cycle-restart gate throws so the
# carrier contract is pinned without invoking host I/O.
$restart = [System.Management.Automation.RuntimeException]::new('YurunaCycleRestart: status-service /control/start-cycle requested mid-cycle abort at [sequence start]')
$restart.Data['YurunaCycleRestart'] = $true

Describe 'UsesWaitSignals flag matches the former failure-label annotation verb set' {

    foreach ($verb in $usesWaitSignals) {
        It "sets UsesWaitSignals on '$verb'" -TestCases @(@{ verb = $verb }) {
            param($verb)
            $e = Get-SequenceAction -Name $verb
            Assert-True ($null -ne $e) "'$verb' must be registered"
            Assert-True ([bool]$e.UsesWaitSignals) "'$verb' must opt into the matched-failurePattern annotation"
        }
    }
    foreach ($verb in $notWaitSignals) {
        It "leaves UsesWaitSignals off '$verb'" -TestCases @(@{ verb = $verb }) {
            param($verb)
            $e = Get-SequenceAction -Name $verb
            Assert-True ($null -ne $e) "'$verb' must be registered"
            Assert-Equal -Expected $false -Actual ([bool]$e.UsesWaitSignals) -Because "'$verb' must NOT be annotated (behavior identity with the former literal list)"
        }
    }
}

Describe 'CapturesOwnFailureScreenshot flag matches the former screenshot-skip verb set' {

    foreach ($verb in $selfCapture) {
        It "sets CapturesOwnFailureScreenshot on '$verb'" -TestCases @(@{ verb = $verb }) {
            param($verb)
            $e = Get-SequenceAction -Name $verb
            Assert-True ($null -ne $e) "'$verb' must be registered"
            Assert-True ([bool]$e.CapturesOwnFailureScreenshot) "'$verb' saves its own failure screenshot; the engine must skip"
        }
    }
    foreach ($verb in $engineCapture) {
        It "leaves CapturesOwnFailureScreenshot off '$verb'" -TestCases @(@{ verb = $verb }) {
            param($verb)
            $e = Get-SequenceAction -Name $verb
            Assert-True ($null -ne $e) "'$verb' must be registered"
            Assert-Equal -Expected $false -Actual ([bool]$e.CapturesOwnFailureScreenshot) -Because "'$verb' must let the engine capture (behavior identity with the former literal list)"
        }
    }
}

Describe 'Engine reads the flags, not literal verb-name lists' {

    It 'no longer gates the annotation on a literal waitForText/../sshWaitReady chain' {
        Assert-True ($engineText -match 'UsesWaitSignals') 'engine must read the UsesWaitSignals flag'
        Assert-True ($engineText -notmatch "action -eq 'sshWaitReady'") 'the literal sshWaitReady annotation gate must be gone'
    }
    It 'no longer gates the screenshot skip on a literal fetchAndExecute chain' {
        Assert-True ($engineText -match 'CapturesOwnFailureScreenshot') 'engine must read the CapturesOwnFailureScreenshot flag'
        Assert-True ($engineText -notmatch 'LastFailedAction -ne "fetchAndExecute"') 'the literal fetchAndExecute screenshot-skip gate must be gone'
    }
}

Describe 'YurunaCycleRestart marker carries a structured tag AND the message prefix' {

    It 'tags Exception.Data so a message rewrap cannot misroute the abort' {
        Assert-True ([bool]$restart.Data['YurunaCycleRestart']) 'the structured tag must be set'
    }
    It 'keeps the message prefix as the fallback for an untagged older throw' {
        Assert-True ($restart.Message -like 'YurunaCycleRestart:*') 'the message prefix fallback must survive'
    }
    It 'the engine catch prefers the tag but still falls back to the prefix' {
        $engineText = Get-Content -Raw $enginePsm
        Assert-True ($engineText -match "Data\['YurunaCycleRestart'\]") 'engine must read the structured tag'
        Assert-True ($engineText -match "Message -like 'YurunaCycleRestart:\*'") 'engine must keep the message-prefix fallback'
    }
    It 'the tag survives a throw through an intervening frame' {
        $blk = { throw $restart }
        $caught = $null
        try {
            try { & $blk } catch { throw }
        } catch { $caught = $_ }
        Assert-True ($null -ne $caught) 'the marker must propagate'
        Assert-True ([bool]$caught.Exception.Data['YurunaCycleRestart']) 'the tag must survive propagation'
        Assert-True ($caught.Exception.Message -like 'YurunaCycleRestart:*') 'the prefix must survive propagation'
    }
}
