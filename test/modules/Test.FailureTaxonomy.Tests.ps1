<#PSScriptInfo
.VERSION 2026.10.31
.GUID 42e7a0f2-fce5-47f4-aa02-059ecae18abf
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test telemetry failure-taxonomy pester
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
    Pester guard for the canonical FailureClass/Severity taxonomy: the three
    sources (Test.FailureTaxonomy canonical arrays, Test.EventSchema validator
    enum, Test.SequenceAction Register-SequenceAction ValidateSet) must stay
    identical, so a future class can never silently drift between them.
.DESCRIPTION
    Throw-based assertions (Pester 5+).
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.FailureTaxonomy.psm1') -Force -DisableNameChecking -Global -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.EventSchema.psm1')     -Force -DisableNameChecking -Global -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.SequenceAction.psm1')  -Force -DisableNameChecking -Global -ErrorAction SilentlyContinue

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

}

Describe 'Test.FailureTaxonomy canonical arrays' {
    It 'returns the FailureClass values (includes the infra classes) and Severity values' {
        $fc = Get-FailureClassEnum
        Assert-True ($fc -contains 'ocr_timeout') 'has a known guest class'
        Assert-True ($fc -contains 'provisioning_failure') 'has the infra provisioning class'
        Assert-True ($fc -contains 'bootstrap_sync') 'has the infra bootstrap class'
        Assert-True ($fc -contains 'plan_invalid') 'has the infra plan class'
        Assert-True ($fc -contains 'hypervisor_unresponsive') 'has the hung hypervisor control-channel class'
        Assert-True ($fc -contains 'source_integrity') 'has the authenticated source-integrity class'
        Assert-True ($fc[-1] -eq 'unknown') "'unknown' stays last as the catch-all"
        Assert-Equal -Expected 'hard|soft|unknown' -Actual ((Get-SeverityEnum) -join '|') -Because 'severity set'
    }

    It 'keeps the network-only refusal set distinct from authentication and integrity' {
        foreach ($class in @((Get-FailureClassEnum)) + @('', 'future_failure')) {
            Test-TransientNetworkFailureClass -FailureClass $class | Should -Be ($class -cin @('network_timeout','host_network_degraded'))
        }
    }

    It 'documents every failure class at a unique dashboard-link destination' {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $classes = @(Get-FailureClassEnum | Sort-Object)
        foreach ($relativePath in @('docs/failure-schema.md', 'docs/pt-BR/failure-schema.md')) {
            $document = Get-Content -Raw -LiteralPath (Join-Path $repoRoot $relativePath)
            $rows = [regex]::Matches($document, '(?m)^\| <a id="failure-class-([a-z_]+)"></a>`\1` \| (.+?) \| (.+?) \|\r?$')
            $documented = @($rows | ForEach-Object { $_.Groups[1].Value } | Sort-Object)
            Assert-Equal -Expected ($classes -join '|') -Actual ($documented -join '|') `
                -Because "$relativePath must give every canonical class one linked meaning and first check"
            foreach ($class in $classes) {
                $anchor = 'id="failure-class-' + $class + '"'
                Assert-Equal -Expected 1 -Actual ([regex]::Matches($document, [regex]::Escape($anchor)).Count) `
                    -Because "$relativePath must resolve the $class link to exactly one destination"
            }
        }
    }
}

Describe 'Assert-FailureTaxonomyInSync' {
    It 'returns true for a matching copy and false (with a warning) for a drifted one' {
        $fc = Get-FailureClassEnum
        $sev = Get-SeverityEnum
        Assert-True (Assert-FailureTaxonomyInSync -Source 't' -FailureClass $fc -Severity $sev -WarningAction SilentlyContinue) 'identical -> in sync'
        Assert-False (Assert-FailureTaxonomyInSync -Source 't' -FailureClass ($fc + 'bogus') -Severity $sev -WarningAction SilentlyContinue) 'extra value -> drift'
        Assert-False (Assert-FailureTaxonomyInSync -Source 't' -FailureClass $fc -Severity @('hard') -WarningAction SilentlyContinue) 'short severity -> drift'
        # Reordered list is also flagged (order-sensitive).
        $reordered = @($fc[1], $fc[0]) + $fc[2..($fc.Count-1)]
        Assert-False (Assert-FailureTaxonomyInSync -Source 't' -FailureClass $reordered -Severity $sev -WarningAction SilentlyContinue) 'reordered -> drift'
    }
}

