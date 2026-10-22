<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42a7229d-27c5-49c9-b988-b09c540defad
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna git mirror source generation
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

Import-Module (Join-Path $PSScriptRoot 'Test.Config.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.ConfigSync.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.CachingProxyService.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.HostGit.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.PoolPlanner.psm1') -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -DisableNameChecking

function Get-GitSourceConfiguration {
    <# .SYNOPSIS
        Read host source settings before the first update, without reconciling disk.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$ConfigPath)
    $config = if (Test-Path -LiteralPath $ConfigPath) { Read-TestConfig -Path $ConfigPath -NoCache -ThrowOnError } else { [ordered]@{} }
    $failures = @(Test-ConfigMirrorSetting -Config $config)
    if ($failures.Count -gt 0) { throw "$($failures[0].Cause): $($failures[0].Path)" }
    $mirror = if ($config.repositories -and $config.repositories.mirror) { $config.repositories.mirror } else { @{} }
    $context = @{
        mode = if ($mirror.Contains('mode')) { [string]$mirror.mode } else { 'prefer' }
        url = [string]$mirror.url
        verificationPublicKeys = @($mirror.verificationPublicKeys | Where-Object { $null -ne $_ })
        mirrorOnlyMaxAgeSeconds = if ($mirror.Contains('mirrorOnlyMaxAgeSeconds')) { [int]$mirror.mirrorOnlyMaxAgeSeconds } else { 604800 }
    }
    if (-not $context.url) {
        $address = [string]$config.vmStart.cachingProxyIp
        if (-not $address) { $address = $env:YURUNA_CACHING_PROXY_SERVICE_IP }
        if (-not $address) { $address = Get-CachingProxyServiceStateIp -ReadOnly }
        if ($address) {
            $parsed = $null
            if ([Net.IPAddress]::TryParse($address.Trim(), [ref]$parsed)) {
                $hostPart = if ($parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) { "[$parsed]" } else { [string]$parsed }
                $context.url = "http://$hostPart"
            }
        }
    }
    $frameworkUrl = [string]$config.repositories.frameworkUrl
    $projectUrl = [string]$config.repositories.projectUrl
    $pool = Read-YurunaPoolManifest
    if ($pool -is [System.Collections.IDictionary] -and $pool.repositories -is [System.Collections.IDictionary] -and
        $pool.repositories.frameworkUrl -and $pool.repositories.projectUrl) {
        # Only repository assignment is pool-owned. Mirror trust and policy
        # always come from this host's operator-managed configuration.
        $frameworkUrl = [string]$pool.repositories.frameworkUrl
        $projectUrl = [string]$pool.repositories.projectUrl
    }
    return @{
        context = $context
        frameworkUrl = $frameworkUrl
        projectUrl = $projectUrl
        refreshSeconds = if ($config.vmStart -and $config.vmStart.Contains('cachingProxyGitMirrorRefreshSeconds')) { [int]$config.vmStart.cachingProxyGitMirrorRefreshSeconds } else { 60 }
    }
}

function Get-GitSourceHandoffPath {
    <# .SYNOPSIS
        Locate the generation record outside served trees in private host state.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([switch]$Create)
    $resolved = Get-YurunaPrivateStatePath -Name 'source-selection.json' -Subdirectory 'git-mirror' -NoCreate:(-not $Create)
    if (-not $resolved.Resolved) {
        if ($Create) { throw "source-handoff-path-unavailable: $($resolved.Reason)" }
        return ''
    }
    return [string]$resolved.Path
}

function ConvertTo-GitSourceSafeUrl {
    <# .SYNOPSIS
        Keep legacy transport credentials out of displayed or retained provenance.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    $text = [string]$Value
    $parsed = $null
    if ([uri]::TryCreate($text, [UriKind]::Absolute, [ref]$parsed) -and $parsed.UserInfo) {
        $builder = [UriBuilder]::new($parsed)
        $builder.UserName = ''; $builder.Password = ''
        return $builder.Uri.AbsoluteUri
    }
    return $text
}

function ConvertTo-GitSourceStoredSelection {
    <# .SYNOPSIS
        Retain source evidence without transport credentials or incidental output.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Selection)
    $copy = @{}
    foreach ($key in @('success','repository','ref','selectedSha','fetchRef','fetchUrl','source','verification',
            'originCheckedAt','refreshAgeSeconds','mirrorVersion','keyId','fallbackReason','failureClass',
            'resolvedDefaultBranch','proof','acceptedAt')) {
        $copy[$key] = if ($key -in @('repository','fetchUrl')) { ConvertTo-GitSourceSafeUrl $Selection[$key] } else { $Selection[$key] }
    }
    return $copy
}

