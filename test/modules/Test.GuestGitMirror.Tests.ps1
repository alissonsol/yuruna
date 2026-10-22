<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42cfce16-0bb7-4e30-aec8-058268db517a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guest git mirror integrity
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

BeforeDiscovery {
    $script:CanRunGuestGit = [bool]((Get-Command bash -ErrorAction SilentlyContinue) -and
        (Get-Command git -ErrorAction SilentlyContinue) -and (Get-Command python3 -ErrorAction SilentlyContinue))
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    function Invoke-GuestGitFixture {
        param([string]$Mode, [string]$Platform = 'Library')
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root
        $driver = @'
set -euo pipefail
cd "$FIXTURE_ROOT"
mkdir -p upstream/bin upstream/docs upstream/dev-only bin home
git_real=$(command -v git)
"$git_real" init -q upstream
"$git_real" -C upstream config user.email fixture@example.invalid
"$git_real" -C upstream config user.name Fixture
printf 'selected\n' > upstream/VERSION
printf 'private\n' > upstream/dev-only/private.txt
printf 'docs\n' > upstream/docs/guide.txt
"$git_real" -C upstream add .
"$git_real" -C upstream commit -qm selected
selected=$("$git_real" -C upstream rev-parse HEAD)
printf 'advanced\n' > upstream/VERSION
"$git_real" -C upstream commit -qam advanced
cat > bin/git <<'GIT'
#!/bin/bash
printf '%s\n' "$*" >> "$FIXTURE_ROOT/calls"
args=()
mirror=0
for arg in "$@"; do
    case "$arg" in
        http://mirror.invalid/git/owner/repository.git)
            mirror=1; arg="$FIXTURE_ROOT/upstream" ;;
        https://github.com/owner/repository.git|https://legacy.invalid/framework.git)
            arg="$FIXTURE_ROOT/upstream" ;;
    esac
    args+=("$arg")
done
if [ "$mirror" = 1 ]; then
    [ -z "${GH_TOKEN:-}${GIT_ASKPASS:-}${http_proxy:-}${HTTP_PROXY:-}${GIT_CONFIG_COUNT:-}" ] || exit 90
    printf 'MIRROR_AUTH_FREE\n' >> "$FIXTURE_ROOT/calls"
fi
if [[ " $* " == *' fetch '* ]] && [ "$FIXTURE_MODE" = unavailable ]; then exit 128; fi
if [[ " $* " == *' rev-parse HEAD '* ]] && [ "$FIXTURE_MODE" = wrong-head ]; then
    printf '0000000000000000000000000000000000000000\n'; exit 0
fi
exec "$FIXTURE_REAL_GIT" "${args[@]}"
GIT
chmod +x bin/git
printf '#!/bin/bash\n[ "$FIXTURE_MODE" != old-proxy ]\n' > bin/wget
chmod +x bin/wget
export FIXTURE_REAL_GIT="$git_real" PATH="$FIXTURE_ROOT/bin:$PATH"
export E_FB_REPO=owner/repository E_FB_REF="$selected"
export YURUNA_CACHING_PROXY_SERVICE_IP=mirror.invalid
export GH_TOKEN=fixture-secret GIT_ASKPASS=/missing/fixture-helper http_proxy=http://invalid.proxy
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=fixture.operator GIT_CONFIG_VALUE_0=retained
. "$FIXTURE_LIBRARY"
yuruna_host_env() { return 1; }
yuruna_host_relocate() { return 1; }
sudo() { :; }
sleep() { :; }
curl() { [ "$FIXTURE_MODE" != old-proxy ]; }
case "$FIXTURE_MODE" in legacy|legacy-no-python) unset E_FB_REPO E_FB_REF ;; esac
if [ "$FIXTURE_MODE" = malformed ]; then E_FB_REF=main; fi
case "$FIXTURE_MODE" in
    missing-python|legacy-no-python)
        command() { if [ "$*" = '-v python3' ]; then return 1; fi; builtin command "$@"; } ;;
esac
if [ "$FIXTURE_MODE" = existing ]; then
    mkdir -p home/yuruna
    printf 'existing\n' > home/yuruna/VERSION
fi
rc=0
if [ -n "$FIXTURE_UPDATE" ]; then
    unset -f yuruna_materialize_framework_pin
    yuruna_materialize_repositories() { echo STALE_LIBRARY_USED; return 97; }
    REAL_HOME="$FIXTURE_ROOT/home" REAL_USER=fixture FRAMEWORK_URL=https://legacy.invalid/framework.git PROJECT_URL=''
    ( . "$FIXTURE_UPDATE" ) || rc=$?
