<#PSScriptInfo
.VERSION 2026.08.02
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

# Get-SudoPwshArgumentList (the nested-sudo argument vector) lives here.
Import-Module (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'automation' -AdditionalChildPath 'Yuruna.Common.psm1') -Global -Force -DisableNameChecking

# Server aliases the two tiers are reached under. They resolve to the loopback
# address here, but the NAME is what test.config.yml and the guest seeds carry,
# so repointing this lab at a real NAS later is a hosts-file edit and nothing
# else. The address is deliberately host-local: the service VMs consume these
# shares too, and they are handed a guest-reachable address at seed-bake time
# by Get-YurunaPoolSeedValue / Get-YurunaStashSeedValue rather than this one.
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

function Set-MacSmbCredential {
<#
.SYNOPSIS
Gives a macOS local account the password record smbd authenticates against, and reports whether it now has one. macOS only.
.DESCRIPTION
smbd authenticates against the account's AuthenticationAuthority record, and `sysadminctl -addUser` does not always leave one. `pwpolicy -sethashtypes` cannot supply it: with no record to modify it exits 0 and changes nothing, so its exit code reports success either way. So the record is written first, then the hash type, then the password -- the hash list governs only hashes generated AFTER it changes, which makes those three one step rather than three.

EVERY READ OF THE RECORD IS PRIVILEGED. macOS shows AuthenticationAuthority only to root and to the account itself: an ordinary user reading ANOTHER account's record gets "No such key" whether or not the attribute is there, and a real login account reads exactly like a broken one. A check built on an unprivileged read therefore reports failure always, and the "repair" it triggers deletes a perfectly good account.

Nothing here reports whether the credential WORKS -- the directory record cannot answer that. Only the server can, via Test-LocalLabStorageSmbAuth, and only once a sharepoint exists to authenticate against.
.OUTPUTS
[hashtable] @{ Ok; Detail } -- Ok is $false only when a command failed outright; Detail carries the captured output.
#>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'The value comes from the lab vault, which stores plaintext by design; SecureString cannot reach sysadminctl.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '',
        Justification = 'Re-setting a specific account password inherently needs both.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Password
    )
    if (-not $PSCmdlet.ShouldProcess($Name, 'Write the password record smbd authenticates against')) {
        return @{ Ok = $false; Detail = 'whatif' }
    }
    $detail = [System.Collections.Generic.List[string]]::new()
    # Read under sudo, and only ADD the record when it is genuinely absent.
    # Overwriting an existing one would strip whatever else it carries -- a
    # SecureToken entry, the Kerberos LKDC identity a normal account gets -- and
    # those are credentials too, so a blind write can take away the very thing
    # that was working.
    $authority = Invoke-LocalLabStorageNative -FilePath 'sudo' `
        -ArgumentList @('dscl', '.', '-read', "/Users/$Name", 'AuthenticationAuthority') -AllowFailure
    if ($authority.ExitCode -ne 0 -or $authority.Output -notmatch 'ShadowHash') {
        Write-Information "      $($Name): writing the password record smbd authenticates against (dscl)..."
        $write = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @(
            'dscl', '.', '-create', "/Users/$Name", 'AuthenticationAuthority',
            ';ShadowHash;HASHLIST:<SALTED-SHA512-PBKDF2,SMB-NT>') -AllowFailure
        if ($write.ExitCode -ne 0) { $detail.Add("dscl -create AuthenticationAuthority exited $($write.ExitCode): $($write.Output)") }
    }
    Write-Information "      $($Name): enabling the SMB-NT hash type (pwpolicy)..."
    $hashTypes = Invoke-LocalLabStorageNative -FilePath 'sudo' `
        -ArgumentList @('pwpolicy', '-u', $Name, '-sethashtypes', 'SMB-NT', 'on') -AllowFailure
    if ($hashTypes.ExitCode -ne 0) { $detail.Add("pwpolicy -sethashtypes exited $($hashTypes.ExitCode): $($hashTypes.Output)") }
    # `dscl -passwd`, NOT `sysadminctl -resetPasswordFor`. Both set the password
    # and both leave OpenDirectory accepting it -- `dscl -authonly` passes either
    # way -- but only the directory-level write regenerates the stored hashes
    # through the hash list that was just changed. Via sysadminctl the account
    # ends up with a correct password and no NT hash, which is precisely the
    # split this failure has: OpenDirectory says yes, smbd says
    # "server rejected the authentication", and the mount that follows reports
    # the rejection as "No such file or directory".
    Write-Information "      $($Name): re-setting the password so the SMB hash is regenerated (dscl)..."
    $passwd = Invoke-LocalLabStorageNative -FilePath 'sudo' `
        -ArgumentList @('dscl', '.', '-passwd', "/Users/$Name", $Password) -AllowFailure
    if ($passwd.ExitCode -ne 0) {
        $detail.Add("dscl -passwd exited $($passwd.ExitCode): $($passwd.Output)")
        # Fall back rather than leave the account with no password at all: a
        # correct password without an SMB hash is still better than a rejected
        # one, and the share probe reports which of the two this ended as.
        Write-Information "      $($Name): dscl could not set it; falling back to sysadminctl..."
        $reset = Invoke-LocalLabStorageNative -FilePath 'sudo' `
            -ArgumentList @('sysadminctl', '-resetPasswordFor', $Name, '-newPassword', $Password) -AllowFailure
        if ($reset.ExitCode -ne 0) { $detail.Add("sysadminctl -resetPasswordFor exited $($reset.ExitCode): $($reset.Output)") }
    }
    return @{ Ok = ($detail.Count -eq 0); Detail = ($detail -join "`n  ") }
}

