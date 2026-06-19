<#PSScriptInfo
.VERSION 2026.06.19
.GUID 42d9e0f1-a2b3-4c45-d678-9e0f1a2b3c47
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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
    Creates a Hyper-V VM that installs Ubuntu Server 24.04 in text mode.

.DESCRIPTION
    Uses the Server live ISO. The Server ISO's cdrom has linux-generic
    and a network-configured ubuntu.sources, so subiquity's
    install_kernel step always succeeds. First boot lands at the
    text-mode login prompt; the test harness's Test-Start sequence
    drives that prompt directly.
#>

param(
    [string]$VMName = "ubuntu-server01",
    # Forwarded by the test harness (Invoke-TestRunner -> Invoke-NewVM)
    # so every guest in a run agrees on one caching proxy URL. When
    # bound (even to ""), local discovery is skipped and this value is
    # used verbatim: "" = no cache, go direct; URL = use this. When NOT
    # bound (standalone run), fall back to the discovery block below.
    [string]$CachingProxyUrl,
    # OS user created by autoinstall and exercised by the test
    # sequences. The framework default 'yuuser24' is intentionally
    # unique/greppable (versus the cloud-image default 'ubuntu', which
    # is noisy in any text search) and version-tagged so 24.04 and 26.04
    # guests don't collide in shared logs. Multi-user future (gap 33)
    # will spawn additional users via a manifest -- no need to override here.
    [string]$Username = 'yuuser24'
)

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Output "Invalid VMName '$VMName'. Only alphanumeric characters, dots, hyphens, and underscores are allowed."
    exit 1
}

$ProgressPreference = 'SilentlyContinue'

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$commonModulePath = Join-Path -Path (Split-Path -Parent $ScriptDir) -ChildPath "modules/Yuruna.Host.psm1"
Import-Module -Name $commonModulePath -Force

Write-Verbose "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    Write-Output "Be careful."
    exit 1
}

# Assert-HyperVEnabled calls dism.exe directly instead of
# Get-WindowsOptionalFeature -- avoids the "Class not registered" COM
# failure on first post-install runs on fresh Windows 11.
if (-not (Assert-HyperVEnabled)) {
    Write-Output "Instructions: https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/quick-start/enable-hyper-v"
    exit 1
}

$downloadDir = (Get-VMHost).VirtualHardDiskPath
if (!(Test-Path -Path $downloadDir)) {
    Write-Output "The Hyper-V default VHDX folder does not exist: $downloadDir"
    exit 1
}

# === Seek the base image ===
# Auto-run Get-Image.ps1 once if the base image is missing; recheck and
# only error out when it's still missing afterward.
$baseImageName = "host.windows.hyper-v.guest.ubuntu.server.24"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"
if (!(Test-Path -Path $baseImageFile)) {
    $getImageScript = Join-Path $PSScriptRoot 'Get-Image.ps1'
    if (Test-Path -LiteralPath $getImageScript) {
        Write-Output "Base image missing: $baseImageFile"
        Write-Output "Auto-running $getImageScript to fetch it..."
        & pwsh -NoProfile -File $getImageScript
        $getImageExit = $LASTEXITCODE
        if ($getImageExit -ne 0) {
            Write-Error "Auto Get-Image.ps1 exited $getImageExit. Cannot create VM."
            exit 1
        }
    }
    if (!(Test-Path -Path $baseImageFile)) {
        Write-Error "Base image not found at '$baseImageFile' after auto Get-Image. Run Get-Image.ps1 manually."
        exit 1
    }
}

# Resolve the autoinstall password from the per-cycle authentication
# vault. Get-Password returns the stored value if present, else
# generates a fresh one (chained to whatever the previous guest in this
# cycle committed -- see test/extension/authentication/default.psm1).
# Cycle-end cleanup wipes the vault on success; a failed cycle leaves
# it in place for debugging.
$_repoRootForExt = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
$_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
$Password = Get-LocalOsPassword -Username $Username
if (-not $Password) { Write-Error "Get-LocalOsPassword returned empty for '$Username'."; exit 1 }
Write-Output "Password came from authentication mechanism: $_authActiveName"
Write-Output "See configuration at: $(Resolve-ExtensionAreaDir -Area 'authentication')"

