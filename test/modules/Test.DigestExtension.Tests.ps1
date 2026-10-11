<#PSScriptInfo
.VERSION 2026.10.11.1
.GUID 42930196-b800-4c0a-baac-f213d39f8eba
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test extension digest sha256 launch integrity pester
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
    The digest extension area: the SHA-256 values a launch command carries to a
    guest so the guest can verify what it downloads before using it.
.DESCRIPTION
    The digest is the guest's only defense for a download over plain HTTP, so
    the properties worth pinning are the ones a wrong digest would silently
    break:

      - a file digest is of the bytes on disk (line endings included) and the
        path cannot name anything outside the checkout;
      - an archive digest is of the bytes the status service answers with, and
        a refusal, a non-gzip body or a dead service yields an EMPTY value
        rather than a plausible one, which a verifying guest refuses;
      - a published digest is replaced only by a successful read, and a failed
        read leaves the previous record alone;
      - all of it resolves through the real ${ext:digest.<Method>(...)} syntax,
        whose CamelCase-to-Verb-Noun mapping is easy to get subtly wrong.

    The status service is replaced by a loopback TCP fixture that speaks just
    enough HTTP, so no real listener, VM or git repository is involved. The
    guest side is replaced by a stub Invoke-GuestSsh.

    Run: pwsh -NoProfile -File tools/_InvokeOneSuite.ps1 -Suite test/modules/Test.DigestExtension.Tests.ps1 -Xml <result.xml>
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    $script:Psm1 = Join-Path $script:RepoRoot 'test/extension/digest/default.psm1'
    $null = Import-Module $script:Psm1 -Force -Global -DisableNameChecking

    if (-not ('YurunaDigestFixtureServer' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public sealed class YurunaDigestFixtureServer : IDisposable {
    private sealed class Reply { public int Status; public byte[] Body; public string ContentType; }
    private readonly TcpListener listener;
    private readonly ConcurrentDictionary<string, Reply> routes = new ConcurrentDictionary<string, Reply>();
    private readonly ConcurrentQueue<string> seen = new ConcurrentQueue<string>();
    private volatile bool stopping;
    public int Port { get; private set; }

    public YurunaDigestFixtureServer() {
        listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        Thread worker = new Thread(Run);
        worker.IsBackground = true;
        worker.Start();
    }

    public void Route(string path, int status, byte[] body, string contentType) {
        routes[path] = new Reply { Status = status, Body = body, ContentType = contentType };
    }

    public string[] Requests() { return seen.ToArray(); }

    private void Run() {
        while (!stopping) {
            TcpClient client;
            try { client = listener.AcceptTcpClient(); }
            catch (SocketException) { return; }
            catch (ObjectDisposedException) { return; }
            try {
                using (client) {
                    NetworkStream stream = client.GetStream();
                    StringBuilder head = new StringBuilder();
                    byte[] one = new byte[1];
                    while (head.Length < 8192 && !head.ToString().EndsWith("\r\n\r\n")) {
                        if (stream.Read(one, 0, 1) <= 0) break;
                        head.Append((char)one[0]);
                    }
                    string[] parts = head.ToString().Split('\n')[0].Trim().Split(' ');
                    string path = parts.Length > 1 ? parts[1] : "";
                    seen.Enqueue(path);
                    Reply reply;
                    if (!routes.TryGetValue(path, out reply)) {
                        reply = new Reply { Status = 404, Body = Encoding.ASCII.GetBytes("no such route"), ContentType = "text/plain" };
                    }
                    byte[] header = Encoding.ASCII.GetBytes("HTTP/1.1 " + reply.Status + " Fixture\r\nContent-Type: " +
                        reply.ContentType + "\r\nContent-Length: " + reply.Body.Length + "\r\nConnection: close\r\n\r\n");
                    stream.Write(header, 0, header.Length);
                    stream.Write(reply.Body, 0, reply.Body.Length);
                    stream.Flush();
                }
            }
            catch (IOException) { }
            catch (SocketException) { }
        }
    }

    public void Dispose() {
        stopping = true;
        try { listener.Stop(); } catch (SocketException) { }
    }
}
'@
    }

    # A real gzip stream, so the "is it gzip" check sees what the status service
    # sends rather than a fabricated header.
    $script:GzipBytes = & {
        $memory = [IO.MemoryStream]::new()
        $gzip = [IO.Compression.GZipStream]::new($memory, [IO.Compression.CompressionMode]::Compress, $true)
        $payload = [Text.Encoding]::ASCII.GetBytes('digest fixture payload ' * 40)
        $gzip.Write($payload, 0, $payload.Length)
        $gzip.Dispose()
        $memory.ToArray()
    }
    $script:GzipDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($script:GzipBytes)).ToLowerInvariant()

    function Get-Digest {
        param([Parameter(Mandatory)][byte[]]$Bytes)
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
    }

    $script:SavedEnv = Save-YurunaTestEnvironment -Name @('YURUNA_RUNTIME_DIR', 'YURUNA_CONFIG_PATH')
    $script:Work = New-YurunaTestTempDir -Prefix 'yrn-digest'
}