function Reset-LocalLabStorageAccount {
<#
.SYNOPSIS
Deletes a macOS storage account and builds it again from nothing, then re-applies its SMB credential. Returns $true when the account exists afterwards. macOS only.
.DESCRIPTION
The last repair available when the SMB server rejects an account whose password is otherwise correct. Nothing in a storage account is worth preserving -- the name, the password and the share grant are all re-derived from the lab vault -- so rebuilding costs nothing and clears whatever state the rejection came from.

Called only after Test-LocalLabStorageSmbAuth has returned 'auth' against a PUBLISHED share, which is the one check that reflects what the server will actually do. Driving a delete from anything weaker (a directory-record read, an exit code) risks destroying a working account over a question that was never really asked.
#>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'The value comes from the lab vault, which stores plaintext by design; SecureString cannot reach sysadminctl.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '',
        Justification = 'Recreating a local account inherently needs both.')]
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$Description
    )
    if (-not $IsMacOS) { return $false }
    if (-not $PSCmdlet.ShouldProcess($Name, 'Delete and rebuild the storage account')) { return $false }
    if (-not (Remove-MacLocalAccount -Name $Name -Confirm:$false)) {
        Write-Warning "Could not delete '$Name', so it could not be rebuilt."
        return $false
    }
    $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @(
        'sysadminctl', '-addUser', $Name, '-fullName', $Description, '-password', $Password, '-shell', '/usr/bin/false') -AllowFailure
    $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('dscl', '.', '-create', "/Users/$Name", 'IsHidden', '1') -AllowFailure
    $null = Set-MacSmbCredential -Name $Name -Password $Password -Confirm:$false
    return (Test-LocalLabStorageAccount -Name $Name)
}

function Remove-MacLocalAccount {
<#
.SYNOPSIS
Deletes a macOS local account, so it can be built again from nothing. Best-effort; returns $true when the account is gone afterwards. macOS only.
.DESCRIPTION
`sysadminctl -deleteUser` is the supported path and takes the home directory with it. `dscl -delete` is the fallback for a record sysadminctl will not own -- a half-created account, which is exactly the state worth recovering from here.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Name)
    if (-not $PSCmdlet.ShouldProcess($Name, 'Delete the local storage account')) { return $false }
    $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('sysadminctl', '-deleteUser', $Name) -AllowFailure
    if (Test-LocalLabStorageAccount -Name $Name) {
        $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('dscl', '.', '-delete', "/Users/$Name") -AllowFailure
    }
    return (-not (Test-LocalLabStorageAccount -Name $Name))
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
        #
        # sysadminctl has no '--' end-of-options marker, so a leading '-' would be
        # parsed as an option and the account would end up with a password the
        # vault does not agree with. New-Lab reuses a host-vault credential when
        # one is already present, and a hand-populated entry carries no
        # leading-character guarantee, so this is reachable -- same guard as
        # New-LocalTestUser.
        if ($Password.StartsWith('-')) {
            throw "On macOS the '$Name' storage password may not begin with '-' (sysadminctl would parse it as an option). Change it in the lab vault and re-run."
        }
        # Each sudo call below is captured, so it prints nothing of its own while
        # it runs, and sysadminctl in particular takes seconds. Narrated so the
        # operator can see which one is in flight.
        if ($exists) {
            Write-Information "      $($Name): re-synchronizing the account password (sysadminctl)..."
            $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('sysadminctl', '-resetPasswordFor', $Name, '-newPassword', $Password)
        } else {
            Write-Information "      $($Name): creating the account (sysadminctl)..."
            $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @(
                'sysadminctl', '-addUser', $Name, '-fullName', $Description, '-password', $Password, '-shell', '/usr/bin/false')
            # A storage account has no business appearing at the login window.
            $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('dscl', '.', '-create', "/Users/$Name", 'IsHidden', '1') -AllowFailure
        }
        # Write the credential; do NOT try to judge here whether it works. There is
        # no sharepoint yet at this point in the run, and without one the server
        # refuses every credential -- so the only check available here cannot tell
        # a bad password from a share that does not exist yet. The verdict, and
        # the rebuild it may call for, belong to the caller once the shares are
        # published (Test-LocalLabStorageSmbAuth, then Reset-LocalLabStorageAccount).
        $credential = Set-MacSmbCredential -Name $Name -Password $Password -Confirm:$false
        if (-not $credential.Ok) {
            Write-Warning "Setting the SMB credential for '$Name' reported an error; the share probe will confirm whether it took.`n  $($credential.Detail)"
        }
    } else {
        if (-not $exists) {
            Write-Information "      $($Name): creating the system account (useradd)..."
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
        Write-Information "      $($Name): storing the Samba credential (smbpasswd)..."
        $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('smbpasswd', '-s', '-a', $Name) -Stdin "$Password`n$Password`n"
        $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('smbpasswd', '-e', $Name) -AllowFailure
    }
    return $(if ($exists) { 'updated' } else { 'created' })
}

