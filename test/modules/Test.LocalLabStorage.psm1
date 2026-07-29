<#PSScriptInfo
.VERSION 2026.07.29
.GUID 42b7d3e6-5c81-4a92-b0f4-6d5e8c1a7b23
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna lab storage smb share loopback local
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

# Local lab storage: turn ONE machine into its own pool/stash SMB server and
# then consume those shares over the network stack, exactly as it would consume
# a NAS. The point of the loopback is uniformity -- the runner, the config gate,
# the drain, and the guest seeds all take the SMB path, so a single-machine lab
# exercises the same code as a lab with a real NAS and can later be pointed at
# one by changing only the host alias.
#
# This module owns the per-OS half of that (accounts, the SMB server, the
# shares, the loopback exemptions); the mount itself is Test.PoolStorage's
# Connect-YurunaPoolStorage, unchanged, so there is exactly one mount
# implementation in the tree.
#
# The pure helpers (path composition, drive selection, smb.conf text, registry
# merge) are separated from the OS calls so they are unit-testable on any
# platform -- the OS calls are integration-verified, since they mutate the host.

# Server aliases the two tiers are reached under. They resolve to the loopback
# address here, but the NAME is what test.config.yml and the guest seeds carry,
# so repointing this lab at a real NAS later is a hosts-file edit and nothing
# else.
$script:LoopbackAddress = '127.0.0.1'

<#
.SYNOPSIS
Returns 'windows', 'macos', or 'linux' for the running host, as the token the pure helpers in this module take. Throws on anything else, since there is no fourth SMB-server implementation here.
#>
function Get-LocalLabStoragePlatform {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($IsWindows) { return 'windows' }
    if ($IsMacOS)   { return 'macos' }
    if ($IsLinux)   { return 'linux' }
    throw "Unsupported operating system. New-LocalLabStorage supports Windows, macOS, and Ubuntu."
}

<#
.SYNOPSIS
Picks the drive lab storage should live on: the first fixed drive that is NOT the system drive, falling back to the system drive when the machine has only one. Pure -- the caller supplies the drive list -- so the selection rule is testable without a second physical disk.
.DESCRIPTION
Keeping cycle archives off the system drive is the reason to prefer another one: a pool share fills up over time (archives accrete, and pruning retired hosts is manual), and a full system drive takes the whole machine down with it, not just the lab. A single-drive machine still works -- the fallback is deliberate, not an error -- it just has no separation.

