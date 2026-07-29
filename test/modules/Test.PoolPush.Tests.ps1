<#PSScriptInfo
.VERSION 2026.07.29
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
        Assert-Equal -Expected 2 -Actual $b.Count -Because 'two batches of <=2'
        Assert-Equal -Expected 'a,b' -Actual (($b[0]) -join ',') -Because 'first batch (blank dropped)'
        Assert-Equal -Expected 'c'   -Actual (($b[1]) -join ',') -Because 'second batch'
    }
    It 'returns a single batch under the cap' {
        $b = Get-PoolPushBatch -Lines @('x', 'y') -MaxLines 1000
        Assert-Equal -Expected 1 -Actual $b.Count -Because 'one batch'
        Assert-Equal -Expected 'x,y' -Actual (($b[0]) -join ',') -Because 'all lines in it'
    }
    It 'returns no batches for empty / all-blank input' {
        $b = Get-PoolPushBatch -Lines @() -MaxLines 10
        Assert-Equal -Expected 0 -Actual @($b).Count -Because 'empty -> no batches'
        $b2 = Get-PoolPushBatch -Lines @('', '   ', "`t") -MaxLines 10
        Assert-Equal -Expected 0 -Actual @($b2).Count -Because 'all-blank -> no batches'
    }
}

Describe 'Send-PoolEventBatch (best-effort guards)' {
    It 'returns 0 for an empty batch (no request attempted)' {
        Assert-Equal 0 (Send-PoolEventBatch -IngestUrl 'https://10.0.0.5:9400/ingest' -CaCertPath 'nope.crt' -Token 't' -Lines @())
    }
}

Describe 'forget-host client (best-effort guards)' {
    It 'Send-PoolForgetRequest returns 0 on an unusable CA (never throws)' {
        Assert-Equal 0 (Send-PoolForgetRequest -Url 'https://192.0.2.1:9400/api/v1/forget-host?hostId=42' -CaCertPath 'nope.crt' -Token 't')
    }
    It 'Invoke-PoolForgetHost reports not-ok with a reason when the aggregator/CA is unreachable' {
        # 192.0.2.1 is TEST-NET-1 (RFC 5737) -- guaranteed unroutable, so the CA fetch
        # fails fast and the call returns a best-effort not-ok summary instead of throwing.
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('pfh_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        try {
            $r = Invoke-PoolForgetHost -ProxyIp '192.0.2.1' -HostId '42cafe0000000000000000000000dead' -Token 't' -RuntimeDir $tmp -TimeoutSeconds 2
            Assert-True ($r -is [hashtable]) 'returns a summary hashtable'
            Assert-True (-not $r.ok) 'not ok against an unreachable aggregator'
            Assert-True ([bool]$r.reason) 'a reason is set'
        } finally { Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue }
    }
}

Describe 'pinned-TLS helper compiled' {
    It 'compiled the CA-pinned HttpClient factory type' {
        Assert-True ([bool]([System.Management.Automation.PSTypeName]'YurunaPoolPinnedTls').Type) 'YurunaPoolPinnedTls present'
    }
}