function Get-InstalledGitSourceSelection {
    <# .SYNOPSIS
        Describe an installed checkout without inventing upstream confirmation.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $sha = [string](& git -C $RepoRoot rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or $sha.Trim() -notmatch '^[0-9a-f]{40}$') { throw 'source-installed-head-unavailable' }
    $url = [string](& git -C $RepoRoot remote get-url origin 2>$null)
    $url = ConvertTo-GitSourceSafeUrl $url.Trim()
    $identity = $url
    $canonical = if ($url) { Get-GitMirrorRepository -Url $url } else { '' }
    if ($canonical) { $identity = $canonical }
    return @{
        success=$true; repository=$identity; ref='HEAD'; selectedSha=$sha.Trim(); fetchRef=$sha.Trim()
        source='origin'; verification='not-applicable'; fetchUrl=$url.Trim(); originCheckedAt=$null
        refreshAgeSeconds=$null; mirrorVersion=''; keyId=''; fallbackReason=''; failureClass=''; detail=''
    }
}

function Invoke-GitSourceGate {
    <# .SYNOPSIS
        Resolve sources once for a gate and retain the exact project pin for its cycle.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$ConfigPath,
        [AllowEmptyString()][string]$CycleGeneration = '')
    $snapshot = Get-GitSourceConfiguration -ConfigPath $ConfigPath
    $prior = Read-InstalledGitSource -RepoRoot $RepoRoot
    $handoff = if ($CycleGeneration) { Read-GitSourceHandoff -CycleGeneration $CycleGeneration -RepoRoot $RepoRoot -ConfigPath $ConfigPath } else { $null }
    $result = @{ framework=$null; frameworkUrl=''; project=$null; projectUrl=$snapshot.projectUrl; skipGitHubProbe=$false; context=$snapshot.context; frameworkSkipped=$false }
    if ($handoff -and $handoff.framework.verification -eq 'not-applicable') {
        $result.framework = $handoff.framework
        $result.frameworkUrl = [string]$handoff.framework.fetchUrl
        $result.frameworkSkipped = $true
    } else {
        $arguments = @{ RepoRoot=$RepoRoot; SourceContext=$snapshot.context; InstalledProvenance=$prior.framework; NoFetch=$true; Operation='Gate'; DeadlineUtc=[DateTimeOffset]::UtcNow.AddSeconds(45) }
        if ($handoff) { $arguments.SourceSelection=$handoff.framework; $arguments.SelectionAcceptedAt=[DateTimeOffset]$handoff.frameworkAcceptedAt }
        $target = Get-GitRepositoryUpdateTarget @arguments
        $result.frameworkUrl = [string]$target.RemoteUrl
        $result.framework = $target.SourceSelection
        if (-not $target.Success) {
            if (-not $result.framework) { $result.framework = @{} }
            $result.framework.success=$false
            $result.framework.failureClass=$(if ($target.FailureClass) { $target.FailureClass } else { 'bootstrap_sync' })
            $result.framework.detail=$target.ErrorMessage
        }
        if ($target.Skipped) { $result.frameworkSkipped=$true }
    }
    if ($snapshot.projectUrl -and (Get-GitMirrorRepository -Url $snapshot.projectUrl)) {
        if ($handoff -and $handoff.project) {
            $valid = Test-GitSourceSelection -Selection $handoff.project -RepositoryUrl $snapshot.projectUrl -Ref HEAD -SourceContext $snapshot.context -AcceptedAt ([DateTimeOffset]$handoff.projectAcceptedAt)
            if (-not $valid.success) { throw "source-handoff-project-invalid: $($valid.reason)" }
            $result.project = $handoff.project
        } else {
            $projectRoot = Join-Path $RepoRoot 'project'
            $installed = ''
            if (Test-Path -LiteralPath (Join-Path $projectRoot '.git')) { $installed = [string](& git -C $projectRoot rev-parse HEAD 2>$null); $installed = $installed.Trim() }
            $result.project = Resolve-GitSourceSelection -RepositoryUrl $snapshot.projectUrl -Ref HEAD -SourceContext $snapshot.context -Operation Gate -InstalledRevision $installed -InstalledProvenance $prior.project -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(45))
            if ($handoff -and $result.project.success) {
                if (-not (Write-GitSourceHandoff -CycleGeneration $CycleGeneration -RepoRoot $RepoRoot -ConfigPath $ConfigPath -Project $result.project -Confirm:$false)) { throw 'source-handoff-write-failed' }
            }
        }
    }
    $required = @()
    if (-not $result.frameworkSkipped -and $result.framework) { $required += $result.framework }
    if ($result.project) { $required += $result.project }
    $githubSources = @($required | Where-Object { $_.repository -match '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' })
    # A successful required ref observation is the connectivity evidence. A
    # later independent TCP probe cannot veto code that was already selected.
    $result.skipGitHubProbe = $githubSources.Count -eq 0 -or @($githubSources | Where-Object { -not $_.success }).Count -eq 0
    return $result
}