AfterAll {
    Restore-YurunaTestEnvironment -Saved $script:SavedEnv
    Remove-Item -Path Function:\Global:Invoke-GuestSsh -ErrorAction SilentlyContinue
    Remove-Module default -Force -ErrorAction SilentlyContinue
    Remove-YurunaTestTempDir $script:Work
}

Describe 'Get-FileSha256' {
    BeforeAll {
        $script:Tree = Join-Path $script:Work 'tree'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $script:Tree 'db')
        # CRLF and a NUL byte: a digest of a "normalized" copy would differ.
        $script:SqlBytes = [byte[]](0x53, 0x45, 0x4C, 0x45, 0x43, 0x54, 0x0D, 0x0A, 0x00, 0xFF, 0x0A)
        [IO.File]::WriteAllBytes((Join-Path $script:Tree 'db/schema.sql'), $script:SqlBytes)
    }

    It 'is the lowercase SHA-256 of the bytes on disk' {
        $digest = Get-FileSha256 -Path 'db/schema.sql' -RepoRoot $script:Tree
        Assert-StringEqual (Get-Digest $script:SqlBytes) $digest
        Assert-Match '^[0-9a-f]{64}$' $digest
    }

    It 'treats a backslash as a separator' {
        Assert-StringEqual (Get-Digest $script:SqlBytes) (Get-FileSha256 -Path 'db\schema.sql' -RepoRoot $script:Tree)
    }

    It 'returns an empty value and says why for <Path>' -TestCases @(
        @{ Path = '' }
        @{ Path = '   ' }
        @{ Path = '../outside.txt' }
        @{ Path = 'db/../../outside.txt' }
        @{ Path = '/etc/passwd' }
        @{ Path = 'C:\Windows\win.ini' }
        @{ Path = 'db/*.sql' }
        @{ Path = 'db/schema.sql::$DATA' }
        @{ Path = 'db/missing.sql' }
        @{ Path = 'db' }
    ) {
        param($Path)
        $digest = Get-FileSha256 -Path $Path -RepoRoot $script:Tree -WarningVariable warned -WarningAction SilentlyContinue
        Assert-StringEqual '' $digest "no digest for '$Path'"
        Assert-True (@($warned).Count -ge 1) "'$Path' must be explained, not silently empty"
    }
}

