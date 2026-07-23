<#PSScriptInfo
.VERSION 2026.07.22
.GUID 421a7f92-3c68-4b05-9e27-8a0f5d2c6b13
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test retry telemetry ndjson pester
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
    Pester coverage for the host-side retry telemetry: Yuruna.Retry emits
    retry_attempt / retry_exhausted NDJSON, and Publish-GuestRetryMarker turns
    the guest bash lib's YURUNA_RETRY stdout markers into the same events. Both
    are validated against the real event schema.
.DESCRIPTION
    Test.EventSchema is imported for Test-CycleEventSchema. The NDJSON sink is a
    global Send-CycleEventSafely stub (the module + the extracted function resolve
    it from the global table, Get-Command-guarded). Publish-GuestRetryMarker is
    lifted out of Test.SequenceHandler.psm1 via the parser (no heavy module
    import), the same discipline as the sibling fetch-execute test.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The NDJSON sink is resolved from the global command table at call time, so the collector stub and its assertions must straddle the global scope.')]
param()

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)

Import-Module (Join-Path $here 'Test.EventSchema.psm1')        -Force -DisableNameChecking
Import-Module (Join-Path $repoRoot 'automation/Yuruna.Retry.psm1') -Force -DisableNameChecking

# Lift Publish-GuestRetryMarker out of the module via the parser (its module
# pulls a heavy dep chain; the function itself is self-contained).
$shModPath = Join-Path $here 'Test.SequenceHandler.psm1'
$modAst = [System.Management.Automation.Language.Parser]::ParseFile($shModPath, [ref]$null, [ref]$null)
$fnAst  = $modAst.Find({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and $n.Name -eq 'Publish-GuestRetryMarker' }, $true)
if (-not $fnAst) { throw 'Publish-GuestRetryMarker not found in Test.SequenceHandler.psm1' }
. ([scriptblock]::Create($fnAst.Extent.Text))

function Assert-Equal { param($Actual, $Expected, [string]$Because = '') if ("$Actual" -ne "$Expected") { throw "Expected '$Expected', got '$Actual'. $Because" } }
function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

Describe 'Yuruna.Retry structured telemetry' {
    It 'emits retry_attempt then retry_exhausted (schema-valid) for a failing scriptblock' {
        $global:__RetryEv = @()
        function global:Send-CycleEventSafely { param($EventRecord) $global:__RetryEv += , $EventRecord }
        try {
            $r = Invoke-WithYurunaRetry -Label 'unit-test' -MaxAttempts 2 -InitialDelaySeconds 1 -ScriptBlock { $global:LASTEXITCODE = 7; 'boom' }
            Assert-Equal -Actual $r.Success -Expected $false -Because 'the scriptblock always exits 7'
            Assert-Equal -Actual $global:__RetryEv.Count -Expected 2 -Because 'one retry_attempt + one retry_exhausted'
            Assert-Equal -Actual $global:__RetryEv[0].event -Expected 'retry_attempt'
            Assert-Equal -Actual $global:__RetryEv[0].attempt -Expected 1
            Assert-Equal -Actual $global:__RetryEv[0].exitCode -Expected 7
            Assert-Equal -Actual $global:__RetryEv[0].stack -Expected 'pwsh'
            Assert-Equal -Actual $global:__RetryEv[1].event -Expected 'retry_exhausted'
            Assert-Equal -Actual $global:__RetryEv[1].permanent -Expected $false
            foreach ($ev in $global:__RetryEv) {
                $v = @(Test-CycleEventSchema -Record ([hashtable]$ev))
                Assert-Equal -Actual $v.Count -Expected 0 -Because "schema violations on $($ev.event): $($v -join '; ')"
            }
        } finally {
            Remove-Item Function:\Send-CycleEventSafely -ErrorAction SilentlyContinue
            Remove-Variable -Name __RetryEv -Scope Global -ErrorAction SilentlyContinue
        }
    }
    It 'fail-fasts with a retry_exhausted(permanent) when the predicate says not-retryable' {
        $global:__RetryEv = @()
        function global:Send-CycleEventSafely { param($EventRecord) $global:__RetryEv += , $EventRecord }
        try {
            $null = Invoke-WithYurunaRetry -Label 'perm' -MaxAttempts 5 -InitialDelaySeconds 1 `
                -ScriptBlock { $global:LASTEXITCODE = 22; 'nope' } -ShouldRetry { param($x) $null = $x; $false }
            Assert-Equal -Actual $global:__RetryEv.Count -Expected 1 -Because 'fail-fast emits exactly one terminal event'
            Assert-Equal -Actual $global:__RetryEv[0].event -Expected 'retry_exhausted'
            Assert-Equal -Actual $global:__RetryEv[0].permanent -Expected $true
        } finally {
            Remove-Item Function:\Send-CycleEventSafely -ErrorAction SilentlyContinue
            Remove-Variable -Name __RetryEv -Scope Global -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Publish-GuestRetryMarker (guest bash marker -> NDJSON)' {
    It 'parses YURUNA_RETRY markers, emits schema-valid retry_attempt events, and skips malformed lines' {
        $global:__RetryEv = @()
        function global:Send-CycleEventSafely { param($EventRecord) $global:__RetryEv += , $EventRecord }
        try {
            $out = @(
                'Installing PowerShell ...',
                'YURUNA_RETRY {"stack":"bash","label":"curl_retry","attempt":2,"maxAttempts":5,"rc":22,"permanent":false}',
                'some other guest output',
                'YURUNA_RETRY {"stack":"bash","label":"apt_retry","attempt":1,"maxAttempts":5,"rc":100,"permanent":false}',
                'YURUNA_RETRY {bad json here',
                '  YURUNA_RETRY {"stack":"bash","label":"curl_retry","attempt":3,"maxAttempts":5,"rc":6,"permanent":true}'
            )
            $n = Publish-GuestRetryMarker -Output $out -GuestKey 'guest.ubuntu.server.26' -VmName 'test-a'
            Assert-Equal -Actual $n -Expected 3 -Because 'three well-formed markers; the malformed line is skipped'
            Assert-Equal -Actual $global:__RetryEv.Count -Expected 3
            Assert-Equal -Actual $global:__RetryEv[0].event -Expected 'retry_attempt'
            Assert-Equal -Actual $global:__RetryEv[0].stack -Expected 'bash'
            Assert-Equal -Actual $global:__RetryEv[0].description -Expected 'curl_retry'
            Assert-Equal -Actual $global:__RetryEv[0].exitCode -Expected 22
            Assert-Equal -Actual $global:__RetryEv[0].guestKey -Expected 'guest.ubuntu.server.26'
            Assert-Equal -Actual $global:__RetryEv[2].permanent -Expected $true
            foreach ($ev in $global:__RetryEv) {
                $v = @(Test-CycleEventSchema -Record ([hashtable]$ev))
                Assert-Equal -Actual $v.Count -Expected 0 -Because "schema violations: $($v -join '; ')"
            }
        } finally {
            Remove-Item Function:\Send-CycleEventSafely -ErrorAction SilentlyContinue
            Remove-Variable -Name __RetryEv -Scope Global -ErrorAction SilentlyContinue
        }
    }
    It 'returns 0 for null output' {
        function global:Send-CycleEventSafely { param($EventRecord) $null = $EventRecord }
        try { Assert-Equal -Actual (Publish-GuestRetryMarker -Output $null) -Expected 0 }
        finally { Remove-Item Function:\Send-CycleEventSafely -ErrorAction SilentlyContinue }
    }
}