function Read-InstalledGitSource {
    <# .SYNOPSIS
        Read previous installed provenance from owner-protected host state.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$RepoRoot)
    $path = Get-YurunaPrivateStatePath -Name 'installed-sources.json' -Subdirectory 'git-mirror' -NoCreate
    if (-not $path.Resolved -or -not (Test-Path -LiteralPath $path.Path)) { return @{} }
    if ((Get-Item -LiteralPath $path.Path).Length -gt 262144) { throw 'source-provenance-oversized' }
    $document = Get-Content -LiteralPath $path.Path -Raw | ConvertFrom-Json -AsHashtable -Depth 20
    if ($document.schemaVersion -ne 1 -or $document.repoRoot -cne [IO.Path]::GetFullPath($RepoRoot)) { return @{} }
    return $document
}

function Write-InstalledGitSource {
    <# .SYNOPSIS
        Retain provenance only after proving its commit is installed on disk.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][ValidateSet('framework','project')][string]$Kind,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Selection)
    $checkout = if ($Kind -eq 'project') { Join-Path $RepoRoot 'project' } else { $RepoRoot }
    $sha = [string](& git -C $checkout rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $Selection.success -or $Selection.selectedSha -cne $sha.Trim()) { throw 'source-provenance-head-mismatch' }
    if (-not $PSCmdlet.ShouldProcess($checkout, 'Retain installed source provenance')) { return $false }
    $document = Read-InstalledGitSource -RepoRoot $RepoRoot
    $document.schemaVersion=1; $document.repoRoot=[IO.Path]::GetFullPath($RepoRoot); $document[$Kind]=(ConvertTo-GitSourceStoredSelection $Selection)
    $path = Get-YurunaPrivateStatePath -Name 'installed-sources.json' -Subdirectory 'git-mirror'
    if (-not $path.Resolved) { throw "source-provenance-path-unavailable: $($path.Reason)" }
    return Write-YurunaStateFileJson -Path $path.Path -InputObject $document -Depth 20 -Confirm:$false
}

function Write-GitSourceHandoff {
    <# .SYNOPSIS
        Atomically bind immutable source evidence to the runner's current generation.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$CycleGeneration,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter()][System.Collections.IDictionary]$Framework,
        [Parameter()][System.Collections.IDictionary]$Project
    )
    if ($CycleGeneration -notmatch '^[0-9a-f]{32}:[1-9][0-9]{0,8}$') { throw 'source-generation-invalid' }
    if (-not $PSCmdlet.ShouldProcess($RepoRoot, 'Write cycle source selection')) { return $false }
    $path = Get-GitSourceHandoffPath -Create
    if (-not $path) { return $false }
    if ($Framework) {
        $document = [ordered]@{
            schemaVersion = 1; cycleGeneration = $CycleGeneration
            repoRoot = [IO.Path]::GetFullPath($RepoRoot); configPath = [IO.Path]::GetFullPath($ConfigPath)
            createdAt = [DateTimeOffset]::UtcNow.ToString('O'); framework = (ConvertTo-GitSourceStoredSelection $Framework); project = $null
            frameworkAcceptedAt = $(if ($Framework.acceptedAt) { [string]$Framework.acceptedAt } else { [DateTimeOffset]::UtcNow.ToString('O') }); projectAcceptedAt = $null
        }
    } else {
        $document = Read-GitSourceHandoff -CycleGeneration $CycleGeneration -RepoRoot $RepoRoot -ConfigPath $ConfigPath
        if (-not $document) { throw 'source-handoff-missing' }
    }
    if ($Project) { $document.project = ConvertTo-GitSourceStoredSelection $Project; $document.projectAcceptedAt = $(if ($Project.acceptedAt) { [string]$Project.acceptedAt } else { [DateTimeOffset]::UtcNow.ToString('O') }) }
    return Write-YurunaStateFileJson -Path $path -InputObject $document -Depth 20 -Confirm:$false
}

function Read-GitSourceHandoff {
    <# .SYNOPSIS
        Reject stale generations, changed checkouts and malformed handoff records.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string]$CycleGeneration,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ConfigPath
    )
    $path = Get-GitSourceHandoffPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
    if ((Get-Item -LiteralPath $path).Length -gt 262144) { throw 'source-handoff-oversized' }
    $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 20
    if ($record.schemaVersion -ne 1 -or $record.cycleGeneration -cne $CycleGeneration -or
        $record.repoRoot -cne [IO.Path]::GetFullPath($RepoRoot) -or
        $record.configPath -cne [IO.Path]::GetFullPath($ConfigPath)) { throw 'source-handoff-identity-mismatch' }
    $head = [string](& git -C $RepoRoot rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or $record.framework.selectedSha -cne $head.Trim()) { throw 'source-handoff-head-mismatch' }
    return $record
}

Export-ModuleMember -Function Get-GitSourceConfiguration, Get-GitSourceHandoffPath, Get-InstalledGitSourceSelection, ConvertTo-GitSourceSafeUrl, Invoke-GitSourceGate, Read-InstalledGitSource, Write-InstalledGitSource, Write-GitSourceHandoff, Read-GitSourceHandoff
