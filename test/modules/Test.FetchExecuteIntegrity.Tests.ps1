<#PSScriptInfo
.VERSION 2026.08.05
.GUID 424f932a-5ed9-4dec-8a02-8f7c8aa9234b
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
      * Host side -- Get-FetchExecuteEnvPrefix (Test.SequenceHandler.psm1) must
        prepend EXEC_REQUIRE_SHA256=1 for any fetch-and-execute command, add an
        E_SHA that equals Get-FileHash of the served file, strip a ?query,
        and fail CLOSED (require flag, no digest) for a traversal/absolute/
        missing path so a served-root drift cannot silently run unverified code.
        The envelope is also typed one key event per character into the guest
        console, so its length is itself a guarded property.
      * Guest side -- verify_sha256 (automation/fetch-and-execute.sh) must return
        0 on a match, 1 on a mismatch, 0 on an empty digest without the require
        flag (rollout-compat), and 1 on an empty digest WITH the require flag.
    The host half extracts the real function via the parser and exercises it (no
    module import, so no host I/O deps -- the same discipline as the sibling
    sequence tests). The guest half extracts the real shell function and runs it
    under bash; it is skipped (passes) where bash is unavailable.
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$modPath  = Join-Path $here 'Test.SequenceHandler.psm1'
$faePath  = Join-Path $repoRoot 'automation/fetch-and-execute.sh'

function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Equal { param($Actual, $Expected, [string]$Because = '') if ("$Actual" -ne "$Expected") { throw "Expected '$Expected', got '$Actual'. $Because" } }

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

# Define the REAL Get-FetchExecuteEnvPrefix by lifting its source out of the
# module (parser find), so a refactor that drops the digest prefix breaks here.
# Lifting the function out of its module also strips its imports, so the GitHub
# fallback resolver it calls has to be brought in by hand here.
Import-Module (Join-Path $repoRoot 'automation/Yuruna.GitHubSource.psm1') -Force -DisableNameChecking
$modAst = [System.Management.Automation.Language.Parser]::ParseFile($modPath, [ref]$null, [ref]$null)
$fnAst  = $modAst.Find({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and $n.Name -eq 'Get-FetchExecuteEnvPrefix' }, $true)
if (-not $fnAst) { throw 'Get-FetchExecuteEnvPrefix not found in Test.SequenceHandler.psm1' }
. ([scriptblock]::Create($fnAst.Extent.Text))

# File scope, not Describe scope. Pester runs a Describe body during DISCOVERY and
# discards its variables before the It blocks run, so a $sample defined in there
# arrives empty at assert time -- and every assertion built on it silently checks
# the empty-path branch instead of the digest. File-scope variables survive into
# the run phase, which is why $repoRoot and $faePath above already work.
$sample     = 'guest/ubuntu.server.26/ubuntu.server.26.update.sh'
$sampleFull = Join-Path $repoRoot $sample
$sampleHash = (Get-FileHash -LiteralPath $sampleFull -Algorithm SHA256).Hash.ToLower()

