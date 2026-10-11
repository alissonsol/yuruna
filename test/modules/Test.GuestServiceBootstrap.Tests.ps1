<#PSScriptInfo
.VERSION 2026.10.11
.GUID 42a28f50-90bf-4aa0-a8f6-cda286b79d39
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guest service yaml readiness architecture pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>

#requires -version 7

BeforeDiscovery {
    $script:CanRunBash = -not $IsWindows -and $null -ne (Get-Command bash -ErrorAction SilentlyContinue)
    $script:CanRunMacPublisher = $script:CanRunBash -and
        $null -ne (Get-Command shasum -ErrorAction SilentlyContinue) -and
        $null -ne (Get-Command iconv -ErrorAction SilentlyContinue)
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    Import-Module powershell-yaml -ErrorAction Stop
    $script:Pwsh = (Get-Command pwsh -ErrorAction Stop).Source
    $script:PoolSource = Get-Content (Join-Path $script:RepoRoot 'guest/ubuntu.server.26/ubuntu.server.26.pool-control-service.sh') -Raw
    $match = [regex]::Match($script:PoolSource, '(?m)^  if sudo pwsh -NoProfile -NonInteractive -Command "(.*)"; then$')
    if (-not $match.Success) { throw 'Pool-control YAML dependency command was not found' }
    # Bash's double-quoted argument removes these escapes before PowerShell sees it.
    $script:PoolYamlPayload = $match.Groups[1].Value.Replace('\$', '$')
    $macSource = Get-Content (Join-Path $script:RepoRoot 'guest/macos.26/macos.26.update.sh') -Raw
    $macMatch = [regex]::Match($macSource, '(?m)^sudo pwsh -NoProfile -Command "(.*)"$')
    if (-not $macMatch.Success) { throw 'macOS YAML smoke command was not found' }
    $script:MacYamlPayload = $macMatch.Groups[1].Value.Replace('\$', '$')
    function Invoke-ServiceYamlFixture {
        param([string]$Mode, [ValidateSet('Pool', 'MacOS')][string]$Platform = 'Pool')
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $fixture
        $prefix = @'
$script:Mode = $env:YURUNA_SERVICE_MODE
$script:Calls = @{ installs=0; imports=0; parses=0 }
function Get-Module { if ($script:Mode -ne 'missing') { [pscustomobject]@{ Name='powershell-yaml' } } }
function Install-Module {
    param([string]$Name, [string]$Scope, [switch]$Force, [switch]$AcceptLicense)
    if ($Name -ne 'powershell-yaml' -or $Scope -ne 'AllUsers' -or -not $Force -or -not $AcceptLicense) { throw 'Installation contract changed' }
    $script:Calls.installs++
}
function Import-Module { $script:Calls.imports++; if ($script:Mode -eq 'broken-import') { Write-Error 'fixture import failed' } }
function ConvertFrom-Yaml {
    param([string]$Yaml)
    $script:Calls.parses++
    if ($Yaml -cne 'k: v') { throw 'Unexpected smoke input' }
    if ($script:Mode -eq 'parse-error') { Write-Error 'fixture parser failed' }
    if ($script:Mode -eq 'wrong-parse') { return @{ k='wrong' } }
    return @{ k='v' }
}
'@
        $suffix = @'

} finally { $script:Calls | ConvertTo-Json -Compress | Set-Content -LiteralPath $env:YURUNA_SERVICE_RESULT }
'@
        $payload = if ($Platform -eq 'MacOS') { $script:MacYamlPayload } else { $script:PoolYamlPayload }
        $entry = Join-Path $fixture 'fixture.ps1'
        $resultFile = Join-Path $fixture 'calls.json'
        Set-Content -LiteralPath $entry -Value ($prefix + "`ntry {`n" + $payload + $suffix) -Encoding utf8NoBOM
        $result = Invoke-BoundedNativeCommand -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-File', $entry) -TimeoutSeconds 15 `
            -Environment @{ YURUNA_SERVICE_MODE=$Mode; YURUNA_SERVICE_RESULT=$resultFile }
        [pscustomobject]@{ Process=$result; Calls=(Get-Content $resultFile -Raw | ConvertFrom-Json) }
    }
    function Invoke-ServiceReadinessFixture {
        param([string]$Service, [bool]$Ready)
        $source = Get-Content (Join-Path $script:RepoRoot "guest/ubuntu.server.26/ubuntu.server.26.$Service-service.sh") -Raw
        $start = $source.IndexOf('# --- REGION: Start the service and wait for readiness')
        if ($start -lt 0) { throw 'Service readiness block was not found' }
        $prefix = @'
set -euo pipefail
HTTP_ADDR=0.0.0.0:80
STATE_DIR=/fixture/state
POOL_DIR=/fixture/pool
sudo() { printf 'sudo %s\n' "$*" >> "$YURUNA_SERVICE_CALLS"; }
ss() { :; }
yuruna_service_wait_active() {
    printf 'wait %s\n' "$*" >> "$YURUNA_SERVICE_CALLS"
    [ "$YURUNA_SERVICE_READY" = true ]
}
'@
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $fixture
        $entry = Join-Path $fixture 'fixture.sh'
        $calls = Join-Path $fixture 'calls.txt'
        Set-Content -LiteralPath $entry -Value ($prefix + "`n" + $source.Substring($start)) -Encoding utf8NoBOM
        $result = Invoke-BoundedNativeCommand -FilePath (Get-Command bash).Source -ArgumentList @($entry) -TimeoutSeconds 10 `
            -Environment @{ YURUNA_SERVICE_CALLS=$calls; YURUNA_SERVICE_READY=$Ready.ToString().ToLowerInvariant() }
        [pscustomobject]@{ Process=$result; Calls=(Get-Content $calls -Raw) }
    }
    function Get-ServiceFrameworkFetch {
        param([string]$Service)
        $seedPath = Join-Path $script:RepoRoot "host/vmconfig/$Service-service.base.user-data"
        $seed = ConvertFrom-Yaml (Get-Content -LiteralPath $seedPath -Raw)
        if ($Service -eq 'stash') {
            $source = @($seed.write_files | Where-Object path -EQ '/usr/local/lib/yuruna/stash-bringup.sh')[0].content
            $start = $source.IndexOf('# --- REGION: Fetch the framework')
            $end = $source.IndexOf('# --- REGION: Build and start the service', $start)
            return $source.Substring($start, $end - $start)
        }
        return @($seed.runcmd | Where-Object { $_ -is [string] -and $_ -match '(?m)^HF=/etc/yuruna/host.env$' })[0]
    }
    function Invoke-ServiceFrameworkFixture {
        param([string]$Service, [string]$Mode)
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $fixture
        $prefix = @'
set -u
mkdir -p "$FIXTURE_ROOT/etc/yuruna" "$FIXTURE_ROOT/checkout" "$FIXTURE_ROOT/payload"
printf 'YURUNA_STATUS_SERVICE_IP=192.0.2.1\nYURUNA_STATUS_SERVICE_PORT=8080\n' > "$FIXTURE_ROOT/etc/yuruna/host.env"
printf 'previous\n' > "$FIXTURE_ROOT/checkout/VERSION"
printf 'prior-source\n' > "$FIXTURE_ROOT/etc/yuruna/framework-source"
printf 'old checkout\n' > "$FIXTURE_ROOT/checkout/old.txt"
case "$FIXTURE_MODE" in
    missing-version) ;;
    empty-version) : > "$FIXTURE_ROOT/payload/VERSION" ;;
    directory-version) mkdir "$FIXTURE_ROOT/payload/VERSION" ;;
    *) printf 'host-version\n' > "$FIXTURE_ROOT/payload/VERSION" ;;
esac
printf 'new checkout\n' > "$FIXTURE_ROOT/payload/new.txt"
command tar -czf "$FIXTURE_ROOT/good.tar.gz" -C "$FIXTURE_ROOT/payload" .
if [ "$FIXTURE_MODE" = truncated-archive ]; then
    head -c 30 "$FIXTURE_ROOT/good.tar.gz" > "$FIXTURE_ROOT/short.tar.gz"
    cp "$FIXTURE_ROOT/short.tar.gz" "$FIXTURE_ROOT/good.tar.gz"
fi
wget() {
    printf 'wget %s\n' "$*" >> "$FIXTURE_ROOT/calls"
    case "$*" in */livecheck) return 0 ;; esac
    count=$(cat "$FIXTURE_ROOT/attempts" 2>/dev/null || printf 0); count=$((count + 1))
    printf '%s' "$count" > "$FIXTURE_ROOT/attempts"
    output='-'
    while [ "$#" -gt 0 ]; do
        case "$1" in -qO|-O) shift; output=$1 ;; -qO-) output='-' ;; esac
        shift
    done
    if [ "$output" = '-' ]; then cat "$FIXTURE_ROOT/good.tar.gz"; else cp "$FIXTURE_ROOT/good.tar.gz" "$output"; fi
    case "$FIXTURE_MODE" in
        transfer-error|all-fail|mirror-invalid) return 8 ;;
        retry) [ "$count" -gt 1 ] || return 8 ;;
    esac
    return 0
}
tar() {
    printf 'tar %s\n' "$*" >> "$FIXTURE_ROOT/calls"
    if [ "$FIXTURE_MODE" = broken-archive ]; then
        while [ "$#" -gt 0 ]; do
            if [ "$1" = '-C' ]; then shift; printf 'partial\n' > "$1/partial.txt"; break; fi
            shift
        done
        return 2
    fi
    command tar "$@"
}
git() {
    printf 'git %s\n' "$*" >> "$FIXTURE_ROOT/calls"
    [ "$FIXTURE_MODE" != all-fail ] || return 1
    for destination in "$@"; do :; done
    mkdir -p "$destination"
    printf 'mirror checkout\n' > "$destination/mirror.txt"
    if [ "$FIXTURE_MODE" != mirror-invalid ]; then printf 'mirror-version\n' > "$destination/VERSION"; fi
}
mv() {
    if [ "$2" = "$FIXTURE_ROOT/checkout" ]; then
        case "$FIXTURE_MODE:$1" in promotion-error:*/tree|rollback-error:*/tree|rollback-error:*/previous) return 1 ;; esac
    fi
    command mv "$@"
}
mktemp() { [ "$FIXTURE_MODE" != staging-error ] && command mktemp "$@"; }
sleep() { printf 'sleep %s\n' "$*" >> "$FIXTURE_ROOT/calls"; }
chown() { :; }
'@
        $source = Get-ServiceFrameworkFetch $Service
        $source = $source -replace '(?m)^DEST=.*$', 'DEST="$FIXTURE_ROOT/checkout"'
        $source = $source.Replace('/etc/yuruna', '"$FIXTURE_ROOT/etc/yuruna"')
        $entry = Join-Path $fixture 'fixture.sh'
        Set-Content -LiteralPath $entry -Value ($prefix + "`n" + $source) -Encoding utf8NoBOM
        $process = Invoke-BoundedNativeCommand -FilePath (Get-Command bash).Source -ArgumentList @($entry) -TimeoutSeconds 15 `
            -Environment @{ FIXTURE_ROOT=$fixture; FIXTURE_MODE=$Mode }
        $attemptsFile = Join-Path $fixture 'attempts'
        [pscustomobject]@{
            Process=$process
            Root=$fixture
            Marker=(Get-Content (Join-Path $fixture 'etc/yuruna/framework-source') -Raw)
            Version=if (Test-Path (Join-Path $fixture 'checkout/VERSION') -PathType Leaf) { (Get-Content (Join-Path $fixture 'checkout/VERSION') -Raw).Trim() } else { '' }
            Calls=(Get-Content (Join-Path $fixture 'calls') -Raw)
            Attempts=if (Test-Path -LiteralPath $attemptsFile) { [int](Get-Content $attemptsFile -Raw) } else { 0 }
        }
    }
    function Get-UpdateFrameworkSource {
        param([string]$Platform, [switch]$Early)
        $relative = switch ($Platform) {
            Ubuntu { 'guest/shared/ubuntu.update.sh' }
            Amazon { 'guest/amazon.linux.2023/amazon.linux.2023.update.sh' }
            MacOS { 'guest/macos.26/macos.26.update.sh' }
            Library { 'automation/yuruna-retry.sh' }
        }
        $source = Get-Content (Join-Path $script:RepoRoot $relative) -Raw
        if ($Platform -eq 'Library') {
            $start = $source.IndexOf('yuruna_materialize_repositories() {')
            $end = $source.IndexOf('# --- REGION: yuruna_wait_network', $start)
            return $source.Substring($start, $end - $start) + "`n" + 'yuruna_materialize_repositories "$REAL_HOME" fixture "$FRAMEWORK_URL" ""'
        }
        if ($Early) {
            $start = $source.IndexOf('# --- REGION: Early yuruna framework extraction')
            $end = $source.IndexOf('# --- REGION: Disable services that may suspend the machine', $start)
        } else {
            $start = $source.IndexOf('# --- REGION: Materialize the yuruna framework and project repos')
            $end = if ($Platform -eq 'MacOS') { $source.IndexOf('# Tarball extraction', $start) } else { $source.IndexOf('# --- REGION: Wait for network convergence', $start) }
        }
        return $source.Substring($start, $end - $start).Replace('/etc/yuruna/host.env', '"$FIXTURE_ROOT/absent-host.env"')
    }
    function Invoke-UpdateFrameworkFixture {
        param([string]$Platform, [string]$Mode, [switch]$Early)
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $fixture
        $prefix = @'
set -euo pipefail
REAL_HOME="$FIXTURE_ROOT"
REAL_USER=fixture
USER=fixture
FRAMEWORK_URL=https://example.invalid/framework
PROJECT_URL=''
YURUNA_STATUS_SERVICE_IP=192.0.2.1
YURUNA_STATUS_SERVICE_PORT=8080
getent() { printf 'fixture:x:1000:1000::%s:/bin/bash\n' "$FIXTURE_ROOT"; }
dscl() { printf 'NFSHomeDirectory: %s\n' "$FIXTURE_ROOT"; }
id() { [ "$*" = "-gn $REAL_USER" ] && printf 'staff\n'; }
yuruna_host_env() { return 0; }
yuruna_host_livecheck() { return 0; }
yuruna_host_relocate() { return 0; }
sudo() { :; }
sleep() { :; }
wget() { printf 'archive'; [ "$FIXTURE_MODE" != transfer-error ]; }
curl() { wget "$@"; }
tar() {
    cat >/dev/null
    for destination in "$@"; do :; done
    mkdir -p "$destination/project"
    case "$FIXTURE_MODE" in
        missing-version) ;;
        empty-version) : > "$destination/VERSION" ;;
        directory-version) mkdir "$destination/VERSION" ;;
        *) printf 'host-version\n' > "$destination/VERSION" ;;
    esac
}
git() {
    printf 'clone\n' >> "$FIXTURE_ROOT/calls"
    for destination in "$@"; do :; done
    mkdir -p "$destination/project"
    printf 'mirror-version\n' > "$destination/VERSION"
}
'@
        $entry = Join-Path $fixture 'fixture.sh'
        Set-Content -LiteralPath $entry -Value ($prefix + "`n" + (Get-UpdateFrameworkSource $Platform -Early:$Early)) -Encoding utf8NoBOM
        $process = Invoke-BoundedNativeCommand -FilePath (Get-Command bash).Source -ArgumentList @($entry) -TimeoutSeconds 10 `
            -Environment @{ FIXTURE_ROOT=$fixture; FIXTURE_MODE=$Mode }
        $versionFile = Join-Path $fixture 'yuruna/VERSION'
        [pscustomobject]@{
            Process=$process
            Exists=(Test-Path (Join-Path $fixture 'yuruna'))
            Version=if (Test-Path $versionFile -PathType Leaf) { (Get-Content $versionFile -Raw).Trim() } else { '' }
            Cloned=(Test-Path (Join-Path $fixture 'calls'))
        }
    }
}

Describe 'Pool-control requires a functional YAML parser' {
    It 'reuses an installed module after a successful parse' {
        $result = Invoke-ServiceYamlFixture healthy
        $result.Process.ExitCode | Should -Be 0
        $result.Calls.installs | Should -Be 0
        $result.Calls.imports | Should -Be 1
        $result.Calls.parses | Should -Be 1
    }
    It 'installs a missing module with the existing AllUsers contract and verifies it' {
        $result = Invoke-ServiceYamlFixture missing
        $result.Process.ExitCode | Should -Be 0
        $result.Calls.installs | Should -Be 1
        $result.Calls.imports | Should -Be 1
        $result.Calls.parses | Should -Be 1
    }
    It 'rejects <Mode> before announcing a usable dependency' -ForEach @(
        @{ Mode='broken-import' }, @{ Mode='parse-error' }, @{ Mode='wrong-parse' }
    ) {
        $result = Invoke-ServiceYamlFixture $Mode
        $result.Process.ExitCode | Should -Not -Be 0
    }
}

Describe 'macOS requires a functional YAML parser after installation' {
    It 'accepts an imported parser with the expected result' {
        $result = Invoke-ServiceYamlFixture healthy -Platform MacOS
        $result.Process.ExitCode | Should -Be 0
        $result.Calls.imports | Should -Be 1
        $result.Calls.parses | Should -Be 1
        $result.Calls.installs | Should -Be 0
    }
    It 'rejects <Mode> instead of continuing after a failed smoke check' -ForEach @(
        @{ Mode='broken-import' }, @{ Mode='parse-error' }, @{ Mode='wrong-parse' }
    ) {
        $result = Invoke-ServiceYamlFixture $Mode -Platform MacOS
        $result.Process.ExitCode | Should -Not -Be 0
    }
}

Describe 'Service guest readiness output belongs to the service' {
    It '<Service> announces readiness only after the active and HTTP health gate' -ForEach @(
        @{ Service='download-agent' }, @{ Service='pool-control' }
    ) -Skip:(-not $script:CanRunBash) {
        $result = Invoke-ServiceReadinessFixture $Service $true
        $result.Process.ExitCode | Should -Be 0
        $result.Calls | Should -Match "wait $Service-service.service 30 http://127.0.0.1:80/healthz"
        ($result.Process.StdOut + $result.Process.StdErr) | Should -Match "$Service-service.service ready"
        ($result.Process.StdOut + $result.Process.StdErr) | Should -Not -Match 'FETCHED AND EXECUTED:'
    }
    It '<Service> fails with journal diagnostics when its readiness gate fails' -ForEach @(
        @{ Service='download-agent' }, @{ Service='pool-control' }
    ) -Skip:(-not $script:CanRunBash) {
        $result = Invoke-ServiceReadinessFixture $Service $false
        $result.Process.ExitCode | Should -Be 1
        $result.Calls | Should -Match "sudo journalctl -u $Service-service.service --no-pager -n 40"
        ($result.Process.StdOut + $result.Process.StdErr) | Should -Not -Match 'service ready|FETCHED AND EXECUTED:'
    }
}


Describe 'Windows guest JDK selection follows the native operating system' {
    BeforeAll {
        $source = Get-Content (Join-Path $script:RepoRoot 'guest/windows.11/windows.11.code.ps1') -Raw
        $start = $source.IndexOf('$jdkProcessor =')
        $end = $source.IndexOf('$jdkLts =', $start)
        if ($start -lt 0 -or $end -lt 0) { throw 'Native JDK architecture selection was not found' }
        $script:JdkSelection = $source.Substring($start, $end - $start)
        function Invoke-JdkArchitectureFixture {
            param([string]$Mode, [int]$Native, [string]$Process)
            $prefix = @'
function Get-CimInstance {
    param([string]$ClassName, [string]$Property)
    if ($ClassName -ne 'Win32_Processor' -or $Property -ne 'Architecture') { throw 'Native architecture query changed' }
    if ($env:YURUNA_CIM_MODE -eq 'failed') { Write-Error 'fixture CIM query failed'; return }
    if ($env:YURUNA_CIM_MODE -eq 'empty') { return }
    [pscustomobject]@{ Architecture=[int]$env:YURUNA_NATIVE_ARCH }
}

'@
            $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.ps1')
            $driver = $prefix + "`n" + $script:JdkSelection + "`nWrite-Output `$jdkArch`nWrite-Output 'would-download'"
            Set-Content -LiteralPath $fixture -Value $driver -Encoding utf8NoBOM
            Invoke-BoundedNativeCommand -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-File', $fixture) -TimeoutSeconds 10 `
                -Environment @{ YURUNA_CIM_MODE=$Mode; YURUNA_NATIVE_ARCH=[string]$Native; PROCESSOR_ARCHITECTURE=$Process }
        }
    }
    It 'selects <Expected> for native code <Native> with process architecture <Process>' -ForEach @(
        @{ Native=12; Process='AMD64'; Expected='aarch64' }
        @{ Native=12; Process='ARM64'; Expected='aarch64' }
        @{ Native=9; Process='ARM64'; Expected='x64' }
        @{ Native=9; Process='x86'; Expected='x64' }
    ) {
        $script:JdkSelection | Should -Not -Match 'PROCESSOR_ARCHITECTURE|RuntimeInformation'
        $result = Invoke-JdkArchitectureFixture -Mode healthy -Native $Native -Process $Process
        $result.ExitCode | Should -Be 0
        ($result.StdOut -split '\r?\n')[0] | Should -BeExactly $Expected
        $result.StdOut | Should -Match 'would-download'
    }
    It 'rejects unsupported native processor <Native> before a JDK download' -ForEach @(
        @{ Native=0; Process='x86' }, @{ Native=5; Process='ARM' }
    ) {
        $result = Invoke-JdkArchitectureFixture -Mode healthy -Native $Native -Process $Process
        $result.ExitCode | Should -Not -Be 0
        $result.StdErr | Should -Match 'Unsupported native processor architecture'
        $result.StdOut | Should -Not -Match 'would-download'
    }
    It 'stops before any download when the native processor query is <Mode>' -ForEach @(
        @{ Mode='failed' }, @{ Mode='empty' }
    ) {
        $result = Invoke-JdkArchitectureFixture -Mode $Mode -Native 12 -Process AMD64
        $result.ExitCode | Should -Not -Be 0
        $result.StdOut | Should -Not -Match 'would-download'
        $result.StdErr | Should -Match 'CIM query failed|Cannot determine the native processor architecture'
    }
}