Describe 'taxonomy single-source invariant (the three lists are identical)' {
    It 'imports the sequence registry repeatedly without a false taxonomy warning' {
        $path = (Join-Path $PSScriptRoot 'Test.SequenceAction.psm1').Replace("'", "''")
        $command = "foreach (`$attempt in 1..3) { Import-Module '$path' -Force -DisableNameChecking }"
        $output = & ([Environment]::ProcessPath) -NoProfile -NonInteractive -Command $command *>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $output
        $output.Trim() | Should -BeExactly ''
    }
    It 'EventSchema enum == canonical' {
        Assert-Equal -Expected ((Get-FailureClassEnum) -join '|') -Actual ((Get-CycleEventSchemaDescriptor).FailureClassEnum -join '|') -Because 'EventSchema must derive from the canonical set'
        Assert-Equal -Expected ((Get-SeverityEnum) -join '|') -Actual ((Get-CycleEventSchemaDescriptor).SeverityEnum -join '|') -Because 'EventSchema severity must derive from the canonical set'
    }
    It 'Register-SequenceAction ValidateSet == canonical (the literal copy has not drifted)' {
        $vs = (Get-Command Register-SequenceAction).Parameters['FailureClass'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
            ForEach-Object { $_.ValidValues }
        Assert-Equal -Expected ((Get-FailureClassEnum) -join '|') -Actual ($vs -join '|') -Because 'the ValidateSet literal must match the canonical set'
    }
    It 'the Register-SequenceAction reference table lists the canonical classes in order' {
        $doc = Join-Path $here '../../docs/test-sequences.md'
        $row = @(Get-Content -LiteralPath $doc | Where-Object { $_.StartsWith('| `FailureClass`', [StringComparison]::Ordinal) })
        Assert-Equal -Expected 1 -Actual $row.Count -Because 'the parameter table has one FailureClass row'
        $listed = @([regex]::Matches(($row[0] -split '\|')[2], '`([a-z_]+)`') | ForEach-Object { $_.Groups[1].Value })
        Assert-Equal -Expected ((Get-FailureClassEnum) -join '|') -Actual ($listed -join '|') -Because 'the table is what authors read to pick a class'
    }
}

# The unattended-retry allow-list, the warm-resume list and the network check
# each kept their own copy of the classes they admit, and the copies had
# drifted apart with nothing to say which difference was meant.
Describe 'The class routing table is the one place a class is routed' {
    BeforeAll {
        Import-Module (Join-Path $here 'Test.Remediation.psm1') -Force -DisableNameChecking -Global -ErrorAction SilentlyContinue
        Import-Module (Join-Path $here 'Test.WarmResume.psm1') -Force -DisableNameChecking -Global -ErrorAction SilentlyContinue
    }
    It 'routes only classes the enum defines' {
        $enum = @(Get-FailureClassEnum)
        foreach ($route in 'UnattendedRetry', 'WarmResume', 'TransientNetwork') {
            foreach ($class in @(Get-FailureClassByRoute -Route $route)) {
                Assert-True ($enum -ccontains $class) "$class ($route) is a canonical class"
            }
        }
        $none = Get-FailureClassRoute -FailureClass 'never_classified'
        Assert-False ($none.UnattendedRetry -or $none.WarmResume -or $none.TransientNetwork) 'an unrouted class has no routing attribute'
    }
    It 'gives every class a runner-minute budget for unattended retries' {
        foreach ($class in @(Get-FailureClassEnum) + 'never_classified') {
            $budget = (Get-FailureClassRoute -FailureClass $class).RetryMinutesPerDay
            Assert-True ($budget -is [int] -and $budget -gt 0) "$class has a positive budget ($budget)"
        }
        Assert-Equal -Expected 180 -Actual (Get-FailureClassRoute -FailureClass 'wait_timeout').RetryMinutesPerDay -Because 'the default'
    }
    It 'is what the unattended-retry allow-list admits, each with its reason' {
        $allowList = Get-AutoRemediationAllowList
        Assert-Equal -Expected ((Get-FailureClassByRoute -Route UnattendedRetry) -join ',') -Actual (@($allowList.Keys) -join ',')
        foreach ($class in @($allowList.Keys)) {
            Assert-False ([string]::IsNullOrWhiteSpace([string]$allowList[$class])) "$class records why it qualifies"
        }
    }
    It 'is what warm resume admits, and what the network check calls transient' {
        Assert-Equal -Expected ((Get-FailureClassByRoute -Route WarmResume) -join ',') -Actual ((Get-WarmResumeEligibleClass) -join ',')
        foreach ($class in @(Get-FailureClassEnum)) {
            Assert-Equal -Expected ((Get-FailureClassRoute -FailureClass $class).TransientNetwork) -Actual (Test-TransientNetworkFailureClass -FailureClass $class) -Because $class
        }
    }
    It 'leaves no class list in the modules that consume it' {
        $enum = @(Get-FailureClassEnum)
        foreach ($module in 'Test.Remediation.psm1', 'Test.WarmResume.psm1') {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $here $module), [ref]$null, [ref]$null)
            $lists = @($ast.FindAll({ param($n)
                ($n -is [System.Management.Automation.Language.ArrayLiteralAst] -and
                    @($n.Elements | Where-Object { $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $enum -ccontains $_.Value }).Count -ge 2) }, $true))
            Assert-Equal -Expected 0 -Actual $lists.Count -Because "$module asks the taxonomy instead of listing classes"
        }
    }
}

