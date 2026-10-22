<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42c2450e-2f43-48fd-a465-cda41ea42d2a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
<#
.SYNOPSIS
    Prepare isolated release fixtures and merge measured native qualification.
.DESCRIPTION
    Candidate preparation never publishes a ref. Public ancestry is fetched once
    into the explicit work directory; subsequent qualification reuses that cache.
    Native result files retain their original supporting artifacts. Missing
    native observations produce an incomplete result and exit 2, never a pass.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CandidateManifestPath,
    [Parameter(Mandatory)][string]$FrameworkRoot,
    [Parameter(Mandatory)][string]$ProjectRoot,
    [Parameter(Mandatory)][string]$SourceFrameworkCommit,
    [Parameter(Mandatory)][string]$SourceProjectCommit,
    [Parameter(Mandatory)][string]$WorkPath,
    [string[]]$NativeEvidencePath = @(),
    [string[]]$NativeProfilePath = @(),
    [switch]$DisposableTarget,
    [switch]$PrepareFixtures
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GitMirror.Qualification.psm1') -Force
$candidate = Test-GitMirrorCandidate -CandidateManifestPath $CandidateManifestPath -FrameworkRoot $FrameworkRoot `
    -ProjectRoot $ProjectRoot -SourceFrameworkCommit $SourceFrameworkCommit -SourceProjectCommit $SourceProjectCommit
$contract = Get-GitMirrorQualificationContract -FrameworkRoot $FrameworkRoot
$work = [IO.Path]::GetFullPath($WorkPath)
foreach ($root in @($FrameworkRoot, $ProjectRoot)) {
    $prefix = [IO.Path]::GetFullPath($root).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($work.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Qualification work must remain outside candidate trees.' }
}
$null = New-Item -ItemType Directory -Path $work -Force

function Invoke-FixtureGit {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Arguments)
    $output = @(& git -C $Root @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Qualification fixture Git failed: $($output -join ' ')" }
    return ($output -join "`n").Trim()
}

function Get-FixtureGitBlobHash {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Root, [string]$Object)
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command git -CommandType Application).Source)
    foreach ($argument in @('-C', $Root, 'show', $Object)) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $errors = $process.StandardError.ReadToEndAsync()
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $value = $hash.ComputeHash($process.StandardOutput.BaseStream)
        $process.WaitForExit()
        if ($process.ExitCode) { throw "Fixture blob unavailable: $($errors.GetAwaiter().GetResult())" }
        return [Convert]::ToHexString($value).ToLowerInvariant()
    } finally { $hash.Dispose(); $process.Dispose() }
}

if ($PrepareFixtures) {
    $fixturePath = Join-Path $work 'upstreams.json'
    if (Test-Path -LiteralPath $fixturePath) {
        $existing = Get-Content -Raw -LiteralPath $fixturePath | ConvertFrom-Json -AsHashtable
        if ($existing.candidateId -cne $candidate.candidateId) { throw 'Work path already belongs to another candidate.' }
        $fixtures = $existing
    } else {
        $fixtures = [ordered]@{ candidateId = $candidate.candidateId; fixture = $contract.fixture; repositories = @() }
        foreach ($pair in @(
                @{ name = 'framework'; root = $FrameworkRoot; url = 'https://github.com/alissonsol/yuruna.git' },
                @{ name = 'project'; root = $ProjectRoot; url = 'https://github.com/alissonsol/yuruna-project.git' })) {
            $repository = Join-Path $work ($pair.name + '.git')
            if (Test-Path -LiteralPath $repository) { throw "Unclaimed fixture repository already exists: $repository" }
            $null = New-Item -ItemType Directory -Path $repository
            $null = Invoke-FixtureGit $repository @('init', '--bare', '--initial-branch=main')
            # Only explicit public origins are fetched, never an ambient origin.
            $null = Invoke-FixtureGit $repository @('-c', 'credential.helper=', 'fetch', '--no-tags', $pair.url, "refs/tags/$($contract.fixture.release):refs/tags/$($contract.fixture.release)")
            $old = Invoke-FixtureGit $repository @('rev-parse', "refs/tags/$($contract.fixture.release)^{commit}")
            if ($pair.name -eq 'framework' -and $old -cne $contract.fixture.commit) { throw 'Old public release has the wrong commit.' }
            $null = Invoke-FixtureGit $repository @('fetch', '--no-tags', $pair.root, $candidate.identity.trees[$pair.name])
            $tree = Invoke-FixtureGit $repository @('rev-parse', 'FETCH_HEAD^{tree}')
            if ($tree -cne $candidate.identity.trees[$pair.name]) { throw 'Fixture candidate tree changed during transfer.' }
            $commit = Invoke-FixtureGit $repository @('-c', 'user.name=Qualification fixture', '-c', 'user.email=fixture@example.invalid',
                'commit-tree', $tree, '-p', $old, '-m', "Unpublished candidate $($candidate.candidateId)")
            $null = Invoke-FixtureGit $repository @('update-ref', 'refs/heads/main', $commit)
            $null = Invoke-FixtureGit $repository @('update-ref', 'refs/tags/qualification-candidate', $commit)
            $fixtures.repositories += [ordered]@{ name = $pair.name; canonicalUrl = $pair.url; localPath = $repository; oldCommit = $old; candidateCommit = $commit; tree = $tree }
        }
        [IO.File]::WriteAllText($fixturePath, ($fixtures | ConvertTo-Json -Depth 12) + "`n")
    }
    foreach ($repository in $fixtures.repositories) {
        if ($repository.name -notin @('framework', 'project') -or
            (Invoke-FixtureGit $repository.localPath @('rev-parse', 'refs/heads/main^{tree}')) -cne $candidate.identity.trees[$repository.name] -or
            (Invoke-FixtureGit $repository.localPath @('rev-parse', 'refs/heads/main')) -cne $repository.candidateCommit) {
            throw 'Cached qualification repository no longer matches its frozen candidate.'
        }
        if ($repository.name -ceq 'framework') {
            if ($repository.oldCommit -cne $contract.fixture.commit) { throw 'Cached public fixture commit changed.' }
            $oldFiles = Get-Content -Raw -LiteralPath (Join-Path $FrameworkRoot $contract.fixture.manifestPath) | ConvertFrom-Json -AsHashtable
            foreach ($file in $oldFiles.files) {
                if ((Get-FixtureGitBlobHash -Root $repository.localPath -Object "$($contract.fixture.commit):$($file.path)") -cne $file.sha256) {
                    throw "Old public fixture bytes changed: $($file.path)"
                }
            }
        }
    }
}

