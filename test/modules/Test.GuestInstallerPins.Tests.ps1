<#PSScriptInfo
.VERSION 2026.10.31
.GUID 428b3db5-3681-402e-9563-08441a6397e3
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guest installer pin digest sha256 pester
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
    Third-party installer artifacts reach a guest only after their pinned
    SHA-256 matches.
.DESCRIPTION
    The install regions of the guest scripts run under bash exactly as shipped,
    with the download, sudo, apt and probe commands replaced by recorders, so a
    case observes whether anything was installed or executed after a digest
    mismatch. Static cases keep the manifest, the dependency checker and the
    caching proxy's warm job on the same pins.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:Bash = Get-Command bash -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $script:K8s = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'guest/shared/ubuntu.k8s.sh'))
    $script:Lib = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'automation/yuruna-retry.sh'))
    $script:VersionsPath = Join-Path $script:RepoRoot 'automation/yuruna-versions.sh'
    $script:Versions = [IO.File]::ReadAllText($script:VersionsPath)
    $script:ProxySeed = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'host/vmconfig/caching-proxy-service.base.user-data'))

    function Get-TextBetween {
        <# .SYNOPSIS
            The text from the first occurrence of Start up to (not including) End.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param([string]$Source, [string]$Start, [string]$End)
        $i = $Source.IndexOf($Start, [StringComparison]::Ordinal)
        if ($i -lt 0) { throw "Start marker not found: $Start" }
        $j = $Source.IndexOf($End, $i + $Start.Length, [StringComparison]::Ordinal)
        if ($j -lt 0) { throw "End marker not found: $End" }
        return $Source.Substring($i, $j - $i)
    }

    $script:VerifyFunction = (Get-TextBetween -Source $script:Lib -Start 'yuruna_verify_sha256() {' -End "`n}`n") + "`n}`n"

    function Get-Sha256Hex {
        <# .SYNOPSIS
            Lowercase SHA-256 of a file.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param([string]$Path)
        return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    }

    function Invoke-InstallRegion {
        <# .SYNOPSIS
            Run one shipped install region with recording stubs; return its exit
            code, its output and the recorded commands.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Writes isolated test fixture files only.')]
        [CmdletBinding()]
        [OutputType([pscustomobject])]
        param([string]$Region, [string]$Payload, [hashtable]$Environment, [string]$ExtraStubs = '')
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($dir) | Out-Null
        $log = Join-Path $dir 'log'
        [IO.File]::WriteAllText($log, '')
        $exports = ($Environment.GetEnumerator() | ForEach-Object { "export $($_.Key)='$($_.Value)'" }) -join "`n"
        $prefix = @'
set -euo pipefail
fixture_dir="$1"
payload="$2"
fixture_log="$fixture_dir/log"
dpkg() { echo amd64; }
curl_retry() {
    local out=""
    while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
    printf 'DOWNLOAD\n' >> "$fixture_log"
    cp "$payload" "$out"
}
wget_try() { printf 'DOWNLOAD\n' >> "$fixture_log"; cp "$payload" "$2"; }
sudo() { printf 'SUDO %s\n' "$*" >> "$fixture_log"; }
apt_retry() { printf 'APT %s\n' "$*" >> "$fixture_log"; }
assert_tool_runnable() { printf 'PROBE %s\n' "$*" >> "$fixture_log"; }
'@
        $body = $prefix + "`n" + $exports + "`n" + $ExtraStubs + "`n" + $script:VerifyFunction + "`n" + $Region + "`nprintf 'REGION-COMPLETE\n'`n"
        $fixture = Join-Path $dir 'fixture.sh'
        [IO.File]::WriteAllText($fixture, $body, [Text.UTF8Encoding]::new($false))
        $PSNativeCommandUseErrorActionPreference = $false
        $output = & $script:Bash.Source $fixture $dir $Payload 2>&1 | Out-String
        return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $output; Log = [IO.File]::ReadAllText($log); Dir = $dir }
    }

    function New-TarPayload {
        <# .SYNOPSIS
            A .tar.gz holding one executable at the given relative path.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Writes isolated test fixture files only.')]
        [CmdletBinding()]
        [OutputType([string])]
        param([string]$Member)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $file = Join-Path $root $Member
        [IO.Directory]::CreateDirectory((Split-Path -Parent $file)) | Out-Null
        [IO.File]::WriteAllText($file, "#!/bin/sh`necho fixture`n")
        $archive = "$root.tar.gz"
        & tar -czf $archive -C $root $Member
        return $archive
    }

    function New-TextPayload {
        <# .SYNOPSIS
            A file with the given content.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Writes isolated test fixture files only.')]
        [CmdletBinding()]
        [OutputType([string])]
        param([string]$Content)
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($path, $Content, [Text.UTF8Encoding]::new($false))
        return $path
    }

    $script:WrongDigest = '0' * 64
}

