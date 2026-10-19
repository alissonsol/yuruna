<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 42fceff5-e96e-4072-9219-6ca416d6489c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test diagnostic pester
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
    Exercises live worker enumeration, clock evidence, and guest materialization identity.
#>

BeforeAll {
    $script:repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:wrapper = Get-Content (Join-Path $script:repo 'automation/fetch-and-execute.sh') -Raw
    $script:snapshot = Join-Path $script:repo 'automation/guest-performance-snapshot.sh'
    $script:snapshotText = Get-Content $script:snapshot -Raw
    $begin = $script:wrapper.IndexOf('fae_recorder_redact()')
    $end = $script:wrapper.IndexOf("fae_recorder_folder=''")
    $script:recorderFunctions = $script:wrapper.Substring($begin, $end-$begin)
    $script:metadataFunctions = foreach ($text in @($script:wrapper,$script:snapshotText)) {
        $begin = $text.IndexOf('# --- REGION: guest_evidence_clock')
        $end = if ($text -eq $script:wrapper) { $text.IndexOf('# shellcheck disable=SC2317 # Invoked in the exported collector child shell.', $begin) }
            else { $text.IndexOf('# --- REGION: Clock correlation', $begin) }
        $text.Substring($begin,$end-$begin)
    }
    function Invoke-GuestMetadataFixture {
        param([string]$Functions,[string]$Fixture,[string]$FixtureHome)
        $path = Join-Path $TestDrive ('metadata-'+[guid]::NewGuid().ToString('N')+'.sh')
        $preamble = "export HOME='$FixtureHome'`nunset SUDO_USER`n"
        [IO.File]::WriteAllText($path,$preamble+$Functions+"`n"+$Fixture)
        $output = (& bash $path 2>&1) -join "`n"
        $LASTEXITCODE | Should -Be 0 -Because $output
        return $output
    }
    function Get-GuestFixtureHome {
        $fixtureHome = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory((Join-Path $fixtureHome 'yuruna/project/tools'))
        return $fixtureHome
    }
}

