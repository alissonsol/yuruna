<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42f0a1b2-c3d4-4e56-8a78-9b0c1d2e3f40
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test log rotation loglevel pester
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
    Behavioral + structural guards on the log-core modules: Test.LogLevel.psm1
    (ProgressPreference restore), Test.LogRotation.psm1 (throttle stamp + live-file
    recreate), and Test.Log.psm1 (cheap cycle-count short-circuit).
.DESCRIPTION
    Pinned invariants:
      * Set-LogLevelPreference restores ProgressPreference when the level rises
        above Verbose, putting back the CAPTURED value (so a caller's deliberate
        SilentlyContinue is preserved, never force-enabled).
      * Test-LogRotationDue is a pure predicate (repeated calls do not advance the
        throttle); Invoke-LogRotation records the throttle only after a completed
        size check.
      * Invoke-LogRotation recreates an empty live file immediately after rotating,
        so there is no window with no live log.
      * Invoke-CycleLogRotation enumerates names and bails before the Sort-Object
        when below the cap.

    The throw-based Assert-* helpers live at script scope and are referenced from
    It blocks, so this runs under Pester 4.10.1.
#>

$here      = Split-Path -Parent $PSCommandPath
$logLevel  = Join-Path $here 'Test.LogLevel.psm1'
$logRot    = Join-Path $here 'Test.LogRotation.psm1'
$logMod    = Join-Path $here 'Test.Log.psm1'

function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }

# Unqualified (not $script:-qualified) file-scope names: an It block runs in a
# fresh script scope, so `$script:Foo` there resolves to that new scope and reads
# back $null even when the file assigned it -- only an unqualified name walks the
# scope chain out to the file's variables. The $script: qualifier INSIDE the
# module scriptblock below is a different scope entirely (Test.LogLevel's own)
# and must stay.
$LogLevelModule = Import-Module $logLevel -Force -DisableNameChecking -PassThru
Import-Module $logRot -Force -DisableNameChecking

# Scriptblock (not a Verb-Noun function) so PSUseShouldProcessForStateChangingFunctions
# does not fire on a trivial test-state reset.
$ResetSavedProgress = { & $LogLevelModule { $script:SavedProgressPreference = $null } }

Describe 'Set-LogLevelPreference restores ProgressPreference symmetrically' {
    It 'restores the captured value when the level rises above Verbose' {
        $saved = $global:ProgressPreference
        & $ResetSavedProgress
        try {
            $global:ProgressPreference = 'Continue'
            Set-LogLevelPreference -Level 'Verbose'
            Assert-Equal 'SilentlyContinue' $global:ProgressPreference -Because 'suppressed at Verbose'
            Set-LogLevelPreference -Level 'Information'
            Assert-Equal 'Continue' $global:ProgressPreference -Because 'restored to the captured Continue when the level rose above Verbose'
        } finally { $global:ProgressPreference = $saved; & $ResetSavedProgress }
    }

    It 'preserves a caller SilentlyContinue (does not force-enable the progress bar)' {
        $saved = $global:ProgressPreference
        & $ResetSavedProgress
        try {
            $global:ProgressPreference = 'SilentlyContinue'
            Set-LogLevelPreference -Level 'Verbose'
            Set-LogLevelPreference -Level 'Information'
            Assert-Equal 'SilentlyContinue' $global:ProgressPreference -Because 'the caller SilentlyContinue is put back, not forced to Continue'
        } finally { $global:ProgressPreference = $saved; & $ResetSavedProgress }
    }
}

