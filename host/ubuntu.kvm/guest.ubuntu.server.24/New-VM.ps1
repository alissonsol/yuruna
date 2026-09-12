<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42f12da2-1112-4de8-b565-c97a7434c2c2
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
    Creates a libvirt VM that installs Ubuntu Server 24.04 via the
    live-server ISO + subiquity autoinstall.

.DESCRIPTION
    Mirrors host/macos.utm/guest.ubuntu.server.24/New-VM.ps1 and
    host/windows.hyper-v/guest.ubuntu.server.24/New-VM.ps1 so all three
    hosts run the same boot sequence: GRUB -> "Continue with autoinstall?"
    confirmation -> subiquity unattended install -> reboot -> text-mode
    login prompt with an EXPIRED `password` so the harness's first login
    triggers the current/new/retype dialog.

    Workflow:
      1. Build seed.iso from host/vmconfig/ubuntu.server.base.user-data + meta-data (CIDATA volume).
         Subiquity scans CD/DVD drives for cidata at boot and consumes the
         autoinstall config from there.
      2. Create a fresh empty 64 G qcow2 disk -- subiquity installs onto it.
      3. virt-install with two CDs (live-server ISO + cidata seed) plus
         the empty install-target qcow2; --noautoconsole because the
         harness's Restart-VMConsole launches virt-viewer separately
         (and detached, so the harness pipe still EOFs cleanly).

    The pre-baked Ubuntu cloud image (.img, qcow2-format) + NoCloud
    cloud-init seed is deliberately NOT used: it boots in ~30s but
    DOES NOT show the "Continue with autoinstall?" prompt, does not run
    subiquity's late-commands, and lands at the login prompt without
    expiring the password -- making the GUI test sequence's first three
    steps non-comparable across hosts. The live-server flow is slower
    (~5-10 min install) but produces the same boot sequence and end
    state as macos.utm and hyper-v.
#>

param(
    [string]$VMName = "ubuntu-server01",
    [string]$CachingProxyServiceUrl,
    # OS user created by autoinstall and exercised by the test
    # sequences. Default 'yuuser24' chosen for greppability (vs the
    # cloud-image default 'ubuntu', which collides with anything Ubuntu)
    # and version-tagged so 24.04 and 26.04 guests don't collide in
    # shared logs.
    [string]$Username = 'yuuser24',
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
    [string]$Cores = ''
)

# --- REGION: Log level from environment
# See https://yuruna.link/42e220c4-0003
# Reuse the caller's log module; a forced reload discards its state.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (-not (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) -and (Test-Path $_logLevelMod)) {
    Import-Module $_logLevelMod -Global
}
if (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) { Use-LogLevelFromEnv }

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'. Only alphanumerics, dots, hyphens, underscores."
    exit 1
}

if ($Hostname -and $Hostname -notmatch '^[a-zA-Z0-9.-]+$') {
    Write-Error "Invalid Hostname '$Hostname'. Only alphanumeric characters, dots, and hyphens are allowed."
    exit 1
}
$GuestHostname = if ($Hostname) { $Hostname } else { $VMName }

# --- REGION: Environment checks
if (-not $IsLinux) {
    Write-Error "host/ubuntu.kvm/guest.ubuntu.server.24/New-VM.ps1 only runs on Linux."
    exit 1
}

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

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
    default   { Write-Error "Unsupported arch: $arch"; exit 1 }
}

# --- REGION: Seek the base image
$downloadDir   = "$HOME/yuruna/image/ubuntu.env"
$baseImageName = "host.ubuntu.kvm.guest.ubuntu.server.24"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.Image.psm1') -Force
if (-not (Assert-YurunaBaseImage -BaseImageFile $baseImageFile -GuestFolder $PSScriptRoot)) { exit 1 }

