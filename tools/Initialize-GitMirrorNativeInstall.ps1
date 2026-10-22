<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42ade151-5e4e-4637-bbf8-67abbffea511
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -Version 7
<#
.SYNOPSIS
    Prepare and measure explicitly disposable native installer qualification.
.DESCRIPTION
    The operator must create StatePath/disposable-target.json with schema
    yuruna.git-mirror.disposable-target/v1 and the absolute targetRoot first.
    Prepare refuses a nonempty target. No action changes the protected old or
    candidate sources. Runtime observations come from real production records;
    this driver never creates launch evidence or changes cleanExit.
    Run each recipe with a separate empty target and private state directory.
.PARAMETER ConfigSourcePath
    Valid host configuration with a non-default project URL. Prepare copies it
    to the selected configuration; fresh setup must obtain the same value from
    its separately supplied setup answer file.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Prepare', 'Capture', 'Observe', 'UpdateLegacy', 'Diverge', 'StartCaptured', 'StopFixture', 'AdvanceOrigin', 'WaitAdoption', 'Enroll', 'RunGate', 'Drain', 'VerifyCleanStop', 'WaitMirrorCycle')][string]$Action,
    [ValidateSet('Main', 'Pin', 'Fresh')][string]$Mode = 'Main',
    [Parameter(Mandatory)][string]$TargetRoot,
    [Parameter(Mandatory)][string]$OldRoot,
    [Parameter(Mandatory)][string]$StatePath,
    [Parameter(Mandatory)][string]$RuntimeDir,
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$ConfigSourcePath,
    [string]$SnapshotPath,
    [switch]$RequireRunner,
    [switch]$ExpectStopped,
    [switch]$AutomaticOrigin,
    [string]$MirrorKeyExportPath,
    [string]$MirrorUrl,
    [ValidateSet('off', 'fallback', 'prefer')][string]$MirrorMode,
    [ValidateSet('Pass', 'OldRollback', 'NewRollback')][string]$GateExpectation = 'Pass',
    [ValidatePattern('^[0-9a-f]{40}$')][string]$CandidateTree,
    [ValidateRange(1, 120)][int]$TimeoutSeconds = 60,
    [ValidateRange(1, 7200)][int]$AdoptionTimeoutSeconds = 1800,
    [switch]$DisposableTarget
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$candidateRoot = Split-Path -Parent $PSScriptRoot
$comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
foreach ($name in @('TargetRoot', 'OldRoot', 'StatePath', 'RuntimeDir', 'ConfigPath', 'ConfigSourcePath')) {
    Set-Variable -Name $name -Value ([IO.Path]::GetFullPath((Get-Variable -Name $name -ValueOnly)).TrimEnd('/', '\'))
}
if (-not $DisposableTarget) { throw 'Fixture preparation requires -DisposableTarget.' }
foreach ($protected in @($candidateRoot, $OldRoot, $StatePath)) {
    if ($protected.Equals($TargetRoot, $comparison) -or
        $protected.StartsWith($TargetRoot + [IO.Path]::DirectorySeparatorChar, $comparison) -or
        $TargetRoot.StartsWith($protected + [IO.Path]::DirectorySeparatorChar, $comparison)) {
        throw 'The target must not contain a candidate, old fixture or private state directory.'
    }
}
foreach ($path in @($TargetRoot, $StatePath, $ConfigSourcePath)) {
    $item = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Native fixture paths must not be links.' }
}
$marker = Get-Content -LiteralPath (Join-Path $StatePath 'disposable-target.json') -Raw | ConvertFrom-Json -AsHashtable
if ($marker.schema -cne 'yuruna.git-mirror.disposable-target/v1' -or
    -not ([string]$marker.targetRoot).Equals($TargetRoot, $comparison)) { throw 'Disposable target marker does not match.' }
if (-not $RuntimeDir.StartsWith($StatePath + [IO.Path]::DirectorySeparatorChar, $comparison)) { throw 'Fixture runtime must be under its private state directory.' }
if (-not $ConfigPath.StartsWith($TargetRoot + [IO.Path]::DirectorySeparatorChar, $comparison) -and
    -not $ConfigPath.StartsWith($StatePath + [IO.Path]::DirectorySeparatorChar, $comparison)) { throw 'Fixture configuration must belong to its target or private state directory.' }
if ($SnapshotPath) {
    $SnapshotPath = [IO.Path]::GetFullPath($SnapshotPath)
    if (-not $SnapshotPath.StartsWith($StatePath + [IO.Path]::DirectorySeparatorChar, $comparison)) { throw 'Fixture snapshot must belong to its private state directory.' }
}
# All writes stay below the two explicitly disposable roots, including when a
# preexisting child path is a symbolic link or Windows junction.
$originPath = Join-Path $StatePath 'adoption-origin.git'
foreach ($path in @($RuntimeDir, $ConfigPath, $SnapshotPath, $originPath,
        (Join-Path $StatePath 'observed.json'), (Join-Path $StatePath 'stopped.json'),
        (Join-Path $StatePath 'advance.json'), (Join-Path $StatePath 'adoption.json'),
        (Join-Path $StatePath 'initial.json'), (Join-Path $StatePath 'enrollment.json'),
        (Join-Path $StatePath 'drain-origin'), (Join-Path $StatePath 'drain-config.yml'),
        (Join-Path $StatePath 'clean-stop.json'), (Join-Path $StatePath 'mirror-cycle.json'),
        (Join-Path $StatePath "gate-$GateExpectation.json"), (Join-Path $StatePath "gate-$GateExpectation.log"))) {
    if (-not $path) { continue }
    $ancestor = $path
    while ($ancestor -and -not $ancestor.Equals($TargetRoot, $comparison) -and -not $ancestor.Equals($StatePath, $comparison)) {
        $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction SilentlyContinue
        if ($item -and $item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Native fixture descendants must not be links.' }
        $ancestor = Split-Path -Parent $ancestor
    }
}
$fixture = Get-Content -LiteralPath (Join-Path $candidateRoot 'test/fixtures/git-mirror/public-2026.10.18.2.json') -Raw | ConvertFrom-Json -AsHashtable
$oldHead = [string](& git -C $OldRoot rev-parse HEAD)
if ($LASTEXITCODE -ne 0 -or $oldHead.Trim() -cne $fixture.commit) { throw 'Old source is not the frozen public fixture.' }
& git -C $OldRoot diff --quiet HEAD --
if ($LASTEXITCODE -ne 0) { throw 'Old fixture contains modified files.' }
Import-Module powershell-yaml -ErrorAction Stop
$configuration = Get-Content -LiteralPath $ConfigSourcePath -Raw | ConvertFrom-Yaml
$expectedProject = [string]$configuration.repositories.projectUrl
if ([string]::IsNullOrWhiteSpace($expectedProject) -or
    $expectedProject.TrimEnd('/') -in @('https://github.com/alissonsol/yuruna-project', 'https://github.com/alissonsol/yuruna-project.git')) {
    throw 'Configuration fixture must carry a non-default operator project URL.'
}
$projectUri = $null
if (-not [uri]::TryCreate($expectedProject, [UriKind]::Absolute, [ref]$projectUri) -or
    $projectUri.UserInfo -or $projectUri.Query -or $projectUri.Fragment) {
    throw 'The measured project URL must not carry credentials or query parameters.'
}

if ($Action -eq 'Prepare') {
    if (@(Get-ChildItem -LiteralPath $TargetRoot -Force).Count) { throw 'Prepare requires an empty disposable target.' }
    if ($Mode -ne 'Fresh') {
        & git clone --no-hardlinks --no-checkout -- $OldRoot $TargetRoot
        if ($LASTEXITCODE) { throw 'Could not clone the frozen old fixture.' }
        if ($Mode -eq 'Pin') { & git -C $TargetRoot checkout --detach $fixture.commit }
        else { & git -C $TargetRoot checkout -B main $fixture.commit }
        if ($LASTEXITCODE) { throw 'Could not select the old fixture revision.' }
        & git -C $TargetRoot remote set-url origin https://github.com/alissonsol/yuruna.git
        if ($LASTEXITCODE) { throw 'Could not set the canonical fixture origin.' }
        if ($Mode -eq 'Main') {
            & git -C $TargetRoot config branch.main.remote origin
            & git -C $TargetRoot config branch.main.merge refs/heads/main
            if ($LASTEXITCODE) { throw 'Could not set the fixture upstream.' }
        }
        if (Test-Path -LiteralPath $ConfigPath) { throw 'Selected fixture configuration already exists.' }
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $ConfigPath) -Force
        Copy-Item -LiteralPath $ConfigSourcePath -Destination $ConfigPath
        if (-not $IsWindows) { [IO.File]::SetUnixFileMode($ConfigPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite) }
    }
    elseif (-not $ConfigPath.Equals((Join-Path $TargetRoot 'test/test.config.yml'), $comparison)) {
        throw 'Fresh setup uses the installed default configuration path.'
    }
    $null = New-Item -ItemType Directory -Path $RuntimeDir -Force
    [IO.File]::WriteAllText((Join-Path $StatePath 'initial.json'), (@{
        origin = 'https://github.com/alissonsol/yuruna.git'
        backupPaths = @(Get-ChildItem -LiteralPath (Split-Path -Parent $TargetRoot) -Directory |
            Where-Object Name -Like ((Split-Path -Leaf $TargetRoot) + '.backup.*') | ForEach-Object FullName)
    } | ConvertTo-Json) + "`n")
    if ($AutomaticOrigin) {
        if ($Mode -ne 'Main' -or (Test-Path -LiteralPath $originPath)) { throw 'Automatic adoption requires a new main origin fixture.' }
        & git clone --bare --no-hardlinks -- $OldRoot $originPath
        if ($LASTEXITCODE) { throw 'Could not create the controlled public origin.' }
        & git -C $originPath update-ref refs/heads/main $fixture.commit
        if ($LASTEXITCODE) { throw 'Could not initialize the controlled main ref.' }
        & git -C $originPath symbolic-ref HEAD refs/heads/main
        if ($LASTEXITCODE) { throw 'Could not initialize the controlled default branch.' }
    }
    return
}

if ($Action -eq 'AdvanceOrigin') {
    if (-not $CandidateTree) { throw 'Advancing the controlled origin requires the frozen candidate tree.' }
    $before = [string](& git -C $originPath rev-parse refs/heads/main)
    if ($LASTEXITCODE -or $before.Trim() -cne $fixture.commit) { throw 'Controlled origin no longer starts at the old public fixture.' }
    $advanceTime = [DateTimeOffset]::UtcNow
    & git -C $originPath fetch --no-tags https://github.com/alissonsol/yuruna.git refs/heads/main:refs/heads/main
    if ($LASTEXITCODE) { throw 'Could not advance the controlled origin from the prepared upstream.' }
    $tree = [string](& git -C $originPath rev-parse 'refs/heads/main^{tree}')
    if ($LASTEXITCODE -or $tree.Trim() -cne $CandidateTree) { throw 'Advanced origin is not the frozen candidate tree.' }
    $sha = [string](& git -C $originPath rev-parse refs/heads/main)
    if ($LASTEXITCODE -or $sha.Trim() -ceq $fixture.commit) { throw 'The controlled origin did not advance.' }
    [IO.File]::WriteAllText((Join-Path $StatePath 'advance.json'), (@{
        oldCommit=$fixture.commit; candidateCommit=$sha.Trim(); candidateTree=$tree.Trim()
        advancedAtUnixMs=$advanceTime.ToUnixTimeMilliseconds()
    } | ConvertTo-Json) + "`n")
    return
}

if ($Action -eq 'UpdateLegacy') {
    # Exercise the exact public updater while the old outer remains resident.
    # A detached public release must remain pinned until the explicit installer.
    $before = [string](& git -C $TargetRoot rev-parse HEAD)
    & git -C $TargetRoot symbolic-ref -q HEAD | Out-Null
    $detached = $LASTEXITCODE -ne 0
    Import-Module (Join-Path $OldRoot 'test/modules/Test.HostGit.psm1') -Force -DisableNameChecking
    if (-not (Invoke-GitPull -RepoRoot $TargetRoot)) { throw 'The public updater failed.' }
    $after = [string](& git -C $TargetRoot rev-parse HEAD)
    if ($detached -and $after.Trim() -cne $before.Trim()) { throw 'The public updater changed a detached pin.' }
    if (-not $detached -and $after.Trim() -ceq $before.Trim()) { throw 'The public main updater did not adopt the prepared release.' }
    return
}

if ($Action -eq 'Diverge') {
    # A local commit makes the installer's real --ff-only update fail, invoking
    # its normal move-aside/reclone path without corrupting source files.
    $path = Join-Path $TargetRoot 'qualification-local-change.txt'
    [IO.File]::WriteAllText($path, "Disposable installer divergence fixture.`n")
    & git -C $TargetRoot add -- qualification-local-change.txt
    if ($LASTEXITCODE) { throw 'Could not stage the disposable divergence fixture.' }
    & git -C $TargetRoot -c user.name=Qualification -c user.email=qualification@example.invalid commit -m 'Create disposable installer divergence'
    if ($LASTEXITCODE) { throw 'Could not commit the disposable divergence fixture.' }
    return
}

Import-Module (Join-Path $candidateRoot 'test/modules/Test.SingleInstance.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $candidateRoot 'test/modules/Test.ConfigSync.psm1') -DisableNameChecking
# These variables are scoped to this short-lived adapter process. Production
# readers use the same selected configuration and private runtime as the runner.
$env:YURUNA_CONFIG_PATH = $ConfigPath
$env:YURUNA_RUNTIME_DIR = $RuntimeDir

function Write-NativeInstallObservation {
    [CmdletBinding()]
    param([string]$Name, [System.Collections.IDictionary]$Value)
    $path = Join-Path $StatePath $Name
    $existing = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if ($Name -notmatch '^[A-Za-z-]+\.json$' -or
        ($existing -and $existing.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Invalid native observation path.'
    }
    [IO.File]::WriteAllText($path, ($Value | ConvertTo-Json -Depth 12) + "`n")
}

function Test-NativeRunnerAlive {
    [CmdletBinding()]
    [OutputType([bool])]
    param($Launch)
    return $Launch.Valid -and
        (Get-YurunaProcessStartUnixMs -ProcessId ([int]$Launch.Record.runner.pid)) -eq [long]$Launch.Record.runner.startTimeUnixMs
}

if ($Action -eq 'Enroll') {
    # Trust is supplied by the operator's provisioning export, never downloaded
    # from the endpoint whose signing key this action is about to trust.
    if (-not $MirrorKeyExportPath -or -not $MirrorUrl) { throw 'Enrollment requires the provisioning key export and mirror URL.' }
    $endpoint = [uri]$MirrorUrl
    if ($endpoint.Scheme -notin @('http', 'https') -or $endpoint.UserInfo -or
        $endpoint.Query -or $endpoint.Fragment -or $endpoint.AbsolutePath -ne '/') { throw 'Mirror URL must be a credential-free origin.' }
    $keyExport = Get-Content -LiteralPath $MirrorKeyExportPath -Raw | ConvertFrom-Json -AsHashtable
    $keyId = [string](Get-ConfigMirrorKeyId -Value $keyExport.publicKey)
    if ($keyId -cne $keyExport.keyId) { throw 'The provisioning key export fingerprint is invalid.' }
    $current = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Yaml -Ordered
    $templatePath = Join-Path $TargetRoot 'test/test.config.yml.template'
    $template = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Yaml -Ordered
    if (-not $template.repositories.mirror) { throw 'Install the mirror-aware template before enrollment.' }
    $proposed = ConvertTo-MergedHashtable -Template $template -Current $current
    if ($current.Contains('secrets')) { $proposed['secrets'] = $current.secrets }
    $proposed.repositories.mirror.url = $endpoint.AbsoluteUri.TrimEnd('/')
    if ($MirrorMode) { $proposed.repositories.mirror.mode = $MirrorMode }
    $keys = @($proposed.repositories.mirror.verificationPublicKeys)
    if ($keys -cnotcontains $keyExport.publicKey) { $proposed.repositories.mirror.verificationPublicKeys = $keys + @($keyExport.publicKey) }
    $changes = @(Get-ConfigMirrorChange -Current $current -Proposed $proposed)
    if (-not @($changes | Where-Object Path -CEQ repositories.mirror.verificationPublicKeys).Count) { throw 'Enrollment must exercise an explicit new key addition.' }
    $backup = Join-Path $StatePath ('enrollment-' + [guid]::NewGuid().ToString('N') + '.yml')
    Copy-Item -LiteralPath $ConfigPath -Destination $backup
    if (-not $IsWindows) { [IO.File]::SetUnixFileMode($backup, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite) }
    foreach ($change in $changes) { Write-Information "$($change.Path): $($change.Previous) -> $($change.Current) (backup: $backup)" -InformationAction Continue }
    if (-not (Write-DocumentedTestConfig -ConfigPath $ConfigPath -Config $proposed -TemplatePath $templatePath -Confirm:$false)) { throw 'Enrollment could not write the selected configuration.' }
    $saved = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Yaml -Ordered
    $unrelatedChanges = @(Get-ConfigLeafChange -Current $current -Merged $saved | Where-Object Path -NotLike 'repositories.mirror.*')
    if ($unrelatedChanges.Count -or @(Get-DroppedConfigField -Current $current -Merged $saved).Count) { throw 'Enrollment changed unrelated operator configuration.' }
    Write-NativeInstallObservation -Name enrollment.json -Value @{
        keyId=$keyId; reportedChanges=@($changes); backupSha256=(Get-FileHash $backup).Hash.ToLowerInvariant()
        operatorValuesPreserved=$true; keyEnrolled=(@($saved.repositories.mirror.verificationPublicKeys) -ccontains $keyExport.publicKey)
    }
    return
}

if ($Action -eq 'RunGate') {
    $launch = Read-YurunaRunnerLaunchRecord -RuntimeDir $RuntimeDir
    if (Test-NativeRunnerAlive $launch) { throw 'Run the rollback gate with the fixture runner stopped to avoid concurrent reconciliation.' }
    Import-Module (Join-Path $candidateRoot 'automation/Yuruna.Common.psm1') -DisableNameChecking
    $before = [IO.File]::ReadAllBytes($ConfigPath)
    $oldConfig = [Text.Encoding]::UTF8.GetString($before) | ConvertFrom-Yaml -Ordered
    $gate = Invoke-BoundedNativeCommand -FilePath (Get-Process -Id $PID).Path `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-File', (Join-Path $TargetRoot 'test/Test-Config.ps1'), '-ConfigPath', $ConfigPath) `
        -TimeoutSeconds 1200 -MaxCapturedChars 1048576
    [IO.File]::WriteAllText((Join-Path $StatePath "gate-$GateExpectation.log"), [string]$gate.Output)
    if ($gate.TimedOut -or $gate.ExitCode -ne 0) { throw "The installed configuration gate failed: $GateExpectation (exit $($gate.ExitCode))." }
    $text = Get-Content -LiteralPath $ConfigPath -Raw
    $current = $text | ConvertFrom-Yaml -Ordered
    $obsolete = Get-ObsoleteConfigEntry -Text $text
    $result = @{ gatePassed=$true; expectation=$GateExpectation }
    if ($GateExpectation -eq 'OldRollback') {
        $head = [string](& git -C $TargetRoot rev-parse HEAD)
        if ($head.Trim() -cne $fixture.commit) { throw 'Rollback gate must execute the frozen public release.' }
        $required = @('repositories.mirror.mode', 'repositories.mirror.verificationPublicKeys', 'vmStart.cachingProxyGitMirrorRefreshSeconds')
        foreach ($key in $required) { if (-not $obsolete.Contains($key)) { throw "Rollback did not park $key." } }
        $backup = "$ConfigPath.backup"
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($backup)) -cne [Convert]::ToBase64String($before)) { throw 'Rollback backup does not preserve the enrolled configuration.' }
        if ($gate.Output -notmatch 'repositories\.mirror\.verificationPublicKeys' -or $gate.Output -notmatch 'NOT part of the current schema') { throw 'Rollback gate did not warn about removed enrolled settings.' }
        if (@($oldConfig.repositories.mirror.verificationPublicKeys).Count -eq 0) { throw 'Rollback must start with an enrolled key.' }
        $result.parked=$true; $result.backupVerified=$true; $result.warningObserved=$true
    } elseif ($GateExpectation -eq 'NewRollback') {
        if ($current.repositories.mirror.mode -cne 'prefer' -or @($current.repositories.mirror.verificationPublicKeys).Count -ne 0) { throw 'Re-upgrade resurrected parked trust instead of using template defaults.' }
        if (-not $obsolete.Contains('repositories.mirror.verificationPublicKeys')) { throw 'Re-upgrade discarded the parked trust comment.' }
        Import-Module (Join-Path $candidateRoot 'test/modules/Test.SourceSelection.psm1') -DisableNameChecking
        Import-Module (Join-Path $candidateRoot 'test/modules/Test.HostGit.psm1') -DisableNameChecking
        $source = Get-GitSourceConfiguration -ConfigPath $ConfigPath
        # A known endpoint without an enrolled key must remain untrusted.
        if (-not $source.context.url -or
            ($MirrorUrl -and $source.context.url.TrimEnd('/') -cne $MirrorUrl.TrimEnd('/'))) {
            throw 'Re-upgrade must retain the prior proxy address through vmStart.cachingProxyIp for its actual untrusted observation.'
        }
        $selected = Resolve-GitSourceSelection -RepositoryUrl https://github.com/alissonsol/yuruna.git -Ref refs/heads/main `
            -SourceContext $source.context -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(45)) -Operation Gate
        if (-not $selected.success -or $selected.fallbackReason -cne 'mirror-untrusted' -or $selected.verification -cne 'origin-direct') { throw 'Re-upgrade did not select the expected untrusted origin fallback.' }
        $result.defaultsRestored=$true; $result.parked=$true; $result.fallbackReason=$selected.fallbackReason
    }
    Write-NativeInstallObservation -Name "gate-$GateExpectation.json" -Value $result
    return
}

if ($Action -eq 'Drain') {
    if (-not $SnapshotPath -or (Test-Path -LiteralPath $SnapshotPath)) { throw 'Clean-stop capture requires a new snapshot path.' }
    $launch = Read-YurunaRunnerLaunchRecord -RuntimeDir $RuntimeDir
    if (-not (Test-NativeRunnerAlive $launch)) { throw 'Clean-stop qualification requires a live production runner.' }
    $current = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Yaml -Ordered
    if ($current.pool.enabled -or $current.pool.configurationGitUrl) { throw 'The clean-stop fixture must not belong to an operator pool.' }
    $hostId = (Get-Content -LiteralPath (Join-Path $RuntimeDir host.uuid) -Raw).Trim()
    if ($hostId -cnotmatch '^42[0-9a-f]{30}$') { throw 'The live runner has no valid host identity.' }
    $poolRoot = Join-Path $StatePath drain-origin
    if (Test-Path -LiteralPath $poolRoot) { throw 'Clean-stop origin already exists.' }
    $null = New-Item -ItemType Directory -Path $poolRoot
    @{ schemaVersion=4; pools=@(@{poolId='qualification'; poolGuid=[guid]::NewGuid().ToString(); configuredState='drain'; members=@($hostId)}) } |
        ConvertTo-Yaml | Set-Content -LiteralPath (Join-Path $poolRoot pools.yml)
    & git init -q $poolRoot
    & git -C $poolRoot add pools.yml
    & git -C $poolRoot -c user.name=Qualification -c user.email=qualification@example.invalid commit -qm 'Request disposable runner drain'
    if ($LASTEXITCODE) { throw 'Could not create the private drain origin.' }
    $backup = Join-Path $StatePath drain-config.yml
    if (Test-Path -LiteralPath $backup) { throw 'Clean-stop configuration backup already exists.' }
    Copy-Item -LiteralPath $ConfigPath -Destination $backup
    if (-not $IsWindows) { [IO.File]::SetUnixFileMode($backup, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite) }
    $proposed = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Yaml -Ordered
    $proposed.pool.enabled=$true; $proposed.pool.configurationGitUrl=[uri]::new($poolRoot).AbsoluteUri
    $proposed.pool.localClonePath=Join-Path $RuntimeDir drain-pool
    $proposed.pool.pullTimeoutSeconds=15
    foreach ($change in @(Get-ConfigLeafChange -Current $current -Merged $proposed)) {
        Write-Information "$($change.Path): $($change.Previous) -> $($change.Current) (backup: $backup)" -InformationAction Continue
    }
    try {
        $null = Write-DocumentedTestConfig -ConfigPath $ConfigPath -Config $proposed -TemplatePath (Join-Path $TargetRoot 'test/test.config.yml.template') -Confirm:$false
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($AdoptionTimeoutSeconds)
        do {
            $stopped = Read-YurunaRunnerLaunchRecord -RuntimeDir $RuntimeDir
            if ($stopped.Valid -and -not (Test-NativeRunnerAlive $stopped) -and $stopped.Record.cleanExit) { break }
            Start-Sleep -Milliseconds 500
        } while ([DateTimeOffset]::UtcNow -lt $deadline)
        if (-not $stopped.Valid -or (Test-NativeRunnerAlive $stopped) -or -not $stopped.Record.cleanExit -or
            $stopped.Record.runner.pid -ne $launch.Record.runner.pid) { throw 'The real runner did not exit cleanly through its pool-drain path.' }
    } finally {
        foreach ($change in @(Get-ConfigLeafChange -Current $proposed -Merged $current)) {
            Write-Information "$($change.Path): $($change.Previous) -> $($change.Current) (backup: $backup)" -InformationAction Continue
        }
        [IO.File]::WriteAllBytes($ConfigPath, [IO.File]::ReadAllBytes($backup))
    }
    $null = Invoke-YurunaInstallerState -Action Capture -RepoRoot $TargetRoot -RuntimeDir $RuntimeDir -SnapshotPath $SnapshotPath
    Write-NativeInstallObservation -Name clean-stop.json -Value @{
        cleanExit=$stopped.Record.cleanExit; runnerStopped=$true; pid=$stopped.Record.runner.pid
        startTimeUnixMs=$stopped.Record.runner.startTimeUnixMs; cleanExitPreserved=$false
    }
    return
}

if ($Action -eq 'VerifyCleanStop') {
    $before = Get-Content -LiteralPath (Join-Path $StatePath clean-stop.json) -Raw | ConvertFrom-Json -AsHashtable
    $launch = Read-YurunaRunnerLaunchRecord -RuntimeDir $RuntimeDir
    if (-not $launch.Valid -or (Test-NativeRunnerAlive $launch) -or -not $launch.Record.cleanExit -or
        $launch.Record.runner.pid -ne $before.pid -or $launch.Record.runner.startTimeUnixMs -ne $before.startTimeUnixMs) {
        throw 'Refresh revived or rewrote the intentionally stopped runner.'
    }
    $before.cleanExitPreserved=$true
    Write-NativeInstallObservation -Name clean-stop.json -Value $before
    return
}

if ($Action -eq 'WaitMirrorCycle') {
    Import-Module (Join-Path $candidateRoot 'test/modules/Test.SourceSelection.psm1') -DisableNameChecking
    $original = Read-YurunaRunnerLaunchRecord -RuntimeDir $RuntimeDir
    if (-not (Test-NativeRunnerAlive $original)) { throw 'Mirror transition requires a live production runner.' }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($AdoptionTimeoutSeconds)
    do {
        $launch = Read-YurunaRunnerLaunchRecord -RuntimeDir $RuntimeDir
        if (-not (Test-NativeRunnerAlive $launch) -or $launch.Record.runner.pid -ne $original.Record.runner.pid -or
            $launch.Record.runner.startTimeUnixMs -ne $original.Record.runner.startTimeUnixMs) { throw 'The host restarted while waiting for mirror activation.' }
        $snapshot = Get-YurunaRunnerSnapshot -RepoRoot $TargetRoot -RuntimeDir $RuntimeDir -WorkerPid $PID
        $handoff = $null
        if ($snapshot.Cycle.State -eq 'AliveOwned') {
            try { $handoff = Read-GitSourceHandoff -RepoRoot $TargetRoot -ConfigPath $ConfigPath -CycleGeneration $snapshot.Cycle.CycleGeneration } catch { $handoff=$null }
        }
        if ($handoff -and $handoff.framework.verification -ceq 'mirror-confirmed' -and $snapshot.Inner.State -eq 'AliveOwned') {
            Write-NativeInstallObservation -Name mirror-cycle.json -Value @{
                verification=$handoff.framework.verification; source=$handoff.framework.source; selectedSha=$handoff.framework.selectedSha
                cycleGeneration=$snapshot.Cycle.CycleGeneration; outerPid=$launch.Record.runner.pid; sameResident=$true
            }
            return
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw 'No actual mirror-confirmed cycle became active before the deadline.'
}
if ($Action -eq 'WaitAdoption') {
    if (-not $SnapshotPath -or -not $CandidateTree) { throw 'Adoption requires the captured old runner and frozen candidate tree.' }
    $captured = Invoke-YurunaInstallerState -Action Read -RepoRoot $TargetRoot -SnapshotPath $SnapshotPath
    $advance = Get-Content -LiteralPath (Join-Path $StatePath 'advance.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($advance.candidateTree -cne $CandidateTree -or $advance.oldCommit -cne $fixture.commit) { throw 'Adoption origin evidence does not match the frozen inputs.' }
    Import-Module (Join-Path $candidateRoot 'test/modules/Test.SourceSelection.psm1') -DisableNameChecking
    $adoptionDeadline = [DateTimeOffset]::UtcNow.AddSeconds($AdoptionTimeoutSeconds)
    do {
        $launch = Read-YurunaRunnerLaunchRecord -RuntimeDir $RuntimeDir
        if (-not $launch.Valid -or $launch.Record.runner.pid -ne $captured.launchRecord.runner.pid -or
            $launch.Record.runner.startTimeUnixMs -ne $captured.launchRecord.runner.startTimeUnixMs) {
            throw 'The public outer was replaced before automatic adoption was observed.'
        }
        $head = [string](& git -C $TargetRoot rev-parse HEAD)
        $snapshot = Get-YurunaRunnerSnapshot -RepoRoot $TargetRoot -RuntimeDir $RuntimeDir -WorkerPid $PID
        $cycle = $snapshot.Cycle
        if ($head.Trim() -ceq $advance.candidateCommit -and $cycle.State -eq 'AliveOwned' -and
            $cycle.OuterPid -eq $captured.launchRecord.runner.pid -and
            $cycle.RecordedStartTimeUnixMs -gt $advance.advancedAtUnixMs -and
            $snapshot.Inner.State -eq 'AliveOwned' -and $snapshot.Inner.RecordedStartTimeUnixMs -ge $cycle.RecordedStartTimeUnixMs) {
            $handoff = $null
            try {
                $handoff = Read-GitSourceHandoff -RepoRoot $TargetRoot -ConfigPath $ConfigPath -CycleGeneration $cycle.CycleGeneration
            } catch { $handoff = $null }
            $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Yaml
            $keysPresent = $config.Contains('repositories') -and $config.repositories.Contains('mirror') -and
                $config.repositories.mirror.Contains('verificationPublicKeys') -and
                $config.Contains('vmStart') -and $config.vmStart.Contains('cachingProxyGitMirrorRefreshSeconds')
            if ($handoff -and $handoff.framework.selectedSha -ceq $advance.candidateCommit -and $keysPresent) {
                [IO.File]::WriteAllText((Join-Path $StatePath 'adoption.json'), (@{
                    candidateCommit=$advance.candidateCommit; candidateTree=$CandidateTree
                    outerPid=$launch.Record.runner.pid; outerStartTimeUnixMs=$launch.Record.runner.startTimeUnixMs
                    cyclePid=$cycle.Pid; cycleGeneration=$cycle.CycleGeneration; cycleStartTimeUnixMs=$cycle.RecordedStartTimeUnixMs
                    innerPid=$snapshot.Inner.Pid; innerStartTimeUnixMs=$snapshot.Inner.RecordedStartTimeUnixMs
                    newCycleBound=$true; templateKeysPresent=$true; oldOuterRetained=$true
                } | ConvertTo-Json) + "`n")
                return
            }
        }
        Start-Sleep -Milliseconds 500
    } while ([DateTimeOffset]::UtcNow -lt $adoptionDeadline)
    throw 'The old public outer did not automatically run a candidate cycle and inner with new template keys before the deadline.'
}
if ($Action -eq 'StopFixture') {
    Import-Module (Join-Path $candidateRoot 'automation/Yuruna.Common.psm1') -DisableNameChecking
    $stopDeadline = New-YurunaDeadline -TotalMilliseconds ($TimeoutSeconds * 1000)
    $snapshot = Get-YurunaRunnerSnapshot -RepoRoot $TargetRoot -RuntimeDir $RuntimeDir -WorkerPid $PID -Deadline $stopDeadline
    $plan = New-YurunaRunnerReclaimPlan -Snapshot $snapshot -WorkerPid $PID
    if (-not $plan.Reclaimable) { throw 'Fixture cleanup could not prove runner process ownership.' }
    $stopped = Stop-YurunaRunnerProcessTarget -Plan $plan -Deadline $stopDeadline -Confirm:$false
    if (-not $stopped.Converged) { throw 'Fixture cleanup did not stop all owned runner processes.' }
    return
}
if ($Action -eq 'StartCaptured') {
    if (-not $SnapshotPath) { throw 'Starting captured options requires SnapshotPath.' }
    $null = Start-YurunaCapturedRunner -RepoRoot $TargetRoot -SnapshotPath $SnapshotPath -TimeoutSeconds $TimeoutSeconds -Confirm:$false
    return
}
if ($ExpectStopped -and ($RequireRunner -or $Action -eq 'Capture')) { throw 'A runner cannot be required both live and stopped.' }
$deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
$launch = $null
do {
    $launch = Read-YurunaRunnerLaunchRecord -RuntimeDir $RuntimeDir
    $alive = $false
    if ($launch.Valid) {
        $identity = $launch.Record.runner
        $alive = (Get-YurunaProcessStartUnixMs -ProcessId ([int]$identity.pid)) -eq [long]$identity.startTimeUnixMs
    }
    if ($ExpectStopped) { if (-not $alive) { break } }
    elseif ($alive -or -not ($RequireRunner -or $Action -eq 'Capture')) { break }
    Start-Sleep -Milliseconds 100
} while ([DateTimeOffset]::UtcNow -lt $deadline)
if (($RequireRunner -or $Action -eq 'Capture') -and -not $alive) { throw 'The real fixture runner did not publish a live launch record.' }
if ($ExpectStopped -and $alive) { throw 'The installer did not stop the recorded fixture runner.' }
if ($Action -eq 'Capture') {
    if (-not $SnapshotPath) { throw 'Capture requires SnapshotPath.' }
    if (Test-Path -LiteralPath $SnapshotPath) { throw 'Capture never overwrites retained evidence.' }
    $null = Invoke-YurunaInstallerState -Action Capture -RepoRoot $TargetRoot -RuntimeDir $RuntimeDir -SnapshotPath $SnapshotPath
}

$current = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Yaml
$initial = Get-Content -LiteralPath (Join-Path $StatePath initial.json) -Raw | ConvertFrom-Json -AsHashtable
$origin = [string](& git -C $TargetRoot config --get remote.origin.url)
if ($LASTEXITCODE) { throw 'The installed checkout has no repository identity.' }
$newBackups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $TargetRoot) -Directory |
    Where-Object { $_.Name -like ((Split-Path -Leaf $TargetRoot) + '.backup.*') -and $_.FullName -cnotin $initial.backupPaths })
$observation = [ordered]@{
    pid = $(if ($alive) { [int]$launch.Record.runner.pid } else { $null })
    startTimeUnixMs = $(if ($alive) { [long]$launch.Record.runner.startTimeUnixMs } else { $null })
    projectUrl = [string]$current.repositories.projectUrl
    projectUrlPreserved = [string]$current.repositories.projectUrl -ceq $expectedProject
    configurationSha256 = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash.ToLowerInvariant()
    runnerAlive = $alive
    launchOptionsPreserved = $false
    launchEnvironmentPreserved = $false
    repositoryIdentityPreserved = $origin.Trim() -ceq $initial.origin
    noRecoveryCheckout = $newBackups.Count -eq 0
    recoveryCheckoutCount = $newBackups.Count
    configurationValuesPreserved = $true
}
if ($SnapshotPath -and (Test-Path -LiteralPath $SnapshotPath)) {
    $captured = Invoke-YurunaInstallerState -Action Read -RepoRoot $TargetRoot -SnapshotPath $SnapshotPath
    $selected = @($captured.configurations | Where-Object { ([string]$_.path).Equals($ConfigPath, $comparison) })
    if ($selected.Count -ne 1) { throw 'The selected operator configuration is absent from the captured state.' }
    $prior = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($selected[0].bytes)) | ConvertFrom-Yaml
    $observation.configurationValuesPreserved =
        @(Get-ConfigLeafChange -Current $prior -Merged $current).Count -eq 0 -and
        @(Get-DroppedConfigField -Current $prior -Merged $current).Count -eq 0
}
if ($alive -and $SnapshotPath -and (Test-Path -LiteralPath $SnapshotPath)) {
    $captured = Invoke-YurunaInstallerState -Action Read -RepoRoot $TargetRoot -SnapshotPath $SnapshotPath
    $sameOptions = $true
    foreach ($name in $captured.launchRecord.parameters.Keys) {
        if ($launch.Record.parameters[$name] -cne $captured.launchRecord.parameters[$name]) { $sameOptions = $false }
    }
    $sameEnvironment = $true
    foreach ($name in $captured.launchRecord.environment.Keys) {
        if ($launch.Record.environment[$name] -cne $captured.launchRecord.environment[$name]) { $sameEnvironment = $false }
    }
    $observation.launchOptionsPreserved = $sameOptions
    $observation.launchEnvironmentPreserved = $sameEnvironment
}
if ($IsMacOS) {
    Import-Module (Join-Path $candidateRoot 'test/modules/Test.HostCondition.Mac.psm1') -DisableNameChecking
    $observation.sessionKind = Get-MacSessionKind -TimeoutSeconds 5
}
$refreshState = Join-Path $RuntimeDir 'host-refresh.state.json'
if (Test-Path -LiteralPath $refreshState) {
    $refresh = Get-Content -LiteralPath $refreshState -Raw | ConvertFrom-Json -AsHashtable
    $observation.refreshVerdict = [string]$refresh.verdict
}
$observationPath = Join-Path $StatePath $(if ($ExpectStopped) { 'stopped.json' } else { 'observed.json' })
[IO.File]::WriteAllText($observationPath, ($observation | ConvertTo-Json -Depth 8) + "`n")
