<#PSScriptInfo
.VERSION 2026.10.18
.GUID 42a5584e-4c2e-4cbb-8d99-15ea594679db
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guest yaml performance pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>

#requires -version 7

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    $script:Pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $source = Get-Content (Join-Path $script:RepoRoot 'guest/shared/ubuntu.update.sh') -Raw
    $start = $source.IndexOf('# --- REGION: Install powershell-yaml module')
    $end = $source.IndexOf('# --- REGION: Early yuruna framework extraction', $start)
    $block = $source.Substring($start, $end - $start)
    $bodies = [regex]::Matches($block, "(?ms)<<'PSEOF'[^\r\n]*\r?\n(.*?)^PSEOF\r?$")
    if ($bodies.Count -eq 0) { throw 'Guest YAML install payload was not found' }
    $script:YamlPayload = ($bodies | ForEach-Object { $_.Groups[1].Value }) -join "`n"
    function Invoke-YamlFixture {
        param([string]$Mode, [string]$Version = '0.4.12', [switch]$RealModule)
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $fixture
        $prefix = @'
$script:FixtureMode = $env:YURUNA_YAML_FIXTURE_MODE
$script:FixtureVersion = $env:YURUNA_YAML_FIXTURE_VERSION
$script:Calls = @{ imports=0; installs=0; repositories=0; providers=0; probes=0; removals=0; parses=0; trustChanges=0 }
function Get-PSRepository { $script:Calls.repositories++; [pscustomobject]@{ Name='PSGallery'; SourceLocation='https://www.powershellgallery.com/api/v2'; InstallationPolicy='Untrusted' } }
function Set-PSRepository { $script:Calls.trustChanges++; throw 'Repository trust policy must remain unchanged' }
function Get-PackageProvider { $script:Calls.providers++; [pscustomobject]@{ Name='NuGet'; Version='2.8.5.208' } }
function Invoke-WebRequest {
    $script:Calls.probes++
    if ($script:FixtureMode -eq 'offline-repair') { throw 'fixture gallery unavailable' }
    [pscustomobject]@{ StatusCode=200 }
}
function Install-Module {
    param([string]$Name, [string]$Scope, [switch]$Force, [string]$RequiredVersion, [string]$MinimumVersion, [switch]$AllowClobber, [switch]$SkipPublisherCheck)
    if ($Name -ne 'powershell-yaml' -or $Scope -ne 'AllUsers' -or -not $Force -or $RequiredVersion -or $MinimumVersion -or $AllowClobber -or $SkipPublisherCheck) { throw 'Install contract changed' }
    $script:Calls.installs++
    if ($script:FixtureMode -in 'install-failed', 'offline-repair') { throw 'fixture install refused' }
}
function Remove-Module { $script:Calls.removals++ }
function Import-Module {
    $script:Calls.imports++
    if ($script:FixtureMode -in 'install-failed','offline-repair' -or
        ($script:Calls.installs -eq 0 -and $script:FixtureMode -in 'missing','broken-import')) { throw 'fixture module unavailable' }
    if ($script:FixtureMode -eq 'repair-import-failed') { throw 'fixture import remains broken' }
    [pscustomobject]@{ Name='powershell-yaml'; Version=[version]$script:FixtureVersion }
}
function Get-Module {
    param([string[]]$Name, [switch]$ListAvailable)
    if ($Name -contains 'powershell-yaml' -and $script:FixtureMode -eq 'verify-missing') { return }
    [pscustomobject]@{ Name=$Name[0]; Version=[version]$script:FixtureVersion }
}
function ConvertFrom-Yaml {
    $script:Calls.parses++
    $broken = $script:FixtureMode -eq 'repair-parse-failed' -or
        ($script:Calls.installs -eq 0 -and $script:FixtureMode -in 'broken-parse','wrong-bool','wrong-number','wrong-list','parse-throws')
    if ($broken -and $script:FixtureMode -eq 'parse-throws') { throw 'fixture parser failed' }
    $parsed = @{ service=@{ enabled=$true; attempts=3; tags=@('first','second') } }
    if ($broken) {
        switch ($script:FixtureMode) {
            'wrong-bool' { $parsed.service.enabled='true' }
            'wrong-number' { $parsed.service.attempts='3' }
            'wrong-list' { $parsed.service.tags=@('first') }
            default { $parsed=@{ incompatible='parser' } }
        }
    }
    return $parsed
}
'@
        if ($RealModule) {
            $prefix += "`nRemove-Item Function:Import-Module, Function:Get-Module, Function:ConvertFrom-Yaml, Function:Remove-Module`n"
        }
        # The DNS API is static; localhost confines repair probes to local name resolution.
        $body = $script:YamlPayload.Replace("GetHostAddresses('www.powershellgallery.com')", "GetHostAddresses('localhost')")
        $driver = $prefix + "`ntry {`n" + $body + @'

} finally {
    $script:Calls | ConvertTo-Json -Compress | Set-Content -LiteralPath $env:YURUNA_YAML_FIXTURE_RESULT
}
'@
        $entry = Join-Path $fixture 'fixture.ps1'
        $resultFile = Join-Path $fixture 'calls.json'
        Set-Content -LiteralPath $entry -Value $driver -Encoding utf8NoBOM
        $result = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-File', $entry) -TimeoutSeconds 20 `
            -Environment @{ YURUNA_YAML_FIXTURE_MODE=$Mode; YURUNA_YAML_FIXTURE_VERSION=$Version; YURUNA_YAML_FIXTURE_RESULT=$resultFile }
        [pscustomobject]@{ Process=$result; Calls=(Get-Content $resultFile -Raw | ConvertFrom-Json) }
    }
}

