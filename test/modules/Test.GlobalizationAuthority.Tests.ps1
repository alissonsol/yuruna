<#PSScriptInfo
.VERSION 2026.09.18
.GUID 4270db15-2984-48ef-823c-a9f61e5d0374
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test globalization literal protocol ratchet pester
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
    Prove the literal and prose-as-protocol ratchets fail closed.

    Run: Invoke-Pester -Path test/modules/Test.GlobalizationAuthority.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Tool = Join-Path $script:RepoRoot 'tools/Test-GlobalizationAuthority.ps1'

function Invoke-Authority {
    param([string]$Root = $script:RepoRoot, [string]$Manifest, [string]$Today = '2026-09-03')
    $runnerArgs = @('-NoProfile', '-File', $script:Tool, '-Root', $Root, '-Today', $Today, '-Quiet')
    if ($Manifest) { $runnerArgs += @('-Manifest', $Manifest) }
    $output = & pwsh @runnerArgs 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Output = $output }
}

function New-AuthorityFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates a disposable source tree under TestDrive.')]
    param([string]$Body, [string]$ExceptionDate = '2026-10-01')
    $root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('n'))
    foreach ($dir in @('globalization/manifests', 'globalization/catalogs/en-US', 'src')) {
        New-Item -ItemType Directory -Path (Join-Path $root $dir) -Force | Out-Null
    }
    [IO.File]::WriteAllText((Join-Path $root 'src/page.js'), $Body)
    $registry = @{ schema = 'yuruna.code-registry/v1'; codes = @(@{
                code = 'ready'; producedBy = @('src/page.js'); consumedBy = @()
            }) }
    [IO.File]::WriteAllText((Join-Path $root 'globalization/manifests/code-registry.json'),
        (ConvertTo-Json $registry -Depth 6))
    [IO.File]::WriteAllText((Join-Path $root 'globalization/catalogs/en-US/sample.json'),
        '{"schema":"yuruna.catalog/v1","domain":"sample","locale":"en-US","messages":{"sample.message":{"message":"A rendered message here.","description":"Translator context contains source code examples.","lifecycle":"active"}}}')
    $authority = @{
        schema = 'yuruna.conversion-authority/v1'
        convertedScopes = @(@{
                path = 'src/page.js'; startMarker = 'function converted('; endMarker = 'function after('
                requiredTokens = @('sample.message'); allowedProse = @()
            })
        legacyProtocolPhrases = @('Old rendered state')
        protocolExceptions = @(@{
                path = 'src/page.js'; text = 'Old rendered state'; removeAfter = $ExceptionDate
                reason = 'compatibility fixture'
            })
    }
    $manifest = Join-Path $root 'authority.json'
    [IO.File]::WriteAllText($manifest, (ConvertTo-Json $authority -Depth 8))
    return @{ Root = $root; Manifest = $manifest }
}
}

Describe 'converted source is a one-way literal ratchet' {

    It 'passes the registered tree' {
        $run = Invoke-Authority
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
    }

    It 'rejects new operator prose inside a converted scope' {
        $fixture = New-AuthorityFixture -Body @'
function converted() {
  var key = 'sample.message';
  var regression = 'An unexplained operator sentence returned.';
}
function after() {}
var old = 'Old rendered state';
'@
        $run = Invoke-Authority -Root $fixture.Root -Manifest $fixture.Manifest
        Assert-Equal -Expected 1 -Actual $run.Code 'new prose regained a converted source region'
        Assert-Match -Pattern 'unexplained operator prose' -Actual $run.Output 'the literal regression is not named'
    }

    It 'ignores prose in source comments' {
        $fixture = New-AuthorityFixture -Body @'
function converted() {
  // This explanatory sentence is not browser output.
  var key = 'sample.message';
}
function after() {}
var old = 'Old rendered state';
'@
        $run = Invoke-Authority -Root $fixture.Root -Manifest $fixture.Manifest
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
    }

    It 'treats an embedded generated catalog as data rather than a branch' {
        $fixture = New-AuthorityFixture -Body @'
// >>> yuruna-i18n embedded block -- generated
var catalog = 'A rendered message here.';
// <<< yuruna-i18n embedded block
function converted() { var key = 'sample.message'; }
function after() {}
var old = 'Old rendered state';
'@
        $run = Invoke-Authority -Root $fixture.Root -Manifest $fixture.Manifest
        Assert-Equal -Expected 0 -Actual $run.Code `
            -Because "catalog payload data was mistaken for executable protocol:`n$($run.Output)"
    }
}