Comparison is on the normalized 'X:' form so a system drive reported as 'C:\' and a volume reported as 'C:' are recognized as the same drive.
#>
function Select-LocalLabStorageDataDrive {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][string[]]$Drive,
        [Parameter(Mandatory)][string]$SystemDrive
    )
    $normalize = { param($d) "$d".Trim().TrimEnd('\', '/').ToUpperInvariant() }
    $sys = & $normalize $SystemDrive
    $candidates = @()
    foreach ($d in @($Drive)) {
        $n = & $normalize $d
        if ($n) { $candidates += $n }
    }
    foreach ($c in $candidates) {
        if ($c -ne $sys) { return $c }
    }
    return $sys
}

<#
.SYNOPSIS
Enumerates this Windows host's fixed drives and returns the one lab storage should use (see Select-LocalLabStorageDataDrive). Returns the system drive when the enumeration fails, so a CIM hiccup degrades to a usable answer instead of an exception.
#>
function Get-LocalLabStorageWindowsDataDrive {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $systemDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
    $drives = @()
    try {
        # DriveType 3 == local fixed disk: excludes removable media, optical, and
        # already-mapped network drives, none of which may host a share.
        $drives = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType = 3' -ErrorAction Stop |
            Sort-Object -Property DeviceID |
            Select-Object -ExpandProperty DeviceID)
    } catch {
        Write-Verbose "Get-LocalLabStorageWindowsDataDrive: drive enumeration failed ($($_.Exception.Message)); using the system drive."
        return $systemDrive.TrimEnd('\', '/').ToUpperInvariant()
    }
    return (Select-LocalLabStorageDataDrive -Drive $drives -SystemDrive $systemDrive)
}

<#
.SYNOPSIS
Returns the suggested storage root for a platform -- /srv/yuruna (Ubuntu), /Users/Shared/yuruna (macOS), <DataDrive>\Shares\yuruna (Windows). Pure; the operator is always offered this as a default they can override.
.DESCRIPTION
Each location is the platform's conventional home for machine-wide, non-user data: /srv is FHS's "data served by this system", /Users/Shared is the macOS all-users folder that survives account changes, and a Windows data drive keeps growing archives off the system volume.
#>
function Get-LocalLabStorageDefaultRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('windows', 'macos', 'linux')][string]$Platform,
        [Parameter()][AllowEmptyString()][string]$DataDrive = ''
    )
    switch ($Platform) {
        'linux' { return '/srv/yuruna' }
        'macos' { return '/Users/Shared/yuruna' }
        default {
            $d = if ([string]::IsNullOrWhiteSpace($DataDrive)) { 'C:' } else { $DataDrive.Trim().TrimEnd('\', '/') }
            return "$d\Shares\yuruna"
        }
    }
}

<#
.SYNOPSIS
Builds the complete descriptor for one storage tier (pool or stash): on-disk folder, share name, SMB path, local mount point, account, and vault key. Pure and platform-parameterized, so the Windows shape can be verified from a macOS test run.
.DESCRIPTION
Every later step reads its inputs from this one object, so the folder that is shared, the path written into test.config.yml, and the path that is mounted cannot drift apart.

Paths are composed from the $Platform token rather than Join-Path: Join-Path uses the RUNNING host's separator, which would silently produce '/'-separated Windows paths whenever this is evaluated for a platform other than the current one (tests, and the operator preview).
#>
function New-LocalLabStorageTier {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure value constructor; creates an in-memory descriptor and touches nothing.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateSet('pool', 'stash')][string]$Kind,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Account,
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$FolderName,
        [Parameter(Mandatory)][string]$ShareName,
        [Parameter(Mandatory)][ValidateSet('windows', 'macos', 'linux')][string]$Platform,
        [Parameter()][AllowEmptyString()][string]$DriveLetter = ''
    )
    $sep  = if ($Platform -eq 'windows') { '\' } else { '/' }
    $base = $Root.Trim().TrimEnd('\', '/')
    $folderPath = "$base$sep$FolderName"

    $networkPath = if ($Platform -eq 'windows') { "\\$Server\$ShareName" } else { "//$Server/$ShareName" }

    $localPath = switch ($Platform) {
        'windows' { $DriveLetter.Trim().TrimEnd('\', '/') }
        'macos'   { "~/Shares/$Server" }
        default   { "/mnt/$Server" }
    }

    return [pscustomobject]@{
        Kind         = $Kind
        Account      = $Account
        # The vault key is namespaced rather than being the bare account name:
        # a non-empty vaultKey is what takes Get-Password off the auto-generate
        # path, where a random password the SMB server never heard of would be
        # minted and every mount would fail with a credential error.
        VaultKey     = "smb.$Account"
        Server       = $Server
        ShareName    = $ShareName
        FolderName   = $FolderName
        FolderPath   = $folderPath
        NetworkPath  = $networkPath
        LocalPath    = $localPath
        ConfigPrefix = if ($Kind -eq 'pool') { 'poolStorage' } else { 'stashStorage' }
    }
}

<#
.SYNOPSIS
Renders the Samba share definitions for the supplied tiers as the text of a standalone conf file. Pure.
.DESCRIPTION
Written as its own file pulled in by an `include` rather than appended into smb.conf, so re-running edits one small generated file and never rewrites the distribution's config. `valid users` scopes each share to its own account, which is what keeps a leaked pool credential away from the stash share.
#>
function Get-LocalLabStorageSambaConfig {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object[]]$Tier)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# Generated by test/New-LocalLabStorage.ps1 -- edits are overwritten on re-run.')
    $lines.Add('# Shares the local yuruna storage folders so this machine can mount them')
    $lines.Add('# over SMB the same way it would mount a NAS.')
    foreach ($t in $Tier) {
        $lines.Add('')
        $lines.Add("[$($t.ShareName)]")
        $lines.Add("   comment = Yuruna $($t.Kind) storage")
        $lines.Add("   path = $($t.FolderPath)")
        $lines.Add("   valid users = $($t.Account)")
        $lines.Add("   force group = $($t.Account)")
        $lines.Add('   read only = no')
        $lines.Add('   guest ok = no')
        $lines.Add('   browseable = yes')
        $lines.Add('   create mask = 0660')
        $lines.Add('   directory mask = 0770')
    }
    return (($lines -join "`n") + "`n")
}

<#
.SYNOPSIS
Returns smb.conf content with the yuruna include line appended, or $null when the line is already present so the caller writes nothing. Pure + idempotent.
#>
function Add-LocalLabStorageSambaInclude {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure string transform; returns the new content for the caller to write.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$IncludePath
    )
    $body = "$Content"
    $wanted = "include = $IncludePath"
    foreach ($line in ($body -split '\r?\n')) {
        # An `include` whose target matches is enough; the surrounding comment is
        # cosmetic and its absence must not cause a duplicate include.
        if (($line -replace '\s+', ' ').Trim() -ieq $wanted) { return $null }
    }
    $suffix = if ($body.Length -gt 0 -and -not $body.EndsWith("`n")) { "`n" } else { '' }
    return $body + $suffix + "`n# Yuruna local lab storage shares.`n$wanted`n"
}