<#
.SYNOPSIS
Classifies an `smbutil view` result into 'ok', 'auth', 'unreachable', or 'unknown'. Pure: takes the exit code and output, returns the verdict.
.DESCRIPTION
The two failures need different advice and look alike from the exit code alone, so the message is chosen from the OUTPUT: a refused credential means the account exists but has no SMB-NT hash (or the wrong password), while a refused connection means the SMB server is not up or not listening yet -- reporting the second as an authentication problem is the misdiagnosis this whole probe exists to prevent.
#>
function Get-LocalLabStorageSmbAuthVerdict {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Output
    )
    if ($ExitCode -eq 0) { return 'ok' }
    $text = "$Output"
    if ($text -match '(?i)authentication error|not permitted|permission denied|password') { return 'auth' }
    if ($text -match '(?i)connection refused|can''t connect|unable to connect|no route to host|timed out|server connection') { return 'unreachable' }
    return 'unknown'
}

<#
.SYNOPSIS
Proves a storage account can authenticate OVER SMB, which is the only authority that matters for the mount. Returns the Get-LocalLabStorageSmbAuthVerdict verdict; 'skipped' off macOS.
.DESCRIPTION
Directory Services accepts a password that smbd then rejects -- they consult different authentication authorities -- so `dscl -authonly` passes on exactly the account that cannot mount. Only an actual SMB conversation settles it. Run this AFTER the sharepoint exists: against a server with no share published yet, a refusal says nothing about the credential.
#>
function Test-LocalLabStorageSmbAuth {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'The value comes from the lab vault, which stores plaintext by design; SecureString cannot reach an smbutil URL.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '',
        Justification = 'Authenticating a specific account inherently needs both.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Account,
        [Parameter(Mandatory)][string]$Password
    )
    if (-not $IsMacOS) { return 'skipped' }
    # Percent-encoded: a password carrying '@', '/' or ':' would otherwise split
    # the URL authority and the probe would test a different (or malformed) target.
    $user = [uri]::EscapeDataString($Account)
    $pass = [uri]::EscapeDataString($Password)
    $probe = Invoke-LocalLabStorageNative -FilePath 'smbutil' -ArgumentList @('view', "//${user}:${pass}@127.0.0.1") -AllowFailure
    return (Get-LocalLabStorageSmbAuthVerdict -ExitCode $probe.ExitCode -Output $probe.Output)
}

<#
.SYNOPSIS
Makes sure this machine is running an SMB server, installing or enabling one as the platform requires. Returns 'present', 'enabled', 'installed', or 'whatif'.
.DESCRIPTION
Windows ships the server (LanmanServer) and only needs it running. macOS ships smbd but leaves it disabled until File Sharing is turned on. Ubuntu ships neither Samba nor the cifs client, so both are installed -- cifs-utils as well, because `mount -t cifs` execs the external /sbin/mount.cifs helper and without it every mount fails with "unknown filesystem type 'cifs'".