# --- REGION: Autoinstall password hash
# See https://yuruna.link/42e220c4-0004
# KVM retains its documented ad hoc environment override before using the vault.
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
    Write-Error "openssl is required for the autoinstall password hash. apt install openssl."
    exit 1
}
$Password = $env:YURUNA_GUEST_PASSWORD
if (-not $Password) {
    Import-Module (Join-Path $repoRoot 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
    $_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
    $Password = Get-LocalOsPassword -Username $Username
    if (-not $Password) { Write-Error "Get-LocalOsPassword returned empty for '$Username'."; exit 1 }
    Write-Output "Password came from authentication mechanism: $_authActiveName"
    Write-Output "See configuration at: $(Resolve-ExtensionAreaDir -Area 'authentication')"
} else {
    Write-Output "Password came from environment variable: YURUNA_GUEST_PASSWORD"
}
Import-Module (Join-Path $repoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
try {
    $PasswordHash = ConvertTo-Sha512CryptHash -Plaintext $Password
} catch {
    Write-Error "Password hashing failed: $($_.Exception.Message)"
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
$virshUri = 'qemu:///system'
$destroyOut = & virsh --connect $virshUri destroy $VMName 2>&1
Write-Verbose "virsh destroy '$VMName' exit=$LASTEXITCODE output='$($destroyOut -join '; ')'"
# --- REGION: https://yuruna.link/42d69dfa-001e
$undefineOut = & virsh --connect $virshUri undefine --nvram --managed-save `
    --snapshots-metadata --checkpoints-metadata $VMName 2>&1
Write-Verbose "virsh undefine '$VMName' exit=$LASTEXITCODE output='$($undefineOut -join '; ')'"
$domainNames = @(& virsh --connect $virshUri list --all --name 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Cannot verify removal of '$VMName': virsh list failed: $($domainNames -join '; ')"
}
if ($domainNames | Where-Object { $_.ToString().Trim() -eq $VMName }) {
    $dominfo = (& virsh --connect $virshUri dominfo $VMName 2>&1 | Out-String).Trim()
    throw "virsh destroy + undefine left '$VMName' defined; aborting before re-creation.`ndominfo:`n$dominfo"
}

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
if (-not $sshPub) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

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
# See feedback_sslbump_rc60_untrusted_chain_and_ca_gate_trap and
# project_sslbump_ca_gating_durable_fix.
$CaCertBase64 = ""
if ($CachingProxyServiceUrl) {
    Import-Module -Name (Join-Path $PSScriptRoot '../../../test/modules/Test.CachingProxyService.psm1') -Force -DisableNameChecking
    $uri = [System.Uri]$CachingProxyServiceUrl
    $cacheHost = if ($uri.Host -match ':') { "[$($uri.Host)]" } else { $uri.Host }
    $ca = Get-CachingProxyServiceCaCertBase64 -CacheCaUrl "http://$cacheHost/yuruna-squid-ca.crt" -CacheHost $uri.Host
    $CaCertBase64 = $ca.CaCertBase64
    if ($ca.Exhausted) {
        Write-Warning "  Guest boots CA-less; it will self-heal the CA from the host status service at update time. HTTP caching via :3128 unaffected."
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
        Write-Error "Template missing: $f"
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
    Write-Error "genisoimage failed (exit $LASTEXITCODE)"
    exit 1
}

# --- REGION: Create empty install target
# See https://yuruna.link/42e220c4-0004
# Delay destructive replacement until the seed preflight succeeds.
# Fresh 64 G qcow2; subiquity partitions and installs onto it.
if (Test-Path -LiteralPath $diskImg) { Remove-Item -Force -LiteralPath $diskImg }
& qemu-img create -f qcow2 $diskImg 64G | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "qemu-img create failed"; exit 1 }

# --- REGION: Create and configure the libvirt domain (virt-install)
# See https://yuruna.link/42d69dfa-0008
$osVariant = 'linux2022'
$osList = & virt-install --osinfo list 2>$null
if ($LASTEXITCODE -eq 0) {
    $canonicalIds = @($osList | ForEach-Object {
        $first = ("$_".Trim() -split '[\s,]', 2)[0]
        ($first -replace ',$', '').Trim()
    } | Where-Object { $_ })
    foreach ($candidate in @('ubuntu24.04', 'ubuntu22.04')) {
        if ($canonicalIds -contains $candidate) { $osVariant = $candidate; break }
    }
    if ($osVariant -eq 'linux2022') {
        # Verbose, not Warning: the fallback variant works fine on every
        # host we've seen the message on, so it's noise at Info level.
        Write-Verbose "osinfo-db has no 'ubuntu24.04' or 'ubuntu22.04' entry; using 'linux2022' generic variant."
    }
}

# --- REGION: https://yuruna.link/42fa6f45-0015
$hostCores = [int](& nproc --all)
if ($hostCores -lt 4) {
    Write-Error "Host has $hostCores cores; Yuruna requires at least 4. See https://yuruna.link/42fa6f45-0015"
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
        Write-Error "Invalid -Cores '$Cores': expected a positive integer."
        exit 1
    }
    if ($coresInt -gt $hostCores) {
        Write-Warning "Requested -Cores $coresInt exceeds host cores ($hostCores); clamping to $hostCores."
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
    Write-Error "virt-install --print-xml failed (exit $LASTEXITCODE):`n$installXml"
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
    Write-Error "Failed to locate <on_reboot> element in virt-install --print-xml output. Refusing to define a domain that would kill itself on first reboot."
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
    Write-Error "Failed to locate <boot order='1'/>+<boot order='2'/> OR <boot dev=`"cdrom`"/>+<boot dev=`"hd`"/> pair in virt-install --print-xml output. Refusing to define a domain whose post-install reboot would loop back to the install CDROM. XML follows:`n$installXml"
    exit 1
}

$xmlFile = New-TemporaryFile
try {
    Set-Content -LiteralPath $xmlFile.FullName -Value $patchedXml -NoNewline
    & virsh --connect $virshUri define $xmlFile.FullName
    if ($LASTEXITCODE -ne 0) { Write-Error "virsh define failed (exit $LASTEXITCODE)"; exit 1 }
    & virsh --connect $virshUri start $VMName
    if ($LASTEXITCODE -ne 0) { Write-Error "virsh start failed (exit $LASTEXITCODE)"; exit 1 }
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