Describe 'Get-ArchiveSha256' {
    BeforeAll {
        $script:Server = [YurunaDigestFixtureServer]::new()
        $script:Base = "http://127.0.0.1:$($script:Server.Port)"
        $script:Server.Route('/yuruna-project-archive.tar.gz', 200, $script:GzipBytes, 'application/gzip')
        $script:Server.Route('/yuruna-archive.tar.gz', 200, $script:GzipBytes, 'application/gzip')
        $script:Server.Route('/missing-gzip/yuruna-project-archive.tar.gz', 404, [Text.Encoding]::ASCII.GetBytes('project repo not present'), 'text/plain')
    }
    AfterAll { $script:Server.Dispose() }

    It 'is the SHA-256 of the bytes the status service answers with, for <Name>' -TestCases @(
        @{ Name = 'project'; Route = '/yuruna-project-archive.tar.gz' }
        @{ Name = 'framework'; Route = '/yuruna-archive.tar.gz' }
    ) {
        param($Name, $Route)
        $digest = Get-ArchiveSha256 -Name $Name -BaseUrl $script:Base -Attempts 1
        Assert-StringEqual $script:GzipDigest $digest
        Assert-True (@($script:Server.Requests()) -contains $Route) "the digest must come from $Route"
    }

    It 'returns an empty value when the service refuses' {
        $script:Server.Route('/yuruna-project-archive.tar.gz', 404, [Text.Encoding]::ASCII.GetBytes('project repo not present'), 'text/plain')
        try {
            $digest = Get-ArchiveSha256 -Name 'project' -BaseUrl $script:Base -Attempts 1 -WarningVariable warned -WarningAction SilentlyContinue
            Assert-StringEqual '' $digest
            Assert-Match '404' ($warned -join ' ')
        } finally {
            $script:Server.Route('/yuruna-project-archive.tar.gz', 200, $script:GzipBytes, 'application/gzip')
        }
    }

    It 'returns an empty value for a body that is not a gzip stream' {
        $script:Server.Route('/yuruna-project-archive.tar.gz', 200, [Text.Encoding]::ASCII.GetBytes('<html>captive portal</html>'), 'text/html')
        try {
            $digest = Get-ArchiveSha256 -Name 'project' -BaseUrl $script:Base -Attempts 1 -WarningVariable warned -WarningAction SilentlyContinue
            Assert-StringEqual '' $digest 'hashing a captive portal page would pin the wrong bytes'
            Assert-Match 'not a gzip' ($warned -join ' ')
        } finally {
            $script:Server.Route('/yuruna-project-archive.tar.gz', 200, $script:GzipBytes, 'application/gzip')
        }
    }

    It 'returns an empty value for an empty body' {
        $script:Server.Route('/yuruna-project-archive.tar.gz', 200, [byte[]]@(), 'application/gzip')
        try {
            Assert-StringEqual '' (Get-ArchiveSha256 -Name 'project' -BaseUrl $script:Base -Attempts 1 -WarningAction SilentlyContinue)
        } finally {
            $script:Server.Route('/yuruna-project-archive.tar.gz', 200, $script:GzipBytes, 'application/gzip')
        }
    }

    It 'returns an empty value when nothing is listening' {
        $closed = [YurunaDigestFixtureServer]::new()
        $url = "http://127.0.0.1:$($closed.Port)"
        $closed.Dispose()
        $digest = Get-ArchiveSha256 -Name 'project' -BaseUrl $url -Attempts 1 -TimeoutSeconds 5 -WarningVariable warned -WarningAction SilentlyContinue
        Assert-StringEqual '' $digest
        Assert-Match 'status service must be running' ($warned -join ' ')
    }

    It 'refuses an archive name it does not know' {
        Assert-StringEqual '' (Get-ArchiveSha256 -Name 'everything' -BaseUrl $script:Base -Attempts 1 -WarningAction SilentlyContinue)
        Assert-StringEqual '' (Get-ArchiveSha256 -Name '' -BaseUrl $script:Base -Attempts 1 -WarningAction SilentlyContinue)
    }
}