# SHA-512 ($6$) password hash for the autoinstall HASH_PLACEHOLDER.
# ConvertTo-Sha512CryptHash centralises the openssl probe + the `--`
# end-of-options safety that keeps a leading-dash password
# (e.g. `-4aWj*CRw` from New-RandomPassword) from being parsed as an
# option. See Test.VMUtility\ConvertTo-Sha512CryptHash for rationale.
Import-Module (Join-Path $_repoRootForExt 'test/modules/Test.VMUtility.psm1') -Force -DisableNameChecking
try {
    $PasswordHash = ConvertTo-Sha512CryptHash -Plaintext $Password
} catch {
    Write-Error "Password hashing failed: $($_.Exception.Message)"
    exit 1
}

Write-Verbose "Creating VM '$VMName' using image: $baseImageFile"
# Provenance side-channel for the transcript. Emits "Provenance: <url>"
# when the sidecar is healthy; warns otherwise.
Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

$existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($existingVM) {
    Write-Output "VM '$VMName' exists. Deleting..."
    Hyper-V\Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    try {
        Hyper-V\Remove-VM -Name $VMName -Force -ErrorAction Stop
    } catch {
        # A half-removed VM (locked vhdx, permission, etc.) would trip
        # the next New-VM call with "already exists" and the outer loop
        # has no signal to recover. Dump live Hyper-V state so the
        # operator can clean orphan disks before retrying.
        $diag = Get-VM -Name $VMName -ErrorAction SilentlyContinue |
            Format-List Name, State, Status, Generation, Path | Out-String
        throw "Hyper-V\Remove-VM failed for '$VMName': $($_.Exception.Message)`nLive Hyper-V state:`n$diag"
    }
    # Hyper-V can return Remove-VM success while leaving a ghost entry;
    # a second Get-VM is the only reliable post-condition.
    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        throw "Hyper-V\Remove-VM returned success for '$VMName' but Get-VM still finds it; aborting before re-creation."
    }
    Write-Output "VM '$VMName' deleted."
}

# === Create copies and files for VM ===

# 512GB dynamically expanding VHDX
$vmDir = Join-Path $downloadDir $VMName
if (!(Test-Path -Path $vmDir)) {
    New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
}
$vhdxFile = Join-Path $vmDir "$VMName.vhdx"
if (Test-Path -Path $vhdxFile) {
    Remove-Item -Path $vhdxFile -Force
}
# 64 GB dynamic VHDX is enough headroom for the k8s + dotnet build
# workload yet stays a uniform cap across hosts.ubuntu.kvm /
# windows.hyper-v / macos.utm. Paired with sizing-policy: all in
# host/vmconfig/ubuntu.server.base.user-data so the root LV consumes the whole PV.
Write-Verbose "Creating 64GB dynamically expanding VHDX..."
New-VHD -Path $vhdxFile -SizeBytes 64GB -Dynamic | Out-Null

# Autoinstall seed ISO. 4-digit entropy is weak by design (10k cases)
# but enough to defeat the deterministic-path symlink trap: an attacker
# dropping a symlink at %TEMP%\seed_<VMName>\ before New-VM runs can't
# predict the trailing 4 digits per run.
$SeedDir = Join-Path $env:TEMP ("seed_${VMName}_{0:D4}" -f (Get-Random -Maximum 10000))
if (Test-Path -LiteralPath $SeedDir) { Remove-Item -LiteralPath $SeedDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $SeedDir | Out-Null

# user-data AND meta-data are shared under host/vmconfig/ (the meta-data is
# byte-identical across the three host platforms; ubuntu.server.24 and .26
# share one file). Anchor contract: automation/Yuruna.CloudInitTemplate.psm1.
$RepoRoot        = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
$HostVmConfigDir = Join-Path $RepoRoot 'host/vmconfig'
$BaseUserData    = Join-Path $HostVmConfigDir 'ubuntu.server.base.user-data'
$OverlayUserData = Join-Path $HostVmConfigDir 'ubuntu.server.hyperv.overlay.yml'
$MetaDataTemplate = Join-Path $HostVmConfigDir 'ubuntu.server.meta-data'
foreach ($p in @($BaseUserData, $OverlayUserData)) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Error "user-data template missing: $p"; exit 1 }
}
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force

# SSH public key used by the test harness.
$TestSshModule = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))) "test/modules/Test.Ssh.psm1"
Import-Module $TestSshModule -Force
$SshAuthorizedKey = Get-YurunaSshPublicKey
if (-not $SshAuthorizedKey) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

