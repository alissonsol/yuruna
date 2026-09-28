<#PSScriptInfo
.VERSION 2026.09.27
.GUID 425ba29c-8d06-4e43-bef3-ad4d3ee670fd
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test fetch-execute integrity pester
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
    Pester guard on the guest fetch-and-execute integrity gate: the host must
    hand each guest a sha256 digest of the working-tree script it is about to
    fetch, and the guest must refuse bytes that do not match.
.DESCRIPTION
    Two halves of one control:
      * Host side -- Get-FetchExecutionContext (Test.SequenceHandler.psm1) must
        bind the exact command and full working-tree digests in a private
        context, strip a ?query for path hashing, and fail before dispatch for
        traversal, absolute, or missing paths. The launch prefix is 16 chars.
      * Guest side -- verify_sha256 (automation/fetch-and-execute.sh) must return
        0 on a match, 1 on a mismatch, 0 on an empty digest without the require
        flag (rollout-compat), and 1 on an empty digest WITH the require flag.
    The host half extracts the real function via the parser and exercises it (no
    module import, so no host I/O deps -- the same discipline as the sibling
    sequence tests). The guest half extracts the real shell function and runs it
    under bash; it is skipped (passes) where bash is unavailable.
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking
$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$modPath  = Join-Path $here 'Test.SequenceHandler.psm1'
$script:faePath  = Join-Path $repoRoot 'automation/fetch-and-execute.sh'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

function Get-GitHubSourceFixture {
    <#
        A throwaway checkout with its own remote and its own test.config.yml, so
        the two sources of "which repository is this" can be set independently.
        Built inside a function because a Describe body runs at discovery time
        and its variables are not in scope when the It bodies execute.
        -RemoteUrl '' leaves the checkout with no remote at all.
    #>
    param([string]$RemoteUrl, [string]$FrameworkUrl)
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-ghsrc-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'test') | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'test/test.config.yml') -Value "repositories:`n  frameworkUrl: $FrameworkUrl`n  ghToken: `"`"`n"
    Set-Content -LiteralPath (Join-Path $dir 'seed.txt') -Value 'seed'
    & git -C $dir init --quiet 2>&1 | Out-Null
    if ($RemoteUrl) { & git -C $dir remote add origin $RemoteUrl 2>&1 | Out-Null }
    & git -C $dir add -A 2>&1 | Out-Null
    & git -C $dir -c user.email='t@example.invalid' -c user.name='t' commit -qm 'seed' 2>&1 | Out-Null
    return $dir
}

# Exercise the production context builder without importing host I/O modules.
Import-Module (Join-Path $repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $repoRoot 'automation/Yuruna.GitHubSource.psm1') -Force -DisableNameChecking
$modAst = [System.Management.Automation.Language.Parser]::ParseFile($modPath, [ref]$null, [ref]$null)
foreach ($name in @('Get-FetchExecutionCommand', 'Get-FetchExecutionContext')) {
    $fnAst = $modAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $fnAst) { throw "Missing function: $name" }
    . ([scriptblock]::Create($fnAst.Extent.Text))
}
$script:NonzeroScriptExitSentinel = 'NONZERO SCRIPT EXIT:'
$sample = 'guest/ubuntu.server.26/ubuntu.server.26.update.sh'
$script:sampleHash = (Get-FileHash -LiteralPath (Join-Path $repoRoot $sample) -Algorithm SHA256).Hash.ToLowerInvariant()
$script:retryHash = (Get-FileHash -LiteralPath (Join-Path $repoRoot 'automation/yuruna-retry.sh') -Algorithm SHA256).Hash.ToLowerInvariant()
$script:fetchContext = @{ Step = @{}; RepoRoot = $repoRoot; StepInvocationId = 'step-123'; SequenceInvocationId = 'sequence-456' }
}

