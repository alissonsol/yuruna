<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42ada8e8-3ff4-49bc-88b3-4e1d20a217de
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
    Provides the shared Ubuntu Server release builder workflow.
#>

param(
    [string]$VMName = "ubuntu-server01",
    [string]$CachingProxyServiceUrl,
    # OS user created by autoinstall and exercised by the test
    # sequences. Default 'yuuser26' chosen for greppability (vs the
    # cloud-image default 'ubuntu', which collides with anything Ubuntu)
    # and version-tagged so 24.04 and 26.04 guests don't collide in
    # shared logs.
    [string]$Username = 'yuuser26',
    # cloud-init local-hostname for the guest. Empty means "follow the VM
    # name", which keeps host-side lookups that assume hostname == VM name
    # working for every caller that does not ask for a specific hostname.
    [string]$Hostname = '',
    # Planner-cascaded VM memory (variables.memoryStartupBytes). Raw byte count
    # or a KB/MB/GB suffix (e.g. 34359738368, 32768MB, 32GB); converted to the
    # MB virt-install wants. Empty keeps the 8 GB default below.
    [string]$MemoryStartupBytes = '',
    # Planner-cascaded vCPU count (variables.cores). Overrules the default
    # calculation below. Empty keeps the default. Clamped to the host cores.
    [string]$Cores = '',
    [Parameter(Mandatory)][ValidateSet('24', '26')][string]$Release,
    [Parameter(Mandatory)][string]$GuestScriptRoot,
    [string]$EnvironmentErrorKey
)

Import-Module (Join-Path $GuestScriptRoot '../../../automation/Yuruna.Globalization.psm1') -DisableNameChecking

# --- REGION: Log level from environment
# See https://yuruna.link/42e220c4-0003
# Reuse the caller's log module; a forced reload discards its state.
$_logLevelMod = Join-Path $GuestScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (-not (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) -and (Test-Path $_logLevelMod)) {
    Import-Module $_logLevelMod -Global
}
if (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) { Use-LogLevelFromEnv }

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_8be0c49190d15cd0' -Arguments @{ vMName = "$VMName" })
    exit 1
}

if ($Hostname -and $Hostname -notmatch '^[a-zA-Z0-9.-]+$') {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_3127c22c5596f553' -Arguments @{ hostname = "$Hostname" })
    exit 1
}
$GuestHostname = if ($Hostname) { $Hostname } else { $VMName }

# --- REGION: Environment checks
if (-not $IsLinux) {
    Write-Error (Format-YurunaOperatorMessage -Key $EnvironmentErrorKey)
    exit 1
}

$ErrorActionPreference = 'Stop'
$ScriptDir = $GuestScriptRoot

# --- REGION: libvirt-qemu search ACL on $HOME
# See https://yuruna.link/42e220c4-0004
# Grant libvirt-qemu traverse-only access to the VM storage below this home directory.
if (Get-Command -Name 'setfacl' -ErrorAction SilentlyContinue) {
    & getent passwd libvirt-qemu *>$null
    if ($LASTEXITCODE -eq 0) {
        & setfacl -m 'u:libvirt-qemu:--x' $HOME 2>$null
    }
}

# --- REGION: Host architecture and mirror
$arch = (& uname -m).Trim()
switch ($arch) {
    'x86_64'  { $virtArch = 'x86_64';  $primaryUri = 'http://archive.ubuntu.com/ubuntu' }
    'aarch64' { $virtArch = 'aarch64'; $primaryUri = 'http://ports.ubuntu.com/ubuntu-ports' }
    default   { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_fdfd0961eabd7db1' -Arguments @{ arch = "$arch" }); exit 1 }
}

# --- REGION: Seek the base image
$downloadDir   = "$HOME/yuruna/image/ubuntu.env"
$baseImageName = "host.ubuntu.kvm.guest.ubuntu.server.$Release"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $GuestScriptRoot)) 'modules/Yuruna.Image.psm1') -Force
if (-not (Assert-YurunaBaseImage -BaseImageFile $baseImageFile -GuestFolder $GuestScriptRoot)) { exit 1 }

