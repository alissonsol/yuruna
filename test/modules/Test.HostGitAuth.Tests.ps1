<#PSScriptInfo
.VERSION 2026.07.14
.GUID 4221fb98-52ab-4cf1-07e9-7351ddd76acd
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test hostgit auth pester
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
    Guards the credential-prompt-proofing added to Test.HostGit.psm1's git-pull
    path: Test-GitRemoteAuthFailure recognizes a stale/missing GitHub login and
    NOT a mere network outage, and Invoke-GitPull never reaches for a raw,
    hang-prone `git fetch`/`git pull` -- it routes network git through the
    prompt-proof helper and fails fast with the refresh-access banner.
.DESCRIPTION
    A missing/expired credential made an unattended runner block forever inside
    `git fetch` (git waiting on an interactive username prompt). The behavioral
    tests assert the auth classifier; the AST/source guards assert the pull path
    stays prompt-proof. Runs under Pester 4.10.1 (script-scoped throw helper).
#>

$here       = Split-Path -Parent $PSCommandPath
$repoRoot   = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$modulePath = Join-Path $repoRoot 'test/modules/Test.HostGit.psm1'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

Import-Module $modulePath -Force

function Get-ModuleAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.ScriptBlockAst])]
    param([Parameter(Mandatory)][string]$Path)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in ${Path}: $($errs[0].Message)" }
    return $ast
}

function Get-FunctionAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.FunctionDefinitionAst])]
    param([Parameter(Mandatory)]$RootAst, [Parameter(Mandatory)][string]$FunctionName)
    $f = $RootAst.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $FunctionName
    }, $true) | Select-Object -First 1
    if (-not $f) { throw "Function '$FunctionName' not found." }
    return $f
}

$rootAst = Get-ModuleAst -Path $modulePath

# The source text each guard matches against is extracted at FILE scope, not in
# the Describe bodies: a Describe body is executed during discovery and its
# variables are discarded before any It runs, so an in-Describe $fnText would
# reach the assertions as $null -- and a $null -notmatch guard passes vacuously,
# silently un-testing the pull path. File-scope variables survive into the run
# phase. The two functions get distinct names so neither guard can read the
# other's source.
$invokeGitPullText     = (Get-FunctionAst -RootAst $rootAst -FunctionName 'Invoke-GitPull').Extent.Text
$updateProjectCloneText = (Get-FunctionAst -RootAst $rootAst -FunctionName 'Update-ProjectClone').Extent.Text

Describe 'Test-GitRemoteAuthFailure -- flags a credential problem, not a network outage' {
    It 'flags a missing credential (GIT_TERMINAL_PROMPT=0 -> terminal prompts disabled)' {
        Assert-True (Test-GitRemoteAuthFailure -Output "fatal: could not read Username for 'https://github.com': terminal prompts disabled")
    }
    It 'flags an expired/wrong credential (Authentication failed)' {
        Assert-True (Test-GitRemoteAuthFailure -Output "remote: Invalid username or password.`nfatal: Authentication failed for 'https://github.com/acme/framework.git/'")
    }
    It 'flags a private repo the identity can no longer see (Repository not found)' {
        Assert-True (Test-GitRemoteAuthFailure -Output "remote: Repository not found.`nfatal: repository 'https://github.com/acme/framework.git/' not found")
    }
    It 'flags an expired PAT / unauthorized SSO (HTTPS 403)' {
        Assert-True (Test-GitRemoteAuthFailure -Output 'fatal: unable to access ...: The requested URL returned error: 403')
    }
    It 'flags an SSH key that is not loaded (publickey)' {
        Assert-True (Test-GitRemoteAuthFailure -Output 'git@github.com: Permission denied (publickey).')
    }
    It 'does NOT flag a DNS/network outage' {
        Assert-True (-not (Test-GitRemoteAuthFailure -Output "fatal: unable to access 'https://github.com/acme/framework.git/': Could not resolve host: github.com"))
    }
    It 'does NOT flag a clean up-to-date fetch (empty output)' {
        Assert-True (-not (Test-GitRemoteAuthFailure -Output ''))
        Assert-True (-not (Test-GitRemoteAuthFailure -Output $null))
    }
    It 'does NOT flag a local branch divergence' {
        Assert-True (-not (Test-GitRemoteAuthFailure -Output 'fatal: Not possible to fast-forward, aborting.'))
    }
}

Describe 'Invoke-GitPull -- the network git path stays prompt-proof' {
    It 'routes network git through the prompt-proof helper' {
        Assert-True ($invokeGitPullText -match 'Invoke-GitNetworkCommand') 'Invoke-GitPull must call Invoke-GitNetworkCommand for network git'
    }
    It 'no longer issues a raw hang-prone `git ... fetch` / `git ... pull`' {
        # The only remaining bare `git` call is the local `config --get remote.origin.url`
        # (no network, no prompt). A raw fetch/pull is the call that hung.
        Assert-True ($invokeGitPullText -notmatch 'git\s+-C\s+\$RepoRoot\s+fetch') 'raw `git -C $RepoRoot fetch` must be gone'
        Assert-True ($invokeGitPullText -notmatch 'git\s+-C\s+\$RepoRoot\s+pull')  'raw `git -C $RepoRoot pull` must be gone'
    }
    It 'preflights the remote and emits the refresh-access banner on auth failure' {
        Assert-True ($invokeGitPullText -match 'ls-remote')                 'a cheap ls-remote preflight must run before the fetch'
        Assert-True ($invokeGitPullText -match 'Test-GitRemoteAuthFailure') 'an auth failure must be classified'
        Assert-True ($invokeGitPullText -match 'Write-GitAuthRefreshBanner') 'an auth failure must surface the refresh-access banner'
    }
}

Describe 'Update-ProjectClone -- the project clone is prompt-proof too' {
    It 'clones through the prompt-proof helper, not a raw `& git clone`' {
        Assert-True ($updateProjectCloneText -match 'Invoke-GitNetworkCommand') 'the clone must route through Invoke-GitNetworkCommand'
        Assert-True ($updateProjectCloneText -notmatch '&\s+git\s+clone')       'the raw `& git clone` (hang-prone) must be gone'
    }
    It 'preflights the project remote before the wipe and surfaces the refresh-access banner' {
        Assert-True ($updateProjectCloneText -match 'ls-remote')                  'the project remote must be preflighted before wiping the clone'
        Assert-True ($updateProjectCloneText -match 'Test-GitRemoteAuthFailure')  'a project-clone auth failure must be classified'
        Assert-True ($updateProjectCloneText -match 'Write-GitAuthRefreshBanner') 'a project-clone auth failure must surface the refresh-access banner'
    }
}