Describe 'Helm installs only the pinned, verified release tarball' {
    BeforeAll {
        $script:HelmRegion = Get-TextBetween -Source $script:K8s -Start '# --- REGION: Install Helm' -End '# --- REGION: Install OpenTofu'
        $script:HelmPayload = New-TarPayload -Member 'linux-amd64/helm'
    }
    It 'installs the binary after the digest matches' {
        if (-not $script:Bash -or $IsWindows) { Set-ItResult -Skipped -Because 'Linux guest Bash fixture requires a Unix Bash path.'; return }
        $result = Invoke-InstallRegion -Region $script:HelmRegion -Payload $script:HelmPayload -Environment @{
            YURUNA_HELM_VERSION = '4.3.1'; YURUNA_HELM_SHA256_AMD64 = (Get-Sha256Hex $script:HelmPayload) }
        $result.Code | Should -Be 0 -Because $result.Output
        $result.Log | Should -Match 'SUDO install -m 0755 \S+/linux-amd64/helm /usr/local/bin/helm'
        $result.Log | Should -Match 'PROBE helm version --short'
    }
    It 'installs nothing and stops when the digest does not match' {
        if (-not $script:Bash -or $IsWindows) { Set-ItResult -Skipped -Because 'Linux guest Bash fixture requires a Unix Bash path.'; return }
        $result = Invoke-InstallRegion -Region $script:HelmRegion -Payload $script:HelmPayload -Environment @{
            YURUNA_HELM_VERSION = '4.3.1'; YURUNA_HELM_SHA256_AMD64 = $script:WrongDigest }
        $result.Code | Should -Be 1
        $result.Output | Should -Match 'sha256 verify: helm-v4\.3\.1-linux-amd64\.tar\.gz has SHA-256'
        $result.Output | Should -Match 'Helm 4\.3\.1 could not be downloaded, verified or installed'
        $result.Log | Should -Not -Match 'SUDO|PROBE'
    }
    It 'stops when the manifest has no digest for this architecture' {
        if (-not $script:Bash -or $IsWindows) { Set-ItResult -Skipped -Because 'Linux guest Bash fixture requires a Unix Bash path.'; return }
        $result = Invoke-InstallRegion -Region $script:HelmRegion -Payload $script:HelmPayload -Environment @{ YURUNA_HELM_VERSION = '4.3.1' }
        $result.Code | Should -Be 1
        $result.Output | Should -Match 'no valid pinned digest'
        $result.Log | Should -Not -Match 'SUDO'
    }
    It 'no longer runs an upstream installer script' {
        $script:HelmRegion | Should -Not -Match 'get-helm'
        $script:HelmRegion | Should -Match ([regex]::Escape('https://get.helm.sh/helm-v${YURUNA_HELM_VERSION}-linux-${DEB_ARCH}.tar.gz'))
    }
}