<#
.SYNOPSIS
Merges the wanted names into an existing BackConnectionHostNames list, or returns $null when every name is already present. Pure, case-insensitive, order-preserving.
.DESCRIPTION
Windows refuses NTLM authentication to itself under any name other than the machine's own -- the loopback check -- so a mount of \\ypool-nas\... on the machine that also serves it fails with access denied even when the credential is correct. BackConnectionHostNames is the targeted exemption (DisableLoopbackCheck disables the protection wholesale, which this never does).

Existing entries are preserved: the value is shared with any other software on the host that registered its own alias, and dropping those would break it.
#>
function Merge-LocalLabStorageBackConnectionName {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()][AllowNull()][string[]]$Existing,
        [Parameter(Mandatory)][string[]]$Wanted
    )
    $merged = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in @($Existing)) {
        $v = "$e".Trim()
        if ($v -and $seen.Add($v)) { $merged.Add($v) }
    }
    $added = $false
    foreach ($w in $Wanted) {
        $v = "$w".Trim()
        if ($v -and $seen.Add($v)) { $merged.Add($v); $added = $true }
    }
    if (-not $added) { return $null }
    return $merged.ToArray()
}

# Runs a native command, returning its merged stdout+stderr and throwing on a
# non-zero exit with that output attached. The output is the whole diagnostic
# value here: `sharing`, `smbpasswd`, `sysadminctl`, and `testparm` all exit 1
# for a wide range of unrelated causes, so the exit code alone never says what
# to fix. -AllowFailure turns it into a probe that returns the result instead.
function Invoke-LocalLabStorageNative {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$ArgumentList = @(),
        [Parameter()][AllowEmptyString()][AllowNull()][string]$Stdin,
        [switch]$AllowFailure
    )
    # Pinned locally so THIS function's exit-code contract governs regardless of
    # the caller's preferences. With $PSNativeCommandUseErrorActionPreference
    # true (a profile or a wrapping script can set it) a non-zero exit becomes a
    # terminating error, which would turn every -AllowFailure probe below -- "is
    # the package installed", "is smbd running", "does this sharepoint exist" --
    # into a thrown exception instead of the answer it is asking for.
    $PSNativeCommandUseErrorActionPreference = $false
    $output = if ($PSBoundParameters.ContainsKey('Stdin')) {
        $Stdin | & $FilePath @ArgumentList 2>&1
    } else {
        & $FilePath @ArgumentList 2>&1
    }
    $code = $LASTEXITCODE
    $text = (@($output) | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "$FilePath $($ArgumentList -join ' ') exited $code`: $text"
    }
    return @{ ExitCode = $code; Output = $text }
}

<#
.SYNOPSIS
True when a local OS account with this name exists. Cross-platform.
#>
function Test-LocalLabStorageAccount {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)
    if ($IsWindows) { return [bool](Get-LocalUser -Name $Name -ErrorAction SilentlyContinue) }
    # `id` exits non-zero for an absent account, which IS the answer here -- see
    # Invoke-LocalLabStorageNative for why the preference is pinned.
    $PSNativeCommandUseErrorActionPreference = $false
    & id $Name *> $null
    return ($LASTEXITCODE -eq 0)
}

<#
.SYNOPSIS
Creates -- or, when it already exists, re-synchronizes the password of -- the local service account an SMB share is scoped to. Returns 'created', 'updated', or 'whatif'.
.DESCRIPTION
The account is a storage account, not a login: no administrator group, no interactive shell, and on macOS hidden from the login window. If it is ever leaked it reaches one share and nothing else on the machine.

Re-synchronizing an existing account's password is what makes a re-run converge. The vault is the source of truth for the value, so an account whose password drifted from the vault (or an account of the same name that predates this script) is brought back into agreement rather than left as a mount that fails with a credential error nobody can explain.

