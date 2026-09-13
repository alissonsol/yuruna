<#PSScriptInfo
.VERSION 2026.09.13
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
        '{"sample.message":"A rendered message here."}')
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
