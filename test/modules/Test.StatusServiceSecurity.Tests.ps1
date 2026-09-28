<#PSScriptInfo
.VERSION 2026.09.27
.GUID 427642c0-6914-46fa-a327-c4a7e4ddc547
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test status security pester
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
    Exercise the generated status server's file authorization and configuration
    redaction against disposable files, without starting a host service.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.Config.psm1') -Force -DisableNameChecking
    $repo = Get-YurunaTestRepoRoot -SuiteDirectory $here
    $source = [IO.File]::ReadAllText((Join-Path $repo 'test/service/Start-StatusService.ps1'))
    $template = [regex]::Match($source, '(?ms)^\$serverScript = @"\r?\n(.*?)^"@')
    Assert-True $template.Success 'the server template must exist'
    $script:ServerText = $ExecutionContext.InvokeCommand.ExpandString($template.Groups[1].Value)
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($script:ServerText, [ref]$null, [ref]$parseErrors)
    Assert-Equal 0 @($parseErrors).Count 'the generated server must parse'
    $shapeAssignment = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$secretNameShapes'
    }, $true) | Select-Object -First 1
    Assert-NotNull $shapeAssignment 'the shared secret-name rules must exist'
    $script:ShapeText = $shapeAssignment.Extent.Text
    $script:Work = New-YurunaTestTempDir -Prefix 'yrn-status-security'
    $script:Roots = @{
        Repo = (Join-Path $script:Work 'repo')
        Status = (Join-Path $script:Work 'repo/test/status')
        Runtime = (Join-Path $script:Work 'repo/test/status/runtime')
        Log = (Join-Path $script:Work 'logs')
    }
    foreach ($dir in $script:Roots.Values) { $null = [IO.Directory]::CreateDirectory($dir) }
    $script:SavedRuntime = $env:YURUNA_RUNTIME_DIR
    $env:YURUNA_RUNTIME_DIR = $script:Roots.Runtime
    foreach ($relative in @('test/test.config.yml', '.git/config', 'test/status/ssh/yuruna_ed25519',
            'test/status/runtime/host-config-ca/ca.pfx', 'test/status/runtime/host-config-ca/server.pfx',
            'test/status/runtime/client.p12', 'test/status/runtime/poolstorage.42.fixture.cifs.cred',
            'test/status/runtime/status.json', 'test/status/runtime/host-refresh.state.json', 'README.md')) {
        $file = Join-Path $script:Roots.Repo $relative
        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $file))
        [IO.File]::WriteAllText($file, 'synthetic-fixture')
    }
    [IO.File]::WriteAllText((Join-Path $script:Roots.Log 'cycle.txt'), 'synthetic-log')

    $start = $script:ServerText.IndexOf('            # Dispatch file serving by URL prefix', [StringComparison]::Ordinal)
    $end = $script:ServerText.IndexOf('                $origLocal = $req.Url.LocalPath', $start, [StringComparison]::Ordinal)
    Assert-True ($start -ge 0 -and $end -gt $start) 'the file authorization block must exist'
    $dispatch = $script:ServerText.Substring($start, $end - $start) + "`n}`n"
    $script:FileHarness = [scriptblock]::Create(@'
param([hashtable]$Roots, [string]$RequestPath)
$repoRoot = $Roots.Repo; $statusDir = $Roots.Status; $runtimeDir = $Roots.Runtime; $logDir = $Roots.Log
$res = [pscustomobject]@{ StatusCode = 200; OutputStream = [IO.MemoryStream]::new() }
$req = [pscustomobject]@{ Url = [pscustomobject]@{ LocalPath = $RequestPath } }
function Get-StatusMessageBytes { return [Text.Encoding]::UTF8.GetBytes('denied') }
function Resolve-ArchivedLogPath { return $null }
$allowed = $false
'@ + "`n" + $script:ShapeText + "`nforeach (`$one in 0) {`n" + @'
$path = [Uri]::UnescapeDataString($RequestPath).TrimStart('/') -replace '^status[/\\]', ''
'@ + "`n" + $dispatch + @'
$allowed = $true
}
$res.OutputStream.Dispose()
[pscustomobject]@{ Allowed = $allowed; Status = $res.StatusCode; File = $file }
'@)

    $getStart = $script:ServerText.IndexOf('$doc  = Read-TestConfig -Path $testConfigFile -ThrowOnError', [StringComparison]::Ordinal)
    $getEnd = $script:ServerText.IndexOf('$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)', $getStart, [StringComparison]::Ordinal)
    Assert-True ($getStart -ge 0 -and $getEnd -gt $getStart) 'the config GET redaction must exist'
    $script:ReadView = [scriptblock]::Create('param([string]$testConfigFile)' + "`n" +
        $script:ServerText.Substring($getStart, $getEnd - $getStart) + "`nreturn `$json")
    $mergeStart = $script:ServerText.IndexOf('                    # Re-merge the on-disk secrets node', [StringComparison]::Ordinal)
    $mergeEnd = $script:ServerText.IndexOf('                    $tmp = "$testConfigFile.', $mergeStart, [StringComparison]::Ordinal)
    Assert-True ($mergeStart -ge 0 -and $mergeEnd -gt $mergeStart) 'the config save re-merge must exist'
    $script:MergeView = [scriptblock]::Create('param([string]$testConfigFile, [System.Collections.IDictionary]$parsedDoc)' + "`n" +
        $script:ServerText.Substring($mergeStart, $mergeEnd - $mergeStart) + "`nreturn ,`$parsedDoc")
}

