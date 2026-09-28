<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42c43b4f-9392-49b0-a0ce-755a0560f4cd
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test tooling culture utf8 performance pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fixture parameters are consumed by lifted production expressions.')]
[CmdletBinding()]
param()

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    function Get-ToolingAst {
        param([string]$Path)
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        if ($errors) { throw ($errors -join "`n") }
        return $ast
    }
}

Describe 'machine timestamps are independent of host culture' {
    BeforeAll {
        $script:TimestampCalls = [Collections.Generic.List[object]]::new()
        $files = @(& git -C $script:RepoRoot ls-files -- '*.ps1' '*.psm1' | Where-Object {
            $_ -notlike '*.Tests.ps1' -and $_ -notlike 'globalization/*' -and $_ -notlike 'dev-only/review.history/*'
        })
        foreach ($file in $files) {
            $ast = Get-ToolingAst (Join-Path $script:RepoRoot $file)
            foreach ($call in $ast.FindAll({ param($n)
                $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
                $n.Member.Value -eq 'ToString' -and $n.Arguments.Count -gt 0 -and
                $n.Arguments[0] -is [Management.Automation.Language.StringConstantExpressionAst] -and
                $n.Arguments[0].Value -like '*yyyy-MM-dd*'
            }, $true)) {
                $script:TimestampCalls.Add(@{File=$file; Line=$call.Extent.StartLineNumber; Call=$call})
            }
        }
    }
    It 'supplies invariant culture to every owned custom ISO-style timestamp' {
        $script:TimestampCalls.Count | Should -BeGreaterThan 100
        $missing = @($script:TimestampCalls | Where-Object { $_.Call.Arguments.Count -lt 2 -or $_.Call.Arguments[1].Extent.Text -notmatch '::InvariantCulture$' })
        @($missing | ForEach-Object { "$($_.File):$($_.Line) $($_.Call.Extent.Text)" }) | Should -BeNullOrEmpty
    }
    It 'preserves Gregorian dates and colon separators under <Culture>' -TestCases @(
        @{Culture='da-DK'}, @{Culture='fi-FI'}, @{Culture='fa-IR'}, @{Culture='th-TH'}, @{Culture='ar-SA'}, @{Culture='en-US'}
    ) {
        param($Culture)
        $prior = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($Culture)
            $instant = [datetime]::new(2026,9,27,12,34,56,[DateTimeKind]::Utc)
            foreach ($row in $script:TimestampCalls) {
                $arguments = ($row.Call.Arguments | ForEach-Object { $_.Extent.Text }) -join ', '
                $expression = [scriptblock]::Create('$when.ToString(' + $arguments + ')')
                $actual = & { param($when); & $expression } $instant
                $expected = $instant.ToString($row.Call.Arguments[0].Value, [Globalization.CultureInfo]::InvariantCulture)
                $actual | Should -BeExactly $expected -Because "$($row.File):$($row.Line) must be stable under $Culture"
                if ($row.Call.Arguments[0].Value -match 'HH:mm:ss' -and $actual -match 'Z$') {
                    [DateTimeOffset]::Parse($actual, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime | Should -Be $instant
                }
            }
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $prior }
    }
}

Describe 'UTF-8 gate control scanning matches character semantics' {
    BeforeAll {
        $ast = Get-ToolingAst (Join-Path $script:RepoRoot tools/Test-Utf8Catalog.ps1)
        $constants = $ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -in @('$BidiOpen','$BidiClose','$BidiControl')}, $true)
        $scan = $ast.Find({param($n) $n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Condition.Extent.Text -match '\[regex\]::Matches'}, $true)
        $script:ScanBody = [scriptblock]::Create(($constants.Extent.Text -join "`n") + "`n" + $scan.Extent.Text)
        function Get-ScanResult {
            param([string]$text, [switch]$Reference)
            $problems = [Collections.Generic.List[string]]::new()
            $depth = 0
            if ($Reference) {
                for ($i=0; $i -lt $text.Length; $i++) {
                    $code = [int]$text[$i]
                    if ($code -in @(0x202A,0x202B,0x202D,0x202E,0x2066,0x2067,0x2068)) { $depth++; continue }
                    if ($code -in @(0x202C,0x2069)) { $depth--; continue }
                    if ($code -lt 32 -and $code -notin @(9,10,13)) {
                        $problems.Add(('carries control character U+{0:X4} at index {1}' -f $code,$i)); break
                    }
                }
            } else { . $script:ScanBody }
            return @{Depth=$depth;Problems=@($problems)} | ConvertTo-Json -Compress
        }
    }
    It 'matches all control codes, bidi controls, nested isolates, and ordinary Unicode' {
        $cases = [Collections.Generic.List[string]]::new()
        foreach ($code in (0..31) + (0x200E..0x200F) + (0x202A..0x202E) + (0x2066..0x2069)) {
            $cases.Add('prefix' + [char]$code + 'tail')
            $cases.Add([char]0x2066 + 'prefix' + [char]$code + [char]0x2069)
        }
        $cases.Add("`u{2066}a`u{2067}b`u{2069}c`u{2069}")
        $cases.Add("plain `u{00E9} `u{0627} `u{4E2D} `u{1F680}`n`t")
        $cases.Add('ordinary text ' * 10000)
        foreach ($text in $cases) { Get-ScanResult $text | Should -BeExactly (Get-ScanResult $text -Reference) }
    }
}

Describe 'performance asset enumeration preserves the registry inputs' {
    BeforeAll {
        $ast = Get-ToolingAst (Join-Path $script:RepoRoot tools/Invoke-PerfBaseline.ps1)
        $loop = $ast.Find({param($n) $n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Variable.Extent.Text -eq '$file' -and $n.Condition.Extent.Text -like '*Get-ChildItem*'}, $true)
        $script:AssetExpression = [scriptblock]::Create($loop.Condition.Extent.Text)
    }
    It 'matches Include for every registered root and a mixed-name fixture' {
        $fixture = Join-Path $TestDrive 'assets with spaces'
        $null = New-Item -ItemType Directory $fixture, (Join-Path $fixture hidden), (Join-Path $fixture '.hidden') -Force
        foreach ($name in @('a.js','A.JS','g.Css','a[1].js','.dot.js','ignore.json','ignore.cssx','hidden/nested.css','.hidden/nested.js')) {
            Set-Content -LiteralPath (Join-Path $fixture $name) -Value fixture
        }
        $registry = Get-Content -Raw (Join-Path $script:RepoRoot globalization/manifests/browser-sources.json) | ConvertFrom-Json
        $directories = @($registry.roots | ForEach-Object { Join-Path $script:RepoRoot $_.path }) + $fixture
        foreach ($directory in $directories) {
            if (-not (Test-Path -LiteralPath $directory)) { continue }
            $expected = @(Get-ChildItem -LiteralPath $directory -File -Recurse -Include '*.js','*.css' | Sort-Object FullName | ForEach-Object FullName)
            $actual = @(& { param($dir); & $script:AssetExpression } $directory | ForEach-Object FullName)
            $actual | Should -Be $expected
        }
    }
}