Describe 'OpenTofu installs only the pinned, verified release tarball' {
    BeforeAll {
        $script:TofuRegion = Get-TextBetween -Source $script:K8s -Start '# --- REGION: Install OpenTofu' -End '# --- REGION: Install mkcert'
        $script:TofuPayload = New-TarPayload -Member 'tofu'
        # command -v tofu finds nothing until the link is recorded, then a stand-in
        # that prints the pinned version, as the installed binary would.
        $script:TofuStubs = @'
printf '#!/bin/sh\necho "OpenTofu v%s"\n' "$YURUNA_OPENTOFU_VERSION" > "$fixture_dir/tofu"
chmod +x "$fixture_dir/tofu"
command() {
    if [ "${1:-}" = -v ] && [ "${2:-}" = tofu ]; then
        grep -q '^SUDO ln -sf /opt/opentofu/tofu /usr/local/bin/tofu' "$fixture_log" && { echo "$fixture_dir/tofu"; return 0; }
        return 1
    fi
    builtin command "$@"
}
'@
    }
    It 'unpacks into /opt/opentofu and links it after the digest matches' {
        if (-not $script:Bash -or $IsWindows) { Set-ItResult -Skipped -Because 'Linux guest Bash fixture requires a Unix Bash path.'; return }
        $result = Invoke-InstallRegion -Region $script:TofuRegion -Payload $script:TofuPayload -ExtraStubs $script:TofuStubs -Environment @{
            YURUNA_OPENTOFU_VERSION = '1.13.1'; YURUNA_OPENTOFU_SHA256_AMD64 = (Get-Sha256Hex $script:TofuPayload) }
        $result.Code | Should -Be 0 -Because $result.Output
        $result.Log | Should -Match 'SUDO tar -xzf \S+/tofu\.tar\.gz -C /opt/opentofu'
        $result.Log | Should -Match 'SUDO ln -sf /opt/opentofu/tofu /usr/local/bin/tofu'
        $result.Output | Should -Match 'REGION-COMPLETE'
    }
    It 'unpacks nothing and stops when the digest does not match' {
        if (-not $script:Bash -or $IsWindows) { Set-ItResult -Skipped -Because 'Linux guest Bash fixture requires a Unix Bash path.'; return }
        $result = Invoke-InstallRegion -Region $script:TofuRegion -Payload $script:TofuPayload -ExtraStubs $script:TofuStubs -Environment @{
            YURUNA_OPENTOFU_VERSION = '1.13.1'; YURUNA_OPENTOFU_SHA256_AMD64 = $script:WrongDigest }
        $result.Code | Should -Be 1
        $result.Output | Should -Match 'OpenTofu 1\.13\.1 could not be downloaded, verified or installed'
        $result.Log | Should -Not -Match 'SUDO'
    }
    It 'no longer runs the upstream installer script' {
        $script:TofuRegion | Should -Not -Match 'install-opentofu'
    }
}

Describe 'mkcert installs only the pinned, verified release binary' {
    BeforeAll {
        $script:MkcertPayload = New-TextPayload -Content "#!/bin/sh`necho mkcert`n"
    }
    It 'installs the release binary after the digest matches' {
        if (-not $script:Bash -or $IsWindows) { Set-ItResult -Skipped -Because 'Linux guest Bash fixture requires a Unix Bash path.'; return }
        $region = Get-TextBetween -Source $script:K8s -Start '# --- REGION: Install mkcert' -End '# --- REGION: Create the HTTPS development certificate'
        $staged = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $result = Invoke-InstallRegion -Region ($region.Replace('/tmp/mkcert', $staged)) -Payload $script:MkcertPayload -Environment @{
            YURUNA_MKCERT_VERSION = '1.4.4'; YURUNA_MKCERT_SHA256_AMD64 = (Get-Sha256Hex $script:MkcertPayload) }
        $result.Code | Should -Be 0 -Because $result.Output
        $result.Log | Should -Match ([regex]::Escape("SUDO install -m 0755 $staged /usr/local/bin/mkcert"))
        $result.Log | Should -Not -Match 'APT'
        Test-Path -LiteralPath $staged | Should -BeFalse
    }
    It 'falls back to the apt package, never the unverified download, on a mismatch' {
        if (-not $script:Bash -or $IsWindows) { Set-ItResult -Skipped -Because 'Linux guest Bash fixture requires a Unix Bash path.'; return }
        $region = Get-TextBetween -Source $script:K8s -Start '# --- REGION: Install mkcert' -End '# --- REGION: Create the HTTPS development certificate'
        $staged = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $result = Invoke-InstallRegion -Region ($region.Replace('/tmp/mkcert', $staged)) -Payload $script:MkcertPayload -Environment @{
            YURUNA_MKCERT_VERSION = '1.4.4'; YURUNA_MKCERT_SHA256_AMD64 = $script:WrongDigest }
        $result.Code | Should -Be 0 -Because $result.Output
        $result.Log | Should -Match 'APT sudo apt-get install -y mkcert'
        $result.Log | Should -Not -Match ([regex]::Escape("SUDO install -m 0755 $staged"))
        Test-Path -LiteralPath $staged | Should -BeFalse
    }
    It 'asks for the pinned release, not the latest redirector' {
        $script:K8s | Should -Not -Match 'dl\.filippo\.io'
        $script:K8s | Should -Match ([regex]::Escape('https://github.com/FiloSottile/mkcert/releases/download/v${YURUNA_MKCERT_VERSION}/${MKCERT_ASSET}'))
    }
}

