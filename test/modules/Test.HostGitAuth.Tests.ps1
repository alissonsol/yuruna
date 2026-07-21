<#PSScriptInfo
.VERSION 2026.07.21
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
$invokeGitNetworkText  = (Get-FunctionAst -RootAst $rootAst -FunctionName 'Invoke-GitNetworkCommand').Extent.Text

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
    It 'issues no raw hang-prone `git ... fetch` / `git ... pull`' {
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

Describe 'Get-YurunaGitCredentialArg -- makes GH_TOKEN work for plain git' {
    # Plain git does not read GH_TOKEN (only the gh CLI does), so a host whose
    # only GitHub credential is that variable failed every https fetch/pull/clone.
    # These pin the -c injection that fixes it -- and, critically, that it stays
    # scoped to github.com and never embeds the token value.
    BeforeEach {
        $script:savedToken = $env:GH_TOKEN
    }
    AfterEach {
        if ($null -eq $script:savedToken) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
        else { $env:GH_TOKEN = $script:savedToken }
    }

    It 'returns no args when GH_TOKEN is unset (plain git, unchanged)' {
        Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
        Assert-True (@(Get-YurunaGitCredentialArg).Count -eq 0) 'no token -> no injected credential args'
    }

    It 'injects a github.com-scoped credential helper when GH_TOKEN is set' {
        $env:GH_TOKEN = 'ghp_UNIT_TEST_token'
        $credArgs = @(Get-YurunaGitCredentialArg)
        Assert-True ($credArgs.Count -eq 4) 'two -c pairs (reset + helper)'
        $joined = $credArgs -join ' '
        Assert-True ($joined -match 'credential\.https://github\.com\.helper') 'the helper is SCOPED to https://github.com so the token never reaches another host'
        Assert-True ($joined -notmatch 'ghp_UNIT_TEST_token') 'the token VALUE is never embedded -- the helper reads $GH_TOKEN at run time'
        Assert-True ($joined -match '\$GH_TOKEN') 'the helper references the env var by name for git''s shell to expand'
    }

    It 'actually resolves the token through git''s own credential machinery' {
        # The end-to-end proof: git's `credential fill` for github.com, run with
        # the injected args, must return the token as the password. Guarded so the
        # suite still passes on a box without git on PATH.
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            Write-Warning 'git not on PATH; skipping the credential-fill end-to-end check.'
            return
        }
        $env:GH_TOKEN = 'ghp_UNIT_TEST_token'
        $prevPrompt = $env:GIT_TERMINAL_PROMPT
        $env:GIT_TERMINAL_PROMPT = '0'
        try {
            $credArgs = @(Get-YurunaGitCredentialArg)
            $fill = "protocol=https`nhost=github.com`n`n"
            $out  = ($fill | & git @credArgs credential fill 2>&1 | Out-String)
        } finally {
            if ($null -eq $prevPrompt) { Remove-Item Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue }
            else { $env:GIT_TERMINAL_PROMPT = $prevPrompt }
        }
        Assert-True ($out -match 'username=x-access-token') 'git resolves the x-access-token username through the helper'
        Assert-True ($out -match 'password=ghp_UNIT_TEST_token') 'git resolves the GH_TOKEN value as the password through the helper'
    }
}

Describe 'Get-YurunaGhCliCredentialArg -- makes a gh CLI login work for plain git' {
    # `gh auth login` stores its credential where plain git can't see it (and on
    # Linux git has no default credential store), so a host bootstrapped with
    # `gh repo clone` authenticated the clone and then failed every later
    # fetch/pull. These pin the per-invocation gh helper injection that fixes it.
    It 'returns no args when gh is not on PATH (plain git, unchanged)' {
        Mock -ModuleName Test.HostGit Get-Command { $null } -ParameterFilter { $Name -eq 'gh' }
        Assert-True (@(Get-YurunaGhCliCredentialArg).Count -eq 0) 'no gh -> no injected credential args'
    }
    It 'injects a github.com-scoped gh credential helper when gh is on PATH' {
        Mock -ModuleName Test.HostGit Get-Command { [pscustomobject]@{ Name = 'gh' } } -ParameterFilter { $Name -eq 'gh' }
        $credArgs = @(Get-YurunaGhCliCredentialArg)
        Assert-True ($credArgs.Count -eq 4) 'two -c pairs (reset + helper)'
        $joined = $credArgs -join ' '
        Assert-True ($joined -match 'credential\.https://github\.com\.helper') 'the helper is SCOPED to https://github.com so the login never reaches another host'
        Assert-True ($joined -match '!gh auth git-credential') 'delegates to gh''s non-interactive credential plumbing'
    }
}

