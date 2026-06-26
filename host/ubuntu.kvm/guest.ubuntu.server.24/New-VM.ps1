<#PSScriptInfo
.VERSION 2026.06.26
.GUID 42a2b3c4-d5e6-4f78-9012-3a4b5c6d7e95
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
      2. Create a fresh empty 32 G qcow2 disk -- subiquity installs onto it.
      3. virt-install with two CDs (live-server ISO + cidata seed) plus
         the empty install-target qcow2; --noautoconsole because the
         harness's Restart-VMConsole launches virt-viewer separately
         (and detached, so the harness pipe still EOFs cleanly).

    The earlier KVM revision used the pre-baked Ubuntu cloud image (.img,
    qcow2-format) + NoCloud cloud-init seed. That boots in ~30s but
    DOES NOT show the "Continue with autoinstall?" prompt, does not run
    subiquity's late-commands, and lands at the login prompt without
    expiring the password -- making the GUI test sequence's first three
    steps non-comparable across hosts. The new flow is slower (~5-10 min
    install) but produces the same boot sequence and end state as
    macos.utm and hyper-v.
#>

param(
    [string]$VMName = "ubuntu-server01",
    [string]$CachingProxyUrl,
    # OS user created by autoinstall and exercised by the test
    # sequences. Default 'yuuser24' chosen for greppability (vs the
    # cloud-image default 'ubuntu', which collides with anything Ubuntu)
    # and version-tagged so 24.04 and 26.04 guests don't collide in
    # shared logs.
    [string]$Username = 'yuuser24'
)

if ($VMName -notmatch '^[a-zA-Z0-9._-]+$') {
    Write-Error "Invalid VMName '$VMName'. Only alphanumerics, dots, hyphens, underscores."
    exit 1
}
if (-not $IsLinux) {
    Write-Error "host/ubuntu.kvm/guest.ubuntu.server.24/New-VM.ps1 only runs on Linux."
    exit 1
}

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# -- libvirt-qemu search ACL on $HOME (self-heal) --------------------------
# Ubuntu 24.04 cloud images create /home/<user> at mode 0750, which blocks
# the libvirt-qemu user (uid 64055, gid kvm) that runs guest qemu processes
# from traversing $HOME to reach the qcow2 below it. virt-install then
# warns "You will need to grant the 'libvirt-qemu' user search permissions
# for ['/home/<user>']" and errors out with "Cannot access storage file ...
# Permission denied". A traverse-only POSIX ACL is the narrowest fix and
# does not change read/write/listing for any other user. Idempotent --
# safe to run every cycle.
if (Get-Command -Name 'setfacl' -ErrorAction SilentlyContinue) {
    & getent passwd libvirt-qemu *>$null
    if ($LASTEXITCODE -eq 0) {
        & setfacl -m 'u:libvirt-qemu:--x' $HOME 2>$null
    }
}

# -- Inputs ----------------------------------------------------------------
$arch = (& uname -m).Trim()
switch ($arch) {
    'x86_64'  { $virtArch = 'x86_64';  $primaryUri = 'http://archive.ubuntu.com/ubuntu' }
    'aarch64' { $virtArch = 'aarch64'; $primaryUri = 'http://ports.ubuntu.com/ubuntu-ports' }
    default   { Write-Error "Unsupported arch: $arch"; exit 1 }
}

$downloadDir   = "$HOME/yuruna/image/ubuntu.env"
$baseImageName = "host.ubuntu.kvm.guest.ubuntu.server.24"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"
# Auto-run Get-Image.ps1 once if the base image is missing; recheck and
# only error out when it's still missing afterward. Saves a round-trip
# when the operator forgot to run Get-Image and let New-VM run anyway.
if (-not (Test-Path -LiteralPath $baseImageFile)) {
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
    if (-not (Test-Path -LiteralPath $baseImageFile)) {
        Write-Error "Base image missing after auto Get-Image: $baseImageFile. Run Get-Image.ps1 manually."
        exit 1
    }
}

