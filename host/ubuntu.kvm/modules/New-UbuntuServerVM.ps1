<#PSScriptInfo
.VERSION 2026.11.05
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
    # Versioned usernames keep release-specific guest logs distinguishable.
    [string]$Username = 'yuuser26',
    # An empty hostname follows the VM name for host-side lookup.
    [string]$Hostname = '',
    # Accept raw bytes or a KB/MB/GB suffix; an empty value keeps the host default.
    # See https://yuruna.link/42fa6f45-0016
    [string]$MemoryStartupBytes = '',
    # An empty core count keeps the host default; explicit values are clamped.
    # See https://yuruna.link/42fa6f45-0015
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

# --- REGION: https://yuruna.link/42e220c4-0004
# Stop on failed VM configuration; the child process exit is the caller's failure signal.
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
# See https://yuruna.link/42e220c4-0003
# Fetch missing media once; fail if manual-download requirements remain unmet.
$downloadDir   = "$HOME/yuruna/image/ubuntu.env"
$baseImageName = "host.ubuntu.kvm.guest.ubuntu.server.$Release"
$baseImageFile = Join-Path $downloadDir "$baseImageName.iso"
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $GuestScriptRoot)) 'modules/Yuruna.Image.psm1') -Force
if (-not (Assert-YurunaBaseImage -BaseImageFile $baseImageFile -GuestFolder $GuestScriptRoot)) { exit 1 }

# --- REGION: Vault user password
# See https://yuruna.link/42e220c4-0004
# KVM retains its documented ad hoc environment override before using the vault.
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $ScriptDir))
# The hash below needs openssl; check it before any credential is read.
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

# --- REGION: Autoinstall password hash
# See https://yuruna.link/429f3d06-0017
# Keep the shared hash helper: its -- separator protects leading-dash passwords.
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
# Runs AFTER the base image is confirmed so a failed image fetch never
# destroys a working VM.
$virshUri = 'qemu:///system'
Remove-KvmDomainDefinition -VMName $VMName -Confirm:$false