# retry_exhausted says only that the retries ran out; the inner class says
# what kept failing, and only the dispatcher looked at it.
Describe 'Resolve-RoutingClass' {
    It 'routes <Class> with inner <Inner> as <Expected>' -TestCases @(
        @{ Class = 'retry_exhausted'; Inner = 'wait_timeout'; Expected = 'wait_timeout'; Wrapped = $true }
        @{ Class = 'retry_exhausted'; Inner = ''; Expected = 'retry_exhausted'; Wrapped = $false }
        @{ Class = 'retry_exhausted'; Inner = 'never_classified'; Expected = 'retry_exhausted'; Wrapped = $false }
        @{ Class = 'retry_exhausted'; Inner = 'retry_exhausted'; Expected = 'retry_exhausted'; Wrapped = $false }
        @{ Class = 'ocr_timeout'; Inner = 'wait_timeout'; Expected = 'ocr_timeout'; Wrapped = $false }
    ) {
        param($Class, $Inner, $Expected, $Wrapped)
        $routing = Resolve-RoutingClass -FailureClass $Class -InnerFailureClass $Inner
        Assert-Equal -Expected $Expected -Actual $routing.RoutingClass
        Assert-Equal -Expected $Wrapped -Actual $routing.Wrapped
        Assert-Equal -Expected $Class -Actual $routing.FailureClass -Because 'the recorded class is kept'
    }
}


Describe 'Get-FailureClassDocUrl' {
    It 'names each canonical class''s own anchor in the failure schema' {
        $doc = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'docs/failure-schema.md'))
        # Joined from parts: a literal link with a placeholder for its anchor
        # reads to the anchor gate as a broken pointer.
        $schema = 'https://yuruna.link/42820e91'
        foreach ($class in @(Get-FailureClassEnum)) {
            $url = Get-FailureClassDocUrl -FailureClass $class
            $url | Should -BeExactly ($schema + '#failure-class-' + $class)
            $doc.Contains("<a id=`"failure-class-$class`"></a>") | Should -BeTrue -Because "the link for $class must land on its row"
        }
    }
    It 'falls back to the schema for a value the taxonomy does not name' {
        Get-FailureClassDocUrl -FailureClass 'not_a_class' | Should -BeExactly 'https://yuruna.link/42820e91'
        Get-FailureClassDocUrl -FailureClass '' | Should -BeExactly 'https://yuruna.link/42820e91'
    }
}