Describe 'Guest archive and clone provenance' {
    It 'reports independent archive revisions and exact helper digests without source text' -Skip:(-not $IsLinux) {
        $fixtureHome = Get-GuestFixtureHome
        $framework = 'a'*40
        $project = 'b'*40
        [IO.File]::WriteAllText((Join-Path $fixtureHome 'yuruna/.yuruna-revision'),"$framework`n")
        [IO.File]::WriteAllText((Join-Path $fixtureHome 'yuruna/project/.yuruna-revision'),"$project`n")
        $helper = Join-Path $fixtureHome 'yuruna/project/tools/example-workload.sh'
        [IO.File]::WriteAllText($helper,"# helper`nprintf 'private-source-content'`n")
        $digest = (Get-FileHash $helper -Algorithm SHA256).Hash.ToLowerInvariant()
        foreach ($functions in $script:metadataFunctions) {
            $output = Invoke-GuestMetadataFixture -Functions $functions -Fixture 'guest_evidence_provenance' -FixtureHome $fixtureHome
            $output | Should -Match "guestProvenance.framework.revision=$framework"
            $output | Should -Match "guestProvenance.project.revision=$project"
            $output | Should -Match 'guestProvenance.project.revisionSource=archive'
            $output | Should -Match "guestProvenance.project.tools/example-workload.sh.sha256=$digest"
            $output | Should -Not -Match 'private-source-content'
        }
    }

    It 'hashes each installed helper at the path the seed installs it' -Skip:(-not $IsLinux) {
        $seed = Get-Content (Join-Path $script:repo 'host/vmconfig/ubuntu.server.base.user-data') -Raw
        $installed = @([regex]::Matches($seed, '> /target(/usr/local/[^\s]+)') | ForEach-Object { $_.Groups[1].Value })
        $expected = [ordered]@{
            'fetch-and-execute.sh'    = '/usr/local/lib/yuruna/fetch-and-execute.sh'
            'yuruna-retry.sh'         = '/usr/local/lib/yuruna/yuruna-retry.sh'
            'yuruna-fetch-context.sh' = '/usr/local/bin/yfe'
        }
        foreach ($path in $expected.Values) { $installed | Should -Contain $path -Because 'the seed installs every hashed helper' }
        $fixture = "guest_evidence_hash() { printf 'HASH %s %s\n' `"`$1`" `"`$2`"; }`nguest_evidence_provenance"
        foreach ($functions in $script:metadataFunctions) {
            $output = Invoke-GuestMetadataFixture -Functions $functions -Fixture $fixture -FixtureHome (Get-GuestFixtureHome)
            foreach ($name in $expected.Keys) {
                $output | Should -Match ('(?m)^HASH installed\.{0} {1}$' -f [regex]::Escape($name), [regex]::Escape($expected[$name]))
            }
        }
    }

    It 'records clone HEAD without mistaking a parent checkout for a project checkout' -Skip:(-not $IsLinux) {
        $fixtureHome = Get-GuestFixtureHome
        $frameworkRoot = Join-Path $fixtureHome 'yuruna'
        & git -c init.defaultBranch=main init --quiet $frameworkRoot
        & git -C $frameworkRoot -c user.name=Fixture -c user.email=fixture@example.invalid -c core.hooksPath=/dev/null commit --quiet --allow-empty -m fixture
        $LASTEXITCODE | Should -Be 0
        $revision = (& git -C $frameworkRoot rev-parse HEAD).Trim()
        foreach ($functions in $script:metadataFunctions) {
            $output = Invoke-GuestMetadataFixture -Functions $functions -Fixture 'guest_evidence_provenance' -FixtureHome $fixtureHome
            $output | Should -Match "guestProvenance.framework.revision=$revision"
            $output | Should -Match 'guestProvenance.framework.revisionSource=git'
            $output | Should -Match 'guestProvenance.project.revision=unavailable'
            $output | Should -Not -Match "guestProvenance.project.revision=$revision"
        }
        $projectRoot = Join-Path $frameworkRoot 'project'
        & git -c init.defaultBranch=main init --quiet $projectRoot
        & git -C $projectRoot -c user.name=Fixture -c user.email=fixture@example.invalid -c core.hooksPath=/dev/null commit --quiet --allow-empty -m project-fixture
        $projectRevision = (& git -C $projectRoot rev-parse HEAD).Trim()
        foreach ($functions in $script:metadataFunctions) {
            (Invoke-GuestMetadataFixture -Functions $functions -Fixture 'guest_evidence_provenance' -FixtureHome $fixtureHome) | Should -Match "guestProvenance.project.revision=$projectRevision"
        }
    }

    It 'prefers owned Git HEAD over a stale archive marker and supports an owned worktree' -Skip:(-not $IsLinux) {
        $fixtureHome = Get-GuestFixtureHome
        $frameworkRoot = Join-Path $fixtureHome 'yuruna'
        & git -c init.defaultBranch=main init --quiet $frameworkRoot
        & git -C $frameworkRoot -c user.name=Fixture -c user.email=fixture@example.invalid -c core.hooksPath=/dev/null commit --quiet --allow-empty -m fixture
        $revision = (& git -C $frameworkRoot rev-parse HEAD).Trim()
        [IO.File]::WriteAllText((Join-Path $frameworkRoot '.yuruna-revision'),('c'*40))
        $projectRoot = Join-Path $frameworkRoot 'project'
        Remove-Item $projectRoot -Recurse -Force
        & git -C $frameworkRoot -c core.hooksPath=/dev/null worktree add --quiet --detach $projectRoot HEAD
        $LASTEXITCODE | Should -Be 0
        (Get-Item (Join-Path $projectRoot '.git') -Force).PSIsContainer | Should -BeFalse
        foreach ($functions in $script:metadataFunctions) {
            $output = Invoke-GuestMetadataFixture -Functions $functions -Fixture 'guest_evidence_provenance' -FixtureHome $fixtureHome
            $output | Should -Match "guestProvenance.framework.revision=$revision"
            $output | Should -Match 'guestProvenance.framework.revisionSource=git'
            $output | Should -Match "guestProvenance.project.revision=$revision"
            $output | Should -Match 'guestProvenance.project.revisionSource=git'
            $output | Should -Not -Match ('guestProvenance.framework.revision='+('c'*40))
        }
    }

    It 'rejects malformed revision text and symlinked metadata or helpers' -Skip:(-not $IsLinux) {
        $fixtureHome = Get-GuestFixtureHome
        $revision = Join-Path $fixtureHome 'yuruna/project/.yuruna-revision'
        [IO.File]::WriteAllText($revision,'password=private-invalid-revision')
        foreach ($functions in $script:metadataFunctions) {
            $output = Invoke-GuestMetadataFixture -Functions $functions -Fixture 'guest_evidence_provenance' -FixtureHome $fixtureHome
            $output | Should -Match 'guestProvenance.project.revisionSource=invalid-archive'
            $output | Should -Not -Match 'private-invalid-revision'
        }
        [IO.File]::WriteAllText($revision,('d'*40)+("`n"*216)+'private-trailing-revision-content')
        foreach ($functions in $script:metadataFunctions) {
            $output = Invoke-GuestMetadataFixture -Functions $functions -Fixture 'guest_evidence_provenance' -FixtureHome $fixtureHome
            $output | Should -Match 'guestProvenance.project.revisionSource=invalid-archive'
            $output | Should -Match 'guestProvenance.project.revision=unavailable'
            $output | Should -Not -Match ('guestProvenance.project.revision='+('d'*40))
            $output | Should -Not -Match 'private-trailing-revision-content'
        }
        Remove-Item $revision -Force
        $privateFile = Join-Path $fixtureHome 'private.txt'
        [IO.File]::WriteAllText($privateFile,'private-file-content')
        & ln -s $privateFile $revision
        & ln -s $privateFile (Join-Path $fixtureHome 'yuruna/project/tools/example-workload.sh')
        foreach ($functions in $script:metadataFunctions) {
            $output = Invoke-GuestMetadataFixture -Functions $functions -Fixture 'guest_evidence_provenance' -FixtureHome $fixtureHome
            $output | Should -Match 'guestProvenance.project.revisionSource=unsafe-path'
            $output | Should -Match 'guestProvenance.project.tools/example-workload.sh.sha256=unsafe-path'
            $output | Should -Not -Match 'private-file-content'
        }
    }

    It 'does not hash helpers reached through a symbolic-link directory' -Skip:(-not $IsLinux) {
        $fixtureHome = Get-GuestFixtureHome
        $outside = Join-Path $fixtureHome 'outside'
        [void][IO.Directory]::CreateDirectory($outside)
        [IO.File]::WriteAllText((Join-Path $outside 'example-workload.sh'),'private-outside-content')
        Remove-Item (Join-Path $fixtureHome 'yuruna/project/tools')
        & ln -s $outside (Join-Path $fixtureHome 'yuruna/project/tools')
        foreach ($functions in $script:metadataFunctions) {
            $output = Invoke-GuestMetadataFixture -Functions $functions -Fixture 'guest_evidence_provenance' -FixtureHome $fixtureHome
            $output | Should -Match 'guestProvenance.project.tools/example-workload.sh.sha256=unsafe-path'
            $output | Should -Not -Match 'private-outside-content'
        }
    }

    It 'bounds source hashing and rejects payload traversal outside the materialization' -Skip:(-not $IsLinux) {
        $fixtureHome = Get-GuestFixtureHome
        [IO.File]::WriteAllText((Join-Path $fixtureHome 'yuruna/project/tools/example-workload.sh'),('x'*4194305))
        foreach ($functions in $script:metadataFunctions) {
            $output = Invoke-GuestMetadataFixture -Functions $functions -Fixture 'FILE_PATH=../private; guest_evidence_provenance' -FixtureHome $fixtureHome
            $output | Should -Match 'guestProvenance.project.tools/example-workload.sh.sha256=size-unavailable-or-over-4194304'
            $output | Should -Not -Match 'guestProvenance.localPayload.sha256='
        }
    }
}

