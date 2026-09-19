<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42c62d9b-08f7-4e13-a5c4-91b7de306f28
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization diagnostic class schema pester
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
    Hold the diagnostic classifier to reading a value rather than a sentence,
    and pin the shape of the document it produces.
.DESCRIPTION
    The sidecar's `class` is what a consumer groups and counts by, so it is a
    machine contract even though it sits beside prose. Every call must supply
    that value explicitly. Deriving it from a leading upper-case word makes the
    sentence the contract: reword the message and the class changes, translate
    it and the class disappears.

    Run: Invoke-Pester -Path test/modules/Test.DiagnosticClass.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Diagnostic = Join-Path $script:RepoRoot 'automation/Get-SystemDiagnostic.ps1'

# The classifier is lifted out of the script rather than reached by running it:
# dot-sourcing would execute the whole diagnostic.
function Get-DiagnosticFunction {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Name IS used -- inside the FindAll predicate scriptblock, which the analyzer does not follow.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Diagnostic, [ref]$null, [ref]$null)
    $found = $ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
        }, $true) | Select-Object -First 1
    if (-not $found) { return '' }
    return $found.Extent.Text
}

# A harness that gives Add-Problem the two collections it writes into, so the
# real function can be called and its records read back.
$script:Harness = @'
$script:Problems = [System.Collections.Generic.List[string]]::new()
$script:ProblemRecords = [System.Collections.Generic.List[object]]::new()
'@
}

