<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42c3a9e8-5b2d-4f17-8a04-1c6d3e5f7a92
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test remediation pester
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
    Pester coverage for Invoke-Remediation's inner-cause routing and the
    enriched handler Context (Test.Remediation.psm1).
.DESCRIPTION
    Throw-based assertions (OS-bundled Pester 3.4 / Pester 5+). Uses the real
    built-in recovery handlers so the routing decision is exercised end to end.
#>

$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.Remediation.psm1'
Import-Module (Join-Path $here 'Test.FailureTaxonomy.psm1') -Force -DisableNameChecking -Global -ErrorAction SilentlyContinue
Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue
if (Get-Command Register-BuiltinRecoveryHandler -ErrorAction SilentlyContinue) { Register-BuiltinRecoveryHandler }

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

Describe 'Invoke-Remediation inner-cause routing' {
    It 'routes past retry_exhausted to the inner failureClass when an inner handler exists' {
        $rec = @{
            failureClass = 'retry_exhausted'; severity = 'hard'
            innerFailureClass = 'ocr_timeout'; innerSeverity = 'hard'
            innerSuggestedRecoveries = @('reconnect')
            stepNumber = 3; actionVerb = 'retry'
        }
        $r = Invoke-Remediation -FailureRecord $rec
        Assert-Equal -Expected 'ocr_timeout' -Actual $r.FailureClass -Because 'routed to inner class'
        Assert-Equal -Expected 'retry_exhausted' -Actual $r.RoutedFromFailureClass -Because 'outer class preserved'
    }
    It 'stays on the outer class when no inner cause is present' {
        $r = Invoke-Remediation -FailureRecord @{ failureClass = 'retry_exhausted'; severity = 'hard'; stepNumber = 1; actionVerb = 'retry' }
        Assert-Equal -Expected 'retry_exhausted' -Actual $r.FailureClass -Because 'no inner -> outer'
        Assert-True (-not $r.Contains('RoutedFromFailureClass')) 'no routing audit when not routed'
    }
    It 'leaves a non-retry failure class untouched' {
        $r = Invoke-Remediation -FailureRecord @{ failureClass = 'ocr_timeout'; severity = 'hard'; stepNumber = 2 }
        Assert-Equal -Expected 'ocr_timeout' -Actual $r.FailureClass -Because 'plain class unchanged'
    }
    It 'severity follows the routed class (unknown, not the outer value) when innerSeverity is absent' {
        $r = Invoke-Remediation -FailureRecord @{ failureClass = 'retry_exhausted'; severity = 'soft'; innerFailureClass = 'ocr_timeout'; stepNumber = 3 }
        Assert-Equal -Expected 'ocr_timeout' -Actual $r.FailureClass -Because 'routed to inner class'
        Assert-Equal -Expected 'unknown' -Actual $r.Severity -Because 'severity must NOT inherit the outer wrapper value'
    }
    It 'does not self-route when the inner class equals the outer class' {
        $r = Invoke-Remediation -FailureRecord @{ failureClass = 'retry_exhausted'; severity = 'hard'; innerFailureClass = 'retry_exhausted'; stepNumber = 1 }
        Assert-Equal -Expected 'retry_exhausted' -Actual $r.FailureClass -Because 'inner==outer stays outer'
        Assert-True (-not $r.Contains('RoutedFromFailureClass')) 'no misleading routed-audit when inner==outer'
    }
}

Describe 'Invoke-Remediation forwards the enriched Context' {
    It 'returns a recommendation in the canonical vocabulary for an enriched record' {
        $rec = @{
            failureClass = 'ocr_timeout'; severity = 'hard'; stepNumber = 4; actionVerb = 'waitForText'
            sequenceName = 'wl.test'
            repro = @{ command = 'pwsh test/Test-Sequence.ps1 -SequenceName "wl.test"' }
            context = @{ sequencePath = 'x/wl.test.yml'; matchedFailurePattern = 'kernel panic' }
        }
        $vocab = @(Get-RecoveryRecommendationName)
        $r = Invoke-Remediation -FailureRecord $rec
        Assert-True ($vocab -contains [string]$r.Recommendation) "recommendation '$($r.Recommendation)' in canonical vocabulary"
    }
}

