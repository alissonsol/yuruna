<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42ea130d-a763-42f7-bb26-62f0af898bb7
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
<#
.SYNOPSIS
    Exercise real proxy provisioning and host enrollment on a disposable host.
.DESCRIPTION
    The private profile supplies a valid configuration and named reference
    hosts, never commands or expected pass labels. The target must be empty
    and explicitly named in StatePath/disposable-target.json. Rebuild scenarios
    require a qualification-prefixed VM name. Every invocation owns a separate
    target, private state directory and immutable observation file.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('GM-PROXY-OWNER-FIRST', 'GM-PROXY-OLD-CHECKOUT',
        'GM-PROXY-NO-STATUS-SERVICE', 'GM-FRESH-LAB-JOIN', 'GM-ROTATE-KEY')][string]$Scenario,
    [Parameter(Mandatory)][string]$TargetRoot,
    [Parameter(Mandatory)][string]$OldRoot,
    [Parameter(Mandatory)][string]$UpstreamsPath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$CandidateTree,
    [Parameter(Mandatory)][string]$ProfilePath,
    [Parameter(Mandatory)][string]$OutputPath,
    [switch]$DisposableTarget
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $DisposableTarget) { throw 'Provisioning qualification requires -DisposableTarget.' }
$root = Split-Path -Parent $PSScriptRoot
$provisionProfile = Get-Content -LiteralPath $ProfilePath -Raw | ConvertFrom-Json -AsHashtable
if ($provisionProfile.schema -cne 'yuruna.git-mirror.native-provision/v1') { throw 'Invalid private provisioning profile.' }
$TargetRoot = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('/', '\')
$statePath = [IO.Path]::GetFullPath($provisionProfile.statePath).TrimEnd('/', '\')
$comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
foreach ($protected in @($root, $OldRoot, $statePath)) {
    $protected = [IO.Path]::GetFullPath($protected).TrimEnd('/', '\')
    if ($TargetRoot.Equals($protected, $comparison) -or
        $TargetRoot.StartsWith($protected + [IO.Path]::DirectorySeparatorChar, $comparison) -or
        $protected.StartsWith($TargetRoot + [IO.Path]::DirectorySeparatorChar, $comparison)) {
        throw 'The disposable checkout must be separate from source and private state.'
    }
}
foreach ($path in @($TargetRoot, $statePath)) {
    $item = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Disposable roots must not be links.' }
}
$marker = Get-Content -LiteralPath (Join-Path $statePath disposable-target.json) -Raw | ConvertFrom-Json -AsHashtable
if ($marker.schema -cne 'yuruna.git-mirror.disposable-target/v1' -or
    -not ([string]$marker.targetRoot).Equals($TargetRoot, $comparison)) { throw 'Disposable target marker does not match.' }
if (@(Get-ChildItem -LiteralPath $TargetRoot -Force).Count) { throw 'Provisioning qualification requires an empty target.' }
$output = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $output) { throw 'Keep prior provisioning observations immutable.' }
$proxyUri = [uri]$provisionProfile.proxyUrl
if ($proxyUri.Scheme -notin @('http', 'https') -or $proxyUri.UserInfo -or $proxyUri.Query -or
    $proxyUri.Fragment -or $proxyUri.AbsolutePath -ne '/') { throw 'The proxy URL must be a credential-free origin.' }
if ($provisionProfile.vmName -cnotmatch '^qualification-[A-Za-z0-9._-]+$') { throw 'A qualification-prefixed VM name is required.' }
Import-Module (Join-Path $root automation/Yuruna.Common.psm1) -Force -DisableNameChecking
Import-Module (Join-Path $root test/modules/Test.HostGit.psm1) -Force -DisableNameChecking
Import-Module (Join-Path $root test/modules/Test.SourceSelection.psm1) -Force -DisableNameChecking
Import-Module (Join-Path $root test/modules/Test.ConfigSync.psm1) -Force -DisableNameChecking
Import-Module (Join-Path $root test/modules/Test.ConfigServiceSync.psm1) -Force -DisableNameChecking
Import-Module powershell-yaml
$fixture = Get-Content (Join-Path $root test/fixtures/git-mirror/public-2026.10.18.2.json) -Raw | ConvertFrom-Json -AsHashtable
$oldHead = [string](& git -C $OldRoot rev-parse HEAD)
if ($LASTEXITCODE -or $oldHead.Trim() -cne $fixture.commit) { throw 'The old checkout is not the frozen public fixture.' }
& git -C $OldRoot diff --exit-code HEAD --
if ($LASTEXITCODE) { throw 'The old source fixture contains modified files.' }
$upstreams = Get-Content -LiteralPath $UpstreamsPath -Raw | ConvertFrom-Json -AsHashtable
$framework = @($upstreams.repositories | Where-Object name -CEQ framework)
if ($framework.Count -ne 1) { throw 'A unique prepared framework upstream is required.' }
$framework = $framework[0]
$tree = [string](& git -C $framework.localPath rev-parse "$($framework.candidateCommit)^{tree}")
if ($LASTEXITCODE -or $tree.Trim() -cne $CandidateTree) { throw 'The prepared upstream differs from the candidate.' }
$configuration = Get-Content -LiteralPath $provisionProfile.configSourcePath -Raw | ConvertFrom-Yaml -Ordered
$failures = @(Test-ConfigMirrorSetting -Config $configuration)
if ($failures.Count) { throw "Invalid fixture configuration: $($failures[0].Cause)" }
if ($configuration.repositories.mirror.mode -cne 'prefer') { throw 'Provisioning scenarios require the shipping prefer policy.' }
$runtime = Join-Path $statePath runtime
if (Test-Path -LiteralPath $runtime) { throw 'Provisioning runtime must be new for this scenario.' }
$null = New-Item -ItemType Directory -Path $runtime
if (-not $IsWindows) { [IO.File]::SetUnixFileMode($runtime, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute) }
$configPath = Join-Path $TargetRoot test/test.config.yml
$result = [ordered]@{
    schema = 'yuruna.git-mirror.native-provision-observation/v1'; scenario = $Scenario
    passed = $false; failure = ''; startedAt = [DateTimeOffset]::UtcNow.ToString('o')
    sourceCommit = ''; sourceTree = ''; status = $null; sourceSelections = @()
    configBackupVerified = $false; rejectedReferencePreserved = $false; oldReferenceRejected = $false
    keyIds = @(); statusServiceRestored = $false; rotationRestored = $false; cycleSource = $null; origins = $null
}
$savedRuntime = $env:YURUNA_RUNTIME_DIR
$statusStopped = $false
$rotationActive = $false
$originsActive = $false
$originsId = [guid]::NewGuid().ToString('N')
$clock = [Diagnostics.Stopwatch]::StartNew()
$handler = [Net.Http.HttpClientHandler]::new()
$handler.UseProxy = $false; $handler.AllowAutoRedirect = $false
$client = [Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(10)

function Invoke-ProvisionGit {
    param([string[]]$Arguments)
    $native = Invoke-BoundedNativeCommand -FilePath git -ArgumentList $Arguments -TimeoutSeconds 60
    if ($native.ExitCode -ne 0 -or $native.TimedOut) { throw "Disposable Git operation failed: $($native.StdErr)" }
    return $native.StdOut.Trim()
}
function Invoke-ProvisionEntryPoint {
    param([string]$Path, [string[]]$Arguments, [int]$TimeoutSeconds = 180)
    $native = Invoke-BoundedNativeCommand -FilePath ([Environment]::ProcessPath) `
        -ArgumentList (@('-NoProfile', '-NonInteractive', '-File', $Path) + $Arguments) -TimeoutSeconds $TimeoutSeconds
    if ($native.StdOut) { Write-Information $native.StdOut -InformationAction Continue }
    if ($native.ExitCode -ne 0 -or $native.TimedOut) { throw "Production entry point failed: $Path; $($native.StdErr)" }
}
function Get-ProvisionStatus {
    param([switch]$AllowMissing)
    $response = $client.GetAsync($proxyUri.AbsoluteUri.TrimEnd('/') + '/git-mirror/status.json').GetAwaiter().GetResult()
    try {
        if ($AllowMissing -and [int]$response.StatusCode -eq 404) { return $null }
        $null = $response.EnsureSuccessStatusCode()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if ($body.Length -gt 1048576) { throw 'Mirror status exceeds the evidence limit.' }
        $value = $body | ConvertFrom-Json -AsHashtable
        if ($value.apiVersion -ne 1) { throw 'Mirror protocol is missing.' }
        return $value
    } finally { $response.Dispose() }
}
function Get-ProvisionSelection {
    param([AllowNull()][hashtable]$Context)
    if (-not $Context) { $Context = (Get-GitSourceConfiguration -ConfigPath $configPath).context }
    $selected = Resolve-GitSourceSelection -RepositoryUrl https://github.com/alissonsol/yuruna.git -Ref HEAD `
        -SourceContext $Context -Operation Gate -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(130))
    $result.sourceSelections += $selected
    return $selected
}
function Assert-ProvisionMirror {
    param([hashtable]$Selection)
    if (-not $Selection.success -or $Selection.verification -cne 'mirror-confirmed' -or
        $Selection.selectedSha -cne $framework.candidateCommit -or
        @($Selection.attempts | Where-Object source -CEQ origin).Count) {
        throw 'The actual mirror did not confirm the frozen candidate without origin fallback.'
    }
}
function Invoke-ProvisionCycle {
    # This entry point runs the shipping gate and project cycle. A resolver
    # sample alone does not prove that the next cycle records its selection.
    Invoke-ProvisionEntryPoint -Path (Join-Path $TargetRoot test/Invoke-TestProject.ps1) `
        -Arguments @('-ConfigPath',$configPath,'-NoStatusService') -TimeoutSeconds 1800
    $installed = Read-InstalledGitSource -RepoRoot $TargetRoot
    if (-not $installed.ContainsKey('project') -or $installed.project.verification -cne 'mirror-confirmed') {
        throw 'The real project cycle did not retain mirror-confirmed provenance.'
    }
    $result.cycleSource = $installed.project
}
function Invoke-ProvisionRotation {
    param([ValidateSet('Prepare', 'Switch', 'Restore')][string]$Action)
    $request = @{action=$Action;runId=$rotationId}
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($request | ConvertTo-Json -Compress)))
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command ssh -CommandType Application).Source)
    foreach ($argument in @('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=10',
            '-i',[IO.Path]::GetFullPath($provisionProfile.sshKeyPath),$provisionProfile.proxyHost,
            "sudo -n python3 -c 'import sys; s=sys.stdin.read(); exec(compile(s,`"native-rotation`",`"exec`"),{`"__name__`":`"__main__`",`"_PROGRAM`":s})' $encoded")) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute=$false; $start.RedirectStandardInput=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $process = [Diagnostics.Process]::Start($start)
    try {
        $out=$process.StandardOutput.ReadToEndAsync(); $err=$process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write([IO.File]::ReadAllText((Join-Path $PSScriptRoot git_mirror_native_rotation.py)))
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(120000)) { $process.Kill($true); throw 'Key rotation control timed out; automatic restore remains armed.' }
        if ($process.ExitCode) { throw "Key rotation control failed: $($err.GetAwaiter().GetResult())" }
        return ($out.GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable)
    } finally { if (-not $process.HasExited) { $process.Kill($true) }; $process.Dispose() }
}