Describe 'Get-FetchExecutionContext (host-side integrity binding)' {
    It 'uses an exact 16-character launch prefix and full SHA-256 digests' {
        $result = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine "/usr/local/lib/yuruna/fetch-and-execute.sh $sample" -WarningAction SilentlyContinue
        $result.Prefix.Length | Should -Be 16
        $result.Prefix | Should -Match '^yfe [0-9a-f]{11} $'
        $result.Launch | Should -BeExactly ($result.Prefix + "bash -c '/usr/local/lib/yuruna/fetch-and-execute.sh $sample'")
        $result.Fields.EXEC_REQUIRE_SHA256 | Should -BeExactly '1'
        $result.Fields.E_SHA | Should -BeExactly $script:sampleHash
        $result.Fields.E_RETRY_SHA | Should -BeExactly $script:retryHash
        $result.Fields.E_FB_REF | Should -Match '^[0-9a-f]{40}$'
        $result.Fields.E_SI | Should -BeExactly 'step-123'
        $result.Fields.E_QI | Should -BeExactly 'sequence-456'
        $result.Bytes.Length | Should -BeLessOrEqual 4096
        $result.Command | Should -Not -Match 'NONZERO SCRIPT EXIT:'
    }
    It 'strips a query before hashing but binds the complete original command' {
        $command = "fetch-and-execute.sh $sample" + '?nocache=9'
        $result = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine $command -WarningAction SilentlyContinue
        $result.Fields.rel | Should -BeExactly $sample
        $result.Fields.E_SHA | Should -BeExactly $script:sampleHash
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try { $digest = [BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($command))).Replace('-', '').ToLowerInvariant() }
        finally { $sha256.Dispose() }
        $result.Fields.cmd_sha | Should -BeExactly $digest
    }
    It 'fails before dispatch on traversal, absolute, missing, or unserved paths' {
        foreach ($command in @(
            'fetch-and-execute.sh ../../etc/passwd',
            'fetch-and-execute.sh /etc/passwd',
            'fetch-and-execute.sh guest/does-not-exist.sh'
        )) {
            { Get-FetchExecutionContext -Context $script:fetchContext -CommandLine $command -WarningAction SilentlyContinue } | Should -Throw
        }
        $missingRoot = @{ Step = @{}; RepoRoot = ''; StepInvocationId = 'x'; SequenceInvocationId = 'y' }
        { Get-FetchExecutionContext -Context $missingRoot -CommandLine "fetch-and-execute.sh $sample" } | Should -Throw
    }
    It 'preserves observations but has no fabricated integrity fields for non-fetch commands' {
        $result = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine ('printf caf' + [char]0x00e9)
        $result.Fields.E_SI | Should -BeExactly 'step-123'
        $result.Fields.Contains('E_SHA') | Should -BeFalse
        $result.Fields.Contains('EXEC_REQUIRE_SHA256') | Should -BeFalse
    }
    It 'keeps the configured token out of the context and launch' {
        $result = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine "fetch-and-execute.sh $sample" -WarningAction SilentlyContinue
        $configured = (Get-YurunaGitHubSource -RepoRoot $repoRoot).Token
        if ($configured) {
            $result.Command | Should -Not -Match ([regex]::Escape($configured))
            [Text.Encoding]::UTF8.GetString($result.Bytes) | Should -Not -Match ([regex]::Escape($configured))
        }
    }
    It 'preserves the sensitive-step profile opt-out and full invocation IDs' {
        $context = @{ Step = @{ sensitive = $true }; RepoRoot = $repoRoot; StepInvocationId = 'step-sensitive-123'; SequenceInvocationId = 'sequence-sensitive-456' }
        $result = Get-FetchExecutionContext -Context $context -CommandLine 'true'
        $result.Fields.EXEC_PROFILE | Should -BeExactly '0'
        $result.Fields.EXEC_KEEP_PROFILE | Should -BeExactly '0'
        $result.Fields.E_SI | Should -BeExactly 'step-sensitive-123'
        $result.Fields.E_QI | Should -BeExactly 'sequence-sensitive-456'
    }
    It 'reserves a distinct context identifier for each explicit retry' {
        $first = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine 'true'
        $retry = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine 'true'
        $first.Id | Should -Not -Be $retry.Id
        $first.Fields.cmd_sha | Should -BeExactly $retry.Fields.cmd_sha
        $first.Launch | Should -Not -Be $retry.Launch
    }
    It 'requires the served retry library before dispatch' {
        $path = Join-Path $TestDrive 'guest/payload.sh'
        $null = New-Item -ItemType Directory -Path (Split-Path $path) -Force
        [IO.File]::WriteAllText($path, 'true')
        $context = @{ Step = @{}; RepoRoot = $TestDrive; StepInvocationId = 'step'; SequenceInvocationId = 'sequence' }
        { Get-FetchExecutionContext -Context $context -CommandLine 'fetch-and-execute.sh guest/payload.sh' } | Should -Throw '*YFE_RETRY_LIB_MISSING*'
    }
    It 'binds the transferred base64 bytes, count, and SHA-256 to one preparation' {
        $result = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine 'printf ready'
        $result.Preparation -match "^printf '%s' '([A-Za-z0-9+/=]+)' \| yfe --prepare ([0-9a-f]{11}) ([0-9]+) ([0-9a-f]{64})$" | Should -BeTrue
        $encoded = $Matches[1]; $id = $Matches[2]; $count = [int]$Matches[3]; $digest = $Matches[4]
        $decoded = [Convert]::FromBase64String($encoded)
        $decoded.Length | Should -Be $count
        $id | Should -BeExactly $result.Id
        [Convert]::ToBase64String($decoded) | Should -BeExactly ([Convert]::ToBase64String($result.Bytes))
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try { $actual = [BitConverter]::ToString($sha256.ComputeHash($decoded)).Replace('-', '').ToLowerInvariant() }
        finally { $sha256.Dispose() }
        $actual | Should -BeExactly $digest
    }
    It 'keeps UTF-8 command binding culture independent and the context BOM-free' {
        $previous = [Threading.Thread]::CurrentThread.CurrentCulture
        try {
            [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('tr-TR')
            $command = 'printf ' + [char]0x03bb
            $result = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine $command
            $sha256 = [Security.Cryptography.SHA256]::Create()
            try { $expected = [BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($command))).Replace('-', '').ToLowerInvariant() }
            finally { $sha256.Dispose() }
            $result.Fields.cmd_sha | Should -BeExactly $expected
            $result.Bytes[0] | Should -Be ([byte][char]'Y')
            $result.Prefix.Length | Should -Be 16
        } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $previous }
    }
    It 'gives all three supplied commands the expected compact launch lengths' {
        $examples = @(
            @{ path = $sample; length = 118 },
            @{ path = 'guest/ubuntu.server.26/ubuntu.server.26.k8s.sh'; length = 115 },
            @{ path = 'project/example/website/test/ubuntu.server.26/ubuntu.server.26.workload.k8s.website.sh'; length = 155 }
        )
        $fixtureRoot = Join-Path $TestDrive 'compact-launch'
        $retry = Join-Path $fixtureRoot 'automation/yuruna-retry.sh'
        $null = New-Item -ItemType Directory -Path (Split-Path $retry) -Force
        Copy-Item -LiteralPath (Join-Path $repoRoot 'automation/yuruna-retry.sh') -Destination $retry
        $context = @{ Step = @{}; RepoRoot = $fixtureRoot; StepInvocationId = 'step'; SequenceInvocationId = 'sequence' }
        foreach ($example in $examples) {
            # Launch length depends on the served path. An isolated payload
            # makes the project case independent of a test-cycle checkout.
            $payload = Join-Path $fixtureRoot $example.path
            $null = New-Item -ItemType Directory -Path (Split-Path $payload) -Force
            [IO.File]::WriteAllText($payload, "printf '%s' 'fixture payload'`n", [Text.UTF8Encoding]::new($false))
            $result = Get-FetchExecutionContext -Context $context -CommandLine "/usr/local/lib/yuruna/fetch-and-execute.sh $($example.path)" -WarningAction SilentlyContinue
            $result.Launch.Length | Should -Be $example.length
            $result.Prefix.Length | Should -Be 16
            $result.Fields.E_SHA | Should -BeExactly (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant()
            Remove-Item -LiteralPath $payload
            { Get-FetchExecutionContext -Context $context -CommandLine "fetch-and-execute.sh $($example.path)" } | Should -Throw '*YFE_PAYLOAD_MISSING*'
        }
    }
    It 'executes the host-built preparation and launch without changing Unicode or shell quoting' {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $command = "printf '%s|' `"it's`"; printf '%s' 'caf$([char]0x00e9)'"
        $result = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine $command
        $driver = @'
set -e
export HOME=$(mktemp -d)
trap 'rm -rf -- "$HOME"' EXIT
yfe() { bash automation/yuruna-fetch-context.sh "$@"; }
'@ + "`n$($result.Command)"
        $output = ($driver | & $bash.Source -s | Out-String).Trim()
        $LASTEXITCODE | Should -Be 0
        $output | Should -BeExactly ("it's|caf" + [char]0x00e9)
    }
    It 'keeps the private context mask out of the launched guest command' {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        foreach ($mask in @('0022', '0027')) {
            $result = Get-FetchExecutionContext -Context $script:fetchContext -CommandLine 'umask'
            $driver = @'
set -e
export HOME=$(mktemp -d)
trap 'rm -rf -- "$HOME"' EXIT
yfe() { bash automation/yuruna-fetch-context.sh "$@"; }
'@ + "`numask $mask`n$($result.Command)"
            $output = ($driver | & $bash.Source -s | Out-String).Trim()
            $LASTEXITCODE | Should -Be 0
            $output | Should -BeExactly $mask
        }
    }
}

