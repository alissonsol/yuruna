<#PSScriptInfo
.VERSION 2026.10.22
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
    Import-Module (Join-Path $here 'Test.ConfigSync.psm1') -Force -DisableNameChecking
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
            'test/status/runtime/status.json', 'test/status/runtime/host-refresh.state.json', 'README.md',
            # Private-key file names that sit where no directory rule looks: a
            # project's hand-off directory, a key beside an unrelated tree, the
            # OpenSSH default names at depth, and the runtime mount.
            'test/status/handoff/amisad-demo-key', 'test/status/ssh/foo_ed25519',
            'test/status/x/y/id_rsa', 'test/status/x/y/id_ecdsa', 'test/status/runtime/deploy_key',
            'test/status/runtime/operator.ppk',
            # The public halves and ordinary hand-off files that must keep being served.
            'test/status/handoff/amisad-demo-key.pub', 'test/status/ssh/yuruna_ed25519.pub',
            'test/status/handoff/edge.ip.txt')) {
        $file = Join-Path $script:Roots.Repo $relative
        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $file))
        [IO.File]::WriteAllText($file, 'synthetic-fixture')
    }
    [IO.File]::WriteAllText((Join-Path $script:Roots.Log 'cycle.txt'), 'synthetic-log')
    $null = [IO.Directory]::CreateDirectory((Join-Path $script:Roots.Log 'handoff'))
    [IO.File]::WriteAllText((Join-Path $script:Roots.Log 'handoff/edge.ip.txt'), '192.0.2.15')
    [IO.File]::WriteAllText((Join-Path $script:Roots.Log 'handoff/amisad-demo-key'), 'synthetic-fixture')

    $start = $script:ServerText.IndexOf('            # Dispatch file serving by URL prefix', [StringComparison]::Ordinal)
    $end = $script:ServerText.IndexOf('                $origLocal = $req.Url.LocalPath', $start, [StringComparison]::Ordinal)
    Assert-True ($start -ge 0 -and $end -gt $start) 'the file authorization block must exist'
    $dispatch = $script:ServerText.Substring($start, $end - $start) + "`n}`n"
    $messageWriter = (Get-YurunaTestFunctionAst -Ast $ast -Name 'Send-StatusMessage').Extent.Text
    $script:FileHarness = [scriptblock]::Create(@'
param([hashtable]$Roots, [string]$RequestPath, [string]$Method = 'GET')
$repoRoot = $Roots.Repo; $statusDir = $Roots.Status; $runtimeDir = $Roots.Runtime; $logDir = $Roots.Log
$res = [pscustomobject]@{ StatusCode = 200; ContentLength64 = 0; OutputStream = [IO.MemoryStream]::new() }
$req = [pscustomobject]@{ HttpMethod = $Method; Url = [pscustomobject]@{ LocalPath = $RequestPath } }
function Get-StatusMessageBytes { return [Text.Encoding]::UTF8.GetBytes('denied') }
function Resolve-ArchivedLogPath { return $null }
$allowed = $false
'@ + "`n" + $messageWriter + "`n" + $script:ShapeText + "`nforeach (`$one in 0) {`n" + @'
$path = [Uri]::UnescapeDataString($RequestPath).TrimStart('/') -replace '^status[/\\]', ''
'@ + "`n" + $dispatch + @'
$allowed = $true
}
$res.OutputStream.Dispose()
[pscustomobject]@{ Allowed = $allowed; Status = $res.StatusCode; File = $file; Length = $res.ContentLength64; BodyLength = $res.OutputStream.ToArray().Length }
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
    $writeEnd = $script:ServerText.IndexOf('                    $body = [System.Text.Encoding]::UTF8.GetBytes', $mergeEnd, [StringComparison]::Ordinal)
    Assert-True ($writeEnd -gt $mergeEnd) 'the configuration writer must exist'
    $script:WriteView = [scriptblock]::Create(@'
param([string]$testConfigFile, [System.Collections.IDictionary]$parsedDoc)
$reports = [Collections.Generic.List[object]]::new()
$res = [pscustomobject]@{StatusCode=200}; $req = $null
function Write-ServerErr {
    param([string]$Message)
    $reports.Add(@{text=$Message;disk=[IO.File]::ReadAllText($testConfigFile)})
}
function Send-JsonError {
    param($Response, $StatusCode, $Request, $Key, $Arguments)
    $Response.StatusCode = $StatusCode
}
function ConvertTo-JsonEscapedString { param($Value) return [string]$Value }
foreach ($request in 1) {
'@ + "`n" + $script:ServerText.Substring($mergeStart, $writeEnd - $mergeStart) + @'
}
return [pscustomobject]@{Status=$res.StatusCode;Reports=$reports.ToArray()}
'@)
    $rsa = [Security.Cryptography.RSA]::Create(3072)
    try { $script:MirrorKey = [Convert]::ToBase64String($rsa.ExportSubjectPublicKeyInfo()) }
    finally { $rsa.Dispose() }
}