# Detect the caching-proxy VM and inject its proxy URL if available.
# Severity policy:
#   * No cache VM         -> WARNING, proceed (direct CDN)
#   * Cache VM stopped    -> WARNING, proceed (direct CDN)
#   * Cache running, :3128
#     doesn't answer      -> ERROR, exit 1
if ($PSBoundParameters.ContainsKey('CachingProxyUrl')) {
    # URL forwarded by the test runner. Skip discovery so this script
    # and the runner agree on one cache URL. On Hyper-V the race is
    # narrower than UTM (MAC-scoped neighbor lookup, not subnet scan),
    # but one source of truth still simplifies debugging.
    if ($CachingProxyUrl) {
        Write-Verbose "  caching proxy URL forwarded by caller: $CachingProxyUrl -- skipping local discovery."
    } else {
        Write-Verbose "  No proxy forwarded by caller -- guest will download directly."
    }
} else {
$CachingProxyUrl = ""
$cacheVM = Get-VM -Name "yuruna-caching-proxy" -ErrorAction SilentlyContinue
if (-not $cacheVM) {
    Write-Warning "  No yuruna-caching-proxy VM exists on this host. Guest will download packages directly from Ubuntu mirrors -- expect occasional 429 rate-limit failures on linux-firmware under load."
    Write-Warning "  To enable caching, run: host\windows.hyper-v\guest.caching-proxy\New-VM.ps1"
} elseif ($cacheVM.State -ne 'Running') {
    Write-Warning "  yuruna-caching-proxy VM exists but is '$($cacheVM.State)'. Guest will download directly (expect occasional 429s)."
    Write-Warning "  To enable caching: Start-VM yuruna-caching-proxy ; then wait for cloud-init to finish."
} else {
    # KVP+ARP discovery + :3128 probe live in Yuruna.Host.psm1
    # (Get-WorkingCachingProxyUrl). One module means this consumer, the
    # producer, and Start-CachingProxy.ps1's summary all see the same
    # answer (avoids the regression class where a KVP-only summary
    # reports "discovery failed" while the ARP path already found it).
    $CachingProxyUrl = Get-WorkingCachingProxyUrl -VMName "yuruna-caching-proxy"
    if ($CachingProxyUrl) {
        Write-Output "  yuruna-caching-proxy VM detected at $CachingProxyUrl -- guest will use local proxy."
    } else {
        $cacheIps = Get-CacheVmCandidateIp -VM $cacheVM
        $ipList = if ($cacheIps) { $cacheIps -join ', ' } else { '(none discovered)' }
        # $Host.UI.WriteLine keeps Write-Host-style color without the
        # PSScriptAnalyzer complaint.
        $detail = @"

=========================================================================
ERROR: yuruna-caching-proxy VM is running but port 3128 is not reachable.
=========================================================================
  Discovered IPs: $ipList

Aborting so this guest install doesn't silently fall back to direct
CDN access and hit the 429 rate limiter.

Accessing the yuruna-caching-proxy VM for debugging:
  * Console:  vmconnect localhost yuruna-caching-proxy
              login:    yuruna
              password: read the 'password:' field from
                test/status/runtime/yuruna-caching-proxy.yml
  * SSH:      ssh yuruna@<ip>

Rebuild the cache VM:
  host\windows.hyper-v\guest.caching-proxy\New-VM.ps1

To intentionally skip the cache:
  Stop-VM yuruna-caching-proxy   (guest will then WARN and download direct).
=========================================================================
"@
        $Host.UI.WriteLine([ConsoleColor]::Red, $Host.UI.RawUI.BackgroundColor, $detail)
        exit 1
    }
}
}

# Build the autoinstall apt block: always emit `geoip: false` + a pinned
# `primary:` mirror (deterministic election; `primary:` not `sources_list:`,
# see feedback_macos_utm_apt_block_resolute_curtin_trap.md).
# --- See https://yuruna.link/vmconfig#apt-proxy-block
#
# `$AptProxyLine` is appended to the end of the `uri:` line below: when a
# proxy is configured we want a leading newline + 4-space indent so the
# YAML lands at the same level as `geoip:` / `primary:`; when there's no
# proxy the whole expansion is empty. The closing `"@` MUST stay on its
# own line at column 0 -- required by PowerShell's here-string parser
# (inlining `$(...)"@` raises "The string is missing the terminator").
$AptProxyLine = if ($CachingProxyUrl) { "`n    proxy: $CachingProxyUrl" } else { "" }
$AptProxyBlock = @"
  apt:
    geoip: false
    primary:
      - arches: [default]
        uri: http://archive.ubuntu.com/ubuntu$($AptProxyLine)
    conf: |
      Acquire::Retries "5";
      Acquire::http::Timeout "120";
      Acquire::https::Timeout "120";
