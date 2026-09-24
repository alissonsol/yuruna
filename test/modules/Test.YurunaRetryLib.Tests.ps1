<#PSScriptInfo
.VERSION 2026.09.24
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

# --- REGION: Exported retry functions
Describe 'yuruna-retry.sh exported functions in a child Bash' {
    It 'preserves <Name> after the parent sources the library' -TestCases @(
        @{ Name = 'first-attempt success'; Attempts = '2'; SucceedAt = 1; ExpectedCalls = 1; ExpectedCode = 0; StrictSuccess = 'yes' }
        @{ Name = 'retry then success'; Attempts = '3'; SucceedAt = 3; ExpectedCalls = 3; ExpectedCode = 0; StrictSuccess = 'no' }
        @{ Name = 'exhaustion exit status'; Attempts = '2'; SucceedAt = 0; ExpectedCalls = 2; ExpectedCode = 9; StrictSuccess = 'no' }
        @{ Name = 'invalid configuration defaults'; Attempts = 'invalid'; SucceedAt = 0; ExpectedCalls = 5; ExpectedCode = 9; StrictSuccess = 'no' }
    ) {
        param($Name, $Attempts, $SucceedAt, $ExpectedCalls, $ExpectedCode, $StrictSuccess)
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $lib = Get-Content -Raw -LiteralPath $script:libPath
        # A fetched guest script inherits exported functions without sourcing
        # the library again; only the parent shell receives its source here.
        $driver = @'
bash -c '
set -euo pipefail
export YURUNA_RETRY_MAX_ATTEMPTS="$1" YURUNA_RETRY_DELAY_SECONDS=invalid
unset YURUNA_RETRY_CLASSIFY YURUNA_RETRY_RECORD YURUNA_RETRY_HEAL
unset YURUNA_RETRY_STALL_TIMEOUT_SECONDS
sleep() { :; }
calls=0
succeed_at="$2"
_probe() {
    calls=$((calls + 1))
    if [ "$calls" -eq "$succeed_at" ]; then return 0; fi
    return 9
}
rc=0
if [ "$3" = yes ]; then
    _yuruna_retry child_probe _probe
else
    _yuruna_retry child_probe _probe || rc=$?
fi
printf "RESULT:%s:%s\n" "$calls" "$rc"
exit "$rc"
' -- "$@"
'@
        $lines = @(($lib + "`n" + $driver) | & $bash.Source -s -- $Attempts $SucceedAt $StrictSuccess 2>&1)
        $actualCode = $LASTEXITCODE
        $output = ($lines | Out-String).Trim()
        Assert-Equal -Expected $ExpectedCode -Actual $actualCode -Because "$Name must preserve the wrapped command's status: $output"
        Assert-Match -Pattern "(?m)^RESULT:${ExpectedCalls}:${ExpectedCode}$" -Actual $output `
            -Because "$Name must execute the command the expected number of times"
        Assert-False ($output -match 'command not found') 'every transitive retry helper must survive the child-shell boundary'
        if ($ExpectedCalls -gt 1) {
            $records = @($lines | ForEach-Object { "$_" } | Where-Object { $_ -like 'YURUNA_RETRY *' } |
                ForEach-Object { $_.Substring('YURUNA_RETRY '.Length) | ConvertFrom-Json })
            $failedAttempts = @($records | Where-Object { $_.event -eq 'attempt' })
            $expectedFailures = if ($ExpectedCode -eq 0) { $ExpectedCalls - 1 } else { $ExpectedCalls }
            Assert-Equal -Expected $expectedFailures -Actual $failedAttempts.Count -Because 'child retries must retain structured failure telemetry'
        }
    }
}

Describe 'yuruna-retry.sh transient gate + jitter (bash)' {
    It 'uses the same positive decimal configuration defaults as PowerShell' {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $lib = Get-Content -Raw -LiteralPath $script:libPath
        Import-Module (Join-Path (Split-Path -Parent $script:libPath) 'Yuruna.Retry.psm1') -Force
        $variable = 'YURUNA_RETRY_CONSISTENCY_TEST'
        $previous = [Environment]::GetEnvironmentVariable($variable)
        try {
            foreach ($raw in @('', '0', '-1', 'bad', '1.5', '1', '02', '08', '0008', ' +8 ', '2147483647', '2147483648', '99999999999999999999999')) {
                [Environment]::SetEnvironmentVariable($variable, $raw)
                $expected = Get-YurunaRetryDefault -EnvName $variable -Fallback 10
                $driver = $lib + "`n" + '_yuruna_retry_positive_integer "$1" 10'
                $actual = ($driver | & $bash.Source -s -- $raw 2>$null | Out-String).Trim()
                Assert-StringEqual -Actual $actual -Expected "$expected" -Because "retry default differs for '$raw'"
            }
        } finally {
            [Environment]::SetEnvironmentVariable($variable, $previous)
        }
    }

    It 'executes the default attempts on invalid configuration and preserves the command failure' {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $lib = Get-Content -Raw -LiteralPath $script:libPath
        $driver = @'
sleep() { :; }
_counted() { calls=$((calls + 1)); return 9; }
for raw in '' 0 -1 bad 2147483648 02 08; do
    calls=0
    YURUNA_RETRY_MAX_ATTEMPTS="$raw" YURUNA_RETRY_DELAY_SECONDS=bad \
        _yuruna_retry probe _counted >/dev/null 2>&1
    printf '%s:%s ' "$calls" "$?"
done
printf '\n'
'@
        $out = (($lib + "`n" + $driver) | & $bash.Source 2>$null | Select-Object -Last 1 | Out-String).Trim()
        Assert-StringEqual -Actual $out -Expected '5:9 5:9 5:9 5:9 5:9 2:9 8:9' -Because 'a retry configuration must never turn an unexecuted command into success'
    }

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
    It 'forces apt attempts non-interactive through sudo without breaking the stall hoist' {
        # An exported DEBIAN_FRONTEND never reaches apt: sudo resets the
        # environment to what env_keep lists, and that list has neither of
        # these variables on it. Losing them is silent and costs a whole step
        # -- dpkg-preconfigure blocks on a debconf question that an OCR-driven
        # console cannot answer, and with stdout on a pipe the question does
        # not even flush -- so the injection is asserted rather than assumed.
        # `env` rather than a bare VAR=value word is what keeps the argument a
        # real command: timeout(1) execs its argument and cannot exec an
        # assignment, so the bare form would break the bounded shape below.
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $lib = Get-Content -Raw -LiteralPath $script:libPath
        $driver = @'

r=""
pre="env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical"
# A real sudo/apt-get on PATH, not shell stubs: the stall hoist declines to
# bound a shell function, so a stubbed sudo would quietly test the unbounded
# path instead of the one under test. The fake sudo records argv and does NOT
# exec, and the fake apt-get shadows the host's own so nothing is installed.
d=$(mktemp -d) || { echo "no-tmpdir"; exit 0; }
printf '#!/bin/sh\necho "SUDOARGS:$*"\n' > "$d/sudo"
printf '#!/bin/sh\necho "APTENV:${DEBIAN_FRONTEND:-unset}/${DEBIAN_PRIORITY:-unset}"\n' > "$d/apt-get"
chmod +x "$d/sudo" "$d/apt-get"
PATH="$d:$PATH"

# Unbounded (the dist-upgrade shape): the prefix lands directly after sudo.
o=$(YURUNA_APT_STALL_TIMEOUT_SECONDS=0 apt_retry sudo apt-get dist-upgrade -y 2>&1)
case "$o" in
  *"SUDOARGS:$pre apt-get dist-upgrade -y"*) r="${r}N " ;;
  *) r="${r}n($o) " ;;
