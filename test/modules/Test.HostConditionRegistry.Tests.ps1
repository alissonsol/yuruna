<#PSScriptInfo
.VERSION 2026.08.19
.GUID 42d1e9a4-db28-4ba0-8a3a-5806a893ed05
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host condition registry provider
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
    Every supported host registers a condition provider, and every slot in
    the record it registers is one somebody reads.
.DESCRIPTION
    The registry binds a per-host record -- Assert, AssertMinimum,
    RequiresElevation and the optional capabilities -- that the dispatchers
    invoke by slot. Registration is all-or-nothing per host: a name listed as
    mandatory that cannot be resolved skips the ENTIRE registration for that
    platform, leaving a host with no Assert and no AssertMinimum. The only
    signal is a Write-Warning at import, which an unattended cycle does not
    read, and the effect surfaces much later as "unknown host type, skipping
    checks" -- which passes. So the first rule here is simply that all three
    hosts are present after a plain import.

    The second rule is why the registry could carry a mandatory slot that
    nothing ever invoked: a record field costs nothing to declare and nothing
    to store, so an unread one is invisible. Requiring every slot to have a
    dispatch site makes the record self-limiting -- a field is either wired to
    a caller or it does not belong in the record. It also protects the first
    rule, because an unread mandatory slot is the cheapest way to lose an
    entire platform's registration: the host stops registering over a function
    whose absence changes no behavior.

    Registration happens at import, on whatever OS the suite runs on, because
    the platform modules define their functions unconditionally and only
    branch at call time. That is what makes this checkable from one host
    rather than needing all three.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath

    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostCondition.psm1') -Force -DisableNameChecking

    $script:Matrix = Get-HostConditionProviderMatrix
    $script:Expected = @('host.windows.hyper-v', 'host.macos.utm', 'host.ubuntu.kvm')

    # The dispatchers live across the Test.Host* family, not in one module.
    $script:FamilyText = (Get-ChildItem -Path $here -Filter 'Test.Host*.psm1' |
            ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
}

Describe 'every supported host registers a condition provider' {
    It 'registers all three host types on a plain import' {
        $missing = @($script:Expected | Where-Object { -not $script:Matrix.Contains($_) })
        Assert-True ($missing.Count -eq 0) @"
these host types did not register, so their Assert and AssertMinimum are gone
and the dispatcher will skip their checks and pass:
$($missing -join "`n")
"@
    }

    It 'binds the mandatory slots on every registered host' {
        $broken = [Collections.Generic.List[string]]::new()
        foreach ($hostType in $script:Expected) {
            $record = $script:Matrix[$hostType]
            if (-not $record) { continue }
            foreach ($slot in @('Assert', 'AssertMinimum')) {
                if (-not $record.$slot) { $broken.Add("${hostType}: $slot is empty") }
            }
        }
        Assert-True ($broken.Count -eq 0) ($broken -join "`n")
    }
}

Describe 'every slot in a provider record has a caller' {
    It 'invokes each registered slot somewhere in the Test.Host* family' {
        # HostType is the registry key rather than a dispatched capability.
        $orphans = [Collections.Generic.List[string]]::new()
        foreach ($hostType in $script:Expected) {
            $record = $script:Matrix[$hostType]
            if (-not $record) { continue }
            foreach ($slot in $record.Keys) {
                if ($slot -eq 'HostType') { continue }
                if ($script:FamilyText -notmatch ('\$provider\.' + [regex]::Escape($slot) + '\b')) {
                    $orphans.Add("${hostType}: $slot")
                }
            }
        }
        Assert-True ($orphans.Count -eq 0) @"
these provider slots are stored but never invoked. An unread slot is dead
weight, and a mandatory one costs a whole platform its registration when its
function goes missing:
$(($orphans | Sort-Object -Unique) -join "`n")
"@
    }
}