Describe 'Get-YurunaGitAuthAttemptList -- one owner of the credential-source order' {
    BeforeEach {
        $script:savedTokenOrder = $env:GH_TOKEN
    }
    AfterEach {
        if ($null -eq $script:savedTokenOrder) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
        else { $env:GH_TOKEN = $script:savedTokenOrder }
    }
    It 'is empty when the host has neither GH_TOKEN nor gh (plain git only)' {
        Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
        Mock -ModuleName Test.HostGit Get-Command { $null } -ParameterFilter { $Name -eq 'gh' }
        Assert-True (@(Get-YurunaGitAuthAttemptList).Count -eq 0) 'no credential source -> no credentialed attempts'
    }
    It 'puts the explicit GH_TOKEN ahead of the ambient gh login' {
        $env:GH_TOKEN = 'ghp_UNIT_TEST_token'
        Mock -ModuleName Test.HostGit Get-Command { [pscustomobject]@{ Name = 'gh' } } -ParameterFilter { $Name -eq 'gh' }
        $attempts = @(Get-YurunaGitAuthAttemptList)
        Assert-True ($attempts.Count -eq 2) 'both sources present -> two credentialed attempts'
        Assert-True (($attempts[0].Args -join ' ') -match '\$GH_TOKEN') 'the explicit token attempt runs first (deliberate operator intent)'
        Assert-True (($attempts[1].Args -join ' ') -match 'gh auth git-credential') 'the gh login attempt runs second'
    }
}

Describe 'Invoke-GitNetworkCommand -- chains the credential sources, plain git last' {
    BeforeEach {
        $script:savedTokenChain = $env:GH_TOKEN
    }
    AfterEach {
        if ($null -eq $script:savedTokenChain) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
        else { $env:GH_TOKEN = $script:savedTokenChain }
    }
    It 'sources the ordered attempts and runs each through the prompt-proof once-runner' {
        Assert-True ($invokeGitNetworkText -match 'Get-YurunaGitAuthAttemptList') 'the ordered credential attempts must be sourced'
        Assert-True ($invokeGitNetworkText -match 'Invoke-GitNetworkCommandOnce') 'each attempt runs through the prompt-proof once-runner'
        Assert-True ($invokeGitNetworkText -match 'Test-GitRemoteAuthFailure') 'a failed attempt must be classified before another source is tried'
    }
    It 'falls through an auth-rejected credentialed attempt to the plain run' {
        $env:GH_TOKEN = 'ghp_UNIT_TEST_token'
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommandOnce {
            if ($GitArgs -contains '-c') { return @{ ExitCode = 128; Output = "fatal: Authentication failed for 'https://github.com/acme/framework.git/'" } }
            return @{ ExitCode = 0; Output = '' }
        }
        Assert-True ((Invoke-GitNetworkCommand -GitArgs @('fetch')).ExitCode -eq 0) 'the plain last-resort run wins after every credentialed attempt is rejected'
    }
    It 'returns a network failure immediately -- more credentials cannot fix an outage' {
        $env:GH_TOKEN = 'ghp_UNIT_TEST_token'
        Mock -ModuleName Test.HostGit Invoke-GitNetworkCommandOnce {
            return @{ ExitCode = 128; Output = "fatal: unable to access 'https://github.com/acme/framework.git/': Could not resolve host: github.com" }
        }
        $r = Invoke-GitNetworkCommand -GitArgs @('fetch')
        Assert-True ($r.ExitCode -eq 128) 'the outage result is surfaced as-is'
        Assert-MockCalled -ModuleName Test.HostGit Invoke-GitNetworkCommandOnce -Exactly -Times 1 -Scope It
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
