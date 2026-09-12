<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42f3b7c1-6e04-4a95-b1d8-27a5c9603ef4
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization culture matrix invariant pester
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
    Run the parts that must not care what culture the host is set to, on hosts
    set to six different ones.
.DESCRIPTION
    Almost every locale defect in this project has the same shape: a value that
    should be decided by data is decided instead by the machine the code
    happens to be running on. It never shows up on the machine it was written
    on, which is why it needs a matrix rather than a test.

    The six cultures are the ones the plan names, and each is there for a
    reason. `de-DE` and `pt-BR` swap the decimal and grouping separators.
    `tr-TR` is the dotted-I: upper-casing "i" gives a character that is not
    "I", so any comparison that upper-cases first stops matching. `th-TH` uses
    a non-Gregorian calendar by default. `ar-SA` uses Arabic-Indic digits AND a
    non-Gregorian calendar, and is the one where a wrong parse does not merely
    shift a decimal point -- it fails outright and leaves a zero.

    That last case is worth stating plainly, because it is demonstrated below
    rather than described: `[double]::TryParse('1.5', [ref]$x)` returns 15 on a
    German host and 0 on a Saudi one. A machine value read that way is not
    slightly wrong; it is a different number, and nothing raises.

    Run: Invoke-Pester -Path test/modules/Test.CultureMatrix.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath

Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
# Catalog first: it imports the locale module itself, and importing that one
# afterwards with -Global is what keeps both sets of commands reachable here.
Import-Module (Join-Path $here 'Test.Catalog.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.Locale.psm1') -Force -Global -DisableNameChecking

$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here

# The six the plan names. Each is present because it breaks something a
# different way; none is here for coverage.
$script:Cultures = @('en-US', 'pt-BR', 'de-DE', 'tr-TR', 'th-TH', 'ar-SA')

$script:Manifest = @{
    Default         = 'en-US'
    Supported       = @('en-US', 'pt-BR')
    Aliases         = @{ 'pt' = 'pt-BR'; 'pt-pt' = 'pt-BR' }
    Direction       = @{ 'en-US' = 'ltr'; 'pt-BR' = 'ltr' }
    NumberFormat    = @{ 'en-US' = @{ Group = ','; Decimal = '.'; GroupSize = 3 }
                         'pt-BR' = @{ Group = '.'; Decimal = ','; GroupSize = 3 } }
    PluralRule      = @{ 'en-US' = 'one-if-1' }
    MaxTagLength    = 35
    MaxHeaderLength = 512
}

function Invoke-UnderCulture {
    <#
    .SYNOPSIS
        Run a scriptblock with the thread set to one culture, and put it back.
    .DESCRIPTION
        Both CurrentCulture and CurrentUICulture: the first decides how numbers
        and dates are read and written, the second decides which resources are
        chosen, and a defect can hide behind either.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][string]$Culture, [Parameter(Mandatory)][scriptblock]$Script)

    $thread = [Threading.Thread]::CurrentThread
    $priorCulture = $thread.CurrentCulture
    $priorUi = $thread.CurrentUICulture
    try {
        $ci = [Globalization.CultureInfo]::GetCultureInfo($Culture)
        $thread.CurrentCulture = $ci
        $thread.CurrentUICulture = $ci
        return (& $Script)
    } finally {
        $thread.CurrentCulture = $priorCulture
        $thread.CurrentUICulture = $priorUi
    }
}
}

