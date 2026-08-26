<#PSScriptInfo
.VERSION 2026.08.25
.GUID 421d3153-a504-4156-917e-10ff36bab08d
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

    Also guards how a refused credential is REPORTED. Every check that reaches a
    remote trips over the same credential, so each one that describes it as a
    generic unreachability -- a typo to hunt, a host that might be offline --
    sends its reader after a cause that is not there. These pin the shared
    remedy and the sites that must name it.
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$repoRoot   = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$modulePath = Join-Path $repoRoot 'test/modules/Test.HostGit.psm1'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

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
$script:invokeGitPullText     = (Get-FunctionAst -RootAst $rootAst -FunctionName 'Invoke-GitPull').Extent.Text
$script:updateProjectCloneText = (Get-FunctionAst -RootAst $rootAst -FunctionName 'Update-ProjectClone').Extent.Text
$script:invokeGitNetworkText  = (Get-FunctionAst -RootAst $rootAst -FunctionName 'Invoke-GitNetworkCommand').Extent.Text

}

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
        Assert-True ($script:invokeGitPullText -match 'Invoke-GitNetworkCommand') 'Invoke-GitPull must call Invoke-GitNetworkCommand for network git'
    }
    It 'issues no raw hang-prone `git ... fetch` / `git ... pull`' {
        # The only remaining bare `git` call is the local `config --get remote.origin.url`
        # (no network, no prompt). A raw fetch/pull is the call that hung.
        Assert-True ($script:invokeGitPullText -notmatch 'git\s+-C\s+\$RepoRoot\s+fetch') 'raw `git -C $RepoRoot fetch` must be gone'
        Assert-True ($script:invokeGitPullText -notmatch 'git\s+-C\s+\$RepoRoot\s+pull')  'raw `git -C $RepoRoot pull` must be gone'
    }
    It 'preflights the remote and emits the refresh-access banner on auth failure' {
        Assert-True ($script:invokeGitPullText -match 'ls-remote')                 'a cheap ls-remote preflight must run before the fetch'
        Assert-True ($script:invokeGitPullText -match 'Test-GitRemoteAuthFailure') 'an auth failure must be classified'
        Assert-True ($script:invokeGitPullText -match 'Write-GitAuthRefreshBanner') 'an auth failure must surface the refresh-access banner'
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
        Assert-True ($script:invokeGitNetworkText -match 'Get-YurunaGitAuthAttemptList') 'the ordered credential attempts must be sourced'
        Assert-True ($script:invokeGitNetworkText -match 'Invoke-GitNetworkCommandOnce') 'each attempt runs through the prompt-proof once-runner'
        Assert-True ($script:invokeGitNetworkText -match 'Test-GitRemoteAuthFailure') 'a failed attempt must be classified before another source is tried'
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
        Assert-True ($script:updateProjectCloneText -match 'Invoke-GitNetworkCommand') 'the clone must route through Invoke-GitNetworkCommand'
        Assert-True ($script:updateProjectCloneText -notmatch '&\s+git\s+clone')       'the raw `& git clone` (hang-prone) must be gone'
    }
    It 'preflights the project remote before the wipe and surfaces the refresh-access banner' {
        Assert-True ($script:updateProjectCloneText -match 'ls-remote')                  'the project remote must be preflighted before wiping the clone'
        Assert-True ($script:updateProjectCloneText -match 'Test-GitRemoteAuthFailure')  'a project-clone auth failure must be classified'
        Assert-True ($script:updateProjectCloneText -match 'Write-GitAuthRefreshBanner') 'a project-clone auth failure must surface the refresh-access banner'
    }
}

Describe 'Get-GitFirstOutputLine -- the one sentence worth quoting back' {
    It 'returns the first non-blank line, trimmed' {
        $out = "`n  remote: Invalid username or token.`nfatal: Authentication failed for 'https://github.com/acme/p/'"
        Assert-StringEqual 'remote: Invalid username or token.' (Get-GitFirstOutputLine -Output $out) `
            'git leads with the human-readable cause and follows with the fatal: restatement of it'
    }
    It 'returns an empty string for empty or whitespace output' {
        Assert-StringEqual '' (Get-GitFirstOutputLine -Output '')      'no output means nothing to quote'
        Assert-StringEqual '' (Get-GitFirstOutputLine -Output "  `n ") 'whitespace-only output means nothing to quote'
    }
}