"@

# Pick a vSwitch FIRST -- prefer Yuruna-External (LAN-bridged) so the
# install VM gets a real LAN IP via DHCP and can reach the squid cache
# directly. Default Switch fallback works for hosts that can't create
# an External vSwitch (no LAN, Wi-Fi-only); install proceeds direct
# against Ubuntu mirrors. Switch choice MUST be resolved before
# Get-GuestReachableHostIp below (the host IP a guest reaches differs
# by topology: Default Switch = 172.x.x.x gateway; External = LAN IP).
$switchName = Get-OrCreateYurunaExternalSwitch
if (-not $switchName) {
    Write-Warning "External vSwitch unavailable -- falling back to 'Default Switch'."
    $switchName = 'Default Switch'
}

# Yuruna host (status server) IP+port baked into the seed for the dev
# iteration loop. Guest scripts read /etc/yuruna/host.env (written by
# the user-data late-commands) to resolve a local URL before falling
# back to GitHub. Default Switch's host IP changes across host
# reboots -- see Test-YurunaHost.ps1 for the in-guest probe.
$YurunaHostIp = Get-GuestReachableHostIp -SwitchName $switchName
if (-not $YurunaHostIp) { $YurunaHostIp = '' }
$YurunaHostPort = '8080'
$YurunaTestConfig = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/test.config.yml'
if (Test-Path $YurunaTestConfig) {
    try {
        $tc = Get-Content -Raw $YurunaTestConfig | ConvertFrom-Yaml -Ordered
        if ($tc.statusService.port) { $YurunaHostPort = "$($tc.statusService.port)" }
    } catch { Write-Verbose "test.config.yml parse failed: $_" }
}

# -- Fetch caching-proxy CA cert (base64-embedded in seed) -------------------
# Mirrors host/macos.utm/guest.ubuntu.server.24/New-VM.ps1. The installer's
# late-commands write the cert from CA_CERT_BASE64_PLACEHOLDER before
# any HTTPS apt fetch, so SSL-bump caching works from the first install
# request. Any failure (no URL, unreachable cache, HTTP error, empty
# body) leaves $CaCertBase64 empty and the guest's HTTPS proxy block
# becomes a no-op -- HTTP caching via :3128 still works.
$CaCertBase64 = ""
if ($CachingProxyUrl) {
    try {
        $uri = [System.Uri]$CachingProxyUrl
        $cacheHost = if ($uri.Host -match ':') { "[$($uri.Host)]" } else { $uri.Host }
        $cacheCaUrl = "http://$cacheHost/yuruna-squid-ca.crt"
        $caResp = Invoke-WebRequest -Uri $cacheCaUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($caResp.StatusCode -eq 200 -and $caResp.RawContentLength -gt 0) {
            $caBytes = if ($caResp.Content -is [byte[]]) { $caResp.Content } else { [System.Text.Encoding]::UTF8.GetBytes([string]$caResp.Content) }
            $CaCertBase64 = [Convert]::ToBase64String($caBytes)
            Write-Verbose "  Fetched caching-proxy CA from $cacheCaUrl ($($caBytes.Length) bytes) -- embedded in seed."
        }
    } catch {
        Write-Warning "  Could not fetch CA cert from caching-proxy : $($_.Exception.Message)"
        Write-Warning "  Guest will skip HTTPS caching (Acquire::https::Proxy); HTTP caching via :3128 unaffected."
    }
}