Describe 'Fetched and executed payload provenance' {
    It 'records exact downloaded and effective shell digests before successful payload execution' -Skip:(-not $IsLinux) {
        $fixtureHome = Get-GuestFixtureHome
        $payload = Join-Path $TestDrive 'payload.sh'
        [IO.File]::WriteAllText($payload,"printf 'ordinary-output\\n'`n`n")
        $downloaded = (Get-FileHash $payload -Algorithm SHA256).Hash.ToLowerInvariant()
        $effective = Join-Path $TestDrive 'effective-payload.sh'
        [IO.File]::WriteAllText($effective,(Get-Content $payload -Raw).TrimEnd("`n"))
        $executed = (Get-FileHash $effective -Algorithm SHA256).Hash.ToLowerInvariant()
        $downloaded | Should -Not -Be $executed
        $log = Join-Path $TestDrive 'payload-execution.log'
        $copy = Join-Path $TestDrive 'fetch-and-execute-copy.sh'
        [IO.File]::WriteAllText($copy,$script:wrapper.Replace("fae_log='/tmp/yuruna-last-fetch-and-execute.log'","fae_log='$log'"))
        $driver = Join-Path $TestDrive 'payload-driver.sh'
        $fixture = @'
export HOME='__HOME__'
unset SUDO_USER
export EXEC_BASE_URL=http://fixture/ E_SHA=__HASH__ EXEC_PROFILE=0 EXEC_RECORDER=0 E_SI=payload-provenance
wget() {
    local output='' argument
    for argument in "$@"; do
        case "$argument" in -qO) ;; /tmp/yuruna-fae-payload.*) output=$argument;; *automation/yuruna-retry.sh*) return 4;; esac
    done
    [ -n "$output" ] || return 4
    cp '__PAYLOAD__' "$output"
}
clear() { :; }
export -f wget clear
bash '__WRAPPER__' guest/test.sh
'@
        [IO.File]::WriteAllText($driver,$fixture.Replace('__HOME__',$fixtureHome).Replace('__HASH__',$downloaded).Replace('__PAYLOAD__',$payload).Replace('__WRAPPER__',$copy))
        $output = (& bash $driver 2>&1) -join "`n"
        $LASTEXITCODE | Should -Be 0 -Because $output
        $output | Should -Match 'ordinary-output'
        $header = Get-Content $log -Raw
        $header | Should -Match "fetchedPayloadSha256=$downloaded"
        $header | Should -Match "executedPayloadSha256=$executed"
        $header.IndexOf('fetchedPayloadSha256=') | Should -BeLessThan $header.IndexOf('ordinary-output') -Because 'The provenance header must precede payload output.'
    }
}

