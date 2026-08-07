<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42b7c1d9-3e5a-4f26-9c84-6d1f0a7b2e53
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna github fallback token
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

<#
.SYNOPSIS
    Resolve the GitHub coordinates a guest needs when it cannot reach the host
    status service: the repository the host is itself running from, the exact
    commit it is serving, and the token that opens that repository if it is
    private.

.DESCRIPTION
    A guest fetches project code from the host status service. When the host is
    unreachable -- a changed DHCP lease, a Wi-Fi roam, a stopped service -- it
    falls back to GitHub. That fallback is only sound if it lands on the SAME
    repository at the SAME commit the host would have served: the host hands the
    guest a sha256 of its working-tree copy, and the guest refuses to run bytes
    that do not match it. A fallback aimed at any other repository (a public
    mirror of a private repo, say), or at a moving branch, serves bytes that
    were never the ones the digest was taken from, so the integrity gate refuses
    to run them and the run dies with an "integrity mismatch" that is really
    "wrong repository" or "wrong commit".

    Two consumers ask this module the same question:

      * Test.SequenceHandler, which TYPES the coordinates into the guest console
        next to the digest, so they describe the commit being served right now.
      * Yuruna.CloudInitTemplate, which BAKES them into /etc/yuruna/host.env at
        New-VM time, so a hand-run fetch-and-execute in a guest still has a
        fallback when nothing was typed.

    Both need the same answer, so it lives here rather than in either of them.
#>

Set-StrictMode -Version Latest

function ConvertTo-GitHubRepoSlug {
    <#
    .SYNOPSIS
        Reduce a GitHub remote URL to its 'owner/repo' slug.
    .DESCRIPTION
        Accepts the shapes a remote URL actually turns up in --
        https://github.com/o/r, https://github.com/o/r.git,
        git@github.com:o/r.git, ssh://git@github.com/o/r -- and returns 'o/r'.
        A URL that is not GitHub returns '', so the caller degrades to "no
        fallback available" instead of assembling a nonsense api.github.com
        path that can only 404.
    .OUTPUTS
        [string] 'owner/repo', or '' when the URL is absent or not GitHub.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return '' }
    $m = [regex]::Match($Url.Trim(), '(?i)github\.com[:/]+([^/:]+)/([^/]+?)(?:\.git)?/*$')
    if (-not $m.Success) { return '' }
    return ('{0}/{1}' -f $m.Groups[1].Value, $m.Groups[2].Value)
}

function Get-YurunaCheckoutRemoteUrl {
    <#
    .SYNOPSIS
        The GitHub remote URL of the checkout at RepoRoot, or '' when it has none.
    .DESCRIPTION
        'origin' first, then any other configured remote, so a checkout whose
        upstream is named something else still resolves. Each name is read with
        the porcelain first and the raw config value second: `remote get-url`
        applies url.<base>.insteadOf rewrites, which is usually what is wanted,
        but it is absent from very old git and returns nothing for a remote that
        exists only as a bare config entry.

        Only a remote that reduces to a GitHub slug is accepted; a mirror on
        another host cannot serve raw.githubusercontent.com content, so skipping
        it lets a later remote answer instead.
    .PARAMETER RepoRoot
        Absolute path to the repository root.
    .OUTPUTS
        [string] the remote URL, or '' when no remote resolves to a GitHub slug.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $names = @('origin')
    $configured = & git -C $RepoRoot remote 2>$null
    if ($LASTEXITCODE -eq 0 -and $configured) { $names += @($configured | ForEach-Object { "$_".Trim() }) }

    foreach ($name in ($names | Where-Object { $_ } | Select-Object -Unique)) {
        foreach ($read in @({ & git -C $RepoRoot remote get-url $name 2>$null },
                            { & git -C $RepoRoot config --get "remote.$name.url" 2>$null })) {
            $url = & $read
            if ($LASTEXITCODE -ne 0 -or -not $url) { continue }
            $url = ([string]$url).Trim()
            if (ConvertTo-GitHubRepoSlug -Url $url) { return $url }
        }
    }
    return ''
}