Describe 'Invoke-Remediation persists last_remediation.json' {
    It 'writes the durable decision record into YURUNA_LOG_DIR' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "yrn-remediation-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $savedLogDir = $env:YURUNA_LOG_DIR
        try {
            $env:YURUNA_LOG_DIR = $tmp
            $rec = @{
                failureClass = 'ocr_timeout'; severity = 'hard'; stepNumber = 4
                actionVerb = 'waitForText'; sequenceName = 'wl.test'; vmName = 'vm1'; guestKey = 'guest.x'
            }
            $r = Invoke-Remediation -FailureRecord $rec
            $path = Join-Path $tmp 'last_remediation.json'
            Assert-True (Test-Path -LiteralPath $path) 'last_remediation.json written to the log dir'
            $doc = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
            Assert-Equal -Expected 1 -Actual $doc.schemaVersion -Because 'schema-versioned record'
            Assert-Equal -Expected 'ocr_timeout' -Actual $doc.failureClass -Because 'failureClass captured'
            Assert-Equal -Expected ([string]$r.Recommendation) -Actual ([string]$doc.recommendation) -Because 'recommendation matches the returned decision'
            Assert-Equal -Expected 'vm1' -Actual $doc.vmName -Because 'correlation field captured'
            Assert-Equal -Expected $false -Actual $doc.autoApply -Because 'advisory-only: autoApply stays false'
            # No BOM: the first byte must be the JSON open-brace, not EF BB BF.
            $bytes = [System.IO.File]::ReadAllBytes($path)
            Assert-True ($bytes[0] -ne 0xEF) 'record is written without a UTF-8 BOM'
        } finally {
            $env:YURUNA_LOG_DIR = $savedLogDir
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'records the outer class when routing past a retry wrapper' {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "yrn-remediation-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $tmp -Force
        $savedLogDir = $env:YURUNA_LOG_DIR
        try {
            $env:YURUNA_LOG_DIR = $tmp
            $null = Invoke-Remediation -FailureRecord @{ failureClass = 'retry_exhausted'; severity = 'hard'; innerFailureClass = 'ocr_timeout'; stepNumber = 3 }
            $doc = Get-Content -Raw -LiteralPath (Join-Path $tmp 'last_remediation.json') | ConvertFrom-Json
            Assert-Equal -Expected 'ocr_timeout' -Actual $doc.failureClass -Because 'routed inner class recorded'
            Assert-Equal -Expected 'retry_exhausted' -Actual $doc.outerFailureClass -Because 'masked outer class preserved in the record'
        } finally {
            $env:YURUNA_LOG_DIR = $savedLogDir
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-Remediation routes the infra-stage failure classes' {
    It 'routes provisioning_failure to retry_with_backoff (transient host provisioning)' {
        $r = Invoke-Remediation -FailureRecord @{ failureClass = 'provisioning_failure'; severity = 'hard'; vmName = 'vm1' }
        Assert-Equal -Expected 'retry_with_backoff' -Actual $r.Recommendation -Because 'provisioning is retryable'
    }
    It 'routes bootstrap_sync and plan_invalid to operator_intervention_required' {
        $r1 = Invoke-Remediation -FailureRecord @{ failureClass = 'bootstrap_sync'; severity = 'hard'; vmName = '(bootstrap)' }
        Assert-Equal -Expected 'operator_intervention_required' -Actual $r1.Recommendation -Because 'git divergence needs an operator'
        $r2 = Invoke-Remediation -FailureRecord @{ failureClass = 'plan_invalid'; severity = 'hard'; vmName = '(planner)' }
        Assert-Equal -Expected 'operator_intervention_required' -Actual $r2.Recommendation -Because 'plan errors need an operator'
    }
    It 'has a registered handler for every canonical FailureClass (no unrouted class)' {
        $enum = @(Get-FailureClassEnum)
        $registered = @(Get-RegisteredFailureClass)
        $missing = @($enum | Where-Object { $registered -notcontains $_ })
        Assert-Equal -Expected 0 -Actual $missing.Count -Because "every enum class must have a handler; missing: $($missing -join ', ')"
    }
}

Describe 'Invoke-Remediation guards a parsed-but-non-object last_failure.json' {
    # A last_failure.json that is valid JSON but not an object (a bare string /
    # number / array, or most subtly a literal `null`) must route to the
    # parse-error fallback, never NRE at the first .Contains(). The `null` case
    # is the load-bearing one: the [hashtable] parameter type coerces-and-throws
    # for the scalar/array cases, but a JSON `null` assigns cleanly as $null and
    # would otherwise reach .Contains() on a $null record.

    It 'routes a JSON null last_failure.json to the parse-error fallback without throwing' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "yrn-rem-nonobj-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $dir -Force
        try {
            $lf = Join-Path $dir 'last_failure.json'
            Set-Content -LiteralPath $lf -Value 'null' -Encoding utf8
            $r = Invoke-Remediation -LastFailurePath $lf
            Assert-Equal -Expected '(parse-error fallback)' -Actual ([string]$r.HandledBy) -Because 'a JSON null must route to the fallback, not throw at .Contains() on $null'
            Assert-Equal -Expected 'operator_intervention_required' -Actual ([string]$r.Recommendation) -Because 'the parse-error fallback recommends operator intervention'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'routes valid-but-non-object JSON (string / number / array) to the parse-error fallback' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "yrn-rem-nonobj-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $dir -Force
        try {
            $lf = Join-Path $dir 'last_failure.json'
            foreach ($content in @('"a string"', '42', '[1,2,3]')) {
                Set-Content -LiteralPath $lf -Value $content -Encoding utf8
                $r = Invoke-Remediation -LastFailurePath $lf
                Assert-Equal -Expected '(parse-error fallback)' -Actual ([string]$r.HandledBy) -Because "non-object JSON ($content) must route to the fallback"
            }
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'still reads a valid JSON-object last_failure.json normally' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) "yrn-rem-nonobj-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $dir -Force
        try {
            $lf = Join-Path $dir 'last_failure.json'
            Set-Content -LiteralPath $lf -Value '{"failureClass":"ocr_timeout","severity":"hard","stepNumber":2}' -Encoding utf8
            $r = Invoke-Remediation -LastFailurePath $lf
            Assert-Equal -Expected 'ocr_timeout' -Actual ([string]$r.FailureClass) -Because 'a real object is parsed and classified normally'
            Assert-True ([string]$r.HandledBy -ne '(parse-error fallback)') 'a valid object does NOT hit the parse-error fallback'
        } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