On Ubuntu the OS password is left LOCKED and the SMB credential lives in Samba's own passdb -- the account cannot be used to log in at all. Windows and macOS have no separate SMB password store, so there the OS password IS the share password.
#>
function Set-LocalLabStorageAccount {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'The value comes from the lab vault, which stores plaintext by design; SecureString cannot reach smbpasswd stdin or sysadminctl.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '',
        Justification = 'Creating a local OS account inherently needs both.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'New-LocalUser requires a SecureString; the plaintext is already in memory.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$Description
    )
    $exists = Test-LocalLabStorageAccount -Name $Name
    $verb = if ($exists) { 'Re-synchronize the password of the existing account' } else { 'Create the storage account' }
    if (-not $PSCmdlet.ShouldProcess($Name, $verb)) { return 'whatif' }

    if ($IsWindows) {
        $secure = ConvertTo-SecureString -String $Password -AsPlainText -Force
        if ($exists) {
            Set-LocalUser -Name $Name -Password $secure -ErrorAction Stop
        } else {
            $null = New-LocalUser -Name $Name -Password $secure -FullName $Description `
                -Description $Description -PasswordNeverExpires -UserMayNotChangePassword -ErrorAction Stop
        }
        # Membership in the built-in Users group carries the "access this computer
        # from the network" right the share connection needs. Resolved by
        # well-known SID because the group NAME is localized. Nothing beyond it is
        # granted -- notably not Administrators.
        $usersGroup = Get-LocalGroup | Where-Object { $_.SID.Value -eq 'S-1-5-32-545' } | Select-Object -First 1
        if (-not $usersGroup) {
            Write-Warning "Could not resolve the built-in Users group (SID S-1-5-32-545); '$Name' may lack the network logon right."
        } else {
            $already = $false
            try {
                $already = [bool](@(Get-LocalGroupMember -Group $usersGroup.Name -ErrorAction Stop) |
                    Where-Object { $_.Name -eq $Name -or $_.Name -like "*\$Name" })
            } catch {
                Write-Verbose "Could not enumerate '$($usersGroup.Name)': $($_.Exception.Message)"
            }
            if (-not $already) {
                Add-LocalGroupMember -Group $usersGroup.Name -Member $Name -ErrorAction SilentlyContinue
            }
        }
    } elseif ($IsMacOS) {
        # sysadminctl takes the password on its argument vector, briefly exposing
        # it to `ps`. There is no stdin-capable equivalent on macOS; the same
        # residual exposure is accepted (and documented) by New-LocalTestUser and
        # by the macOS branch of the poolStorage mount.
        if ($exists) {
            $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('sysadminctl', '-resetPasswordFor', $Name, '-newPassword', $Password)
        } else {
            $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @(
                'sysadminctl', '-addUser', $Name, '-fullName', $Description, '-password', $Password, '-shell', '/usr/bin/false')
            # A storage account has no business appearing at the login window.
            $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('dscl', '.', '-create', "/Users/$Name", 'IsHidden', '1') -AllowFailure
        }
        # Directory Services accepts a password that the SMB server then rejects,
        # because the two consult different authentication authorities. Proving
        # the credential authenticates here is the difference between a clear
        # failure now and an "access denied" at mount time with no cause.
        $auth = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('dscl', '.', '-authonly', $Name, $Password) -AllowFailure
        if ($auth.ExitCode -ne 0) {
            Write-Warning "macOS accepted the account '$Name' but 'dscl -authonly' did not verify its password: $($auth.Output)"
        }
    } else {
        if (-not $exists) {
            # --system: a service identity below the login UID range. No home, no
            # shell, and no -p, so the Unix password stays LOCKED -- the account
            # exists for Samba's file access and cannot be logged into.
            $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @(
                'useradd', '--system', '--user-group', '--no-create-home', '--shell', '/usr/sbin/nologin',
                '--comment', $Description, $Name)
        }
        # smbpasswd reads the password twice from stdin, so it never enters an
        # argument vector and a leading '-' cannot be mistaken for an option.
        # -a is add-or-update, so this is the same call on a re-run.
        $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('smbpasswd', '-s', '-a', $Name) -Stdin "$Password`n$Password`n"
        $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('smbpasswd', '-e', $Name) -AllowFailure
    }
    return $(if ($exists) { 'updated' } else { 'created' })
}

<#
.SYNOPSIS
Makes sure this machine is running an SMB server, installing or enabling one as the platform requires. Returns 'present', 'enabled', 'installed', or 'whatif'.
.DESCRIPTION
Windows ships the server (LanmanServer) and only needs it running. macOS ships smbd but leaves it disabled until File Sharing is turned on. Ubuntu ships neither Samba nor the cifs client, so both are installed -- cifs-utils as well, because `mount -t cifs` execs the external /sbin/mount.cifs helper and without it every mount fails with "unknown filesystem type 'cifs'".

On macOS the server is brought up BEFORE any account is created: the SMB authentication authority for a local account is materialized when its password is set, so an account whose password was set while smbd was off can authenticate everywhere except over SMB.
#>
function Enable-LocalLabStorageServer {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param()
    if ($IsWindows) {
        $svc = Get-Service -Name 'LanmanServer' -ErrorAction SilentlyContinue
        if (-not $svc) { throw "The Server (LanmanServer) service is not present on this host; SMB sharing cannot be enabled." }
        if ($svc.Status -eq 'Running') { return 'present' }
        if (-not $PSCmdlet.ShouldProcess('LanmanServer', 'Start the Windows Server (SMB) service')) { return 'whatif' }
        Set-Service -Name 'LanmanServer' -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name 'LanmanServer' -ErrorAction Stop
        return 'enabled'
    }
    if ($IsMacOS) {
        $probe = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('launchctl', 'print', 'system/com.apple.smbd') -AllowFailure
        if ($probe.ExitCode -eq 0) { return 'present' }
        if (-not $PSCmdlet.ShouldProcess('com.apple.smbd', 'Enable macOS File Sharing (SMB)')) { return 'whatif' }
        $enable = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('launchctl', 'enable', 'system/com.apple.smbd') -AllowFailure
        $start  = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('launchctl', 'kickstart', '-k', 'system/com.apple.smbd') -AllowFailure
        if ($start.ExitCode -ne 0) {
            # Releases before the launchctl subcommand rework only understand the
            # plist form.
            $start = Invoke-LocalLabStorageNative -FilePath 'sudo' `
                -ArgumentList @('launchctl', 'load', '-w', '/System/Library/LaunchDaemons/com.apple.smbd.plist') -AllowFailure
        }
        $verify = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('launchctl', 'print', 'system/com.apple.smbd') -AllowFailure
        if ($verify.ExitCode -ne 0) {
            throw "Could not enable the macOS SMB server. Turn File Sharing on in System Settings > General > Sharing and re-run. (launchctl enable: $($enable.Output); start: $($start.Output))"
        }
        return 'enabled'
    }
    # Ubuntu / Debian.
    $missing = @()
    foreach ($pkg in @('samba', 'cifs-utils')) {
        $q = Invoke-LocalLabStorageNative -FilePath 'dpkg-query' -ArgumentList @('-W', '-f=${Status}', $pkg) -AllowFailure
        if ($q.ExitCode -ne 0 -or $q.Output -notmatch 'install ok installed') { $missing += $pkg }
    }
    if ($missing.Count -eq 0) { return 'present' }
    if (-not $PSCmdlet.ShouldProcess(($missing -join ', '), 'Install with apt-get')) { return 'whatif' }
    # A machine whose package index predates the current release pocket cannot
    # resolve the packages at all, so the index is refreshed first.
    $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('apt-get', 'update') -AllowFailure
    $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList (@(
        'env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '-y', '--no-install-recommends') + $missing)
    return 'installed'
}

<#
.SYNOPSIS
Grants the tier's account write access to its storage folder, so the SMB server can write there as that account. ADDITIVE: the operator keeps ownership. Honors -WhatIf.
.DESCRIPTION
The grant never takes ownership away from the invoking operator, for two reasons that both surface on a machine that is its own storage server:

  * `New-Lab.ps1` creates each lab's pool-intent repository directly on disk under the pool folder. An operator locked out of that folder cannot add a second lab to the machine at all.
  * git refuses to operate on a repository owned by a different user ("detected dubious ownership"), so chowning the pool folder would break every later git operation on an intent repository already inside it.

So the account is added alongside the existing owner -- an inherited ACE on Windows, an inherited ACL entry on macOS, and group ownership plus setgid on Linux, where the setgid bit is what makes files created under the share carry the tier's group instead of the creator's.
#>
function Set-LocalLabStorageFolderAccess {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][pscustomobject]$Tier)
    if (-not (Test-Path -LiteralPath $Tier.FolderPath)) {
        Write-Warning "Storage folder '$($Tier.FolderPath)' does not exist; skipping its permissions."
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess($Tier.FolderPath, "Grant '$($Tier.Account)' write access")) { return $false }
    if ($IsWindows) {
        # Modify, inherited by files (OI) and folders (CI) created later. Added
        # to the existing ACL, so the inherited administrator and owner ACEs --
        # the operator's own local access -- survive.
        $null = Invoke-LocalLabStorageNative -FilePath 'icacls' -ArgumentList @($Tier.FolderPath, '/grant', "$($Tier.Account):(OI)(CI)M") -AllowFailure
    } elseif ($IsMacOS) {
        # An inherited ACL entry rather than a chown: file_inherit +
        # directory_inherit carry the grant to everything created later, and the
        # POSIX owner is untouched.
        $ace = 'allow list,add_file,search,add_subdirectory,delete_child,readattr,writeattr,' +
               'readextattr,writeextattr,readsecurity,file_inherit,directory_inherit'
        $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @(
            'chmod', '+a', "user:$($Tier.Account) $ace", $Tier.FolderPath) -AllowFailure
    } else {
        # Group ownership only -- the owning USER is left alone.
        $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('chgrp', '-R', $Tier.Account, $Tier.FolderPath) -AllowFailure
        # setgid (2770) so everything created under the share inherits the tier's
        # group; without it a file's group follows the creator and the SMB server
        # can be denied its own archive.
        $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('chmod', '2770', $Tier.FolderPath) -AllowFailure
        # Existing content predating the grant (an intent repository New-Lab
        # already created) needs the group bits too; X sets execute only where
        # it already applies, so files do not become executable.
        $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('chmod', '-R', 'g+rwX', $Tier.FolderPath) -AllowFailure
    }
    return $true
}

