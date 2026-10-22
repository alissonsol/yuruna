<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42b27442-d024-4e11-b9de-4e6650433f1e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
<#
.SYNOPSIS
    Exercise registration, cancellation and isolation in the running services.
.DESCRIPTION
    Run as root inside a disposable provisioned Linux proxy VM. These probes
    enter the actual service namespaces and use the actual serving identities.
    The two temporary registrations are removed in finally. Authentication
    material stays in process memory and is never included in the evidence.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')][string]$Repository,
    [Parameter(Mandatory)][string]$OutputPath,
    [switch]$DisposableTarget
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $DisposableTarget) { throw 'Service sandbox qualification requires an explicitly disposable proxy.' }
if (-not $IsLinux -or (& id -u) -ne '0') { throw 'Native service qualification requires root inside the disposable Linux proxy.' }
$records = [Collections.Generic.List[object]]::new()
$units = @{}
foreach ($name in @('git-mirror-worker', 'git-mirror-reader', 'caching-proxy-service', 'apache2')) {
    $processId = [int](& systemctl show "$name.service" --property=MainPID --value)
    if ($LASTEXITCODE -or $processId -le 0 -or -not (Test-Path "/proc/$processId/ns/mnt")) { throw "Required service is not running: $name" }
    $units[$name] = $processId
}
$repositoryPath = "/var/lib/yuruna/git/$Repository.git"
if (-not (Test-Path -LiteralPath $repositoryPath)) { throw 'Native sandbox probe requires an existing populated mirror.' }
if (-not (Test-Path -LiteralPath /run/yuruna/git-mirror/worker.sock)) { throw 'Signing worker socket is absent.' }
foreach ($pair in @(
        @{ unit = 'apache2'; user = 'www-data' },
        @{ unit = 'git-mirror-reader'; user = 'yuruna-git-reader' })) {
    foreach ($probe in @(
            @{ mode = '-r'; path = '/etc/yuruna/git-mirror/credentials'; expected = $false },
            @{ mode = '-r'; path = '/etc/yuruna/git-mirror/signing-key.pem'; expected = $false },
            @{ mode = '-w'; path = $repositoryPath; expected = $false },
            @{ mode = '-w'; path = '/run/yuruna/git-mirror/worker.sock'; expected = $false },
            @{ mode = '-r'; path = "$repositoryPath/HEAD"; expected = $true })) {
        & nsenter --target $units[$pair.unit] --mount -- runuser -u $pair.user -- test $probe.mode $probe.path
        $allowed = $LASTEXITCODE -eq 0
        $records.Add(@{ unit = $pair.unit; user = $pair.user; processId = $units[$pair.unit]; mode = $probe.mode; path = $probe.path; allowed = $allowed; passed = $allowed -eq $probe.expected })
    }
}
foreach ($path in @('/etc/yuruna/git-mirror/credentials', '/etc/yuruna/git-mirror/signing-key.pem')) {
    & nsenter --target $units['caching-proxy-service'] --mount -- test -r $path
    $records.Add(@{ unit = 'caching-proxy-service'; user = 'root'; processId = $units['caching-proxy-service']; mode = '-r'; path = $path; allowed = $LASTEXITCODE -eq 0; passed = $LASTEXITCODE -ne 0 })
}
$client = [Net.Http.HttpClient]::new()
$client.Timeout = [TimeSpan]::FromSeconds(20)
$registrationPaths = [Collections.Generic.List[string]]::new()
$temporaryRepositories = [Collections.Generic.List[string]]::new()
$failure = ''
$cleanupSucceeded = $false
try {
    $arguments = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes("/proc/$($units['caching-proxy-service'])/cmdline")).Split([char]0)
    $tokenArgument = @($arguments | Where-Object { $_.StartsWith('--auth-token-file=') })
    $addressArgument = @($arguments | Where-Object { $_.StartsWith('--http-addr=') })
    if ($tokenArgument.Count -ne 1 -or $addressArgument.Count -ne 1) { throw 'Cannot identify the running management authentication and listening address.' }
    $tokenPath = $tokenArgument[0].Substring('--auth-token-file='.Length)
    $token = [IO.File]::ReadAllText($tokenPath).Trim()
    if (-not $token) { throw 'Management service has no configured authentication token.' }
    $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
    $token = $null
    $managementAddress = $addressArgument[0].Substring('--http-addr='.Length)
    $managementPort = [int]($managementAddress -replace '^.*:', '')
    $management = "http://127.0.0.1:$managementPort"
    $owner = 'yuruna-qualification-' + [guid]::NewGuid().ToString('N')
    foreach ($suffix in @('one', 'two')) {
        $temporary = "$owner/$suffix"
        $temporaryRepositories.Add($temporary)
        $key = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($temporary)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $path = "/var/lib/yuruna/git-mirror/registrations/$key.json"
        if (Test-Path -LiteralPath $path) { throw 'Disposable registration unexpectedly exists.' }
        $registrationPaths.Add($path)
    }
    $posts = [Collections.Generic.List[object]]::new()
    foreach ($temporary in @($temporaryRepositories.ToArray()) + @($temporaryRepositories.ToArray())) {
        $content = [Net.Http.StringContent]::new((@{ repository = $temporary } | ConvertTo-Json -Compress), [Text.Encoding]::UTF8, 'application/json')
        $posts.Add(@{ content = $content; task = $client.PostAsync("$management/api/git-mirror/repositories", $content) })
    }
    try {
        foreach ($post in $posts) {
            $response = $post.task.GetAwaiter().GetResult()
            try { if ([int]$response.StatusCode -ne 200) { throw "Concurrent registration returned $([int]$response.StatusCode)." } }
            finally { $response.Dispose() }
        }
    } finally { foreach ($post in $posts) { $post.content.Dispose() } }
    foreach ($path in $registrationPaths) {
        $registration = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable
        if ($registration.repository -notin $temporaryRepositories) { throw 'Concurrent registration corrupted its durable record.' }
    }
    $client.DefaultRequestHeaders.Authorization = $null
    $records.Add(@{ check = 'concurrent-registrations'; writers = $posts.Count; durableRecords = $registrationPaths.Count; passed = $true })
    & systemctl restart caching-proxy-service.service git-mirror-worker.service
    if ($LASTEXITCODE) { throw 'Could not restart the actual services for registration persistence.' }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    do {
        try {
            $status = $client.GetStringAsync("$management/git-mirror/status.json").GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
            $present = @($temporaryRepositories | Where-Object { $_ -in @($status.repositories.name) }).Count -eq $temporaryRepositories.Count
        } catch { $present = $false }
        if (-not $present) { Start-Sleep -Milliseconds 250 }
    } while (-not $present -and [DateTimeOffset]::UtcNow -lt $deadline)
    if (-not $present) { throw 'Disposable registrations did not survive the actual service restart.' }
    $records.Add(@{ check = 'registration-restart-persistence'; repositories = $temporaryRepositories.ToArray(); passed = $true })
    $response = $client.GetAsync("http://127.0.0.1/git/$Repository.git/info/refs?service=git-upload-pack").GetAwaiter().GetResult()
    try {
        $records.Add(@{ check = 'serving-identity-upload-pack'; status = [int]$response.StatusCode
                passed = [int]$response.StatusCode -eq 200 -and $response.Content.Headers.ContentType.MediaType -ceq 'application/x-git-upload-pack-advertisement' })
    } finally { $response.Dispose() }
    foreach ($method in @('GET', 'POST')) {
        $url = if ($method -ceq 'GET') { "http://127.0.0.1/git/$Repository.git/info/refs?service=git-receive-pack" } else { "http://127.0.0.1/git/$Repository.git/git-receive-pack" }
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($method), $url)
        try {
            if ($method -ceq 'POST') { $request.Content = [Net.Http.StringContent]::new('0000') }
            $response = $client.Send($request)
            try {
                $denied = [int]$response.StatusCode -in @(403, 404, 405)
                $records.Add(@{ check = 'receive-pack-denied'; method = $method; status = [int]$response.StatusCode; passed = $denied })
            } finally { $response.Dispose() }
        } finally { $request.Dispose() }
    }
    for ($i = 0; $i -lt 8; $i++) {
        $connection = [Net.Sockets.TcpClient]::new()
        try {
            if (-not $connection.ConnectAsync('127.0.0.1', $managementPort).Wait(2000)) { throw 'Cancellation probe could not connect to management.' }
            $partial = [Text.Encoding]::ASCII.GetBytes("POST /git-mirror/v1/resolve HTTP/1.1`r`nHost: localhost`r`nContent-Type: application/json`r`nContent-Length: 4096`r`nConnection: close`r`n`r`n{")
            $connection.GetStream().Write($partial, 0, $partial.Length)
        } finally { $connection.Dispose() }
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $body = @{ repository = $Repository; ref = 'HEAD'; nonce = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).TrimEnd('=').Replace('+', '-').Replace('/', '_') } | ConvertTo-Json -Compress
    $content = [Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, 'application/json')
    try {
        $response = $client.PostAsync("$management/git-mirror/v1/resolve", $content).GetAwaiter().GetResult()
        try {
            $envelope = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
            $passed = [int]$response.StatusCode -eq 200 -and $envelope.Contains('payload') -and $envelope.Contains('signature') -and $clock.Elapsed.TotalSeconds -lt 16
            $records.Add(@{ check = 'disconnected-body-recovery'; canceledRequests = 8; responseSeconds = $clock.Elapsed.TotalSeconds; passed = $passed })
        } finally { $response.Dispose() }
    } finally { $content.Dispose() }
} catch { $failure = $_.Exception.Message }
finally {
    $client.Dispose()
    if ($registrationPaths.Count) {
        try {
            & systemctl stop git-mirror-worker.service
            if ($LASTEXITCODE) { throw 'Could not stop worker before removing disposable registrations.' }
            foreach ($path in $registrationPaths) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
            }
            foreach ($temporary in $temporaryRepositories) {
                $key = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($temporary)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
                foreach ($path in @("/var/lib/yuruna/git/$temporary.git", "/var/lib/yuruna/git-mirror/state/$key.json", "/run/yuruna/git-mirror-readers/$key")) {
                    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
                }
            }
            foreach ($stage in @(Get-ChildItem -LiteralPath /var/lib/yuruna/git-mirror/staging -Directory)) {
                $origin = @(& git -c "safe.directory=$($stage.FullName)" -C $stage.FullName config --get remote.origin.url 2>$null)
                if ($LASTEXITCODE -eq 0 -and ($origin -join '').Trim() -in @($temporaryRepositories | ForEach-Object { "https://github.com/$_.git" })) {
                    Remove-Item -LiteralPath $stage.FullName -Recurse -Force
                }
            }
            $cleanupSucceeded = $true
        } catch { $failure = "$failure Cleanup: $($_.Exception.Message)".Trim() }
        finally {
            & systemctl start git-mirror-worker.service
            if ($LASTEXITCODE) { $cleanupSucceeded = $false; $failure = "$failure Worker restart failed.".Trim() }
        }
    }
}
$result = @{
    schema = 'yuruna.git-mirror.native-service/v1'; recordedAt = [DateTimeOffset]::UtcNow.ToString('o')
    passed = -not $failure -and $cleanupSucceeded -and @($records | Where-Object { -not $_.passed }).Count -eq 0
    checks = $records.ToArray(); cleanupSucceeded = $cleanupSucceeded; failure = $failure
}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), ($result | ConvertTo-Json -Depth 10) + "`n")
if (-not $result.passed) { exit 1 }