Describe 'Windows guest update architecture follows the native processor' {
    BeforeAll {
        $source = Get-Content (Join-Path $script:RepoRoot 'guest/windows.11/windows.11.update.ps1') -Raw
        $start = $source.IndexOf('# --- REGION: Detect architecture')
        $end = $source.IndexOf('# --- REGION: Ensure PowerShell is installed', $start)
        if ($start -lt 0 -or $end -lt 0) { throw 'Guest update architecture phase was not found' }
        $script:UpdateArchitecture = $source.Substring($start, $end - $start)
        function Invoke-UpdateArchitectureFixture {
            <# Runs the actual update architecture phase without any package commands. #>
            param([string]$Mode, [int]$Native, [string]$Process)
            $prefix = @'
function Get-CimInstance {
    [CmdletBinding()]
    param([string]$ClassName, [string]$Property)
    if ($ClassName -ne 'Win32_Processor' -or $Property -ne 'Architecture') { throw 'Native architecture query changed' }
    if ($env:YURUNA_CIM_MODE -eq 'failed') { Write-Error 'fixture CIM query failed'; return }
    if ($env:YURUNA_CIM_MODE -eq 'empty') { return }
    if ($env:YURUNA_CIM_MODE -eq 'missing-property') { return [pscustomobject]@{ DeviceID='fixture' } }
    [pscustomobject]@{ Architecture=[int]$env:YURUNA_NATIVE_ARCH }
}
'@
            $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.ps1')
            $driver = $prefix + "`n" + $script:UpdateArchitecture + "`nWrite-Output 'would-install'"
            Set-Content -LiteralPath $fixture -Value $driver -Encoding utf8NoBOM
            Invoke-BoundedNativeCommand -FilePath $script:Pwsh -ArgumentList @('-NoProfile', '-File', $fixture) -TimeoutSeconds 10 `
                -Environment @{ YURUNA_CIM_MODE=$Mode; YURUNA_NATIVE_ARCH=[string]$Native; PROCESSOR_ARCHITECTURE=$Process }
        }
    }
    It 'reports <Expected> for native code <Native> despite process architecture <Process>' -ForEach @(
        @{ Native=12; Process='AMD64'; Expected='ARM64' }
        @{ Native=12; Process='ARM64'; Expected='ARM64' }
        @{ Native=9; Process='ARM64'; Expected='AMD64' }
        @{ Native=9; Process='x86'; Expected='AMD64' }
    ) {
        $result = Invoke-UpdateArchitectureFixture -Mode healthy -Native $Native -Process $Process
        $result.ExitCode | Should -Be 0
        $result.StdOut | Should -Match "Detected architecture: $Expected"
        $result.StdOut | Should -Match 'would-install'
    }
    It 'rejects unsupported native code <Native> before package installation' -ForEach @(
        @{ Native=0 }, @{ Native=5 }, @{ Native=99 }
    ) {
        $result = Invoke-UpdateArchitectureFixture -Mode healthy -Native $Native -Process AMD64
        $result.ExitCode | Should -Not -Be 0
        $result.StdOut | Should -Match "Unsupported architecture: Unknown \($Native\)"
        $result.StdOut | Should -Not -Match 'would-install'
    }
    It 'stops before package installation when its native query is <Mode>' -ForEach @(
        @{ Mode='failed' }, @{ Mode='empty' }, @{ Mode='missing-property' }
    ) {
        $result = Invoke-UpdateArchitectureFixture -Mode $Mode -Native 12 -Process AMD64
        $result.ExitCode | Should -Not -Be 0
        $result.StdOut | Should -Not -Match 'would-install'
        $result.StdErr | Should -Match 'CIM query failed|Cannot determine the native processor architecture'
    }
}

Describe 'macOS PowerShell package acceptance matches Linux checksum semantics' {
    BeforeAll {
        $source = Get-Content (Join-Path $script:RepoRoot 'guest/macos.26/macos.26.update.sh') -Raw
        $start = $source.IndexOf('# --- REGION: Ensure PowerShell is installed')
        $end = $source.IndexOf('# --- REGION: Install powershell-yaml module', $start)
        if ($start -lt 0 -or $end -lt 0) { throw 'macOS PowerShell package phase was not found' }
        $script:MacPublisherPhase = $source.Substring($start, $end - $start)
        function Invoke-MacPublisherFixture {
            <# Verifies local package/checksum bytes through the shipped phase without downloading or installing. #>
            param([string]$Mode)
            $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $fixture
            $prefix = @'
set -euo pipefail
export TMPDIR="$FIXTURE_ROOT"
printf 'fixture PowerShell package bytes\n' > "$FIXTURE_ROOT/source.pkg"
digest=$(shasum -a 256 "$FIXTURE_ROOT/source.pkg" | awk '{print $1}')
case "$FIXTURE_MODE" in
    uppercase|utf16-uppercase) digest=$(printf '%s' "$digest" | tr 'a-f' 'A-F') ;;
    mixed-case) digest=$(printf '%s' "$digest" | tr 'a-c' 'A-C') ;;
    mismatch) digest=$(printf '%064d' 0) ;;
    malformed-checksum) digest=not-a-sha256 ;;
esac
package=powershell-7.6.6-osx-arm64.pkg
[ "$FIXTURE_MODE" != missing-checksum ] || package=another-package.pkg
printf '%s  %s\n' "$digest" "$package" > "$FIXTURE_ROOT/hashes.sha256"
if [ "$FIXTURE_MODE" = utf16-uppercase ]; then
    iconv -f UTF-8 -t UTF-16 "$FIXTURE_ROOT/hashes.sha256" > "$FIXTURE_ROOT/hashes.utf16"
    mv "$FIXTURE_ROOT/hashes.utf16" "$FIXTURE_ROOT/hashes.sha256"
fi
command() {
    if [ "$1" = '-v' ] && [ "$2" = pwsh ]; then return 1; fi
    builtin command "$@"
}
curl() {
    printf 'curl %s\n' "$*" >> "$FIXTURE_ROOT/calls"
    for url in "$@"; do :; done
    if [ "$url" = https://github.com/PowerShell/PowerShell/releases/latest ]; then
        printf 'https://github.com/PowerShell/PowerShell/releases/tag/v7.6.6'
        return 0
    fi
    output=''
    while [ "$#" -gt 0 ]; do
        if [ "$1" = '-o' ]; then shift; output=$1; fi
        shift
    done
    [ -n "$output" ] || return 91
    case "$url" in
        */powershell-7.6.6-osx-arm64.pkg)
            if [ "$FIXTURE_MODE" = malformed-download ]; then
                head -c 3 "$FIXTURE_ROOT/source.pkg" > "$output"
            else
                cp "$FIXTURE_ROOT/source.pkg" "$output"
            fi
            [ "$FIXTURE_MODE" != failed-download ] || return 22
            ;;
        */hashes.sha256) cp "$FIXTURE_ROOT/hashes.sha256" "$output" ;;
        *) return 92 ;;
    esac
}
sudo() {
    [ "$1" = installer ] || return 93
    shift
    printf 'installer %s\n' "$*" >> "$FIXTURE_ROOT/calls"
}
pwsh() { printf 'pwsh %s\n' "$*" >> "$FIXTURE_ROOT/calls"; }
'@
            $entry = Join-Path $fixture 'fixture.sh'
            Set-Content -LiteralPath $entry -Value ($prefix + "`n" + $script:MacPublisherPhase + "`necho phase-complete") -Encoding utf8NoBOM
            $result = Invoke-BoundedNativeCommand -FilePath (Get-Command bash).Source -ArgumentList @($entry) -TimeoutSeconds 15 `
                -Environment @{ FIXTURE_ROOT=$fixture; FIXTURE_MODE=$Mode }
            [pscustomobject]@{ Process=$result; Calls=(Get-Content (Join-Path $fixture 'calls') -Raw); Root=$fixture }
        }
    }
    It 'accepts verified <Mode> publisher digests before invoking the installer' -ForEach @(
        @{ Mode='lowercase' }, @{ Mode='uppercase' }, @{ Mode='mixed-case' }, @{ Mode='utf16-uppercase' }
    ) -Skip:(-not $script:CanRunMacPublisher) {
        $state = Invoke-MacPublisherFixture -Mode $Mode
        $state.Process.ExitCode | Should -Be 0
        $state.Calls | Should -Match '(?m)^installer -pkg .*powershell-7\.6\.6-osx-arm64\.pkg -target /$'
        $state.Calls | Should -Match '(?m)^pwsh --version$'
        $state.Process.StdOut | Should -Match 'phase-complete'
        @(Get-ChildItem $state.Root -Directory -Filter 'yuruna-pwsh.*').Count | Should -Be 0
    }
    It 'rejects <Mode> before any installer invocation and cleans private downloads' -ForEach @(
        @{ Mode='mismatch' }, @{ Mode='malformed-checksum' }, @{ Mode='missing-checksum' }
        @{ Mode='malformed-download' }, @{ Mode='failed-download' }
    ) -Skip:(-not $script:CanRunMacPublisher) {
        $state = Invoke-MacPublisherFixture -Mode $Mode
        $state.Process.ExitCode | Should -Not -Be 0
        $state.Calls | Should -Not -Match '(?m)^installer |(?m)^pwsh '
        $state.Process.StdOut | Should -Not -Match 'phase-complete'
        @(Get-ChildItem $state.Root -Directory -Filter 'yuruna-pwsh.*').Count | Should -Be 0
    }
}

