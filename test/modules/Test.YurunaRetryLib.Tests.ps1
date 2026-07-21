<#PSScriptInfo
.VERSION 2026.07.21
.GUID 423e1a49-2b85-4d60-9f12-6a0d5c8e2b74
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test retry jitter transient-gate pester
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
    Pester guard on automation/yuruna-retry.sh: the transient/permanent gate
    (a deterministic 404 fails fast; a 503/429/network error still retries) and
    the equal-jitter backoff (a random point in [delay/2, delay]).
.DESCRIPTION
    The whole lib is sourced inline under bash and exercised with a driver fed on
    stdin (no Windows/POSIX path to translate). The curl re-probe is stubbed with
    a shell `curl` returning a fixed status, so no network is touched. Skipped
    (passes) where bash is unavailable -- the live path is covered by the pool
    cycle, which sources this lib on every guest.
#>

$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$libPath  = Join-Path $repoRoot 'automation/yuruna-retry.sh'

function Assert-Equal { param($Actual, $Expected, [string]$Because = '') if ("$Actual" -ne "$Expected") { throw "Expected '$Expected', got '$Actual'. $Because" } }
function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

Describe 'yuruna-retry.sh transient gate + jitter (bash)' {
    It 'classifies 404 permanent / 503 + 429 + network transient, fails fast on permanent, and jitters within [delay/2, delay]' {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Assert-True $true 'bash unavailable -- skipping shell check'; return }
        $lib = Get-Content -Raw -LiteralPath $libPath
        $driver = @'

r=""
# classifier: network transient -> 0, malformed URL -> 1
_yuruna_classify_curl 7  >/dev/null 2>&1; r="$r$? "
_yuruna_classify_curl 3  >/dev/null 2>&1; r="$r$? "
# HTTP-error (rc 22): re-probe stubbed to a fixed status. 404 -> permanent(1), 503/429 -> transient(0)
curl() { echo 404; }
YURUNA_RETRY_CURL_URL=x _yuruna_classify_curl 22 >/dev/null 2>&1; r="$r$? "
curl() { echo 503; }
YURUNA_RETRY_CURL_URL=x _yuruna_classify_curl 22 >/dev/null 2>&1; r="$r$? "
curl() { echo 429; }
YURUNA_RETRY_CURL_URL=x _yuruna_classify_curl 22 >/dev/null 2>&1; r="$r$? "
unset -f curl
# gate integration: a permanent rc (3) stops the ladder after exactly 1 attempt
_p() { return 3; }
a=$(YURUNA_RETRY_CLASSIFY=_yuruna_classify_curl YURUNA_RETRY_MAX_ATTEMPTS=5 YURUNA_RETRY_DELAY=1 _yuruna_retry t _p 2>&1 | grep -c 'attempt .* failed')
r="$r$a "
# jitter: a retried failure sleeps a value in [5,10] for a base delay of 10
_x() { return 9; }
n=$(YURUNA_RETRY_MAX_ATTEMPTS=2 YURUNA_RETRY_DELAY=10 _yuruna_retry t _x 2>&1 | sed -n 's/.*sleeping \([0-9][0-9]*\)s before retry (backoff 10s.*/\1/p' | head -1)
if [ -n "$n" ] && [ "$n" -ge 5 ] && [ "$n" -le 10 ]; then r="${r}J"; else r="${r}j($n)"; fi
echo "$r"
'@
        $script = $lib + "`n" + $driver
        $out = ($script | & $bash.Source 2>$null | Select-Object -Last 1 | Out-String).Trim()
        # rc7=transient(0) rc3=permanent(1) 404=permanent(1) 503=transient(0) 429=transient(0) | 1 attempt | jitter-in-band
        Assert-Equal -Actual $out -Expected '0 1 1 0 0 1 J' -Because "classifier/gate/jitter result was: '$out'"
    }
    It 'classifies wget exit codes (incl. re-probe on exit 8) and emits one YURUNA_RETRY marker per failed attempt' {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Assert-True $true 'bash unavailable -- skipping shell check'; return }
        $lib = Get-Content -Raw -LiteralPath $libPath
        $driver = @'

r=""
_yuruna_classify_wget 4 >/dev/null 2>&1; r="$r$? "   # net -> transient 0
_yuruna_classify_wget 6 >/dev/null 2>&1; r="$r$? "   # auth -> permanent 1
_yuruna_classify_wget 2 >/dev/null 2>&1; r="$r$? "   # parse -> permanent 1
curl() { echo 404; }
YURUNA_RETRY_WGET_URL=x _yuruna_classify_wget 8 >/dev/null 2>&1; r="$r$? "  # 404 -> permanent 1
curl() { echo 503; }
YURUNA_RETRY_WGET_URL=x _yuruna_classify_wget 8 >/dev/null 2>&1; r="$r$? "  # 503 -> transient 0
unset -f curl
# one structured marker per failed attempt, carrying stack/label/attempt/rc
_r9() { return 9; }
mk=$(YURUNA_RETRY_MAX_ATTEMPTS=2 YURUNA_RETRY_DELAY=1 _yuruna_retry curl_retry _r9 2>&1 | grep -c '^YURUNA_RETRY {"stack":"bash"')
r="${r}${mk}"
echo "$r"
'@
        $script = $lib + "`n" + $driver
        $out = ($script | & $bash.Source 2>$null | Select-Object -Last 1 | Out-String).Trim()
        # wget: net=0 auth=1 parse=1 404=1 503=0 | 2 markers over 2 failed attempts
        Assert-Equal -Actual $out -Expected '0 1 1 1 0 2' -Because "wget classifier + marker result was: '$out'"
    }
}
