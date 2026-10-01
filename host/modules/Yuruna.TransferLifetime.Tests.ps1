<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42f1b39c-5884-49aa-8979-f180da646601
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna download timeout pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'Responder jobs receive listeners through explicit ArgumentList parameters and own their loop variables.')]
[CmdletBinding()]
param()
if (-not (Get-Command Describe -ErrorAction SilentlyContinue)) { throw 'Run this suite with Pester.' }
BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $script:AgentModule = Import-Module (Join-Path $PSScriptRoot 'Yuruna.DownloadAgent.psm1') -Force -PassThru -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Yuruna.HostDownload.psm1') -Force -DisableNameChecking
    function Get-StalledResponder {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'The listener and signal are explicit thread-job arguments.')]
        param([switch]$NoHeaders)
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $signal = [Threading.ManualResetEventSlim]::new($false)
        $job = Start-ThreadJob -ArgumentList $listener, $signal, $NoHeaders.IsPresent -ScriptBlock {
            param($Listener, $Signal, $NoHeaders)
            $peer = $null
            try {
                $peer = $Listener.AcceptTcpClient()
                $stream = $peer.GetStream()
                $buffer = [byte[]]::new(8192)
                [void]$stream.Read($buffer, 0, $buffer.Length)
                if (-not $NoHeaders) {
                    $bytes = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 100000`r`nConnection: close`r`n`r`n1234567890")
                    $stream.Write($bytes, 0, $bytes.Length)
                    $stream.Flush()
                }
                [void]$Signal.Wait(15000)
            } finally {
                if ($peer) { $peer.Dispose() }
                $Listener.Stop()
            }
        }
        return @{ Url = "http://127.0.0.1:$($listener.LocalEndpoint.Port)/bytes"; Listener = $listener; Signal = $signal; Job = $job }
    }
    function Close-StalledResponder {
        param($Responder)
        $Responder.Signal.Set()
        $Responder.Listener.Stop()
        $Responder.Job | Wait-Job -Timeout 3 | Out-Null
        $Responder.Job | Remove-Job -Force
        $Responder.Signal.Dispose()
    }
}
Describe 'Download bodies obey total and idle deadlines' {
    It 'cancels a silent <Phase> peer using the idle timeout' -ForEach @(
        @{ Phase = 'headers'; NoHeaders = $true }, @{ Phase = 'body'; NoHeaders = $false }
    ) {
        $server = Get-StalledResponder -NoHeaders:$NoHeaders
        $client = [Net.Http.HttpClient]::new()
        $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
        $clock = [Diagnostics.Stopwatch]::StartNew()
        try {
            { & $script:AgentModule { param($Client, $Url, $Path)
                Copy-DownloadAgentStream -Client $Client -Uri $Url -OutFile $Path -IdleTimeoutSeconds 1
            } $client $server.Url (Join-Path $TestDrive 'partial') } | Should -Throw
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 8
        } finally { $client.Dispose(); Close-StalledResponder $server }
    }
    It 'reports a partial unknown-size artifact as failed when its total deadline expires' {
        $server = Get-StalledResponder
        $clock = [Diagnostics.Stopwatch]::StartNew()
        try {
            $result = & $script:AgentModule { param($Url, $Path)
                Save-DownloadAgentArtifact -Uri $Url -OutFile $Path -Deadline ([datetime]::UtcNow.AddSeconds(1))
            } $server.Url (Join-Path $TestDrive 'partial-unknown')
            $result.Ok | Should -BeFalse
            $result.ByteCount | Should -Be 10
            $result.Error | Should -Not -BeNullOrEmpty
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 8
        } finally { Close-StalledResponder $server }
    }
    It 'cancels a stalled cache body independently of HttpClient header completion' {
        $server = Get-StalledResponder
        $rsa = [Security.Cryptography.RSA]::Create(2048)
        $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new('CN=fixture', $rsa,
            [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $certificate = $request.CreateSelfSigned([DateTimeOffset]::UtcNow.AddMinutes(-1), [DateTimeOffset]::UtcNow.AddHours(1))
        $pemPath = Join-Path $TestDrive 'ca.pem'
        [IO.File]::WriteAllText($pemPath, $certificate.ExportCertificatePem())
        $clock = [Diagnostics.Stopwatch]::StartNew()
        try {
            { Invoke-HttpsViaSquidBump -Uri $server.Url -OutFile (Join-Path $TestDrive 'cache-partial') `
                -ProxyUrl 'http://127.0.0.1:1' -CaPemPath $pemPath -IdleTimeoutSeconds 1 } | Should -Throw
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 8
            (Get-Item (Join-Path $TestDrive 'cache-partial')).Length | Should -Be 10
        } finally { $certificate.Dispose(); $rsa.Dispose(); Close-StalledResponder $server }
    }
}
Describe 'Interrupted agent responses resume from the bytes already staged' {
    It 'finishes a truncated body through a Range request' {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $url = "http://127.0.0.1:$($listener.LocalEndpoint.Port)/bytes"
        $job = Start-ThreadJob -ArgumentList $listener -ScriptBlock {
            param($Listener)
            try {
                foreach ($attempt in 1, 2) {
                    $peer = $Listener.AcceptTcpClient()
                    try {
                        $stream = $peer.GetStream()
                        $buffer = [byte[]]::new(8192)
                        $count = $stream.Read($buffer, 0, $buffer.Length)
                        $requestText = [Text.Encoding]::ASCII.GetString($buffer, 0, $count)
                        if ($attempt -eq 1) { $reply = "HTTP/1.1 200 OK`r`nContent-Length: 10`r`nConnection: close`r`n`r`n12345" }
                        else {
                            $requestText
                            $reply = "HTTP/1.1 206 Partial Content`r`nContent-Length: 5`r`nContent-Range: bytes 5-9/10`r`nConnection: close`r`n`r`n67890"
                        }
                        $bytes = [Text.Encoding]::ASCII.GetBytes($reply)
                        $stream.Write($bytes, 0, $bytes.Length)
                    } finally { $peer.Dispose() }
                }
            } finally { $Listener.Stop() }
        }
        $path = Join-Path $TestDrive 'resumed'
        try {
            $result = & $script:AgentModule { param($Url, $Path)
                Save-DownloadAgentArtifact -Uri $Url -OutFile $Path -ExpectedByteCount 10 -Deadline ([datetime]::UtcNow.AddSeconds(10))
            } $url $path
            $result.Ok | Should -BeTrue
            [IO.File]::ReadAllText($path) | Should -Be '1234567890'
            $job | Wait-Job -Timeout 3 | Out-Null
            ($job | Receive-Job | Out-String) | Should -Match 'Range: bytes=5-'
        } finally { $listener.Stop(); $job | Remove-Job -Force }
    }
}
