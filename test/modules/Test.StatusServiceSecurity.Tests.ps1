<#PSScriptInfo
.VERSION 2026.10.25
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
            # The public halves and ordinary hand-off files, which the status root
            # does not serve either; guests read the hand-off from the log root.
            'test/status/handoff/amisad-demo-key.pub', 'test/status/ssh/yuruna_ed25519.pub',
            'test/status/handoff/edge.ip.txt',
            # Runtime files no page or pool service reads, under names no deny
            # pattern ever matched, beside the records that are served.
            'test/status/runtime/yuruna-caching-proxy.yml', 'test/status/runtime/yuruna-caching-proxy.yml.backup',
            'test/status/runtime/yuruna-caching-proxy-service.yml', 'test/status/runtime/caching-proxy.txt',
            'test/status/runtime/.caching-proxy-service.env.json', 'test/status/runtime/host.uuid',
            'test/status/runtime/outer.log', 'test/status/runtime/.status-service.ps1',
            'test/status/runtime/runner-attempts/index.json', 'test/status/runtime/runner-attempts/0a1b2c/runner-fault.json',
            'test/status/runtime/runner-attempts/0a1b2c/transcript.log', 'test/status/runtime/current-action.json',
            'test/status/index.html', 'test/status/log/cycle-copy.txt', 'test/status/perf/row.jsonl')) {
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
    $messageWriter += "`n" + ((@('Get-ServedSourceSet', 'Test-ServedSourceFile') | ForEach-Object { (Get-YurunaTestFunctionAst -Ast $ast -Name $_).Extent.Text }) -join "`n")
    $artifactAssignment = $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$servedArtifacts'
    }, $true) | Select-Object -First 1
    Assert-NotNull $artifactAssignment 'the published artifacts must exist'
    $messageWriter += "`n" + $artifactAssignment.Extent.Text
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
        # The hand-off files the lab reads back.
        @{ Path = '/log/handoff/edge.ip.txt' }
    ) {
        param($Path)
        $result = & $script:FileHarness $script:Roots $Path
        Assert-Equal 200 $result.Status $Path
        Assert-True $result.Allowed $Path
        Assert-True (Test-Path -LiteralPath $result.File -PathType Leaf) $Path
    }

    # The status root keeps keys, hand-off files and extension state in folders
    # beside its pages. Those used to be served unless a name rule caught them,
    # and a hand-off folder there once held a private key; nothing reads them
    # over HTTP, so none of them is served, public halves included.
    It 'serves no folder of the status root but the performance rows and captures: <Path>' -TestCases @(
        @{ Path = '/handoff/edge.ip.txt' }
        @{ Path = '/handoff/amisad-demo-key.pub' }
        @{ Path = '/ssh/yuruna_ed25519.pub' }
        @{ Path = '/status/ssh/yuruna_ed25519.pub' }
        @{ Path = '/ssh/' }
        @{ Path = '/handoff/' }
        @{ Path = '/./' }
    ) {
        param($Path)
        $result = & $script:FileHarness $script:Roots $Path
        Assert-Equal 403 $result.Status $Path
        Assert-False $result.Allowed $Path
    }

    It 'serves from the runtime directory only the records pages and pool services read: <Path>' -TestCases @(
        @{ Path = '/runtime/current-action.json' }
        @{ Path = '/runtime/runner-attempts/index.json' }
        @{ Path = '/runtime/runner-attempts/0a1b2c/runner-fault.json' }
    ) {
        param($Path)
        $result = & $script:FileHarness $script:Roots $Path
        Assert-Equal 200 $result.Status $Path
        Assert-True $result.Allowed $Path
    }

    # The legacy proxy credential file was served for months because the deny
    # list named only the file's newer name. Every spelling below exists on disk.
    It 'refuses a runtime file that is not on the allow-list, by any route: <Path>' -TestCases @(
        @{ Path = '/runtime/yuruna-caching-proxy.yml' }
        @{ Path = '/runtime/yuruna-caching-proxy.yml.backup' }
        @{ Path = '/runtime/yuruna-caching-proxy-service.yml' }
        @{ Path = '/runtime/caching-proxy.txt' }
        @{ Path = '/runtime/.caching-proxy-service.env.json' }
        @{ Path = '/runtime/host.uuid' }
        @{ Path = '/runtime/outer.log' }
        @{ Path = '/runtime/.status-service.ps1' }
        @{ Path = '/runtime/runner-attempts/0a1b2c/transcript.log' }
        @{ Path = '//runtime/yuruna-caching-proxy.yml' }
        @{ Path = '/status/runtime/yuruna-caching-proxy.yml' }
        @{ Path = '/status//runtime/yuruna-caching-proxy.yml' }
        @{ Path = '/yuruna-repo/test/status/runtime/yuruna-caching-proxy.yml' }
        @{ Path = '/yuruna-repo/test/status/runtime/status.json' }
    ) {
        param($Path)
        $result = & $script:FileHarness $script:Roots $Path
        Assert-Equal 403 $result.Status $Path
        Assert-False $result.Allowed $Path
    }

    It 'serves committed status pages through the repository mount but never harness state: <Path>' -TestCases @(
        @{ Path = '/yuruna-repo/test/status/index.html'; Status = 200 }
        @{ Path = '/yuruna-repo/test/status/log/cycle-copy.txt'; Status = 403 }
        @{ Path = '/yuruna-repo/test/status/perf/row.jsonl'; Status = 403 }
    ) {
        param($Path, $Status)
        $result = & $script:FileHarness $script:Roots $Path
        Assert-Equal $Status $result.Status $Path
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

# A deny list of names fails open for every file added under a name it did not
# foresee. The repository mount now serves what git tracks or would track, so
# an ignored file is refused whatever it is called.
Describe 'the repository mount serves source files only' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
    BeforeAll {
        $script:GitRoots = @{
            Repo = (Join-Path $script:Work 'gitrepo')
            Status = (Join-Path $script:Work 'gitrepo/test/status')
            Runtime = (Join-Path $script:Work 'gitrepo/test/status/runtime')
            Log = (Join-Path $script:Work 'gitlogs')
        }
        foreach ($dir in $script:GitRoots.Values) { $null = [IO.Directory]::CreateDirectory($dir) }
        $repo = $script:GitRoots.Repo
        function Write-Fixture { param([string]$Root, [string]$Relative) $file = Join-Path $Root $Relative; $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $file)); [IO.File]::WriteAllText($file, 'synthetic-fixture') }
        [IO.File]::WriteAllText((Join-Path $repo '.gitignore'), "test/test.config.yml`ntest/status/*/`nprivate/`nproject/`n*.secret`nproject-poc.tar.gz`n")
        foreach ($relative in @('README.md', 'automation/fetch-and-execute.sh', 'test/status/index.html', 'test/status/yuruna.common.js',
                'notes/new-script.sh', 'private/notes.txt', 'creds.secret', 'project-poc.tar.gz', 'test/test.config.yml',
                'test/status/perf/row.jsonl', 'test/status/captures/shot.png', 'test/status/ssh/yuruna_ed25519.pub',
                'test/status/handoff/edge.ip.txt', 'test/status/extension/authentication/users.yml', 'test/status/runtime/status.json')) {
            Write-Fixture -Root $repo -Relative $relative
        }
        $null = & git -C $repo init -q 2>&1
        $null = & git -C $repo add README.md automation test/status/index.html test/status/yuruna.common.js .gitignore 2>&1
        $project = Join-Path $repo 'project'
        foreach ($relative in @('poc/db/schema.sql', '.cache/token')) { Write-Fixture -Root $project -Relative $relative }
        [IO.File]::WriteAllText((Join-Path $project '.gitignore'), ".cache/`n")
        $null = & git -C $project init -q 2>&1
        $null = & git -C $project add poc .gitignore 2>&1
    }

    It 'serves <Path> with <Status>' -TestCases @(
        @{ Path = '/yuruna-repo/README.md'; Status = 200 }
        @{ Path = '/yuruna-repo/automation/fetch-and-execute.sh'; Status = 200 }
        @{ Path = '/yuruna-repo/notes/new-script.sh'; Status = 200 }
        @{ Path = '/yuruna-repo/private/notes.txt'; Status = 403 }
        @{ Path = '/yuruna-repo/creds.secret'; Status = 403 }
        @{ Path = '/yuruna-repo/test/test.config.yml'; Status = 403 }
        @{ Path = '/yuruna-repo/project-poc.tar.gz'; Status = 200 }
        @{ Path = '/yuruna-repo/project/poc/db/schema.sql'; Status = 200 }
        @{ Path = '/yuruna-repo/project/.cache/token'; Status = 403 }
        @{ Path = '/yuruna-repo/test/status/index.html'; Status = 200 }
        @{ Path = '/yuruna-repo/test/status/perf/row.jsonl'; Status = 403 }
        @{ Path = '/index.html'; Status = 200 }
        @{ Path = '/status/yuruna.common.js'; Status = 200 }
        @{ Path = '/perf/row.jsonl'; Status = 200 }
        @{ Path = '/captures/shot.png'; Status = 200 }
        @{ Path = '/ssh/yuruna_ed25519.pub'; Status = 403 }
        @{ Path = '/handoff/edge.ip.txt'; Status = 403 }
        @{ Path = '/extension/authentication/users.yml'; Status = 403 }
        @{ Path = '/extension/'; Status = 403 }
        @{ Path = '/runtime/status.json'; Status = 200 }
    ) {
        param($Path, $Status)
        $result = & $script:FileHarness $script:GitRoots $Path
        Assert-Equal $Status $result.Status $Path
    }
    It 'serves a source file created after the listing was read, without a restart' {
        $before = & $script:FileHarness $script:GitRoots '/yuruna-repo/automation/later.sh'
        Assert-Equal 403 $before.Status 'a file git does not list yet is not served'
        [IO.File]::WriteAllText((Join-Path $script:GitRoots.Repo 'automation/later.sh'), 'synthetic-fixture')
        Start-Sleep -Milliseconds 2200
        $after = & $script:FileHarness $script:GitRoots '/yuruna-repo/automation/later.sh'
        Assert-Equal 200 $after.Status 'the listing is read again on a miss'
    }
}