Describe 'Clock and memory sample capture' {
    It 'keeps both clock samples when optional boot metadata cannot complete' -Skip:(-not $IsLinux) {
        $probe = Join-Path $TestDrive 'clock-before-metadata.sh'
        $source = $script:snapshotText.Replace('# --- REGION: Clock correlation', @'
guest_evidence_boot_metadata() { printf 'metadata unavailable\n'; exit 124; }
export E_CLOCK_ONLY=1
# --- REGION: Clock correlation
'@)
        [IO.File]::WriteAllText($probe,$source)
        $output = (& bash $probe 2>&1) -join "`n"
        $LASTEXITCODE | Should -Be 124
        @([regex]::Matches($output,'(?m)^guestEvidenceSchema=2$')).Count | Should -Be 2
        $output | Should -Match '(?m)^cpu0\s+\d+'
        $output | Should -Not -Match 'snapshotCompleteUtc='
    }

    It 'retains timestamped interrupt counters before a later read interrupts each sample' -Skip:(-not $IsLinux) {
        foreach ($mode in 'recorder','snapshot') {
            $probe = Join-Path $TestDrive "early-interrupts-$mode.sh"
            $readName = if ($mode -eq 'recorder') { 'fae_recorder_read' } else { 'snapshot_read' }
            $stub = @'
__READ__() {
    if [ "$1" = /proc/meminfo ]; then exit 124; fi
    printf '\n--- %s ---\n' "$1"
    case "$1" in /proc/interrupts) printf '10: 100 200 arch_timer\n';; /proc/softirqs) printf 'TIMER: 10 20\n';; esac
}
'@.Replace('__READ__',$readName)
            $source = if ($mode -eq 'recorder') { $script:recorderFunctions+"`n"+$stub+"`nfae_recorder_collect" }
                else { $script:snapshotText.Replace('# --- REGION: Clock correlation',$stub+"`n# --- REGION: Clock correlation") }
            [IO.File]::WriteAllText($probe,$source)
            foreach ($sample in 1..2) {
                $output = (& bash $probe 2>&1) -join "`n"
                $LASTEXITCODE | Should -Be 124
                $output | Should -Match 'guestClockUtc=\d{4}-\d{2}-\d{2}T'
                $output | Should -Match '(?m)^10: 100 200 arch_timer$' -Because "$mode sample $sample must retain IRQ data before slower reads"
                $output | Should -Match '(?m)^TIMER: 10 20$'
            }
        }
    }

    It 'captures two independent CPU-accounting samples within the restart observation budget' -Skip:(-not $IsLinux) {
        $oldMode = $env:E_CLOCK_ONLY
        try {
            $env:E_CLOCK_ONLY = '1'
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $output = (& bash $script:snapshot 2>&1) -join "`n"
            $LASTEXITCODE | Should -Be 0
            $clock.Elapsed.TotalSeconds | Should -BeLessThan 3
            $samples = @([regex]::Split($output,'--- YURUNA CLOCK SAMPLE ---') | Select-Object -Skip 1)
            $samples.Count | Should -Be 2
            foreach ($sample in $samples) {
                $sample | Should -Match 'guestEvidenceSchema=2'
                $sample | Should -Match 'guestClockUtc=\d{4}-\d{2}-\d{2}T'
                $sample | Should -Match 'guestClockEpochSeconds=\d+\.\d+'
                $sample | Should -Match 'guestClockUptimeSeconds=\d+\.\d+'
                $sample | Should -Match 'guestClockUptimeClock=boottime'
                $sample | Should -Match 'guestClockTicksPerSecond=\d+'
                $sample | Should -Match 'guestBootId=[0-9a-f-]{36}'
                $sample | Should -Match 'guestOnlineCpus=[0-9,-]+'
                $sample | Should -Match '(?m)^cpu0\s+\d+\s+'
                $sample | Should -Not -Match 'per-thread CPU/state|kernel journal|guestProvenance'
            }
            $before = [double]([regex]::Match($samples[0],'guestClockUptimeSeconds=([0-9.]+)').Groups[1].Value)
            $after = [double]([regex]::Match($samples[1],'guestClockUptimeSeconds=([0-9.]+)').Groups[1].Value)
            ($after-$before) | Should -BeGreaterThan 0.8
            $output | Should -Match 'guestKernel=Linux'
            $output | Should -Match 'current_clocksource'
            $output | Should -Match 'topology/core_id'
            $output | Should -Match 'snapshotCompleteUtc='
        } finally { $env:E_CLOCK_ONLY = $oldMode }
    }

    It 'captures raw memory pressure and cgroup counters before stacks can exhaust a sample' -Skip:(-not $IsLinux) {
        $fixtureHome = Get-GuestFixtureHome
        $output = Invoke-GuestMetadataFixture -Functions $script:recorderFunctions -Fixture 'fae_recorder_collect' -FixtureHome $fixtureHome
        $output | Should -Match '/proc/meminfo'
        $output | Should -Match '/proc/vmstat'
        $output | Should -Match 'guestClockTicksPerSecond='
        $output | Should -Match 'MemTotal:'
        $output | Should -Match 'pgfault '
        if (Test-Path '/sys/fs/cgroup/memory.events') { $output | Should -Match '/sys/fs/cgroup/memory.events' }
        $output | Should -Match 'sampleCompleteUtc='
    }
}

