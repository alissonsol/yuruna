<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42dbfc19-bf21-4ef5-ad59-a132755a721d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guest kubernetes readiness pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>

#requires -version 7

BeforeDiscovery {
    $script:CanRunOpenTofu = -not $IsWindows -and $null -ne (Get-Command bash -ErrorAction SilentlyContinue)
    $script:CanRunBootstrap = -not $IsWindows -and $null -ne (Get-Command bash -ErrorAction SilentlyContinue) -and
        $null -ne (Get-Command timeout -ErrorAction SilentlyContinue)
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    $script:K8sSources = @{}
    foreach ($version in '24', '26') {
        $script:K8sSources[$version] = Get-Content (Join-Path $script:RepoRoot "guest/shared/ubuntu.k8s.sh") -Raw
    }
    function Get-BootstrapFixture {
        param([string]$Version, [string]$Mode, [int]$WaitSeconds = 3)
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $fixture
        $source = $script:K8sSources[$Version]
        $begin = $source.IndexOf('wait_for_containerd() {')
        $end = $source.IndexOf("`n}`n", $begin)
        $helper = $source.Substring($begin, $end + 3 - $begin)
        $stub = @'
#!/bin/bash
printf 'probe\n' >> "$YURUNA_PROBE_CALLS"
case "$YURUNA_PROBE_MODE" in
    ready) printf '{"status":"ready"}\n'; exit 0 ;;
    delayed)
        [ "$(wc -l < "$YURUNA_PROBE_CALLS")" -ge 3 ] && exit 0
        echo 'CRI endpoint is starting' >&2; exit 17 ;;
    failed) echo 'CRI plugin unavailable: diagnostic fixture' >&2; exit 17 ;;
    blocked|deadline)
        trap '' TERM
        bash -c 'trap "" TERM; while true; do printf "tick\n" >> "$YURUNA_PROBE_HEARTBEAT"; sleep 0.1; done' &
        wait ;;
esac
'@
        Set-Content (Join-Path $fixture 'crictl') $stub
        Set-Content (Join-Path $fixture 'sudo') "#!/bin/bash`nexec `"`$@`""
        & chmod +x (Join-Path $fixture 'crictl') (Join-Path $fixture 'sudo')
        $prefix = @'
set -euo pipefail
export PATH="$YURUNA_PROBE_BIN:$PATH"
'@
        if ($Mode -eq 'missing') {
            $prefix += "`ncommand() { if [ `"`$1`" = -v ] && [ `"`$2`" = crictl ]; then return 1; fi; builtin command `"`$@`"; }`n"
        }
        if ($Mode -eq 'deadline') {
            # Simulate the second ticking between the loop condition and the probe budget.
            $prefix += @'

[() {
    if [[ "$#" == 4 && "$2" == -lt ]]; then
        builtin [ "$@" ] || return
        SECONDS="$3"
        return 0
    fi
    builtin [ "$@" ]
}
'@
        }
        $entrypoint = Join-Path $fixture 'probe.sh'
        Set-Content $entrypoint ($prefix + "`n" + $helper + "`nwait_for_containerd $WaitSeconds`nprintf 'downstream-init\n'`n")
        return @{
            EntryPoint = $entrypoint
            Calls = (Join-Path $fixture 'calls.txt')
            Heartbeat = (Join-Path $fixture 'heartbeat.txt')
            Environment = @{
                YURUNA_PROBE_BIN = $fixture
                YURUNA_PROBE_CALLS = (Join-Path $fixture 'calls.txt')
                YURUNA_PROBE_MODE = $Mode
                YURUNA_PROBE_HEARTBEAT = (Join-Path $fixture 'heartbeat.txt')
            }
        }
    }
}