Describe 'The flannel manifest is the pinned release, verified before it is applied' {
    It 'applies nothing when the manifest does not match its digest' {
        if (-not $script:Bash -or $IsWindows) { Set-ItResult -Skipped -Because 'Linux guest Bash fixture requires a Unix Bash path.'; return }
        $region = Get-TextBetween -Source $script:K8s -Start 'FLANNEL_MANIFEST=/tmp/kube-flannel.yml' -End '# --- REGION: https://yuruna.link/42f6b05f-0020'
        $manifest = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $payload = New-TextPayload -Content "image: ghcr.io/flannel-io/flannel:v0.28.10`n"
        $region = $region.Replace('/tmp/kube-flannel.yml', $manifest)
        $bad = Invoke-InstallRegion -Region $region -Payload $payload -Environment @{
            YURUNA_FLANNEL_VERSION = '0.28.10'; YURUNA_FLANNEL_MANIFEST_SHA256 = $script:WrongDigest }
        $bad.Code | Should -Be 1
        $bad.Output | Should -Match 'refusing to apply it'
        $good = Invoke-InstallRegion -Region $region -Payload $payload -Environment @{
            YURUNA_FLANNEL_VERSION = '0.28.10'; YURUNA_FLANNEL_MANIFEST_SHA256 = (Get-Sha256Hex $payload) }
        $good.Code | Should -Be 0 -Because $good.Output
        $good.Output | Should -Match 'REGION-COMPLETE'
    }
    It 'never resolves the latest release at install time' {
        $script:K8s | Should -Not -Match 'flannel/releases/latest'
        $script:K8s | Should -Match ([regex]::Escape('FLANNEL_TAG="v${YURUNA_FLANNEL_VERSION}"'))
    }
}