Describe 'the host culture decides nothing a reader sees' {

    It 'renders every catalog message identically on all six hosts' {
        $findings = @()
        $baseline = $null
        foreach ($culture in $script:Cultures) {
            $rendered = Invoke-UnderCulture -Culture $culture -Script {
                [ordered]@{
                    duration = Format-CatalogMessage -Key 'status.cycle_duration' -Arguments @{ elapsed = 5400 } -Locale 'en-US'
                    count    = Format-CatalogMessage -Key 'status.host_online_count' -Arguments @{ count = 1234567 } -Locale 'en-US'
                    one      = Format-CatalogMessage -Key 'status.host_online_count' -Arguments @{ count = 1 } -Locale 'en-US'
                    decimal  = Format-CatalogNumber -Value 1234.5 -Locale 'en-US' -Decimals 2
                    ptDecimal = Format-CatalogNumber -Value 1234.5 -Locale 'pt-BR' -Decimals 2
                    stamp    = Format-CatalogArgument -Value '2026-09-03T14:05:09Z' -Type 'datetime' -Locale 'en-US'
                }
            }
            if ($null -eq $baseline) { $baseline = $rendered; continue }
            foreach ($key in $baseline.Keys) {
                if ($rendered[$key] -cne $baseline[$key]) {
                    $findings += "$culture rendered $key as '$($rendered[$key])', en-US rendered '$($baseline[$key])'"
                }
            }
        }
        Assert-NoFinding $findings 'the host culture leaked into what a reader is shown'
    }

    It 'resolves a locale identically on all six hosts' {
        # tr-TR is the case that matters here. A comparison that upper-cases
        # before matching turns "i" into a character that is not "I", so a tag
        # like "pt-BR" stops matching itself on exactly one host in the world.
        $findings = @()
        foreach ($culture in $script:Cultures) {
            $got = Invoke-UnderCulture -Culture $culture -Script {
                [ordered]@{
                    canonical = ConvertTo-CanonicalLocaleTag -Tag 'pt_br'
                    resolved  = Resolve-SupportedLocale -Tag 'PT-BR' -Manifest $script:Manifest
                    header    = Select-LocaleFromHeader -Header 'de-DE;q=0.9, pt-BR;q=1.0' -Manifest $script:Manifest
                    refused   = Select-LocaleFromHeader -Header 'pt-BR;q=0, en-US;q=0.5' -Manifest $script:Manifest
                    script    = ConvertTo-CanonicalLocaleTag -Tag 'ZH-HANS-cn'
                }
            }
            if ($got.canonical -ne 'pt-BR') { $findings += "$culture canonicalized pt_br as '$($got.canonical)'" }
            if ($got.resolved -ne 'pt-BR') { $findings += "$culture resolved PT-BR as '$($got.resolved)'" }
            if ($got.header -ne 'pt-BR') { $findings += "$culture read the header as '$($got.header)'" }
            if ($got.refused -ne 'en-US') { $findings += "$culture honored a q=0 refusal as '$($got.refused)'" }
            if ($got.script -ne 'zh-Hans-CN') { $findings += "$culture title-cased the script subtag as '$($got.script)'" }
        }
        Assert-NoFinding $findings 'the host culture changed which language a reader would be served'
    }

    It 'chooses the same plural form on all six hosts' {
        $findings = @()
        foreach ($culture in $script:Cultures) {
            foreach ($pair in @(@{ N = 0; Want = 'other' }, @{ N = 1; Want = 'one' }, @{ N = 2; Want = 'other' })) {
                $got = Invoke-UnderCulture -Culture $culture -Script { Get-PluralCategory -Locale 'en-US' -Count $pair.N }
                if ($got -ne $pair.Want) { $findings += "$culture put $($pair.N) in '$got', not '$($pair.Want)'" }
            }
        }
        Assert-NoFinding $findings 'the host culture changed which plural form a message takes'
    }
}