else
    ( yuruna_materialize_repositories "$FIXTURE_ROOT/home" fixture https://legacy.invalid/framework.git '' ) || rc=$?
fi
printf 'RESULT_RC=%s\nEXPECTED_SHA=%s\n' "$rc" "$selected"
if [ -f home/yuruna/VERSION ]; then printf 'VERSION='; cat home/yuruna/VERSION; fi
if [ -f home/yuruna/.yuruna-revision ]; then printf 'REVISION='; cat home/yuruna/.yuruna-revision; fi
if [ -f home/yuruna/.yuruna-origin ]; then printf 'ORIGIN='; cat home/yuruna/.yuruna-origin; fi
test ! -d home/yuruna/docs || printf 'DOCS_PRESENT\n'
test ! -d home/yuruna/dev-only || printf 'PRIVATE_PRESENT\n'
printf 'CALLS_BEGIN\n'
cat calls 2>/dev/null || true
printf 'CALLS_END\n'
'@
        $entry = Join-Path $root 'fixture.sh'
        [IO.File]::WriteAllText($entry, $driver.Replace("`r`n", "`n"))
        $updatePath = ''
        if ($Platform -ne 'Library') {
            $relative = if ($Platform -eq 'Ubuntu') { 'guest/shared/ubuntu.update.sh' } else { 'guest/amazon.linux.2023/amazon.linux.2023.update.sh' }
            $source = Get-Content (Join-Path $script:RepoRoot $relative) -Raw
            $start = $source.IndexOf('# --- REGION: Materialize the yuruna framework and project repos')
            $end = $source.IndexOf('# --- REGION: Wait for network convergence', $start)
            $updatePath = Join-Path $root 'standalone-update.sh'
            [IO.File]::WriteAllText($updatePath, $source.Substring($start, $end - $start).Replace("`r`n", "`n"))
        }
        $result = Invoke-BoundedNativeCommand -FilePath (Get-Command bash).Source -ArgumentList @($entry) -TimeoutSeconds 20 `
            -Environment @{ FIXTURE_ROOT=$root; FIXTURE_MODE=$Mode; FIXTURE_UPDATE=$updatePath
                FIXTURE_LIBRARY=(Join-Path $script:RepoRoot 'automation/yuruna-retry.sh') }
        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        if ($Mode -eq 'missing-python') { $result.StdErr | Should -Match 'Python 3 is required for bounded pinned Git materialization' }
        return $result.StdOut
    }
}

Describe 'Guest framework Git materialization' -Skip:(-not $script:CanRunGuestGit) {
    It '<Platform> fetches the selected commit even when the branch advanced or installed library is old' -ForEach @(
        @{ Platform='Library' }, @{ Platform='Ubuntu' }, @{ Platform='Amazon' }
    ) {
        $output = Invoke-GuestGitFixture mirror $Platform
        $output | Should -Match 'RESULT_RC=0'
        $output | Should -Match '(?m)^VERSION=selected$'
        $output | Should -Match 'source=lan-mirror'
        $output | Should -Match 'MIRROR_AUTH_FREE'
        $output | Should -Not -Match 'legacy.invalid| fetch .+https://github.com|DOCS_PRESENT|PRIVATE_PRESENT|STALE_LIBRARY_USED'
        $pin = [regex]::Match($output, 'EXPECTED_SHA=([a-f0-9]{40})').Groups[1].Value
        $output | Should -Match "(?m)^REVISION=$pin$"
        $output | Should -Match '(?m)^ORIGIN=https://github.com/owner/repository.git$'
    }
    It 'uses the same immutable commit on GitHub when an old proxy lacks capability' {
        $output = Invoke-GuestGitFixture old-proxy
        $output | Should -Match 'RESULT_RC=0'
        $output | Should -Match '(?m)^VERSION=selected$'
        $output | Should -Match 'https://github.com/owner/repository.git'
        $output | Should -Not -Match 'http://mirror.invalid/git/| clone |legacy.invalid'
    }
    It 'fails a pinned invocation after <Mode> without cloning a moving branch' -ForEach @(
        @{ Mode='unavailable' }, @{ Mode='wrong-head' }, @{ Mode='malformed' }, @{ Mode='missing-python' }
    ) {
        $output = Invoke-GuestGitFixture $Mode
        $output | Should -Match 'RESULT_RC=1'
        $output | Should -Not -Match '(?m)^VERSION=| clone |legacy.invalid'
    }
    It 'preserves the labeled legacy clone for <Mode> without an immutable identity' -ForEach @(
        @{ Mode='legacy' }, @{ Mode='legacy-no-python' }
    ) {
        $output = Invoke-GuestGitFixture $Mode
        $output | Should -Match 'RESULT_RC=0'
        $output | Should -Match '(?m)^VERSION=advanced$'
        $output | Should -Match 'legacy.*unpinned'
        $output | Should -Match 'clone https://legacy.invalid/framework.git'
    }
    It 'preserves an existing framework without replacing its contents' {
        $output = Invoke-GuestGitFixture existing
        $output | Should -Match 'RESULT_RC=0'
        $output | Should -Match '(?m)^VERSION=existing$'
        $output | Should -Not -Match ' fetch | clone '
    }
    It 'keeps the complete portable helper and Linux materializer copies in standalone updaters' {
        $library = Get-Content (Join-Path $script:RepoRoot 'automation/yuruna-retry.sh') -Raw
        foreach ($relative in 'guest/shared/ubuntu.update.sh', 'guest/amazon.linux.2023/amazon.linux.2023.update.sh', 'guest/macos.26/macos.26.update.sh') {
            $source = Get-Content (Join-Path $script:RepoRoot $relative) -Raw
            $names = @('yuruna_materialize_framework_pin')
            if ($relative -notlike 'guest/macos*') { $names += 'yuruna_materialize_repositories' }
            foreach ($name in $names) {
                $pattern = "(?ms)^$name\(\) \{.*?^\}"
                $expected = [regex]::Match($library, $pattern)
                $actual = [regex]::Match($source, $pattern)
                $expected.Success | Should -BeTrue
                $actual.Success | Should -BeTrue
                $actual.Value | Should -BeExactly $expected.Value
            }
        }
    }
    It 'kills a TERM-resistant Git descendant when the Git parent exits first' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root
        $library = Get-Content (Join-Path $script:RepoRoot 'automation/yuruna-retry.sh') -Raw
        $worker = [regex]::Match($library, "(?ms)^import os`n.*?(?=^YURUNA_PINNED_GIT$)")
        $worker.Success | Should -BeTrue
        [IO.File]::WriteAllText((Join-Path $root 'worker.py'), $worker.Value)
        $driver = @'
python3 - "$FIXTURE_ROOT" <<'PY'
import os, pathlib, signal, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
binary = root / "git"
binary.write_text("""#!/usr/bin/env python3
import os, pathlib, signal, subprocess, sys, time
if "fetch" in sys.argv:
    code = 'import os,signal,time,pathlib;signal.signal(signal.SIGTERM,signal.SIG_IGN);pathlib.Path(os.environ["CHILD_PID_FILE"]).write_text(str(os.getpid()));time.sleep(60)'
    child = subprocess.Popen([sys.executable, "-c", code])
    child.wait()
""")
binary.chmod(0o755)
environment = os.environ.copy()
environment.update(PATH=str(root) + os.pathsep + environment["PATH"], CHILD_PID_FILE=str(root / "child.pid"))
process = subprocess.Popen([sys.executable, str(root / "worker.py"), str(root / "checkout"),
                            "owner/repository", "1"*40, "http://mirror.invalid/git/owner/repository.git"],
                           env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
child = None
try:
    deadline = time.monotonic() + 5
    while not (root / "child.pid").exists() and time.monotonic() < deadline:
        time.sleep(0.02)
    child = int((root / "child.pid").read_text())
    process.terminate()
    process.communicate(timeout=5)
    state = subprocess.run(["ps", "-o", "stat=", "-p", str(child)], capture_output=True, text=True).stdout.strip()
    print("DESCENDANT_ALIVE=" + str(bool(state and not state.startswith("Z"))).lower())
    print("STAGING_REMAINS=" + str(bool(list(root.glob(".yuruna-pin.*")))).lower())
finally:
    if process.poll() is None:
        process.kill()
        process.communicate()
    if child is not None:
        try:
            os.kill(child, signal.SIGKILL)
        except ProcessLookupError:
            pass
PY
'@
        $entry = Join-Path $root 'cancel.sh'
        [IO.File]::WriteAllText($entry, $driver.Replace("`r`n", "`n"))
        $result = Invoke-BoundedNativeCommand -FilePath (Get-Command bash).Source -ArgumentList @($entry) -TimeoutSeconds 15 `
            -Environment @{ FIXTURE_ROOT=$root }
        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        $result.StdOut | Should -Match 'DESCENDANT_ALIVE=false'
        $result.StdOut | Should -Match 'STAGING_REMAINS=false'
    }
}