$vmDir   = Join-Path $HOME "yuruna/vms/$VMName"
$diskImg = Join-Path $vmDir "$VMName.qcow2"
$seedImg = Join-Path $vmDir 'seed.iso'
New-Item -ItemType Directory -Force -Path $vmDir | Out-Null

# -- SSH key (single harness key; matches macOS/Hyper-V variants) ---------
# The harness uses one ed25519 key pair at test/status/ssh/yuruna_ed25519,
# owned by Test.Ssh\Get-YurunaSshPublicKey. Test.Diagnostic's post-
# failure SSH path (Invoke-GuestSsh) authenticates with that SAME key,
# so the public bytes seeded into the guest's authorized_keys MUST be
# this key -- not an ad-hoc per-host pair. Prior versions of this
# script generated test/status/ssh/host.ubuntu.kvm and silently broke
# diagnostics (Permission denied (publickey,password)).
$repoRoot      = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
$TestSshModule = Join-Path $repoRoot 'test/modules/Test.Ssh.psm1'
Import-Module $TestSshModule -Force -DisableNameChecking
$sshPub = Get-YurunaSshPublicKey
if (-not $sshPub) { Write-Error "Get-YurunaSshPublicKey returned empty. Module path: $TestSshModule"; exit 1 }

# -- Password hash for cloud-init identity --------------------------------
# Resolve the autoinstall password from the per-cycle authentication
# vault (test/extension/authentication/default.psm1). Get-Password
# auto-generates and stores on first call; later calls within the same
# cycle return the rotated value committed by an earlier guest's
# Set-Password. Cycle-end cleanup wipes vault.yml on success.
# YURUNA_GUEST_PASSWORD env-var is honoured for ad-hoc dev-loop
# overrides (skips the vault -- nothing is committed back).
if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) {
    Write-Error "openssl is required for the autoinstall password hash. apt install openssl."
    exit 1
}
$plaintextPassword = $env:YURUNA_GUEST_PASSWORD
if (-not $plaintextPassword) {
    Import-Module (Join-Path $repoRoot 'test/modules/Test.Extension.psm1') -Global -Force -Verbose:$false
    $_authActiveName = @(Import-Extension -Area 'authentication' -RequireSingle)[0]
    $plaintextPassword = Get-LocalOsPassword -Username $Username
    if (-not $plaintextPassword) { Write-Error "Get-LocalOsPassword returned empty for '$Username'."; exit 1 }
    Write-Output "Password came from authentication mechanism: $_authActiveName"
    Write-Output "See configuration at: $(Resolve-ExtensionAreaDir -Area 'authentication')"
} else {
    Write-Output "Password came from environment variable: YURUNA_GUEST_PASSWORD"
}
Import-Module (Join-Path $repoRoot 'test/modules/Test.VMUtility.psm1') -Force -DisableNameChecking
try {
    $pwHash = ConvertTo-Sha512CryptHash -Plaintext $plaintextPassword
} catch {
    Write-Error "Password hashing failed: $($_.Exception.Message)"
    exit 1
}

# -- Yuruna host coordinates + guest network (topology-aware) -------------
# The guest must attach to the SAME libvirt network as the caching-proxy
# (Get-ExternalNetwork: bridged 'yuruna-external' when defined, else the
# NAT 'default') and reach the host status server at an address routable
# from that network. Resolve-GuestHostBinding returns the matched
# pair, so the cache's address (passed in via -CachingProxyUrl) and the
# baked host coordinates can't point at a network the guest can't route
# to: a guest on the NAT 'default' net cannot reach a bridged cache's LAN
# IP, which makes apt's in-target kernel fetch fail "Network is
# unreachable". Status server port is read from test.config.yml when
# available, otherwise defaults to 8080.
Import-Module (Join-Path (Split-Path -Parent $ScriptDir) 'modules/Yuruna.Host.psm1') -Force -DisableNameChecking
$guestBinding = Resolve-GuestHostBinding
$networkName  = $guestBinding.NetworkName
$hostIp       = $guestBinding.HostIp
$hostPort = '8080'
$cfg = Join-Path $repoRoot 'test/test.config.yml'
if (Test-Path -LiteralPath $cfg) {
    try {
        $j = Get-Content -Raw -LiteralPath $cfg | ConvertFrom-Yaml -Ordered
        if ($j.statusService.port) { $hostPort = "$($j.statusService.port)" }
    } catch { Write-Verbose "test.config.yml unparseable; using port $hostPort" }
}