Describe 'rendered prose cannot become a machine protocol' {

    It 'rejects a catalog sentence at a registered boundary' {
        $fixture = New-AuthorityFixture -Body @'
function converted() { var key = 'sample.message'; }
function after() {}
if (state === 'A rendered message here.') { fail(); }
var old = 'Old rendered state';
'@
        $run = Invoke-Authority -Root $fixture.Root -Manifest $fixture.Manifest
        Assert-Equal -Expected 1 -Actual $run.Code 'a rendered message became a branch token'
        Assert-Match -Pattern 'registered machine boundary' -Actual $run.Output 'the protocol coupling is not named'
    }

    It 'rejects escaped rendered prose inside a JavaScript regex' {
        $fixture = New-AuthorityFixture -Body @'
function converted() { var key = 'sample.message'; }
function after() {}
if (/A rendered message here\./.test(state)) { fail(); }
var old = 'Old rendered state';
'@
        $run = Invoke-Authority -Root $fixture.Root -Manifest $fixture.Manifest
        Assert-Equal -Expected 1 -Actual $run.Code `
            'escaping punctuation in a regex hid a rendered-message branch'
        Assert-Match -Pattern 'registered machine boundary' -Actual $run.Output `
            'the regex protocol coupling is not named'
    }

    It 'rejects an expired compatibility reader' {
        $fixture = New-AuthorityFixture -ExceptionDate '2026-09-02' -Body @'
function converted() { var key = 'sample.message'; }
function after() {}
var old = 'Old rendered state';
'@
        $run = Invoke-Authority -Root $fixture.Root -Manifest $fixture.Manifest
        Assert-Equal -Expected 1 -Actual $run.Code 'a dated prose reader became permanent'
        Assert-Match -Pattern 'expired' -Actual $run.Output 'the expiry is not named'
    }
}

Describe 'catalog authority distinguishes rendered text from metadata and metric frames' {
    It 'checks select and plural forms while leaving translator examples out of the protocol set' {
        $fixture = New-AuthorityFixture -Body @'
function converted() { var key = 'sample.message'; }
function after() {}
var old = 'Old rendered state';
var developerExample = 'Translator context contains source code examples.';
'@
        $run = Invoke-Authority -Root $fixture.Root -Manifest $fixture.Manifest
        $run.Code | Should -Be 0 -Because $run.Output
        $catalogPath = Join-Path $fixture.Root 'globalization/catalogs/en-US/sample.json'
        $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json -AsHashtable
        $catalog.messages['sample.choice'] = @{ select = @{ argument = 'kind'; variants = @{ other = 'A rendered select branch.' } } }
        $catalog.messages['sample.count'] = @{ plural = @{ argument = 'count'; variants = @{ one = 'A rendered singular branch.'; other = 'A rendered plural branch.' } } }
        $catalog | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $catalogPath
        foreach ($phrase in @('A rendered select branch.', 'A rendered singular branch.', 'A rendered plural branch.')) {
            Add-Content -LiteralPath (Join-Path $fixture.Root 'src/page.js') -Value ("if (state === '" + $phrase + "') { fail(); }")
            $run = Invoke-Authority -Root $fixture.Root -Manifest $fixture.Manifest
            $run.Code | Should -Be 1
            $run.Output | Should -Match ([regex]::Escape($phrase))
        }
    }
    It 'excludes only explicit Prometheus writer frames while retaining an equal prose branch' {
        $fixture = New-AuthorityFixture -Body "function converted() { var key = 'sample.message'; }`nfunction after() {}`nvar old = 'Old rendered state';"
        $registryPath = Join-Path $fixture.Root 'globalization/manifests/code-registry.json'
        $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
        $registry.codes[0].producedBy += 'src/metrics.go'
        $registry | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $registryPath
        $goPath = Join-Path $fixture.Root 'src/metrics.go'
        [IO.File]::WriteAllText($goPath, 'fmt.Fprintf(w, "# HELP fixture_metric A rendered message here.\n# TYPE fixture_metric gauge\n")' + "`n" + 'b.WriteString("# HELP fixture_other A rendered message here.\n# TYPE fixture_other gauge\n")')
        $run = Invoke-Authority -Root $fixture.Root -Manifest $fixture.Manifest
        $run.Code | Should -Be 0 -Because $run.Output
        Add-Content -LiteralPath $goPath -Value 'if state == "A rendered message here." { return }'
        $run = Invoke-Authority -Root $fixture.Root -Manifest $fixture.Manifest
        $run.Code | Should -Be 1
        $run.Output | Should -Match 'registered machine boundary'
    }
}

