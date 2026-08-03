<#PSScriptInfo
.VERSION 2026.08.03
.GUID 42990764-3373-4051-8f39-084f655b6d63
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
    Create a local OS account on the host, optionally with a password and
    local-machine-administrator rights, and register it under the default
    Yuruna authentication extension. Cross-platform (Windows / macOS /
    Ubuntu).

.DESCRIPTION
    Creates a local OS user with the supplied display name and account
    name. The account name defaults to `yurunatest`, so the common case is
    a single switch: `.\New-LocalTestUser.ps1 -Admin`.

    The password is set at creation and is immediately usable, so an
    unattended test host can log in without an interactive first-login
    rotation standing in the way. Three shapes:

      * Default: the password is asked for interactively (twice,
        confirmed), on the elevated side, so it never reaches shell
        history or a process argument vector.

      * With -Password: the supplied password is used instead of asking.

      * With -NoPassword: the account is created WITHOUT a usable
        password. It exists but cannot log in until the operator sets one
        out-of-band.

    -ForcePasswordChange makes the password a one-shot initial credential
    and demands a change at the first interactive login. It is opt-in --
    without it the account logs in unattended.

    -Admin additionally makes the account a local machine administrator:
    the built-in Administrators group on Windows (resolved by SID, so it
    works on non-English installs), the `admin` group on macOS, and the
    `sudo` group on Ubuntu.

    The same logical account name is appended to the default
    authentication extension's users.yml (and users.yml.template if no
    runtime users.yml exists yet), with empty corporate / vault fields
    so the entry behaves as a purely-local Yuruna user (cf.
    test/extension/authentication/users.yml.template).

    Fails if a user with the same account name already exists on the
    host OS or in users.yml -- the script does not attempt to update
    an existing account.

    Elevation is requested before anything is changed. On Windows an
    unelevated run asks for consent and then relaunches itself through
    UAC; the elevated window prompts for the password rather than
    receiving it on the command line, so the secret never appears in
    the process list. On macOS / Ubuntu the script pre-authenticates
    sudo up front, so there is a single clearly-labeled prompt.

.PARAMETER AccountName
    OS account / login name (matches the logical username used in
    users.yml). Defaults to `yurunatest`. Must start with a letter or
    underscore and contain only ASCII letters, digits, dot, underscore,
    or hyphen.

.PARAMETER Password
    Initial password for the new account. When omitted the script asks
    for one interactively rather than leaving the account unusable; pass
    -NoPassword to skip the password entirely.

.PARAMETER Admin
    Make the new account a local machine administrator.

.PARAMETER FirstName
    Display first name. Combined with -LastName as the OS-level full
    name (Windows FullName, macOS fullName, Ubuntu GECOS).

.PARAMETER LastName
    Display last name.

.PARAMETER ForcePasswordChange
    Treat the password as a one-shot initial credential: force a change
    at the first interactive login. Off unless asked for, so the account
    stays usable for unattended logins.

.PARAMETER PromptForPassword
    Read the password interactively (twice, confirmed) instead of taking
    it from -Password. This is already the default when neither -Password
    nor -NoPassword is given; the switch is how the self-elevated Windows
    window is told to ask.

.PARAMETER NoPassword
    Create the account without a usable password. It exists but cannot
    log in until the operator sets one out-of-band.

.PARAMETER Force
    Skip this script's own confirmation prompts. The operating system may
    still prompt (UAC consent, sudo password).

.EXAMPLE
    .\New-LocalTestUser.ps1 -Admin
    # The common case: creates "Yuruna Test User" (yurunatest) as a local
    # machine administrator, asking for the password once on the elevated
    # side. The account can log in immediately.

.EXAMPLE
    .\New-LocalTestUser.ps1 yurunatest 'S0me-Str0ng-Pass' -Admin
    # Two-parameter form, for a scripted run that cannot answer a prompt.
    # The password appears in shell history -- prefer the form above.

.EXAMPLE
    .\New-LocalTestUser.ps1 -FirstName 'Alisson' -LastName 'Sol' -AccountName 'alissonsol' -NoPassword
    # Account is created locked and must have a password set out-of-band
    # before first login.

