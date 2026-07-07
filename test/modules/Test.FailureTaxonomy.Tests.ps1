<#PSScriptInfo
.VERSION 2026.07.07
.GUID 42d4f1a7-6c83-4b29-9e05-2a7b8c1d3e60
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test telemetry failure-taxonomy pester
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
    Pester guard for the canonical FailureClass/Severity taxonomy: the three
    sources (Test.FailureTaxonomy canonical arrays, Test.EventSchema validator
    enum, Test.SequenceAction Register-SequenceAction ValidateSet) must stay
    identical, so a future class can never silently drift between them.
.DESCRIPTION
    Throw-based assertions (OS-bundled Pester 3.4 / Pester 5+).
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.FailureTaxonomy.psm1') -Force -DisableNameChecking -Global -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.EventSchema.psm1')     -Force -DisableNameChecking -Global -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.SequenceAction.psm1')  -Force -DisableNameChecking -Global -ErrorAction SilentlyContinue

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-False { param($Condition, [string]$Because='') if ($Condition) { throw "Expected false. $Because" } }

Describe 'Test.FailureTaxonomy canonical arrays' {
    It 'returns the FailureClass values (includes the infra classes) and Severity values' {
        $fc = Get-FailureClassEnum
        Assert-True ($fc -contains 'ocr_timeout') 'has a known guest class'
        Assert-True ($fc -contains 'provisioning_failure') 'has the infra provisioning class'
        Assert-True ($fc -contains 'bootstrap_sync') 'has the infra bootstrap class'
        Assert-True ($fc -contains 'plan_invalid') 'has the infra plan class'
        Assert-True ($fc[-1] -eq 'unknown') "'unknown' stays last as the catch-all"
        Assert-Equal -Expected 'hard|soft|unknown' -Actual ((Get-SeverityEnum) -join '|') -Because 'severity set'
    }
}

Describe 'Assert-FailureTaxonomyInSync' {
    It 'returns true for a matching copy and false (with a warning) for a drifted one' {
        $fc = Get-FailureClassEnum
        $sev = Get-SeverityEnum
        Assert-True (Assert-FailureTaxonomyInSync -Source 't' -FailureClass $fc -Severity $sev -WarningAction SilentlyContinue) 'identical -> in sync'
        Assert-False (Assert-FailureTaxonomyInSync -Source 't' -FailureClass ($fc + 'bogus') -Severity $sev -WarningAction SilentlyContinue) 'extra value -> drift'
        Assert-False (Assert-FailureTaxonomyInSync -Source 't' -FailureClass $fc -Severity @('hard') -WarningAction SilentlyContinue) 'short severity -> drift'
        # Reordered list is also flagged (order-sensitive).
        $reordered = @($fc[1], $fc[0]) + $fc[2..($fc.Count-1)]
        Assert-False (Assert-FailureTaxonomyInSync -Source 't' -FailureClass $reordered -Severity $sev -WarningAction SilentlyContinue) 'reordered -> drift'
    }
}

Describe 'taxonomy single-source invariant (the three lists are identical)' {
    It 'EventSchema enum == canonical' {
        Assert-Equal -Expected ((Get-FailureClassEnum) -join '|') -Actual ((Get-CycleEventSchemaDescriptor).FailureClassEnum -join '|') -Because 'EventSchema must derive from the canonical set'
        Assert-Equal -Expected ((Get-SeverityEnum) -join '|') -Actual ((Get-CycleEventSchemaDescriptor).SeverityEnum -join '|') -Because 'EventSchema severity must derive from the canonical set'
    }
    It 'Register-SequenceAction ValidateSet == canonical (the literal copy has not drifted)' {
        $vs = (Get-Command Register-SequenceAction).Parameters['FailureClass'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
            ForEach-Object { $_.ValidValues }
        Assert-Equal -Expected ((Get-FailureClassEnum) -join '|') -Actual ($vs -join '|') -Because 'the ValidateSet literal must match the canonical set'
    }
}