Describe 'Service seeds accept only complete framework sources' {
    It '<Service> publishes a validated host archive' -ForEach @(
        @{ Service='stash' }, @{ Service='pool-control' }, @{ Service='download-agent' }
    ) -Skip:(-not $script:CanRunBash) {
        $result = Invoke-ServiceFrameworkFixture $Service healthy
        $result.Version | Should -BeExactly host-version
        $result.Marker | Should -Match '(?m)^source=host$'
        $result.Attempts | Should -Be 1
        $result.Calls | Should -Not -Match '(?m)^git '
        Test-Path (Join-Path $result.Root 'checkout/old.txt') | Should -BeFalse
        @(Get-ChildItem $result.Root -Filter 'checkout.fetch.*').Count | Should -Be 0
    }
    It '<Service> rejects <Mode> and uses its validated mirror after six attempts' -ForEach @(
        @{ Service='stash'; Mode='transfer-error' }, @{ Service='pool-control'; Mode='transfer-error' }, @{ Service='download-agent'; Mode='transfer-error' }
        @{ Service='stash'; Mode='broken-archive' }, @{ Service='pool-control'; Mode='broken-archive' }, @{ Service='download-agent'; Mode='broken-archive' }
        @{ Service='stash'; Mode='missing-version' }, @{ Service='pool-control'; Mode='missing-version' }, @{ Service='download-agent'; Mode='missing-version' }
        @{ Service='stash'; Mode='empty-version' }, @{ Service='pool-control'; Mode='empty-version' }, @{ Service='download-agent'; Mode='empty-version' }
        @{ Service='stash'; Mode='directory-version' }, @{ Service='pool-control'; Mode='directory-version' }, @{ Service='download-agent'; Mode='directory-version' }
        @{ Service='stash'; Mode='truncated-archive' }, @{ Service='pool-control'; Mode='truncated-archive' }, @{ Service='download-agent'; Mode='truncated-archive' }
    ) -Skip:(-not $script:CanRunBash) {
        $result = Invoke-ServiceFrameworkFixture $Service $Mode
        $result.Version | Should -BeExactly mirror-version
        $result.Marker | Should -Match '(?m)^source=mirror$'
        $result.Attempts | Should -Be 6
        @([regex]::Matches($result.Calls, '(?m)^sleep 10$')).Count | Should -Be 5
        $result.Calls | Should -Match '(?m)^git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 clone --depth 1 '
        Test-Path (Join-Path $result.Root 'checkout/partial.txt') | Should -BeFalse
        if ($Mode -eq 'transfer-error') { $result.Calls | Should -Not -Match '(?m)^tar ' }
    }
    It '<Service> retries a failed transfer before accepting the host' -ForEach @(
        @{ Service='stash' }, @{ Service='pool-control' }, @{ Service='download-agent' }
    ) -Skip:(-not $script:CanRunBash) {
        $result = Invoke-ServiceFrameworkFixture $Service retry
        $result.Version | Should -BeExactly host-version
        $result.Marker | Should -Match '(?m)^source=host$'
        $result.Attempts | Should -Be 2
    }
    It '<Service> retains the previous checkout and provenance after <Mode>' -ForEach @(
        @{ Service='stash'; Mode='all-fail' }, @{ Service='pool-control'; Mode='all-fail' }, @{ Service='download-agent'; Mode='all-fail' }
        @{ Service='stash'; Mode='mirror-invalid' }, @{ Service='pool-control'; Mode='mirror-invalid' }, @{ Service='download-agent'; Mode='mirror-invalid' }
        @{ Service='stash'; Mode='promotion-error' }, @{ Service='pool-control'; Mode='promotion-error' }, @{ Service='download-agent'; Mode='promotion-error' }
        @{ Service='stash'; Mode='staging-error' }, @{ Service='pool-control'; Mode='staging-error' }, @{ Service='download-agent'; Mode='staging-error' }
    ) -Skip:(-not $script:CanRunBash) {
        $result = Invoke-ServiceFrameworkFixture $Service $Mode
        $result.Version | Should -BeExactly previous
        $result.Marker.Trim() | Should -BeExactly prior-source
        Test-Path (Join-Path $result.Root 'checkout/old.txt') | Should -BeTrue
        $result.Process.StdErr | Should -Match 'could not obtain the framework source'
        @(Get-ChildItem $result.Root -Filter 'checkout.fetch.*').Count | Should -Be 0
    }
}