function Get-YurunaGitHubSource {
    <#
    .SYNOPSIS
        The repo slug, commit, and token a guest needs to fetch this host's code
        from GitHub.
    .DESCRIPTION
        Repo and Ref MUST name the same repository, so both are read from the
        checkout at RepoRoot: the slug from its git remote, the commit from its
        HEAD. Taking the slug from a configured URL instead lets the two disagree
        whenever the checkout came from somewhere else -- a host running a
        published mirror of the repository the config names is the ordinary way
        that happens -- and the resulting URL is a commit that does not exist in
        the repository it is asked for, which can only 404. A token cannot fix
        that, and the 404 reads as "private repo, no token" instead.

        repositories.frameworkUrl still supplies FrameworkUrl, the CLONE url a
        cut-off guest needs. That is a different question from "where do these
        exact bytes live", and only the second one has to agree with Ref. When
        the two name different repositories the mismatch is reported, because a
        config pointing somewhere the checkout never came from is worth knowing
        about either way.

        Ref is RepoRoot's HEAD commit, never a branch name. A branch moves; the
        digest the host computed from its working tree does not. Pinning the
        commit is what lets the fallback bytes match that digest at all.

        Token comes from test.config.yml's repositories.ghToken and is required
        only when the repository is private -- raw.githubusercontent.com and the
        Contents API both refuse an unauthenticated read of a private repo.
        FrameworkUrl / ProjectUrl are the clone URLs, carried alongside so a guest
        that cannot reach the host has them too. A guest normally reads them from
        the host's /control/test-config -- which is exactly what a guest cut off
        from the host cannot do, leaving it able to FETCH its update script from
        GitHub but with no URL to CLONE the framework from. Baking them into the
        seed closes that gap.
    .PARAMETER RepoRoot
        Absolute path to the repository root the host is serving.
    .OUTPUTS
        [hashtable] @{ Repo = 'owner/repo'; Ref = '<sha>'; Token = '<token>';
                       FrameworkUrl = '<url>'; ProjectUrl = '<url>' }.
        Any field is '' when it could not be resolved; callers treat an empty
        Repo or Ref as "no GitHub fallback is possible".
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $result = @{ Repo = ''; Ref = ''; Token = ''; FrameworkUrl = ''; ProjectUrl = '' }
    if ([string]::IsNullOrWhiteSpace($RepoRoot) -or -not (Test-Path -LiteralPath $RepoRoot)) {
        return $result
    }

    # powershell-yaml is present wherever the runner or a New-VM script runs; a
    # context without it still gets a usable Repo/Ref from git below, just no token.
    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        Import-Module powershell-yaml -ErrorAction SilentlyContinue -Verbose:$false
    }
    $configPath = Join-Path $RepoRoot 'test/test.config.yml'
    if ((Test-Path -LiteralPath $configPath) -and (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
        try {
            $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Yaml -Ordered
            if ($config -is [System.Collections.IDictionary] -and $config.Contains('repositories')) {
                $repositories = $config['repositories']
                if ($repositories -is [System.Collections.IDictionary]) {
                    if ($repositories.Contains('frameworkUrl')) {
                        $result.FrameworkUrl = ([string]$repositories['frameworkUrl']).Trim()
                    }
                    if ($repositories.Contains('projectUrl')) {
                        $result.ProjectUrl = ([string]$repositories['projectUrl']).Trim()
                    }
                    if ($repositories.Contains('ghToken')) {
                        $result.Token = ([string]$repositories['ghToken']).Trim()
                    }
                }
            }
        } catch {
            Write-Verbose "Get-YurunaGitHubSource: could not read $configPath ($($_.Exception.Message)); falling back to the git remote."
        }
    }

    # The checkout answers first, because Ref below comes from the same checkout
    # and the pair is only usable when both name one repository.
    $remoteUrl    = Get-YurunaCheckoutRemoteUrl -RepoRoot $RepoRoot
    $remoteSlug   = ConvertTo-GitHubRepoSlug -Url $remoteUrl
    $configSlug   = ConvertTo-GitHubRepoSlug -Url $result.FrameworkUrl
    $result.Repo  = $remoteSlug

    if ($remoteSlug -and $configSlug -and ($remoteSlug -ne $configSlug)) {
        Write-Warning ("This checkout came from '$remoteSlug' but repositories.frameworkUrl names '$configSlug'. " +
                       "Serving the guest fallback from '$remoteSlug' so it matches the commit being pinned; " +
                       "a commit from one repository cannot be fetched from the other. " +
                       'Point frameworkUrl at the repository this host actually tracks, or run the host from a checkout of it.')
    }
    if (-not $result.Repo) {
        # No GitHub remote at all: the configured URL is the only candidate left.
        # HEAD then has no proven relationship to it, so this is a best effort --
        # said out loud, because the failure it produces (a 404 on a commit that
        # exists only here) otherwise reads as a permissions problem.
        $result.Repo = $configSlug
        if ($result.Repo) {
            Write-Warning ("This checkout has no GitHub remote, so the guest fallback falls back to repositories.frameworkUrl " +
                           "('$($result.Repo)'). Its HEAD commit may not exist there, in which case the fallback 404s.")
        }
    }
    if (-not $result.FrameworkUrl -and $result.Repo) {
        $result.FrameworkUrl = "https://github.com/$($result.Repo)"
    }

    $head = & git -C $RepoRoot rev-parse HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $head) {
        $result.Ref = ([string]$head).Trim()
    }

    return $result
}

function Test-YurunaFileMatchesHead {
    <#
    .SYNOPSIS
        Does the working-tree copy of a file match the commit the GitHub fallback
        would serve?
    .DESCRIPTION
        The host digests its WORKING TREE copy, but the fallback fetches HEAD from
        GitHub. When the two differ -- an uncommitted edit, or a commit that was
        never pushed -- the fallback can only ever fetch bytes that fail the
        integrity gate. Callers use this to warn the operator up front, so the
        run does not instead surface as an opaque "INTEGRITY MISMATCH" several
        minutes into a guest install.

        Answers $true when the file is unmodified relative to HEAD, and $false
        when it is modified, untracked, or when git could not be consulted at all
        (a non-repository RepoRoot). "Cannot tell" is reported as "will not match"
        so the warning is emitted rather than silently withheld.
    .PARAMETER RepoRoot
        Absolute path to the repository root.
    .PARAMETER RelativePath
        Repository-relative path of the file, e.g. 'guest/x/x.update.sh'.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $status = & git -C $RepoRoot status --porcelain --untracked-files=all -- $RelativePath 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    return [string]::IsNullOrWhiteSpace(($status | Out-String))
}

Export-ModuleMember -Function ConvertTo-GitHubRepoSlug, Get-YurunaCheckoutRemoteUrl, Get-YurunaGitHubSource, Test-YurunaFileMatchesHead