# --- REGION: Create copies and files for VM
$vmDir   = Join-Path $HOME "yuruna/vms/$VMName"
$diskImg = Join-Path $vmDir "$VMName.qcow2"
$seedImg = Join-Path $vmDir 'seed.iso'
New-Item -ItemType Directory -Force -Path $vmDir | Out-Null
# --- REGION: Stage the cloud-init seed directory
# The seed carries the autoinstall password hash and the harness key. It is
# staged in a private (0700) workspace beside the disk and published as an
# owner-only image, and the finally below removes the workspace on every exit,
# a failed build included.
Import-Module (Join-Path $repoRoot 'host/modules/Yuruna.SeedMedia.psm1') -Force
# A plaintext source an older builder left beside the disk goes first.
Remove-Item -LiteralPath (Join-Path $vmDir 'seed.src') -Recurse -Force -ErrorAction SilentlyContinue
$seedWorkspace = $null
try {
    $seedWorkspace = New-SeedMediaWorkspace -ParentPath $vmDir
    $seedDir = $seedWorkspace.Source

    # --- REGION: Yuruna harness SSH key
    # See https://yuruna.link/42e220c4-0004
    # Seed the shared harness key so guest provisioning and failure diagnostics agree.
    $TestSshModule = Join-Path $repoRoot 'test/modules/Test.Ssh.psm1'
    Import-Module $TestSshModule -Force -DisableNameChecking
    $sshPub = Get-YurunaSshPublicKey
    if (-not $sshPub) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_6424990f88c7f7bc' -Arguments @{ testSshModule = "$TestSshModule" }); exit 1 }

    # --- REGION: Detect the caching-proxy service
    # See https://yuruna.link/42e220c4-0004
    # A bound URL, including empty for direct fetching, overrides discovery. A missing
    # or stopped cache permits direct fetching; a running but unresponsive cache fails.
    if (-not $PSBoundParameters.ContainsKey('CachingProxyServiceUrl')) {
        $CachingProxyServiceUrl = Test-CachingProxyServiceAvailable
        if (-not $CachingProxyServiceUrl -and
            (Get-VMState -VMName 'yuruna-caching-proxy-service') -eq 'running') {
            Write-Error (Format-YurunaOperatorMessage -Key 'host.kvm_running_cache_unreachable')
            exit 1
        }
    }

    # --- REGION: Build the autoinstall apt block
    # See https://yuruna.link/429f3d06-000a
    # Use the shared apt builder to keep mirror selection and retry budgets identical.
    Import-Module (Join-Path $repoRoot 'automation/Yuruna.GuestSeed.psm1') -Force
    $AptProxyBlock = New-AptProxyBlock -PrimaryUri $primaryUri -CachingProxyServiceUrl $CachingProxyServiceUrl

    # --- REGION: Select the guest network
    # See https://yuruna.link/42e220c4-0004
    # Resolve the network and reachable host address together before rendering the seed.
    $guestBinding = Resolve-GuestHostBinding
    $networkName  = $guestBinding.NetworkName

    # --- REGION: Yuruna host coordinates
    # See https://yuruna.link/4220a755-001b
    # Bake the status-service address reachable through the selected guest network.
    $hostIp = $guestBinding.HostIp
    Import-Module (Join-Path $repoRoot 'test/modules/Test.Config.psm1') -Global -Force
    $_statusSeed = Get-YurunaStatusServiceSeed -RepoRoot $repoRoot
    $hostPort = $_statusSeed.Port

    # --- REGION: Fetch caching-proxy-service CA cert
    # Embedded in the seed as base64.
    # See https://yuruna.link/4220a755-0015
    # An empty $CaCertBase64 is NOT a harmless no-op (curl rc=60 SSL-bump gate).
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
        if ($ca.Refused) {
            # A guest seeded with another root would meet a proxy that bumps with
            # this one; the refusal is reported as source_integrity, not built around.
            Write-Error (Format-YurunaOperatorMessage -Key 'host.proxy_ca_refused_build' -Arguments @{ vMName = "$VMName"; cacheHost = "$($uri.IdnHost)"; reason = "$($ca.Reason)" }) -ErrorAction Continue
            exit (Get-YurunaSourceIntegrityExitCode)
        }
    }

    # --- REGION: Render user-data / meta-data
    # See https://yuruna.link/4220a755-0003
    # Embed the guest libraries as base64 write_files entries so bootstrap needs no download.
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

    Set-Content -LiteralPath (Join-Path $seedDir 'user-data') -Value $userData -NoNewline
    Set-Content -LiteralPath (Join-Path $seedDir 'meta-data') -Value $metaData -NoNewline
    # --- REGION: https://yuruna.link/4220a755-000b
    # The shared network-config pins DHCP identity during installation and after reboot.
    Copy-Item -LiteralPath (Join-Path $hostVmConfigDir 'guest-dhcp.network-config') `
        -Destination (Join-Path $seedDir 'network-config') -Force

    # --- REGION: Generate cloud-init seed ISO
    # CIDATA volume label is what cloud-init's NoCloud datasource scans for.
    & genisoimage -output $seedWorkspace.Image -volid cidata -joliet -rock `
        (Join-Path $seedDir 'user-data') (Join-Path $seedDir 'meta-data') `
        (Join-Path $seedDir 'network-config') 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_3d53fa1f73f89fed' -Arguments @{ lASTEXITCODE = "$LASTEXITCODE" })
        exit 1
    }
    Publish-SeedMediaImage -Workspace $seedWorkspace -Path $seedImg -Confirm:$false

    # --- REGION: Create empty install target
    # See https://yuruna.link/42e220c4-0004
    # Delay destructive replacement until the seed preflight succeeds.
    # The 64 GB sparse disk fits the k8s and .NET build workloads and is the uniform
    # cap across hosts; sizing-policy: all in host/vmconfig/ubuntu.server.base.user-data
    # lets the root LV consume the whole PV.
    if (Test-Path -LiteralPath $diskImg) { Remove-Item -Force -LiteralPath $diskImg }
    & qemu-img create -f qcow2 $diskImg 64G | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_919e5b9a9a611298'); exit 1 }

    # --- REGION: Create and configure the libvirt domain
    # See https://yuruna.link/42d69dfa-0008
    $osVariant = Resolve-KvmOsVariant -Candidates $(if ($Release -eq '26') { @('ubuntu26.04', 'ubuntu24.04', 'ubuntu22.04') } else { @('ubuntu24.04', 'ubuntu22.04') })

    # --- REGION: https://yuruna.link/42fa6f45-0015
    $hostCores = [int](& nproc --all)
    if ($hostCores -lt 4) {
        Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_243943232cde57ac' -Arguments @{ hostCores = "$hostCores" })
        exit 1
    }
    # See https://yuruna.link/42fa6f45-0015
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
    # Key the MAC by durable guest identity so rebuilds and VM renames keep the DHCP lease.
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
        # See https://yuruna.link/42e220c4-0004
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
    # virt-install reads the host's capabilities from libvirt even to print.
    $printed = Invoke-BoundedNativeCommand -FilePath 'virt-install' -ArgumentList (@($installArgs) + '--print-xml=1') -TimeoutSeconds 120
    # The definition is stdout alone; a warning on stderr is not XML.
    $installXml = @(Get-BoundedNativeOutputLine -Result $printed) -join "`n"
    $printExit = if (Test-BoundedNativeResultComplete -Result $printed) { $printed.ExitCode } else { -1 }
    if ($printExit -ne 0) {
        $printedText = @(Get-BoundedNativeOutputLine -Result $printed -IncludeError) -join "`n"
        $message = Format-YurunaOperatorMessage -Key 'host.operator_bba21c5cbbc83755' -Arguments @{ lASTEXITCODE = "$printExit"; installXml = "$printedText" }
        Write-YurunaProvisionResult -Kind $(if ($printed.Started -and $printExit -eq -1) { 'unresponsive' } else { 'tool' }) -Message $message
        Write-Error $message
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
        # Bounded like every other virsh call: a daemon that stops answering is
        # recorded as such for the runner instead of holding the build. Each
        # failure key is passed by name so the catalog source map can trace it
        # to the formatter.
        function Invoke-BuildVirshStep {
            param([string[]]$Arguments, [string]$FailureKey)
            $virsh = Invoke-BoundedNativeCommand -FilePath 'virsh' -ArgumentList (@('--connect', $virshUri) + $Arguments) `
                -Environment @{ LC_MESSAGES = 'C'; LC_ALL = '' } -TimeoutSeconds 120
            Get-BoundedNativeOutputLine -Result $virsh -IncludeError | ForEach-Object { Write-Information $_ -InformationAction Continue }
            $complete = Test-BoundedNativeResultComplete -Result $virsh
            if ($complete -and $virsh.ExitCode -eq 0) { return }
            $exitText = if ($complete) { "$($virsh.ExitCode)" } else { 'no answer' }
            $message = Format-YurunaOperatorMessage -Key $FailureKey -Arguments @{ lASTEXITCODE = $exitText }
            Write-YurunaProvisionResult -Kind $(if ($virsh.Started -and -not $complete) { 'unresponsive' } else { 'tool' }) -Message $message
            Write-Error $message
            exit 1
        }
        Invoke-BuildVirshStep -Arguments @('define', $xmlFile.FullName) -FailureKey 'host.operator_a419339df771d79e'
        Invoke-BuildVirshStep -Arguments @('start', $VMName) -FailureKey 'host.operator_1b83e0a223018f37'
    } finally {
        Remove-Item -LiteralPath $xmlFile.FullName -Force -ErrorAction SilentlyContinue
    }
} finally {
    # --- REGION: Clean up temporary files
    Remove-SeedMediaWorkspace -Workspace $seedWorkspace -Confirm:$false
}

# --- REGION: Guidance
Write-Verbose "VM '$VMName' created. Subiquity will autoinstall (~5-10 min)."
Write-Verbose "Default credentials - username: $Username, password: <vault-managed> (must be changed on first login). Vault: test/status/extension/authentication/vault.yml (set YURUNA_GUEST_PASSWORD to bypass vault for ad-hoc dev runs)"
Write-Verbose "Console:  virt-viewer --connect $virshUri $VMName"
Write-Verbose "Get IP via 'virsh -c $virshUri domifaddr $VMName' once cloud-init finishes."

# --- REGION: Completion
# Clear a successful native probe's stale exit code before returning to the wrapper.
exit 0