# --- REGION: Autoinstall password hash
# See https://yuruna.link/42e220c4-0004
# KVM retains its documented ad hoc environment override before using the vault.
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_356561278d80158b')
    exit 1
}
$Password = $env:YURUNA_GUEST_PASSWORD
if (-not $Password) {
    Import-Module (Join-Path $repoRoot 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
    $_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
    $Password = Get-LocalOsPassword -Username $Username
    if (-not $Password) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_a8c8c2c47e517a44' -Arguments @{ username = "$Username" }); exit 1 }
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_762658980a25b8fb' -Arguments @{ authActiveName = "$_authActiveName" })
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_c427eb2402415f42' -Arguments @{ authentication = "$(Resolve-ExtensionAreaDir -Area 'authentication')" })
} else {
    Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_ada79849fa8dc53a')
}
Import-Module (Join-Path $repoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
try {
    $PasswordHash = ConvertTo-Sha512CryptHash -Plaintext $Password
} catch {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_a22129b198b9c117' -Arguments @{ message = "$($_.Exception.Message)" })
    exit 1
}

# --- REGION: Base image provenance
# Emit the source URL from a healthy sidecar; warn when provenance is incomplete.
Import-Module (Join-Path $repoRoot 'test/modules/Test.Provenance.psm1') -Force
Write-BaseImageProvenance -BaseImagePath $baseImageFile

# --- REGION: Import host modules
Import-Module (Join-Path (Split-Path -Parent $ScriptDir) 'modules/Yuruna.Host.psm1') -Force -DisableNameChecking

# --- REGION: Remove existing VM
# See https://yuruna.link/42e220c4-0004
Import-Module (Join-Path $PSScriptRoot '../modules/Yuruna.Host.psm1') -DisableNameChecking -Verbose:$false
$virshUri = 'qemu:///system'
Remove-KvmDomainDefinition -VMName $VMName -Confirm:$false

# --- REGION: Create copies and files for VM
$vmDir   = Join-Path $HOME "yuruna/vms/$VMName"
$diskImg = Join-Path $vmDir "$VMName.qcow2"
$seedImg = Join-Path $vmDir 'seed.iso'
New-Item -ItemType Directory -Force -Path $vmDir | Out-Null

# --- REGION: Yuruna harness SSH key
# See https://yuruna.link/42e220c4-0004
# Use the shared harness key so test execution and failure diagnostics authenticate identically.
$TestSshModule = Join-Path $repoRoot 'test/modules/Test.Ssh.psm1'
Import-Module $TestSshModule -Force -DisableNameChecking
$sshPub = Get-YurunaSshPublicKey
if (-not $sshPub) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_6424990f88c7f7bc' -Arguments @{ testSshModule = "$TestSshModule" }); exit 1 }

# --- REGION: Build the autoinstall apt block
# See https://yuruna.link/429f3d06-000a
# Use the shared apt builder to keep mirror selection and retry budgets identical.
Import-Module (Join-Path $repoRoot 'automation/Yuruna.GuestSeed.psm1') -Force
$AptProxyBlock = New-AptProxyBlock -PrimaryUri $primaryUri -CachingProxyServiceUrl $CachingProxyServiceUrl

# --- REGION: Select the guest network
# Resolve the network and its reachable host address atomically so they cannot drift.
$guestBinding = Resolve-GuestHostBinding
$networkName  = $guestBinding.NetworkName

# --- REGION: Yuruna host coordinates
# See https://yuruna.link/42e220c4-0004
$hostIp = $guestBinding.HostIp
Import-Module (Join-Path $repoRoot 'test/modules/Test.Config.psm1') -Global -Force
$_statusSeed = Get-YurunaStatusServiceSeed -RepoRoot $repoRoot
$hostPort = $_statusSeed.Port

# --- REGION: Fetch caching-proxy-service CA cert (base64-embedded in seed)
# See https://yuruna.link/4220a755-0015
# An empty $CaCertBase64 is NOT a harmless no-op (curl rc=60 SSL-bump gate).
# Without the embedded CA, a guest using the SSL-bump proxy fails curl
# certificate verification (rc=60) before it can run its setup scripts.
$CaCertBase64 = ""
if ($CachingProxyServiceUrl) {
    Import-Module -Name (Join-Path $GuestScriptRoot '../../../test/modules/Test.CachingProxyService.psm1') -Force -DisableNameChecking
    $uri = [System.Uri]$CachingProxyServiceUrl
    $cacheHost = Format-IpUrlHost $uri.IdnHost
    $ca = Get-CachingProxyServiceCaCertBase64 -CacheCaUrl "http://$cacheHost/yuruna-squid-ca.crt" -CacheHost $uri.IdnHost
    $CaCertBase64 = $ca.CaCertBase64
    if ($ca.Exhausted) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_f2bb24df290cd0c1')
    }
}

# --- REGION: Render user-data / meta-data
# user-data AND meta-data are shared under host/vmconfig/ (the meta-data is
# byte-identical across the three host platforms; ubuntu.server.24 and .26
# share one file). Anchor contract: automation/Yuruna.CloudInitTemplate.psm1.
$metaDataTemplate = Join-Path $repoRoot 'host/vmconfig/ubuntu.server.meta-data'
$hostVmConfigDir  = Join-Path $repoRoot 'host/vmconfig'
$baseUserData     = Join-Path $hostVmConfigDir 'ubuntu.server.base.user-data'
$overlayUserData  = Join-Path $hostVmConfigDir 'ubuntu.server.kvm.overlay.yml'
foreach ($f in @($baseUserData, $overlayUserData, $metaDataTemplate)) {
    if (-not (Test-Path -LiteralPath $f)) {
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_9a1ef2a7551102d0' -Arguments @{ f = "$f" })
        exit 1
    }
}
Import-Module (Join-Path $repoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
# --- REGION: https://yuruna.link/4220a755-0003
# Embed the guest libraries as base64 write_files entries so bootstrap needs no download.
$userData = New-CloudInitUserData `
    -BasePath    $baseUserData `
    -OverlayPath $overlayUserData `
    -RepoRoot    $repoRoot `
    -Replacement @{
        HOSTNAME_PLACEHOLDER           = $GuestHostname
        USERNAME_PLACEHOLDER           = $Username
        SSH_AUTHORIZED_KEY_PLACEHOLDER = $sshPub
        HASH_PLACEHOLDER               = $PasswordHash
        APT_PROXY_BLOCK_PLACEHOLDER    = $AptProxyBlock
        CACHING_PROXY_URL_PLACEHOLDER  = ($CachingProxyServiceUrl ?? '')
        CA_CERT_BASE64_PLACEHOLDER     = $CaCertBase64
        YURUNA_STATUS_SERVICE_IP_PLACEHOLDER     = $hostIp
        YURUNA_STATUS_SERVICE_PORT_PLACEHOLDER   = $hostPort
    } -Confirm:$false
$metaData = (Get-Content -Raw -LiteralPath $metaDataTemplate).
    Replace('INSTANCE_ID_PLACEHOLDER', $VMName).Replace('HOSTNAME_PLACEHOLDER', $GuestHostname)

$seedDir = Join-Path $vmDir 'seed.src'
New-Item -ItemType Directory -Force -Path $seedDir | Out-Null
Set-Content -LiteralPath (Join-Path $seedDir 'user-data') -Value $userData -NoNewline
Set-Content -LiteralPath (Join-Path $seedDir 'meta-data') -Value $metaData -NoNewline
# --- REGION: https://yuruna.link/4220a755-000b
# The shared network-config pins DHCP identity during installation and after reboot.
Copy-Item -LiteralPath (Join-Path $hostVmConfigDir 'guest-dhcp.network-config') `
    -Destination (Join-Path $seedDir 'network-config') -Force

# --- REGION: Generate cloud-init seed ISO
# CIDATA volume label is what cloud-init's NoCloud datasource scans for.
& genisoimage -output $seedImg -volid cidata -joliet -rock `
    (Join-Path $seedDir 'user-data') (Join-Path $seedDir 'meta-data') `
    (Join-Path $seedDir 'network-config') 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_3d53fa1f73f89fed' -Arguments @{ lASTEXITCODE = "$LASTEXITCODE" })
    exit 1
}

# --- REGION: Create empty install target
# See https://yuruna.link/42e220c4-0004
# Delay destructive replacement until the seed preflight succeeds.
# Fresh 64 G qcow2; subiquity partitions and installs onto it.
if (Test-Path -LiteralPath $diskImg) { Remove-Item -Force -LiteralPath $diskImg }
& qemu-img create -f qcow2 $diskImg 64G | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_919e5b9a9a611298'); exit 1 }

# --- REGION: Create and configure the libvirt domain (virt-install)
# See https://yuruna.link/42d69dfa-0008
$osVariant = Resolve-KvmOsVariant -Candidates $(if ($Release -eq '26') { @('ubuntu26.04', 'ubuntu24.04', 'ubuntu22.04') } else { @('ubuntu24.04', 'ubuntu22.04') })

# --- REGION: https://yuruna.link/42fa6f45-0015
$hostCores = [int](& nproc --all)
if ($hostCores -lt 4) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_243943232cde57ac' -Arguments @{ hostCores = "$hostCores" })
    exit 1
}
# --- REGION: https://yuruna.link/42fa6f45-0015
# Reserve at least one host thread while applying the shared guest core policy.
$vmCores = [math]::Min($hostCores - 1, [math]::Max(2, [math]::Floor($hostCores / 2)))
# Cascaded variables.cores overrules the default; clamp to the host cores so an
# over-ask can't fail virt-install.
if ($Cores) {
    $coresInt = 0
    if (-not [int]::TryParse($Cores, [ref]$coresInt) -or $coresInt -lt 1) {
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_0e7d8993e0f54ff9' -Arguments @{ cores = "$Cores" })
        exit 1
    }
    if ($coresInt -gt $hostCores) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_8e635d5ac6761fab' -Arguments @{ coresInt = "$coresInt"; hostCores = "$hostCores" })
        $coresInt = $hostCores
    }
    $vmCores = $coresInt
}

# --- REGION: https://yuruna.link/42fa6f45-0016
# virt-install --memory is in MB, so convert from the canonical byte count.
try { $vmMemoryBytes = ConvertTo-MemoryStartupBytes $MemoryStartupBytes } catch { Write-Error $_.Exception.Message; exit 1 }
$vmMemoryMb = if ($vmMemoryBytes -gt 0) { [int]($vmMemoryBytes / 1MB) } else { 8192 }

# --- REGION: https://yuruna.link/4220a755-000a
# Keyed on the guest's durable identity, not on the name the VM carries now: a
# guest is built in a per-kind slot and renamed to its real name when its
# baseline is snapshotted, and an address that moved with that rename would
# re-DHCP a guest whose own state already records the one it was built on.
$YurunaGuestMac = Get-YurunaGuestMacAddress -VMName $GuestHostname
Write-Verbose "Deterministic guest MAC for '$GuestHostname': $YurunaGuestMac"

$installArgs = @(
    '--connect', $virshUri,
    '--name',    $VMName,
    '--memory',  "$vmMemoryMb",
    '--vcpus',   "$vmCores",
    '--cpu',     'host-passthrough',
    '--os-variant', $osVariant,
    '--disk',    "path=$diskImg,format=qcow2,bus=virtio",
    '--cdrom',   $baseImageFile,
    '--disk',    "path=$seedImg,device=cdrom,readonly=on",
    '--network', "network=$networkName,model=virtio,mac=$YurunaGuestMac",
    # Pinned rather than left to the default. virt-install adds this channel on
    # its own for this argument shape today, so the line changes nothing now --
    # but qemu-guest-agent in the seed is useless without it, and a future
    # default change would remove the host's only on-demand way to ask this
    # guest for its address, leaving discovery on a decaying ARP cache with no
    # sign of what broke.
    '--channel', 'unix,target_type=virtio,name=org.qemu.guest_agent.0',
    '--graphics','vnc,listen=127.0.0.1',
    # --- REGION: https://yuruna.link/42e220c4-0004
    # Pin virtio video on both Ubuntu releases to avoid installer framebuffer stalls.
    '--video',   'virtio'
)
switch ($virtArch) {
    'x86_64'  { $installArgs += @('--machine', 'q35',  '--boot', 'uefi') }
    'aarch64' { $installArgs += @('--machine', 'virt', '--boot', 'uefi') }
}

Write-Verbose "virt-install --print-xml=1 $($installArgs -join ' ')"
$installXml = (& virt-install @installArgs --print-xml=1 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_bba21c5cbbc83755' -Arguments @{ lASTEXITCODE = "$LASTEXITCODE"; installXml = "$installXml" })
    exit 1
}

# --- REGION: https://yuruna.link/42d69dfa-0003
# Force on_reboot=restart so subiquity's post-install reboot doesn't kill
# the domain. Sanity-check the substitution actually fired -- if a future
# virt-install version stops emitting the destroy literal we want a noisy
# failure here, not a silent regression that lands us back in the same
# `virsh screenshot failed` loop.
$patchedXml = $installXml -replace '<on_reboot>[^<]*</on_reboot>', '<on_reboot>restart</on_reboot>'
if ($patchedXml -eq $installXml -and $installXml -notmatch '<on_reboot>restart</on_reboot>') {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_7dcd4815768ac5a4')
    exit 1
}

# --- REGION: https://yuruna.link/42d69dfa-0004
$preBootSwap = $patchedXml
if ($patchedXml -match "<boot order='1'/>" -and $patchedXml -match "<boot order='2'/>") {
    $patchedXml = $patchedXml -replace "<boot order='1'/>", "<boot order='__YURUNA_BOOT_SWAP__'/>"
    $patchedXml = $patchedXml -replace "<boot order='2'/>", "<boot order='1'/>"
    $patchedXml = $patchedXml -replace "<boot order='__YURUNA_BOOT_SWAP__'/>", "<boot order='2'/>"
}
elseif ($patchedXml -match '<boot dev="cdrom"/>' -and $patchedXml -match '<boot dev="hd"/>') {
    $patchedXml = $patchedXml -replace '<boot dev="cdrom"/>(\s*)<boot dev="hd"/>', '<boot dev="hd"/>$1<boot dev="cdrom"/>'
}
if ($patchedXml -eq $preBootSwap) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_cdc9bbc4510f4f72' -Arguments @{ installXml = "$installXml" })
    exit 1
}

$xmlFile = New-TemporaryFile
try {
    Set-Content -LiteralPath $xmlFile.FullName -Value $patchedXml -NoNewline
    & virsh --connect $virshUri define $xmlFile.FullName
    if ($LASTEXITCODE -ne 0) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_a419339df771d79e' -Arguments @{ lASTEXITCODE = "$LASTEXITCODE" }); exit 1 }
    & virsh --connect $virshUri start $VMName
    if ($LASTEXITCODE -ne 0) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_1b83e0a223018f37' -Arguments @{ lASTEXITCODE = "$LASTEXITCODE" }); exit 1 }
} finally {
    Remove-Item -LiteralPath $xmlFile.FullName -Force -ErrorAction SilentlyContinue
}

# --- REGION: Clean up temporary files
# seed.src holds the rendered user-data with the autoinstall password hash
# and the harness SSH public key; the guest reads them from seed.iso, so the
# plaintext source directory has no reason to survive the run.
Remove-Item -LiteralPath $seedDir -Recurse -Force -ErrorAction SilentlyContinue

# --- REGION: Guidance
Write-Verbose "VM '$VMName' created. Subiquity will autoinstall (~5-10 min)."
Write-Verbose "Default credentials - username: $Username, password: <vault-managed> (must be changed on first login). Vault: test/status/extension/authentication/vault.yml (set YURUNA_GUEST_PASSWORD to bypass vault for ad-hoc dev runs)"
Write-Verbose "Console:  virt-viewer --connect $virshUri $VMName"
Write-Verbose "Get IP via 'virsh -c $virshUri domifaddr $VMName' once cloud-init finishes."