Describe 'Live Linux worker-thread enumeration' {
    It 'retains every worker TID of a real five-thread process in recorder and snapshot inventories' -Skip:(-not $IsLinux) {
        if (-not (Get-Command python3 -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'Python 3 is required for the owned-thread fixture'; return }
        $functions = Join-Path $TestDrive 'recorder-functions.sh'
        [IO.File]::WriteAllText($functions,$script:recorderFunctions)
        $probe = Join-Path $TestDrive 'live-workers.py'
        [IO.File]::WriteAllText($probe,@'
import os, re, subprocess, sys, threading, time
stop = threading.Event()
tids = []
def worker():
    tids.append(threading.get_native_id())
    while not stop.wait(.01): pass
threads = [threading.Thread(target=worker, daemon=True) for _ in range(4)]
for thread in threads: thread.start()
while len(tids) < 4: time.sleep(.01)
owner = os.getpid()
env = dict(os.environ, DIAG_THREAD_PID=str(owner))
# Filtering preserves real procps flags and behavior while excluding unrelated
# host processes from the inventory's 64-row retention bound.
prefix = '''ps() { command ps "$@" | awk -v owner="$DIAG_THREAD_PID" '$1==owner'; }; export -f ps; '''
try:
    for target in ('recorder', 'snapshot'):
        command = prefix + ('source "$1"; fae_recorder_collect' if target == 'recorder' else 'bash "$1"')
        path = sys.argv[1] if target == 'recorder' else sys.argv[2]
        result = subprocess.run(['bash', '-c', command, 'fixture', path], env=env, text=True, capture_output=True, timeout=15)
        if result.returncode: raise AssertionError((target, result.returncode, result.stderr))
        found = set(int(x) for x in re.findall(r'^\s*%d\s+(\d+)\s+\d+\s+\d+(?:\.\d+)?\s+\S+\s+.+$' % owner, result.stdout, re.M))
        expected = {owner, *tids}
        if not expected <= found: raise AssertionError((target, expected, found, result.stdout))
        print('%s: %s real TIDs retained' % (target, len(expected)))
finally:
    stop.set()
    for thread in threads: thread.join(1)
'@)
        $output = (& python3 $probe $functions $script:snapshot 2>&1) -join "`n"
        $LASTEXITCODE | Should -Be 0 -Because $output
        $output | Should -Match 'recorder: 5 real TIDs retained'
        $output | Should -Match 'snapshot: 5 real TIDs retained'
    }
}