Describe 'Containerd readiness is a bounded API check' -Skip:(-not $script:CanRunBootstrap) {
    It 'Ubuntu <Version> immediately proceeds when the CRI API answers' -ForEach @(@{ Version='24' }, @{ Version='26' }) {
        $fixture = Get-BootstrapFixture -Version $Version -Mode ready
        $result = Invoke-BoundedNativeCommand -FilePath bash -ArgumentList @($fixture.EntryPoint) -TimeoutSeconds 8 -Environment $fixture.Environment
        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        @(Get-Content $fixture.Calls).Count | Should -Be 1
        $result.StdOut | Should -Match 'containerd CRI API is ready[\r\n]+downstream-init'
        $result.StdOut | Should -Not -Match 'Waiting for'
    }

    It 'Ubuntu <Version> polls a starting API and proceeds only once it answers' -ForEach @(@{ Version='24' }, @{ Version='26' }) {
        $fixture = Get-BootstrapFixture -Version $Version -Mode delayed -WaitSeconds 5
        $result = Invoke-BoundedNativeCommand -FilePath bash -ArgumentList @($fixture.EntryPoint) -TimeoutSeconds 9 -Environment $fixture.Environment
        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        @(Get-Content $fixture.Calls).Count | Should -Be 3
        $result.StdOut | Should -Match 'downstream-init'
    }

    It 'Ubuntu <Version> stops before initialization and retains the failed API diagnostic' -ForEach @(@{ Version='24' }, @{ Version='26' }) {
        $fixture = Get-BootstrapFixture -Version $Version -Mode failed -WaitSeconds 2
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-BoundedNativeCommand -FilePath bash -ArgumentList @($fixture.EntryPoint) -TimeoutSeconds 8 -Environment $fixture.Environment
        $clock.Stop()
        $result.ExitCode | Should -Be 1
        $result.StdErr | Should -Match 'did not become ready within 2s.*last probe exit: 17'
        $result.StdErr | Should -Match 'CRI plugin unavailable: diagnostic fixture'
        $result.StdOut | Should -Not -Match 'downstream-init'
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 4
    }

    It 'Ubuntu <Version> bounds a blocked API and terminates its children' -ForEach @(@{ Version='24' }, @{ Version='26' }) {
        $fixture = Get-BootstrapFixture -Version $Version -Mode blocked -WaitSeconds 1
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-BoundedNativeCommand -FilePath bash -ArgumentList @($fixture.EntryPoint) -TimeoutSeconds 8 -Environment $fixture.Environment
        $clock.Stop()
        $result.ExitCode | Should -Be 1
        $result.TimedOut | Should -BeFalse
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 4
        $result.StdErr | Should -Match 'did not become ready within 1s'
        $result.StdOut | Should -Not -Match 'downstream-init'
        $before = (Get-Item $fixture.Heartbeat).Length
        Start-Sleep -Milliseconds 300
        (Get-Item $fixture.Heartbeat).Length | Should -Be $before
    }

    It 'Ubuntu <Version> never starts an unbounded zero-second probe when the deadline expires' -ForEach @(@{ Version='24' }, @{ Version='26' }) {
        $fixture = Get-BootstrapFixture -Version $Version -Mode deadline -WaitSeconds 1
        $result = Invoke-BoundedNativeCommand -FilePath bash -ArgumentList @($fixture.EntryPoint) -TimeoutSeconds 5 -Environment $fixture.Environment
        $result.ExitCode | Should -Be 1
        $result.TimedOut | Should -BeFalse
        Test-Path $fixture.Calls | Should -BeFalse
        $result.StdOut | Should -Not -Match 'downstream-init'
        $result.StdErr | Should -Match 'did not become ready within 1s'
    }

    It 'Ubuntu <Version> diagnoses a missing probe immediately' -ForEach @(@{ Version='24' }, @{ Version='26' }) {
        $fixture = Get-BootstrapFixture -Version $Version -Mode missing
        $result = Invoke-BoundedNativeCommand -FilePath bash -ArgumentList @($fixture.EntryPoint) -TimeoutSeconds 8 -Environment $fixture.Environment
        $result.ExitCode | Should -Be 1
        $result.StdErr | Should -Match 'requires installed cri-tools \(crictl\) and coreutils \(timeout\)'
        Test-Path $fixture.Calls | Should -BeFalse
        $result.StdOut | Should -Not -Match 'downstream-init'
    }
}