Describe 'a diagnostic class is a value, not a reading of a sentence' {

    It 'takes an explicit class over anything the message says' {
        $fn = Get-DiagnosticFunction -Name 'Add-Problem'
        Assert-True ([bool]$fn) 'the diagnostic script has no Add-Problem'
        $run = [scriptblock]::Create($script:Harness + "`n" + $fn + @'

Add-Problem "DISK: something entirely different" -Class 'SWIFT'
$script:ProblemRecords[0].class
'@)
        Assert-StringEqual -Expected 'SWIFT' -Actual ([string](& $run)) `
            'an explicit class must win; otherwise passing one is decoration'
    }

    It 'requires a class instead of deriving one from prose' {
        $fn = Get-DiagnosticFunction -Name 'Add-Problem'
        Assert-Match '(?s)\[Parameter\(Mandatory\)\].*\$Class' $fn `
            'a caller must not be able to omit the machine class'
        Assert-False ($fn -match '-c?match|\$Matches') `
            'Add-Problem still appears to derive a class from message text'
    }

    It 'passes an explicit class at every diagnostic call site' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $script:Diagnostic, [ref]$null, [ref]$null)
        $findings = @()
        $calls = @($ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.CommandAst] -and
                    $n.GetCommandName() -eq 'Add-Problem'
                }, $true))
        foreach ($call in $calls) {
            $hasClass = @($call.CommandElements | Where-Object {
                    $_ -is [System.Management.Automation.Language.CommandParameterAst] -and
                    $_.ParameterName -eq 'Class'
                }).Count -gt 0
            if (-not $hasClass) {
                $findings += "line $($call.Extent.StartLineNumber): $($call.Extent.Text)"
            }
        }
        Assert-True ($calls.Count -gt 40) 'the scan did not find the real diagnostic call sites'
        Assert-NoFinding $findings 'a diagnostic class is still being recovered from prose'
    }
}

Describe 'the cache is classified from its metrics, not from its health page' {

    It 'reads names, labels and values and ignores the descriptive lines' {
        $fn = Get-DiagnosticFunction -Name 'Get-PrometheusReading'
        Assert-True ([bool]$fn) 'the diagnostic script has no Prometheus reader'
        $run = [scriptblock]::Create($fn + @'

$text = @"
# HELP yuruna_zot_manifest_ok whether the canary answered
# TYPE yuruna_zot_manifest_ok gauge
yuruna_zot_manifest_ok 0
yuruna_zot_manifest_latency_seconds{repo="a/b",tag="v1"} 12.5
yuruna_prewarm_images_resident{set="k8s"} 3
"@
$r = Get-PrometheusReading -Text $text
"{0}|{1}|{2}|{3}" -f $r.Keys.Count, $r['yuruna_zot_manifest_ok'][0].Value,
    $r['yuruna_zot_manifest_latency_seconds'][0].Labels['repo'],
    $r['yuruna_prewarm_images_resident'][0].Labels['set']
'@)
        Assert-StringEqual -Expected '3|0|a/b|k8s' -Actual ([string](& $run)) `
            -Because 'HELP and TYPE lines describe a series and carry no reading'
    }

    It 'answers null for a metric the cache did not publish' {
        # Zero and absent are different findings. A cache that could not read
        # the upstream budget publishes no budget reading, and calling that
        # "0 left" reports an exhausted budget on every cache that never asked.
        $run = [scriptblock]::Create((Get-DiagnosticFunction -Name 'Get-PrometheusReading') + "`n" +
            (Get-DiagnosticFunction -Name 'Get-PrometheusValue') + @'

$r = Get-PrometheusReading -Text "yuruna_dockerhub_ratelimit_limit 100"
$absent = Get-PrometheusValue -Reading $r -Name 'yuruna_dockerhub_ratelimit_remaining'
$present = Get-PrometheusValue -Reading $r -Name 'yuruna_dockerhub_ratelimit_limit'
"{0}|{1}" -f $(if ($null -eq $absent) { 'null' } else { $absent }), $present
'@)
        Assert-StringEqual -Expected 'null|100' -Actual ([string](& $run)) `
            -Because 'an unpublished reading must not read as zero'
    }

    It 'classifies from the metric document and never from the health page' {
        # Both documents come from one exporter. The page is written for a
        # person opening it during an incident, so its wording is free to
        # change and to be translated; a check that recognized a sentence
        # there would go quiet on the day someone improved it -- and go quiet
        # by reporting nothing wrong.
        $source = [IO.File]::ReadAllText($script:Diagnostic)
        Assert-Match 'Get-PrometheusReading -Text \$metaText' $source `
            'the cache section must classify from the metric document'
        Assert-False ($source -match '\$healthText\s+-c?match') `
            'a reading of the health page is a reading of a sentence'
        foreach ($metric in @('yuruna_zot_manifest_ok', 'yuruna_zot_manifest_ok_under_client_patience',
                'yuruna_prewarm_images_resident', 'yuruna_dockerhub_ratelimit_probe_ok')) {
            Assert-Match ([regex]::Escape($metric)) $source `
                "the classification must name the $metric reading it depends on"
        }
    }
}

Describe 'the sidecar document has a shape a consumer can rely on' {

    It 'declares a schema and keeps the fields that name it' {
        $fn = Get-DiagnosticFunction -Name 'Get-ProblemJson'
        Assert-True ([bool]$fn) 'the diagnostic script has no Get-ProblemJson'
        foreach ($field in @('schema', 'count', 'byClass', 'problems')) {
            Assert-True ($fn -match "(?m)^\s*$field\s*=") "the document declares no '$field'"
        }
        Assert-True ($fn -match "yuruna\.diagnostic\.problems/v\d+") 'the document carries no versioned schema id'
    }

    It 'produces a document that parses and tallies what it lists' {
        $add = Get-DiagnosticFunction -Name 'Add-Problem'
        $build = Get-DiagnosticFunction -Name 'Get-ProblemJson'
        $run = [scriptblock]::Create($script:Harness + "`n" + $add + "`n" + $build + @'

Add-Problem "DISK: one" -Class 'DISK.high-usage'
Add-Problem "DISK: two" -Class 'DISK.high-usage'
Add-Problem "CPU: three" -Class 'CPU.high-load'
Add-Problem "no prefix" -Class 'DIAG.other'
Get-ProblemJson
'@)
        $doc = ConvertFrom-Json -InputObject ([string](& $run))
        Assert-StringEqual -Expected 'yuruna.diagnostic.problems/v1' -Actual $doc.schema 'the schema id changed'
        Assert-Equal -Expected 4 -Actual $doc.count 'the count does not match what was added'
        Assert-Equal -Expected 2 -Actual $doc.byClass.'DISK.high-usage' 'the disk tally is wrong'
        Assert-Equal -Expected 1 -Actual $doc.byClass.'CPU.high-load' 'the CPU tally is wrong'
        Assert-Equal -Expected 1 -Actual $doc.byClass.'DIAG.other' 'the explicit catch-all tally is wrong'
        Assert-Equal -Expected 4 -Actual @($doc.problems).Count 'the record list does not match the count'

        # The tallies have to be a partition of the records, or a consumer
        # summing byClass gets a different total from the list beside it.
        $summed = 0
        foreach ($p in $doc.byClass.PSObject.Properties) { $summed += [int]$p.Value }
        Assert-Equal -Expected $doc.count -Actual $summed 'the per-class tallies do not sum to the count'
    }

    It 'keeps the sentinels a consumer slices the document out with' {
        $text = [IO.File]::ReadAllText($script:Diagnostic)
        foreach ($marker in @('===YURUNA-DIAG-JSON-BEGIN===', '===YURUNA-DIAG-JSON-END===')) {
            Assert-True ($text.Contains($marker)) "the sentinel '$marker' is gone; a consumer cannot find the document"
        }
    }
}
