<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42aff78c-5fac-4e32-8d83-77f7da83ba9b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
<#
.SYNOPSIS
    Measure source decisions against the enrolled mirror and frozen public candidate.
.DESCRIPTION
    Run only on a disposable qualification host. The origin fixture changes this
    process's Git environment; the worker controller owns and restores its own
    temporary service override. No operator configuration is rewritten. Receipts,
    actual selected commits, transport attempts and measured outage connections
    are retained instead of accepting a caller's verdict.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('GM-MIRROR-FIRST-HOST-OFFLINE', 'GM-WORKER-OFFLINE',
        'GM-BOTH-ROUTES-OFFLINE', 'GM-MIRROR-RECOVERY', 'GM-MISSING-TRUST', 'GM-AUTH-DENIED')][string]$Scenario,
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$UpstreamsPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$FrameworkTree,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$ProxyHost,
    [string]$SshKeyPath,
    [switch]$DisposableTarget
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $DisposableTarget) { throw 'Source drills require an explicitly disposable qualification host.' }
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'test/modules/Test.HostGit.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'test/modules/Test.SourceSelection.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $root 'test/modules/Test.GitOutageFixture.psm1') -Force -DisableNameChecking
$output = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $output) { throw 'Route evidence already exists; preserve prior observations.' }
$upstreams = Get-Content -Raw -LiteralPath $UpstreamsPath | ConvertFrom-Json -AsHashtable
$repositories = @($upstreams.repositories | Where-Object name -CEQ framework)
if ($repositories.Count -ne 1) { throw 'The prepared fixture must contain exactly one framework repository.' }
$repository = $repositories[0]
if ($repository.canonicalUrl -cne 'https://github.com/alissonsol/yuruna.git' -or
    $repository.candidateCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'The fixture has an invalid public framework identity.' }
$actualTree = [string](& git -C $repository.localPath rev-parse "$($repository.candidateCommit)^{tree}" 2>$null)
if ($LASTEXITCODE -or $actualTree.Trim() -cne $FrameworkTree) { throw 'The prepared origin does not contain the frozen candidate tree.' }
$snapshot = Get-GitSourceConfiguration -ConfigPath $ConfigPath
if ($snapshot.frameworkUrl -and (Get-GitMirrorRepository $snapshot.frameworkUrl) -cne 'alissonsol/yuruna') {
    throw 'The disposable configuration must select the canonical public framework.'
}
$context = @{}
foreach ($key in $snapshot.context.Keys) { $context[$key] = $snapshot.context[$key] }
if ($context.mode -cne 'prefer') { throw 'Host route qualification requires the shipping prefer policy.' }
$configHash = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash
$runId = [guid]::NewGuid().ToString('N')
$workerEvidence = "$output.worker"
$workerActive = $false
$outage = $null
$extraEnvironment = @{}
$samples = [Collections.Generic.List[object]]::new()
$clock = [Diagnostics.Stopwatch]::StartNew()
$result = [ordered]@{
    schema = 'yuruna.git-mirror.native-route/v1'; scenario = $Scenario
    expectedCommit = $repository.candidateCommit; expectedTree = $FrameworkTree
    passed = $false; failure = ''; samples = @(); hostOutageConnections = 0
    configPreserved = $false; workerEvidence = @(); durationSeconds = 0
}