Describe 'Guest network readiness begins immediately and remains mandatory' -Skip:(-not $script:CanRunBootstrap) {
    It 'Ubuntu <Version> validates both successful and failed network readiness' -ForEach @(
        @{ Version='24'; Network='ready' }, @{ Version='26'; Network='ready' },
        @{ Version='24'; Network='failed' }, @{ Version='26'; Network='failed' }
    ) {
        $source = $script:K8sSources[$Version]
        $begin = $source.IndexOf('wait_for_kubernetes_network() {')
        $end = $source.IndexOf("`n}`n", $begin)
        $block = $source.Substring($begin, $end + 3 - $begin) + "`nwait_for_kubernetes_network`n"
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $fixture
        $prefix = @'
set -euo pipefail
REAL_HOME=/tmp/fixture
kubectl() {
    printf '%s\n' "$*" >> "$YURUNA_NETWORK_CALLS"
    if [[ "$*" == *'rollout status'* ]]; then
        # A real rollout wait can consume time while node readiness remains authoritative.
        [ "$YURUNA_NETWORK" = ready ] || return 1
    fi
    if [[ "$*" == *'wait --for=condition=ready'* ]]; then
        [ "$YURUNA_NETWORK" = ready ] || return 1
    fi
}
sleep() { echo 'unexpected fixed sleep' >&2; return 72; }
ls() { return 0; }
'@
        $entrypoint = Join-Path $fixture 'network.sh'
        Set-Content $entrypoint ($prefix + "`n" + $block + "`nprintf 'downstream-workload\n'`n")
        $calls = Join-Path $fixture 'calls.txt'
        $result = Invoke-BoundedNativeCommand -FilePath bash -ArgumentList @($entrypoint) -TimeoutSeconds 8 `
            -Environment @{ YURUNA_NETWORK_CALLS=$calls; YURUNA_NETWORK=$Network }
        $invocations = @(Get-Content $calls)
        $invocations[0] | Should -Match 'rollout status daemonset/kube-flannel-ds --timeout=180s'
        $invocations[1] | Should -Match 'wait --for=condition=ready node --all --timeout=180s'
        if ($Network -eq 'ready') {
            $result.ExitCode | Should -Be 0 -Because $result.StdErr
            $result.StdOut | Should -Match 'downstream-workload'
        } else {
            $result.ExitCode | Should -Be 1
            $result.StdErr | Should -Match 'node did not reach Ready within 180s'
            $result.StdOut | Should -Not -Match 'downstream-workload'
            $invocations | Should -Contain '--kubeconfig=/tmp/fixture/.kube/config get nodes -o wide'
        }
    }
}

Describe 'Existing cluster reset restores Docker bridge networking' -Skip:(-not $script:CanRunBootstrap) {
    It 'Ubuntu <Version> preserves reset ordering and fails closed for <Mode>' -ForEach @(
        @{ Version='24'; Mode='ready' }, @{ Version='26'; Mode='ready' },
        @{ Version='24'; Mode='cold' }, @{ Version='26'; Mode='cold' },
        @{ Version='24'; Mode='restart-failed' }, @{ Version='26'; Mode='restart-failed' },
        @{ Version='24'; Mode='engine-failed' }, @{ Version='26'; Mode='engine-failed' },
        @{ Version='24'; Mode='cri-failed' }, @{ Version='26'; Mode='cri-failed' }
    ) {
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $fixture
        $source = $script:K8sSources[$Version]
        $begin = $source.IndexOf('# Reset any existing kubeadm state')
        $end = $source.IndexOf('# Load kernel modules required by Kubernetes networking', $begin)
        $block = $source.Substring($begin, $end - $begin)
        $prefix = @'
set -euo pipefail
REAL_HOME="$YURUNA_RESET_HOME"
[() {
    if [[ "$#" == 3 && ( "$2" == /etc/kubernetes/manifests/kube-apiserver.yaml || "$2" == /etc/kubernetes/pki ) ]]; then
        [[ "$YURUNA_RESET_MODE" != cold ]]
        return
    fi
    builtin [ "$@"
}
command() {
    if [[ "$#" == 2 && "$1" == -v && "$2" == ipvsadm ]]; then return 1; fi
    builtin command "$@"
}
sudo() {
    printf '%s\n' "$*" >> "$YURUNA_RESET_CALLS"
    case "$*" in
        iptables*) : > "$YURUNA_RESET_HOME/firewall-dirty" ;;
        'timeout --kill-after=1 60 systemctl restart docker')
            if [[ "$YURUNA_RESET_MODE" == restart-failed ]]; then
                echo 'Docker restart fixture failed' >&2; return 27
            fi
            rm -f "$YURUNA_RESET_HOME/firewall-dirty" ;;
        'timeout --kill-after=1 10 docker info')
            if [[ "$YURUNA_RESET_MODE" == engine-failed ]]; then
                echo 'Docker engine fixture unavailable' >&2; return 29
            fi
            [[ ! -e "$YURUNA_RESET_HOME/firewall-dirty" ]] || return 31 ;;
        'kubeadm init '*)
            [[ ! -e "$YURUNA_RESET_HOME/firewall-dirty" ]] || return 32 ;;
    esac
    return 0
}
wait_for_containerd() {
    printf 'CRI readiness\n' >> "$YURUNA_RESET_CALLS"
    if [[ "$YURUNA_RESET_MODE" == cri-failed ]]; then
        echo 'CRI fixture unavailable' >&2; return 17
    fi
}
'@
        $entrypoint = Join-Path $fixture 'reset.sh'
        Set-Content $entrypoint ($prefix + "`n" + $block + "`nsudo kubeadm init --pod-network-cidr=10.244.0.0/16`nprintf 'downstream-workload\n'`n")
        $callsPath = Join-Path $fixture 'calls.txt'
        $result = Invoke-BoundedNativeCommand -FilePath bash -ArgumentList @($entrypoint) -TimeoutSeconds 8 `
            -Environment @{ YURUNA_RESET_HOME=$fixture; YURUNA_RESET_CALLS=$callsPath; YURUNA_RESET_MODE=$Mode }
        $calls = @(Get-Content $callsPath)
        $containerd = [array]::IndexOf($calls, 'systemctl restart containerd')
        $cri = [array]::IndexOf($calls, 'CRI readiness')
        $docker = [array]::IndexOf($calls, 'timeout --kill-after=1 60 systemctl restart docker')
        $engine = [array]::IndexOf($calls, 'timeout --kill-after=1 10 docker info')
        $init = [array]::IndexOf($calls, 'kubeadm init --pod-network-cidr=10.244.0.0/16')
        $containerd | Should -BeGreaterOrEqual 0
        $cri | Should -BeGreaterThan $containerd
        if ($Mode -eq 'cold') {
            $result.ExitCode | Should -Be 0 -Because $result.StdErr
            $calls | Should -Not -Contain 'iptables -F'
            $docker | Should -Be -1
            $engine | Should -Be -1
            $init | Should -BeGreaterThan $cri
            $result.StdOut | Should -Match 'downstream-workload'
        } else {
            [array]::IndexOf($calls, 'iptables -X') | Should -BeLessThan $containerd
            $calls | Should -Contain 'iptables -F'
            $calls | Should -Contain 'iptables -t nat -F'
            $calls | Should -Contain 'iptables -t mangle -F'
            if ($Mode -eq 'cri-failed') {
                $result.ExitCode | Should -Be 17
                $docker | Should -Be -1
                $engine | Should -Be -1
            } else {
                $docker | Should -BeGreaterThan $cri
                if ($Mode -eq 'restart-failed') {
                    $result.ExitCode | Should -Be 1
                    $result.StdErr | Should -Match 'Docker restart failed after Kubernetes firewall cleanup'
                    $engine | Should -Be -1
                } else {
                    $engine | Should -BeGreaterThan $docker
                    if ($Mode -eq 'engine-failed') {
                        $result.ExitCode | Should -Be 1
                        $result.StdErr | Should -Match 'Docker engine did not answer after Kubernetes firewall cleanup'
                    } else {
                        $result.ExitCode | Should -Be 0 -Because $result.StdErr
                        $init | Should -BeGreaterThan $engine
                        $result.StdOut | Should -Match 'downstream-workload'
                    }
                }
            }
            if ($Mode -ne 'ready') {
                $init | Should -Be -1
                $result.StdOut | Should -Not -Match 'downstream-workload'
            }
        }
    }
}