Describe 'Fetch context guest seeding' {
    It 'embeds the exact launcher bytes in the shared seed builder' {
        $scripts = Get-YurunaGuestScriptBase64 -RepoRoot $repoRoot
        $actual = [Convert]::FromBase64String($scripts.FetchContext)
        $expected = [IO.File]::ReadAllBytes((Join-Path $repoRoot 'automation/yuruna-fetch-context.sh'))
        [Convert]::ToBase64String($actual) | Should -BeExactly ([Convert]::ToBase64String($expected))
    }

    It 'installs the launcher in both shared Linux guest bases' {
        foreach ($name in @('ubuntu.server.base.user-data', 'amazon.linux.2023.base.user-data')) {
            $seed = [IO.File]::ReadAllText((Join-Path $repoRoot "host/vmconfig/$name"))
            $seed | Should -Match '/usr/local/bin/yfe'
            $seed | Should -Match 'YURUNA_FETCH_CONTEXT_BASE64_PLACEHOLDER'
        }
    }
}

Describe 'Get-YurunaGitHubSource / ConvertTo-GitHubRepoSlug' {
    It 'reduces every remote-URL shape to owner/repo' {
        Assert-StringEqual -Actual (ConvertTo-GitHubRepoSlug 'https://github.com/o/r') -Expected 'o/r'
        Assert-StringEqual -Actual (ConvertTo-GitHubRepoSlug 'https://github.com/o/r.git') -Expected 'o/r'
        Assert-StringEqual -Actual (ConvertTo-GitHubRepoSlug 'git@github.com:o/r.git') -Expected 'o/r'
        Assert-StringEqual -Actual (ConvertTo-GitHubRepoSlug 'ssh://git@github.com/o/r') -Expected 'o/r'
    }
    It 'returns empty for a non-GitHub URL, so no fallback is attempted' {
        Assert-StringEqual -Actual (ConvertTo-GitHubRepoSlug 'https://gitlab.com/o/r') -Expected ''
        Assert-StringEqual -Actual (ConvertTo-GitHubRepoSlug '') -Expected ''
    }
    It 'resolves this repo to a slug and a 40-char commit' {
        $s = Get-YurunaGitHubSource -RepoRoot $repoRoot
        Assert-True ($s.Repo -match '^[^/]+/[^/]+$') "repo slug shape, got '$($s.Repo)'"
        Assert-True ($s.Ref  -match '^[0-9a-f]{40}$') "commit sha shape, got '$($s.Ref)'"
    }

    # Repo and Ref address ONE blob on raw.githubusercontent.com. Ref is always
    # this checkout's HEAD, so a slug taken from anywhere else builds a URL for a
    # commit that repository does not contain -- a 404 no token can open, and one
    # that reads as a permissions problem rather than the mismatch it is.
    It 'takes the slug from the checkout, not from a frameworkUrl naming another repo' {
        $dir = Get-GitHubSourceFixture -RemoteUrl 'https://github.com/owner/checkout-repo.git' `
                                       -FrameworkUrl 'https://github.com/owner/configured-repo'
        try {
            $s = Get-YurunaGitHubSource -RepoRoot $dir -WarningAction SilentlyContinue
            Assert-StringEqual -Actual $s.Repo -Expected 'owner/checkout-repo' -Because 'the slug must name the repository the commit came from'
            Assert-StringEqual -Actual $s.Ref -Expected (& git -C $dir rev-parse HEAD).Trim() -Because 'the ref is still this checkout HEAD'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    It 'reports the disagreement instead of silently preferring one side' {
        $dir = Get-GitHubSourceFixture -RemoteUrl 'https://github.com/owner/checkout-repo.git' `
                                       -FrameworkUrl 'https://github.com/owner/configured-repo'
        try {
            $w = @()
            $null = Get-YurunaGitHubSource -RepoRoot $dir -WarningVariable w -WarningAction SilentlyContinue
            Assert-True ($w.Count -gt 0) 'a repo mismatch must be reported'
            Assert-True ("$w" -match 'checkout-repo')   'the warning names the checkout repository'
            Assert-True ("$w" -match 'configured-repo') 'the warning names the configured repository'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    It 'stays quiet when the checkout and the configured URL agree' {
        $dir = Get-GitHubSourceFixture -RemoteUrl 'https://github.com/owner/same-repo.git' `
                                       -FrameworkUrl 'https://github.com/owner/same-repo'
        try {
            $w = @()
            $s = Get-YurunaGitHubSource -RepoRoot $dir -WarningVariable w -WarningAction SilentlyContinue
            Assert-StringEqual -Actual $s.Repo -Expected 'owner/same-repo' -Because 'the agreed slug is used'
            Assert-StringEqual -Actual $w.Count -Expected 0 -Because 'agreement is not worth a warning'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    # A checkout with no remote cannot prove where HEAD lives, so the configured
    # URL is the only candidate left. It is still offered -- a fallback that might
    # work beats none -- but not silently, because the 404 it can produce looks
    # exactly like a missing token.
    It 'falls back to frameworkUrl only when the checkout has no remote, and says so' {
        $dir = Get-GitHubSourceFixture -RemoteUrl '' -FrameworkUrl 'https://github.com/owner/configured-repo'
        try {
            $w = @()
            $s = Get-YurunaGitHubSource -RepoRoot $dir -WarningVariable w -WarningAction SilentlyContinue
            Assert-StringEqual -Actual $s.Repo -Expected 'owner/configured-repo' -Because 'with no remote, the configured URL is all there is'
            Assert-True ($w.Count -gt 0) 'the unproven pairing must be reported'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    It 'keeps frameworkUrl as the clone URL even when the fetch slug differs' {
        # FrameworkUrl answers "where do I clone the framework from", which is a
        # different question from "where do these exact bytes live". Only the
        # second has to agree with the pinned commit.
        $dir = Get-GitHubSourceFixture -RemoteUrl 'https://github.com/owner/checkout-repo.git' `
                                       -FrameworkUrl 'https://github.com/owner/configured-repo'
        try {
            $s = Get-YurunaGitHubSource -RepoRoot $dir -WarningAction SilentlyContinue
            Assert-StringEqual -Actual $s.FrameworkUrl -Expected 'https://github.com/owner/configured-repo' -Because 'the clone URL still comes from config'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    It 'ignores a non-GitHub remote so a mirror cannot become the fetch source' {
        $dir = Get-GitHubSourceFixture -RemoteUrl 'https://gitlab.com/owner/mirror.git' `
                                       -FrameworkUrl 'https://github.com/owner/configured-repo'
        try {
            $s = Get-YurunaGitHubSource -RepoRoot $dir -WarningAction SilentlyContinue
            Assert-StringEqual -Actual (Get-YurunaCheckoutRemoteUrl -RepoRoot $dir) -Expected '' -Because 'a non-GitHub remote cannot serve raw content'
            Assert-StringEqual -Actual $s.Repo -Expected 'owner/configured-repo' -Because 'so the configured URL answers instead'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }
}

Describe 'verify_sha256 (guest-side gate)' {
    It 'returns 0 match / 1 mismatch / 0 empty-unenforced / 1 empty-enforced' {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $fae   = Get-Content -Raw -LiteralPath $script:faePath
        $vf    = [regex]::Match($fae, '(?ms)^verify_sha256\(\)\s*\{.*?^\}')
        Assert-True $vf.Success 'verify_sha256 found in fetch-and-execute.sh'
        $driver = @'

tf=$(mktemp); printf 'yuruna integrity probe' > "$tf"
h=$(sha256sum "$tf" | awk '{print $1}')
m=0;  verify_sha256 "$tf" "$h"        l >/dev/null 2>&1 || m=$?
x=0;  verify_sha256 "$tf" "deadbeef"  l >/dev/null 2>&1 || x=$?
e=0;  verify_sha256 "$tf" ""          l >/dev/null 2>&1 || e=$?
export EXEC_REQUIRE_SHA256=1
r=0;  verify_sha256 "$tf" ""          l >/dev/null 2>&1 || r=$?
unset EXEC_REQUIRE_SHA256
rm -f "$tf"
echo "$m $x $e $r"
'@
        $script = $vf.Value + "`n" + $driver
        # Feed the script on stdin so there is no Windows/POSIX temp-path to
        # translate for the bash child (the suite also runs on Linux/macOS hosts).
        # Drop stderr (the deliberate integrity warnings) so only the result line
        # is captured.
        $out = ($script | & $bash.Source 2>$null | Select-Object -Last 1 | Out-String).Trim()
        Assert-StringEqual -Actual $out -Expected '0 1 0 1' -Because "verify_sha256 rc[match mismatch empty require]=$out"
    }
}

Describe 'envelope name compatibility (guest side)' {
    # The host types the short names, but a short-name guest can still meet an
    # older host that types EXEC_*, and a hand-run guest has only the host.env
    # values. All three levels must resolve, newest first, or the pairing breaks
    # on a name mismatch rather than on anything real. (The opposite direction --
    # an old guest under a new host -- is what the unshortened
    # EXEC_REQUIRE_SHA256 above keeps fail-closed.)
    It 'resolves E_FB_REPO/REF first, then EXEC_FALLBACK_*, then host.env' {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        # resolve_fetch_source sources /etc/yuruna/host.env when present, which
        # would supply its own YURUNA_GITHUB_* and mask the third level. That
        # file is a guest artifact; a machine that has one is not a test host.
        if (Test-Path -LiteralPath '/etc/yuruna/host.env') { Set-ItResult -Skipped -Because 'this host is guest-shaped (/etc/yuruna/host.env present)'; return }
        $fae = Get-Content -Raw -LiteralPath $script:faePath
        $fn  = [regex]::Match($fae, '(?ms)^resolve_fetch_source\(\)\s*\{.*?^\}')
        Assert-True $fn.Success 'resolve_fetch_source found in fetch-and-execute.sh'
        $driver = @'

E_FB_REPO=short/repo; EXEC_FALLBACK_REPO=legacy/repo; YURUNA_GITHUB_REPO=baked/repo
E_FB_REF=aaa;         EXEC_FALLBACK_REF=bbb;          YURUNA_GITHUB_REF=ccc
resolve_fetch_source; printf '%s:%s ' "$GH_REPO" "$GH_REF"
unset E_FB_REPO E_FB_REF
resolve_fetch_source; printf '%s:%s ' "$GH_REPO" "$GH_REF"
unset EXEC_FALLBACK_REPO EXEC_FALLBACK_REF
resolve_fetch_source; printf '%s:%s\n' "$GH_REPO" "$GH_REF"
'@
        $script = $fn.Value + "`n" + $driver
        $out = ($script | & $bash.Source 2>$null | Select-Object -Last 1 | Out-String).Trim()
        Assert-StringEqual -Actual $out -Expected 'short/repo:aaa legacy/repo:bbb baked/repo:ccc' -Because "fallback name precedence, got '$out'"
    }

    # The two digests are read at file scope, not inside an extractable
    # function, so these are asserted against the source.
    It 'reads both digest spellings, short name first' {
        $fae = Get-Content -Raw -LiteralPath $script:faePath
        Assert-True ($fae -match '\$\{E_SHA:-\$\{EXEC_SHA256:-\}\}')             'payload digest accepts both spellings'
        Assert-True ($fae -match '\$\{E_RETRY_SHA:-\$\{EXEC_RETRY_SHA256:-\}\}') 'retry-lib digest accepts both spellings'
    }
}

Describe 'guidance when the GitHub fallback cannot work' {

    # A guest cannot tell whether its host's git credential may read the project,
    # so when the fallback is the only route left and that route can only 404, the
    # banners name where the answer already lives instead of guessing. Printed at
    # file scope rather than from an extractable function, so asserted against the
    # source the way the digest reads above are.
    It 'sends the reader to the pool column and to the standalone check' {
        $fae = Get-Content -Raw -LiteralPath $script:faePath
        Assert-True ($fae -match "'Project'")        'the pool column carrying the verdict is named'
        Assert-True ($fae -match 'DENIED')           'the verdict no retry can fix is named'
        Assert-True ($fae -match 'Test-Config\.ps1') 'the standalone host check is named'
    }

    # Guidance that names a page is only as good as the page. Tying the two
    # together here means renaming the column breaks this test rather than
    # quietly leaving every stranded guest pointed at something that is gone.
    It 'names a column that Pool Control actually renders, and a script that exists' {
        $repo = Split-Path -Parent (Split-Path -Parent $script:faePath)
        $hostsPage = Join-Path $repo 'test/extension/pool-control-service/server/internal/httpsrv/web/hosts.html'
        Assert-True (Test-Path -LiteralPath $hostsPage) "pool control hosts page present at $hostsPage"
        Assert-True ((Get-Content -Raw -LiteralPath $hostsPage) -match '>Project</button>') `
            'the hosts page still renders the Project column the guest banner names'
        Assert-True (Test-Path -LiteralPath (Join-Path $repo 'test/Test-Config.ps1')) `
            'the standalone check the banner names still exists'
    }
}