Describe 'Get-FetchExecuteEnvPrefix (host-side digest injection)' {
    It 'prepends the require flag + an E_SHA equal to Get-FileHash, plus the retry digest' {
        $p = Get-FetchExecuteEnvPrefix -CommandLine "/usr/local/lib/yuruna/fetch-and-execute.sh $sample" -RepoRoot $repoRoot
        Assert-True ($p -match 'EXEC_REQUIRE_SHA256=1 ')       'require flag present'
        Assert-True ($p -match "E_SHA=$sampleHash ")           'digest equals Get-FileHash'
        Assert-True ($p -match 'E_RETRY_SHA=[0-9a-f]{64} ')    'retry-lib digest present'
    }
    It 'strips a ?query before hashing' {
        $p = Get-FetchExecuteEnvPrefix -CommandLine "fetch-and-execute.sh $sample`?nocache=9" -RepoRoot $repoRoot
        Assert-True ($p -match "E_SHA=$sampleHash ") 'query stripped, digest still correct'
    }

    # The value-carrying names were shortened to buy console keystrokes, but
    # EXEC_REQUIRE_SHA256 was deliberately left long: it is the only token a
    # guest imaged BEFORE the rename still recognizes. Seeing it with no digest
    # it understands, such a guest refuses; shorten it and the same guest would
    # instead run the fetched bytes unverified. This test is the tripwire.
    It 'keeps EXEC_REQUIRE_SHA256 unshortened so a pre-rename guest fails closed' {
        $p = Get-FetchExecuteEnvPrefix -CommandLine "fetch-and-execute.sh $sample" -RepoRoot $repoRoot -WarningAction SilentlyContinue
        Assert-True ($p.StartsWith('EXEC_REQUIRE_SHA256=1 ')) 'the legacy require flag leads the envelope'
    }

    # The envelope is TYPED into the guest console one key event per character
    # and shares a ~400-character budget with the step's own command (see
    # $script:FetchExecuteTypedCharWarn). Growing it silently eats the headroom
    # every sequence author is spending, so the ceiling is asserted here.
    It 'stays inside its share of the typed-character budget' {
        $p = Get-FetchExecuteEnvPrefix -CommandLine "fetch-and-execute.sh $sample" -RepoRoot $repoRoot -WarningAction SilentlyContinue
        Assert-True ($p.Length -le 240) "envelope is $($p.Length) characters; budget is 240"
    }
    It 'fails closed (require, no digest) for a traversal path' {
        $p = Get-FetchExecuteEnvPrefix -CommandLine 'fetch-and-execute.sh ../../etc/passwd' -RepoRoot $repoRoot -WarningAction SilentlyContinue
        Assert-Equal -Actual $p -Expected 'EXEC_REQUIRE_SHA256=1 ' -Because 'traversal -> require, no digest'
    }
    It 'fails closed (require, no digest) for an absolute path' {
        $p = Get-FetchExecuteEnvPrefix -CommandLine 'fetch-and-execute.sh /etc/passwd' -RepoRoot $repoRoot -WarningAction SilentlyContinue
        Assert-Equal -Actual $p -Expected 'EXEC_REQUIRE_SHA256=1 ' -Because 'absolute -> require, no digest'
    }
    It 'fails closed (require, no digest) for a missing file' {
        $p = Get-FetchExecuteEnvPrefix -CommandLine 'fetch-and-execute.sh guest/does-not-exist.sh' -RepoRoot $repoRoot -WarningAction SilentlyContinue
        Assert-Equal -Actual $p -Expected 'EXEC_REQUIRE_SHA256=1 ' -Because 'missing file -> require, no digest'
    }
    It 'returns empty for a non-fetch-and-execute command' {
        Assert-Equal -Actual (Get-FetchExecuteEnvPrefix -CommandLine 'whoami && hostname' -RepoRoot $repoRoot) -Expected '' -Because 'non-fetch -> empty'
    }
    It 'returns empty when RepoRoot is unset (code-regression safety valve, not a runtime state)' {
        Assert-Equal -Actual (Get-FetchExecuteEnvPrefix -CommandLine 'fetch-and-execute.sh guest/x.sh' -RepoRoot '') -Expected '' -Because 'no RepoRoot -> empty'
    }

    # The GitHub fallback must name THIS repository at an EXACT commit. A moving
    # branch, or any other repository, serves bytes the digest above was never
    # taken from, so the guest's integrity gate refuses to run them -- surfacing
    # as an "integrity mismatch" whose real cause is the wrong source.
    It 'pins the fallback to this repo at an exact commit (never a branch)' {
        $p = Get-FetchExecuteEnvPrefix -CommandLine "fetch-and-execute.sh $sample" -RepoRoot $repoRoot -WarningAction SilentlyContinue
        $expectedRepo = (Get-YurunaGitHubSource -RepoRoot $repoRoot).Repo
        # Abbreviated to 12 hex characters to save keystrokes; still a commit,
        # which is the property that matters -- a branch would move off the
        # bytes the digest above was taken from.
        $expectedRef  = (& git -C $repoRoot rev-parse HEAD).Trim().Substring(0, 12)
        Assert-True ($p -match "E_FB_REPO=$([regex]::Escape($expectedRepo)) ") 'fallback names this repository'
        Assert-True ($p -match "E_FB_REF=$expectedRef ")                       'fallback pins HEAD, not a branch'
        Assert-True ($p -notmatch 'refs/heads|/main/|/master/')                'no moving-branch ref'
    }

    # The typed command line is rendered on the VM console, which the host
    # screenshots and OCRs into the run log the status service publishes. A token
    # typed here would be readable in failure_screenshot.png / failure_ocr.txt.
    It 'never types the GitHub token onto the console' {
        $p = Get-FetchExecuteEnvPrefix -CommandLine "fetch-and-execute.sh $sample" -RepoRoot $repoRoot -WarningAction SilentlyContinue
        Assert-True ($p -notmatch '(?i)GH_TOKEN') 'no GH_TOKEN in the typed prefix'
        $configured = (Get-YurunaGitHubSource -RepoRoot $repoRoot).Token
        if ($configured) { Assert-True ($p -notmatch [regex]::Escape($configured)) 'the configured token value never appears' }
    }
}