.NOTES
    Requires Administrator (Windows) or sudo (macOS / Ubuntu).

    powershell-yaml is optional. It is used only to parse and re-validate
    users.yml; creating the OS account never needs it, so a freshly imaged
    host can run this before any module is installed. Without it the
    users.yml duplicate check and post-write confirmation fall back to a
    text scan of the two-space entry shape the file is written in.

    Passing a password on the command line exposes it to shell history
    and, on macOS, to the process list for the duration of the call. The
    default interactive prompt avoids both, and is asked once -- past the
    elevation gate, so a UAC relaunch does not ask a second time. Windows and Ubuntu never place the
    password in an argument vector (SecureString and chpasswd stdin
    respectively); macOS has no stdin-capable equivalent, which is also
    why a password beginning with "-" is rejected there -- sysadminctl
    would parse it as an option and silently create an account with the
    wrong credential. See docs/vmconfig.md for the trap class.
#>

# The account name and its password are both operator inputs to a local
# account-creation tool, which is exactly the pair these two rules exist
# to discourage in remoting/credential-passing code. Here the plaintext
# never leaves the machine, and -PromptForPassword is offered as the
# non-plaintext path.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'Password',
    Justification = 'Local account bootstrap; -PromptForPassword is the SecureString path.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '',
    Justification = 'Creating a local OS account inherently needs both.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'New-LocalUser requires a SecureString; the plaintext is already in memory.')]
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)][string]$AccountName = 'yurunatest',
    [Parameter(Position = 1)][string]$Password,
    [switch]$Admin,
    [string]$FirstName = 'Yuruna',
    [string]$LastName = 'Test User',
    [switch]$ForcePasswordChange,
    [switch]$PromptForPassword,
    [switch]$NoPassword,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# --- REGION: Validate
if ($AccountName -notmatch '^[A-Za-z_][A-Za-z0-9._-]*$') {
    throw "AccountName '$AccountName' is invalid. Must start with a letter or underscore and contain only ASCII letters, digits, '.', '_', or '-'."
}
foreach ($p in @('FirstName', 'LastName')) {
    if ([string]::IsNullOrWhiteSpace((Get-Variable $p -ValueOnly))) {
        throw "$p must not be empty or whitespace."
    }
}
if ($PromptForPassword -and $PSBoundParameters.ContainsKey('Password')) {
    throw "Specify either -Password or -PromptForPassword, not both."
}
if ($NoPassword -and ($PSBoundParameters.ContainsKey('Password') -or $PromptForPassword)) {
    throw "-NoPassword cannot be combined with -Password or -PromptForPassword."
}

$FullName = "$FirstName $LastName"

# --- REGION: Interactive prompts
function Confirm-Step {
    param([string]$Question)
    if ($Force) { return $true }
    $answer = Read-Host "$Question [y/N]"
    return ($answer -match '^(y|yes)$')
}

function Read-NewPassword {
    param([string]$Name)
    $first = Read-Host -Prompt "Password for new account '$Name'" -AsSecureString
    $again = Read-Host -Prompt "Confirm password" -AsSecureString
    $a = [System.Net.NetworkCredential]::new('', $first).Password
    $b = [System.Net.NetworkCredential]::new('', $again).Password
    if ($a -ne $b) { throw "The two passwords did not match." }
    if ([string]::IsNullOrEmpty($a)) { throw "Password must not be empty." }
    return $a
}

# An account with a password is the point of the tool, so a run that names
# no password asks for one rather than producing a locked account nobody can
# log into. -NoPassword is the explicit opt-out.
#
# The prompt itself is deliberately NOT here. On Windows an unelevated run
# relaunches itself through UAC and the password is never forwarded on the
# command line, so asking now would ask again in the elevated window. It is
# asked once, after the elevation gate and after the pre-flight checks -- no
# point collecting a secret for an account that already exists.
$WantsPassword = -not $NoPassword

# The must-change-at-first-login flag is opt-in. A password set here is
# usable as-is, so an unattended test host can log in without an interactive
# rotation standing in the way.
$ShouldForceChange = $ForcePasswordChange.IsPresent

# --- REGION: Locate users.yml files
$TestRoot      = $PSScriptRoot
$UsersTemplate = Join-Path $TestRoot 'extension/authentication/users.yml.template'
$UsersRuntime  = Join-Path $TestRoot 'status/extension/authentication/users.yml'

