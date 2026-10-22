<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42d0d3f5-5045-4fb5-9bb9-b7a3a91c01d6
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-GitMirrorJsonHash {
    <# .SYNOPSIS
        Hash JSON values with deterministic dictionary ordering.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Value)
    function ConvertTo-CanonicalValue {
        param($InputValue)
        if ($InputValue -is [Collections.IDictionary]) {
            $result = [ordered]@{}
            [string[]]$keys = @($InputValue.Keys)
            [Array]::Sort($keys, [StringComparer]::Ordinal)
            foreach ($key in $keys) {
                $result[$key] = ConvertTo-CanonicalValue $InputValue[$key]
            }
            return $result
        }
        if ($InputValue -is [Collections.IEnumerable] -and $InputValue -isnot [string]) {
            $items = @($InputValue | ForEach-Object { ConvertTo-CanonicalValue $_ })
            return ,$items
        }
        return $InputValue
    }
    $json = ConvertTo-Json -InputObject (ConvertTo-CanonicalValue $Value) -Depth 30 -Compress
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}

function Invoke-GitMirrorCandidateGit {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$Arguments)
    $result = @(& git -C $Root @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Candidate Git failed: $($result -join ' ')" }
    return ($result -join "`n").Trim()
}

function Test-GitMirrorArchiveTree {
    [CmdletBinding()]
    param([string]$ArchivePath, [string]$Root, [string]$Tree)
    $entries = Invoke-GitMirrorCandidateGit $Root @('ls-tree', '-r', '-z', $Tree)
    $expected = @{}
    foreach ($line in $entries.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($line -cmatch '^([0-9]{6}) blob ([0-9a-f]{40})\t(.+)$') {
            $expected[$Matches[3]] = @{ mode = $Matches[1]; oid = $Matches[2] }
        }
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $stream = [IO.File]::OpenRead($ArchivePath)
    $reader = [System.Formats.Tar.TarReader]::new($stream)
    try {
        while ($null -ne ($entry = $reader.GetNextEntry())) {
            if ([string]$entry.EntryType -in @('Directory', 'GlobalExtendedAttributes')) { continue }
            $name = [string]$entry.Name
            if (-not $expected.ContainsKey($name) -or -not $seen.Add($name)) { throw "Archive contains unexpected or duplicate path: $name" }
            $record = $expected[$name]
            $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA1)
            try {
                if ([string]$entry.EntryType -ceq 'SymbolicLink') {
                    if ($record.mode -cne '120000') { throw "Archive mode mismatch: $name" }
                    $data = [Text.Encoding]::UTF8.GetBytes($entry.LinkName)
                    $hash.AppendData([Text.Encoding]::UTF8.GetBytes("blob $($data.Length)`0"))
                    $hash.AppendData($data)
                } elseif ([string]$entry.EntryType -in @('RegularFile', 'V7RegularFile')) {
                    $mode = if (([int]$entry.Mode -band 73) -ne 0) { '100755' } else { '100644' }
                    if ($record.mode -cne $mode) { throw "Archive mode mismatch: $name" }
                    $hash.AppendData([Text.Encoding]::UTF8.GetBytes("blob $($entry.Length)`0"))
                    $buffer = [byte[]]::new(65536)
                    if ($entry.DataStream) {
                        while (($count = $entry.DataStream.Read($buffer, 0, $buffer.Length)) -gt 0) { $hash.AppendData($buffer, 0, $count) }
                    }
                } else { throw "Archive has unsupported entry type: $name" }
                if ([Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant() -cne $record.oid) {
                    throw "Archive bytes do not match staged tree: $name"
                }
            } finally { $hash.Dispose() }
        }
    } finally { $reader.Dispose(); $stream.Dispose() }
    if ($seen.Count -ne $expected.Count) { throw 'Archive omits staged tree files.' }
}

function Get-GitMirrorQualificationContract {
    <# .SYNOPSIS
        Read the required scenario and platform combinations from the candidate.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$FrameworkRoot)
    $path = Join-Path $FrameworkRoot 'test/fixtures/git-mirror/qualification-contract.json'
    $contract = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable
    if ($contract.schema -cne 'yuruna.git-mirror.qualification-contract/v1' -or
        $contract.fixture.commit -cne '160bbb0855b3c304ad61ab45c02b7ef7c042721d' -or
        @($contract.requiredPhases) -join ',' -cne '0,1,2,3' -or @($contract.rows).Count -lt 1) {
        throw 'Invalid checked-in mirror qualification contract.'
    }
    if ($contract.fixture.manifestPath -cne 'test/fixtures/git-mirror/public-2026.10.18.2.json' -or
        (Get-FileHash -LiteralPath (Join-Path $FrameworkRoot $contract.fixture.manifestPath) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $contract.fixture.manifestSha256) {
        throw 'The recorded old public fixture file hashes changed.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $contract.rows) {
        if ($row.phase -notin $contract.requiredPhases -or
            $row.platform -notin @('linux-x64', 'windows-x64', 'windows-arm64', 'macos-arm64') -or
            $row.id -cnotmatch '^GM-[A-Z0-9-]+$' -or -not $seen.Add("$($row.id)/$($row.platform)")) {
            throw 'Invalid or duplicate required qualification row.'
        }
    }
    $contract.nativeRecipes = @()
    foreach ($relative in $contract.nativeRecipePaths) {
        if ($relative -cnotmatch '^test/fixtures/git-mirror/native-[a-z-]+\.json$') { throw 'Unsafe native recipe catalog path.' }
        $catalog = Get-Content -Raw -LiteralPath (Join-Path $FrameworkRoot $relative) | ConvertFrom-Json -AsHashtable
        if ($catalog.schema -cne 'yuruna.git-mirror.native-recipes/v1') { throw 'Invalid native recipe catalog.' }
        foreach ($recipe in $catalog.recipes) {
            if ($recipe.ContainsKey('prepareOrigins') -and $recipe.prepareOrigins) {
                $prepare = @{
                    source = 'candidate'; path = 'tools/Invoke-GitMirrorNativeOrigins.ps1'; stage = 'setup'; timeoutSeconds = 600
                    arguments = @('-Action', 'Prepare', '-ProxyHost', '${ProxyHost}', '-SshKeyPath', '${ProxySshKeyPath}',
                        '-RunId', '${OriginRunId}', '-UpstreamsPath', '${UpstreamsPath}', '-OutputPath', '${OriginPreparePath}', '-DisposableTarget')
                }
                $restore = @{
                    source = 'candidate'; path = 'tools/Invoke-GitMirrorNativeOrigins.ps1'; timeoutSeconds = 180
                    arguments = @('-Action', 'Restore', '-ProxyHost', '${ProxyHost}', '-SshKeyPath', '${ProxySshKeyPath}',
                        '-RunId', '${OriginRunId}', '-OutputPath', '${OriginRestorePath}', '-DisposableTarget')
                }
                $recipe.commands = @($prepare) + @($recipe.commands)
                $cleanup = @(if ($recipe.ContainsKey('cleanupCommands')) { $recipe.cleanupCommands })
                $recipe.cleanupCommands = $cleanup + @($restore)
            }
        }
        $contract.nativeRecipes += @($catalog.recipes)
    }
    return $contract
}

function Get-GitMirrorCandidateIdentity {
    <# .SYNOPSIS
        Independently measure final staged trees and qualification source inputs.
    #>
    [CmdletBinding()]
    [OutputType([Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$FrameworkRoot,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$SourceFrameworkCommit,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$SourceProjectCommit
    )
    $contract = Get-GitMirrorQualificationContract -FrameworkRoot $FrameworkRoot
    foreach ($root in @($FrameworkRoot, $ProjectRoot)) {
        $null = Invoke-GitMirrorCandidateGit -Root $root -Arguments @('diff', '--exit-code')
    }
    $frameworkTree = Invoke-GitMirrorCandidateGit -Root $FrameworkRoot -Arguments @('write-tree')
    $projectTree = Invoke-GitMirrorCandidateGit -Root $ProjectRoot -Arguments @('write-tree')
    $fingerprints = [ordered]@{}
    foreach ($relative in @(
            'test/fixtures/git-mirror/qualification-contract.json',
            'tools/GitMirror.Qualification.psm1',
            'tools/GitMirror.NativeQualification.psm1',
            'tools/Invoke-GitMirrorQualification.ps1',
            'tools/Invoke-GitMirrorNativeQualification.ps1',
            'tools/Test-GitMirrorNativeService.ps1',
            'tools/Invoke-GitMirrorNativeWorker.ps1',
            'tools/git_mirror_native_worker.py',
            'tools/Initialize-GitMirrorNativeInstall.ps1',
            'tools/Invoke-GitMirrorNativeRoute.ps1',
            'tools/Invoke-GitMirrorNativeGuest.ps1',
            'tools/Invoke-GitMirrorNativeOutage.ps1',
            'tools/git_mirror_outage_fixture.py',
            'tools/Invoke-GitMirrorNativeOrigins.ps1',
            'tools/git_mirror_native_origins.py',
            'tools/Invoke-GitMirrorNativeProvision.ps1',
            'tools/git_mirror_native_rotation.py',
            'tools/Test-GitMirrorQualification.ps1',
            'tools/git_mirror_http_fixture.py',
            'host/vmconfig/caching-proxy-service.base.user-data',
            'test/modules/Test.HostGit.psm1',
            'test/extension/caching-proxy-service/gitmirror.go')) {
        $fingerprints[$relative] = (Get-FileHash -LiteralPath (Join-Path $FrameworkRoot $relative) -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    # Capabilities are checked against the candidate, never chosen by evidence.
    $runtime = Get-Content -Raw -LiteralPath (Join-Path $FrameworkRoot 'test/extension/caching-proxy-service/gitmirror.go')
    if ($runtime -notmatch 'newMirrorReader' -or $runtime -notmatch '/git-mirror/v1/resolve') {
        throw 'Candidate lacks the runtime required by its checked-in phase contract.'
    }
    $streamPath = Join-Path $FrameworkRoot 'test/extension/caching-proxy-service/gitmirror_stream.go'
    if (Test-Path -LiteralPath $streamPath) {
        $stream = Get-Content -Raw -LiteralPath $streamPath
        if ($stream -match 'Handle(?:Func)?\([^)]*/git-archive/' -or $runtime -match 'Handle(?:Func)?\([^)]*/git-archive/') {
            throw 'Candidate exposes deferred archive capabilities without their qualification contract.'
        }
    }
    return [ordered]@{
        source = [ordered]@{ frameworkCommit = $SourceFrameworkCommit; projectCommit = $SourceProjectCommit }
        trees = [ordered]@{ framework = $frameworkTree; project = $projectTree }
        fixture = $contract.fixture
        phases = @($contract.requiredPhases)
        capabilities = @('resolve', 'git', 'raw')
        fingerprint = Get-GitMirrorJsonHash -Value $fingerprints
        contractHash = Get-GitMirrorJsonHash -Value $contract
    }
}

function Test-GitMirrorCandidate {
    <# .SYNOPSIS
        Refuse a prepared candidate whose source, tree or artifact changed.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$CandidateManifestPath,
        [Parameter(Mandatory)][string]$FrameworkRoot,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$SourceFrameworkCommit,
        [Parameter(Mandatory)][string]$SourceProjectCommit
    )
    $manifest = Get-Content -Raw -LiteralPath $CandidateManifestPath | ConvertFrom-Json -AsHashtable
    $identity = Get-GitMirrorCandidateIdentity -FrameworkRoot $FrameworkRoot -ProjectRoot $ProjectRoot `
        -SourceFrameworkCommit $SourceFrameworkCommit -SourceProjectCommit $SourceProjectCommit
    if ($manifest.schema -cne 'yuruna.git-mirror.candidate/v1' -or
        (Get-GitMirrorJsonHash $manifest.identity) -cne (Get-GitMirrorJsonHash $identity)) {
        throw 'Prepared candidate does not match independently measured current inputs.'
    }
    if ($manifest.candidateId -cne (Get-GitMirrorJsonHash -Value ([ordered]@{ identity = $manifest.identity; artifacts = $manifest.artifacts }))) {
        throw 'Prepared candidate identity or artifact list changed.'
    }
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($CandidateManifestPath))
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($artifact in $manifest.artifacts) {
        if ($artifact.path -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
            @($artifact.path.Split('/') | Where-Object { $_ -in @('.', '..') }).Count -gt 0 -or
            $artifact.sha256 -cnotmatch '^[0-9a-f]{64}$' -or -not $seen.Add($artifact.path)) {
            throw 'Invalid candidate artifact path or hash.'
        }
        $file = Join-Path $parent $artifact.path
        foreach ($entry in @((Get-Item -LiteralPath $file), (Get-Item -LiteralPath (Split-Path -Parent $file)))) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Candidate artifacts cannot be symbolic links.' }
        }
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $artifact.sha256) {
            throw "Prepared candidate artifact changed: $($artifact.path)"
        }
        $name = [IO.Path]::GetFileName($artifact.path)
        if ($name -in @('framework.tar', 'project.tar')) {
            $kind = $name.Split('.')[0]
            $root = if ($kind -ceq 'framework') { $FrameworkRoot } else { $ProjectRoot }
            Test-GitMirrorArchiveTree -ArchivePath $file -Root $root -Tree $identity.trees[$kind]
        } elseif ($name -in @('ubuntu.kvm.sh', 'macos.utm.sh', 'windows.hyper-v.ps1', 'install.sha256', 'install.sha256.sig')) {
            $current = (Get-FileHash -LiteralPath (Join-Path $FrameworkRoot "install/$name") -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($current -cne $artifact.sha256) { throw "Prepared artifact differs from current staged installer: $name" }
        } else { throw "Unexpected prepared artifact: $name" }
    }
    foreach ($name in @('framework.tar', 'project.tar', 'ubuntu.kvm.sh', 'macos.utm.sh', 'windows.hyper-v.ps1', 'install.sha256', 'install.sha256.sig')) {
        if (@($manifest.artifacts | Where-Object { [IO.Path]::GetFileName($_.path) -ceq $name }).Count -ne 1) {
            throw "Required prepared artifact missing: $name"
        }
    }
    return $manifest
}

function New-GitMirrorCandidate {
    <# .SYNOPSIS
        Export an immutable candidate without committing or publishing it.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Exports only to the explicitly supplied new output path and refuses to overwrite an existing candidate.')]
    [OutputType([Collections.Specialized.OrderedDictionary], [hashtable])]
    param(
        [Parameter(Mandatory)][string]$FrameworkRoot,
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$SourceFrameworkCommit,
        [Parameter(Mandatory)][string]$SourceProjectCommit,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $identityParameters = @{
        FrameworkRoot = $FrameworkRoot; ProjectRoot = $ProjectRoot
        SourceFrameworkCommit = $SourceFrameworkCommit; SourceProjectCommit = $SourceProjectCommit
    }
    if (Test-Path -LiteralPath $OutputPath) {
        return Test-GitMirrorCandidate -CandidateManifestPath $OutputPath @identityParameters
    }
    $identity = Get-GitMirrorCandidateIdentity @identityParameters
    $output = [IO.Path]::GetFullPath($OutputPath)
    foreach ($root in @($FrameworkRoot, $ProjectRoot)) {
        $prefix = [IO.Path]::GetFullPath($root).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if ($output.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Candidate manifest must remain outside candidate trees.' }
    }
    $parent = Split-Path -Parent $output
    $null = New-Item -ItemType Directory -Path $parent -Force
    $directoryName = [IO.Path]::GetFileNameWithoutExtension($output) + '.artifacts'
    $directory = Join-Path $parent $directoryName
    if (Test-Path -LiteralPath $directory) { throw "Unclaimed candidate artifacts already exist: $directory" }
    $null = New-Item -ItemType Directory -Path $directory
    try {
        foreach ($pair in @(@{ name = 'framework'; root = $FrameworkRoot }, @{ name = 'project'; root = $ProjectRoot })) {
            $null = Invoke-GitMirrorCandidateGit -Root $pair.root -Arguments @('archive', '--format=tar',
                "--output=$(Join-Path $directory ($pair.name + '.tar'))", $identity.trees[$pair.name])
        }
        foreach ($name in @('ubuntu.kvm.sh', 'macos.utm.sh', 'windows.hyper-v.ps1', 'install.sha256', 'install.sha256.sig')) {
            Copy-Item -LiteralPath (Join-Path $FrameworkRoot "install/$name") -Destination (Join-Path $directory $name)
        }
        $artifacts = @(Get-ChildItem -LiteralPath $directory -File | Sort-Object Name | ForEach-Object {
                [ordered]@{ path = "$directoryName/$($_.Name)"; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
            })
        $manifest = [ordered]@{
            schema = 'yuruna.git-mirror.candidate/v1'
            status = 'prepared-not-qualified'
            identity = $identity
            artifacts = $artifacts
            candidateId = Get-GitMirrorJsonHash -Value ([ordered]@{ identity = $identity; artifacts = $artifacts })
        }
        [IO.File]::WriteAllText($output, ($manifest | ConvertTo-Json -Depth 30) + "`n", [Text.UTF8Encoding]::new($false))
        return $manifest
    } catch {
        Remove-Item -LiteralPath $directory -Recurse -Force
        throw
    }
}

function Test-GitMirrorQualificationEvidence {
    <# .SYNOPSIS
        Require complete native results bound to the current prepared candidate.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Candidate,
        [Parameter(Mandatory)][hashtable]$Contract,
        [Parameter(Mandatory)][hashtable]$Evidence,
        [Parameter(Mandatory)][string]$EvidenceDirectory
    )
    if ($Evidence.schema -cne 'yuruna.git-mirror.qualification/v1' -or
        $Evidence.candidateId -cne $Candidate.candidateId -or
        (Get-GitMirrorJsonHash $Evidence.identity) -cne (Get-GitMirrorJsonHash $Candidate.identity)) {
        throw 'Qualification evidence belongs to a different candidate, fixture or source fingerprint.'
    }
    $required = @{}
    foreach ($row in $Contract.rows) { $required["$($row.id)/$($row.platform)"] = $row }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $Evidence.rows) {
        $key = "$($row.id)/$($row.platform)"
        if (-not $required.ContainsKey($key) -or -not $seen.Add($key)) { throw "Unexpected or duplicate qualification row: $key" }
        if ($row.result -cne 'pass' -or $row.phase -ne $required[$key].phase -or @($row.artifacts).Count -lt 1) {
            throw "Qualification row is incomplete or failed: $key"
        }
        if ($row.id -ceq 'GM-UTM-AQUA' -and ($row.sessionKind -cne 'Aqua' -or $row.refreshVerdict -cne 'restarted')) {
            throw 'UTM activation requires a measured Aqua restart.'
        }
        if ($row.id -ceq 'GM-OUTAGE-6MIN-NO-CONTENT' -and [double]$row.durationSeconds -lt 360) {
            throw 'The wall-clock outage observation lasted less than six minutes.'
        }
        foreach ($artifact in $row.artifacts) {
            if ($artifact.path -match '(^|[/\\])\.\.([/\\]|$)' -or [IO.Path]::IsPathRooted($artifact.path) -or
                $artifact.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Unsafe qualification artifact path or hash.' }
            if ((Get-FileHash -LiteralPath (Join-Path $EvidenceDirectory $artifact.path) -Algorithm SHA256).Hash.ToLowerInvariant() -cne $artifact.sha256) {
                throw "Qualification artifact changed: $($artifact.path)"
            }
        }
        if (-not $row.ContainsKey('executionSha256') -or $row.executionSha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw "Qualification row has no measured native execution record: $key"
        }
        $executionArtifact = @($row.artifacts | Where-Object { $_.sha256 -ceq $row.executionSha256 })
        if ($executionArtifact.Count -ne 1) { throw "Native execution artifact is missing or ambiguous: $key" }
        $execution = Get-Content -Raw -LiteralPath (Join-Path $EvidenceDirectory $executionArtifact[0].path) | ConvertFrom-Json -AsHashtable
        $recipes = @($Contract.nativeRecipes | Where-Object { $_.id -ceq $row.id -and $_.platform -in @('*', $row.platform) })
        if ($recipes.Count -ne 1) { throw "No unique executable native recipe for required row: $key" }
        $recipe = $recipes[0]
        $expectedCommands = @($recipe.commands)
        if ($recipe.ContainsKey('cleanupCommands')) { $expectedCommands += @($recipe.cleanupCommands) }
        if (($recipe.ContainsKey('coverage') -and $recipe.coverage -cne 'complete') -or
            $execution.schema -cne 'yuruna.git-mirror.native-execution/v1' -or
            $execution.candidateId -cne $Candidate.candidateId -or $execution.id -cne $row.id -or $execution.platform -cne $row.platform -or
            $execution.recipeHash -cne (Get-GitMirrorJsonHash $recipe) -or $execution.failure -or
            @($execution.commands).Count -ne $expectedCommands.Count -or @($execution.observations).Count -ne @($recipe.observations).Count) {
            throw "Native execution does not match its complete frozen recipe: $key"
        }
        if ([Math]::Abs([double]$row.durationSeconds - [double]$execution.durationSeconds) -gt 1 -or
            ($row.id -ceq 'GM-OUTAGE-6MIN-NO-CONTENT' -and [double]$execution.durationSeconds -lt 360)) {
            throw "Native execution duration does not support the row: $key"
        }
        foreach ($command in $execution.commands) {
            $definitions = @($expectedCommands | Where-Object { (Get-GitMirrorJsonHash $_) -ceq $command.commandHash })
            if (-not $definitions.Count) { throw "Native execution command is absent from the frozen recipe: $key" }
            $definition = $definitions[0]
            $expectedExitCodes = if ($definition.ContainsKey('expectedExitCodes')) { @($definition.expectedExitCodes) } else { @(0) }
            if ($command.timedOut -or ($null -ne $command.exitCode -and $command.exitCode -notin $expectedExitCodes) -or
                ($null -eq $command.exitCode -and (-not $definition.ContainsKey('background') -or -not $definition.background)) -or
                $command.sourceHash -cnotmatch '^[0-9a-f]{64}$' -or
                @($expectedCommands | Where-Object { $_.source -ceq $command.source -and $_.path -ceq $command.path }).Count -eq 0 -or
                @($row.artifacts | Where-Object { $_.sha256 -ceq $command.stdoutSha256 }).Count -eq 0 -or
                @($row.artifacts | Where-Object { $_.sha256 -ceq $command.stderrSha256 }).Count -eq 0 -or
                ($command.source -ceq 'installer' -and -not $command.installerSignatureVerified)) {
                throw "Native execution contains a failed or unverified command: $key"
            }
        }
        foreach ($definition in $expectedCommands) {
            $hash = Get-GitMirrorJsonHash $definition
            if (@($execution.commands | Where-Object { $_.commandHash -ceq $hash }).Count -ne
                @($expectedCommands | Where-Object { (Get-GitMirrorJsonHash $_) -ceq $hash }).Count) {
                throw "Native execution omitted or repeated a frozen command: $key"
            }
        }
        foreach ($expected in $recipe.observations) {
            $observed = @($execution.observations | Where-Object { $_.name -ceq $expected.name -and $_.kind -ceq $expected.kind })
            if ($observed.Count -ne 1 -or -not $observed[0].passed) { throw "Native execution observation missing or failed: $key/$($expected.name)" }
            if ($expected.kind -ceq 'json' -and
                (ConvertTo-Json -InputObject $observed[0].after.value -Depth 10 -Compress) -cne
                (ConvertTo-Json -InputObject $expected.expected -Depth 10 -Compress)) {
                throw "Native execution measured a different value: $key/$($expected.name)"
            }
            if ($expected.kind -ceq 'file-preserved' -and $observed[0].before.hash -cne $observed[0].after.hash) {
                throw "Native execution changed a preserved file: $key/$($expected.name)"
            }
            if ($expected.kind -ceq 'file-absent' -and $observed[0].after.exists) {
                throw "Native execution retained a forbidden file: $key/$($expected.name)"
            }
            if ($expected.kind -ceq 'git' -and
                (($expected.expected -ceq 'candidate' -and $observed[0].after.tree -cne $Candidate.identity.trees.framework) -or
                ($expected.expected -ceq 'old' -and $observed[0].after.head -cne $Candidate.identity.fixture.commit) -or
                ($expected.expected -ceq 'unchanged' -and ($observed[0].before.head -cne $observed[0].after.head -or $observed[0].before.tree -cne $observed[0].after.tree)))) {
                throw "Native execution used a different Git snapshot: $key/$($expected.name)"
            }
        }
    }
    foreach ($key in $required.Keys) {
        if (-not $seen.Contains($key)) { throw "Required qualification row is missing: $key" }
    }
    return @{ status = 'qualified'; candidateId = $Candidate.candidateId; rows = $seen.Count }
}

Export-ModuleMember -Function Get-GitMirrorJsonHash, Get-GitMirrorQualificationContract, Get-GitMirrorCandidateIdentity, New-GitMirrorCandidate, Test-GitMirrorCandidate, Test-GitMirrorQualificationEvidence
