<#PSScriptInfo
.VERSION 2026.10.11.1
.GUID 42e157fc-5dda-4b28-a498-afaf9bcafda2
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test diagnostic kernel recorder journal pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.EXTERNALMODULEDEPENDENCIES Pester
#>

#requires -version 7

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    Import-Module powershell-yaml -ErrorAction Stop
    $script:SeedSources = @{}
    foreach ($name in 'ubuntu.server', 'amazon.linux.2023') {
        $script:SeedSources[$name] = Get-Content -LiteralPath (Join-Path $script:RepoRoot "host/vmconfig/$name.base.user-data") -Raw
    }
    function Get-KernelRecorderSource {
        $source = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'automation/fetch-and-execute.sh') -Raw
        $redact = [regex]::Match($source, '(?ms)^fae_recorder_redact\(\) \{.*?^\}').Value
        $functions = foreach ($name in 'collect', 'upload', 'loop', 'start_kernel_recorder') {
            $functionName = if ($name -eq 'start_kernel_recorder') { 'fae_start_kernel_recorder' } else { "fae_kernel_$name" }
            $match = [regex]::Match($source, "(?ms)^$functionName\(\) \{.*?^\}")
            if (-not $match.Success) { throw "Missing actual kernel recorder function $functionName" }
            $match.Value
        }
        return $redact + "`n" + ($functions -join "`n")
    }
    function Invoke-KernelFixture {
        param([string]$Body, [int]$TimeoutSeconds = 10)
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $folder
        $driver = Join-Path $folder 'driver.sh'
        $prefix = @'
set -uo pipefail
export FAE_TEST_FOLDER='__FOLDER__'
mkdir -p "$FAE_TEST_FOLDER/ring" "$FAE_TEST_FOLDER/bin"
E_SI=kernel-fixture
E_QI=sequence-fixture
E_RECORDER_URL=http://fixture:8080/diagnostics/cycle/vm/kernel.system.diagnostic.step.txt
cat > "$FAE_TEST_FOLDER/bin/wget" <<'WGET'
#!/bin/bash
    for arg in "$@"; do case "$arg" in --post-file=*) source=${arg#--post-file=} ;; esac; done
    printf 'attempt\n' >> "$FAE_TEST_FOLDER/attempts.txt"
    if [ "${FAE_TEST_FAIL_FIRST:-0}" = 1 ] && [ ! -e "$FAE_TEST_FOLDER/failed-first" ]; then
        : > "$FAE_TEST_FOLDER/failed-first"
        exit 1
    fi
    cat -- "$source" > "$FAE_TEST_FOLDER/last-upload.txt"
    printf 'upload\n' >> "$FAE_TEST_FOLDER/uploads.txt"
WGET
chmod +x "$FAE_TEST_FOLDER/bin/wget"
export PATH="$FAE_TEST_FOLDER/bin:$PATH"
'@
        [IO.File]::WriteAllText($driver, (Get-KernelRecorderSource) + "`n" + $prefix.Replace('__FOLDER__', $folder) + "`n" + $Body)
        $result = Invoke-BoundedNativeCommand -FilePath bash -ArgumentList @($driver) -TimeoutSeconds $TimeoutSeconds
        return @{ Folder=$folder; Result=$result }
    }
}