if (-not (Test-Path -LiteralPath $UsersTemplate)) {
    throw "users.yml.template not found at $UsersTemplate. Is this script under test/ in a Yuruna checkout?"
}

# --- REGION: powershell-yaml (optional)
# Creating the OS account needs no YAML at all -- the module is used only to
# read and re-validate users.yml. A freshly imaged host that does not have it
# still gets a fully created, fully privileged account; the users.yml checks
# degrade to a line scan of the same two-space entry shape this script writes.
$YamlAvailable = [bool](Get-Module -ListAvailable -Name powershell-yaml -ErrorAction SilentlyContinue)
if ($YamlAvailable) {
    # Import-Module itself takes no -WhatIf; the noise comes from the module's
    # own New-Alias calls reading $WhatIfPreference out of the caller's scope
    # chain, which makes a dry run narrate alias registrations no operator asked
    # about. Suppress the preference across the import only.
    $PreviousWhatIf = $WhatIfPreference
    try {
        $WhatIfPreference = $false
        Import-Module powershell-yaml -Verbose:$false -ErrorAction Stop
    } catch {
        Write-Warning "powershell-yaml is present but failed to import: $($_.Exception.Message)"
        Write-Warning "Falling back to a text scan of users.yml."
        $YamlAvailable = $false
    } finally {
        $WhatIfPreference = $PreviousWhatIf
    }
} else {
    Write-Information ""
    Write-Information "powershell-yaml is not installed: users.yml will be checked by text scan"
    Write-Information "instead of a YAML parse. Account creation is unaffected."
    Write-Information "Install it later with:  Install-Module powershell-yaml -Scope CurrentUser"
}