Describe 'The nvm installer runs only after it matches its digest on <Script>' -ForEach @(
    @{ Script = 'guest/shared/ubuntu.n8n.sh' }, @{ Script = 'guest/shared/ubuntu.openclaw.sh' }
) {
    BeforeAll {
        $source = [IO.File]::ReadAllText((Join-Path $script:RepoRoot $Script))
        # The region ends at the cleanup line, not at the same text inside the trap.
        $script:NvmRegion = Get-TextBetween -Source $source -Start 'nvm_installer="$(mktemp' -End ("`n" + 'rm -f -- "$nvm_installer"')
    }
    It 'runs the downloaded installer after the digest matches' {
        if (-not $script:Bash -or $IsWindows) { Set-ItResult -Skipped -Because 'Linux guest Bash fixture requires a Unix Bash path.'; return }
        $payload = New-TextPayload -Content "printf 'INSTALLER-RAN\n' >> `"`$1`"`n"
        $region = $script:NvmRegion.Replace('bash "$nvm_installer"', 'bash "$nvm_installer" "$fixture_log"')
        $result = Invoke-InstallRegion -Region $region -Payload $payload -Environment @{
            YURUNA_NVM_VERSION = '0.40.8'; YURUNA_NVM_INSTALL_SHA256 = (Get-Sha256Hex $payload) }
        $result.Code | Should -Be 0 -Because $result.Output
        $result.Log | Should -Match 'INSTALLER-RAN'
    }
    It 'never runs a downloaded installer that does not match' {
        if (-not $script:Bash -or $IsWindows) { Set-ItResult -Skipped -Because 'Linux guest Bash fixture requires a Unix Bash path.'; return }
        $payload = New-TextPayload -Content "printf 'INSTALLER-RAN\n' >> `"`$1`"`n"
        $region = $script:NvmRegion.Replace('bash "$nvm_installer"', 'bash "$nvm_installer" "$fixture_log"')
        $result = Invoke-InstallRegion -Region $region -Payload $payload -Environment @{
            YURUNA_NVM_VERSION = '0.40.8'; YURUNA_NVM_INSTALL_SHA256 = $script:WrongDigest }
        $result.Code | Should -Be 1
        $result.Output | Should -Match 'sha256 verify: nvm v0\.40\.8 install\.sh has SHA-256'
        $result.Log | Should -Match 'DOWNLOAD'
        $result.Log | Should -Not -Match 'INSTALLER-RAN'
    }
}

Describe 'The .NET installer runs only after it matches its digest on <Script>' -ForEach @(
    @{ Script = 'guest/shared/ubuntu.code.sh' }, @{ Script = 'guest/amazon.linux.2023/amazon.linux.2023.code.sh' }
) {
    BeforeAll {
        $source = [IO.File]::ReadAllText((Join-Path $script:RepoRoot $Script))
        $script:DotnetRegion = Get-TextBetween -Source $source -Start '# The installer comes from a pinned commit' -End 'sudo ln -sf /usr/local/dotnet/dotnet'
        $script:DotnetPayload = New-TextPayload -Content "echo dotnet-install`n"
    }
    It 'runs the pinned installer after the digest matches' {
        if (-not $script:Bash -or $IsWindows) { Set-ItResult -Skipped -Because 'Linux guest Bash fixture requires a Unix Bash path.'; return }
        $staged = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $result = Invoke-InstallRegion -Region ($script:DotnetRegion.Replace('/tmp/dotnet-install.sh', $staged)) -Payload $script:DotnetPayload -Environment @{
            YURUNA_DOTNET_INSTALL_COMMIT = '4a37a9f9d1a061fc389d6515100336db4e51710e'; YURUNA_DOTNET_INSTALL_SHA256 = (Get-Sha256Hex $script:DotnetPayload) }
        $result.Code | Should -Be 0 -Because $result.Output
        $result.Log | Should -Match ([regex]::Escape("SUDO bash $staged --channel LTS --install-dir /usr/local/dotnet"))
    }
    It 'never runs an installer that does not match' {
        if (-not $script:Bash -or $IsWindows) { Set-ItResult -Skipped -Because 'Linux guest Bash fixture requires a Unix Bash path.'; return }
        $staged = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $result = Invoke-InstallRegion -Region ($script:DotnetRegion.Replace('/tmp/dotnet-install.sh', $staged)) -Payload $script:DotnetPayload -Environment @{
            YURUNA_DOTNET_INSTALL_COMMIT = '4a37a9f9d1a061fc389d6515100336db4e51710e'; YURUNA_DOTNET_INSTALL_SHA256 = $script:WrongDigest }
        $result.Code | Should -Be 1
        $result.Output | Should -Match 'refusing to run it'
        $result.Log | Should -Not -Match 'SUDO'
        Test-Path -LiteralPath $staged | Should -BeFalse
    }
    It 'stops before downloading when the manifest has no commit pin' {
        if (-not $script:Bash -or $IsWindows) { Set-ItResult -Skipped -Because 'Linux guest Bash fixture requires a Unix Bash path.'; return }
        $result = Invoke-InstallRegion -Region $script:DotnetRegion -Payload $script:DotnetPayload -Environment @{}
        $result.Code | Should -Be 1
        $result.Output | Should -Match 'no dotnet-install commit pin'
        $result.Log | Should -Not -Match 'DOWNLOAD|SUDO'
    }
}

