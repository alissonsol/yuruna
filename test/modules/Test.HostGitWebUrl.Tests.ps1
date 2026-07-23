<#PSScriptInfo
.VERSION 2026.07.22
.GUID 4292cccb-faec-453f-afcd-02b6a9bee927
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test hostgit weburl pester
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
    Guards Resolve-GitRepositoryWebUrl (Test.HostGit.psm1): every valid clone
    source -- https, ssh://, scp-like, or a local clone path -- resolves to the
    browser-routable https URL the status page and pool dashboard need for
    their <repoUrl>/commit/<sha> deep-links, and non-resolvable inputs return
    $null instead of a broken link base.
.DESCRIPTION
    The gitCommits[].repoUrl field is only linkable when it is http(s); a host
    whose repositories.projectUrl is a local clone path (or an ssh remote)
    otherwise renders its project commit as plain text on both the host status
    page and the pool dashboard's Commit column. Behavioral tests cover the
    string rewrites plus the local-path origin walk (real temp git repos) and
    the origin-cycle hop cap. Runs under Pester 4.10.1.
#>

$here       = Split-Path -Parent $PSCommandPath
$repoRoot   = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$modulePath = Join-Path $repoRoot 'test/modules/Test.HostGit.psm1'

function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ($Expected -ne $Actual) { throw "Expected '$Expected' but got '$Actual'. $Because" }
}
function Assert-Null {
    param($Actual, [string]$Because = '')
    if ($null -ne $Actual) { throw "Expected `$null but got '$Actual'. $Because" }
}

Import-Module $modulePath -Force

# Temp repos for the local-path walk. Layout:
#   webRepo   -- plain repo whose origin is an https URL (the chain's end)
#   midRepo   -- origin points at webRepo's path (one local hop)
#   loopRepo  -- origin points at itself (self-cycle; must not spin)
# git config edits are local-only (no network); repos need no commits because
# only remote.origin.url is read.
$script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-weburl-tests-" + [guid]::NewGuid().ToString('N'))
$webRepo  = Join-Path $script:tmpRoot 'web-origin-repo'
$midRepo  = Join-Path $script:tmpRoot 'mid-hop-repo'
$loopRepo = Join-Path $script:tmpRoot 'self-loop-repo'
foreach ($r in @($webRepo, $midRepo, $loopRepo)) {
    $null = New-Item -ItemType Directory -Path $r -Force
    & git -C $r init --quiet 2>$null
}
& git -C $webRepo  remote add origin 'https://github.com/example/project-under-test.git' 2>$null
& git -C $midRepo  remote add origin $webRepo 2>$null
& git -C $loopRepo remote add origin $loopRepo 2>$null

Describe 'Resolve-GitRepositoryWebUrl -- direct URL forms' {
    It 'passes a plain https URL through unchanged' {
        Assert-Equal 'https://github.com/acme/project' `
            (Resolve-GitRepositoryWebUrl -Url 'https://github.com/acme/project')
    }
    It 'strips a trailing .git and trailing slash from an https URL' {
        Assert-Equal 'https://github.com/acme/project' `
            (Resolve-GitRepositoryWebUrl -Url 'https://github.com/acme/project.git/')
    }
    It 'strips embedded userinfo credentials (repoUrl lands on unauthenticated status surfaces)' {
        Assert-Equal 'https://github.com/acme/project' `
            (Resolve-GitRepositoryWebUrl -Url 'https://x-access-token:ghp_secret@github.com/acme/project.git')
    }
    It 'rewrites an scp-like ssh remote to https' {
        Assert-Equal 'https://github.com/acme/project' `
            (Resolve-GitRepositoryWebUrl -Url 'git@github.com:acme/project.git')
    }
    It 'rewrites an ssh:// remote (with user and port) to https' {
        Assert-Equal 'https://github.com/acme/project' `
            (Resolve-GitRepositoryWebUrl -Url 'ssh://git@github.com:22/acme/project.git')
    }
    It 'returns $null for empty and whitespace input' {
        Assert-Null (Resolve-GitRepositoryWebUrl -Url '')
        Assert-Null (Resolve-GitRepositoryWebUrl -Url '   ')
    }
    It 'returns $null for a nonexistent local path (never a broken link base)' {
        Assert-Null (Resolve-GitRepositoryWebUrl -Url 'C:/no/such/dir/anywhere-at-all')
    }
    It 'does not mistake a Windows drive path for an scp-like host:path remote' {
        # C:/... must fall through to the local-path branch (and $null when not
        # a repo), never rewrite to https://C/...
        $r = Resolve-GitRepositoryWebUrl -Url 'Q:/definitely/not/a/repo'
        Assert-Null $r 'drive-letter path must not match the scp-like form'
    }
}

Describe 'Resolve-GitRepositoryWebUrl -- local clone-path origin walk' {
    It 'resolves a local repo path to its https origin' {
        Assert-Equal 'https://github.com/example/project-under-test' `
            (Resolve-GitRepositoryWebUrl -Url $webRepo)
    }
    It 'follows a local-path origin chain (clone of a clone) to the web remote' {
        Assert-Equal 'https://github.com/example/project-under-test' `
            (Resolve-GitRepositoryWebUrl -Url $midRepo)
    }
    It 'returns $null for a local repo with no origin remote' {
        $bare = Join-Path $script:tmpRoot 'no-origin-repo'
        $null = New-Item -ItemType Directory -Path $bare -Force
        & git -C $bare init --quiet 2>$null
        Assert-Null (Resolve-GitRepositoryWebUrl -Url $bare)
    }
    It 'terminates on an origin self-cycle instead of spinning' {
        Assert-Null (Resolve-GitRepositoryWebUrl -Url $loopRepo)
    }
    It 'returns $null for a plain directory that is not a git repo' {
        $plain = Join-Path $script:tmpRoot 'plain-dir'
        $null = New-Item -ItemType Directory -Path $plain -Force
        Assert-Null (Resolve-GitRepositoryWebUrl -Url $plain)
    }
}

# Pester 4 executes Describe blocks inline, so this runs after all tests.
if ($script:tmpRoot -and (Test-Path -LiteralPath $script:tmpRoot)) {
    Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
