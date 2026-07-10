<#PSScriptInfo
.VERSION 2026.07.10
.GUID 42c4d5e6-f7a8-4b9c-8d01-2e3f4a5b6c7d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test output copy-safety pester
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
    Behavioral guard on Test.Output.psm1's Get-OutputState copy-safety contract.
.DESCRIPTION
    Get-OutputState documents that the returned snapshot is a copy so a caller
    mutating it does not corrupt the live counter state. A WarningsBySection
    returned by live reference lets a snapshot mutation (adding a section, or
    .Add()-ing to a section's list) corrupt the live state. These tests
    populate warnings, snapshot, mutate the snapshot, and assert the live state
    is unchanged -- they fail against a live-reference return.

    The throw-based Assert-* helpers are defined at script scope and referenced
    from It blocks, so this runs under Pester 4.10.1 (Pester 5's scope split
    hides top-level helpers from It blocks).
#>

$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.Output.psm1'

function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }

Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue

Describe 'Get-OutputState returns a copy-safe WarningsBySection' {
    # Leave the ambient counters zeroed so the suite does not perturb a live
    # $global:YurunaOutputState if it runs in-session.
    AfterAll { Reset-OutputState -Confirm:$false }

    It 'isolates the returned WarningsBySection from live state (mutating the snapshot does not corrupt live)' {
        Reset-OutputState -Confirm:$false
        $null = Write-Section 'SecA'
        $null = Write-Warn 'w1'
        $null = Write-Warn 'w2'

        $snap = Get-OutputState
        Assert-Equal -Expected 2 -Actual $snap.WarningsBySection['SecA'].Count -Because 'the snapshot carries the live warnings'

        # Mutate the snapshot two ways: append to an existing section's list, and
        # add a brand-new section. Neither may reach the live state.
        $snap.WarningsBySection['SecA'].Add('injected')
        $snap.WarningsBySection['SecZ'] = [System.Collections.Generic.List[string]]::new()

        $live = Get-OutputState
        Assert-Equal -Expected 2 -Actual $live.WarningsBySection['SecA'].Count -Because 'the section list must be a copy, not the live list'
        Assert-True  (-not $live.WarningsBySection.Contains('SecZ')) 'the dictionary must be a fresh container, not the live one'
    }

    It 'preserves the recorded warnings in the copy' {
        Reset-OutputState -Confirm:$false
        $null = Write-Section 'SecB'
        $null = Write-Warn 'only'

        $snap = Get-OutputState
        Assert-Equal -Expected 1     -Actual $snap.WarningsBySection['SecB'].Count -Because 'the copy carries the live data'
        Assert-Equal -Expected 'only' -Actual $snap.WarningsBySection['SecB'][0]    -Because 'copied content matches the live content'
    }

    It 'Failures remains copy-safe (unchanged contract, regression guard)' {
        Reset-OutputState -Confirm:$false
        Write-Fail 'boom' | Out-Null
        $snap = Get-OutputState
        $snap.Failures += [pscustomobject]@{ Message = 'injected' }
        $live = Get-OutputState
        Assert-Equal -Expected 1 -Actual @($live.Failures).Count -Because 'the Failures array snapshot is isolated from caller mutation'
    }
}
