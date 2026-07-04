<#PSScriptInfo
.VERSION 2026.07.03
.GUID 42990764-3373-4051-8f39-084f655b6d63
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Create a local OS account on the host and register it under the
    default Yuruna authentication extension. Cross-platform (Windows /
    macOS / Linux).

.DESCRIPTION
    Creates a local OS user with the supplied display name and account
    name, configured so the first interactive login is forced to change
    the password. The account is created WITHOUT a usable password; the
    operator must set the initial password out-of-band before the user
    can log in (the "change at first login" flag fires once that
    password is set).

    The same logical account name is appended to the default
    authentication extension's users.yml (and users.yml.template if no
    runtime users.yml exists yet), with empty corporate / vault fields
    so the entry behaves as a purely-local Yuruna user (cf.
    test/extension/authentication/users.yml.template).

    Fails if a user with the same account name already exists on the
    host OS or in users.yml -- the script does not attempt to update
    an existing account.

.PARAMETER FirstName
    Display first name. Combined with -LastName as the OS-level full
    name (Windows FullName, macOS fullName, Linux GECOS).

.PARAMETER LastName
    Display last name.

.PARAMETER AccountName
    OS account / login name (matches the logical username used in
    users.yml). Must start with a letter or underscore and contain only
    ASCII letters, digits, dot, underscore, or hyphen.

.EXAMPLE
    .\New-LocalTestUser.ps1 -FirstName 'Alisson' -LastName 'Sol' -AccountName 'alissonsol'

.NOTES
    Requires Administrator (Windows) or sudo (macOS / Linux).
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$FirstName,
    [Parameter(Mandatory)][string]$LastName,
    [Parameter(Mandatory)][string]$AccountName
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# -- Validate -----------------------------------------------------------
if ($AccountName -notmatch '^[A-Za-z_][A-Za-z0-9._-]*$') {
    throw "AccountName '$AccountName' is invalid. Must start with a letter or underscore and contain only ASCII letters, digits, '.', '_', or '-'."
}
foreach ($p in @('FirstName', 'LastName')) {
    if ([string]::IsNullOrWhiteSpace((Get-Variable $p -ValueOnly))) {
        throw "$p must not be empty or whitespace."
    }
}

$FullName = "$FirstName $LastName"

# -- Locate users.yml files --------------------------------------------
$TestRoot      = $PSScriptRoot
$UsersTemplate = Join-Path $TestRoot 'extension/authentication/users.yml.template'
$UsersRuntime  = Join-Path $TestRoot 'status/extension/authentication/users.yml'

if (-not (Test-Path -LiteralPath $UsersTemplate)) {
    throw "users.yml.template not found at $UsersTemplate. Is this script under test/ in a Yuruna checkout?"
}

# -- powershell-yaml dependency ----------------------------------------
if (-not (Get-Module -ListAvailable -Name powershell-yaml -ErrorAction SilentlyContinue)) {
    throw "powershell-yaml is not installed. Install with: Install-Module powershell-yaml -Scope CurrentUser"
}
Import-Module powershell-yaml -Verbose:$false -ErrorAction Stop