try {
    $env:YURUNA_RUNTIME_DIR = $runtime
    $source = if ($Scenario -ceq 'GM-PROXY-OLD-CHECKOUT') { $OldRoot } else { $framework.localPath }
    $null = Invoke-ProvisionGit @('clone','--no-hardlinks','--no-checkout','--',$source,$TargetRoot)
    $commit = if ($Scenario -ceq 'GM-PROXY-OLD-CHECKOUT') { $fixture.commit } else { $framework.candidateCommit }
    $null = Invoke-ProvisionGit @('-C',$TargetRoot,'checkout','--detach',$commit)
    $null = Invoke-ProvisionGit @('-C',$TargetRoot,'remote','set-url','origin','https://github.com/alissonsol/yuruna.git')
    $result.sourceCommit = Invoke-ProvisionGit @('-C',$TargetRoot,'rev-parse','HEAD')
    $result.sourceTree = Invoke-ProvisionGit @('-C',$TargetRoot,'rev-parse','HEAD^{tree}')
    Copy-Item -LiteralPath $provisionProfile.configSourcePath -Destination $configPath
    if (-not $IsWindows) { [IO.File]::SetUnixFileMode($configPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite) }
    if ($Scenario -in @('GM-PROXY-OWNER-FIRST','GM-PROXY-OLD-CHECKOUT','GM-PROXY-NO-STATUS-SERVICE')) {
        if ($Scenario -ceq 'GM-PROXY-NO-STATUS-SERVICE') {
            # The provisioning entry point honors this setting; merely stopping
            # the service first would let it start it again before seeding.
            $disabled = Get-Content $configPath -Raw | ConvertFrom-Yaml -Ordered
            if (-not $disabled.statusService.enabled) { throw 'The profile must begin with an enabled status service.' }
            Write-Information "statusService.enabled: True -> False (backup: $($provisionProfile.configSourcePath))" -InformationAction Continue
            $disabled.statusService.enabled=$false
            $null = Write-DocumentedTestConfig -ConfigPath $configPath -Config $disabled -TemplatePath ($configPath+'.template') -Confirm:$false
            $statusStopped = $true
            Invoke-ProvisionEntryPoint (Join-Path $TargetRoot test/service/Stop-StatusService.ps1) @()
            if (Test-Path (Join-Path $runtime status-service.json)) { throw 'The status service was not stopped.' }
        } else {
            Invoke-ProvisionEntryPoint (Join-Path $TargetRoot test/service/Start-StatusService.ps1) @()
        }
        Invoke-ProvisionEntryPoint -Path (Join-Path $TargetRoot test/service/Start-CachingProxyServiceVM.ps1) `
            -Arguments @('-VMName',$provisionProfile.vmName,'-ForceRebuild') -TimeoutSeconds 3600
        $package = $client.GetAsync($proxyUri.AbsoluteUri).GetAwaiter().GetResult()
        try { $null=$package.EnsureSuccessStatusCode() } finally { $package.Dispose() }
        Import-Module (Join-Path $root test/modules/Test.CachingProxyService.psm1) -Force -DisableNameChecking
        $packageHealth = Invoke-CachingProxyServiceProbe -CacheIp $proxyUri.Host -CacheSource qualification
        if (-not $packageHealth.Success -or -not $packageHealth.HttpProxyReachable) { throw 'The rebuilt package proxy failed its production health probe.' }
        $result.status = Get-ProvisionStatus -AllowMissing:($Scenario -ceq 'GM-PROXY-OLD-CHECKOUT')
        if ($Scenario -ceq 'GM-PROXY-OLD-CHECKOUT') {
            if ($null -ne $result.status) { throw 'The public old proxy unexpectedly advertises mirror capability.' }
            $context = (Get-GitSourceConfiguration -ConfigPath $configPath).context
            $context.url = $proxyUri.AbsoluteUri.TrimEnd('/')
            if (@($context.verificationPublicKeys).Count -eq 0) { throw 'Old-proxy fallback needs an enrolled test key to exercise capability discovery.' }
            $selected = Get-ProvisionSelection $context
            if (-not $selected.success -or $selected.verification -cne 'origin-direct' -or
                $selected.fallbackReason -cne 'mirror-unavailable') { throw 'The old proxy did not select bounded origin fallback.' }
        } else {
            $expectedSource = if ($Scenario -ceq 'GM-PROXY-NO-STATUS-SERVICE') { 'github' } else { 'host' }
            if ($result.status.buildSource.source -cne $expectedSource -or
                $result.status.buildSource.commit -cne $commit -or -not $result.status.keyId -or
                $result.status.version -cne ([IO.File]::ReadAllText((Join-Path $TargetRoot VERSION))).Trim()) {
                throw 'The rebuilt mirror has the wrong source identity or signing key.'
            }
            $originsActive = $true
            & (Join-Path $PSScriptRoot Invoke-GitMirrorNativeOrigins.ps1) -Action Prepare -ProxyHost $provisionProfile.proxyHost `
                -SshKeyPath $provisionProfile.sshKeyPath -RunId $originsId -UpstreamsPath $UpstreamsPath `
                -OutputPath ($output+'.origins.json') -DisposableTarget
            $result.origins = Get-Content ($output+'.origins.json') -Raw | ConvertFrom-Json -AsHashtable
            Import-Module (Join-Path $root test/modules/Test.CachingProxyService.psm1) -Force -DisableNameChecking
            $null = Set-CachingProxyGitMirrorEnrollment -ConfigPath $configPath -ProxyIp $proxyUri.Host -Confirm:$false
            $deadline = [DateTimeOffset]::UtcNow.AddMinutes(30)
            do {
                $selected = Get-ProvisionSelection
                if ($selected.success -and $selected.verification -ceq 'mirror-confirmed') { break }
                Start-Sleep -Seconds 5
            } while ([DateTimeOffset]::UtcNow -lt $deadline)
            Assert-ProvisionMirror $selected
            $result.keyIds = @((Get-Content $configPath -Raw | ConvertFrom-Yaml).repositories.mirror.verificationPublicKeys | ForEach-Object { Get-ConfigMirrorKeyId -Value $_ })
            Invoke-ProvisionCycle
        }
    } elseif ($Scenario -ceq 'GM-FRESH-LAB-JOIN') {
        $before = [IO.File]::ReadAllBytes($configPath)
        $rejected = $false
        try { $null = Sync-HostConfiguration -ReferenceHost $provisionProfile.referenceHost -StatusPort $provisionProfile.referencePort -RepoRoot $TargetRoot -NonInteractive -SkipValidation -NoPool }
        catch { if ($_.Exception.Message -notmatch 'mirror-key-confirmation-required') { throw }; $rejected=$true }
        if (-not $rejected -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -cne [Convert]::ToBase64String($before)) { throw 'Unconfirmed reference trust changed the local file.' }
        $reports = [Collections.Generic.List[string]]::new()
        $null = Sync-HostConfiguration -ReferenceHost $provisionProfile.referenceHost -StatusPort $provisionProfile.referencePort -RepoRoot $TargetRoot `
            -NonInteractive -SkipValidation -NoPool -AcceptMirrorKey -InformationVariable enrollmentReports
        foreach ($report in $enrollmentReports) { $reports.Add([string]$report) }
        if (-not ($reports -match 'repositories.mirror.verificationPublicKeys:.* -> ')) { throw 'Enrollment did not report previous and new fingerprints.' }
        $result.configBackupVerified = [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath+'.backup')) -ceq [Convert]::ToBase64String($before)
        if (-not $result.configBackupVerified) { throw 'Sync backup does not preserve the previous configuration.' }
        Assert-ProvisionMirror (Get-ProvisionSelection)
        Invoke-ProvisionCycle
        foreach ($reference in @(@{host=$provisionProfile.tamperedReferenceHost;port=$provisionProfile.tamperedReferencePort;kind='tampered'},@{host=$provisionProfile.oldReferenceHost;port=$provisionProfile.oldReferencePort;kind='old'})) {
            $referenceConfig = Get-ConfigSyncReferenceConfig -ReferenceHost $reference.host -Port $reference.port
            if ($reference.kind -ceq 'old') {
                $freshness = Test-ConfigSyncReferenceFreshness -Reference $referenceConfig -TemplatePath ($configPath+'.template')
                if ($freshness.IsCurrent -or 'repositories.mirror.verificationPublicKeys' -notin $freshness.Missing) {
                    throw 'The old reference fixture must actually lack the mirror schema.'
                }
            } else {
                $changes = @(Get-ConfigMirrorChange -Current (Get-Content $configPath -Raw | ConvertFrom-Yaml -Ordered) -Proposed $referenceConfig)
                if (-not @($changes | Where-Object Path -CEQ repositories.mirror.verificationPublicKeys).Count) {
                    throw 'The tampered reference must actually propose a different trust list.'
                }
            }
            $before = [IO.File]::ReadAllBytes($configPath)
            $rejected=$false
            try { $null = Sync-HostConfiguration -ReferenceHost $reference.host -StatusPort $reference.port -RepoRoot $TargetRoot -NonInteractive -SkipValidation -NoPool }
            catch {
                if ($reference.kind -ceq 'tampered' -and $_.Exception.Message -notmatch 'mirror-key-confirmation-required') { throw }
                $rejected=$true
            }
            if (-not $rejected -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath)) -cne [Convert]::ToBase64String($before)) { throw 'An unconfirmed reference changed the enrolled configuration.' }
            if ($reference.kind -ceq 'old') { $result.oldReferenceRejected=$true } else { $result.rejectedReferencePreserved=$true }
        }
    } else {
        if ($provisionProfile.proxyHost -cnotmatch '^[A-Za-z0-9_.@:-]+$') { throw 'Invalid disposable proxy SSH host.' }
        $beforeContext = (Get-GitSourceConfiguration -ConfigPath $configPath).context
        Assert-ProvisionMirror (Get-ProvisionSelection $beforeContext)
        $rotationId = [guid]::NewGuid().ToString('N')
        $rotationActive = $true
        $prepared = Invoke-ProvisionRotation Prepare
        $keyId = Get-ConfigMirrorKeyId -Value $prepared.publicKey
        if ($keyId -cne $prepared.keyId) { throw 'Prepared rotation public identity is invalid.' }
        $overlap = (Get-Content $configPath -Raw | ConvertFrom-Yaml -Ordered)
        $overlap.repositories.mirror.verificationPublicKeys = @($overlap.repositories.mirror.verificationPublicKeys) + @($prepared.publicKey)
        $before = [IO.File]::ReadAllBytes($configPath)
        foreach ($change in @(Get-ConfigMirrorChange -Current (Get-Content $configPath -Raw | ConvertFrom-Yaml -Ordered) -Proposed $overlap)) {
            Write-Information "$($change.Path): $($change.Previous) -> $($change.Current) (backup: $configPath.backup)" -InformationAction Continue
        }
        Copy-Item $configPath ($configPath+'.backup')
        $null = Write-DocumentedTestConfig -ConfigPath $configPath -Config $overlap -TemplatePath ($configPath+'.template') -Confirm:$false
        $result.configBackupVerified = [Convert]::ToBase64String([IO.File]::ReadAllBytes($configPath+'.backup')) -ceq [Convert]::ToBase64String($before)
        if (-not $result.configBackupVerified) { throw 'Rotation enrollment lost its recoverable configuration.' }
        Assert-ProvisionMirror (Get-ProvisionSelection)
        $null = Invoke-ProvisionRotation Switch
        Assert-ProvisionMirror (Get-ProvisionSelection)
        Invoke-ProvisionCycle
        $missed = Get-ProvisionSelection $beforeContext
        if (-not $missed.success -or $missed.verification -cne 'origin-direct' -or
            $missed.fallbackReason -cne 'mirror-key-not-enrolled') { throw 'A host missing the rotation did not report mirror-key-not-enrolled.' }
        $result.keyIds = @($beforeContext.verificationPublicKeys | ForEach-Object { Get-ConfigMirrorKeyId -Value $_ }) + @($keyId)
    }
    $result.passed = $true
} catch { $result.failure = $_.Exception.Message }
finally {
    if ($rotationActive) {
        try { $restored=Invoke-ProvisionRotation Restore; $result.rotationRestored=[bool]$restored.restored; if (-not $result.rotationRestored) { throw 'Rotation restore was not confirmed.' } }
        catch { $result.passed=$false; $result.failure=($result.failure+' Restore: '+$_.Exception.Message).Trim() }
    }
    if ($statusStopped) {
        try {
            $enabled = Get-Content $configPath -Raw | ConvertFrom-Yaml -Ordered
            Write-Information "statusService.enabled: False -> True (backup: $($provisionProfile.configSourcePath))" -InformationAction Continue
            $enabled.statusService.enabled=$true
            $null = Write-DocumentedTestConfig -ConfigPath $configPath -Config $enabled -TemplatePath ($configPath+'.template') -Confirm:$false
            Invoke-ProvisionEntryPoint (Join-Path $TargetRoot test/service/Start-StatusService.ps1) @()
            $result.statusServiceRestored=$true
        }
        catch { $result.passed=$false; $result.failure=($result.failure+' Status restore: '+$_.Exception.Message).Trim() }
    }
    if ($originsActive) {
        try {
            & (Join-Path $PSScriptRoot Invoke-GitMirrorNativeOrigins.ps1) -Action Restore -ProxyHost $provisionProfile.proxyHost `
                -SshKeyPath $provisionProfile.sshKeyPath -RunId $originsId -OutputPath ($output+'.origins-restored.json') -DisposableTarget
        } catch { $result.passed=$false; $result.failure=($result.failure+' Origin restore: '+$_.Exception.Message).Trim() }
    }
    $client.Dispose(); $env:YURUNA_RUNTIME_DIR=$savedRuntime; $clock.Stop()
    $result.durationSeconds=$clock.Elapsed.TotalSeconds
    [IO.File]::WriteAllText($output, ($result | ConvertTo-Json -Depth 25)+"`n")
}
if (-not $result.passed) { throw "Native provisioning observation failed: $($result.failure)" }