# --- See https://yuruna.link/network#defining-yuruna-retry-lib
# Bake yuruna-retry.sh + fetch-and-execute.sh into the seed as base64-encoded
# write_files entries. Eliminates the legacy network-dependent wget+wget
# bootstrap and ensures both files are on disk before any guest script runs.
$null = Build-CloudInitUserData `
    -BasePath    $BaseUserData `
    -OverlayPath $OverlayUserData `
    -RepoRoot    $RepoRoot `
    -OutputPath  "$SeedDir/user-data" `
    -Replacement @{
        HOSTNAME_PLACEHOLDER           = $VMName
        USERNAME_PLACEHOLDER           = $Username
        HASH_PLACEHOLDER               = $PasswordHash
        SSH_AUTHORIZED_KEY_PLACEHOLDER = $SshAuthorizedKey
        APT_PROXY_BLOCK_PLACEHOLDER    = $AptProxyBlock
        CACHING_PROXY_URL_PLACEHOLDER  = $CachingProxyUrl
        CA_CERT_BASE64_PLACEHOLDER     = $CaCertBase64
        YURUNA_HOST_IP_PLACEHOLDER     = $YurunaHostIp
        YURUNA_HOST_PORT_PLACEHOLDER   = $YurunaHostPort
    } -Confirm:$false

$MetaData = (Get-Content -Raw $MetaDataTemplate) `
    -replace 'HOSTNAME_PLACEHOLDER', $VMName
Set-Content -Path "$SeedDir/meta-data" -Value $MetaData -NoNewline

$SeedIso = Join-Path $vmDir "seed.iso"
Write-Verbose "Generating seed.iso with autoinstall configuration..."
CreateIso -SourceDir $SeedDir -OutputFile $SeedIso -VolumeId "cidata"

Write-Verbose "Creating new VM '$VMName' on switch '$switchName'..."
Hyper-V\New-VM -Name $VMName -Generation 2 -MemoryStartupBytes 16384MB -SwitchName $switchName -VHDPath $vhdxFile | Out-Null
Set-VM -Name $VMName -MemoryStartupBytes 16384MB -MemoryMinimumBytes 16384MB -MemoryMaximumBytes 16384MB -AutomaticCheckpointsEnabled $false | Out-Null
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off | Out-Null

# Prune stale per-VM ACEs accumulated on this SHARED base image before
# Hyper-V appends this VM's ACE on attach. Without it the file's DACL grows
# unbounded across runs (Hyper-V never revokes on Remove-VM) and eventually
# hits the ~64 KB ACL limit, failing the attach with 0x8007053C ("does not
# have permission to open attachment"). See docs/hyperv-iso-ace-bloat.md.
$prunedAce = Remove-OrphanedVMFileAccess -Path $baseImageFile
if ($prunedAce -gt 0) { Write-Verbose "Pruned $prunedAce stale per-VM ACE(s) from base image before attach." }
Add-VMDvdDrive -VMName $VMName -Path $baseImageFile | Out-Null
Add-VMDvdDrive -VMName $VMName -Path $SeedIso | Out-Null

# Boot order: DVD (Ubuntu ISO) first, then hard drive
$dvdDrive = Get-VMDvdDrive -VMName $VMName | Where-Object { $_.Path -eq $baseImageFile }
Set-VMFirmware -VMName $VMName -FirstBootDevice $dvdDrive

# --- VM core-count policy: see https://yuruna.link/definition#defining-the-vm-core-count-policy
$hostCores = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum
if ($hostCores -lt 4) {
    Write-Error "Host has $hostCores physical cores; Yuruna requires at least 4. See https://yuruna.link/definition#defining-the-vm-core-count-policy"
    exit 1
}
$vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))
Set-VMProcessor -VMName $VMName -Count $vmCores -ExposeVirtualizationExtensions $true | Out-Null

# WARNING: The test harness OCR is calibrated for 1920x1080.
# Changing this resolution may break automated screen-text detection
# in waitForText sequence steps.
Set-VMVideo -VMName $VMName -HorizontalResolution 1920 -VerticalResolution 1080 -ResolutionType Single

# === Cleanup temporary folders ===
Remove-Item -LiteralPath $SeedDir -Recurse -Force -ErrorAction SilentlyContinue

# === Guidance ===
Write-Verbose "VM '$VMName' created and configured."
Write-Verbose "Start the VM from Hyper-V Manager to begin Ubuntu Server installation."
Write-Verbose "Boot sequence:"
Write-Verbose "  1. Ubuntu Server autoinstalls via subiquity (~5-10 min)"
Write-Verbose "  2. First boot: text-mode login prompt."
Write-Verbose "Default credentials - username: $Username, password: <vault-managed> (must be changed on first login). Vault: test/status/extension/authentication/vault.yml"
Write-Verbose "After installation completes, remove the DVD drives:"
Write-Verbose "  Get-VMDvdDrive -VMName '$VMName' | Remove-VMDvdDrive"
