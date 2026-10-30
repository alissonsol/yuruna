<#PSScriptInfo
.VERSION 2026.10.30
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
            { Invoke-YurunaResumableDownload -Uri $server.Url -OutFile (Join-Path $TestDrive 'partial') -IdleTimeoutSeconds 1 -MaxAttempt 1 } | Should -Throw
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
            (Get-Item (Join-Path $TestDrive 'cache-partial.partial')).Length | Should -Be 10 -Because 'the bytes that arrived stay staged for the next attempt'
            Test-Path -LiteralPath (Join-Path $TestDrive 'cache-partial') | Should -BeFalse -Because 'only a complete transfer takes the destination name'
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

Describe 'A download cut short resumes at its next attempt, and only on the same bytes' {
    BeforeAll {
        # Answers one scripted reply per connection and hands back each
        # request's text, so a case can read the headers the engine sent.
        function Get-ScriptedResponder {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'The listener and replies are explicit thread-job arguments.')]
            param([string[]]$Reply)
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
            $listener.Start()
            $job = Start-ThreadJob -ArgumentList $listener, $Reply -ScriptBlock {
                param($Listener, $Replies)
                try {
                    foreach ($reply in $Replies) {
                        $peer = $Listener.AcceptTcpClient()
                        try {
                            $stream = $peer.GetStream()
                            $buffer = [byte[]]::new(8192)
                            $count = $stream.Read($buffer, 0, $buffer.Length)
                            [Text.Encoding]::ASCII.GetString($buffer, 0, $count)
                            $bytes = [Text.Encoding]::ASCII.GetBytes($reply)
                            $stream.Write($bytes, 0, $bytes.Length)
                            $stream.Flush()
                        } finally { $peer.Dispose() }
                    }
                } finally { $Listener.Stop() }
            }
            $responder = @{ Url = "http://127.0.0.1:$($listener.LocalEndpoint.Port)/disk.img"; Listener = $listener; Job = $job }
            $script:OpenResponders.Add($responder)
            return $responder
        }
        function Close-ScriptedResponder {
            param($Responder)
            $Responder.Listener.Stop()
            $Responder.Job | Wait-Job -Timeout 5 | Out-Null
            $requests = @($Responder.Job | Receive-Job -ErrorAction SilentlyContinue)
            $Responder.Job | Remove-Job -Force -ErrorAction SilentlyContinue
            [void]$script:OpenResponders.Remove($Responder)
            return $requests
        }
        $script:Cut = "HTTP/1.1 200 OK`r`nContent-Length: 10`r`nETag: `"v1`"`r`nConnection: close`r`n`r`n12345"
    }
    BeforeEach {
        $script:Out = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).img"
        $script:OpenResponders = [System.Collections.Generic.List[object]]::new()
    }
    # A case that fails before closing its responder must not leave a listener
    # thread holding the suite's process open.
    AfterEach { foreach ($responder in @($script:OpenResponders)) { $null = Close-ScriptedResponder $responder } }

    It 'asks a later call for only the remainder, under the validator it recorded' {
        $first = Get-ScriptedResponder -Reply @($script:Cut)
        { Invoke-YurunaResumableDownload -Uri $first.Url -OutFile $script:Out -MaxAttempt 1 -IdleTimeoutSeconds 5 } | Should -Throw
        $null = Close-ScriptedResponder $first
        Test-Path -LiteralPath $script:Out | Should -BeFalse -Because 'a cut transfer never takes the destination name'
        (Get-Item -LiteralPath "$($script:Out).partial").Length | Should -Be 5
        $second = Get-ScriptedResponder -Reply @("HTTP/1.1 206 Partial Content`r`nContent-Length: 5`r`nContent-Range: bytes 5-9/10`r`nETag: `"v1`"`r`nConnection: close`r`n`r`n67890")
        # The second call reaches the same bytes at a new address only in this
        # fixture; the record names the URI, so the case keeps it.
        $sidecar = Get-Content -Raw -LiteralPath "$($script:Out).partial.json" | ConvertFrom-Json -AsHashtable
        $sidecar.uri = $second.Url
        Set-Content -LiteralPath "$($script:Out).partial.json" -Value ($sidecar | ConvertTo-Json -Compress)
        Invoke-YurunaResumableDownload -Uri $second.Url -OutFile $script:Out -IdleTimeoutSeconds 5 | Should -Be 10
        $requests = Close-ScriptedResponder $second
        [IO.File]::ReadAllText($script:Out) | Should -Be '1234567890'
        ($requests -join "`n") | Should -Match 'Range: bytes=5-'
        ($requests -join "`n") | Should -Match 'If-Range: "v1"'
        Test-Path -LiteralPath "$($script:Out).partial" | Should -BeFalse
        Test-Path -LiteralPath "$($script:Out).partial.json" | Should -BeFalse
    }
    It 'starts again from zero when the bytes changed under their validator' {
        $server = Get-ScriptedResponder -Reply @($script:Cut, "HTTP/1.1 200 OK`r`nContent-Length: 10`r`nETag: `"v2`"`r`nConnection: close`r`n`r`nabcdefghij")
        Invoke-YurunaResumableDownload -Uri $server.Url -OutFile $script:Out -MaxAttempt 2 -IdleTimeoutSeconds 5 | Should -Be 10
        $requests = Close-ScriptedResponder $server
        [IO.File]::ReadAllText($script:Out) | Should -Be 'abcdefghij' -Because 'the server answered the If-Range request in full, so nothing old is spliced in'
        $requests[1] | Should -Match 'If-Range: "v1"'
    }
    It 'never resumes a transfer whose server sent no validator' {
        $server = Get-ScriptedResponder -Reply @("HTTP/1.1 200 OK`r`nContent-Length: 10`r`nConnection: close`r`n`r`n12345")
        { Invoke-YurunaResumableDownload -Uri $server.Url -OutFile $script:Out -MaxAttempt 1 -IdleTimeoutSeconds 5 } | Should -Throw
        $null = Close-ScriptedResponder $server
        $again = Get-ScriptedResponder -Reply @("HTTP/1.1 200 OK`r`nContent-Length: 10`r`nConnection: close`r`n`r`n1234567890")
        $sidecar = Get-Content -Raw -LiteralPath "$($script:Out).partial.json" | ConvertFrom-Json -AsHashtable
        $sidecar.uri = $again.Url
        Set-Content -LiteralPath "$($script:Out).partial.json" -Value ($sidecar | ConvertTo-Json -Compress)
        Invoke-YurunaResumableDownload -Uri $again.Url -OutFile $script:Out -IdleTimeoutSeconds 5 | Should -Be 10
        $requests = Close-ScriptedResponder $again
        $requests[0] | Should -Not -Match 'Range:'
        [IO.File]::ReadAllText($script:Out) | Should -Be '1234567890'
    }
    It 'reports a refusal no retry changes at once, with its status for the caller' {
        $server = Get-ScriptedResponder -Reply @("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n", "HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
        { Invoke-YurunaResumableDownload -Uri $server.Url -OutFile $script:Out -MaxAttempt 3 -IdleTimeoutSeconds 5 } | Should -Throw -ExpectedMessage '*404*'
        $server.Listener.Stop()
        @(Close-ScriptedResponder $server).Count | Should -Be 1 -Because 'a 404 is not retried'
    }
    It 'finishes, with no transfer, a partial its server says is already whole' {
        $server = Get-ScriptedResponder -Reply @("HTTP/1.1 416 Range Not Satisfiable`r`nContent-Range: bytes */10`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
        [IO.File]::WriteAllText("$($script:Out).partial", '1234567890')
        Set-Content -LiteralPath "$($script:Out).partial.json" -Value (ConvertTo-Json -Compress -InputObject @{ uri = $server.Url; etag = '"v1"'; lastModified = ''; length = 0 })
        Invoke-YurunaResumableDownload -Uri $server.Url -OutFile $script:Out -IdleTimeoutSeconds 5 | Should -Be 10
        $null = Close-ScriptedResponder $server
        [IO.File]::ReadAllText($script:Out) | Should -Be '1234567890'
    }
    It 'resumes on the direct path a driver with no cache takes' {
        $server = Get-ScriptedResponder -Reply @($script:Cut)
        { Save-CachedHttpUri -Uri $server.Url -OutFile $script:Out } | Should -Throw
        $null = Close-ScriptedResponder $server
        Test-Path -LiteralPath "$($script:Out).partial.json" | Should -BeTrue -Because 'Save-CachedHttpUri runs on the resumable engine'
    }
}