Describe 'Get-GitAuthRefreshRemedy -- one remedy list, every reporting site' {
    # An auth-shaped failure has the same fix wherever it is noticed. Reports that
    # word it differently read like different problems, and a host that grows a new
    # credential source has to be updated in each place it is described.
    It 'names every credential source the runner actually chains' {
        $r = @(Get-GitAuthRefreshRemedy)
        Assert-True ($r.Count -ge 3)              'the list covers gh, GH_TOKEN, and the credential helper'
        Assert-True (($r -join ' ') -match 'gh auth login') 'the gh CLI login is offered'
        Assert-True (($r -join ' ') -match 'GH_TOKEN')      'the environment token is offered'
    }
    It 'is what the refresh banner renders, so the two cannot drift' {
        $banner = (Write-GitAuthRefreshBanner -RemoteUrl 'https://github.com/acme/p' `
                       -GitOutput 'remote: Invalid username or token.' 3>&1 | Out-String)
        foreach ($option in @(Get-GitAuthRefreshRemedy)) {
            Assert-True ($banner -match [regex]::Escape($option)) "the banner renders the shared remedy: $option"
        }
        Assert-True ($banner -match 'git said: remote: Invalid username or token\.') 'the banner quotes what git said'
    }
}

Describe 'Reporting an auth-shaped failure as one -- not as "offline, or maybe credentials"' {
    # A refused credential is not an ambient condition to wait out, and it takes
    # down every other remote-touching check in the same report. Each site that
    # notices one must say so, and say what to do, or the reader is left picking
    # between causes that call for opposite responses.
    BeforeAll {
        $script:testConfigText = Get-Content -Raw (Join-Path $repoRoot 'test/Test-Config.ps1')
        $validatorAst  = Get-ModuleAst -Path (Join-Path $repoRoot 'test/modules/Test.ConfigValidator.psm1')
        $script:freshnessText = (Get-FunctionAst -RootAst $validatorAst -FunctionName 'Test-RepoFreshness').Extent.Text
        # Test-RepoFreshness reports through Test.Output and returns nothing, so the
        # message IS the behavior: load the reporter and give the function a
        # directory that looks like a working tree for it to check.
        Import-Module (Join-Path $repoRoot 'test/modules/Test.Output.psm1')          -Force -Global -DisableNameChecking
        Import-Module (Join-Path $repoRoot 'test/modules/Test.ConfigValidator.psm1') -Force -Global -DisableNameChecking
        Initialize-OutputState
        $script:fakeRepo = New-YurunaTestTempDir -Prefix 'freshness'
        New-Item -ItemType Directory -Path (Join-Path $script:fakeRepo '.git') -Force | Out-Null

        function Get-FreshnessWarning {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'GitOutput',
                Justification = 'Consumed inside the .GetNewClosure() mock body below, which the analyzer does not follow.')]
            [CmdletBinding()]
            [OutputType([string])]
            param([Parameter(Mandatory)][string]$GitOutput)
            $captured = [System.Collections.Generic.List[string]]::new()
            # .GetNewClosure() binds $GitOutput into the mock body here and now.
            # A mock scriptblock is invoked later, from inside the mocked module's
            # session state, so a bare reference to a caller variable is a
            # different question than it looks -- and one that silently answers
            # $null would make every case in this Describe assert the same thing.
            $fetchResult = { return @{ ExitCode = 128; Output = $GitOutput } }.GetNewClosure()
            Mock -ModuleName Test.ConfigValidator Invoke-GitNetworkCommand $fetchResult
            Mock -ModuleName Test.ConfigValidator Write-Warn { param($Message) $captured.Add("$Message") }
            Test-RepoFreshness -Label 'project' -Path $script:fakeRepo
            return ($captured -join "`n")
        }
    }
    AfterAll {
        if ($script:fakeRepo) { Remove-YurunaTestTempDir -Path $script:fakeRepo }
    }
    It 'the projectUrl probe classifies before it blames the URL' {
        Assert-True ($script:testConfigText -match 'Test-GitRemoteAuthFailure -Output \$ls\.Output') `
            'a refused credential must be told apart from a typo / missing repo'
        Assert-True ($script:testConfigText -match 'Get-GitAuthRefreshRemedy') `
            'the remedy must ride INSIDE the FAIL -- the gate re-emits only the FAILURES block'
    }
    It 'the staleness check classifies its fetch failure' {
        Assert-True ($script:freshnessText -match 'Test-GitRemoteAuthFailure') `
            'a refused fetch must be told apart from an offline host'
        Assert-True ($script:freshnessText -match 'Get-GitAuthRefreshRemedy') `
            'the same remedy must reach a reader who only sees the staleness warning'
        Assert-True ($script:freshnessText -notmatch 'offline, or the remote needs credentials') `
            'an either/or wording leaves the reader picking between causes that call for opposite responses'
    }
    It 'names the credential, the blast radius, and the fix when the fetch is refused' {
        $warning = Get-FreshnessWarning -GitOutput "remote: Invalid username or token. Password authentication is not supported for Git operations.`nfatal: Authentication failed for 'https://github.com/acme/p/'"
        Assert-Match 'REFUSED'          $warning 'the reader must not be left wondering whether the host is merely offline'
        Assert-Match 'gh auth login'    $warning 'the fix belongs where the problem is reported'
        Assert-Match 'every other check' $warning 'one dead credential explains every other remote failure in the same report'
        Assert-Match 'git said: remote: Invalid username or token' $warning 'quoting git is what proves the diagnosis'
    }
    It 'still reports an unreachable remote as unreachable' {
        $warning = Get-FreshnessWarning -GitOutput "fatal: unable to access 'https://github.com/acme/p/': Could not resolve host: github.com"
        Assert-Match 'offline'             $warning 'an outage is an outage'
        Assert-True  ($warning -notmatch 'gh auth login') 'refreshing a login cannot fix a resolver failure, so do not suggest it'
    }
}