Describe 'Service seed rollback keeps recoverable source evidence' {
    It '<Service> retains its private backup when promotion and restoration both fail' -ForEach @(
        @{ Service='stash' }, @{ Service='pool-control' }, @{ Service='download-agent' }
    ) -Skip:(-not $script:CanRunBash) {
        $result = Invoke-ServiceFrameworkFixture $Service rollback-error
        $result.Marker.Trim() | Should -BeExactly prior-source
        $result.Version | Should -BeExactly ''
        $staging = @(Get-ChildItem $result.Root -Filter 'checkout.fetch.*')
        $staging.Count | Should -Be 1
        (Get-Content (Join-Path $staging[0].FullName 'previous/VERSION') -Raw).Trim() | Should -BeExactly previous
        Test-Path (Join-Path $staging[0].FullName 'previous/old.txt') | Should -BeTrue
        $result.Process.StdErr | Should -Match 'previous checkout retained.*after restore failed'
    }
}

Describe 'Guest update framework acceptance is consistent across archive paths' {
    It '<Platform> accepts the complete host checkout and falls back for <Mode>' -ForEach @(
        foreach ($platform in 'Library', 'Ubuntu', 'Amazon', 'MacOS') {
            foreach ($mode in 'healthy', 'missing-version', 'empty-version', 'directory-version', 'transfer-error') {
                @{ Platform=$platform; Mode=$mode }
            }
        }
    ) -Skip:(-not $script:CanRunBash) {
        $result = Invoke-UpdateFrameworkFixture $Platform $Mode
        $result.Process.ExitCode | Should -Be 0 -Because $result.Process.StdErr
        if ($Mode -eq 'healthy') {
            $result.Version | Should -BeExactly host-version
            $result.Cloned | Should -BeFalse
        } else {
            $result.Version | Should -BeExactly mirror-version
            $result.Cloned | Should -BeTrue
        }
    }
    It '<Platform> removes an early archive with <Mode> instead of announcing availability' -ForEach @(
        foreach ($platform in 'Ubuntu', 'Amazon', 'MacOS') {
            foreach ($mode in 'missing-version', 'empty-version', 'directory-version') {
                @{ Platform=$platform; Mode=$mode }
            }
        }
    ) -Skip:(-not $script:CanRunBash) {
        $result = Invoke-UpdateFrameworkFixture $Platform $Mode -Early
        $result.Process.ExitCode | Should -Be 0 -Because $result.Process.StdErr
        $result.Exists | Should -BeFalse
        $result.Process.StdOut | Should -Not -Match 'framework available'
        $result.Cloned | Should -BeFalse
    }
}
