<#PSScriptInfo
.VERSION 2026.08.20
.GUID 42c9b3e7-1d58-4a06-9e24-7f3b5c8d1a60
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pester remediation self-healing policy
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
    Which failures the runner may retry unattended, and the guarantee that the
    decision has exactly one home.
.DESCRIPTION
    Auto-remediation ends a failure pause early so the next cycle starts
    immediately. That is a real action taken with no operator watching, so the
    set of classes it applies to is a policy and is pinned here.

    The rule this suite exists to keep is not the membership -- that will grow
    -- but the SINGLE SOURCE. The outer loop used to carry its own four-class
    literal beside the registry that classifies failures, and the two drifted:
    the literal omitted three classes whose handlers already recommended a
    retry. A second copy is the defect; a changed list is just a decision.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1')     -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.Remediation.psm1') -Force -Global -DisableNameChecking

    $script:RepoRoot   = Get-YurunaTestRepoRoot -SuiteDirectory $here
    $script:OuterLoop  = Join-Path $here 'Test.RunnerOuterLoop.psm1'
    $script:AllowList  = Get-AutoRemediationAllowList
}

Describe 'the auto-remediation allow-list' {

    It 'admits only classes whose retry is the whole repair' {
        $expected = @(
            'wait_timeout', 'network_timeout', 'ip_not_discovered', 'host_network_degraded',
            'instrumentation_failure', 'host_io_blocked', 'credential_expired'
        )
        foreach ($c in $expected) {
            Assert-True (Test-AutoRemediationAllowed -FailureClass $c) "$c must be retryable"
        }
        Assert-Equal -Expected $expected.Count -Actual $script:AllowList.Count `
            -Because 'a class added without a reason recorded beside it is a policy change made by accident'
    }

    It 'refuses the classes where a retry cannot help or destroys evidence' {
        # Each of these has a registered handler that recommends something other
        # than a retry: a bad plan, a missing payload, a full disk and an
        # unclassified failure all need a human before the next attempt.
        foreach ($c in @('plan_invalid', 'payload_unavailable', 'pool_storage_full',
                'project_access_denied', 'elevation_required', 'script_error', 'unknown')) {
            Assert-True (-not (Test-AutoRemediationAllowed -FailureClass $c)) "$c must NOT be retried unattended"
        }
    }

    It 'fails closed on a class it has never seen' {
        # The failure nobody classified is precisely the one to stop on.
        Assert-True (-not (Test-AutoRemediationAllowed -FailureClass 'a_class_from_the_future'))
        Assert-True (-not (Test-AutoRemediationAllowed -FailureClass ''))
    }

    It 'records why each class qualifies' {
        foreach ($k in $script:AllowList.Keys) {
            Assert-True ([bool]$script:AllowList[$k]) "$k must carry the reason it is safe to retry"
        }
    }

    It 'names only classes the registry can actually classify' {
        # An allow-list entry with no handler would let the loop retry a failure
        # nothing has reasoned about.
        $known = @(Get-RegisteredFailureClass)
        Assert-True ($known.Count -gt 0) 'the registry must have handlers registered'
        foreach ($k in $script:AllowList.Keys) {
            Assert-True ($known -contains $k) "$k is allow-listed but has no registered handler"
        }
    }
}

Describe 'the decision has one home' {

    It 'leaves no failure-class literal in the outer loop' {
        # The defect this replaced: a second list, in another file, that could
        # disagree with the registry and did.
        $src = Get-Content -Raw -LiteralPath $script:OuterLoop
        foreach ($c in $script:AllowList.Keys) {
            $literal = "'$c'"
            $inArray = [regex]::Matches($src, [regex]::Escape($literal) + '\s*,\s*''')
            Assert-True ($inArray.Count -eq 0) `
                "$script:OuterLoop still builds a failure-class array containing $literal; ask the registry instead"
        }
    }

    It 'asks the registry before ending a failure pause early' {
        $src = Get-Content -Raw -LiteralPath $script:OuterLoop
        Assert-Match -Pattern 'Test-AutoRemediationAllowed' -Actual $src `
            -Because 'the outer loop must route the retry decision through the registry'
    }
}
