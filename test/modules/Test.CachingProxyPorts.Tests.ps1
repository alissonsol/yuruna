<#PSScriptInfo
.VERSION 2026.07.17
.GUID 42e6c9b2-7d18-4a53-8f01-2b4c6e9d0a37
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test caching-proxy port pester
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
    Guards that the caching-proxy exposed-port set is single-sourced through
    Get-CachingProxyExposedPort, so the three callers cannot drift apart.
.DESCRIPTION
    The parent status-service port-map setup, the inner cycle-start gate, and
    Start-CachingProxy's install list all pass the same TCP port set to
    Add-PortMap, which is clear-all-first on Windows -- so a port present in one
    list but dropped from another goes dark on the next map. The set now comes
    from one function; these tests pin its contents (fixed service ports plus
    the passed http/https ports) and assert no caller re-inlines the literal
    @(80, 3000, 9302, ...) set that the function replaced.

    The throw-based Assert-* helpers are defined at script scope and referenced
    from It blocks, so this runs under Pester 4.10.1 (Pester 5's scope split
    hides top-level helpers from It blocks).
#>

$here = Split-Path -Parent $PSCommandPath
$repo = Split-Path -Parent (Split-Path -Parent $here)

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

Import-Module (Join-Path $here 'Test.VMUtility.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue

Describe 'caching-proxy exposed-port set is single-sourced' {

    It 'exposes Get-CachingProxyExposedPort' {
        Assert-True ($null -ne (Get-Command Get-CachingProxyExposedPort -ErrorAction SilentlyContinue)) 'the helper must be exported'
    }

    It 'returns the fixed service ports (incl. 9400 pool-aggregator) plus the passed http/https ports' {
        $r = Get-CachingProxyExposedPort -HttpPort 3128 -HttpsPort 3129
        Assert-Equal -Expected '80,3000,9302,9400,3128,3129' -Actual ($r -join ',')
    }

    It 'defaults the http/https ports to Get-CachingProxyPort' {
        $exp = @(80, 3000, 9302, 9400, (Get-CachingProxyPort -Scheme http), (Get-CachingProxyPort -Scheme https)) -join ','
        Assert-Equal -Expected $exp -Actual ((Get-CachingProxyExposedPort) -join ',')
    }

    It 'no caller re-inlines the fixed @(80, 3000, 9302, ...) port set' {
        foreach ($rel in @('test/Start-StatusService.ps1', 'test/modules/Invoke-TestInnerRunner.ps1', 'test/Start-CachingProxy.ps1')) {
            $t = Get-Content -Raw -LiteralPath (Join-Path $repo $rel)
            Assert-True (-not ($t -match '@\(80,\s*3000,\s*9302,')) "the inline exposed-port set reappeared in $rel -- route it through Get-CachingProxyExposedPort"
        }
    }
}
