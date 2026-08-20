<#PSScriptInfo
.VERSION 2026.08.20
.GUID 421b43ea-86ef-4745-ba78-cc02250870e2
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

BeforeAll {
$here     = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$script:libPath  = Join-Path $repoRoot 'automation/yuruna-retry.sh'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

}

Describe 'yuruna-retry.sh transient gate + jitter (bash)' {
    It 'classifies 404 permanent / 503 + 429 + network transient, fails fast on permanent, and jitters within [delay/2, delay]' {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $lib = Get-Content -Raw -LiteralPath $script:libPath
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
a=$(YURUNA_RETRY_CLASSIFY=_yuruna_classify_curl YURUNA_RETRY_MAX_ATTEMPTS=5 YURUNA_RETRY_DELAY_SECONDS=1 _yuruna_retry t _p 2>&1 | grep -c 'attempt .* failed')
r="$r$a "
# jitter: a retried failure sleeps a value in [5,10] for a base delay of 10
_x() { return 9; }
n=$(YURUNA_RETRY_MAX_ATTEMPTS=2 YURUNA_RETRY_DELAY_SECONDS=10 _yuruna_retry t _x 2>&1 | sed -n 's/.*sleeping \([0-9][0-9]*\)s before retry (backoff 10s.*/\1/p' | head -1)
if [ -n "$n" ] && [ "$n" -ge 5 ] && [ "$n" -le 10 ]; then r="${r}J"; else r="${r}j($n)"; fi
echo "$r"
'@
        $script = $lib + "`n" + $driver
        $out = ($script | & $bash.Source 2>$null | Select-Object -Last 1 | Out-String).Trim()
        # rc7=transient(0) rc3=permanent(1) 404=permanent(1) 503=transient(0) 429=transient(0) | 1 attempt | jitter-in-band
        Assert-StringEqual -Actual $out -Expected '0 1 1 0 0 1 J' -Because "classifier/gate/jitter result was: '$out'"
    }
    It 'advertises the safe-stall marker and wraps a bounded call in timeout --foreground' {
        # The marker is what lets a guest script ask for a wall-clock bound
        # without knowing which copy of this lib its image baked. It certifies
        # two properties, so both are asserted here rather than trusted:
        # --foreground (a bounded command that touches the console tty is
        # otherwise stopped by SIGTTIN/SIGTTOU) and the --kill-after backstop.
        # If the wrapper ever loses those flags the marker becomes a lie, and
        # every guest that gated on it starts killing apt the unsafe way.
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $lib = Get-Content -Raw -LiteralPath $script:libPath
        $driver = @'

r=""
[ "${YURUNA_RETRY_LIB_SAFE_STALL:-}" = "1" ] && r="${r}M " || r="${r}m(${YURUNA_RETRY_LIB_SAFE_STALL:-unset}) "
# A stubbed timeout records the exact argv the wrapper builds.
timeout() { echo "TARGS:$*"; return 0; }
o=$(YURUNA_RETRY_STALL_TIMEOUT_SECONDS=300 _yuruna_retry t /bin/true 2>&1)
case "$o" in
  *"TARGS:--foreground --kill-after=30 300 /bin/true"*) r="${r}B " ;;
  *) r="${r}b($o) " ;;
esac
# Default (no stall requested) must not wrap at all: that is the state an
# older baked lib's callers rely on, and the gate expands to empty for them.
o=$(_yuruna_retry t /bin/true 2>&1)
case "$o" in
  *TARGS:*) r="${r}u($o)" ;;
  *) r="${r}U" ;;
