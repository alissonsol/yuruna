<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42b2a26c-2f83-45a5-9ea1-2968fe3e40d9
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test config mtls security pester
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
    Exercise the config service's actual TLS accept loop with disposable host
    CAs and guest certificates on an ephemeral loopback port.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:Work = New-YurunaTestTempDir -Prefix 'yrn-config-tls'
    $script:SavedRuntime = $env:YURUNA_RUNTIME_DIR
    $script:CaModule = Join-Path $here 'Test.ConfigServiceCA.psm1'
    Import-Module $script:CaModule -Force -DisableNameChecking
    $env:YURUNA_RUNTIME_DIR = Join-Path $script:Work 'trusted'
    $null = [IO.Directory]::CreateDirectory($env:YURUNA_RUNTIME_DIR)
    $null = Initialize-YurunaConfigCA -Confirm:$false
    $null = New-YurunaConfigServerCertificate -Confirm:$false
    $script:CaPath = Join-Path $env:YURUNA_RUNTIME_DIR 'host-config-ca/ca.crt'
    $script:TrustedRuntime = $env:YURUNA_RUNTIME_DIR
    $trusted = New-YurunaConfigClientCertificate -SubjectName 'fixture-client' -HostId '42deadbeefdeadbeefdeadbeefdead01'
    [IO.File]::WriteAllText((Join-Path $script:Work 'client.crt'), $trusted.CertificatePem)
    [IO.File]::WriteAllText((Join-Path $script:Work 'client.key'), $trusted.PrivateKeyPem)
    $env:YURUNA_RUNTIME_DIR = Join-Path $script:Work 'foreign'
    $null = [IO.Directory]::CreateDirectory($env:YURUNA_RUNTIME_DIR)
    $foreign = New-YurunaConfigClientCertificate -SubjectName 'foreign-client' -HostId '42deadbeefdeadbeefdeadbeefdead02'
    [IO.File]::WriteAllText((Join-Path $script:Work 'foreign.crt'), $foreign.CertificatePem)
    [IO.File]::WriteAllText((Join-Path $script:Work 'foreign.key'), $foreign.PrivateKeyPem)
    $env:YURUNA_RUNTIME_DIR = $script:TrustedRuntime

    # The native TLS callback and transport run without a PowerShell delegate,
    # matching the service's handshake thread behavior on every platform.
    if (-not ('Yuruna.Test.ConfigTlsProbe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text;
namespace Yuruna.Test {
    public static class ConfigTlsProbe {
        public static string Exchange(int port, string caPath, string certPath, string keyPath) {
            using var tcp = new TcpClient();
            if (!tcp.ConnectAsync("127.0.0.1", port).Wait(5000)) throw new TimeoutException("connect");
            tcp.ReceiveTimeout = 5000;
            tcp.SendTimeout = 5000;
            using var tls = new SslStream(tcp.GetStream(), false);
            tls.ReadTimeout = 5000;
            tls.WriteTimeout = 5000;
            using var ca = X509Certificate2.CreateFromPem(File.ReadAllText(caPath));
            var chain = new X509ChainPolicy { TrustMode = X509ChainTrustMode.CustomRootTrust,
                RevocationMode = X509RevocationMode.NoCheck };
            chain.CustomTrustStore.Add(ca);
            var options = new SslClientAuthenticationOptions { TargetHost = "yuruna-host-config",
                EnabledSslProtocols = SslProtocols.Tls12, CertificateChainPolicy = chain };
            using var client = String.IsNullOrEmpty(certPath) ? null : X509Certificate2.CreateFromPemFile(certPath, keyPath);
            if (client != null) options.ClientCertificates = new X509CertificateCollection { client };
            if (!tls.AuthenticateAsClientAsync(options).Wait(5000)) throw new TimeoutException("TLS handshake");
            var request = Encoding.ASCII.GetBytes("GET /healthz HTTP/1.1\r\nHost: yuruna-host-config\r\nConnection: close\r\n\r\n");
            tls.Write(request, 0, request.Length);
            tls.Flush();
            using var reader = new StreamReader(tls, Encoding.UTF8);
            return reader.ReadToEnd();
        }
    }
}
'@
    }

    $repo = Get-YurunaTestRepoRoot -SuiteDirectory $here
    $ast = Get-YurunaTestFileAst -Path (Join-Path $repo 'test/service/Start-ConfigService.ps1')
    $definitions = foreach ($name in @('Read-YurunaHttpRequest', 'Write-YurunaHttpResponse', 'Invoke-YurunaConfigServeLoop')) {
        $definition = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
        }, $true) | Select-Object -First 1
        Assert-NotNull $definition "$name must exist"
        $definition.Extent.Text
    }
    # Restrict only the fixture's bind address; the entire authentication and
    # HTTP request path remain the service function's own code.
    $functions = ($definitions -join "`n") -replace '\[System.Net.IPAddress\]::Any', '[System.Net.IPAddress]::Loopback'
    $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    try { $script:Port = $probe.LocalEndpoint.Port } finally { $probe.Stop() }
    $childPath = Join-Path $script:Work 'server.ps1'
    $childText = @'