# -- Elevation check ---------------------------------------------------
function Test-IsElevated {
    if ($IsWindows) {
        $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    return $true
}

if ($IsWindows) {
    if (-not (Test-IsElevated)) {
        throw "Administrator privileges required on Windows. Re-run from an elevated PowerShell."
    }
} elseif ($IsMacOS -or $IsLinux) {
    if (-not (Get-Command sudo -ErrorAction SilentlyContinue)) {
        throw "sudo not found on PATH. macOS / Linux: sudo is required to create a local user."
    }
    # Pre-authenticate sudo so the operator sees a single, clearly-labeled
    # prompt for THEIR OWN login password (not a password for the account
    # about to be created -- that account doesn't exist yet, and is created
    # without a password by design). Subsequent `sudo` calls below reuse
    # the cached credential and won't re-prompt.
    $invokingUser = $env:USER
    if ([string]::IsNullOrWhiteSpace($invokingUser)) { $invokingUser = & id -un }
    Write-Information ""
    Write-Information "About to create a new local OS user via sudo."
    Write-Information "sudo will prompt for YOUR login password ($invokingUser) -- NOT a"
    Write-Information "password for the new account (that is set later, separately)."
    Write-Information ""
    & sudo -v
    if ($LASTEXITCODE -ne 0) {
        throw "sudo authentication failed (exit $LASTEXITCODE). Make sure $invokingUser is an admin (dseditgroup -o checkmember -m $invokingUser admin) and re-run."
    }
} else {
    throw "Unsupported OS. This script supports Windows, macOS, and Linux."
}

# -- Pre-flight: does the OS account already exist? --------------------
function Test-OsUser {
    param([string]$Name)
    if ($IsWindows) {
        return [bool](Get-LocalUser -Name $Name -ErrorAction SilentlyContinue)
    }
    # macOS / Linux: `id` exits 0 iff the user exists.
    & id $Name *> $null
    return ($LASTEXITCODE -eq 0)
}

if (Test-OsUser -Name $AccountName) {
    throw "OS account '$AccountName' already exists on this host. New-LocalTestUser refuses to modify existing accounts."
}

# -- Pre-flight: does users.yml already declare this name? -------------
function Test-YurunaUserDeclared {
    param([string]$Name, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $cfg = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Yaml -Ordered -ErrorAction Stop
    } catch {
        throw "Could not parse $Path as YAML: $($_.Exception.Message)"
    }
    if ($null -eq $cfg -or $null -eq $cfg.users) { return $false }
    return $cfg.users.Contains($Name)
}

foreach ($p in @($UsersTemplate, $UsersRuntime)) {
    if (Test-YurunaUserDeclared -Name $AccountName -Path $p) {
        throw "User '$AccountName' is already declared in $p. New-LocalTestUser refuses to overwrite an existing yuruna users entry."
    }
}

# -- Create the OS account ---------------------------------------------
function New-WindowsLocalUser {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name, [string]$Display)
    if (-not $PSCmdlet.ShouldProcess($Name, "New-LocalUser (no password, FullName='$Display')")) { return }
    $null = New-LocalUser -Name $Name -FullName $Display -Description 'Yuruna local test user' -NoPassword -ErrorAction Stop
    # Set PasswordExpired so the first login (once the operator has set
    # an initial password) is forced to change it. ADSI works on PS 7
    # Windows and writes the same flag `net user X /logonpasswordchg:yes`
    # sets.
    try {
        $user = [adsi]"WinNT://./${Name},user"
        $user.PasswordExpired = 1
        $user.SetInfo()
    } catch {
        Write-Warning "Could not set PasswordExpired flag via ADSI: $($_.Exception.Message)"
        Write-Warning "After setting the initial password, run manually:  net user $Name /logonpasswordchg:yes"
    }
}

function New-MacLocalUser {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name, [string]$Display)
    if (-not $PSCmdlet.ShouldProcess($Name, "sudo sysadminctl -addUser (no password, fullName='$Display')")) { return }
    $out = & sudo sysadminctl -addUser $Name -fullName $Display 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "sysadminctl -addUser exited $LASTEXITCODE`: $out"
    }
    # newPasswordRequired=1 forces a password change on the next login.
    $out = & sudo pwpolicy -u $Name -setpolicy "newPasswordRequired=1" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "pwpolicy newPasswordRequired=1 failed (exit $LASTEXITCODE): $out"
        Write-Warning "After setting the initial password, run manually:  sudo pwpolicy -u $Name -setpolicy 'newPasswordRequired=1'"
    }
}

function New-LinuxLocalUser {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name, [string]$Display)
    if (-not $PSCmdlet.ShouldProcess($Name, "sudo useradd (locked password, GECOS='$Display')")) { return }
    # No -p means the password is locked (`!` in /etc/shadow) -- the user
    # cannot log in until the operator runs `sudo passwd $Name`. -m
    # creates the home dir; -s sets a sane default login shell.
    $out = & sudo useradd -c $Display -m -s /bin/bash $Name 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "useradd exited $LASTEXITCODE`: $out"
    }
    # chage -d 0 forces a password change on the next login.
    $out = & sudo chage -d 0 $Name 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "chage -d 0 failed (exit $LASTEXITCODE): $out"
        Write-Warning "After setting the initial password, run manually:  sudo chage -d 0 $Name"
    }
}