Describe 'a machine value is read the same on every host' {

    It 'shows why the rule exists: a bare parse is a different number per host' {
        # Demonstrated rather than asserted about, because the size of it is
        # the argument. This is not a defect in the project -- it is the
        # behavior every machine-boundary parse has to be written against.
        $observed = @{}
        foreach ($culture in $script:Cultures) {
            $observed[$culture] = Invoke-UnderCulture -Culture $culture -Script {
                $bare = 0.0
                [void][double]::TryParse('1.5', [ref]$bare)
                return $bare
            }
        }
        Assert-Equal -Expected 1.5 -Actual $observed['en-US'] 'the demonstration is not measuring what it claims'
        Assert-True ($observed['de-DE'] -ne 1.5) `
            'a bare parse no longer differs by host, so this demonstration is stale and the rule should be re-examined'
        Assert-True ($observed['ar-SA'] -eq 0) `
            'the Arabic-Indic case no longer yields a silent zero; re-check what it does now'
    }

    It 'reads a machine value invariantly on all six hosts' {
        $findings = @()
        foreach ($culture in $script:Cultures) {
            $got = Invoke-UnderCulture -Culture $culture -Script {
                $v = 0.0
                $ok = [double]::TryParse('1.5', [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$v)
                return @{ Ok = $ok; Value = $v }
            }
            if (-not $got.Ok) { $findings += "$culture could not parse the machine value at all" }
            if ($got.Value -ne 1.5) { $findings += "$culture read 1.5 as $($got.Value)" }
        }
        Assert-NoFinding $findings 'an invariant parse still depends on the host'
    }

    It 'reads a Prometheus metric identically on all six hosts' {
        # Exposition format fixes the decimal point as a dot regardless of who
        # reads it. Parsed through the host's culture, a healthy fraction of
        # 0.75 becomes 75 -- and the thresholds compare against 1, so a healthy
        # pool reads as alerting and a degraded one can read as fine.
        Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.PoolNotifier.psm1') `
            -Force -Global -DisableNameChecking

        $metrics = @(
            'yuruna_pool_healthy_fraction{pool="default"} 0.75',
            'yuruna_pool_alert_active{pool="default"} 0',
            'yuruna_pool_members_healthy{pool="default"} 3',
            'yuruna_pool_members_total{pool="default"} 4'
        ) -join "`n"

        $findings = @()
        foreach ($culture in $script:Cultures) {
            $got = Invoke-UnderCulture -Culture $culture -Script {
                # Keyed by pool, not a list of rows.
                $parsed = ConvertFrom-PrometheusPoolGauge -MetricsText $metrics
                $row = $parsed['default']
                return @{ Fraction = $row.healthyFraction; Alert = $row.alertActive }
            }
            if ($got.Fraction -ne 0.75) { $findings += "$culture read the healthy fraction as $($got.Fraction), not 0.75" }
            if ($got.Alert -ne $false) { $findings += "$culture read the alert flag as $($got.Alert)" }
        }
        Assert-NoFinding $findings 'a metric value depends on the culture of the host reading it'
    }

    It 'migrates a config factor identically on all six hosts' {
        # The value comes out of a config FILE, so its decimal point is a dot
        # wherever the file was written. Read through the host's culture, "1.5"
        # becomes 15, the migration multiplies THAT by the factor, and writes
        # the result back into a file nobody re-reads.
        $module = Join-Path (Split-Path -Parent $PSCommandPath) 'Test.ConfigNaming.psm1'
        $text = [IO.File]::ReadAllText($module)
        $m = [regex]::Match($text, '(?s)if \(\[int\]\$entry\.Factor -ne 1\) \{.*?
        \}')
        Assert-True $m.Success 'the factor migration is not where this expected it'
        Assert-True ($m.Value -match 'InvariantCulture') `
            'the factor migration reads its value through the host culture'

        # And the arithmetic itself, run under each culture.
        $findings = @()
        foreach ($culture in $script:Cultures) {
            $got = Invoke-UnderCulture -Culture $culture -Script {
                $n = 0.0
                $ok = [double]::TryParse('1.5', [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$n)
                if (-not $ok) { return 'unparsed' }
                return [int][math]::Round($n * 1024)
            }
            if ($got -ne 1536) { $findings += "$culture migrated 1.5 x 1024 to $got, not 1536" }
        }
        Assert-NoFinding $findings 'the migrated value depends on the host that ran the migration'
    }

    It 'leaves no machine-boundary float parse reading the host culture' {
        # The ratchet. An integer parse is safe -- NumberStyles.Integer never
        # consults a separator, which this suite measures rather than assumes --
        # and a PowerShell [double] CAST is invariant. What is not safe is a
        # float TryParse or Parse with no culture named, so those are refused.
        Push-Location $script:RepoRoot
        try { $tracked = @(& git ls-files) } finally { Pop-Location }

        $findings = @()
        foreach ($relative in $tracked) {
            if ($relative -notmatch '\.(ps1|psm1)$') { continue }
            if ($relative -like 'dev-only/*') { continue }
            $full = Join-Path $script:RepoRoot $relative
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            $lines = [IO.File]::ReadAllLines($full)
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $line = $lines[$i]
                if ($line -notmatch '\[(double|decimal|float|single)\]::(Try)?Parse\(') { continue }
                # The culture may be named on this line or the next -- the call
                # is routinely wrapped for width.
                $window = $line
                if ($i + 1 -lt $lines.Count) { $window += "`n" + $lines[$i + 1] }
                if ($i + 2 -lt $lines.Count) { $window += "`n" + $lines[$i + 2] }
                if ($window -match 'InvariantCulture|CurrentCulture|CultureInfo') { continue }
                # This suite's own demonstration of the defect is the exception.
                if ($relative -eq 'test/modules/Test.CultureMatrix.Tests.ps1') { continue }
                $findings += "${relative}:$($i + 1): parses a float without naming a culture -- $($line.Trim())"
            }
        }
        Assert-NoFinding $findings 'a float read from a machine boundary depends on the host that reads it'
    }

    It 'reads the locale manifest identically on all six hosts' {
        # The manifest carries the separators every runtime formats from. If
        # reading it depended on the host, every number in the project would.
        $findings = @()
        $baseline = $null
        foreach ($culture in $script:Cultures) {
            $got = Invoke-UnderCulture -Culture $culture -Script {
                $m = Get-LocaleManifest
                $pt = $m.NumberFormat['pt-BR']
                $sep = "$($pt.Group)$($pt.Decimal)$($pt.GroupSize)"
                $supported = ($m.Supported | Sort-Object) -join ','
                return "$($m.Default)|$supported|$sep|$($m.MaxTagLength)|$($m.PluralRule['en-US'])"
            }
            if ($null -eq $baseline) { $baseline = $got; continue }
            if ($got -cne $baseline) { $findings += "$culture read the manifest as '$got', en-US read '$baseline'" }
        }
        Assert-NoFinding $findings 'the host culture changed what the shared locale table says'
    }
}
