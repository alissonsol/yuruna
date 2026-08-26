<#PSScriptInfo
.VERSION 2026.08.25
.GUID 427af241-f350-490e-872c-815aba062774
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test requirement capability aesgcm pester
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
    Pester coverage for the runtime-capability half of the requirement check.
.DESCRIPTION
    The tool list answers "what is installed". This answers "what can the
    runtime DO", and the gap between the two is where the expensive failures
    live: a host can satisfy every version floor and still lack an algorithm
    the framework needs, then fail at the moment of use with an error that
    describes the symptom instead of the cause.

    That is not hypothetical. A macOS host whose runtime reported
    AesGcm.IsSupported=False failed every Lab token enrollment with a message
    blaming the code -- advice that could not work, because the aggregator had
    already accepted the code and sealed a reply the client simply could not
    open.

    The classifier is tested rather than the probe, because the probe answers
    truthfully on every host that would run this suite, and a test that can
    only pass on a broken machine is a test nobody runs.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -File test/modules/Test.RuntimeCapability.Tests.ps1
#>

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$TestRoot = Split-Path -Parent $here
$script:RepoRoot = Split-Path -Parent $TestRoot
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
Import-Module ([IO.Path]::Combine($script:RepoRoot, 'automation', 'Yuruna.Requirement.psm1')) -Force -Global -DisableNameChecking
}

Describe 'the runtime-capability rows' {
    It 'passes a runtime that reports the algorithm' {
        $rows = @(Get-RuntimeCapability -AesGcmSupported $true)
        Assert-Equal 1 $rows.Count
        Assert-Equal 'AES-GCM' $rows[0].Name
        Assert-True $rows[0].Available
        Assert-Equal '' $rows[0].Reason 'a satisfied capability needs no explanation'
    }

    It 'passes a runtime too old to be asked the question' {
        # $null is "IsSupported is not exposed here". Absence of the property is
        # not evidence of absence of the algorithm, and failing a working host
        # on an unanswerable question is worse than missing a broken one.
        $rows = @(Get-RuntimeCapability -AesGcmSupported $null)
        Assert-True $rows[0].Available 'an unanswerable probe must not fail the host'
    }

    It 'fails a runtime without the algorithm, naming both surfaces it breaks' {
        $rows = @(Get-RuntimeCapability -AesGcmSupported $false)
        Assert-False $rows[0].Available
        Assert-Match 'AES-GCM' $rows[0].Reason
        Assert-Match 'Lab token enrollment' $rows[0].Reason `
            'the operator meets this as a failed enrollment, so the reason must name it'
        Assert-Match 'config-sync credential' $rows[0].Reason `
            'the same runtime cannot serve credentials either, which fails on a DIFFERENT host and must not be a surprise'
        Assert-Match 'upgraded' $rows[0].Reason 'the reason names the fix, since nothing installs a capability'
    }

    It 'reports what this host actually has, without throwing' {
        # A capability check that throws is one nobody can run.
        $rows = @(Get-RuntimeCapabilityList)
        Assert-True ($rows.Count -ge 1) 'the list is never empty'
        foreach ($row in $rows) {
            Assert-True ($row.Available -is [bool]) "$($row.Name) answers with a verdict"
            if (-not $row.Available) { Assert-True ($row.Reason.Length -gt 0) "$($row.Name) must say why" }
        }
    }
}

Describe 'the requirement report' {
    It 'folds a missing capability into the aggregate reason, not just a pass/fail' {
        # Confirm-RequirementList returns a boxed bool carrying Reason. A
        # capability failure that did not reach that reason would leave a
        # machine consuming the result with no pointer to the cause -- the
        # exact gap New-YurunaValidationResult exists to close.
        $body = Get-Content -Raw -LiteralPath ([IO.Path]::Combine($script:RepoRoot, 'automation', 'Yuruna.Requirement.psm1'))
        Assert-Match 'Get-RuntimeCapabilityList' $body 'the report consults the capability list'
        Assert-Match 'failureReasons\.Add\("\$\(\$capability\.Name\) MISSING' $body `
            'a missing capability joins the same aggregate reason the tool rows use'
    }
}