Write-Information ""
Write-Information "Creating local OS user '$AccountName' ($FullName) ..."
if     ($IsWindows) { New-WindowsLocalUser -Name $AccountName -Display $FullName }
elseif ($IsMacOS)   { New-MacLocalUser     -Name $AccountName -Display $FullName }
elseif ($IsLinux)   { New-LinuxLocalUser   -Name $AccountName -Display $FullName }

# -- Append to users.yml (runtime + template) --------------------------
# YAML literal preserves the exact formatting used by the committed
# users.yml.template entries (2-space indent under `users:`, inline-
# flow `corporate: { domain: "", sam: "", upn: "" }`, padded keys for
# vaultKey / localOsPasswordRef). Appending text rather than round-
# tripping through ConvertTo-Yaml keeps the file's existing comments
# and entry formatting intact.
$YamlEntry = @"

  ${AccountName}:
    localOsUser: $AccountName
    corporate:   { domain: "", sam: "", upn: "" }
    vaultKey:           ""
    localOsPasswordRef: ""
"@

$wrote = New-Object System.Collections.Generic.List[string]
foreach ($p in @($UsersTemplate, $UsersRuntime)) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    if (-not $PSCmdlet.ShouldProcess($p, "Append yuruna users entry '$AccountName'")) { continue }
    Add-Content -LiteralPath $p -Value $YamlEntry -NoNewline:$false
    # Re-parse to confirm the resulting file is still valid YAML and
    # the new entry is reachable; rollback if not.
    try {
        $cfg = Get-Content -Raw -LiteralPath $p | ConvertFrom-Yaml -Ordered -ErrorAction Stop
        if ($null -eq $cfg.users -or -not $cfg.users.Contains($AccountName)) {
            throw "Post-write parse did not surface the new entry."
        }
    } catch {
        throw "Wrote '$AccountName' to $p but post-write YAML parse failed: $($_.Exception.Message). Restore the file from git or your editor's undo, then re-run."
    }
    $null = $wrote.Add($p)
}

# -- Inform the operator -----------------------------------------------
Write-Information ""
Write-Information "=========================================================="
Write-Information "  Local test user created: $AccountName ($FullName)"
Write-Information "=========================================================="
Write-Information ""
Write-Information "Action items + state:"
Write-Information ""
Write-Information "  1. The initial password for '$AccountName' HAS NOT been set."
Write-Information "     The account exists but cannot log in until you set one."
if ($IsWindows) {
    Write-Information "     Set it with:  net user $AccountName *"
    Write-Information "     (or use 'Computer Management > Local Users and Groups')"
} elseif ($IsMacOS) {
    Write-Information "     Set it with:  sudo passwd $AccountName"
    Write-Information "     (or use 'System Settings > Users & Groups')"
} elseif ($IsLinux) {
    Write-Information "     Set it with:  sudo passwd $AccountName"
}
Write-Information ""
Write-Information "  2. The account is flagged 'must change password at first login':"
if ($IsWindows) {
    Write-Information "     PasswordExpired=1 via ADSI; the first interactive sign-in"
    Write-Information "     after the initial password is set will prompt for a new one."
} elseif ($IsMacOS) {
    Write-Information "     pwpolicy newPasswordRequired=1; the first login after the"
    Write-Information "     initial password is set will prompt for a new one."
} elseif ($IsLinux) {
    Write-Information "     chage -d 0 forces a password change on the next login."
}
Write-Information ""
if ($wrote.Count -gt 0) {
    Write-Information "  3. Added to the default Yuruna authentication extension:"
    foreach ($p in $wrote) { Write-Information "       $p" }
    Write-Information "     corporate.* / vaultKey / localOsPasswordRef are empty --"
    Write-Information "     the account is registered as a purely-local Yuruna user,"
    Write-Information "     NOT yet bound to any corporate (AD / Entra / etc.) identity."
    Write-Information "     See test/extension/authentication/users.yml.template for how"
    Write-Information "     to bind a vault key / corporate identity later."
}
if ($wrote.Count -eq 1 -and $wrote[0] -eq $UsersTemplate) {
    Write-Information ""
    Write-Information "     Note: only the committed template was updated; the runtime"
    Write-Information "     users.yml does not yet exist on this host. The default"
    Write-Information "     authentication extension bootstraps it from the template on"
    Write-Information "     first use, so no further action is needed."
}
Write-Information ""