<#
.SYNOPSIS
Publishes the tiers as SMB shares, each scoped to its own account. Returns a hashtable of share name to 'created', 'present', or 'whatif'. Windows and macOS act per share; Ubuntu writes one generated Samba conf for all of them and reloads smbd once.
#>
function New-LocalLabStorageShare {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][object[]]$Tier)
    $result = @{}

    if ($IsLinux) {
        $includePath = '/etc/samba/yuruna.conf'
        $smbConf     = '/etc/samba/smb.conf'
        if (-not $PSCmdlet.ShouldProcess($includePath, "Define the yuruna shares and reload smbd")) {
            foreach ($t in $Tier) { $result[$t.ShareName] = 'whatif' }
            return $result
        }
        # Written through a temp file owned by this user and moved into place with
        # sudo: a here-string piped to `sudo tee` would be at the mercy of shell
        # quoting for every path in the generated config.
        $body = Get-LocalLabStorageSambaConfig -Tier $Tier
        $tmp  = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna.smb.$PID.$([guid]::NewGuid().ToString('N')).conf")
        try {
            [System.IO.File]::WriteAllText($tmp, $body, [System.Text.UTF8Encoding]::new($false))
            $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('install', '-m', '0644', '-o', 'root', '-g', 'root', $tmp, $includePath)
        } finally {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }

        $current = ''
        if (Test-Path -LiteralPath $smbConf) { $current = Get-Content -Raw -LiteralPath $smbConf }
        $updated = Add-LocalLabStorageSambaInclude -Content $current -IncludePath $includePath
        if ($null -ne $updated) {
            $tmp2 = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna.smbconf.$PID.$([guid]::NewGuid().ToString('N')).conf")
            try {
                [System.IO.File]::WriteAllText($tmp2, $updated, [System.Text.UTF8Encoding]::new($false))
                $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('install', '-m', '0644', '-o', 'root', '-g', 'root', $tmp2, $smbConf)
            } finally {
                Remove-Item -LiteralPath $tmp2 -Force -ErrorAction SilentlyContinue
            }
        }
        # A config Samba rejects leaves smbd serving the PREVIOUS definitions, so
        # the shares would appear to be missing with no error anywhere. testparm
        # is the same parser smbd uses, so this catches it here.
        $check = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('testparm', '-s') -AllowFailure
        if ($check.ExitCode -ne 0) {
            throw "Samba rejected the generated configuration; the shares were NOT activated: $($check.Output)"
        }
        $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('systemctl', 'enable', '--now', 'smbd') -AllowFailure
        $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('systemctl', 'reload-or-restart', 'smbd')
        foreach ($t in $Tier) { $result[$t.ShareName] = 'created' }
        return $result
    }

    foreach ($t in $Tier) {
        if ($IsWindows) {
            $existing = Get-SmbShare -Name $t.ShareName -ErrorAction SilentlyContinue
            if ($existing) {
                if ($existing.Path -ne $t.FolderPath) {
                    throw "An SMB share named '$($t.ShareName)' already exists on this host and points at '$($existing.Path)', not '$($t.FolderPath)'. Remove or rename it, then re-run."
                }
                if (-not $PSCmdlet.ShouldProcess($t.ShareName, "Grant '$($t.Account)' full access to the existing share")) { $result[$t.ShareName] = 'whatif'; continue }
                $null = Grant-SmbShareAccess -Name $t.ShareName -AccountName $t.Account -AccessRight Full -Force -ErrorAction SilentlyContinue
                $result[$t.ShareName] = 'present'
                continue
            }
            if (-not $PSCmdlet.ShouldProcess($t.ShareName, "Create the SMB share for '$($t.FolderPath)'")) { $result[$t.ShareName] = 'whatif'; continue }
            # -FullAccess names the ONLY principal on the share ACL, so the
            # default Everyone/Read grant a bare New-SmbShare would apply is
            # never created.
            $null = New-SmbShare -Name $t.ShareName -Path $t.FolderPath -FullAccess $t.Account `
                -Description "Yuruna $($t.Kind) storage" -ErrorAction Stop
            $result[$t.ShareName] = 'created'
            continue
        }
        # macOS.
        $listed = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('sharing', '-l') -AllowFailure
        if ($listed.Output -match "(?m)^\s*name:\s*$([regex]::Escape($t.ShareName))\s*$") {
            $result[$t.ShareName] = 'present'
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($t.ShareName, "Create the macOS SMB sharepoint for '$($t.FolderPath)'")) { $result[$t.ShareName] = 'whatif'; continue }
        # -s 001 is the AFP/FTP/SMB protocol mask: SMB only. -g 000 refuses guest
        # access on all three, so the share is reachable only with the tier's
        # credential.
        $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('sharing', '-a', $t.FolderPath, '-S', $t.ShareName, '-n', $t.ShareName, '-s', '001', '-g', '000')
        $result[$t.ShareName] = 'created'
    }
    return $result
}

<#
.SYNOPSIS
Registers the storage server aliases as Windows loopback-check exemptions so the machine will accept its own SMB connections under those names. Returns 'present', 'updated', 'whatif', or 'skipped'. No-op off Windows.
.DESCRIPTION
See Merge-LocalLabStorageBackConnectionName for why the exemption is needed at all. The value is read by LSA when the Server service starts, so the service is restarted; when a restart is refused, the operator is told a reboot applies it instead.
#>
function Set-LocalLabStorageLoopbackException {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param([Parameter(Mandatory)][string[]]$Name)
    if (-not $IsWindows) { return 'skipped' }
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0'
    $existing = @()
    try {
        $existing = @((Get-ItemProperty -Path $key -Name 'BackConnectionHostNames' -ErrorAction Stop).BackConnectionHostNames)
    } catch {
        Write-Verbose "BackConnectionHostNames is not set yet: $($_.Exception.Message)"
    }
    $merged = Merge-LocalLabStorageBackConnectionName -Existing $existing -Wanted $Name
    if ($null -eq $merged) { return 'present' }
    if (-not $PSCmdlet.ShouldProcess("$key\BackConnectionHostNames", "Add $($Name -join ', ')")) { return 'whatif' }
    if (-not (Test-Path -LiteralPath $key)) { $null = New-Item -Path $key -Force }
    New-ItemProperty -Path $key -Name 'BackConnectionHostNames' -Value $merged -PropertyType MultiString -Force -ErrorAction Stop | Out-Null
    try {
        Restart-Service -Name 'LanmanServer' -Force -ErrorAction Stop
    } catch {
        Write-Warning "Registered the loopback exemption but could not restart the Server service ($($_.Exception.Message)). Reboot to apply it if the mount is refused with access denied."
    }
    return 'updated'
}

<#
.SYNOPSIS
Sets EnableLinkedConnections so a drive mapped in an elevated session is also visible to the operator's ordinary session. Returns 'present', 'updated', or 'skipped'. Windows only; the change takes effect at the next sign-in.
.DESCRIPTION
UAC gives an administrator two logon tokens and mounts drive mappings on the token that created them. This script must run elevated to create accounts and shares, so without this the mapped Y:/Z: would exist for elevated processes and be missing from Explorer and from an ordinary shell -- looking like the mount silently failed.
#>
function Set-LocalLabStorageLinkedConnection {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param()
    if (-not $IsWindows) { return 'skipped' }
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $current = $null
    try { $current = (Get-ItemProperty -Path $key -Name 'EnableLinkedConnections' -ErrorAction Stop).EnableLinkedConnections } catch { $null = $_ }
    if (1 -eq $current) { return 'present' }
    if (-not $PSCmdlet.ShouldProcess("$key\EnableLinkedConnections", 'Set to 1')) { return 'whatif' }
    if (-not (Test-Path -LiteralPath $key)) { $null = New-Item -Path $key -Force }
    New-ItemProperty -Path $key -Name 'EnableLinkedConnections' -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    return 'updated'
}

<#
.SYNOPSIS
Points the storage server aliases at the loopback address in the hosts file, via automation/Set-HostAlias.ps1. Returns the number of aliases written.
.DESCRIPTION
The alias is the seam that keeps this lab's config identical in shape to a lab with a real NAS: test.config.yml and the guest seeds carry the NAME, so moving the storage to real hardware later changes the address this maps to and nothing else.
#>
function Set-LocalLabStorageHostAlias {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string[]]$Name
    )
    $aliasScript = Join-Path -Path $RepoRoot -ChildPath 'automation' -AdditionalChildPath 'Set-HostAlias.ps1'
    if (-not (Test-Path -LiteralPath $aliasScript)) {
        Write-Warning "Set-HostAlias.ps1 not found at $aliasScript; add the alias lines to the hosts file by hand."
        return 0
    }
    $address = $script:LoopbackAddress
    $written = 0
    foreach ($n in $Name) {
        if (-not $PSCmdlet.ShouldProcess($n, "Map to $address in the hosts file")) { continue }
        if ($IsWindows) {
            # Called in-process: this session is already elevated, and
            # Set-HostAlias asserts elevation itself, so a nested launch would
            # only add a second UAC prompt.
            & $aliasScript -ComputerName $n -IPAddress $address
        } else {
            # Re-launched under sudo because the hosts file is root-owned and
            # Set-HostAlias refuses to run as an unprivileged user.
            $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @(
                'pwsh', '-NoProfile', '-File', $aliasScript, '-ComputerName', $n, '-IPAddress', $address)
        }
        $written++
    }
    return $written
}

<#
.SYNOPSIS
Writes the six networkStorage keys (pool and stash) for the supplied tiers into test.config.yml, preserving every other setting. Optionally turns pool replication on. Returns $true when the file was written.
.DESCRIPTION
The document is round-tripped rather than templated, because test.config.yml is per-host and git-ignored: it already holds the operator's project URL, guest sequence, and service ports, none of which this may disturb.
#>
function Set-LocalLabStorageConfigValue {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][object[]]$Tier,
        [switch]$EnableReplication
    )
    if (-not $PSCmdlet.ShouldProcess($ConfigPath, 'Write the networkStorage pool + stash values')) { return $false }
    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue) -or -not (Get-Command ConvertTo-Yaml -ErrorAction SilentlyContinue)) {
        Write-Warning "powershell-yaml is not available; cannot write $ConfigPath. Install it with: Install-Module powershell-yaml -Scope CurrentUser"
        return $false
    }
    try {
        $doc = $null
        if (Test-Path -LiteralPath $ConfigPath) {
            $doc = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Yaml -Ordered
        }
        if (-not ($doc -is [System.Collections.IDictionary])) { $doc = [ordered]@{} }
        if (-not ($doc['networkStorage'] -is [System.Collections.IDictionary])) { $doc['networkStorage'] = [ordered]@{} }
        $ns = $doc['networkStorage']
        foreach ($t in $Tier) {
            $ns["$($t.ConfigPrefix)NetworkPath"] = $t.NetworkPath
            $ns["$($t.ConfigPrefix)NetworkUser"] = $t.Account
            $ns["$($t.ConfigPrefix)LocalPath"]   = $t.LocalPath
        }
        if ($EnableReplication) {
            # networkReplicate is a pool BEHAVIOR, so it lives under `pool`;
            # networkStorage carries only paths and accounts.
            if (-not ($doc['pool'] -is [System.Collections.IDictionary])) { $doc['pool'] = [ordered]@{} }
            $doc['pool']['networkReplicate'] = $true
        }
        $yaml = ConvertTo-Yaml $doc
        $wrote = $false
        if (Get-Command Write-YurunaStateFile -ErrorAction SilentlyContinue) {
            $wrote = [bool](Write-YurunaStateFile -Path $ConfigPath -Content $yaml -Confirm:$false)
        }
        if (-not $wrote) { [System.IO.File]::WriteAllText($ConfigPath, $yaml, [System.Text.UTF8Encoding]::new($false)) }
        if (Get-Command Clear-TestConfigCache -ErrorAction SilentlyContinue) { Clear-TestConfigCache }
        return $true
    } catch {
        Write-Warning "Could not write $ConfigPath ($($_.Exception.Message))."
        return $false
    }
}

# Reading a lab vault is Test.Lab's job (Get-YurunaLabVaultPassword) -- the lab
# vault format has one owner, so a reader here could not drift from the writer
# there.

Export-ModuleMember -Function `
    Get-LocalLabStoragePlatform, Select-LocalLabStorageDataDrive, Get-LocalLabStorageWindowsDataDrive, `
    Get-LocalLabStorageDefaultRoot, New-LocalLabStorageTier, Get-LocalLabStorageSambaConfig, `
    Add-LocalLabStorageSambaInclude, Merge-LocalLabStorageBackConnectionName, `
    Test-LocalLabStorageAccount, Set-LocalLabStorageAccount, Enable-LocalLabStorageServer, `
    Set-LocalLabStorageFolderAccess, New-LocalLabStorageShare, Set-LocalLabStorageLoopbackException, `
    Set-LocalLabStorageLinkedConnection, Set-LocalLabStorageHostAlias, Set-LocalLabStorageConfigValue

# Copyright (c) 2019-2026 by Alisson Sol et al.