Describe 'Kubernetes bootstrap supplies its readiness probe' {
    It 'Ubuntu <Version> installs and validates cri-tools before either readiness gate' -ForEach @(@{ Version='24' }, @{ Version='26' }) {
        $source = $script:K8sSources[$Version]
        $source | Should -Match '(?m)^apt_retry sudo apt-get install -y kubelet kubeadm kubectl cri-tools$'
        $source | Should -Match '(?m)^assert_tool_runnable crictl --version$'
        $source.IndexOf('assert_tool_runnable crictl --version') | Should -BeLessThan $source.IndexOf("`nwait_for_containerd 30`n")
        @([regex]::Matches($source, '(?m)^\s*wait_for_containerd 30$')).Count | Should -Be 2
    }
}


Describe 'OpenTofu bootstrap avoids apt work and enforces the requested signed release' -Skip:(-not $script:CanRunOpenTofu) {
    It 'Ubuntu <Version> handles <Mode> without accepting a stale or failed installation' -ForEach @(
        @{ Version='24'; Mode='healthy' }, @{ Version='26'; Mode='healthy' },
        @{ Version='24'; Mode='missing' }, @{ Version='26'; Mode='missing' },
        @{ Version='24'; Mode='zero' }, @{ Version='26'; Mode='zero' },
        @{ Version='24'; Mode='dangling' }, @{ Version='26'; Mode='dangling' },
        @{ Version='24'; Mode='broken' }, @{ Version='26'; Mode='broken' },
        @{ Version='24'; Mode='silent' }, @{ Version='26'; Mode='silent' },
        @{ Version='24'; Mode='wrong-version' }, @{ Version='26'; Mode='wrong-version' },
        @{ Version='24'; Mode='download-failed' }, @{ Version='26'; Mode='download-failed' },
        @{ Version='24'; Mode='install-failed' }, @{ Version='26'; Mode='install-failed' },
        @{ Version='24'; Mode='verify-failed' }, @{ Version='26'; Mode='verify-failed' },
        @{ Version='24'; Mode='wrong-after-install' }, @{ Version='26'; Mode='wrong-after-install' },
        @{ Version='24'; Mode='shadowed-after-install' }, @{ Version='26'; Mode='shadowed-after-install' }
    ) {
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $bin = Join-Path $fixture 'bin'
        $shadow = Join-Path $fixture 'shadow'
        $legacy = Join-Path $fixture 'legacy'
        $install = Join-Path $fixture 'install'
        $null = New-Item -ItemType Directory -Path $bin, $shadow, $legacy, $install
        $source = $script:K8sSources[$Version]
        $begin = $source.IndexOf('# The signed standalone release avoids')
        $end = $source.IndexOf('# --- REGION: Install mkcert', $begin)
        $block = $source.Substring($begin, $end - $begin).
            Replace('/opt/opentofu', $install).Replace('/usr/local/bin', $bin)
        $initial = switch ($Mode) {
            'healthy' { "#!/bin/bash`nprintf 'OpenTofu v1.13.1\non linux_amd64\n'`n" }
            'zero' { '' }
            'broken' { "#!/bin/bash`nexit 12`n" }
            'silent' { "#!/bin/bash`nexit 0`n" }
            default { "#!/bin/bash`nprintf 'OpenTofu v1.12.9\non linux_amd64\n'`n" }
        }
        if ($Mode -eq 'dangling') {
            $null = New-Item -ItemType SymbolicLink -Path (Join-Path $legacy 'tofu') -Target (Join-Path $fixture 'absent')
        } elseif ($Mode -ne 'missing') {
            $initialDirectory = if ($Mode -eq 'shadowed-after-install') { $shadow } elseif ($Mode -eq 'healthy') { $bin } else { $legacy }
            $initialPath = Join-Path $initialDirectory 'tofu'
            [IO.File]::WriteAllText($initialPath, $initial)
            & chmod +x $initialPath
        }
        $installer = @'
#!/bin/bash
set -euo pipefail
printf 'installer %s\n' "$*" >> "$YURUNA_TOFU_CALLS"
install_path=''; symlink_path=''; version=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --install-method) [ "$2" = standalone ] || exit 61; shift 2 ;;
        --opentofu-version) version="$2"; shift 2 ;;
        --install-path) install_path="$2"; shift 2 ;;
        --symlink-path) symlink_path="$2"; shift 2 ;;
        *) echo 'unexpected installer flag' >&2; exit 62 ;;
    esac