foreach ($nativeProfile in $NativeProfilePath) {
    if (-not $DisposableTarget) { throw 'Executing native profiles requires -DisposableTarget.' }
    $nativeOutput = Join-Path $work ('native-' + [guid]::NewGuid().ToString('N'))
    & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $PSScriptRoot 'Invoke-GitMirrorNativeQualification.ps1') `
        -CandidateManifestPath $CandidateManifestPath -FrameworkRoot $FrameworkRoot -ProjectRoot $ProjectRoot `
        -SourceFrameworkCommit $SourceFrameworkCommit -SourceProjectCommit $SourceProjectCommit `
        -ProfilePath $nativeProfile -OutputPath $nativeOutput -DisposableTarget
    $nativeResult = Join-Path $nativeOutput native-evidence.json
    if (-not (Test-Path -LiteralPath $nativeResult)) { throw "Native runner produced no evidence: $nativeProfile" }
    $NativeEvidencePath += $nativeResult
}
$rows = [Collections.Generic.List[object]]::new()
foreach ($path in $NativeEvidencePath) {
    $native = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable
    if ($native.candidateId -cne $candidate.candidateId -or
        (Get-GitMirrorJsonHash $native.identity) -cne (Get-GitMirrorJsonHash $candidate.identity)) {
        throw "Native evidence belongs to another candidate: $path"
    }
    $source = Split-Path -Parent ([IO.Path]::GetFullPath($path))
    foreach ($row in $native.rows) {
        foreach ($artifact in $row.artifacts) {
            if ($artifact.path -match '(^|[/\\])\.\.([/\\]|$)' -or [IO.Path]::IsPathRooted($artifact.path)) { throw 'Unsafe native artifact path.' }
            $file = Join-Path $source $artifact.path
            $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($hash -cne $artifact.sha256) { throw "Native evidence artifact changed: $file" }
            $name = "$hash.bin"
            $target = Join-Path $work $name
            if (-not (Test-Path -LiteralPath $target)) { Copy-Item -LiteralPath $file -Destination $target }
            $artifact.path = $name
        }
        $rows.Add($row)
    }
}
$evidence = [ordered]@{ schema = 'yuruna.git-mirror.qualification/v1'; candidateId = $candidate.candidateId; identity = $candidate.identity; rows = $rows.ToArray() }
$outputPath = Join-Path $work 'git-mirror-qualification.json'
[IO.File]::WriteAllText($outputPath, ($evidence | ConvertTo-Json -Depth 30) + "`n")
try {
    $result = Test-GitMirrorQualificationEvidence -Candidate $candidate -Contract $contract -Evidence $evidence -EvidenceDirectory $work
    Write-Output "Qualified $($result.candidateId): $($result.rows) required rows. Evidence: $outputPath"
    exit 0
} catch {
    Write-Warning "Prepared, not qualified: $($_.Exception.Message) Evidence: $outputPath"
    exit 2
}