Describe 'Ubuntu YAML module reuse and repair' {
    It 'keeps the common Amazon Linux and Ubuntu YAML validation and repair payload identical' {
        $source = Get-Content (Join-Path $script:RepoRoot 'guest/amazon.linux.2023/amazon.linux.2023.update.sh') -Raw
        $start = $source.IndexOf('# --- REGION: Install powershell-yaml module')
        $end = $source.IndexOf('# --- REGION: Early yuruna framework extraction', $start)
        $block = $source.Substring($start, $end - $start)
        $bodies = [regex]::Matches($block, "(?ms)<<'PSEOF'[^\r\n]*\r?\n(.*?)^PSEOF\r?$")
        (($bodies | ForEach-Object { $_.Groups[1].Value }) -join "`n") | Should -Be $script:YamlPayload
    }

    It 'reuses a functional installed version <Version> without Gallery or install work' -ForEach @(
        @{ Version='0.4.12' }, @{ Version='0.3.0' }, @{ Version='9.0.0' }
    ) {
        $fixture = Invoke-YamlFixture -Mode healthy -Version $Version
        $fixture.Process.ExitCode | Should -Be 0 -Because $fixture.Process.StdErr
        $fixture.Calls.installs | Should -Be 0
        $fixture.Calls.repositories | Should -Be 0
        $fixture.Calls.providers | Should -Be 0
        $fixture.Calls.probes | Should -Be 0
        $fixture.Calls.trustChanges | Should -Be 0
        $fixture.Calls.parses | Should -Be 1
        $fixture.Process.StdOut | Should -Match 'already functional'
    }

    It 'repairs <Mode> and verifies the installed module before continuing' -ForEach @(
        @{ Mode='missing' }, @{ Mode='broken-import' }, @{ Mode='broken-parse' },
        @{ Mode='wrong-bool' }, @{ Mode='wrong-number' }, @{ Mode='wrong-list' }, @{ Mode='parse-throws' }
    ) {
        $fixture = Invoke-YamlFixture -Mode $Mode
        $fixture.Process.ExitCode | Should -Be 0 -Because $fixture.Process.StdErr
        $fixture.Calls.installs | Should -Be 1
        $fixture.Calls.repositories | Should -Be 1
        $fixture.Calls.providers | Should -Be 1
        $fixture.Calls.probes | Should -Be 1
        $fixture.Calls.trustChanges | Should -Be 0
        $fixture.Process.StdOut | Should -Match 'INITIAL SMOKE ERROR:'
        $fixture.Process.StdOut | Should -Match 'OK'
    }

    It 'fails closed for <Mode> so the existing shell retry can try again' -ForEach @(
        @{ Mode='install-failed' }, @{ Mode='offline-repair' }, @{ Mode='repair-import-failed' },
        @{ Mode='repair-parse-failed' }, @{ Mode='verify-missing' }
    ) {
        $fixture = Invoke-YamlFixture -Mode $Mode
        $fixture.Process.ExitCode | Should -Be 1
        $fixture.Calls.installs | Should -Be 1
        $fixture.Process.StdOut | Should -Match 'SMOKE ERROR:'
        $fixture.Process.StdOut | Should -Not -Match '(?m)^OK$'
    }

    It 'reuses the real installed powershell-yaml parser and checks nested values without contacting Gallery' {
        if (-not (Get-Module powershell-yaml -ListAvailable)) { Set-ItResult -Skipped -Because 'powershell-yaml is unavailable'; return }
        $fixture = Invoke-YamlFixture -Mode healthy -RealModule
        $fixture.Process.ExitCode | Should -Be 0 -Because $fixture.Process.StdErr
        $fixture.Calls.installs | Should -Be 0
        $fixture.Calls.repositories | Should -Be 0
        $fixture.Calls.probes | Should -Be 0
        $fixture.Calls.trustChanges | Should -Be 0
        $fixture.Process.StdOut | Should -Match 'already functional'
    }
}
