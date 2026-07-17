<#PSScriptInfo
.VERSION 2026.07.17
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
        EXEC_SHA256 that equals Get-FileHash of the served file, strip a ?query,
        and fail CLOSED (require flag, no digest) for a traversal/absolute/
        missing path so a served-root drift cannot silently run unverified code.
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
    It 'prepends the require flag + an EXEC_SHA256 equal to Get-FileHash, plus the retry digest' {
        $p = Get-FetchExecuteEnvPrefix -CommandLine "/usr/local/lib/yuruna/fetch-and-execute.sh $sample" -RepoRoot $repoRoot
        Assert-True ($p -match 'EXEC_REQUIRE_SHA256=1 ')            'require flag present'
        Assert-True ($p -match "EXEC_SHA256=$sampleHash ")          'digest equals Get-FileHash'
        Assert-True ($p -match 'EXEC_RETRY_SHA256=[0-9a-f]{64} ')   'retry-lib digest present'
    }
    It 'strips a ?query before hashing' {
        $p = Get-FetchExecuteEnvPrefix -CommandLine "fetch-and-execute.sh $sample`?nocache=9" -RepoRoot $repoRoot
        Assert-True ($p -match "EXEC_SHA256=$sampleHash ") 'query stripped, digest still correct'
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
        $expectedRef  = (& git -C $repoRoot rev-parse HEAD).Trim()
        Assert-True ($p -match "EXEC_FALLBACK_REPO=$([regex]::Escape($expectedRepo)) ") 'fallback names this repository'
        Assert-True ($p -match "EXEC_FALLBACK_REF=$expectedRef ")                       'fallback pins HEAD, not a branch'
        Assert-True ($p -notmatch 'refs/heads|/main/|/master/')                         'no moving-branch ref'
    }

    # The typed command line is rendered on the VM console, which the host
    # screenshots and OCRs into the run log the status server publishes. A token
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
