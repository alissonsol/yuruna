<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42131309-1c41-47e3-a6f7-4eec70770d25
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
<#
.SYNOPSIS
    Execute checked-in mirror recipes on an explicitly disposable native host.
.DESCRIPTION
    The profile selects checked-in scenarios and supplies fixture paths, never
    commands or pass labels. Commands use the real old, candidate and installed
    scripts; standalone installers require the release signature before launch.
    Each row retains subprocess logs and measured before/after observations.
    Run locally in the owning Aqua session on macOS. Platform selection is
    measured from this process, not accepted from the profile.
.PARAMETER DisposableTarget
    Acknowledge that the profile names a disposable qualification host and its
    test checkout. Installer and refresh recipes can change host configuration.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CandidateManifestPath,
    [Parameter(Mandatory)][string]$FrameworkRoot,
    [Parameter(Mandatory)][string]$ProjectRoot,
    [Parameter(Mandatory)][string]$SourceFrameworkCommit,
    [Parameter(Mandatory)][string]$SourceProjectCommit,
    [Parameter(Mandatory)][string]$ProfilePath,
    [Parameter(Mandatory)][string]$OutputPath,
    [switch]$DisposableTarget
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $DisposableTarget) { throw 'Native recipes require an explicitly disposable qualification target.' }
Import-Module (Join-Path $PSScriptRoot 'GitMirror.Qualification.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'GitMirror.NativeQualification.psm1') -Force
$candidate = Test-GitMirrorCandidate -CandidateManifestPath $CandidateManifestPath -FrameworkRoot $FrameworkRoot `
    -ProjectRoot $ProjectRoot -SourceFrameworkCommit $SourceFrameworkCommit -SourceProjectCommit $SourceProjectCommit
$contract = Get-GitMirrorQualificationContract $FrameworkRoot
$nativeProfile = Get-Content -Raw -LiteralPath $ProfilePath | ConvertFrom-Json -AsHashtable
if ($nativeProfile.schema -cne 'yuruna.git-mirror.native-profile/v1' -or @($nativeProfile.scenarios).Count -eq 0) {
    throw 'Native profile must select at least one checked-in scenario.'
}
$architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
$platform = if ($IsWindows) { "windows-$architecture" } elseif ($IsMacOS) { "macos-$architecture" } else { "linux-$architecture" }
$recipes = @{}
foreach ($recipe in $contract.nativeRecipes) {
    if ($recipe.platform -in @('*', $platform)) {
        if ($recipes.ContainsKey($recipe.id)) { throw "Duplicate native recipe: $($recipe.id)" }
        $recipes[$recipe.id] = $recipe
    }
}
$output = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $output) { throw 'Native output path already exists; keep prior evidence immutable.' }
$null = New-Item -ItemType Directory -Path $output
$target = [IO.Path]::GetFullPath($nativeProfile.targetRoot)
foreach ($root in @($FrameworkRoot, $ProjectRoot, $nativeProfile.oldRoot)) {
    if ($target -ceq [IO.Path]::GetFullPath($root)) { throw 'The disposable target must differ from candidate and old fixture sources.' }
}
$oldHead = (& git -C $nativeProfile.oldRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -or $oldHead -cne $contract.fixture.commit) { throw 'Native old source is not the exact required public release.' }
& git -C $nativeProfile.oldRoot diff --exit-code HEAD --
if ($LASTEXITCODE) { throw 'Native old fixture source has modified files.' }
$artifact = $candidate.artifacts | Where-Object { $_.path.EndsWith('/install.sha256') }
$artifactDirectory = Split-Path -Parent (Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($CandidateManifestPath))) $artifact.path)
$variables = @{
    TargetRoot = $target; OldRoot = [IO.Path]::GetFullPath($nativeProfile.oldRoot); CandidateTag = 'qualification-candidate'; OldRelease = $contract.fixture.release
    FrameworkRoot = [IO.Path]::GetFullPath($FrameworkRoot); UpstreamsPath = [IO.Path]::GetFullPath($nativeProfile.upstreamsPath)
    CandidateId = $candidate.candidateId; CandidateTree = $candidate.identity.trees.framework
}
foreach ($entry in $nativeProfile.variables.GetEnumerator()) {
    if ($variables.ContainsKey($entry.Key) -or $entry.Key -in @('OriginRunId', 'OriginPreparePath', 'OriginRestorePath')) {
        throw "Profile cannot replace reserved variable: $($entry.Key)"
    }
    $variables[$entry.Key] = [string]$entry.Value
}
$environment = @{}
foreach ($entry in $nativeProfile.environment.GetEnumerator()) {
    if ($entry.Key -match '(?i)(TOKEN|PASSWORD|SECRET|CREDENTIAL|ASKPASS|^GIT_CONFIG)') { throw 'Native profiles cannot forward credentials or replace fixture Git routing.' }
    $environment[$entry.Key] = Expand-GitMirrorNativeValue ([string]$entry.Value) $variables
}
$fixtures = Get-Content -Raw -LiteralPath $nativeProfile.upstreamsPath | ConvertFrom-Json -AsHashtable
if ($fixtures.candidateId -cne $candidate.candidateId) { throw 'Native upstream fixtures belong to another candidate.' }
$gitSettings = [Collections.Generic.List[object]]::new()
$inheritedCount = 0
if ($env:GIT_CONFIG_COUNT -and (-not [int]::TryParse($env:GIT_CONFIG_COUNT, [ref]$inheritedCount) -or
        $inheritedCount -lt 0 -or $inheritedCount -gt 1024)) { throw 'Invalid inherited Git configuration count.' }
for ($i = 0; $i -lt $inheritedCount; $i++) {
    $key = [Environment]::GetEnvironmentVariable("GIT_CONFIG_KEY_$i")
    $value = [Environment]::GetEnvironmentVariable("GIT_CONFIG_VALUE_$i")
    if ($null -eq $key -or $null -eq $value) { throw 'Incomplete inherited Git configuration.' }
    $gitSettings.Add(@($key, $value))
}
$gitSettings.Add(@('credential.helper', ''))
$gitSettings.Add(@('protocol.file.allow', 'always'))
foreach ($repository in $fixtures.repositories) {
    $canonical = if ($repository.name -ceq 'framework') { 'https://github.com/alissonsol/yuruna.git' } else { 'https://github.com/alissonsol/yuruna-project.git' }
    if ($repository.name -notin @('framework', 'project') -or
        $repository.canonicalUrl -cne $canonical) {
        throw 'Native fixture contains an unexpected canonical origin.'
    }
    $tree = (& git -C $repository.localPath rev-parse 'refs/heads/main^{tree}').Trim()
    if ($LASTEXITCODE -or $tree -cne $candidate.identity.trees[$repository.name]) { throw 'Native fixture no longer contains the frozen candidate tree.' }
    $uri = [Uri]::new([IO.Path]::GetFullPath($repository.localPath)).AbsoluteUri
    foreach ($url in @($repository.canonicalUrl, $repository.canonicalUrl.Substring(0, $repository.canonicalUrl.Length - 4))) {
        $gitSettings.Add(@("url.$uri.insteadOf", $url))
    }
}
$environment.GIT_CONFIG_COUNT = [string]$gitSettings.Count
$environment.GIT_TERMINAL_PROMPT = '0'
$environment.GIT_CONFIG_NOSYSTEM = '1'
$environment.GIT_CONFIG_GLOBAL = if ($IsWindows) { 'NUL' } else { '/dev/null' }
for ($i = 0; $i -lt $gitSettings.Count; $i++) {
    $environment["GIT_CONFIG_KEY_$i"] = $gitSettings[$i][0]
    $environment["GIT_CONFIG_VALUE_$i"] = $gitSettings[$i][1]
}
$context = @{
    roots = @{ candidate = $FrameworkRoot; old = $nativeProfile.oldRoot; installer = $artifactDirectory; target = $target }
    variables = $variables; environment = $environment
    releasePublicKey = Join-Path $FrameworkRoot 'install/keys/yuruna-release-signing.pub.pem'
    fixtureCommit = $contract.fixture.commit; frameworkTree = $candidate.identity.trees.framework
    background = [Collections.Generic.List[object]]::new()
}
function Get-NativeObservationWithWait {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable]$Observation, [AllowNull()][hashtable]$Before, [switch]$Verify)
    $waitSeconds = if ($Observation.ContainsKey('waitSeconds')) { [int]$Observation.waitSeconds } else { 0 }
    if ($waitSeconds -lt 0 -or $waitSeconds -gt 120) { throw 'Native observation wait must be 0..120 seconds.' }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($waitSeconds)
    while ($true) {
        try {
            $value = Get-GitMirrorNativeObservation $Observation $context
            if (-not $Verify -or (Test-GitMirrorNativeObservation $Observation $Before $value $context) -or
                [DateTimeOffset]::UtcNow -ge $deadline) { return $value }
            Start-Sleep -Milliseconds 250
        }
        catch {
            if ([DateTimeOffset]::UtcNow -ge $deadline) { throw }
            Start-Sleep -Milliseconds 250
        }
    }
}
$rows = [Collections.Generic.List[object]]::new()
foreach ($id in $nativeProfile.scenarios) {
    $required = @($contract.rows | Where-Object { $_.id -ceq $id -and $_.platform -ceq $platform })
    if ($required.Count -ne 1 -or -not $recipes.ContainsKey($id)) { throw "No executable native recipe for $id/$platform." }
    $recipe = $recipes[$id]
    if (@($recipe.commands).Count -eq 0 -or @($recipe.observations).Count -eq 0) { throw 'A native recipe requires real commands and measured observations.' }
    $directory = Join-Path $output $id
    $null = New-Item -ItemType Directory -Path $directory
    $variables.OriginRunId = [guid]::NewGuid().ToString('N')
    $variables.OriginPreparePath = Join-Path $directory origins-prepare.json
    $variables.OriginRestorePath = Join-Path $directory origins-restore.json
    $started = [DateTimeOffset]::UtcNow
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $commands = [Collections.Generic.List[object]]::new()
    $observations = [Collections.Generic.List[object]]::new()
    $before = @{}
    $failure = ''
    try {
        $index = 0
        foreach ($stage in @('setup', 'exercise')) {
            foreach ($command in $recipe.commands) {
                $commandStage = if ($command.ContainsKey('stage')) { $command.stage } else { 'exercise' }
                if ($commandStage -cne $stage) { continue }
                $index++
                $result = Invoke-GitMirrorNativeCommand -Command $command -Context $context -OutputDirectory $directory -Index $index
                $result.commandHash = Get-GitMirrorJsonHash $command
                $commands.Add($result)
                if ($result.timedOut -or ($null -ne $result.exitCode -and $result.exitCode -notin $result.expectedExitCodes)) {
                    throw "Native command $index failed or timed out."
                }
            }
            if ($stage -ceq 'setup') {
                foreach ($observation in $recipe.observations) {
                    if ($observation.ContainsKey('before') -and -not $observation.before) { continue }
                    $before[$observation.name] = Get-NativeObservationWithWait $observation
                }
            }
        }
        if ($recipe.ContainsKey('observeSeconds')) {
            $seconds = [int]$recipe.observeSeconds
            if ($seconds -lt 0 -or $seconds -gt 720) { throw 'Native observation interval must be 0..720 seconds.' }
            Start-Sleep -Seconds $seconds
        }
        foreach ($observation in $recipe.observations) {
            $prior = if ($before.ContainsKey($observation.name)) { $before[$observation.name] } else { $null }
            $after = Get-NativeObservationWithWait $observation -Before $prior -Verify
            $passed = Test-GitMirrorNativeObservation $observation $prior $after $context
            $observations.Add(@{ name = $observation.name; kind = $observation.kind; before = $prior; after = $after; passed = $passed })
            if ($observation.ContainsKey('retain') -and $observation.retain) {
                if ($observation.name -cnotmatch '^[A-Za-z][A-Za-z0-9_-]*$') { throw 'Unsafe retained observation name.' }
                $observedPath = Expand-GitMirrorNativeValue ([string]$observation.path) $variables
                Copy-Item -LiteralPath $observedPath -Destination (Join-Path $directory ("observation-" + $observation.name + ".json"))
            }
            if (-not $passed) { throw "Measured native observation failed: $($observation.name)" }
        }
        if ($recipe.ContainsKey('coverage') -and $recipe.coverage -cne 'complete') {
            throw "Native recipe records diagnostics but does not yet cover the full required row: $($recipe.remaining)"
        }
    } catch { $failure = $_.Exception.Message }
    finally {
        if ($recipe.ContainsKey('cleanupCommands')) {
            foreach ($command in $recipe.cleanupCommands) {
                try {
                    $index++
                    $cleanup = Invoke-GitMirrorNativeCommand -Command $command -Context $context -OutputDirectory $directory -Index $index
                    $cleanup.commandHash = Get-GitMirrorJsonHash $command
                    $commands.Add($cleanup)
                    if ($cleanup.timedOut -or $cleanup.exitCode -notin $cleanup.expectedExitCodes) { throw "Native cleanup command $index failed." }
                } catch { $failure = "$failure Cleanup: $($_.Exception.Message)".Trim() }
            }
        }
        try { Stop-GitMirrorNativeCommand $context -Confirm:$false }
        catch { $failure = "$failure Process cleanup: $($_.Exception.Message)".Trim() }
        $clock.Stop()
    }
    foreach ($command in $commands) {
        $command.stdoutSha256 = (Get-FileHash -LiteralPath $command.stdout -Algorithm SHA256).Hash.ToLowerInvariant()
        $command.stderrSha256 = (Get-FileHash -LiteralPath $command.stderr -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $execution = @{
        schema = 'yuruna.git-mirror.native-execution/v1'; candidateId = $candidate.candidateId
        id = $id; platform = $platform; recipeHash = Get-GitMirrorJsonHash $recipe
        startedAt = $started.ToString('o'); durationSeconds = $clock.Elapsed.TotalSeconds
        commands = $commands.ToArray(); observations = $observations.ToArray(); failure = $failure
    }
    $executionPath = Join-Path $directory execution.json
    [IO.File]::WriteAllText($executionPath, ($execution | ConvertTo-Json -Depth 30) + "`n")
    $artifacts = @(Get-ChildItem -LiteralPath $directory -File | ForEach-Object {
            @{ path = "$id/$($_.Name)"; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
        })
    $row = @{
        id = $id; platform = $platform; phase = $required[0].phase
        result = $(if ($failure) { 'fail' } else { 'pass' }); durationSeconds = $clock.Elapsed.TotalSeconds
        executionSha256 = (Get-FileHash -LiteralPath $executionPath -Algorithm SHA256).Hash.ToLowerInvariant()
        artifacts = $artifacts
    }
    if ($id -ceq 'GM-UTM-AQUA') {
        $row.sessionKind = ($observations | Where-Object name -CEQ sessionKind).after.value
        $row.refreshVerdict = ($observations | Where-Object name -CEQ refreshVerdict).after.value
    }
    $rows.Add($row)
}
$evidence = @{ schema = 'yuruna.git-mirror.qualification/v1'; candidateId = $candidate.candidateId; identity = $candidate.identity; rows = $rows.ToArray() }
$evidencePath = Join-Path $output native-evidence.json
[IO.File]::WriteAllText($evidencePath, ($evidence | ConvertTo-Json -Depth 30) + "`n")
Write-Output $evidencePath
if (@($rows | Where-Object result -CNE pass).Count) { exit 1 }