Describe 'Log rotation throttle stamps only after a completed check' {
    It 'Test-LogRotationDue is a pure predicate (repeated calls do not advance the throttle)' {
        Reset-LogRotationCache -Confirm:$false
        $p = [System.IO.Path]::GetTempFileName()
        try {
            Assert-True (Test-LogRotationDue -Path $p) 'first call is due'
            Assert-True (Test-LogRotationDue -Path $p) 'still due -- the predicate does not stamp'
        } finally { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }

    It 'Invoke-LogRotation records the throttle after a completed size check' {
        Reset-LogRotationCache -Confirm:$false
        $p = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllText($p, 'small')
            $null = Invoke-LogRotation -Path $p -MaxBytes 1MB -Confirm:$false
            Assert-True (-not (Test-LogRotationDue -Path $p)) 'the completed under-threshold check stamped the throttle'
        } finally { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }

    It 'a failed size read does NOT burn the throttle window (the next call retries)' {
        Reset-LogRotationCache -Confirm:$false
        $p = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllText($p, 'small')
            # Test-Path still passes (the file exists); force the size read to throw
            # so the rotation "check" never completes.
            Mock -ModuleName Test.LogRotation Get-Item { throw 'simulated FS error' }
            $null = Invoke-LogRotation -Path $p -MaxBytes 1MB -Confirm:$false
            Assert-True (Test-LogRotationDue -Path $p) 'a read failure must not stamp the throttle -- the next call retries immediately'
        } finally { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Invoke-LogRotation recreates the live file after rotating' {
    It 'leaves an empty live file (no gap with no live log) and moves content to .1' {
        Reset-LogRotationCache -Confirm:$false
        $p = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllText($p, ('x' * 100))
            $rotated = Invoke-LogRotation -Path $p -MaxBytes 10 -Force -Confirm:$false
            Assert-True $rotated 'rotation fired (size over threshold)'
            Assert-True (Test-Path -LiteralPath $p) 'live file recreated immediately after the move'
            Assert-Equal 0 (Get-Item -LiteralPath $p).Length -Because 'recreated live file is empty'
            Assert-True (Test-Path -LiteralPath "$p.1") 'rotated content moved to .1'
        } finally { Remove-Item -LiteralPath $p, "$p.1" -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Invoke-CycleLogRotation cheap-counts before the sort' {
    It 'gates the Sort-Object behind a -Name pre-count bail (short-circuit, not just a -Name presence)' {
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($logMod, [ref]$null, [ref]$errs)
        if ($errs) { throw "Parse errors: $($errs[0].Message)" }
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-CycleLogRotation' }, $true) | Select-Object -First 1
        Assert-True ($null -ne $fn) 'Invoke-CycleLogRotation is defined'
        $nameListing = @($fn.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Get-ChildItem' -and
            @($n.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Name' }).Count -ge 1
        }, $true)) | Select-Object -First 1
        Assert-True ($null -ne $nameListing) 'a Get-ChildItem -Name cheap pre-count is present'
        $sort = @($fn.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Sort-Object'
        }, $true)) | Select-Object -First 1
        Assert-True ($null -ne $sort) 'a Sort-Object listing is present'
        # A return-0 bail must sit BETWEEN the -Name pre-count and the Sort-Object,
        # so a below-cap call short-circuits before paying the sort. A dead -Name
        # call in front of an unconditional Sort-Object would not satisfy this.
        $bail = @($fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] }, $true) | Where-Object {
            $_.Extent.StartOffset -ge $nameListing.Extent.EndOffset -and
            $_.Extent.EndOffset -le $sort.Extent.StartOffset -and
            @($_.FindAll({ param($m) $m -is [System.Management.Automation.Language.ReturnStatementAst] }, $true)).Count -ge 1
        })
        Assert-True (@($bail).Count -ge 1) 'a return-bail gates the Sort-Object behind the cheap pre-count'
    }
}

Describe 'Invoke-CycleLogRotation trims at a trigger below the hard limit' {
    It 'gates rotation on CycleHistoryTrigger, held strictly between KEEP and LIMIT so the count stays bounded near the trigger' {
        # Read the rotation constants from the module's own scope (no global
        # pollution). The invariant KEEP < TRIGGER < LIMIT is what stops the
        # top-level count from swinging KEEP..LIMIT between trims: trimming at
        # the trigger caps the steady-state backlog near the trigger instead.
        $mod = Import-Module $logMod -Force -DisableNameChecking -PassThru
        try {
            $keep    = & $mod { $script:CycleHistoryKeep }
            $trigger = & $mod { $script:CycleHistoryTrigger }
            $limit   = & $mod { $script:CycleHistoryLimit }
            Assert-True ($trigger -gt $keep) "trigger ($trigger) must exceed keep ($keep) so a rotation always has folders to move"
            Assert-True ($trigger -lt $limit) "trigger ($trigger) must sit below the hard limit ($limit) so the count is bounded near the trigger, not the ceiling"
        } finally { Remove-Module $mod -Force -ErrorAction SilentlyContinue }

        # The threshold both bail checks compare against must be CycleHistoryTrigger,
        # not CycleHistoryLimit -- otherwise rotation never fires until the ceiling
        # and the directory oscillates KEEP..LIMIT.
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($logMod, [ref]$null, [ref]$errs)
        if ($errs) { throw "Parse errors: $($errs[0].Message)" }
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-CycleLogRotation' }, $true) | Select-Object -First 1
        Assert-True ($null -ne $fn) 'Invoke-CycleLogRotation is defined'
        $triggerRefs = @($fn.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $n.VariablePath.UserPath -eq 'script:CycleHistoryTrigger'
        }, $true))
        Assert-True (@($triggerRefs).Count -ge 2) 'both count bails compare against CycleHistoryTrigger'
    }
}