Describe 'The Windows .NET installer is the pinned commit, checked before it runs' {
    It 'uses the commit the manifest names and compares the digest before invoking the script' {
        $win = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'guest/windows.11/windows.11.code.ps1'))
        $commit = [regex]::Match($script:Versions, '(?m)^export YURUNA_DOTNET_INSTALL_COMMIT=([0-9a-f]{40})$').Groups[1].Value
        $commit | Should -Not -BeNullOrEmpty
        $win | Should -Match ([regex]::Escape("`$dotnetInstallCommit = '$commit'"))
        $win | Should -Match "\`$dotnetInstallSha256 = '[0-9a-f]{64}'"
        $win | Should -Not -Match 'dot\.net/v1/dotnet-install'
        $check = $win.IndexOf('if ($dotnetInstallActual -ne $dotnetInstallSha256)', [StringComparison]::Ordinal)
        $run = $win.IndexOf('& $dotnetScript -Channel LTS', [StringComparison]::Ordinal)
        $check | Should -BeGreaterThan 0
        $run | Should -BeGreaterThan $check
    }
}

Describe 'Guest scripts never pipe a download into a shell' {
    It 'has no download piped into bash, sh or a root shell in <Path>' -ForEach @(
        Get-ChildItem -LiteralPath (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path 'guest') -Recurse -File |
            Where-Object { $_.Extension -in '.sh', '.ps1' } |
            ForEach-Object { @{ Path = $_.FullName } }
    ) {
        $lines = [IO.File]::ReadAllLines($Path) | Where-Object { $_ -notmatch '^\s*#' }
        $piped = @($lines | Where-Object { $_ -match '\b(curl|wget|curl_retry|wget_try|Invoke-WebRequest|Invoke-RestMethod|irm|iwr)\b.*\|\s*(sudo\s+)?(bash|sh|iex|Invoke-Expression)\b' })
        $piped | Should -BeNullOrEmpty
    }
    It 'reaches NodeSource on Amazon Linux through a repository file with a pinned key, not its setup script' -ForEach @(
        @{ Script = 'guest/amazon.linux.2023/amazon.linux.2023.n8n.sh' }, @{ Script = 'guest/amazon.linux.2023/amazon.linux.2023.openclaw.sh' }
    ) {
        $source = [IO.File]::ReadAllText((Join-Path $script:RepoRoot $Script))
        $source | Should -Not -Match 'rpm\.nodesource\.com/setup_'
        $verify = $source.IndexOf('_yuruna_verify_key_fpr "$_ns_key" 242B813831AF09562B6C46F76B88DA4E3AF28A14', [StringComparison]::Ordinal)
        $install = $source.IndexOf('sudo install -m 0644 "$_ns_key" /etc/pki/rpm-gpg/nodesource.asc', [StringComparison]::Ordinal)
        $verify | Should -BeGreaterThan 0
        $install | Should -BeGreaterThan $verify
        $source | Should -Match '(?m)^gpgcheck=1$'
        $source | Should -Match '(?m)^gpgkey=file:///etc/pki/rpm-gpg/nodesource\.asc$'
    }
}