Describe 'Publish-GuestFileSha256 and Get-PublishedSha256' {
    BeforeAll {
        $script:Runtime = Join-Path $script:Work 'runtime'
        $env:YURUNA_RUNTIME_DIR = $script:Runtime
        $script:SshCalls = [Collections.Generic.List[hashtable]]::new()
        $script:SshAnswer = @{ success = $true; exitCode = 0; output = '' }
        function Global:Invoke-GuestSsh {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalFunctions', '',
                Justification = 'Stands in for the harness SSH helper, which the module under test resolves from the global scope.')]
            param([string]$VMName, [string]$GuestKey, [string]$Command, [string]$User, [int]$TimeoutSeconds)
            $script:SshCalls.Add(@{ VMName = $VMName; GuestKey = $GuestKey; Command = $Command; User = $User; TimeoutSeconds = $TimeoutSeconds })
            return $script:SshAnswer
        }
        $script:Good = ('ab' * 32)
    }
    BeforeEach {
        $script:SshCalls.Clear()
        Remove-Item -LiteralPath (Join-Path $script:Runtime 'digest') -Recurse -Force -ErrorAction SilentlyContinue
        $script:SshAnswer = @{ success = $true; exitCode = 0; output = "$($script:Good)  /tmp/amisad-x86_64-binaries.tgz" }
    }

    It 'reads the digest over SSH, records it, and hands it back by name' {
        $published = Publish-GuestFileSha256 -Name 'amisad-binaries' -VMName 'amisad-build' -User 'amisad-build-admin' `
            -Path '/tmp/amisad-*-binaries.tgz' 6>$null
        Assert-StringEqual $script:Good $published
        Assert-Equal 1 $script:SshCalls.Count
        Assert-StringEqual 'sha256sum -- /tmp/amisad-*-binaries.tgz' $script:SshCalls[0].Command
        Assert-StringEqual 'amisad-build' $script:SshCalls[0].VMName
        Assert-StringEqual 'amisad-build-admin' $script:SshCalls[0].User
        Assert-StringEqual $script:Good (Get-PublishedSha256 -Name 'amisad-binaries')
        # Raw text, not ConvertFrom-Json: the parser turns an ISO timestamp into a
        # DateTime, and what is pinned here is the spelling written to disk.
        $text = Get-Content -LiteralPath (Join-Path $script:Runtime 'digest/amisad-binaries.json') -Raw
        Assert-Match '"source":\s*"amisad-build:/tmp/amisad-x86_64-binaries\.tgz"' $text
        Assert-Match '"publishedUtc":\s*"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"' $text
    }

    It 'normalizes an uppercase digest and the binary-mode marker' {
        $script:SshAnswer = @{ success = $true; exitCode = 0; output = "$($script:Good.ToUpperInvariant()) */tmp/x.tgz" }
        Assert-StringEqual $script:Good (Publish-GuestFileSha256 -Name 'n' -VMName 'vm' -Path '/tmp/x.tgz' 6>$null)
    }

    It 'replaces the record on a later publish' {
        $null = Publish-GuestFileSha256 -Name 'n' -VMName 'vm' -Path '/tmp/x.tgz' 6>$null
        $script:SshAnswer = @{ success = $true; exitCode = 0; output = "$('cd' * 32)  /tmp/x.tgz" }
        $null = Publish-GuestFileSha256 -Name 'n' -VMName 'vm' -Path '/tmp/x.tgz' 6>$null
        Assert-StringEqual ('cd' * 32) (Get-PublishedSha256 -Name 'n')
    }

    It 'fails the step and keeps the previous record when the read <Case>' -TestCases @(
        @{ Case = 'fails'; Answer = @{ success = $false; exitCode = 255; output = 'connection refused' } }
        @{ Case = 'prints nothing'; Answer = @{ success = $true; exitCode = 0; output = '' } }
        @{ Case = 'matches two files'; Answer = @{ success = $true; exitCode = 0; output = ("$('ab' * 32)  /tmp/a.tgz`n$('cd' * 32)  /tmp/b.tgz") } }
        @{ Case = 'is not a digest'; Answer = @{ success = $true; exitCode = 0; output = 'sha256sum: /tmp/x.tgz: No such file or directory' } }
        @{ Case = 'is a short digest'; Answer = @{ success = $true; exitCode = 0; output = "$('ab' * 31)  /tmp/x.tgz" } }
    ) {
        param($Answer)
        $null = Publish-GuestFileSha256 -Name 'n' -VMName 'vm' -Path '/tmp/x.tgz' 6>$null
        $script:SshAnswer = $Answer
        Assert-Throw { Publish-GuestFileSha256 -Name 'n' -VMName 'vm' -Path '/tmp/x.tgz' 6>$null } 'digest:'
        Assert-StringEqual $script:Good (Get-PublishedSha256 -Name 'n') 'a stale value must not be mistaken for the new artifact, and a failure must not erase the old one'
    }

    It 'refuses <What> before touching the guest' -TestCases @(
        @{ What = 'a name that is a path'; Name = '../escape'; VM = 'vm'; Path = '/tmp/x'; User = '' }
        @{ What = 'a relative guest path'; Name = 'n'; VM = 'vm'; Path = 'tmp/x'; User = '' }
        @{ What = 'a guest path with a space'; Name = 'n'; VM = 'vm'; Path = '/tmp/a b'; User = '' }
        @{ What = 'a guest path with a command separator'; Name = 'n'; VM = 'vm'; Path = '/tmp/x;reboot'; User = '' }
        @{ What = 'a guest path with ..'; Name = 'n'; VM = 'vm'; Path = '/tmp/../etc/shadow'; User = '' }
        @{ What = 'a guest path with two wildcards'; Name = 'n'; VM = 'vm'; Path = '/tmp/*/*.tgz'; User = '' }
        @{ What = 'a VM name that is an option'; Name = 'n'; VM = '-oProxyCommand=x'; Path = '/tmp/x'; User = '' }
        @{ What = 'a login user that is an option'; Name = 'n'; VM = 'vm'; Path = '/tmp/x'; User = '-oProxyCommand=x' }
    ) {
        param($What, $Name, $VM, $Path, $User)
        $arguments = @{ Name = $Name; VMName = $VM; Path = $Path; User = $User }
        Assert-Throw { Publish-GuestFileSha256 @arguments 6>$null }
        Assert-Equal 0 $script:SshCalls.Count "$What reached the guest"
    }

    It 'warns and returns an empty value for a name nothing published' {
        $digest = Get-PublishedSha256 -Name 'never-published' -WarningVariable warned -WarningAction SilentlyContinue
        Assert-StringEqual '' $digest
        Assert-Match 'nothing is published' ($warned -join ' ')
    }

    It 'warns and returns an empty value for a record that holds no digest' {
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $script:Runtime 'digest')
        Set-Content -LiteralPath (Join-Path $script:Runtime 'digest/broken.json') -Value '{"sha256":"not-a-digest"}'
        Set-Content -LiteralPath (Join-Path $script:Runtime 'digest/garbled.json') -Value '{{{'
        foreach ($name in 'broken', 'garbled') {
            Assert-StringEqual '' (Get-PublishedSha256 -Name $name -WarningAction SilentlyContinue) $name
        }
    }
}

