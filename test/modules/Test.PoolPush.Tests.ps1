<#PSScriptInfo
.VERSION 2026.06.26
.GUID 421a7e34-5b82-4d60-8f13-2a6c9e0b4d75
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool push pester
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
    Pester coverage for the pure + guard parts of Test.PoolPush.psm1: NDJSON batching
    (consumed by ASSIGNMENT per the ,@() array-return idiom), the best-effort guards in
    Send-PoolEventBatch, and that the pinned-TLS helper type compiled. The CA-pinned POST
    itself is integration-verified against a live aggregator.
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.PoolPush.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

Describe 'Get-PoolPushBatch (NDJSON batching, assignment-consumed)' {
    It 'splits into capped batches and drops blank lines' {
        $b = Get-PoolPushBatch -Lines @('a', '', 'b', 'c') -MaxLines 2
        Assert-Equal 2 $b.Count 'two batches of <=2'
        Assert-Equal 'a,b' (($b[0]) -join ',') 'first batch (blank dropped)'
        Assert-Equal 'c'   (($b[1]) -join ',') 'second batch'
    }
    It 'returns a single batch under the cap' {
        $b = Get-PoolPushBatch -Lines @('x', 'y') -MaxLines 1000
        Assert-Equal 1 $b.Count 'one batch'
        Assert-Equal 'x,y' (($b[0]) -join ',') 'all lines in it'
    }
    It 'returns no batches for empty / all-blank input' {
        $b = Get-PoolPushBatch -Lines @() -MaxLines 10
        Assert-Equal 0 @($b).Count 'empty -> no batches'
        $b2 = Get-PoolPushBatch -Lines @('', '   ', "`t") -MaxLines 10
        Assert-Equal 0 @($b2).Count 'all-blank -> no batches'
    }
}

Describe 'Send-PoolEventBatch (best-effort guards)' {
    It 'returns 0 for an empty batch (no request attempted)' {
        Assert-Equal 0 (Send-PoolEventBatch -IngestUrl 'https://10.0.0.5:9400/ingest' -CaCertPath 'nope.crt' -Token 't' -Lines @())
    }
}

Describe 'pinned-TLS helper compiled' {
    It 'compiled the CA-pinned HttpClient factory type' {
        Assert-True ([bool]([System.Management.Automation.PSTypeName]'YurunaPoolPinnedTls').Type) 'YurunaPoolPinnedTls present'
    }
}