AfterAll {
    if ($null -eq $script:SavedRuntime) { Remove-Item Env:YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue }
    else { $env:YURUNA_RUNTIME_DIR = $script:SavedRuntime }
    Remove-YurunaTestTempDir $script:Work
}

Describe 'status file authorization uses the resolved path' {
    It 'denies secret aliases before their bytes can be read' -TestCases @(
        @{ Path = '/yuruna-repo/test/test.config.yml' }
        @{ Path = '/yuruna-repo/test//test.config.yml' }
        @{ Path = '/yuruna-repo//test/test.config.yml' }
        @{ Path = '/yuruna-repo/%2F.git/config' }
        @{ Path = '/yuruna-repo//.git/config' }
        @{ Path = '/status//ssh/yuruna_ed25519' }
        @{ Path = '/yuruna-repo/test/status//ssh/yuruna_ed25519' }
        @{ Path = '/runtime/host-config-ca/ca.pfx' }
        @{ Path = '/runtime//host-config-ca/server.pfx' }
        @{ Path = '/runtime/client.p12' }
        @{ Path = '/runtime/poolstorage.42.fixture.cifs.cred' }
        @{ Path = '/status/runtime/host-config-ca/ca.pfx' }
        @{ Path = '/yuruna-repo/test/status/runtime/poolstorage.42.fixture.cifs.cred' }
        @{ Path = '/yuruna-repo/../outside.txt' }
    ) {
        param($Path)
        $result = & $script:FileHarness $script:Roots $Path
        Assert-Equal 403 $result.Status $Path
        Assert-False $result.Allowed $Path
    }

    It 'serves public progress and repository files' -TestCases @(
        @{ Path = '/runtime/status.json' }
        @{ Path = '/runtime//host-refresh.state.json' }
        @{ Path = '/yuruna-repo/README.md' }
        @{ Path = '/log/cycle.txt' }
    ) {
        param($Path)
        $result = & $script:FileHarness $script:Roots $Path
        Assert-Equal 200 $result.Status $Path
        Assert-True $result.Allowed $Path
        Assert-True (Test-Path -LiteralPath $result.File -PathType Leaf) $Path
    }

    It 'does not enumerate runtime secrets through either runtime mount' -TestCases @(
        @{ Path = '/runtime/' }
        @{ Path = '/status/runtime/' }
        @{ Path = '/runtime/host-config-ca/' }
    ) {
        param($Path)
        $result = & $script:FileHarness $script:Roots $Path
        Assert-Equal 403 $result.Status $Path
        Assert-False $result.Allowed $Path
    }

    It 'shares private key and credential exclusions with the archive packer' {
        $shapes = & ([scriptblock]::Create($script:ShapeText + "`nreturn ,`$secretNameShapes"))
        foreach ($name in @('ca.pfx', 'server.p12', 'poolstorage.42.fixture.cifs.cred')) {
            $matched = @($shapes | Where-Object { $name -like $_ })
            Assert-True ($matched.Count -gt 0) "$name must be excluded from archives too"
        }
    }
}

Describe 'configuration redaction preserves the cached and on-disk secrets' {
    It 'redacts only the response and preserves secrets across repeated reads and a UI save' {
        $config = Join-Path $script:Work 'roundtrip.yml'
        [IO.File]::WriteAllText($config, "setting: before`nsecrets:`n  token: fixture-token`n  nested:`n    password: fixture-password`n")
        $cached = Read-TestConfig -Path $config -ThrowOnError
        foreach ($iteration in 1..2) {
            $view = (& $script:ReadView $config) | ConvertFrom-Json -AsHashtable
            Assert-Equal 0 $view.secrets.Count 'the response never contains secrets'
            Assert-StringEqual 'fixture-token' $cached.secrets.token 'the shared cache stays intact'
            Assert-StringEqual 'fixture-password' $cached.secrets.nested.password
        }
        $view.setting = 'edited'
        $merged = & $script:MergeView $config $view
        [IO.File]::WriteAllText($config, ($merged | ConvertTo-Yaml))
        $saved = Read-TestConfig -Path $config -NoCache -ThrowOnError
        Assert-StringEqual 'edited' $saved.setting
        Assert-StringEqual 'fixture-token' $saved.secrets.token
        Assert-StringEqual 'fixture-password' $saved.secrets.nested.password
    }

    It 're-reads authoritative disk secrets even if another cached reader altered its object' {
        $config = Join-Path $script:Work 'cache.yml'
        [IO.File]::WriteAllText($config, "secrets:`n  token: disk-token`n")
        $cached = Read-TestConfig -Path $config -ThrowOnError
        $cached.secrets.Clear()
        $merged = & $script:MergeView $config ([ordered]@{ secrets = [ordered]@{} })
        Assert-StringEqual 'disk-token' $merged.secrets.token
    }
}