Describe 'Get-YurunaGitHubSource / ConvertTo-GitHubRepoSlug' {
    It 'reduces every remote-URL shape to owner/repo' {
        Assert-Equal (ConvertTo-GitHubRepoSlug 'https://github.com/o/r')        'o/r'
        Assert-Equal (ConvertTo-GitHubRepoSlug 'https://github.com/o/r.git')    'o/r'
        Assert-Equal (ConvertTo-GitHubRepoSlug 'git@github.com:o/r.git')        'o/r'
        Assert-Equal (ConvertTo-GitHubRepoSlug 'ssh://git@github.com/o/r')      'o/r'
    }
    It 'returns empty for a non-GitHub URL, so no fallback is attempted' {
        Assert-Equal (ConvertTo-GitHubRepoSlug 'https://gitlab.com/o/r') ''
        Assert-Equal (ConvertTo-GitHubRepoSlug '')                       ''
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
            Assert-Equal $s.Repo 'owner/checkout-repo' -Because 'the slug must name the repository the commit came from'
            Assert-Equal $s.Ref (& git -C $dir rev-parse HEAD).Trim() -Because 'the ref is still this checkout HEAD'
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
            Assert-Equal $s.Repo 'owner/same-repo' -Because 'the agreed slug is used'
            Assert-Equal $w.Count 0 -Because 'agreement is not worth a warning'
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
            Assert-Equal $s.Repo 'owner/configured-repo' -Because 'with no remote, the configured URL is all there is'
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
            Assert-Equal $s.FrameworkUrl 'https://github.com/owner/configured-repo' -Because 'the clone URL still comes from config'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }

    It 'ignores a non-GitHub remote so a mirror cannot become the fetch source' {
        $dir = Get-GitHubSourceFixture -RemoteUrl 'https://gitlab.com/owner/mirror.git' `
                                       -FrameworkUrl 'https://github.com/owner/configured-repo'
        try {
            $s = Get-YurunaGitHubSource -RepoRoot $dir -WarningAction SilentlyContinue
            Assert-Equal (Get-YurunaCheckoutRemoteUrl -RepoRoot $dir) '' -Because 'a non-GitHub remote cannot serve raw content'
            Assert-Equal $s.Repo 'owner/configured-repo' -Because 'so the configured URL answers instead'
        } finally { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue }
    }
}

Describe 'verify_sha256 (guest-side gate)' {
    It 'returns 0 match / 1 mismatch / 0 empty-unenforced / 1 empty-enforced' {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Assert-True $true 'bash unavailable -- skipping shell check'; return }
        $fae   = Get-Content -Raw -LiteralPath $faePath
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
        Assert-Equal -Actual $out -Expected '0 1 0 1' -Because "verify_sha256 rc[match mismatch empty require]=$out"
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
        if (-not $bash) { Assert-True $true 'bash unavailable -- skipping shell check'; return }
        # resolve_fetch_source sources /etc/yuruna/host.env when present, which
        # would supply its own YURUNA_GITHUB_* and mask the third level. That
        # file is a guest artifact; a machine that has one is not a test host.
        if (Test-Path -LiteralPath '/etc/yuruna/host.env') { Assert-True $true 'guest-shaped machine -- skipping'; return }
        $fae = Get-Content -Raw -LiteralPath $faePath
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
        Assert-Equal -Actual $out -Expected 'short/repo:aaa legacy/repo:bbb baked/repo:ccc' -Because "fallback name precedence, got '$out'"
    }

    # The two digests are read at file scope, not inside an extractable
    # function, so these are asserted against the source.
    It 'reads both digest spellings, short name first' {
        $fae = Get-Content -Raw -LiteralPath $faePath
        Assert-True ($fae -match '\$\{E_SHA:-\$\{EXEC_SHA256:-\}\}')             'payload digest accepts both spellings'
        Assert-True ($fae -match '\$\{E_RETRY_SHA:-\$\{EXEC_RETRY_SHA256:-\}\}') 'retry-lib digest accepts both spellings'
    }
}