Describe 'control routes accept the scope that covers them' {
    # A pause-scoped proof is what the pool-wide pause and continue carries; it
    # must open the four pause and resume routes and none of the others.
    BeforeAll {
        $line = @($script:ServerText -split "`r?`n" | Where-Object { $_ -match '^\s*\$ctlScope = ' })
        Assert-Equal 1 $line.Count 'the route scope rule must exist once'
        $script:ScopeRule = [scriptblock]::Create("param([string]`$path)`n" + $line[0].Trim() + "`nreturn ,`$ctlScope")
    }
    It 'gives <Route> the scopes <Expected>' -TestCases @(
        @{ Route = 'control/step-pause'; Expected = 'pause' }
        @{ Route = 'control/step-resume'; Expected = 'pause' }
        @{ Route = 'control/cycle-pause'; Expected = 'pause' }
        @{ Route = 'control/cycle-resume'; Expected = 'pause' }
        @{ Route = 'control/start-cycle'; Expected = '' }
        @{ Route = 'control/test-config'; Expected = '' }
        @{ Route = 'control/host-refresh'; Expected = '' }
        @{ Route = 'control/break-continue'; Expected = '' }
        @{ Route = 'control/lab-hold-release'; Expected = '' }
        @{ Route = 'control/host-diagnostic'; Expected = '' }
    ) {
        param($Route, $Expected)
        ((& $script:ScopeRule -path $Route) -join ',') | Should -BeExactly $Expected
    }
    It 'hands the route''s scopes to the verifier' {
        $script:ServerText | Should -Match ([regex]::Escape('Test-YurunaControlProof -Token $ctlToken -Wire $ctlWire -Audience (Get-ArchiveHostId) -AllowedScope $ctlScope'))
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
