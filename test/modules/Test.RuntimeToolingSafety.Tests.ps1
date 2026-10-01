<#PSScriptInfo
.VERSION 2026.09.30
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
        Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -DisableNameChecking -Verbose:$false
    }
    It 'rejects control codes and malformed bidi nesting while accepting balanced Unicode' {
        foreach ($code in 0..31) {
            $findings = @(Test-Utf8TextByte -Bytes ([Text.Encoding]::UTF8.GetBytes('prefix' + [char]$code + 'tail')))
            if ($code -in 9,10,13) { $findings.Count | Should -Be 0 }
            else { ($findings -join ';') | Should -Match ('U\+{0:X4}' -f $code) }
        }
        foreach ($text in @("`u{2066}a`u{2067}b`u{2069}c`u{2069}", "plain `u{00E9} `u{0627} `u{4E2D} `u{1F680}`n`t", 'ordinary text ' * 10000)) {
            @(Test-Utf8TextByte -Bytes ([Text.Encoding]::UTF8.GetBytes($text))).Count | Should -Be 0
        }
        foreach ($text in @("`u{2069}", "`u{2066}unclosed", "`u{202A}wrong closer`u{2069}", "`u{2066}wrong closer`u{202C}")) {
            @(Test-Utf8TextByte -Bytes ([Text.Encoding]::UTF8.GetBytes($text))).Count | Should -BeGreaterThan 0
        }
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

Describe 'local diagnostic data handling' {
    BeforeAll {
        $script:DiagnosticAst = Get-ToolingAst (Join-Path $script:RepoRoot 'automation/Get-SystemDiagnostic.ps1')
        $catalog = $script:DiagnosticAst.Find({ param($n)
            $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-LocalRegistryCatalog'
        }, $true)
        . ([scriptblock]::Create($catalog.Extent.Text))
    }
    It 'treats a successful HTML response as an unavailable registry' {
        Mock Invoke-WebRequest { @{ Content = '<html>development server</html>' } }
        { Get-LocalRegistryCatalog } | Should -Not -Throw
        Get-LocalRegistryCatalog | Should -BeNullOrEmpty
    }
    It 'preserves an empty reachable catalog and a populated catalog' {
        Mock Invoke-WebRequest { @{ Content = '{"repositories":[]}' } }
        $empty = Get-LocalRegistryCatalog
        ($null -eq $empty) | Should -BeFalse
        $empty.Count | Should -Be 0
        Mock Invoke-WebRequest { @{ Content = '{"repositories":["sample"]}' } }
        (Get-LocalRegistryCatalog)[0] | Should -BeExactly 'sample'
    }
    It 'includes only the GPU device and its attached PCI details' {
        $loop = $script:DiagnosticAst.Find({ param($n)
            $n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Condition.Extent.Text -match 'lspci -nnk'
        }, $true)
        $loop | Should -Not -BeNullOrEmpty
        function lspci {
            '00:01.0 USB controller', "`tSubsystem: USB", "`tKernel driver in use: usb",
            '00:02.0 VGA compatible controller', "`tSubsystem: GPU", "`tKernel driver in use: graphics",
            '00:03.0 Ethernet controller', "`tSubsystem: NIC", "`tKernel driver in use: ethernet"
        }
        $actual = & ([scriptblock]::Create('$inGpu = $false' + "`n" + $loop.Extent.Text))
        $actual | Should -Be @('00:02.0 VGA compatible controller', "`tSubsystem: GPU", "`tKernel driver in use: graphics")
    }
    It 'keeps the Docker client and server on distinct lines' {
        $call = $script:DiagnosticAst.Find({ param($n)
            $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-Tool' -and $n.Extent.Text -like '*Client: {{.Client.Version}}*'
        }, $true)
        $format = $call.Find({ param($n)
            $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -like 'Client:*'
        }, $true)
        $format.Value | Should -Match "Client:.*`nServer:"
    }
    It 'copies hidden files from the <Module> template' -TestCases @(
        @{ Module='Yuruna.Workload.psm1'; Variable='chartFolder'; Destination='workFolder' },
        @{ Module='Yuruna.Resource.psm1'; Variable='templateFolder'; Destination='workFolderNew' }
    ) {
        param($Module, $Variable, $Destination)
        $source = Join-Path $TestDrive $Module
        $target = Join-Path $TestDrive ($Module + '-copy')
        $null = New-Item -ItemType Directory -Path $source,$target -Force
        Set-Content -LiteralPath (Join-Path $source '.helmignore') -Value '*.bak'
        Set-Content -LiteralPath (Join-Path $source 'values.yml') -Value 'key: value'
        $ast = Get-ToolingAst (Join-Path $script:RepoRoot "automation/$Module")
        $call = $ast.Find({ param($n)
            $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Copy-Item' -and $n.Extent.Text.Contains('$' + $Variable + '/*')
        }, $true)
        $call | Should -Not -BeNullOrEmpty
        & { param($SourceVariable, $DestinationVariable, $SourcePath, $DestinationPath, $Expression)
            Set-Variable -Name $SourceVariable -Value $SourcePath
            Set-Variable -Name $DestinationVariable -Value $DestinationPath
            & $Expression
        } $Variable $Destination $source $target ([scriptblock]::Create($call.Extent.Text))
        Test-Path -LiteralPath (Join-Path $target '.helmignore') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $target 'values.yml') | Should -BeTrue
    }
}