# --- REGION: Elevation
function Test-IsElevated {
    if ($IsWindows) {
        $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    return $true
}

function Invoke-SelfElevation {
    <#
        Relaunch this script through UAC. The password is deliberately
        NOT forwarded: command-line arguments of a running process are
        readable by any account on the machine, so the elevated window
        re-prompts for it instead. -NoExit keeps that window open, since
        a window spawned by -Verb RunAs closes the instant the script
        returns and would otherwise take the summary with it.
    #>
    param([bool]$WantsPassword)

    $shellExe = $null
    try { $shellExe = (Get-Process -Id $PID).Path } catch { $shellExe = $null }
    if (-not $shellExe) { $shellExe = 'pwsh.exe' }

    $argList = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"",
                 '-AccountName', "`"$AccountName`"")
    if ($PSBoundParameters.ContainsKey('FirstName')) { $argList += @('-FirstName', "`"$FirstName`"") }
    if ($PSBoundParameters.ContainsKey('LastName'))  { $argList += @('-LastName',  "`"$LastName`"") }
    if ($Admin)               { $argList += '-Admin' }
    if ($ForcePasswordChange) { $argList += '-ForcePasswordChange' }
    if ($Force)               { $argList += '-Force' }
    if ($WantsPassword)       { $argList += '-PromptForPassword' } else { $argList += '-NoPassword' }

    Write-Information ""
    Write-Information "Launching an elevated PowerShell window (UAC will prompt for consent)."
    if ($WantsPassword) {
        Write-Information "That window will ask you to type the password for '$AccountName'."
        Write-Information "It is not passed on the command line, where other accounts could read it."
    }
    Write-Information "The elevated window stays open so you can read the result."
    Write-Information ""
    Start-Process -FilePath $shellExe -Verb RunAs -ArgumentList $argList
}

# -WhatIf is a dry run: it must not raise a UAC prompt or spend a sudo
# authentication, so the whole gate is skipped and the ShouldProcess
# messages below describe what an elevated run would do.
if ($WhatIfPreference) {
    Write-Information ""
    Write-Information "-WhatIf: skipping the elevation request. A real run needs Administrator (Windows) or sudo (macOS / Ubuntu)."
} elseif ($IsWindows) {
    if (-not (Test-IsElevated)) {
        Write-Information ""
        Write-Information "Creating a local OS account requires Administrator rights on Windows."
        Write-Information "  account : $AccountName ($FullName)"
        Write-Information "  admin   : $(if ($Admin) { 'yes -- will join the built-in Administrators group' } else { 'no' })"
        Write-Information ""
        if (-not (Confirm-Step "Relaunch this script elevated")) {
            Write-Information "Cancelled. Nothing was changed."
            return
        }
        Invoke-SelfElevation -WantsPassword $WantsPassword
        return
    }
} elseif ($IsMacOS -or $IsLinux) {
    if (-not (Get-Command sudo -ErrorAction SilentlyContinue)) {
        throw "sudo not found on PATH. macOS / Ubuntu: sudo is required to create a local user."
    }
    # Pre-authenticate sudo so the operator sees a single, clearly-labeled
    # prompt for THEIR OWN login password rather than a scattering of
    # prompts between the account, group, and password steps below.
    # Subsequent `sudo` calls reuse the cached credential.
    $invokingUser = $env:USER
    if ([string]::IsNullOrWhiteSpace($invokingUser)) { $invokingUser = & id -un }
    Write-Information ""
    Write-Information "About to create a new local OS user via sudo."
    Write-Information "  account : $AccountName ($FullName)"
    Write-Information "  admin   : $(if ($Admin) { 'yes' } else { 'no' })"
    Write-Information ""
    Write-Information "sudo will prompt for YOUR login password ($invokingUser) -- NOT the"
    Write-Information "password for the new account."
    Write-Information ""
    if (-not (Confirm-Step "Proceed")) {
        Write-Information "Cancelled. Nothing was changed."
        return
    }
    & sudo -v
    if ($LASTEXITCODE -ne 0) {
        throw "sudo authentication failed (exit $LASTEXITCODE). Make sure $invokingUser is an admin (dseditgroup -o checkmember -m $invokingUser admin) and re-run."
    }
} else {
    throw "Unsupported OS. This script supports Windows, macOS, and Ubuntu."
}

# --- REGION: Pre-flight: does the OS account already exist?
function Test-OsUser {
    param([string]$Name)
    if ($IsWindows) {
        return [bool](Get-LocalUser -Name $Name -ErrorAction SilentlyContinue)
    }
    # macOS / Ubuntu: `id` exits 0 iff the user exists.
    & id $Name *> $null
    return ($LASTEXITCODE -eq 0)
}

if (Test-OsUser -Name $AccountName) {
    throw "OS account '$AccountName' already exists on this host. New-LocalTestUser refuses to modify existing accounts."
}

# --- REGION: Pre-flight: does users.yml already declare this name?
function Get-DeclaredUserNameFromText {
    <#
        Entry names as the file physically stores them: two-space-indented
        keys inside the top-level `users:` mapping. This is the no-YAML path,
        so it reads only the shape this script and users.yml.template write --
        column-0 keys end the mapping, and a commented-out example (`  # x:`)
        is not an entry.
    #>
    param([string[]]$Lines)

    $names   = New-Object System.Collections.Generic.List[string]
    $inUsers = $false
    foreach ($line in $Lines) {
        if (-not $inUsers) {
            if ($line -match '^users:\s*(#.*)?$') { $inUsers = $true }
            continue
        }
        if ($line -match '^\S') { break }
        if ($line -match '^\s{2}(?<name>[A-Za-z_][A-Za-z0-9._-]*):\s*(#.*)?$') {
            $null = $names.Add($Matches['name'])
        }
    }
    return $names
}

function Test-YurunaUserDeclared {
    param([string]$Name, [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if (-not $YamlAvailable) {
        return (@(Get-DeclaredUserNameFromText -Lines (Get-Content -LiteralPath $Path)) -contains $Name)
    }
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

# --- REGION: Resolve the password
# Asked here, once, and only once: past the elevation gate (so the UAC
# relaunch does not re-ask) and past the pre-flight checks (so nobody types
# a secret for an account the next line would refuse). Under -WhatIf nothing
# is created, so there is nothing to protect and no reason to prompt.
if ($WantsPassword -and [string]::IsNullOrEmpty($Password) -and -not $WhatIfPreference) {
    $Password = Read-NewPassword -Name $AccountName
}
$HasPassword = -not [string]::IsNullOrEmpty($Password)

# macOS sets the password through sysadminctl's argument vector, and
# sysadminctl has no "--" end-of-options marker: a leading "-" would be
# consumed as an option and the account would be created with a different
# credential than the operator believes. Refuse instead of silently
# producing an account nobody can log into.
if ($IsMacOS -and $HasPassword -and $Password.StartsWith('-')) {
    throw "On macOS the password may not begin with '-' (sysadminctl would parse it as an option). Choose a password with a different leading character."
}

# --- REGION: Create the OS account
function New-WindowsLocalUser {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name, [string]$Display, [string]$Secret, [bool]$ForceChange, [bool]$AsAdmin)

    $what = if ($Secret) { 'with password' } else { 'no password' }
    if (-not $PSCmdlet.ShouldProcess($Name, "New-LocalUser ($what, FullName='$Display')")) { return }

    $common = @{ Name = $Name; FullName = $Display; Description = 'Yuruna local test user'; ErrorAction = 'Stop' }
    if ($Secret) {
        # New-LocalUser only accepts a SecureString, so the password never
        # reaches a command line here.
        $secure = ConvertTo-SecureString -String $Secret -AsPlainText -Force
        $null = New-LocalUser @common -Password $secure
    } else {
        $null = New-LocalUser @common -NoPassword
    }

    if ($ForceChange) {
        # PasswordExpired forces a change at the first interactive login.
        # ADSI works on PS 7 Windows and writes the same flag
        # `net user X /logonpasswordchg:yes` sets.
        try {
            $user = [adsi]"WinNT://./${Name},user"
            $user.PasswordExpired = 1
            $user.SetInfo()
        } catch {
            Write-Warning "Could not set PasswordExpired flag via ADSI: $($_.Exception.Message)"
            Write-Warning "Set it manually with:  net user $Name /logonpasswordchg:yes"
        }
    }

    if ($AsAdmin) {
        # Resolve the built-in Administrators group by its well-known SID:
        # its NAME is localized (Administradores, Administrateurs, ...) and
        # hardcoding the English string breaks on non-English installs.
        $adminGroup = Get-LocalGroup | Where-Object { $_.SID.Value -eq 'S-1-5-32-544' } | Select-Object -First 1
        if (-not $adminGroup) {
            throw "Could not resolve the built-in Administrators group (SID S-1-5-32-544) on this host."
        }
        Add-LocalGroupMember -Group $adminGroup.Name -Member $Name -ErrorAction Stop
        # Get-LocalGroupMember fails to enumerate a group that still holds a
        # SID no longer resolvable to a principal (a deleted domain account,
        # a removed local user). Add-LocalGroupMember above already throws on
        # a real failure, so an unreadable group is a verification gap, not a
        # failed grant -- say so instead of aborting a successful run.
        # $null means "could not enumerate", which is distinct from $false
        # ("enumerated, and the account is not there") -- only the latter is
        # an actual failed grant.
        $isMember = $null
        try {
            $members  = @(Get-LocalGroupMember -Group $adminGroup.Name -ErrorAction Stop)
            $isMember = [bool]($members | Where-Object { $_.Name -eq $Name -or $_.Name -like "*\$Name" })
        } catch {
            Write-Warning "Could not enumerate '$($adminGroup.Name)' to verify membership: $($_.Exception.Message)"
            Write-Warning "Verify manually with:  net localgroup `"$($adminGroup.Name)`""
        }
        if ($false -eq $isMember) {
            throw "Added '$Name' to '$($adminGroup.Name)' but the membership did not verify."
        }
    }
}

function New-MacLocalUser {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name, [string]$Display, [string]$Secret, [bool]$ForceChange, [bool]$AsAdmin)

    $what = if ($Secret) { 'with password' } else { 'no password' }
    if (-not $PSCmdlet.ShouldProcess($Name, "sudo sysadminctl -addUser ($what, fullName='$Display')")) { return }

    $addArgs = @('sysadminctl', '-addUser', $Name, '-fullName', $Display)
    if ($Secret)  { $addArgs += @('-password', $Secret) }
    if ($AsAdmin) { $addArgs += '-admin' }
    $out = & sudo @addArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "sysadminctl -addUser exited $LASTEXITCODE`: $out"
    }

    if ($AsAdmin) {
        # Not every macOS release honors -admin at creation time, so confirm
        # the membership and repair it rather than trusting the exit code.
        & dseditgroup -o checkmember -m $Name admin *> $null
        if ($LASTEXITCODE -ne 0) {
            $out = & sudo dseditgroup -o edit -a $Name -t user admin 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Could not add '$Name' to the admin group (exit $LASTEXITCODE): $out"
            }
            & dseditgroup -o checkmember -m $Name admin *> $null
            if ($LASTEXITCODE -ne 0) {
                throw "Added '$Name' to the admin group but the membership did not verify."
            }
        }
    }

    if ($Secret) {
        # Confirm the credential actually took. A silently-mangled password
        # produces an account that exists but cannot log in, which is far
        # more expensive to diagnose after the fact than here.
        & sudo dscl . -authonly $Name $Secret *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Created '$Name' but could not verify the password with 'dscl . -authonly'."
            Write-Warning "Verify manually, and reset if needed with:  sudo sysadminctl -resetPasswordFor $Name -newPassword <password>"
        }
    }

    if ($ForceChange) {
        # newPasswordRequired=1 forces a password change on the next login.
        $out = & sudo pwpolicy -u $Name -setpolicy "newPasswordRequired=1" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "pwpolicy newPasswordRequired=1 failed (exit $LASTEXITCODE): $out"
            Write-Warning "Set it manually with:  sudo pwpolicy -u $Name -setpolicy 'newPasswordRequired=1'"
        }
    }
}

function New-LinuxLocalUser {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name, [string]$Display, [string]$Secret, [bool]$ForceChange, [bool]$AsAdmin)

    $what = if ($Secret) { 'with password' } else { 'locked password' }
    if (-not $PSCmdlet.ShouldProcess($Name, "sudo useradd ($what, GECOS='$Display')")) { return }

    # Without -p the password is locked (`!` in /etc/shadow). -m creates the
    # home dir; -s sets a sane default login shell.
    $out = & sudo useradd -c $Display -m -s /bin/bash $Name 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "useradd exited $LASTEXITCODE`: $out"
    }

    if ($Secret) {
        # chpasswd reads `user:password` from stdin, so the plaintext never
        # enters an argument vector and a leading '-' cannot be mistaken for
        # an option. See docs/vmconfig.md for the trap class.
        $out = "${Name}:${Secret}" | & sudo chpasswd 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "chpasswd exited $LASTEXITCODE`: $out"
        }
    }

    if ($AsAdmin) {
        # Ubuntu grants machine administration through the `sudo` group;
        # `wheel` is the equivalent on the RHEL-family layout.
        $adminGroup = $null
        foreach ($g in @('sudo', 'wheel')) {
            & getent group $g *> $null
            if ($LASTEXITCODE -eq 0) { $adminGroup = $g; break }
        }
        if (-not $adminGroup) {
            throw "Neither a 'sudo' nor a 'wheel' group exists on this host; cannot grant administrator rights to '$Name'."
        }
        $out = & sudo usermod -aG $adminGroup $Name 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "usermod -aG $adminGroup exited $LASTEXITCODE`: $out"
        }
        $groups = (& id -nG $Name) -split '\s+'
        if ($groups -notcontains $adminGroup) {
            throw "Added '$Name' to '$adminGroup' but the membership did not verify."
        }
    }

    if ($ForceChange) {
        # chage -d 0 forces a password change on the next login.
        $out = & sudo chage -d 0 $Name 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "chage -d 0 failed (exit $LASTEXITCODE): $out"
            Write-Warning "Set it manually with:  sudo chage -d 0 $Name"
        }
    }
}