AfterAll {
    if ($null -eq $script:SavedRuntime) { Remove-Item Env:YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue }
    else { $env:YURUNA_RUNTIME_DIR = $script:SavedRuntime }
    Remove-YurunaTestTempDir $script:Work
}

Describe 'status file authorization uses the resolved path' {
    It 'keeps error headers on HEAD without writing response bytes' {
        $get = & $script:FileHarness $script:Roots '/runtime/client.p12' 'GET'
        $head = & $script:FileHarness $script:Roots '/runtime/client.p12' 'HEAD'
        $get.Status | Should -Be 403
        $get.BodyLength | Should -Be 6
        $head.Status | Should -Be $get.Status
        $head.Length | Should -Be $get.Length
        $head.BodyLength | Should -Be 0
    }

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
        # The NTFS named-stream spelling of a refused file reads the file's own
        # bytes through a name no pattern matches.
        @{ Path = '/yuruna-repo/test/test.config.yml::$DATA' }
        @{ Path = '/runtime/host-config-ca/ca.pfx::$DATA' }
        @{ Path = '/handoff/amisad-demo-key::$DATA' }
        @{ Path = '/yuruna-repo/test/status/handoff/amisad-demo-key:stream' }
    ) {
        param($Path)
        $result = & $script:FileHarness $script:Roots $Path
        Assert-Equal 403 $result.Status $Path
        Assert-False $result.Allowed $Path
    }

    # A private key is refused by the shape of its NAME, wherever it sits. A rule
    # keyed on one directory protects only the files its author remembered, and
    # a project that parks a key in a directory of its own (a hand-off folder a
    # guest downloads from) is outside every such rule. The file below exists on
    # disk in each case, so a pass means the listener refused bytes it had.
    It 'denies a private key by its name in <Path>' -TestCases @(
        @{ Path = '/handoff/amisad-demo-key' }
        @{ Path = '/handoff//amisad-demo-key' }
        @{ Path = '/status/handoff/amisad-demo-key' }
        @{ Path = '/log/handoff/amisad-demo-key' }
        @{ Path = '/yuruna-repo/test/status/handoff/amisad-demo-key' }
        @{ Path = '/ssh/foo_ed25519' }
        @{ Path = '/x/y/id_rsa' }
        @{ Path = '/x/y/id_ecdsa' }
        @{ Path = '/yuruna-repo/test/status/x/y/id_rsa' }
        @{ Path = '/runtime/deploy_key' }
        @{ Path = '/runtime/operator.ppk' }
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
        # The public halves of keys and the hand-off files the lab reads back.
        @{ Path = '/handoff/edge.ip.txt' }
        @{ Path = '/log/handoff/edge.ip.txt' }
        @{ Path = '/handoff/amisad-demo-key.pub' }
        @{ Path = '/ssh/yuruna_ed25519.pub' }
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
        foreach ($name in @('ca.pfx', 'server.p12', 'poolstorage.42.fixture.cifs.cred',
                'amisad-demo-key', 'deploy_key', 'id_rsa', 'id_ed25519', 'id_ecdsa', 'id_dsa', 'operator.ppk')) {
            $matched = @($shapes | Where-Object { $name -like $_ })
            Assert-True ($matched.Count -gt 0) "$name must be excluded from archives too"
        }
    }

    It 'leaves the public halves of keys out of the name shapes' {
        # The shapes are shared with the archive packer and the repository mount,
        # so a shape that also caught a public key or an address file would
        # silently drop it from a cycle archive and refuse it to every guest.
        $shapes = & ([scriptblock]::Create($script:ShapeText + "`nreturn ,`$secretNameShapes"))
        foreach ($name in @('amisad-demo-key.pub', 'yuruna_ed25519.pub', 'id_rsa.pub', 'edge.ip.txt',
                'handoff', 'ca.crt', 'yuruna-release-signing.pub.pem', 'ubuntu-image-signing-keys.asc')) {
            $matched = @($shapes | Where-Object { $name -like $_ })
            Assert-Equal 0 $matched.Count "$name must not match a secret name shape ($($matched -join ', '))"
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

Describe 'control configuration writer preserves and validates mirror enrollment' {
    BeforeEach {
        $script:MirrorConfig = Join-Path $script:Work 'mirror-config.yml'
        $script:MirrorDoc = @{repositories=@{projectUrl='file:///operator/project.git';mirror=@{mode='prefer';url='http://192.0.2.8';verificationPublicKeys=@($script:MirrorKey)}};secrets=@{token='fixture-token'}}
        $script:MirrorDoc | ConvertTo-Yaml | Set-Content $script:MirrorConfig
    }

    It 'keeps omitted trust from an older editor and preserves custom repositories on disk' {
        $posted = @{repositories=@{projectUrl='file:///operator/project.git'};secrets=@{}}
        $result = & $script:WriteView $script:MirrorConfig $posted
        $result.Status | Should -Be 200
        $disk = Read-TestConfig -Path $script:MirrorConfig -NoCache -ThrowOnError
        @($disk.repositories.mirror.verificationPublicKeys) | Should -BeExactly @($script:MirrorKey)
        $disk.repositories.mirror.url | Should -BeExactly 'http://192.0.2.8'
        $disk.repositories.projectUrl | Should -BeExactly 'file:///operator/project.git'
        $disk.secrets.token | Should -BeExactly 'fixture-token'
    }

    It 'backs up and reports previous and new policy before replacing the file' {
        $before = [IO.File]::ReadAllText($script:MirrorConfig)
        $script:MirrorDoc.repositories.mirror.mode = 'off'
        $result = & $script:WriteView $script:MirrorConfig $script:MirrorDoc
        $result.Status | Should -Be 200
        [IO.File]::ReadAllText($script:MirrorConfig+'.backup') | Should -BeExactly $before
        $report = @($result.Reports | Where-Object text -Like 'repositories.mirror.mode:*')
        $report.Count | Should -Be 1
        $report[0].text | Should -Match 'prefer -> off'
        $report[0].disk | Should -BeExactly $before
        (Read-TestConfig -Path $script:MirrorConfig -NoCache -ThrowOnError).repositories.mirror.mode | Should -BeExactly 'off'
    }

    It 'leaves the file unchanged when a posted key is malformed' {
        $before = [IO.File]::ReadAllBytes($script:MirrorConfig)
        $script:MirrorDoc.repositories.mirror.verificationPublicKeys = @('invalid-key')
        $result = & $script:WriteView $script:MirrorConfig $script:MirrorDoc
        $result.Status | Should -Be 500
        [IO.File]::ReadAllBytes($script:MirrorConfig) | Should -BeExactly $before
        @($result.Reports | Where-Object text -Like '*mirror-key-invalid*').Count | Should -Be 1
    }
}