Describe 'The version manifest carries a digest beside every downloaded artifact' {
    BeforeAll {
        $script:Pins = @{}
        foreach ($line in [IO.File]::ReadAllLines($script:VersionsPath)) {
            if ($line -match '^export (?<k>YURUNA_[A-Z0-9_]+)=(?<v>\S+)$') { $script:Pins[$Matches['k']] = $Matches['v'] }
        }
    }
    It 'holds well-formed digests for <Name>' -ForEach @(
        @{ Name = 'YURUNA_HELM_SHA256_AMD64' }, @{ Name = 'YURUNA_HELM_SHA256_ARM64' }
        @{ Name = 'YURUNA_OPENTOFU_SHA256_AMD64' }, @{ Name = 'YURUNA_OPENTOFU_SHA256_ARM64' }
        @{ Name = 'YURUNA_MKCERT_SHA256_AMD64' }, @{ Name = 'YURUNA_MKCERT_SHA256_ARM64' }
        @{ Name = 'YURUNA_FLANNEL_MANIFEST_SHA256' }, @{ Name = 'YURUNA_NVM_INSTALL_SHA256' }
        @{ Name = 'YURUNA_DOTNET_INSTALL_SHA256' }
    ) {
        $script:Pins.ContainsKey($Name) | Should -BeTrue
        $script:Pins[$Name] | Should -MatchExactly '^[0-9a-f]{64}$'
    }
    It 'lists every version pin in the dependency checker, so a bump is reported' {
        $checker = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'automation/Check-DependencyVersion.ps1'))
        foreach ($key in @($script:Pins.Keys | Where-Object { $_ -match '_(VERSION|MINOR|MAJOR)$' })) {
            $checker | Should -Match ("Key = '" + [regex]::Escape($key) + "'") -Because "$key needs a pinned row"
        }
    }
}

Describe 'The caching proxy warms the images of the pinned flannel release' {
    BeforeAll {
        $script:WarmRegion = Get-TextBetween -Source $script:ProxySeed -Start '      FLANNEL_TAG=""' -End '      CNI_REFS=""'
    }
    It 'takes the tag from the versions file and asks GitHub only without a pin' {
        if (-not $script:Bash -or $IsWindows) { Set-ItResult -Skipped -Because 'Linux guest Bash fixture requires a Unix Bash path.'; return }
        $driver = @'
set -u
latest_marker="$2"
curl() { printf 'Location: https://github.com/flannel-io/flannel/releases/tag/v9.9.9\r\n'; echo LATEST-ASKED >> "$latest_marker"; }
VERSIONS_TXT="$1"
'@ + "`n" + $script:WarmRegion + "`nprintf 'TAG=%s\n' `"`$FLANNEL_TAG`"`n"
        $fixture = Join-Path $TestDrive 'warm.sh'
        [IO.File]::WriteAllText($fixture, $driver, [Text.UTF8Encoding]::new($false))
        $PSNativeCommandUseErrorActionPreference = $false
        $marker = Join-Path $TestDrive 'latest-asked'
        $pinned = & $script:Bash.Source $fixture "export YURUNA_K8S_MINOR=1.37`nexport YURUNA_FLANNEL_VERSION=0.28.10" $marker 2>&1 | Out-String
        $pinned | Should -Match 'TAG=v0\.28\.10'
        Test-Path -LiteralPath $marker | Should -BeFalse
        $unpinned = & $script:Bash.Source $fixture "export YURUNA_K8S_MINOR=1.37" $marker 2>&1 | Out-String
        $unpinned | Should -Match 'TAG=v9\.9\.9'
        Test-Path -LiteralPath $marker | Should -BeTrue
    }
}

Describe 'The community zot dashboard is one reviewed, verified revision' {
    It 'fetches revision 2, checks its digest before the rewriter, and does not promise a retry that never runs' {
        $block = Get-TextBetween -Source $script:ProxySeed -Start '# --- REGION: https://yuruna.link/429f3d06-007c' -End '# --- REGION: https://yuruna.link/429f3d06-007d'
        $block | Should -Not -Match 'revisions/latest'
        $block | Should -Match 'dashboards/20501/revisions/2/download'
        $check = $block.IndexOf('sha256sum -c', [StringComparison]::Ordinal)
        $rewrite = $block.IndexOf('/usr/local/bin/yuruna-rewrite-zot-dashboard.py', [StringComparison]::Ordinal)
        $check | Should -BeGreaterThan 0
        $rewrite | Should -BeGreaterThan $check
        $block | Should -Not -Match 'next boot'
    }
}