Describe 'the ${ext:digest.<Method>(...)} syntax' {
    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'test/modules/Test.SequenceVariable.psm1') -Force -Global -DisableNameChecking
        $script:Server2 = [YurunaDigestFixtureServer]::new()
        $script:Server2.Route('/yuruna-project-archive.tar.gz', 200, $script:GzipBytes, 'application/gzip')
        # A status port the expansion has to read from the configuration.
        $script:ConfigPath = Join-Path $script:Work 'ext-test.config.yml'
        Set-Content -LiteralPath $script:ConfigPath -Value "statusService:`n  port: $($script:Server2.Port)`n"
        $env:YURUNA_CONFIG_PATH = $script:ConfigPath
        $env:YURUNA_RUNTIME_DIR = Join-Path $script:Work 'runtime-ext'
    }
    AfterAll { $script:Server2.Dispose() }

    It 'resolves GetFileSha256 against the checkout' {
        $expected = (Get-FileHash -LiteralPath (Join-Path $script:RepoRoot 'README.md') -Algorithm SHA256).Hash.ToLowerInvariant()
        $expanded = Expand-Variable "AMISAD_X_SHA256='`${ext:digest.GetFileSha256(README.md)}'" @{}
        Assert-StringEqual "AMISAD_X_SHA256='$expected'" $expanded
    }

    It 'resolves GetArchiveSha256 through the configured status port' {
        $expanded = Expand-Variable 'a=${ext:digest.GetArchiveSha256(project)}' @{}
        Assert-StringEqual "a=$($script:GzipDigest)" $expanded
    }

    It 'expands a ${var} placeholder inside the argument' {
        $expected = (Get-FileHash -LiteralPath (Join-Path $script:RepoRoot 'README.md') -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-StringEqual $expected (Expand-Variable '${ext:digest.GetFileSha256(${doc})}' @{ doc = 'README.md' })
    }

    It 'expands an unpublished name to an empty value, never to the literal expression' {
        $expanded = Expand-Variable "x='`${ext:digest.GetPublishedSha256(never-published-name)}'" @{} 3>$null
        Assert-StringEqual "x=''" $expanded
    }

    It 'resolves GetPublishedSha256 to what a callExtension step published' {
        $script:SshAnswer = @{ success = $true; exitCode = 0; output = "$('ef' * 32)  /tmp/artifact.tgz" }
        $null = Publish-GuestFileSha256 -Name 'artifact' -VMName 'vm' -Path '/tmp/artifact.tgz' 6>$null
        Assert-StringEqual ('ef' * 32) (Expand-Variable '${ext:digest.GetPublishedSha256(artifact)}' @{})
    }
}

Describe 'the digest area as shipped' {
    It 'loads through the extension loader with its contract fully covered' {
        Import-Module (Join-Path $script:RepoRoot 'test/modules/Test.Extension.psm1') -Force -Global -DisableNameChecking
        Assert-True (@(Get-ExtensionAreaName) -contains 'digest') 'the area is discovered by directory'
        $captured = $null
        $null = Import-Extension -Area 'digest' -WarningVariable captured -WarningAction SilentlyContinue
        Assert-Equal 0 @($captured | Where-Object { "$($_.Message)" -match 'contract verb' }).Count
    }
}