# -- Build the autoinstall apt block --------------------------------------
# Always emit `geoip: false` + a pinned `primary:` mirror (deterministic
# election; `primary:` not `sources_list:`).
# --- See https://yuruna.link/vmconfig#apt-proxy-block
$AptProxyLine = if ($CachingProxyUrl) { "`n    proxy: $CachingProxyUrl" } else { "" }
$AptProxyBlock = @"
  apt:
    geoip: false
    primary:
      - arches: [default]
        uri: $primaryUri$($AptProxyLine)
    conf: |
      Acquire::Retries "5";
      Acquire::http::Timeout "120";
      Acquire::https::Timeout "120";
"@

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

# -- Render user-data / meta-data ------------------------------------------
# user-data AND meta-data are shared under host/vmconfig/ (the meta-data is
# byte-identical across the three host platforms; ubuntu.server.24 and .26
# share one file). Anchor contract: automation/Yuruna.CloudInitTemplate.psm1.
$metaDataTemplate = Join-Path $repoRoot 'host/vmconfig/ubuntu.server.meta-data'
$repoRoot         = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
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
# --- See https://yuruna.link/network#defining-yuruna-retry-lib
# Bake the guest-side lib scripts into the seed as base64-encoded write_files
# entries. Eliminates the legacy network-dependent wget+wget bootstrap and
# ensures the files are on disk before any guest script runs.
# Build-CloudInitUserData reads + base64-encodes the scripts under
# $repoRoot/automation/, populates their *_BASE64_PLACEHOLDER tokens, then
# renders the merged template with the per-cycle replacements below.
$userData = Build-CloudInitUserData `
    -BasePath    $baseUserData `
    -OverlayPath $overlayUserData `
    -RepoRoot    $repoRoot `
    -Replacement @{
        HOSTNAME_PLACEHOLDER           = $VMName
        USERNAME_PLACEHOLDER           = $Username
        SSH_AUTHORIZED_KEY_PLACEHOLDER = $sshPub
        HASH_PLACEHOLDER               = $pwHash
        APT_PROXY_BLOCK_PLACEHOLDER    = $AptProxyBlock
        CACHING_PROXY_URL_PLACEHOLDER  = ($CachingProxyUrl ?? '')
        CA_CERT_BASE64_PLACEHOLDER     = $CaCertBase64
        YURUNA_HOST_IP_PLACEHOLDER     = $hostIp
        YURUNA_HOST_PORT_PLACEHOLDER   = $hostPort
    } -Confirm:$false
$metaData = (Get-Content -Raw -LiteralPath $metaDataTemplate).
    Replace('HOSTNAME_PLACEHOLDER', $VMName)

$seedDir = Join-Path $vmDir 'seed.src'
New-Item -ItemType Directory -Force -Path $seedDir | Out-Null
Set-Content -LiteralPath (Join-Path $seedDir 'user-data') -Value $userData -NoNewline
Set-Content -LiteralPath (Join-Path $seedDir 'meta-data') -Value $metaData -NoNewline