esac
echo "$r"
'@
        $script = $lib + "`n" + $driver
        $out = ($script | & $bash.Source 2>$null | Select-Object -Last 1 | Out-String).Trim()
        Assert-StringEqual -Actual $out -Expected 'M B U' -Because "marker/wrap/no-wrap result was: '$out'"
    }
    It 'classifies wget exit codes (incl. re-probe on exit 8) and emits one YURUNA_RETRY marker per failed attempt' {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $lib = Get-Content -Raw -LiteralPath $script:libPath
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
mk=$(YURUNA_RETRY_MAX_ATTEMPTS=2 YURUNA_RETRY_DELAY_SECONDS=1 _yuruna_retry curl_retry _r9 2>&1 | grep -c '^YURUNA_RETRY {"stack":"bash"')
r="${r}${mk}"
echo "$r"
'@
        $script = $lib + "`n" + $driver
        $out = ($script | & $bash.Source 2>$null | Select-Object -Last 1 | Out-String).Trim()
        # wget: net=0 auth=1 parse=1 404=1 503=0 | 2 markers over 2 failed attempts
        Assert-StringEqual -Actual $out -Expected '0 1 1 1 0 2' -Because "wget classifier + marker result was: '$out'"
    }
    It 'routes a certificate failure (curl 60 / wget 5) through the bump-CA re-anchor and retries only when it repaired something' {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $lib = Get-Content -Raw -LiteralPath $script:libPath
        # A stale bump CA is the only cert failure a retry can survive, and only
        # after the anchor has actually been replaced. The stub stands in for the
        # trust store: TRUSTED tracks what a spider probe would see, and the
        # /ca.crt fetch flips it when HEAL_WORKS says the served CA matches.
        $driver = @'

r=""
TRUSTED=no; CA_SERVED=yes; HEAL_WORKS=yes
wget() {
  case "$*" in
    *--spider*) [ "$TRUSTED" = yes ] && return 0 || return 1 ;;
    *ca.crt*)   [ "$CA_SERVED" = yes ] || return 1
                prev=""; for a in "$@"; do [ "$prev" = "-qO" ] && echo "-----BEGIN CERTIFICATE-----" > "$a"; prev="$a"; done
                [ "$HEAL_WORKS" = yes ] && TRUSTED=yes; return 0 ;;
  esac; return 1
}
sudo() { return 0; }
YURUNA_STATUS_SERVICE_IP=10.0.0.2; YURUNA_STATUS_SERVICE_PORT=8080
# no bump in front of the guest -> nothing to repair, so a cert failure is the
# far end's certificate and retrying it is pointless
https_proxy=""
yuruna_ca_selfheal >/dev/null 2>&1; r="$r$? "                       # 1
_yuruna_classify_curl 60 >/dev/null 2>&1; r="$r$? "                 # 1 permanent
# bump present and already trusted -> same verdict, without a fetch
https_proxy="http://10.0.0.1:3129/"; TRUSTED=yes
yuruna_ca_selfheal >/dev/null 2>&1; r="$r$? "                       # 1
_yuruna_classify_curl 60 >/dev/null 2>&1; r="$r$? "                 # 1 permanent
# stale CA the status service can replace -> repaired, so spend a retry
TRUSTED=no
yuruna_ca_selfheal >/dev/null 2>&1; r="$r$? "                       # 0
TRUSTED=no; _yuruna_classify_curl 60 >/dev/null 2>&1; r="$r$? "     # 0 transient
TRUSTED=no; _yuruna_classify_wget 5 >/dev/null 2>&1; r="$r$? "      # 0 transient
# a CA that arrives but does not match the bump -> tried and still untrusted
TRUSTED=no; HEAL_WORKS=no
yuruna_ca_selfheal >/dev/null 2>&1; r="$r$? "                       # 2
_yuruna_classify_curl 60 >/dev/null 2>&1; r="$r$? "                 # 1 permanent
# nothing usable served at all -> same, and never a silent pass
TRUSTED=no; CA_SERVED=no
yuruna_ca_selfheal >/dev/null 2>&1; r="$r$? "                       # 2
# the ladder stops on the first attempt once the anchor cannot be repaired
_c60() { return 60; }
a=$(YURUNA_RETRY_CLASSIFY=_yuruna_classify_curl YURUNA_RETRY_MAX_ATTEMPTS=5 YURUNA_RETRY_DELAY_SECONDS=1 _yuruna_retry t _c60 2>&1 | grep -c 'attempt .* failed')
r="$r$a"
echo "$r"
'@
        $script = $lib + "`n" + $driver
        $out = ($script | & $bash.Source 2>$null | Select-Object -Last 1 | Out-String).Trim()
        Assert-StringEqual -Actual $out -Expected '1 1 1 1 0 0 0 2 1 2 1' -Because "cert-failure re-anchor result was: '$out'"
    }
}
