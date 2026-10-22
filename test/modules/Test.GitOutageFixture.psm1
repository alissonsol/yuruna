<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42310dac-f28d-47ee-8578-a5ebec4e7d52
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test git network fixture
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

function New-GitOutageFixture {
    <#
    .SYNOPSIS
        Redirect GitHub Git traffic and direct probes to independent loopback fixtures.
    .DESCRIPTION
        Appends process-local Git settings and restores their original values on
        disposal. The direct TCP endpoint is bound but never listens, so an
        accepting HTTP stall cannot accidentally qualify a TCP-connect probe.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: owns temporary sockets, a runspace and process-local environment, restored by Remove-GitOutageFixture.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([ValidateSet('Stall', 'Reset', 'Unauthorized')][string]$Mode = 'Stall')
    $count = 0
    $rawCount = [Environment]::GetEnvironmentVariable('GIT_CONFIG_COUNT')
    if ($rawCount -and (-not [int]::TryParse($rawCount, [ref]$count) -or $count -lt 0)) {
        throw 'Existing GIT_CONFIG_COUNT is invalid.'
    }
    $fixture = @{
        PreviousEnvironment = @{}; Listener = $null; ProbeSocket = $null
        Worker = $null; Async = $null
        Clients = [Collections.Concurrent.ConcurrentBag[Net.Sockets.TcpClient]]::new()
        PrivateDirectory = Join-Path ([IO.Path]::GetTempPath()) ('git-outage-' + [guid]::NewGuid().ToString('N'))
    }
    try {
        $fixture.Listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $fixture.Listener.Start()
        $fixture.ProbeSocket = [Net.Sockets.Socket]::new([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Stream, [Net.Sockets.ProtocolType]::Tcp)
        $fixture.ProbeSocket.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Loopback, 0))
        $fixture.GitEndpoint = "http://127.0.0.1:$($fixture.Listener.LocalEndpoint.Port)/"
        $fixture.ProbeEndpoint = "http://127.0.0.1:$($fixture.ProbeSocket.LocalEndPoint.Port)"
        $fixture.Worker = [powershell]::Create()
        $null = $fixture.Worker.AddScript({
            param($Listener, $Clients, $Mode)
            while ($true) {
                try { $client = $Listener.AcceptTcpClient() } catch { break }
                $Clients.Add($client)
                if ($Mode -eq 'Reset') {
                    $client.Client.LingerState = [Net.Sockets.LingerOption]::new($true, 0)
                    $client.Dispose()
                } elseif ($Mode -eq 'Unauthorized') {
                    $response = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 401 Unauthorized`r`nWWW-Authenticate: Basic realm=`"fixture`"`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                    try { $client.GetStream().Write($response, 0, $response.Length) } finally { $client.Dispose() }
                }
            }
        }).AddArgument($fixture.Listener).AddArgument($fixture.Clients).AddArgument($Mode)
        $fixture.Async = $fixture.Worker.BeginInvoke()
        $null = [IO.Directory]::CreateDirectory($fixture.PrivateDirectory)
        $changes = @{
            GIT_CONFIG_COUNT = [string]($count + 3)
            YURUNA_GITHUB_PROBE_ENDPOINT = $fixture.ProbeEndpoint
            GH_TOKEN = $null; GITHUB_TOKEN = $null; GH_CONFIG_DIR = $fixture.PrivateDirectory
        }
        $settings = @(
            @("url.$($fixture.GitEndpoint).insteadOf", 'https://github.com/'),
            @('http.lowSpeedLimit', '1'), @('http.lowSpeedTime', '1')
        )
        for ($i = 0; $i -lt $settings.Count; $i++) {
            $changes["GIT_CONFIG_KEY_$($count + $i)"] = $settings[$i][0]
            $changes["GIT_CONFIG_VALUE_$($count + $i)"] = $settings[$i][1]
        }
        foreach ($name in $changes.Keys) {
            $fixture.PreviousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $changes[$name], 'Process')
        }
        return $fixture
    } catch {
        Remove-GitOutageFixture -Fixture $fixture
        throw
    }
}

function Remove-GitOutageFixture {
    <#
    .SYNOPSIS
        Release an outage fixture and restore the caller's process environment.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Disposes only resources owned by the supplied test fixture.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Fixture)
    foreach ($name in $Fixture.PreviousEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $Fixture.PreviousEnvironment[$name], 'Process')
    }
    if ($Fixture.Listener) { $Fixture.Listener.Stop() }
    foreach ($client in $Fixture.Clients) { $client.Dispose() }
    if ($Fixture.ProbeSocket) { $Fixture.ProbeSocket.Dispose() }
    if ($Fixture.Worker) {
        if ($Fixture.Async) {
            try { $null = $Fixture.Worker.EndInvoke($Fixture.Async) } catch { Write-Verbose $_.Exception.Message }
        }
        $Fixture.Worker.Dispose()
    }
    if (Test-Path -LiteralPath $Fixture.PrivateDirectory) {
        Remove-Item -LiteralPath $Fixture.PrivateDirectory -Recurse -Force
    }
}

Export-ModuleMember -Function New-GitOutageFixture, Remove-GitOutageFixture