Write-Information ""
Write-Information "Creating local OS user '$AccountName' ($FullName) ..."
$osArgs = @{
    Name        = $AccountName
    Display     = $FullName
    Secret      = $Password
    ForceChange = $ShouldForceChange
    AsAdmin     = $Admin.IsPresent
}
if     ($IsWindows) { New-WindowsLocalUser @osArgs }
elseif ($IsMacOS)   { New-MacLocalUser     @osArgs }
elseif ($IsLinux)   { New-LinuxLocalUser   @osArgs }

# --- REGION: Append to users.yml (runtime + template)
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
    # Re-read to confirm the new entry is reachable; rollback if not. With
    # powershell-yaml this also proves the whole file still parses as YAML,
    # which the text scan cannot establish -- the scan only proves the entry
    # landed in the shape it was written.
    try {
        if ($YamlAvailable) {
            $cfg = Get-Content -Raw -LiteralPath $p | ConvertFrom-Yaml -Ordered -ErrorAction Stop
            if ($null -eq $cfg.users -or -not $cfg.users.Contains($AccountName)) {
                throw "Post-write parse did not surface the new entry."
            }
        } elseif (@(Get-DeclaredUserNameFromText -Lines (Get-Content -LiteralPath $p)) -notcontains $AccountName) {
            throw "Post-write scan did not surface the new entry."
        }
    } catch {
        throw "Wrote '$AccountName' to $p but post-write verification failed: $($_.Exception.Message). Restore the file from git or your editor's undo, then re-run."
    }
    $null = $wrote.Add($p)
}

