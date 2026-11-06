<#PSScriptInfo
.VERSION 2026.11.05
.GUID 426c3a63-78b5-4843-bac8-e94da2bae44a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test fetch-execute recorder profile nested prune pester
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
    A fetch-and-execute started from another one's payload leaves the outer
    invocation's recorder folder and profile alone while it runs, and a later
    invocation still removes them once it has ended.
.DESCRIPTION
    Every invocation removes the recorder folder and profile that the shared
    execution log names, because nothing else names them once that log is
    replaced. A generated guest wrapper delegates to its shared workflow
    through a second invocation inside the first one's payload, and the log
    the second invocation finds belongs to the outer one, still running:
    removing its folder loses the outer recorder's evidence and turns the
    outer stop request into a console error.

    The whole script runs under bash with the network, the terminal, sudo and
    the recorder's collector stubbed and its two system paths pointed at a
    private folder, so the nested run, the top-level run after it, and the run
    after an invocation ended by TERM are real invocations. Their recorder
    folders and profiles still land in /tmp, where the script names them, and
    every one a scenario names is removed afterwards. The function cases drive
    the extracted pruning and stop functions directly.

    Linux only: the guest tells a running invocation from a finished one
    through /proc.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    $script:ScriptText = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'automation/fetch-and-execute.sh')).Replace("`r`n", "`n")
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    $script:SkipReason = if (-not $IsLinux) { 'the guest tells a running invocation apart through /proc, which only a Linux host has' }
        elseif (-not $bash) { 'bash is not available on this host' }
        elseif ([int](& $bash.Source -c 'echo ${BASH_VERSINFO[0]}') -lt 5) { 'the host bash predates 5.0; the guest profiles its payload through EPOCHREALTIME' }
        else { '' }
    # The host joins a copied execution log to its step through this reader.
    $diagnosticAst = [Management.Automation.Language.Parser]::ParseFile((Join-Path $here 'Test.Diagnostic.psm1'), [ref]$null, [ref]$null)
    $verdict = $diagnosticAst.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-GuestExecutionLogVerdict' }, $true)
    . ([scriptblock]::Create($verdict.Extent.Text))

    function Remove-ScenarioTmpPath {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Removes only /tmp paths of the recorder and profile shapes that a fixture run named for itself.')]
        [CmdletBinding()]
        param([AllowEmptyCollection()][string[]]$Path)
        foreach ($item in @($Path)) {
            if ($item -match '^/tmp/yuruna-fae-(?:recorder|profile)\.[A-Za-z0-9]+$') {
                Remove-Item -LiteralPath $item -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'A nested fetch-and-execute and the outer invocation whose payload started it' {
    BeforeAll {
        $script:Values = @{}
        $script:Logs = @{}
        $script:TmpPaths = [Collections.Generic.List[string]]::new()
        $script:Output = ''
        if ($script:SkipReason) { return }
        $text = $script:ScriptText
        $libDecl = 'YURUNA_LIB_DIR=/usr/local/lib/yuruna'
        $logDecl = "fae_log='/tmp/yuruna-last-fetch-and-execute.log'"
        # A silent miss here would let a run write to the real system paths.
        if (-not $text.Contains($libDecl) -or -not $text.Contains($logDecl)) {
            throw 'fetch-and-execute.sh no longer declares the two system paths this harness redirects; update the harness before running it.'
        }
        $text = $text.Replace($libDecl, 'YURUNA_LIB_DIR="${FAE_TEST_LIB_DIR:?}"').Replace($logDecl, 'fae_log="${FAE_TEST_LOG:?}"')
        $work = Join-Path $TestDrive 'nested'
        foreach ($folder in 'bin', 'lib', 'payloads') { $null = New-Item -ItemType Directory -Force -Path (Join-Path $work $folder) }
        $files = [ordered]@{
            'fae.sh'                = $text
            'lib/yuruna-retry.sh'   = ''
            'bin/clear'             = "#!/bin/bash`nexit 0`n"
            'bin/sudo'              = "#!/bin/bash`nexit 1`n"
            # The recorder's samples are not under test; an instant collector
            # keeps each run short and leaves the host's processes unread.
            'bin/timeout'           = "#!/bin/bash`nexit 0`n"
            'bin/wget'              = @'
#!/bin/bash
out='' url=''
while [ $# -gt 0 ]; do
    case "$1" in
        -qO|-O) out=$2; shift ;;
        -*) ;;
        *) url=$1 ;;
    esac
    shift
done
name=${url%%\?*}; name=${name##*/}
[ -n "$out" ] && [ -f "$FAE_TEST_PAYLOADS/$name" ] || exit 8
cat -- "$FAE_TEST_PAYLOADS/$name" > "$out"
'@
            # The generated wrappers delegate the same way, through exec; the
            # outer payload continues here so it can look afterwards.
            'payloads/parent.sh'    = @'
recorder=$(sed -n 's/^# recorder: *//p' "$FAE_TEST_LOG" | head -n 1)
profile=$(sed -n 's/^# profile: *//p' "$FAE_TEST_LOG" | head -n 1)
printf 'PARENT_RECORDER=%s\nPARENT_PROFILE=%s\n' "$recorder" "$profile"
E_SHA=$FAE_TEST_CHILD_SHA bash "$FAE_TEST_SCRIPT" guest/child.sh
if [ -n "$recorder" ] && [ -d "$recorder" ]; then echo PARENT_RECORDER_AFTER_NESTED=present; else echo PARENT_RECORDER_AFTER_NESTED=absent; fi
if [ -n "$profile" ] && [ -f "$profile" ]; then echo PARENT_PROFILE_AFTER_NESTED=present; else echo PARENT_PROFILE_AFTER_NESTED=absent; fi
'@
            'payloads/child.sh'     = @'
printf 'CHILD_RECORDER=%s\n' "$(sed -n 's/^# recorder: *//p' "$FAE_TEST_LOG" | head -n 1)"
printf 'CHILD_PROFILE=%s\n' "$(sed -n 's/^# profile: *//p' "$FAE_TEST_LOG" | head -n 1)"
'@
            'payloads/next.sh'      = @'
printf 'NEXT_RECORDER=%s\n' "$(sed -n 's/^# recorder: *//p' "$FAE_TEST_LOG" | head -n 1)"
'@
            'payloads/blocker.sh'   = @'
: > "$FAE_TEST_WORK/blocker.started"
sleep 60
'@
        }
        foreach ($name in $files.Keys) {
            [IO.File]::WriteAllText((Join-Path $work $name), $files[$name].Replace("`r`n", "`n"))
        }
        $driver = @'
set -u
unset E_SHA EXEC_SHA256 E_RETRY_SHA EXEC_RETRY_SHA256 EXEC_REQUIRE_SHA256 EXEC_ALLOW_UNVERIFIED \
      E_FB_REPO E_FB_REF EXEC_FALLBACK_REPO EXEC_FALLBACK_REF YURUNA_GITHUB_REPO YURUNA_GITHUB_REF \
      EXEC_BASE_URL EXEC_QUERY_PARAMS YurunaCacheContent GH_TOKEN E_SI E_QI E_RECORDER_URL E_RECORDER_PATH \
      EXEC_PROFILE EXEC_KEEP_PROFILE EXEC_RECORDER EXEC_RECORDER_MAX_SAMPLES EXEC_KERNEL_RECORDER \
      FAE_INVOCATION_SCRIPT YURUNA_STATUS_SERVICE_IP YURUNA_STATUS_SERVICE_PORT YURUNA_CACHING_PROXY_SERVICE_IP
work='__WORK__'
log="$work/fae.log"
chmod +x "$work/bin/"*
digest() { sha256sum -- "$work/payloads/$1" | awk '{print $1}'; }
state() { if [ -n "$1" ] && [ -e "$1" ]; then echo present; else echo absent; fi; }
first() { sed -n "s/^# $1: *//p" "$log" | head -n 1; }
value() { sed -n "s/^$1=//p" "$work/$2.out" | head -n 1; }
# A recorder's last write is its stopped status. Removing a folder it still
# writes into can leave that folder behind, so each one is let finish first.
settle() {
    local tick
    [ -n "$1" ] || return 0
    for ((tick=0; tick<200; tick++)); do
        [ -d "$1" ] || return 0
        grep -q '^state=stopped' "$1/status" 2>/dev/null && return 0
        sleep 0.1
    done
    echo "RECORDER_STILL_RUNNING=$1"
}
common=(PATH="$work/bin:$PATH" EXEC_BASE_URL=http://stub.invalid/yuruna-repo/ YURUNA_FETCH_IPV4_WAIT=0
    EXEC_KERNEL_RECORDER=0 EXEC_RECORDER_INTERVAL_SECONDS=1
    FAE_TEST_LIB_DIR="$work/lib" FAE_TEST_LOG="$log" FAE_TEST_PAYLOADS="$work/payloads"
    FAE_TEST_SCRIPT="$work/fae.sh" FAE_TEST_WORK="$work" FAE_TEST_CHILD_SHA="$(digest child.sh)")
run() {   # run <NAME> <payload> <step>: one top-level invocation, as a host step starts it
    local rc=0
    env "${common[@]}" E_SHA="$(digest "$2")" E_SI="$3" E_QI="$3-sequence" \
        bash "$work/fae.sh" "guest/$2" </dev/null >"$work/$1.out" 2>"$work/$1.err" || rc=$?
    cp -- "$log" "$work/$1.log"
    echo "$1_RC=$rc"
}

run PARENT parent.sh nested-step
parent_recorder=$(value PARENT_RECORDER PARENT)
child_recorder=$(value CHILD_RECORDER PARENT)
grep -E '^(PARENT|CHILD)_[A-Z_]+=' "$work/PARENT.out"
settle "$parent_recorder"; settle "$child_recorder"
echo "PARENT_RECORDER_AFTER_PARENT=$(state "$parent_recorder")"
echo "PARENT_STOP_AFTER_PARENT=$(state "$parent_recorder/stop")"
if grep -qs 'No such file or directory' "$work/PARENT.out" "$work/PARENT.err"; then echo PARENT_PATH_ERROR=yes; else echo PARENT_PATH_ERROR=no; fi
echo "LOG_FIRST_RECORDER=$(first recorder)"
echo "LOG_FIRST_PROFILE=$(first profile)"

run NEXT next.sh next-step
next_recorder=$(value NEXT_RECORDER NEXT)
settle "$next_recorder"
echo "NEXT_RECORDER=$next_recorder"
echo "NEXT_LOG_FIRST_RECORDER=$(first recorder)"
echo "PARENT_RECORDER_AFTER_NEXT=$(state "$parent_recorder")"
echo "CHILD_RECORDER_AFTER_NEXT=$(state "$child_recorder")"
echo "NEXT_RECORDER_AFTER_NEXT=$(state "$next_recorder")"
if grep -qsF -e "${parent_recorder:-unnamed}" -e "${child_recorder:-unnamed}" "$log"; then echo NEXT_LOG_NAMES_ENDED_RUNS=yes; else echo NEXT_LOG_NAMES_ENDED_RUNS=no; fi

# A run budget ends an invocation with TERM to its whole process group.
set -m
env "${common[@]}" E_SHA="$(digest blocker.sh)" E_SI=killed-step E_QI=killed-step-sequence \
    bash "$work/fae.sh" guest/blocker.sh </dev/null >"$work/KILLED.out" 2>"$work/KILLED.err" &
killed=$!
set +m
for ((tick=0; tick<300; tick++)); do [ -e "$work/blocker.started" ] && break; sleep 0.1; done
cp -- "$log" "$work/KILLED.log"
killed_recorder=$(first recorder); killed_profile=$(first profile)
echo "KILLED_PAYLOAD_STARTED=$(state "$work/blocker.started")"
echo "KILLED_RECORDER_WHILE_RUNNING=$(state "$killed_recorder")"
echo "KILLED_PROFILE_WHILE_RUNNING=$(state "$killed_profile")"
kill -TERM -- "-$killed" 2>/dev/null
wait "$killed" 2>/dev/null
run AFTER next.sh after-step
settle "$(value NEXT_RECORDER AFTER)"
echo "KILLED_RECORDER_AFTER_NEXT=$(state "$killed_recorder")"
echo "KILLED_PROFILE_AFTER_NEXT=$(state "$killed_profile")"
'@
        try {
            $result = Invoke-YurunaTestShell -Body $driver.Replace('__WORK__', $work) -TimeoutSeconds 180
            $script:Output = $result.Output
            foreach ($line in ($result.Output -split "`r?`n")) {
                if ($line -match '^([A-Z][A-Z_]*)=(.*)$' -and -not $script:Values.ContainsKey($Matches[1])) { $script:Values[$Matches[1]] = $Matches[2] }
            }
            foreach ($name in 'PARENT', 'NEXT') { $script:Logs[$name] = [IO.File]::ReadAllText((Join-Path $work "$name.log")) }
        } finally {
            # Every path a run created is named in the output or log it left,
            # including those of a driver cut short by its time limit.
            foreach ($file in Get-ChildItem -LiteralPath $work -File -Include '*.out', '*.err', '*.log' -Recurse -ErrorAction SilentlyContinue) {
                foreach ($match in [regex]::Matches([IO.File]::ReadAllText($file.FullName), '/tmp/yuruna-fae-(?:recorder|profile)\.[A-Za-z0-9]+')) {
                    $script:TmpPaths.Add($match.Value)
                }
            }
        }
    }

    AfterAll { Remove-ScenarioTmpPath -Path $script:TmpPaths }

    It 'leaves the outer invocation''s recorder folder and profile in place while the nested one runs' {
        if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        $script:Values['PARENT_RC'] | Should -Be '0' -Because $script:Output
        $script:Values['PARENT_RECORDER'] | Should -Match '^/tmp/yuruna-fae-recorder\.[A-Za-z0-9]+$'
        $script:Values['PARENT_PROFILE'] | Should -Match '^/tmp/yuruna-fae-profile\.[A-Za-z0-9]+$'
        $script:Values['PARENT_RECORDER_AFTER_NESTED'] | Should -Be 'present' -Because 'the outer recorder still writes its samples there'
        $script:Values['PARENT_PROFILE_AFTER_NESTED'] | Should -Be 'present' -Because 'the outer payload still traces into it'
    }

    It 'lets the outer invocation stop its own recorder without a missing-path error' {
        if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        $script:Values['PARENT_STOP_AFTER_PARENT'] | Should -Be 'present'
        $script:Values['PARENT_PATH_ERROR'] | Should -Be 'no' -Because $script:Output
        $script:Output | Should -Not -Match 'RECORDER_STILL_RUNNING='
    }

    It 'still names the nested invocation''s own recorder and profile first, under the outer step''s identity' {
        if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        $script:Values['CHILD_RECORDER'] | Should -Match '^/tmp/yuruna-fae-recorder\.[A-Za-z0-9]+$'
        $script:Values['CHILD_RECORDER'] | Should -Not -Be $script:Values['PARENT_RECORDER']
        $script:Values['LOG_FIRST_RECORDER'] | Should -Be $script:Values['CHILD_RECORDER']
        $script:Values['LOG_FIRST_PROFILE'] | Should -Be $script:Values['CHILD_PROFILE']
        $verdict = Get-GuestExecutionLogVerdict -ExecutionLog $script:Logs['PARENT'] -ScriptPath 'guest/parent.sh' `
            -StepInvocationId 'nested-step' -SequenceInvocationId 'nested-step-sequence'
        $verdict.state | Should -Be 'current' -Because $verdict.reasonCode
    }

    It 'keeps both recorder folders until the next top-level invocation, which removes them' {
        if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        $script:Values['PARENT_RECORDER_AFTER_PARENT'] | Should -Be 'present' -Because 'the host may still read it until another step starts'
        $script:Values['NEXT_RC'] | Should -Be '0' -Because $script:Output
        $script:Values['PARENT_RECORDER_AFTER_NEXT'] | Should -Be 'absent'
        $script:Values['CHILD_RECORDER_AFTER_NEXT'] | Should -Be 'absent'
        $script:Values['NEXT_RECORDER_AFTER_NEXT'] | Should -Be 'present'
        $script:Values['NEXT_LOG_FIRST_RECORDER'] | Should -Be $script:Values['NEXT_RECORDER']
        $script:Values['NEXT_LOG_NAMES_ENDED_RUNS'] | Should -Be 'no' -Because 'paths of runs that have ended are not carried any further'
        $verdict = Get-GuestExecutionLogVerdict -ExecutionLog $script:Logs['NEXT'] -ScriptPath 'guest/next.sh' `
            -StepInvocationId 'next-step' -SequenceInvocationId 'next-step-sequence'
        $verdict.state | Should -Be 'current' -Because $verdict.reasonCode
    }

    It 'removes the recorder folder and profile of an invocation ended by TERM' {
        if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        $script:Values['KILLED_PAYLOAD_STARTED'] | Should -Be 'present' -Because $script:Output
        $script:Values['KILLED_RECORDER_WHILE_RUNNING'] | Should -Be 'present'
        $script:Values['KILLED_PROFILE_WHILE_RUNNING'] | Should -Be 'present'
        $script:Values['AFTER_RC'] | Should -Be '0' -Because $script:Output
        $script:Values['KILLED_RECORDER_AFTER_NEXT'] | Should -Be 'absent'
        $script:Values['KILLED_PROFILE_AFTER_NEXT'] | Should -Be 'absent'
    }
}

Describe 'Pruning the paths of a previous invocation by its owner' {
    BeforeAll {
        if (-not $script:SkipReason) {
            $script:PruneFunctions = Get-YurunaTestShellFunction -Text $script:ScriptText -Name @('fae_process_start', 'fae_prune_prior_invocation')
        }
        function Invoke-PruneFixture {
            param([string]$Body, [string]$Suffix)
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $root
            $prefix = "set -euo pipefail`n$($script:PruneFunctions)`nroot='$root'`nsuffix='$Suffix'`n"
            return Invoke-YurunaTestShell -Body ($prefix + $Body) -TimeoutSeconds 30
        }
    }

    It 'keeps a running owner''s paths from run to run and removes them once it has exited' {
        if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 10)
        try {
            $r = Invoke-PruneFixture -Suffix $suffix -Body @'
recorder=/tmp/yuruna-fae-recorder.L$suffix
profile=/tmp/yuruna-fae-profile.L$suffix
sleep 60 &
owner=$!
trap 'kill "$owner" 2>/dev/null || true' EXIT
start=$(fae_process_start "$owner")
mkdir "$recorder"; : > "$profile"
held() { if [ -e "$recorder" ] && [ -e "$profile" ]; then echo kept; elif [ -e "$recorder" ] || [ -e "$profile" ]; then echo partial; else echo removed; fi; }
named() { grep -cF -e "$recorder" -e "$profile" "$1" || true; }
printf '# Yuruna fetch-and-execute log\n# ---\n# owner: %s %s\n# profile:   %s\n# recorder: %s\n' "$owner" "$start" "$profile" "$recorder" > "$root/1.log"
# Each run writes what it kept into its own log, which the run after it reads.
fae_prune_prior_invocation "$root/1.log" > "$root/2.log"
echo "FIRST=$(held) $(named "$root/2.log")"
fae_prune_prior_invocation "$root/2.log" > "$root/3.log"
echo "SECOND=$(held) $(named "$root/3.log")"
kill "$owner"; wait "$owner" 2>/dev/null || true
fae_prune_prior_invocation "$root/3.log" > "$root/4.log"
echo "EXITED=$(held) $(named "$root/4.log")"
'@
            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match '(?m)^FIRST=kept 2$'
            $r.Output | Should -Match '(?m)^SECOND=kept 2$'
            $r.Output | Should -Match '(?m)^EXITED=removed 0$'
        } finally {
            Remove-ScenarioTmpPath -Path "/tmp/yuruna-fae-recorder.L$suffix", "/tmp/yuruna-fae-profile.L$suffix"
        }
    }

    It 'treats a running process with another start time as a finished invocation' {
        if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 10)
        try {
            $r = Invoke-PruneFixture -Suffix $suffix -Body @'
recorder=/tmp/yuruna-fae-recorder.M$suffix
carried=/tmp/yuruna-fae-recorder.C$suffix
profile=/tmp/yuruna-fae-profile.M$suffix
mkdir "$recorder" "$carried"; : > "$profile"
other=$(( $(fae_process_start $$) + 1 ))
printf '# owner: %s %s\n# profile:   %s\n# recorder: %s\n# retained: %s %s %s\n' \
    $$ "$other" "$profile" "$recorder" $$ "$other" "$carried" > "$root/recycled.log"
fae_prune_prior_invocation "$root/recycled.log" > "$root/next.log"
remaining=0
for path in "$recorder" "$carried" "$profile"; do [ ! -e "$path" ] || remaining=$((remaining + 1)); done
echo "REMAINING=$remaining NAMED=$(wc -l < "$root/next.log")"
'@
            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match '(?m)^REMAINING=0 NAMED=0$'
        } finally {
            Remove-ScenarioTmpPath -Path "/tmp/yuruna-fae-recorder.M$suffix", "/tmp/yuruna-fae-recorder.C$suffix", "/tmp/yuruna-fae-profile.M$suffix"
        }
    }

    It 'holds the paths it carries forward to the shape it removes' {
        if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 10)
        $decoy = "/tmp/yuruna-fae-recorder-decoy-$suffix"
        try {
            $r = Invoke-PruneFixture -Suffix $suffix -Body @'
decoy=/tmp/yuruna-fae-recorder-decoy-$suffix
mkdir "$decoy"
sleep 0 &
gone=$!
wait "$gone"
printf '# retained: %s %s %s\n' "$gone" 1 "$decoy" $$ "$(fae_process_start $$)" "$decoy" \
    "$gone" 1 /tmp/yuruna-fae-recorder.x/../../etc > "$root/shape.log"
fae_prune_prior_invocation "$root/shape.log" > "$root/next.log"
if [ -d "$decoy" ]; then echo DECOY=present; else echo DECOY=absent; fi
echo "NAMED=$(wc -l < "$root/next.log")"
'@
            $r.ExitCode | Should -Be 0 -Because $r.Output
            $r.Output | Should -Match '(?m)^DECOY=present$'
            $r.Output | Should -Match '(?m)^NAMED=0$'
        } finally {
            Remove-Item -LiteralPath $decoy -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Stopping a recorder whose folder is gone' {
    It 'writes the stop file when the folder exists and says nothing when it does not' {
        if ($script:SkipReason) { Set-ItResult -Skipped -Because $script:SkipReason; return }
        $function = Get-YurunaTestShellFunction -Text $script:ScriptText -Name @('fae_stop_recorder')
        $root = Join-Path $TestDrive 'stop'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'live-recorder')
        $r = Invoke-YurunaTestShell -TimeoutSeconds 30 -Body @"
set -euo pipefail
$function
fae_recorder_folder='$root/removed-recorder'
fae_stop_recorder
echo "GONE_RC=`$?"
fae_recorder_folder='$root/live-recorder'
fae_stop_recorder
if [ -e "`$fae_recorder_folder/stop" ]; then echo LIVE_STOP=present; else echo LIVE_STOP=absent; fi
"@
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -BeExactly "GONE_RC=0`nLIVE_STOP=present"
    }
}