Describe 'Bounded persistent guest journal' {
    It 'configures Ubuntu and Amazon Linux with the same bounded journal and no console forwarding' {
        $ubuntu = $script:SeedSources['ubuntu.server']
        $ubuntuConfig = [regex]::Match($ubuntu, "(?ms)cat > /target/etc/systemd/journald.conf.d/60-yuruna-diagnostic.conf << 'EOF'\r?\n(?<config>.*?)^      EOF").Groups['config'].Value
        $amazonDoc = ConvertFrom-Yaml $script:SeedSources['amazon.linux.2023']
        $amazonFile = @($amazonDoc.write_files | Where-Object path -EQ '/etc/systemd/journald.conf.d/60-yuruna-diagnostic.conf')
        $amazonFile.Count | Should -Be 1
        $amazonFile[0].permissions | Should -Be '0644'
        $ubuntuConfig = ($ubuntuConfig -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join "`n"
        $amazonConfig = ($amazonFile[0].content -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join "`n"
        $ubuntuConfig | Should -BeExactly $amazonConfig
        $amazonConfig | Should -Match '(?m)^Storage=persistent$'
        $amazonConfig | Should -Match '(?m)^SystemMaxUse=32M$'
        $amazonConfig | Should -Match '(?m)^SystemKeepFree=256M$'
        $amazonConfig | Should -Match '(?m)^RuntimeMaxUse=8M$'
        $amazonConfig | Should -Match '(?m)^SyncIntervalSec=30s$'
        $amazonConfig | Should -Match '(?m)^ForwardToConsole=no$'
        $ubuntu | Should -Match 'mkdir -p /target/etc/systemd/journald.conf.d /target/var/log/journal'
        ($amazonDoc.runcmd -join "`n") | Should -Match 'mkdir -p /var/log/journal'
        ($amazonDoc.runcmd -join "`n") | Should -Match 'timeout --kill-after=1 10 systemctl restart systemd-journald.service && timeout --kill-after=1 10 journalctl --flush'
    }
}

Describe 'Kernel evidence uploads do not depend on SSH or the process collector' -Skip:(-not $IsLinux) {
    It 'uploads new kernel messages while full execution evidence remains stalled' {
        $fixture = Invoke-KernelFixture @'
printf 'heartbeatUtc=old-process-sample\nraw-process-evidence\n' > "$FAE_TEST_FOLDER/ring/evidence.txt"
fae_kernel_collect() { printf 'kernel blocked-task evidence %s\n' "$(date +%s%N)"; }
ssh() { printf 'SSH unexpectedly invoked\n' >&2; return 90; }
export -f ssh
fae_kernel_loop "$BASHPID" "$FAE_TEST_FOLDER/ring" 1 2
'@
        $fixture.Result.ExitCode | Should -Be 0 -Because $fixture.Result.StdErr
        $upload = Get-Content -LiteralPath (Join-Path $fixture.Folder 'last-upload.txt') -Raw
        $upload | Should -Match 'old-process-sample'
        $upload | Should -Match 'raw-process-evidence'
        $upload | Should -Match 'kernel blocked-task evidence'
        $upload | Should -Match 'kernelRecorderState=stopped'
        $upload | Should -Match 'kernelSampleIndex=1'
        @(Get-Content -LiteralPath (Join-Path $fixture.Folder 'uploads.txt')).Count | Should -Be 3
        $fixture.Result.StdErr | Should -Not -Match 'SSH unexpectedly'
    }

    It 'uploads the final slow sample when the payload stops before the first collection finishes' {
        $source = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'automation/fetch-and-execute.sh') -Raw
        $mainLoop = [regex]::Match($source, '(?ms)^fae_recorder_loop\(\) \{.*?^\}').Value
        $fixture = Invoke-KernelFixture -Body ($mainLoop + "`n" + @'
for name in guest_evidence_clock guest_evidence_safe_path guest_evidence_hash guest_evidence_revision guest_evidence_provenance guest_evidence_boot_metadata fae_recorder_read; do eval "$name() { :; }"; done
: > "$FAE_TEST_FOLDER/ring/metadata.txt"
fae_kernel_collect() { printf 'independent kernel message\n'; }
fae_recorder_collect() { printf 'full sample before delay\n'; sleep 2; printf 'full sample after delay\n'; }
fae_recorder_loop "$BASHPID" "$FAE_TEST_FOLDER/ring" 1 2 &
producer=$!
sleep 0.2
: > "$FAE_TEST_FOLDER/ring/stop"
wait "$producer"
for ((attempt=0; attempt<50; attempt++)); do
    if grep -q '^state=stopped' "$FAE_TEST_FOLDER/ring/kernel.status" 2>/dev/null; then break; fi
    sleep 0.1
done
'@) -TimeoutSeconds 12
        $fixture.Result.TimedOut | Should -BeFalse
        $fixture.Result.ExitCode | Should -Be 0 -Because $fixture.Result.StdErr
        $upload = Get-Content -LiteralPath (Join-Path $fixture.Folder 'last-upload.txt') -Raw
        $upload | Should -Match 'full sample after delay'
        $upload | Should -Match 'recorderState=stopped'
        $upload | Should -Match 'kernelRecorderState=stopped'
        $upload | Should -Not -Match 'executionEvidence=not-yet-available'
        Test-Path -LiteralPath (Join-Path $fixture.Folder 'ring/recorder.finalized') | Should -BeTrue
    }

    It 'does not retransmit unchanged kernel and execution evidence on every tick' {
        $fixture = Invoke-KernelFixture @'
fae_kernel_collect() { printf 'same kernel message\n'; }
fae_kernel_loop "$BASHPID" "$FAE_TEST_FOLDER/ring" 0 4
'@
        $fixture.Result.ExitCode | Should -Be 0 -Because $fixture.Result.StdErr
        @(Get-Content -LiteralPath (Join-Path $fixture.Folder 'uploads.txt')).Count | Should -Be 2
    }

    It 'sends a bounded heartbeat even when kernel and full execution evidence do not change' {
        $fixture = Invoke-KernelFixture @'
fae_kernel_collect() { printf 'same kernel message while full collector stalled\n'; }
fae_kernel_loop "$BASHPID" "$FAE_TEST_FOLDER/ring" 0 4 '' 0
'@
        $fixture.Result.ExitCode | Should -Be 0 -Because $fixture.Result.StdErr
        @(Get-Content -LiteralPath (Join-Path $fixture.Folder 'uploads.txt')).Count | Should -Be 5
        Get-Content -LiteralPath (Join-Path $fixture.Folder 'last-upload.txt') -Raw | Should -Match 'kernelHeartbeatUtc='
    }

    It 'retries unchanged evidence after a failed upload and deduplicates only successful delivery' {
        $fixture = Invoke-KernelFixture @'
export FAE_TEST_FAIL_FIRST=1
fae_kernel_collect() { printf 'same kernel message after temporary network loss\n'; }
fae_kernel_loop "$BASHPID" "$FAE_TEST_FOLDER/ring" 0 4
'@
        $fixture.Result.ExitCode | Should -Be 0 -Because $fixture.Result.StdErr
        @(Get-Content -LiteralPath (Join-Path $fixture.Folder 'attempts.txt')).Count | Should -Be 3
        @(Get-Content -LiteralPath (Join-Path $fixture.Folder 'uploads.txt')).Count | Should -Be 2
        Get-Content -LiteralPath (Join-Path $fixture.Folder 'last-upload.txt') -Raw | Should -Match 'kernelRecorderState=stopped'
    }

    It 'retains partial kernel output and kills a stalled collector within its bounded budget' {
        $fixture = Invoke-KernelFixture @'
fae_kernel_collect() { printf 'kernel message before journal read stalled\n'; trap '' TERM; while :; do sleep 1; done; }
fae_kernel_loop "$BASHPID" "$FAE_TEST_FOLDER/ring" 0 1
'@
        $fixture.Result.TimedOut | Should -BeFalse
        $fixture.Result.ExitCode | Should -Be 0 -Because $fixture.Result.StdErr
        $upload = Get-Content -LiteralPath (Join-Path $fixture.Folder 'last-upload.txt') -Raw
        $upload | Should -Match 'kernel message before journal read stalled'
        $upload | Should -Match 'kernelSampleExitCode=(124|137)'
        $upload | Should -Match 'kernelRecorderState=stopped'
    }

    It 'caps the kernel ring, redacts known secrets, and never sends its environment' {
        $fixture = Invoke-KernelFixture @'
export GH_TOKEN=known-kernel-secret
fae_kernel_collect() { printf 'ordinary message\nknown-kernel-secret\n'; yes 'ordinary kernel message'; }
fae_kernel_loop "$BASHPID" "$FAE_TEST_FOLDER/ring" 0 5
'@
        $fixture.Result.ExitCode | Should -Be 0 -Because $fixture.Result.StdErr
        $upload = Get-Content -LiteralPath (Join-Path $fixture.Folder 'last-upload.txt') -Raw
        $upload | Should -Not -Match 'known-kernel-secret'
        $upload | Should -Match '\[REDACTED SECRET\]'
        $upload | Should -Match 'kernelSampleTruncated=true'
        @(Get-ChildItem -LiteralPath (Join-Path $fixture.Folder 'ring') -Filter 'kernel.sample.*').Count | Should -Be 4
        (Get-Item -LiteralPath (Join-Path $fixture.Folder 'ring/kernel.evidence.txt')).Length | Should -BeLessThan 140000
        @(Get-ChildItem -LiteralPath (Join-Path $fixture.Folder 'ring') -Filter 'kernel-upload.*').Count | Should -Be 0
    }

    It 'stops sampling after its owner has gone and retains a final host upload' {
        $fixture = Invoke-KernelFixture @'
fae_kernel_collect() { printf 'kernel message with owner gone\n'; }
fae_kernel_loop 2147483647 "$FAE_TEST_FOLDER/ring" 0 5
'@
        $fixture.Result.ExitCode | Should -Be 0 -Because $fixture.Result.StdErr
        Get-Content -LiteralPath (Join-Path $fixture.Folder 'ring/kernel.status') -Raw | Should -Match 'state=stopped samples=1 upload=complete'
        Get-Content -LiteralPath (Join-Path $fixture.Folder 'last-upload.txt') -Raw | Should -Match 'kernelRecorderState=stopped'
    }

    It 'leaves the main uploader available when kernel capture is disabled or unavailable' {
        $fixture = Invoke-KernelFixture @'
EXEC_KERNEL_RECORDER=0
if fae_start_kernel_recorder "$BASHPID" "$FAE_TEST_FOLDER/ring"; then exit 91; fi
unset EXEC_KERNEL_RECORDER
command() { if [ "$1" = -v ] && [ "$2" = journalctl ]; then return 1; fi; builtin command "$@"; }
if fae_start_kernel_recorder "$BASHPID" "$FAE_TEST_FOLDER/ring"; then exit 92; fi
printf 'kernel unavailable without startup side effects\n'
'@
        $fixture.Result.ExitCode | Should -Be 0 -Because $fixture.Result.StdErr
        Test-Path -LiteralPath (Join-Path $fixture.Folder 'ring/kernel.status') | Should -BeFalse
        $fixture.Result.StdOut | Should -Match 'kernel unavailable without startup side effects'
    }
}
