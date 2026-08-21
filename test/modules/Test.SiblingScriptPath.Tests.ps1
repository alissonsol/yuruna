<#PSScriptInfo
.VERSION 2026.08.21
.GUID 42d59e0e-8323-436b-9a13-dede2f134739
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pester path sibling script
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
    Every sibling-script path composed from a repo-relative string resolves to a
    file that exists.
.DESCRIPTION
    A path assembled from a string and then guarded by Test-Path fails silently
    by construction: the guard was added for resilience, and its effect is that
    a wrong path becomes a "skipped" line instead of an error. Nothing in the
    suite set could see that class, because no test resolved composed paths.

    It was not hypothetical. All three Disable-TestAutomation.ps1 copies composed
    `test/Stop-<service>VM.ps1` after those scripts had moved to test/service/,
    so -StopServices reported success while stopping nothing, on every host
    platform at once.

    The rule is deliberately narrow: composed paths must RESOLVE. It does not
    assert which directory they name, because that would veto the next
    legitimate move -- and test/service/ is itself the result of one.

    The expansion values are read from the composing script's OWN loop, not from
    Get-YurunaServiceVmRoster. The roster keys are slugs (`caching-proxy`) while
    these scripts name services in PascalCase (`CachingProxyService`), so
    expanding with the roster would test a path the script never builds. What
    matters is the invariant that every path the script WILL compose at runtime
    resolves -- which is exactly the defect that shipped.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1')    -Force -Global -DisableNameChecking

    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here

    # Scripts that compose sibling paths out of a repo-relative string. Kept as
    # an explicit list because the pattern is a string literal, not a call site
    # any parser can enumerate reliably.
    # One entry, and that is the point: the three per-host Disable scripts used
    # to compose these paths themselves, so a service moved on disk had to be
    # corrected in three places. They now call Stop-YurunaServiceVMSet, which
    # composes them once.
    $script:Composers = @(
        'test/modules/Test.HostAutomationState.psm1'
    )

    # Pull every "<dir>/<literal>${svc}<literal>.ps1" shape out of a file and
    # expand it across the roster, so a template is checked for every value it
    # is used with rather than only as text.
    function Get-ComposedPath {
        param([Parameter(Mandatory)][string]$Relative)
        $src = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot $Relative)
        $loop = [regex]::Match($src, 'foreach\s*\(\s*\$svc\s+in\s+@\(([^)]*)\)')
        $keys = if ($loop.Success) {
            @([regex]::Matches($loop.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
        } else { @() }
        $out = [Collections.Generic.List[object]]::new()
        foreach ($m in [regex]::Matches($src, '"(test/[^"]*\$\{svc\}[^"]*\.ps1)"')) {
            foreach ($k in $keys) {
                $out.Add([pscustomobject]@{
                        Source   = $Relative
                        Template = $m.Groups[1].Value
                        Path     = ($m.Groups[1].Value -replace '\$\{svc\}', $k)
                    })
            }
        }
        $out
    }
}

Describe 'composed sibling-script paths resolve' {

    It 'finds the composing scripts it claims to cover' {
        foreach ($rel in $script:Composers) {
            Assert-True (Test-Path -LiteralPath (Join-Path $script:RepoRoot $rel)) "missing composer: $rel"
        }
    }

    It 'extracts the service names each composer actually loops over' {
        # If extraction returned nothing, every expansion below would vacuously
        # pass -- the same hollow-green shape this suite exists to end.
        foreach ($rel in $script:Composers) {
            Assert-True (@(Get-ComposedPath -Relative $rel).Count -gt 0) "no composed path extracted from $rel"
        }
    }

    It 'resolves every composed service-script path on disk' {
        $missing = [Collections.Generic.List[string]]::new()
        $checked = 0
        foreach ($rel in $script:Composers) {
            foreach ($c in Get-ComposedPath -Relative $rel) {
                $checked++
                if (-not (Test-Path -LiteralPath (Join-Path $script:RepoRoot $c.Path))) {
                    $missing.Add("$($c.Source) composes '$($c.Path)' -- no such file")
                }
            }
        }
        Assert-True ($checked -gt 0) 'no composed path was found to check -- the extraction pattern has drifted'
        Assert-NoFinding -Finding $missing -Because 'a composed path that does not resolve is a silent no-op behind its Test-Path guard'
    }
}