esac

# Bounded: timeout must still hoist INSIDE sudo, with the prefix inside it.
o=$(YURUNA_APT_STALL_TIMEOUT_SECONDS=300 apt_retry sudo apt-get update 2>&1)
case "$o" in
  *"SUDOARGS:timeout --foreground --kill-after=30 300 $pre apt-get update"*) r="${r}H " ;;
  *) r="${r}h($o) " ;;
esac

# Already root, so no sudo token to insert after: the variables still have to
# reach the tool, or a root-run guest keeps the hang the sudo path just lost.
o=$(YURUNA_APT_STALL_TIMEOUT_SECONDS=0 apt_retry apt-get install -y git 2>&1)
case "$o" in
  *"APTENV:noninteractive/critical"*) r="${r}R" ;;
  *) r="${r}r($o)" ;;
esac

rm -rf "$d"
echo "$r"
'@
        $script = $lib + "`n" + $driver
        $out = ($script | & $bash.Source 2>$null | Select-Object -Last 1 | Out-String).Trim()
        Assert-StringEqual -Actual $out -Expected 'N H R' -Because "apt non-interactive/hoist result was: '$out'"
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
# one structured marker per failed attempt, carrying stack/label/attempt/rc.
# Counting the attempt event specifically: the run also records one outcome
# event at the end, and a bare marker count would fold the two together.
_r9() { return 9; }
mk=$(YURUNA_RETRY_MAX_ATTEMPTS=2 YURUNA_RETRY_DELAY_SECONDS=1 _yuruna_retry curl_retry _r9 2>&1 | grep -c '"event":"attempt"')
r="${r}${mk}"
echo "$r"
'@
        $script = $lib + "`n" + $driver
        $out = ($script | & $bash.Source 2>$null | Select-Object -Last 1 | Out-String).Trim()
        # wget: net=0 auth=1 parse=1 404=1 503=0 | 2 markers over 2 failed attempts
        Assert-StringEqual -Actual $out -Expected '0 1 1 1 0 2' -Because "wget classifier + marker result was: '$out'"
    }
    It 'writes its verdict into the log a wrapped attempt appends to' {
        # The wrapper's prose goes to the CALLER's stderr, while the log an
        # attempt writes is opened around the attempt alone -- so a consumer
        # reading that log never sees a sentence the wrapper printed. The
        # outcome record is what reaches it.
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $lib = Get-Content -Raw -LiteralPath $script:libPath
        $log = (Join-Path $TestDrive 'retry-record.log') -replace '\\', '/'
        $driver = @"

_fail() { return 7; }
_perm() { return 3; }
rm -f '$log'
export YURUNA_RETRY_MAX_ATTEMPTS=2 YURUNA_RETRY_DELAY_SECONDS=1
YURUNA_RETRY_RECORD='$log' _yuruna_retry exhaust_probe _fail >/dev/null 2>&1 || true
_classify() { return 1; }
YURUNA_RETRY_CLASSIFY=_classify YURUNA_RETRY_RECORD='$log' _yuruna_retry perm_probe _perm >/dev/null 2>&1 || true
"@
        $null = ($lib + "`n" + $driver) | & $bash.Source 2>$null
        Assert-True (Test-Path -LiteralPath $log) 'the wrapper wrote no record file at all'
        $records = @(Get-Content -LiteralPath $log |
            Where-Object { $_ -like 'YURUNA_RETRY *' } |
            ForEach-Object { ConvertFrom-Json -InputObject $_.Substring('YURUNA_RETRY '.Length) })
        $outcomes = @($records | Where-Object { [string]$_.event -ceq 'outcome' })
        Assert-Equal -Expected 2 -Actual $outcomes.Count 'each run must record exactly one outcome'

        $exhausted = @($outcomes | Where-Object { [string]$_.outcome -ceq 'exhausted' })
        Assert-Equal -Expected 1 -Actual $exhausted.Count 'a run that used every attempt records exhausted'
        Assert-Equal -Expected 7 -Actual ([int]$exhausted[0].rc) 'the record carries the failing exit code'
        Assert-Equal -Expected 2 -Actual ([int]$exhausted[0].maxAttempts) 'and how many attempts it was allowed'

        $permanent = @($outcomes | Where-Object { [string]$_.outcome -ceq 'permanent' })
        Assert-Equal -Expected 1 -Actual $permanent.Count 'a classified-permanent failure records permanent, not exhausted'
        Assert-Equal -Expected 1 -Actual ([int]$permanent[0].attempt) 'and stops on the attempt that classified it'
    }

    It 'gives a consumer no sentence to recognize' {
        # The diagnostic reads these records. It used to match the English
        # "all N attempts exhausted", which the wrapper writes to a stream that
        # log never receives -- so the check found nothing on any real run, and
        # would have followed the host's language even if it had.
        $here = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
        $diagnostic = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $here) 'automation/Get-SystemDiagnostic.ps1'))
        Assert-False ($diagnostic -match "(?i)-match\s+'[^']*attempts exhausted") `
            'the diagnostic recognizes the retry outcome by a sentence again'
        Assert-Match "\`$record\.event -cne 'outcome'" $diagnostic `
            'the diagnostic must select the outcome record, not any YURUNA_RETRY line'
    }

    It 'routes certificate failures through repair in <Shell> Bash and retries only after a repair' -TestCases @(
        @{ Shell = 'parent' }
        @{ Shell = 'child' }
    ) {
        param($Shell)
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) { Set-ItResult -Skipped -Because 'bash is not available on this host'; return }
        $lib = Get-Content -Raw -LiteralPath $script:libPath
        # A stale bump CA is the only cert failure a retry can survive, and only
        # after the anchor has actually been replaced. The stub stands in for the
        # trust store: TRUSTED tracks what a spider probe would see, and the
        # stubbed trust refresh flips it only when the served CA matches.
        $driver = @'

r=""
TRUSTED=no; CA_SERVED=yes; HEAL_WORKS=yes
wget() {
  case "$*" in
    *--spider*) [ "$TRUSTED" = yes ] && return 0 || return 1 ;;
    *ca.crt*)   [ "$CA_SERVED" = yes ] || return 1
                prev=""; for a in "$@"; do [ "$prev" = "-qO" ] && echo "-----BEGIN CERTIFICATE-----" > "$a"; prev="$a"; done
                return 0 ;;
  esac; return 1
}
update-ca-certificates() { :; }
sudo() {
  if [ "$1" = update-ca-certificates ] && [ "$HEAL_WORKS" = yes ]; then TRUSTED=yes; fi
  return 0
}
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
        if ($Shell -eq 'child') {
            $driver = "bash <<'YURUNA_CHILD_BASH'`n" + $driver + "`nYURUNA_CHILD_BASH`n"
        }
        $script = $lib + "`n" + $driver
        $out = ($script | & $bash.Source 2>$null | Select-Object -Last 1 | Out-String).Trim()
        Assert-StringEqual -Actual $out -Expected '1 1 1 1 0 0 0 2 1 2 1' -Because "cert-failure re-anchor result was: '$out'"
    }
}