On macOS the server is brought up BEFORE any account is created, so the shares can be published and probed in the same run. Note that this ordering is NOT what gives an account its SMB credential: this function only enables smbd (launchctl), which touches no user record. The SMB-NT hash is created by Set-LocalLabStorageAccount's explicit pwpolicy call, and nothing else creates it.
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
        Write-Information "      File Sharing is off; enabling and starting smbd (launchctl)..."
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
    Write-Information "      refreshing the package index (apt-get update)..."
    $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('apt-get', 'update') -AllowFailure
    Write-Information "      installing $($missing -join ', ') -- this can take several minutes..."
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
        Write-Information "      checking the generated Samba configuration (testparm)..."
        $check = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('testparm', '-s') -AllowFailure
        if ($check.ExitCode -ne 0) {
            throw "Samba rejected the generated configuration; the shares were NOT activated: $($check.Output)"
        }
        Write-Information "      reloading smbd..."
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
        # macOS. A sharepoint that is already listed is REMOVED and published
        # again rather than left alone: "a sharepoint by that name exists" and
        # "the sharepoint this lab needs" are not the same statement, and the
        # difference between them -- a stale path, a protocol mask that no longer
        # includes SMB, a guest grant -- is invisible from the name alone. The
        # definition is cheap to rebuild and is the only one that is known good.
        $listed = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('sharing', '-l') -AllowFailure
        $existed = ($listed.Output -match "(?m)^\s*name:\s*$([regex]::Escape($t.ShareName))\s*$")
        if (-not $PSCmdlet.ShouldProcess($t.ShareName, "$(if ($existed) { 'Replace' } else { 'Create' }) the macOS SMB sharepoint for '$($t.FolderPath)'")) { $result[$t.ShareName] = 'whatif'; continue }
        if ($existed) {
            Write-Information "      $($t.ShareName): removing the previous sharepoint (sharing -r)..."
            $null = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList @('sharing', '-r', $t.ShareName) -AllowFailure
        }
        # -s 001 is the AFP/FTP/SMB protocol mask: SMB only. -g 000 refuses guest
        # access on all three, so the share is reachable only with the tier's
        # credential.
        Write-Information "      $($t.ShareName): publishing the sharepoint (sharing -a)..."
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
        # The non-Windows arm below starts a whole nested pwsh under sudo, which
        # is a second or two of silence per alias.
        Write-Information "      $n -> $address in the hosts file..."
        if ($IsWindows) {
            # Called in-process: this session is already elevated, and
            # Set-HostAlias asserts elevation itself, so a nested launch would
            # only add a second UAC prompt.
            & $aliasScript -ComputerName $n -IPAddress $address
        } else {
            # Re-launched under sudo because the hosts file is root-owned and
            # Set-HostAlias refuses to run as an unprivileged user. The argument
            # vector comes from Get-SudoPwshArgumentList: a bare 'pwsh' under a
            # stripped environment is how this step used to die with a .NET
            # "libhostfxr not found" exit 131, three steps before the vault and
            # the config were written.
            $aliasArgs = Get-SudoPwshArgumentList -ScriptPath $aliasScript `
                -ScriptArgument @('-ComputerName', $n, '-IPAddress', $address)
            $aliasRun = Invoke-LocalLabStorageNative -FilePath 'sudo' -ArgumentList $aliasArgs -AllowFailure
            if ($aliasRun.ExitCode -ne 0) {
                throw ("Could not write the '$n' hosts-file alias (sudo pwsh exited $($aliasRun.ExitCode)): $($aliasRun.Output)`n" +
                    "If that names a missing .NET runtime, this host's PowerShell is the Homebrew formula build and cannot start with a stripped environment. Fix it once, machine-wide:`n" +
                    "  echo `"`$(brew --prefix dotnet)/libexec`" | sudo tee /etc/dotnet/install_location_`$(uname -m)`n" +
                    "then re-run this script -- it is idempotent and will converge.")
            }
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
    Get-LocalLabStorageSmbAuthVerdict, Test-LocalLabStorageSmbAuth, `
    Get-LocalLabStoragePlatform, Select-LocalLabStorageDataDrive, Get-LocalLabStorageWindowsDataDrive, `
    Get-LocalLabStorageDefaultRoot, New-LocalLabStorageTier, Get-LocalLabStorageSambaConfig, `
    Add-LocalLabStorageSambaInclude, Merge-LocalLabStorageBackConnectionName, `
    Test-LocalLabStorageAccount, Set-LocalLabStorageAccount, Reset-LocalLabStorageAccount, Enable-LocalLabStorageServer, `
    Set-LocalLabStorageFolderAccess, New-LocalLabStorageShare, Set-LocalLabStorageLoopbackException, `
    Set-LocalLabStorageLinkedConnection, Set-LocalLabStorageHostAlias, Set-LocalLabStorageConfigValue

# Copyright (c) 2019-2026 by Alisson Sol et al.
