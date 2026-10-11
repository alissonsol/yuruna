<#PSScriptInfo
.VERSION 2026.10.11
.GUID 42cdf6b6-938d-4e26-ae2b-c1d96da2bed0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test kubernetes bootstrap readiness performance
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

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:Bash = Get-Command bash -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    function Get-NetworkReadinessFunction {
        <# .SYNOPSIS
            Read the exact production readiness helper for executable fixtures.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param([string]$Source)
        $start = $Source.IndexOf('wait_for_kubernetes_network() {', [StringComparison]::Ordinal)
        if ($start -lt 0) { throw 'Kubernetes network readiness helper is missing.' }
        $end = $Source.IndexOf("`n}`n", $start, [StringComparison]::Ordinal)
        if ($end -lt 0) { throw 'Kubernetes network readiness helper is incomplete.' }
        return $Source.Substring($start, $end + 3 - $start)
    }
    function Invoke-NetworkReadinessFixture {
        <# .SYNOPSIS
            Run the shipped helper against a controlled Kubernetes command surface.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Writes isolated test fixture files only.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([string]$Source, [int]$RolloutExit, [int]$NodeExit)
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.sh')
        $log = $fixture + '.commands'
        $prefix = @'
set -euo pipefail
REAL_HOME="$1"
fixture_log="$2"
rollout_exit="$3"
node_exit="$4"
kubectl() {
    printf '<%s>' "$@" >> "$fixture_log"
    printf '\n' >> "$fixture_log"
    case "$*" in
        *' rollout status '*) echo 'rollout-probe'; return "$rollout_exit" ;;
        *' wait '*) echo 'node-probe'; return "$node_exit" ;;
        *) echo 'diagnostic-evidence'; return 0 ;;
    esac
}
ls() { printf 'cni-evidence\n' >> "$fixture_log"; }
'@
        $body = $prefix + "`n" + (Get-NetworkReadinessFunction -Source $Source) + "`nwait_for_kubernetes_network`nprintf 'passed-readiness-gate\n'`n"
        [IO.File]::WriteAllText($fixture, $body, [Text.UTF8Encoding]::new($false))
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $script:Bash.Source $fixture '/home/guest user [literal]' $log "$RolloutExit" "$NodeExit" 2>&1 | Out-String
        $code = $LASTEXITCODE
        return [pscustomobject]@{ Code = $code; Output = $output; Commands = [IO.File]::ReadAllText($log) }
    }
}

Describe 'Kubernetes bootstrap overlap for Ubuntu <Version>' -ForEach @(
    @{ Version = '24' }, @{ Version = '26' }
) {
    BeforeAll {
        $script:Source = [IO.File]::ReadAllText((Join-Path $script:RepoRoot "guest/ubuntu.server.$Version/ubuntu.server.$Version.k8s.sh"))
    }
    It 'starts network convergence before tools and gates completion after certificate generation' {
        $apply = $script:Source.IndexOf(' apply -f "$FLANNEL_MANIFEST"', [StringComparison]::Ordinal)
        $helm = $script:Source.IndexOf('# --- REGION: Install Helm', [StringComparison]::Ordinal)
        $tofu = $script:Source.IndexOf('# --- REGION: Install OpenTofu', [StringComparison]::Ordinal)
        $cert = $script:Source.IndexOf('chown -R "$REAL_USER:$REAL_USER" "$PFX_DIR"', [StringComparison]::Ordinal)
        $gate = [regex]::Match($script:Source, '(?m)^wait_for_kubernetes_network\r?$').Index
        $summary = $script:Source.IndexOf('# --- REGION: Installation summary', [StringComparison]::Ordinal)
        $apply | Should -BeGreaterThan 0
        $helm | Should -BeGreaterThan $apply
        $tofu | Should -BeGreaterThan $helm
        $cert | Should -BeGreaterThan $tofu
        $gate | Should -BeGreaterThan $cert
        $summary | Should -BeGreaterThan $gate
        [regex]::Matches($script:Source, '(?m)^wait_for_kubernetes_network\r?$').Count | Should -Be 1
    }
    It 'keeps node taint and context changes behind the readiness gate' {
        $gate = [regex]::Match($script:Source, '(?m)^wait_for_kubernetes_network\r?$').Index
        $script:Source.IndexOf(' taint nodes --all ', [StringComparison]::Ordinal) | Should -BeGreaterThan $gate
        $script:Source.IndexOf(' config rename-context ', [StringComparison]::Ordinal) | Should -BeGreaterThan $gate
    }
    It 'retains bounded readiness probes and literal kubeconfig arguments' {
        $helper = Get-NetworkReadinessFunction -Source $script:Source
        $helper | Should -Match 'rollout status daemonset/kube-flannel-ds --timeout=180s'
        $helper | Should -Match 'wait --for=condition=ready node --all --timeout=180s'
        $helper | Should -Not -Match '\bsleep\s'
    }
    It 'finishes only when the actual node readiness command succeeds' {
        if (-not $script:Bash -or $IsWindows) { Set-ItResult -Skipped -Because 'Linux guest Bash fixture requires a Unix Bash path.'; return }
        $result = Invoke-NetworkReadinessFixture -Source $script:Source -RolloutExit 0 -NodeExit 0
        $result.Code | Should -Be 0
        $result.Output | Should -Match 'passed-readiness-gate'
        $result.Commands | Should -Match '<--kubeconfig=/home/guest user \[literal\]/\.kube/config>'
        ($result.Commands -split "`n" | Where-Object { $_ }).Count | Should -Be 2
    }
    It 'preserves the advisory rollout timeout while requiring a Ready node' {
        if (-not $script:Bash -or $IsWindows) { Set-ItResult -Skipped -Because 'Linux guest Bash fixture requires a Unix Bash path.'; return }
        $result = Invoke-NetworkReadinessFixture -Source $script:Source -RolloutExit 124 -NodeExit 0
        $result.Code | Should -Be 0
        $result.Output | Should -Match 'Flannel rollout status check timed out'
        $result.Output | Should -Match 'passed-readiness-gate'
        $result.Commands | Should -Match '<wait><--for=condition=ready><node><--all><--timeout=180s>'
    }
    It 'fails and retains nodes, pods and CNI evidence when networking never becomes ready' {
        if (-not $script:Bash -or $IsWindows) { Set-ItResult -Skipped -Because 'Linux guest Bash fixture requires a Unix Bash path.'; return }
        $result = Invoke-NetworkReadinessFixture -Source $script:Source -RolloutExit 0 -NodeExit 1
        $result.Code | Should -Be 1
        $result.Output | Should -Not -Match 'passed-readiness-gate'
        $result.Output | Should -Match 'node did not reach Ready within 180s'
        $result.Commands | Should -Match '<get><nodes><-o><wide>'
        $result.Commands | Should -Match '<-n><kube-flannel><get><pods><-o><wide>'
        $result.Commands | Should -Match 'cni-evidence'
    }
}