done
[ "$version" = 1.13.1 ] && [ -n "$install_path" ] && [ -n "$symlink_path" ] || exit 63
case "$YURUNA_TOFU_MODE" in
    install-failed) echo 'upstream install fixture failed' >&2; exit 41 ;;
    verify-failed) echo 'Signature verification failed: fixture' >&2; exit 42 ;;
    wrong-after-install) version=1.12.9 ;;
esac
mkdir -p "$install_path" "$symlink_path"
printf '#!/bin/bash\nprintf "OpenTofu v%s\\non linux_amd64\\n"\n' "$version" > "$install_path/tofu"
chmod +x "$install_path/tofu"
ln -sf "$install_path/tofu" "$symlink_path/tofu"
'@
        $installerSource = Join-Path $fixture 'installer.sh'
        Set-Content $installerSource $installer
        $prefix = @'
set -euo pipefail
export PATH="$YURUNA_TOFU_SHADOW:$YURUNA_TOFU_BIN:$YURUNA_TOFU_LEGACY:$PATH"
command() {
    if [[ "$#" == 2 && "$1" == -v && "$2" == tofu ]]; then
        local path
        path="$(builtin command -v tofu 2>/dev/null || true)"
        case "$path" in
            "$YURUNA_TOFU_BIN/"*|"$YURUNA_TOFU_SHADOW/"*|"$YURUNA_TOFU_LEGACY/"*) printf '%s\n' "$path" ;;
            *) return 1 ;;
        esac
        return
    fi
    builtin command "$@"
}
export YURUNA_OPENTOFU_VERSION=1.13.1
curl_retry() {
    printf 'download %s\n' "$*" >> "$YURUNA_TOFU_CALLS"
    if [ "$YURUNA_TOFU_MODE" = download-failed ]; then return 15; fi
    while [ "$#" -gt 0 ]; do
        if [ "$1" = -o ]; then cp "$YURUNA_TOFU_INSTALLER" "$2"; return; fi
        shift
    done
    return 64
}
_yuruna_retry() {
    printf 'retry %s\n' "$1" >> "$YURUNA_TOFU_CALLS"
    shift
    "$@"
}
# A cached old path must be refreshed before checking the installed link.
if command -v tofu >/dev/null 2>&1; then tofu version >/dev/null 2>&1 || true; fi
'@
        $entryPoint = Join-Path $fixture 'opentofu.sh'
        Set-Content $entryPoint ($prefix + "`n" + $block + @'

tofu version
"$YURUNA_TOFU_PWSH" -NoProfile -Command '& tofu version; if ($LASTEXITCODE -ne 0) { exit 1 }'
printf 'downstream-resource\n'
'@)
        $callsPath = Join-Path $fixture 'calls.txt'
        $result = Invoke-BoundedNativeCommand -FilePath bash -ArgumentList @($entryPoint) -TimeoutSeconds 12 -Environment @{
            YURUNA_TOFU_MODE=$Mode; YURUNA_TOFU_BIN=$bin; YURUNA_TOFU_SHADOW=$shadow; YURUNA_TOFU_LEGACY=$legacy
            YURUNA_TOFU_INSTALLER=$installerSource; YURUNA_TOFU_CALLS=$callsPath
            YURUNA_TOFU_PWSH=(Get-Process -Id $PID).Path
        }
        $calls = if (Test-Path $callsPath) { @(Get-Content $callsPath) } else { @() }
        $fails = $Mode -in @('download-failed', 'install-failed', 'verify-failed', 'wrong-after-install', 'shadowed-after-install')
        if ($fails) {
            $result.ExitCode | Should -Be 1 -Because $result.StdErr
            $result.StdOut | Should -Not -Match 'downstream-resource'
            switch ($Mode) {
                'download-failed' { $result.StdErr | Should -Match 'Could not download the OpenTofu installer' }
                'install-failed' { $result.StdErr | Should -Match 'upstream install fixture failed' }
                'verify-failed' { $result.StdErr | Should -Match 'Signature verification failed: fixture' }
                default { $result.StdErr | Should -Match '1\.13\.1 is not runnable on PATH after installation' }
            }
        } else {
            $result.ExitCode | Should -Be 0 -Because $result.StdErr
            $result.StdOut | Should -Match 'downstream-resource'
            @([regex]::Matches($result.StdOut, 'OpenTofu v1\.13\.1')).Count | Should -Be 2
        }
        if ($Mode -eq 'healthy') {
            $calls.Count | Should -Be 0
            $result.StdOut | Should -Match 'already installed and runnable'
        } else {
            @($calls | Where-Object { $_ -like 'download *' }).Count | Should -Be 1
            if ($Mode -ne 'download-failed') {
                $calls | Should -Contain 'retry opentofu_standalone'
                $calls[-1] | Should -Be "installer --install-method standalone --opentofu-version 1.13.1 --install-path $install --symlink-path $bin"
            }
            $calls -join "`n" | Should -Not -Match 'apt-get|--skip-verify|--install-method deb'
            $download = @($calls | Where-Object { $_ -like 'download *' })[0]
            $temporaryInstaller = ($download -split ' -o ', 2)[1]
            Test-Path -LiteralPath $temporaryInstaller | Should -BeFalse
        }
    }
}