param([string]$ModulePath, [int]$ListenPort, [string]$FixtureRoot)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Force -DisableNameChecking
'@ + "`n" + $functions + "`nInvoke-YurunaConfigServeLoop -ListenPort `$ListenPort -ConfigPath (Join-Path `$FixtureRoot 'unused.yml')`n"
    [IO.File]::WriteAllText($childPath, $childText)
    $psi = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($arg in @('-NoProfile', '-NonInteractive', '-File', $childPath, '-ModulePath', $script:CaModule,
            '-ListenPort', [string]$script:Port, '-FixtureRoot', $script:Work)) { $psi.ArgumentList.Add($arg) }
    $psi.Environment['YURUNA_RUNTIME_DIR'] = $script:TrustedRuntime
    $script:Server = [Diagnostics.Process]::Start($psi)
    $script:Stdout = $script:Server.StandardOutput.ReadToEndAsync()
    $script:Stderr = $script:Server.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds(20)
    $ready = $false
    while (-not $ready -and [DateTime]::UtcNow -lt $deadline -and -not $script:Server.HasExited) {
        $socket = [Net.Sockets.TcpClient]::new()
        try { $ready = $socket.ConnectAsync('127.0.0.1', $script:Port).Wait(250) -and $socket.Connected }
        catch { $ready = $false }
        finally { $socket.Dispose() }
        if (-not $ready) { Start-Sleep -Milliseconds 100 }
    }
    Assert-True $ready 'the disposable config server must start'
}

AfterAll {
    if ($script:Server) {
        try {
            if (-not $script:Server.HasExited) { $script:Server.Kill(); $null = $script:Server.WaitForExit(10000) }
        } finally { $script:Server.Dispose() }
    }
    if ($null -eq $script:SavedRuntime) { Remove-Item Env:YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue }
    else { $env:YURUNA_RUNTIME_DIR = $script:SavedRuntime }
    Remove-YurunaTestTempDir $script:Work
}

Describe 'config service validates its private host CA during the TLS handshake' {
    It 'serves a guest certificate signed by this host without system trust installation' {
        $response = [Yuruna.Test.ConfigTlsProbe]::Exchange($script:Port, $script:CaPath,
            (Join-Path $script:Work 'client.crt'), (Join-Path $script:Work 'client.key'))
        Assert-Match '^HTTP/1.1 200 OK' $response
        Assert-Match '\r\n\r\nok$' $response
    }

    It 'refuses certificates from a foreign host CA' {
        $response = ''
        try {
            $response = [Yuruna.Test.ConfigTlsProbe]::Exchange($script:Port, $script:CaPath,
                (Join-Path $script:Work 'foreign.crt'), (Join-Path $script:Work 'foreign.key'))
        } catch { $response = '' }
        Assert-False ($response -match '200 OK') 'an unrelated CA cannot authorize a guest'
    }

    It 'refuses clients that present no certificate' {
        $response = ''
        try { $response = [Yuruna.Test.ConfigTlsProbe]::Exchange($script:Port, $script:CaPath, '', '') }
        catch { $response = '' }
        Assert-False ($response -match '200 OK') 'the TLS route requires an authenticated guest'
    }

    It 'continues serving legitimate guests after rejected handshakes' {
        Assert-False $script:Server.HasExited
        $response = [Yuruna.Test.ConfigTlsProbe]::Exchange($script:Port, $script:CaPath,
            (Join-Path $script:Work 'client.crt'), (Join-Path $script:Work 'client.key'))
        Assert-Match '^HTTP/1.1 200 OK' $response
    }
}