# --- REGION: Inform the operator
$banner  = if ($WhatIfPreference) { 'Local test user WOULD BE created' } else { 'Local test user created' }
$heading = if ($WhatIfPreference) { 'What a real run would leave behind:' } else { 'Action items + state:' }
Write-Information ""
Write-Information "=========================================================="
Write-Information "  ${banner}: $AccountName ($FullName)"
Write-Information "=========================================================="
Write-Information ""
Write-Information $heading
Write-Information ""

$step = 1
if ($HasPassword -or ($WhatIfPreference -and $WantsPassword)) {
    if ($WhatIfPreference) {
        Write-Information "  $step. A real run would ask for the password and set it as usable."
    } else {
        Write-Information "  $step. The password is set and usable."
    }
    if (-not $ShouldForceChange) {
        Write-Information "     The account can log in unattended -- no first-login rotation."
    }
    Write-Information "     Do not leave it in open text files or shell history."
} else {
    Write-Information "  $step. The initial password for '$AccountName' HAS NOT been set."
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
}
Write-Information ""
$step++

if ($Admin) {
    Write-Information "  $step. The account IS a local machine administrator:"
    if ($IsWindows) {
        Write-Information "     member of the built-in Administrators group (S-1-5-32-544)."
    } elseif ($IsMacOS) {
        Write-Information "     member of the 'admin' group; sudo works after first login."
    } elseif ($IsLinux) {
        Write-Information "     member of the 'sudo' group. Group membership is read at login,"
        Write-Information "     so it takes effect on the account's next sign-in."
    }
    Write-Information ""
    $step++
}