Describe 'external process literal contracts are bound to an exact parser' {
    It 'permits an external pattern only at its hashed typed input and rejects copying it into a rendered-message branch' {
        $fixture = New-AuthorityFixture -Body "function converted() { var key = 'sample.message'; }`nfunction after() {}`nvar old = 'Old rendered state';"
        $path = Join-Path $fixture.Root 'src/adapter.psm1'
        $pattern = 'A rendered message here.'
        [IO.File]::WriteAllText($path, 'function Test-ExternalResult { param($Line) return $Line -match ''A rendered message here.'' }')
        $registryPath = Join-Path $fixture.Root 'globalization/manifests/code-registry.json'
        $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
        $registry.codes[0].producedBy += 'src/adapter.psm1'
        $registry | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $registryPath
        $authority = Get-Content -LiteralPath $fixture.Manifest -Raw | ConvertFrom-Json -AsHashtable
        $authority.literalContracts = @(@{ kind = 'external-process-pattern'; path = 'src/adapter.psm1'; function = 'Test-ExternalResult'; input = '$Line'; operator = 'Imatch'; sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($pattern))).ToLowerInvariant(); reason = 'Fixture external process frame.' })
        $authority | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixture.Manifest
        $run = Invoke-Authority -Root $fixture.Root -Manifest $fixture.Manifest
        $run.Code | Should -Be 0 -Because $run.Output
        [IO.File]::WriteAllText($path, 'function Test-ExternalResult { param($Message) return $Message -match ''A rendered message here.'' }')
        $run = Invoke-Authority -Root $fixture.Root -Manifest $fixture.Manifest
        $run.Code | Should -Be 1
        $run.Output | Should -Match 'registered machine boundary'
        $run.Output | Should -Match 'literal contract is malformed or no longer matches'
    }
}

Describe 'generated boundary code is parsed as runtime source' {
    It 'ignores comments in a declared template but rejects its real prose condition and a stale declaration' {
        $fixture = New-AuthorityFixture -Body "function converted() { var key = 'sample.message'; }`nfunction after() {}`nvar old = 'Old rendered state';"
        $path = Join-Path $fixture.Root 'src/generator.ps1'
        $body = @'
$server = @"
# A rendered message here.
function Test-State { param(`$State) return `$State -eq 'ready' }
`$path = '$($Root.Replace("'", "''"))'
"@
'@
        [IO.File]::WriteAllText($path, $body)
        $registryPath = Join-Path $fixture.Root 'globalization/manifests/code-registry.json'
        $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
        $registry.codes[0].producedBy += 'src/generator.ps1'
        $registry | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $registryPath
        $authority = Get-Content -LiteralPath $fixture.Manifest -Raw | ConvertFrom-Json -AsHashtable
        $authority.generatedPowerShell = @(@{ path = 'src/generator.ps1'; variable = '$server'; reason = 'Fixture deployed PowerShell source.' })
        $authority | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixture.Manifest
        $run = Invoke-Authority -Root $fixture.Root -Manifest $fixture.Manifest
        $run.Code | Should -Be 0 -Because $run.Output
        [IO.File]::WriteAllText($path, $body.Replace("-eq 'ready'", "-eq 'A rendered message here.'"))
        $run = Invoke-Authority -Root $fixture.Root -Manifest $fixture.Manifest
        $run.Code | Should -Be 1
        $run.Output | Should -Match 'registered machine boundary'
        [IO.File]::WriteAllText($path, $body.Replace('$server =', '$renamed ='))
        $run = Invoke-Authority -Root $fixture.Root -Manifest $fixture.Manifest
        $run.Code | Should -Be 1
        $run.Output | Should -Match 'generated PowerShell declaration no longer matches'
    }
    It 'qualifies exact active HTML catalog leaves only with a renderer and keeps unmarked branches visible' {
        $fixture = New-AuthorityFixture -Body "function converted() { var key = 'sample.message'; }`nfunction after() {}`nvar old = 'Old rendered state';"
        $path = Join-Path $fixture.Root 'src/page.ps1'
        $body = @'
$html = '<span data-i18n="sample.message" data-i18n-args="' + $escapedArguments + '">A rendered message here.</span>'
ConvertTo-CatalogHtml -Html $html -Locale en-US
'@
        [IO.File]::WriteAllText($path, $body)
        $registryPath = Join-Path $fixture.Root 'globalization/manifests/code-registry.json'
        $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
        $registry.codes[0].producedBy += 'src/page.ps1'
        $registry | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $registryPath
        $run = Invoke-Authority -Root $fixture.Root -Manifest $fixture.Manifest
        $run.Code | Should -Be 0 -Because $run.Output
        foreach ($changed in @($body.Replace('sample.message', 'missing.message'), $body.Replace('ConvertTo-CatalogHtml', 'Write-Output'), ($body + "`nif (`$state -eq 'A rendered message here.') { exit 1 }"))) {
            [IO.File]::WriteAllText($path, $changed)
            $run = Invoke-Authority -Root $fixture.Root -Manifest $fixture.Manifest
            $run.Code | Should -Be 1
            $run.Output | Should -Match 'registered machine boundary'
        }
    }
}