function Get-NativeRouteSelection {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $selected = Resolve-GitSourceSelection -RepositoryUrl $repository.canonicalUrl -Ref HEAD `
        -SourceContext $context -Operation Gate -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(130))
    $samples.Add($selected)
    return $selected
}

try {
    if ($Scenario -cne 'GM-MISSING-TRUST') {
        $initial = Get-NativeRouteSelection
        if (-not $initial.success -or $initial.verification -cne 'mirror-confirmed' -or
            $initial.selectedSha -cne $repository.candidateCommit) {
            throw 'The actual enrolled mirror must first confirm the frozen candidate.'
        }
    }
    if ($Scenario -in @('GM-WORKER-OFFLINE', 'GM-BOTH-ROUTES-OFFLINE', 'GM-MIRROR-RECOVERY', 'GM-AUTH-DENIED')) {
        if (-not $ProxyHost -or -not $SshKeyPath) { throw 'The worker outage requires the disposable proxy SSH identity.' }
        # Mark ownership before launch so a partially applied override is also restored.
        $workerActive = $true
        & (Join-Path $PSScriptRoot 'Invoke-GitMirrorNativeWorker.ps1') -Action EnableOutage `
            -ProxyHost $ProxyHost -SshKeyPath $SshKeyPath -RunId $runId -OutputPath "$workerEvidence.enable.json" `
            -Mode $(if ($Scenario -ceq 'GM-AUTH-DENIED') { 'Unauthorized' } else { 'Reset' })
        $result.workerEvidence += "$workerEvidence.enable.json"
        if ($Scenario -ceq 'GM-AUTH-DENIED') {
            $hostAuthorized = Get-NativeRouteSelection
            if (-not $hostAuthorized.success -or $hostAuthorized.verification -cne 'origin-direct' -or
                $hostAuthorized.fallbackReason -cne 'mirror-auth-denied' -or
                $hostAuthorized.selectedSha -cne $repository.candidateCommit) {
                throw 'Worker authorization failure did not preserve the working host origin route.'
            }
        }
    }
    if ($Scenario -in @('GM-MIRROR-FIRST-HOST-OFFLINE', 'GM-BOTH-ROUTES-OFFLINE', 'GM-MIRROR-RECOVERY', 'GM-AUTH-DENIED')) {
        $outage = New-GitOutageFixture -Mode $(if ($Scenario -ceq 'GM-AUTH-DENIED') { 'Unauthorized' } else { 'Reset' })
        # Prepared fixture rewrites are longer than the broad GitHub rule. Change
        # their values in this process only, so an outage cannot silently reach
        # the healthy local fixture by Git's longest-prefix matching.
        $count = [int]$env:GIT_CONFIG_COUNT
        for ($i = 0; $i -lt $count; $i++) {
            $keyName = "GIT_CONFIG_KEY_$i"
            $valueName = "GIT_CONFIG_VALUE_$i"
            $key = [Environment]::GetEnvironmentVariable($keyName)
            $value = [Environment]::GetEnvironmentVariable($valueName)
            if ($key -match '^url\..+\.insteadOf$' -and $value -in @($repository.canonicalUrl, $repository.canonicalUrl.Substring(0, $repository.canonicalUrl.Length - 4))) {
                $extraEnvironment[$keyName] = $key
                [Environment]::SetEnvironmentVariable($keyName, "url.$($outage.GitEndpoint).insteadOf", 'Process')
            }
        }
        # An exact entry also covers an invocation without the outer qualifier.
        foreach ($pair in @(@("GIT_CONFIG_KEY_$count", "url.$($outage.GitEndpoint).insteadOf"),
                @("GIT_CONFIG_VALUE_$count", $repository.canonicalUrl), @('GIT_CONFIG_COUNT', [string]($count + 1)))) {
            $extraEnvironment[$pair[0]] = [Environment]::GetEnvironmentVariable($pair[0])
            [Environment]::SetEnvironmentVariable($pair[0], $pair[1], 'Process')
        }
    }
    if ($Scenario -ceq 'GM-MISSING-TRUST') { $context.verificationPublicKeys = @() }
    $selected = Get-NativeRouteSelection
    $expectedVerification = switch ($Scenario) {
        'GM-MIRROR-FIRST-HOST-OFFLINE' { 'mirror-confirmed' }
        'GM-WORKER-OFFLINE' { 'origin-direct' }
        'GM-MISSING-TRUST' { 'origin-direct' }
        default { 'mirror-stale' }
    }
    if ($Scenario -ceq 'GM-AUTH-DENIED') {
        if ($selected.success -or $selected.failureClass -cne 'project_access_denied' -or
            @($selected.attempts | Where-Object { $_.source -ceq 'origin' -and -not $_.success }).Count -ne 1) {
            throw 'An actual origin authorization denial did not prevent stale selection.'
        }
    } elseif (-not $selected.success -or $selected.selectedSha -cne $repository.candidateCommit -or
        $selected.verification -cne $expectedVerification) {
        throw "The measured route did not select the same candidate with $expectedVerification."
    }
    if ($Scenario -ceq 'GM-MIRROR-FIRST-HOST-OFFLINE' -and
        (@($selected.attempts | Where-Object source -CEQ origin).Count -ne 0 -or $outage.Clients.Count -ne 0)) {
        throw 'A healthy mirror operation contacted the host origin transport.'
    }
    if ($Scenario -ceq 'GM-MISSING-TRUST' -and ($selected.fallbackReason -cne 'mirror-untrusted' -or
        @($selected.attempts | Where-Object source -CEQ mirror).Count -ne 0)) { throw 'Missing trust incurred a mirror operation.' }
    if ($Scenario -ceq 'GM-MIRROR-RECOVERY') {
        & (Join-Path $PSScriptRoot 'Invoke-GitMirrorNativeWorker.ps1') -Action RestoreOutage `
            -ProxyHost $ProxyHost -SshKeyPath $SshKeyPath -RunId $runId -OutputPath "$workerEvidence.restore.json"
        $workerActive = $false
        $result.workerEvidence += "$workerEvidence.restore.json"
        $recovered = Get-NativeRouteSelection
        if (-not $recovered.success -or $recovered.verification -cne 'mirror-confirmed' -or
            $recovered.selectedSha -cne $repository.candidateCommit) { throw 'The same host process did not rediscover the recovered mirror.' }
    }
    $result.passed = $true
} catch { $result.failure = $_.Exception.Message }
finally {
    if ($workerActive) {
        try {
            & (Join-Path $PSScriptRoot 'Invoke-GitMirrorNativeWorker.ps1') -Action RestoreOutage `
                -ProxyHost $ProxyHost -SshKeyPath $SshKeyPath -RunId $runId -OutputPath "$workerEvidence.restore.json"
            $result.workerEvidence += "$workerEvidence.restore.json"
        } catch { $result.passed = $false; $result.failure += " Worker restoration failed: $($_.Exception.Message)" }
    }
    if ($outage) {
        $result.hostOutageConnections = $outage.Clients.Count
        foreach ($name in $extraEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $extraEnvironment[$name], 'Process') }
        Remove-GitOutageFixture -Fixture $outage
    }
    $clock.Stop()
    $result.configPreserved = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash -ceq $configHash
    if (-not $result.configPreserved) { $result.passed = $false; $result.failure += ' Operator configuration changed.' }
    $result.durationSeconds = $clock.Elapsed.TotalSeconds
    $result.samples = $samples.ToArray()
    [IO.File]::WriteAllText($output, ($result | ConvertTo-Json -Depth 20) + "`n", [Text.UTF8Encoding]::new($false))
}
if (-not $result.passed) { throw $result.failure }
Write-Output $output