if ($ShouldForceChange) {
    Write-Information "  $step. The account is flagged 'must change password at first login':"
    if ($IsWindows) {
        Write-Information "     PasswordExpired=1 via ADSI; the first interactive sign-in"
        Write-Information "     will prompt for a new password."
    } elseif ($IsMacOS) {
        Write-Information "     pwpolicy newPasswordRequired=1; the first login will prompt"
        Write-Information "     for a new password."
    } elseif ($IsLinux) {
        Write-Information "     chage -d 0 forces a password change on the next login."
    }
    Write-Information ""
    $step++
}

if ($wrote.Count -gt 0) {
    Write-Information "  $step. Added to the default Yuruna authentication extension:"
    foreach ($p in $wrote) { Write-Information "       $p" }
    Write-Information "     corporate.* / vaultKey / localOsPasswordRef are empty --"
    Write-Information "     the account is registered as a purely-local Yuruna user,"
    Write-Information "     NOT yet bound to any corporate (AD / Entra / etc.) identity."
    Write-Information "     See test/extension/authentication/users.yml.template for how"
    Write-Information "     to bind a vault key / corporate identity later."
    if (-not $YamlAvailable) {
        Write-Information "     The entry was confirmed by text scan; install powershell-yaml"
        Write-Information "     to have the whole file re-validated as YAML on future runs."
    }
}
if ($wrote.Count -eq 1 -and $wrote[0] -eq $UsersTemplate) {
    Write-Information ""
    Write-Information "     Note: only the committed template was updated; the runtime"
    Write-Information "     users.yml does not yet exist on this host. The default"
    Write-Information "     authentication extension bootstraps it from the template on"
    Write-Information "     first use, so no further action is needed."
}
Write-Information ""