# -- Build the seed ISO ----------------------------------------------------
# CIDATA volume label is what cloud-init's NoCloud datasource scans for.
& genisoimage -output $seedImg -volid cidata -joliet -rock `
    (Join-Path $seedDir 'user-data') (Join-Path $seedDir 'meta-data') 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "genisoimage failed (exit $LASTEXITCODE)"
    exit 1
}

# -- Create empty install target -------------------------------------------
# Fresh 64 G qcow2; subiquity will partition + install onto it. Paired with
# sizing-policy: all in host/vmconfig/ubuntu.server.base.user-data so the root LV consumes the
# whole PV instead of subiquity's default ~50% server heuristic that left
# kubelet's image filesystem at ~14 GiB and tripped ephemeral-storage
# eviction during the website test.
if (Test-Path -LiteralPath $diskImg) { Remove-Item -Force -LiteralPath $diskImg }
& qemu-img create -f qcow2 $diskImg 64G | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Error "qemu-img create failed"; exit 1 }

# -- Define + start the VM via virt-install ---------------------------------
$virshUri = 'qemu:///system'
# Capture stdout+stderr + exit code for each call so an operator
# running with -Verbose sees the per-call outcome. The post-condition
# below catches the actual failure mode; this just preserves forensics
# when something unusual surfaces between the two idempotent ops.
$destroyOut = & virsh --connect $virshUri destroy $VMName 2>&1
Write-Verbose "virsh destroy '$VMName' exit=$LASTEXITCODE output='$($destroyOut -join '; ')'"
$undefineOut = & virsh --connect $virshUri undefine --nvram $VMName 2>&1
Write-Verbose "virsh undefine '$VMName' exit=$LASTEXITCODE output='$($undefineOut -join '; ')'"
# Post-condition: virsh destroy/undefine on a non-existing domain is
# idempotent (returns non-zero, swallowed by `2>$null`). But if either
# op failed while the domain remains defined, the next virt-install
# fails with "domain already defined" and the outer loop has no signal
# to recover. Fail-loud now with dominfo so the operator can act.
$stillDefined = & virsh --connect $virshUri list --all --name 2>$null |
    Where-Object { $_.Trim() -eq $VMName }
if ($stillDefined) {
    $dominfo = (& virsh --connect $virshUri dominfo $VMName 2>&1 | Out-String).Trim()
    throw "virsh destroy + undefine left '$VMName' defined; aborting before re-creation.`ndominfo:`n$dominfo"
}

# --- See https://yuruna.link/memory#why-we-patch-virt-installs-phase-1-xml-on-kvm

# --- See https://yuruna.link/memory#why-osinfo-db-variant-detection-parses-canonical-token-first
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

# --- VM core-count policy: see https://yuruna.link/definition#defining-the-vm-core-count-policy
$hostCores = [int](& nproc --all)
if ($hostCores -lt 4) {
    Write-Error "Host has $hostCores cores; Yuruna requires at least 4. See https://yuruna.link/definition#defining-the-vm-core-count-policy"
    exit 1
}
$vmCores = [math]::Max(4, [math]::Floor($hostCores / 2))

$installArgs = @(
    '--connect', $virshUri,
    '--name',    $VMName,
    '--memory',  '4096',
    '--vcpus',   "$vmCores",
    '--cpu',     'host-passthrough',
    '--os-variant', $osVariant,
    '--disk',    "path=$diskImg,format=qcow2,bus=virtio",
    '--cdrom',   $baseImageFile,
    '--disk',    "path=$seedImg,device=cdrom,readonly=on",
    '--network', "network=$networkName,model=virtio",
    '--graphics','vnc,listen=127.0.0.1',
    # Force paravirtual virtio video instead of the q35+UEFI default
    # (bochs-display). The bochs DRM driver in the resolute live-server
    # kernel (7.0.0-15) thrashes drm_fb_helper_damage_work during the
    # subiquity install phase, correlating with an overlayfs oops that
    # stalls autoinstall before the post-install login prompt appears.
    # virtio-vga is paravirtual, has no DRM driver burn, and works
    # identically on noble, so we pin it for both 24 and 26.
    # See log/000088 on host.ubuntu.kvm for the failure that triggered this.
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

# --- See https://yuruna.link/memory#why-we-swap-boot-order-1-and-2-in-the-install-xml
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

Write-Verbose "VM '$VMName' created. Subiquity will autoinstall (~5-10 min)."
Write-Verbose "Default credentials - username: $Username, password: <vault-managed> (must be changed on first login). Vault: test/status/extension/authentication/vault.yml (set YURUNA_GUEST_PASSWORD to bypass vault for ad-hoc dev runs)"
Write-Verbose "Console:  virt-viewer --connect $virshUri $VMName"
Write-Verbose "Get IP via 'virsh -c $virshUri domifaddr $VMName' once cloud-init finishes."
