<#PSScriptInfo
.VERSION 2026.07.14
.GUID 42c1a9b8-7d6e-4f52-90a3-1b2c3d4e5f61
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test automation result failure-taxonomy pester
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
    Pester guard for ConvertTo-CanonicalFailureClass: the automation-domain
    result taxonomy maps onto the canonical dispatcher taxonomy so a deploy-phase
    failure is dispatcher-routable instead of dropped or flagged as out-of-enum.
.DESCRIPTION
    Asserts (1) every automation failureClass maps to a value, (2) every mapped
    failure value is a member of the canonical FailureClass enum AND has a
    registered remediation handler, and (3) an unrecognized input falls back to
    'unknown'. Throw-based assertions. Runs under Pester 4.10.1.
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$autoDir  = Join-Path $repoRoot 'automation'

Import-Module (Join-Path $autoDir 'Yuruna.Result.psm1')      -Force -DisableNameChecking -Global -ErrorAction SilentlyContinue
Import-Module (Join-Path $here   'Test.FailureTaxonomy.psm1') -Force -DisableNameChecking -Global -ErrorAction SilentlyContinue
Import-Module (Join-Path $here   'Test.Remediation.psm1')     -Force -DisableNameChecking -Global -ErrorAction SilentlyContinue

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

# The automation-domain failureClass vocabulary (the ValidateSet in
# New-YurunaResultManifest). 'ok' is the non-failure member.
$automationFailureClasses = @('config_error', 'cluster_unreachable', 'chart_invalid', 'tool_failed', 'unknown')

Describe 'ConvertTo-CanonicalFailureClass -- automation-to-canonical failure mapping' {
    It "maps 'ok' through unchanged (a success is not a routable failure)" {
        Assert-Equal -Expected 'ok' -Actual (ConvertTo-CanonicalFailureClass 'ok') -Because 'ok is not a failure'
    }

    It 'maps every automation failure class to a canonical enum member' {
        $canonical = Get-FailureClassEnum
        foreach ($c in $automationFailureClasses) {
            $mapped = ConvertTo-CanonicalFailureClass $c
            Assert-True ($canonical -contains $mapped) "'$c' -> '$mapped' must be a canonical value"
        }
    }

    It 'maps every automation failure class to a value the dispatcher has a handler for' {
        $registered = Get-RegisteredFailureClass
        foreach ($c in $automationFailureClasses) {
            $mapped = ConvertTo-CanonicalFailureClass $c
            Assert-True ($registered -contains $mapped) "'$c' -> '$mapped' must have a registered remediation handler"
        }
    }

    It 'uses the intended per-class mapping' {
        Assert-Equal -Expected 'plan_invalid'         -Actual (ConvertTo-CanonicalFailureClass 'config_error')        -Because 'config_error is a config/plan error'
        Assert-Equal -Expected 'plan_invalid'         -Actual (ConvertTo-CanonicalFailureClass 'chart_invalid')       -Because 'a rejected chart is a config error'
        Assert-Equal -Expected 'network_timeout'      -Actual (ConvertTo-CanonicalFailureClass 'cluster_unreachable') -Because 'unreachable cluster maps to the network class'
        Assert-Equal -Expected 'provisioning_failure' -Actual (ConvertTo-CanonicalFailureClass 'tool_failed')         -Because 'a failed deploy tool is a provisioning failure'
        Assert-Equal -Expected 'unknown'              -Actual (ConvertTo-CanonicalFailureClass 'unknown')             -Because 'unknown stays unknown'
    }

    It "falls back to 'unknown' for an input outside the automation vocabulary" {
        Assert-Equal -Expected 'unknown' -Actual (ConvertTo-CanonicalFailureClass 'not_a_real_class') -Because 'unrecognized -> catch-all'
        Assert-Equal -Expected 'unknown' -Actual (ConvertTo-CanonicalFailureClass '')                 -Because 'empty -> catch-all'
    }
}
