<#PSScriptInfo
.VERSION 2026.09.18
.GUID 4271255a-d0dd-4c45-8932-15f35ae51cf4
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

    When the authentication vault already holds a local-OS password for
    this account name, that password is reused instead of asking, so a
    re-created account still matches the credential Yuruna hands out for
    it. -Password overrides the stored one; -PromptForPassword asks
    anyway, and warns that the stored copy stops matching.

    -ForcePasswordChange makes the password a one-shot initial credential
    and demands a change at the first interactive login. It is opt-in --
    without it the account logs in unattended.

    -Admin additionally makes the account a local machine administrator:
    the built-in Administrators group on Windows (resolved by SID, so it
    works on non-English installs), the `admin` group on macOS, and the
    `sudo` group on Ubuntu.

    On Windows the account is also left able to run scripts: its CurrentUser
    execution policy is set to RemoteSigned. That policy lives in the
    account's own profile, so it is set from a session that runs as the new
    account -- a one-shot logon here when the password is usable, and a
    first-sign-in scheduled task when -NoPassword or -ForcePasswordChange
    rules a logon out.

    The same logical account name is registered in the runtime
    authentication mapping, status/extension/authentication/users.yml,
    with empty corporate / vault fields so the entry behaves as a
    purely-local Yuruna user (cf.
    test/extension/authentication/users.yml.template). A host whose
    runtime file does not exist yet gets one seeded from the committed
    template first; the template itself is never written to, so
    registering a machine-local account never dirties a tracked file.

    A name already declared in users.yml is reused, not refused: the
    entry stays exactly as it is, along with whatever vault credential
    it points at, and the run continues. An OS account that already
    exists is not a stop either: the run reports what deleting it takes
    with it and asks to confirm, then deletes the account -- home
    directory and everything under it -- and creates it again from
    scratch. -Force answers that confirmation in advance, which is what
    lets an unattended run recreate the account in one call. Three cases
    are refused outright, -Force included: a system account, the account
    running the script, and an account with an open login session.

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
    Initial password for the new account. When omitted the script reuses
    the password the authentication vault already holds for this account
    if there is one, and otherwise asks interactively rather than leaving
    the account unusable; pass -NoPassword to skip the password entirely.

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
    it from -Password or from a vault entry that already exists for this
    account. Without it, an account whose vault password outlived the
    account itself is re-created with that same password.

.PARAMETER NoPassword
    Create the account without a usable password. It exists but cannot
    log in until the operator sets one out-of-band.

.PARAMETER Force
    Answer this script's own confirmation prompts in advance, so a run
    that would stop to ask completes unattended. That includes the
    consent to DELETE an OS account that already exists -- home
    directory and everything under it -- and recreate it with the
    password and group membership asked for. The operating system may
    still prompt (UAC consent, sudo password).

    Three cases are refused even with -Force: the account running the
    script, a system account (a built-in Windows principal, macOS
    UniqueID below 500, Linux UID below 1000), and an account with an
    open login session.

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

.EXAMPLE
    .\New-LocalTestUser.ps1 -Admin -Force
    # Re-create the default test account without stopping to ask: an
    # existing `yurunatest` OS account and its home directory are deleted
    # first, while the Yuruna users.yml entry and any vault password it
    # points at are reused. The same run without -Force does the same
    # thing, after confirming the deletion with the operator. Add -WhatIf
    # the first time to see exactly what would be removed.

.NOTES
    Requires Administrator (Windows) or sudo (macOS / Ubuntu).

    powershell-yaml is optional. It is used only to parse and re-validate
    users.yml and to peek at the vault; creating the OS account never
    needs it, so a freshly imaged host can run this before any module is
    installed. Without it the users.yml duplicate check and post-write
    confirmation fall back to a text scan of the two-space entry shape the
    file is written in, and a stored vault password cannot be reused --
    the run asks for a password instead.

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

Import-Module (Join-Path $PSScriptRoot '../automation/Yuruna.Globalization.psm1') -DisableNameChecking
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
    $first = Read-Host -Prompt (Format-YurunaOperatorMessage -Key 'runner.operator_e0b33e122bc96ca1' -Arguments @{ name = "$Name" }) -AsSecureString
    $again = Read-Host -Prompt (Format-YurunaOperatorMessage -Key 'runner.operator_0dfb80d85bdca638') -AsSecureString
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
# The template is read-only here: it is the seed for a host with no runtime
# mapping yet, and a place to read an existing declaration from. Every write
# goes to the gitignored runtime file, so registering a machine-local account
# never turns up in `git status`.
$TestRoot      = $PSScriptRoot
$UsersTemplate = Join-Path $TestRoot 'extension/authentication/users.yml.template'
$UsersRuntime  = Join-Path $TestRoot 'status/extension/authentication/users.yml'
$VaultPath     = Join-Path $TestRoot 'status/extension/authentication/vault.yml'

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
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_5c6a1d8c5466eae1' -Arguments @{ message = "$($_.Exception.Message)" })
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_1b7841e3289bf783')
        $YamlAvailable = $false
    } finally {
        $WhatIfPreference = $PreviousWhatIf
    }
} else {
    Write-Information ""
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_13c098483d4f4c49')
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_6db2729f4ace52e7')
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_96c44416adfc3cc0')
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
    # -PromptForPassword is forwarded only when the operator asked for it: it
    # also means "do not reuse a stored vault password", and the elevated
    # window prompts by default anyway once no password reaches it.
    if (-not $WantsPassword)    { $argList += '-NoPassword' }
    elseif ($PromptForPassword) { $argList += '-PromptForPassword' }

    Write-Information ""
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_213409dfa7d92529')
    if ($WantsPassword) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_82526458a1a29a27' -Arguments @{ accountName = "$AccountName" })
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_4c9eae1b8e30960e')
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_588a227ff4f65891')
    Write-Information ""
    Start-Process -FilePath $shellExe -Verb RunAs -ArgumentList $argList
}

# -WhatIf is a dry run: it must not raise a UAC prompt or spend a sudo
# authentication, so the whole gate is skipped and the ShouldProcess
# messages below describe what an elevated run would do.
if ($WhatIfPreference) {
    Write-Information ""
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_85f773939904ad98')
} elseif ($IsWindows) {
    if (-not (Test-IsElevated)) {
        Write-Information ""
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_03f133aca57bd2cb')
        Write-Information "  account : $AccountName ($FullName)"
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_77d9db5835dcc034' -Arguments @{ no = "$(if ($Admin) { 'yes -- will join the built-in Administrators group' } else { 'no' })" })
        Write-Information ""
        if (-not (Confirm-Step "Relaunch this script elevated")) {
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_04265e41f16edc05')
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
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_8b08b414d23d6def')
    Write-Information "  account : $AccountName ($FullName)"
    Write-Information "  admin   : $(if ($Admin) { 'yes' } else { 'no' })"
    Write-Information ""
    Write-Information "sudo will prompt for YOUR login password ($invokingUser) -- NOT the"
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_c1b596d7a4419ab5')
    Write-Information ""
    if (-not (Confirm-Step "Proceed")) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_04265e41f16edc05')
        return
    }
    & sudo -v
    if ($LASTEXITCODE -ne 0) {
        # The check to suggest is OS-specific: dseditgroup does not exist on Ubuntu.
        $checkHint = if ($IsMacOS) {
            "dseditgroup -o checkmember -m $invokingUser admin"
        } else {
            "id -nG | tr ' ' '\n' | grep -qxE 'sudo|wheel'"
        }
        throw "sudo authentication failed (exit $LASTEXITCODE). Confirm $invokingUser can elevate ($checkHint) and re-run. A session opened before the group was granted keeps the group list it started with, so sign out and back in first."
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

function Get-OsUserFact {
    <#
        What deleting the account would take with it, plus the two
        properties that decide whether it may be deleted at all. A numeric
        id below the platform's first-real-user boundary marks a principal
        whose removal breaks the host rather than resetting a test account:
        Windows built-ins sit at RID < 1000 (Administrator 500, Guest 501,
        DefaultAccount 503), macOS service accounts below UniqueID 500,
        Linux system accounts below UID 1000.
    #>
    param([string]$Name)

    $fact = @{ Id = ''; Home = ''; IsSystem = $false; Active = $false }

    if ($IsWindows) {
        $account = Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
        if (-not $account) { return $fact }
        $fact.Id = $account.SID.Value
        if ($fact.Id -match '-(\d+)$' -and [int]$Matches[1] -lt 1000) { $fact.IsSystem = $true }
        $stored = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$($fact.Id)'" -ErrorAction SilentlyContinue
        if ($stored) {
            $fact.Home   = [string]$stored.LocalPath
            $fact.Active = [bool]$stored.Loaded
        }
        return $fact
    }

    $uid = & id -u $Name 2>$null
    if ($LASTEXITCODE -eq 0 -and "$uid" -match '^\d+$') {
        $fact.Id       = "$uid"
        $fact.IsSystem = ([int]"$uid" -lt $(if ($IsMacOS) { 500 } else { 1000 }))
    }
    if ($IsMacOS) {
        # `dscl . -read` prints "NFSHomeDirectory: /Users/x"; there is no
        # getent on macOS.
        $record = (& dscl . -read "/Users/$Name" NFSHomeDirectory 2>$null) -join ' '
        if ($record -match 'NFSHomeDirectory:\s*(?<home>\S.*)$') { $fact.Home = $Matches['home'].Trim() }
    } else {
        $record = (& getent passwd $Name 2>$null) -join ''
        if ($record) { $fact.Home = ($record -split ':')[5] }
    }
    # Deleting an account out from under a live session leaves that session
    # running against a uid and a home directory that no longer exist --
    # far harder to unpick than signing it out first.
    $fact.Active = [bool]@(@(& who 2>$null) | Where-Object { ($_ -split '\s+')[0] -eq $Name }).Count
    return $fact
}

function Remove-OsUserHome {
    <#
        Second pass over the home directory, because every platform's
        account delete has a way of leaving it behind: a Windows profile
        whose ProfileList entry is unreadable, `userdel` reporting exit 12,
        a macOS home with files still open in it. What survives is not
        cosmetic -- the recreated account cannot read files owned by an id
        that no longer resolves, and on Windows it is handed a second,
        `.000`-suffixed profile directory beside the old one.

        The path comes from the OS itself (Win32_UserProfile.LocalPath,
        the passwd record, dscl), never from the account name, so this
        removes the directory the account really had.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path))  { return }
    # A path at or beside the filesystem root is a damaged account record
    # rather than a home directory -- '/', '/home' and C:\Users hold every
    # other account's files, and a recursive delete of one of those is not
    # recoverable. DirectoryInfo rather than Split-Path: Split-Path errors
    # on a root path instead of returning nothing, and the error abandons
    # the statement that was supposed to be the guard. Anything the check
    # cannot resolve is refused for the same reason.
    $parent = $null
    try { $parent = ([System.IO.DirectoryInfo]::new($Path)).Parent } catch { $parent = $null }
    if ($null -eq $parent -or $null -eq $parent.Parent) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_140e197d642a7f7b' -Arguments @{ path = "$Path" })
        return
    }
    if (-not $PSCmdlet.ShouldProcess($Path, (Format-YurunaOperatorMessage -Key 'runner.operator_fb1f33b7473e1277'))) { return }

    try {
        if ($IsWindows) {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        } else {
            $out = & sudo rm -rf $Path 2>&1
            if ($LASTEXITCODE -ne 0) { throw "rm -rf exited $LASTEXITCODE`: $out" }
        }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_3ed0888647b78ffb' -Arguments @{ path = "$Path"; message = "$($_.Exception.Message)" })
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_66c59fb94122df6a')
        return
    }
    if (Test-Path -LiteralPath $Path) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d01c908b7e1943f2' -Arguments @{ path = "$Path" })
    } else {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_8439ce329c12c44a' -Arguments @{ path = "$Path" })
    }
}

function Remove-OsUser {
    <#
        Delete an existing account and its home directory, so the account
        recreated over it starts clean. A home directory left behind keeps
        the old owner's uid, which the new account cannot read and cannot
        be given without a recursive chown nobody asked for. Each platform's
        delete takes the directory with it; Remove-OsUserHome is what makes
        that true when it does not.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name, [hashtable]$Fact)

    $target = if ($Fact.Home) { "$Name (and $($Fact.Home))" } else { $Name }
    if (-not $PSCmdlet.ShouldProcess($target, (Format-YurunaOperatorMessage -Key 'runner.operator_80631a3ed310d88c'))) { return }

    if ($IsWindows) {
        Remove-LocalUser -Name $Name -ErrorAction Stop
        # Remove-LocalUser leaves the profile behind, and Windows then hands
        # a later account of the same name a `.000`-suffixed directory
        # instead of the old one. Deleting the profile instance removes the
        # directory and its ProfileList registry entry together, which a
        # plain Remove-Item does not.
        if ($Fact.Id) {
            try {
                $stored = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$($Fact.Id)'" -ErrorAction Stop
                if ($stored) { Remove-CimInstance -InputObject $stored -ErrorAction Stop }
            } catch {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_2b64497fe1d6bed5' -Arguments @{ id = "$($Fact.Id)"; message = "$($_.Exception.Message)" })
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_4b325ef891a8ed11')
            }
        }
    } elseif ($IsMacOS) {
        # -deleteUser takes the home directory with it; -keepHome would
        # leave it owned by a uid that no longer resolves.
        $out = & sudo sysadminctl -deleteUser $Name 2>&1
        $rc  = $LASTEXITCODE
        # sysadminctl reports some failures on stderr while still exiting 0,
        # so the account itself is the verification.
        if (Test-OsUser -Name $Name) {
            throw "sysadminctl -deleteUser did not remove '$Name' (exit $rc): $out"
        }
    } else {
        # -r takes the home directory and the mail spool with the account.
        $out = & sudo userdel -r $Name 2>&1
        $rc  = $LASTEXITCODE
        if ($rc -ne 0) {
            if (Test-OsUser -Name $Name) { throw "userdel -r exited $rc`: $out" }
            # Exit 12 is "account removed, home directory could not be": the
            # recreate still works, on a directory the sweep below clears.
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d3c149b79d6b0f5b' -Arguments @{ rc = "$rc"; name = "$Name"; out = "$out" })
        }
    }

    Remove-OsUserHome -Path $Fact.Home
}

$Recreated   = $false
$RemovedHome = ''

if (Test-OsUser -Name $AccountName) {
    $existing = Get-OsUserFact -Name $AccountName
    $homeNote = if ($existing.Home) { $existing.Home } else { 'not found' }

    $invokingAccount = if ($IsWindows) { $env:USERNAME } else { $env:USER }
    if ([string]::IsNullOrWhiteSpace($invokingAccount) -and -not $IsWindows) { $invokingAccount = & id -un }

    # The three refusals come before the question, and hold with -Force too:
    # none of them is an operator's to answer, and asking about a deletion
    # that will not happen trains the reader to say yes to a question that
    # decides nothing.
    if ($existing.IsSystem) {
        throw "OS account '$AccountName' is a system account (id $($existing.Id)); this script will not delete it, with or without -Force. Deleting it would break the host, not reset a test account. Choose a different -AccountName."
    }
    # Windows account names are case-insensitive; POSIX ones are not, so
    # `-ceq` there keeps a legitimately distinct name out of this guard.
    $isInvoker = if ($IsWindows) { $AccountName -eq $invokingAccount } else { $AccountName -ceq $invokingAccount }
    if ($isInvoker) {
        throw "'$AccountName' is the account running this script; it will not delete the account it is running as, with or without -Force. Re-run from another administrator account, or choose a different -AccountName."
    }
    if ($existing.Active) {
        throw "OS account '$AccountName' has an open login session. Sign every session of it out and re-run: deleting it now would leave that session pointing at a uid and a home directory that no longer exist."
    }

    # Recreating is the whole point of running this against a name that
    # already exists, so the run offers it rather than refusing and telling
    # the operator which switch to add. What it cannot do is decide on their
    # behalf: the account may be a stale test account or one in use, and only
    # the operator can tell which. -Force is that answer given in advance,
    # which is what makes an unattended recreate possible.
    $consentTarget = if ($existing.Home) { "'$AccountName' and $($existing.Home)" } else { "'$AccountName'" }
    Write-Information ""
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_42dcde04bb769692' -Arguments @{ accountName = "$AccountName"; homeNote = "$homeNote" })
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_11a27b5d651f84e3')
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_6121ef24c9e88198' -Arguments @{ accountName = "$AccountName" })
    if ($WhatIfPreference) {
        # A dry run has no consent to ask for -- it deletes nothing.
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_46cf3f3b25c7b1d5')
    } else {
        if ($Force) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_56d07230931cc37f')
        }
        if (-not (Confirm-Step "Delete $consentTarget and recreate the account")) {
            throw "Declined: '$AccountName' is untouched and nothing was created. Re-run with -Force to answer that confirmation in advance, or with a different -AccountName to leave this account alone."
        }
    }
    Remove-OsUser -Name $AccountName -Fact $existing
    $Recreated   = $true
    $RemovedHome = $existing.Home
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
        # A file too broken to parse is still readable as text, and the entry
        # shape this script writes is recognizable without a YAML parser. Say
        # what would fix it, and let -Force take the text-scan route rather
        # than blocking account creation on an unrelated edit elsewhere in
        # the file.
        if ($Force) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_84832aa8f31a6464' -Arguments @{ path = "$Path"; message = "$($_.Exception.Message)"; name = "$Name" })
            return (@(Get-DeclaredUserNameFromText -Lines (Get-Content -LiteralPath $Path)) -contains $Name)
        }
        throw "Could not parse $Path as YAML: $($_.Exception.Message). Fix the file (entries are two-space-indented keys under the top-level 'users:' mapping), or re-run with -Force to fall back to a text scan of it."
    }
    if ($null -eq $cfg -or $null -eq $cfg.users) { return $false }
    return $cfg.users.Contains($Name)
}

# A name already declared is a no-op, not a conflict: the entry holds no
# password of its own, and the vault key it points at is exactly what the
# rest of Yuruna already hands out for this user. Keep it, say so, and leave
# the file alone.
$DeclaredIn = @(foreach ($p in @($UsersRuntime, $UsersTemplate)) {
    if (Test-YurunaUserDeclared -Name $AccountName -Path $p) { $p }
})
$UsersEntryReused = ($DeclaredIn.Count -gt 0)
if ($UsersEntryReused) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_ab6c6159190ac7ff' -Arguments @{ accountName = "$AccountName"; and = "$($DeclaredIn -join ' and ')" })
    if ($DeclaredIn -notcontains $UsersRuntime) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_ad81b45f1712b9c6' -Arguments @{ usersRuntime = "$UsersRuntime" })
    }
}

# --- REGION: Resolve the password
# Resolved here, once, and only once: past the elevation gate (so the UAC
# relaunch does not re-ask) and past the pre-flight checks (so nobody types
# a secret for an account the run is about to refuse). Under -WhatIf nothing
# is created, so there is nothing to protect and no reason to prompt.
function Get-VaultLocalOsPassword {
    <#
        Read-only mirror of the extension's localOsPasswordRef indirection
        (extension/authentication/default.psm1, Get-LocalOsPassword): the
        vault key is the users.yml entry's localOsPasswordRef when it is
        populated, and the account's own name otherwise. Nothing is
        generated and nothing is written, so a missing entry simply means
        "nothing to reuse". Returns @{ Key; Password } or $null.
    #>
    param([string]$Name, [string]$UsersPath, [string]$Path)

    if (-not $YamlAvailable -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $key = $Name
    if ($UsersPath -and (Test-Path -LiteralPath $UsersPath)) {
        try {
            $cfg   = Get-Content -Raw -LiteralPath $UsersPath | ConvertFrom-Yaml -Ordered -ErrorAction Stop
            $entry = if ($cfg -and $cfg.users -and $cfg.users.Contains($Name)) { $cfg.users[$Name] } else { $null }
            if ($entry -is [System.Collections.IDictionary] -and $entry.Contains('localOsPasswordRef')) {
                $ref = "$($entry['localOsPasswordRef'])".Trim()
                if ($ref) { $key = $ref }
            }
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_94283e93422a2b2c' -Arguments @{ usersPath = "$UsersPath"; message = "$($_.Exception.Message)" })
        }
    }
    try {
        $vault = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Yaml -Ordered -ErrorAction Stop
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_905cb8b93b701fa9' -Arguments @{ path = "$Path"; message = "$($_.Exception.Message)" })
        return $null
    }
    if ($null -eq $vault -or $null -eq $vault.users -or -not $vault.users.Contains($key)) { return $null }
    $stored = "$($vault.users[$key].password)"
    if ([string]::IsNullOrEmpty($stored)) { return $null }
    return @{ Key = $key; Password = $stored }
}

# The vault outlives the OS account: deleting the account leaves its stored
# password behind, so an account recreated with a freshly typed one leaves
# every Yuruna consumer handing out a credential the host no longer accepts.
# Reuse the stored password by default, and when something overrides it, say
# plainly that the two have parted ways.
$usersForKey       = if (Test-Path -LiteralPath $UsersRuntime) { $UsersRuntime } else { $UsersTemplate }
$StoredCredential  = Get-VaultLocalOsPassword -Name $AccountName -UsersPath $usersForKey -Path $VaultPath
$PasswordFromVault = $false
$ReuseStored       = $false

if ($WantsPassword -and [string]::IsNullOrEmpty($Password)) {
    $ReuseStored = ($null -ne $StoredCredential -and -not $PromptForPassword)
    if ($WhatIfPreference) {
        $source = if ($ReuseStored) { "reuse the password stored in the vault under key '$($StoredCredential.Key)'" } else { 'ask for a password' }
        Write-Information ""
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_90f1184615501062' -Arguments @{ source = "$source" })
    } elseif ($ReuseStored) {
        $Password          = $StoredCredential.Password
        $PasswordFromVault = $true
        Write-Information ""
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_adcbeaf50ba5d167' -Arguments @{ accountName = "$AccountName" })
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_0f5a8f43e49a6d8b' -Arguments @{ key = "$($StoredCredential.Key)" })
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_fc8ff78e8d43540a')
    } else {
        if ($StoredCredential) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_0486223c9c2a3ea4' -Arguments @{ accountName = "$AccountName"; key = "$($StoredCredential.Key)"; vaultPath = "$VaultPath" })
        }
        $Password = Read-NewPassword -Name $AccountName
    }
}
$HasPassword = -not [string]::IsNullOrEmpty($Password)

if ($StoredCredential -and $HasPassword -and -not $PasswordFromVault -and $Password -ne $StoredCredential.Password) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_3897cb6768db5aa5' -Arguments @{ accountName = "$AccountName"; key = "$($StoredCredential.Key)"; vaultPath = "$VaultPath" })
}
if ($StoredCredential -and $NoPassword) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_837a0a153498d90e' -Arguments @{ accountName = "$AccountName"; key = "$($StoredCredential.Key)" })
}

# macOS sets the password through sysadminctl's argument vector, and
# sysadminctl has no "--" end-of-options marker: a leading "-" would be
# consumed as an option and the account would be created with a different
# credential than the operator believes. Refuse instead of silently
# producing an account nobody can log into.
if ($IsMacOS -and $HasPassword -and $Password.StartsWith('-')) {
    if ($PasswordFromVault) {
        throw "On macOS the password may not begin with '-' (sysadminctl would parse it as an option), and the password stored in the vault under key '$($StoredCredential.Key)' does. Rotate that entry in $VaultPath to a value that does not start with '-', or pass -PromptForPassword to set a different one on the account."
    }
    throw "On macOS the password may not begin with '-' (sysadminctl would parse it as an option). Choose a password with a different leading character."
}

# --- REGION: Create the OS account
function New-WindowsLocalUser {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name, [string]$Display, [string]$Secret, [bool]$ForceChange, [bool]$AsAdmin)

    $what = if ($Secret) { 'with password' } else { 'no password' }
    if (-not $PSCmdlet.ShouldProcess($Name, "New-LocalUser ($what, FullName='$Display')")) { return }

    $common = @{ Name = $Name; FullName = $Display; Description = (Format-YurunaOperatorMessage -Key 'runner.operator_b1e68dfd3e1dc85c'); ErrorAction = 'Stop' }
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
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_8330193335bf15c6' -Arguments @{ message = "$($_.Exception.Message)" })
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_dc4be49860381c3d' -Arguments @{ name = "$Name" })
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
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_aaa6a4a2c37b1716' -Arguments @{ name = "$($adminGroup.Name)"; message = "$($_.Exception.Message)" })
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_68de40e1de70dffb' -Arguments @{ name = "$($adminGroup.Name)" })
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
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_2c1e0d4c810e5b32' -Arguments @{ name = "$Name" })
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_200a7d32aba9bfdf' -Arguments @{ name = "$Name" })
        }
    }

    if ($ForceChange) {
        # newPasswordRequired=1 forces a password change on the next login.
        $out = & sudo pwpolicy -u $Name -setpolicy "newPasswordRequired=1" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_f47e5116da805733' -Arguments @{ lASTEXITCODE = "$LASTEXITCODE"; out = "$out" })
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_7b20400706381dc6' -Arguments @{ name = "$Name" })
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
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_448fe7d7e7ace692' -Arguments @{ name = "$Name" })
        }
    }
}

Write-Information ""
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_3f8083a9bb99b964' -Arguments @{ accountName = "$AccountName"; fullName = "$FullName" })
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

# --- REGION: Let the new Windows account run scripts
# A fresh Windows account starts at the shell default -- Restricted on
# client SKUs -- so the first .ps1 the operator runs interactively as this
# account is refused. The CurrentUser policy lives inside the account's own
# profile (PowerShell 7 keeps it in
# Documents\PowerShell\powershell.config.json, Windows PowerShell 5.1 in
# HKCU), and neither store exists until the account has signed in once:
# setting it from this elevated session would only change the policy of the
# operator running the script. So it is set from a session that really runs
# as the new account -- a one-shot logon here when the account has a usable
# password, and a first-sign-in scheduled task when it does not.
#
# Framework entry points do not depend on this: they all launch with
# -ExecutionPolicy Bypass. It is the account's own interactive sessions
# that are otherwise refused.

# The read-back is the verdict: `exit 3` says the write did not land. The
# closing `exit 0` is what keeps a successful run from reading as a failure
# -- a PowerShell host returns 1 whenever anything reached the error stream,
# and Set-ExecutionPolicy writes an error record when a Group Policy already
# outranks the scope it just wrote to, which is not this script's problem.
$PolicyCommand = "Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force; if ((Get-ExecutionPolicy -Scope CurrentUser) -ne 'RemoteSigned') { exit 3 }; exit 0"

# Named after the account so a host can carry one per test account, and so a
# run that reaches the policy by logon can clear a task an earlier run left.
$PolicyTaskName = "YurunaExecutionPolicy-$AccountName"

function ConvertTo-EncodedCommand {
    <#
        -EncodedCommand rather than -Command: the payload becomes a single
        argument with no spaces or quotes in it, which both Start-Process
        and the Task Scheduler's flat argument string carry through
        unchanged. A -Command string has to survive their re-quoting, and
        a command with quotes in it does not.
    #>
    [OutputType([string])]
    param([string]$Command)
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
}

function Test-PathUnderDirectory {
    [OutputType([bool])]
    param([string]$Path, [string]$Directory)

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Directory)) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $root = [System.IO.Path]::GetFullPath($Directory).TrimEnd([System.IO.Path]::DirectorySeparatorChar) +
                [System.IO.Path]::DirectorySeparatorChar
    } catch {
        return $false
    }
    return $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-WindowsShellCandidate {
    <#
        One entry per host -- the CurrentUser policy is stored per host, so
        setting one leaves the other at its default -- and whether the new
        account can execute it at all.

        A PowerShell installed for a single user lives under that user's
        profile: a per-user MSI under AppData\Local\Programs, or a Store
        execution alias under AppData\Local\Microsoft\WindowsApps. No other
        account can run it. Handing such a path to a logon as the new
        account fails with "Access is denied" before the command starts,
        and a scheduled task pointed at the same path fails the same way at
        that account's own sign-in -- so a path under a profile is reported
        to the operator, never used.
    #>
    [OutputType([hashtable[]])]
    param()

    # Every account's profile lives under this root, including the profile
    # of the operator running the script, so an executable under it belongs
    # to one account rather than to the machine.
    $profileRoot = Split-Path -Parent $env:USERPROFILE
    $found       = New-Object System.Collections.Generic.List[hashtable]

    foreach ($exe in @('pwsh.exe', 'powershell.exe')) {
        $paths  = New-Object System.Collections.Generic.List[string]
        $onPath = Get-Command -Name $exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($onPath) { $null = $paths.Add($onPath.Source) }
        if ($exe -eq 'pwsh.exe') {
            # A machine-wide 7 that PATH does not reach yet -- installed in
            # this same session, or reached by full path -- is still the one
            # the new account can run, so look where the MSI puts it.
            foreach ($programs in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
                if ($programs) { $null = $paths.Add((Join-Path $programs 'PowerShell\7\pwsh.exe')) }
            }
            # This process is a pwsh (`#requires -version 7`), and it may be
            # the only one this operator has.
            $self = $null
            try { $self = (Get-Process -Id $PID).Path } catch { $self = $null }
            if ($self) { $null = $paths.Add($self) }
        }

        # First usable path wins; an unusable one is remembered only if no
        # usable path for the same host turns up after it.
        $pick = $null
        foreach ($candidate in $paths) {
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            if (-not (Test-PathUnderDirectory -Path $candidate -Directory $profileRoot)) {
                $pick = @{ Leaf = $exe; Path = $candidate; Usable = $true }
                break
            }
            if (-not $pick) { $pick = @{ Leaf = $exe; Path = $candidate; Usable = $false } }
        }
        if ($pick) { $null = $found.Add($pick) }
    }
    return $found.ToArray()
}

function Set-WindowsUserExecutionPolicy {
    <#
        Log the account on once, right here, and let it set its own policy.
        The logon is what creates the profile and loads the account's hive,
        so both stores are written where the account will read them from.
        Returns the hosts whose policy is confirmed set.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string[]])]
    param([string]$Name, [string]$Secret, [string]$Command, [hashtable[]]$Shell)

    $applied = New-Object System.Collections.Generic.List[string]
    if (-not $PSCmdlet.ShouldProcess($Name, (Format-YurunaOperatorMessage -Key 'runner.operator_0622a4d0730acf6c'))) {
        return $applied.ToArray()
    }

    # ".\" pins the logon to this machine: an unqualified name lets a
    # same-named domain account answer first on a joined host.
    $cred    = [pscredential]::new(".\$Name", (ConvertTo-SecureString -String $Secret -AsPlainText -Force))
    $encoded = ConvertTo-EncodedCommand -Command $Command

    foreach ($entry in $Shell) {
        # -WindowStyle, not -NoNewWindow: -Credential belongs to a parameter
        # set that has no -NoNewWindow.
        # -WorkingDirectory: without it the child inherits the caller's
        # directory, and an elevated operator's directory is regularly one
        # the new account cannot read -- which fails the launch itself,
        # before any of the command runs.
        $launch = @{
            FilePath         = $entry.Path
            Credential       = $cred
            WorkingDirectory = $env:SystemRoot
            ArgumentList     = @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded)
            WindowStyle      = 'Hidden'
            Wait             = $true
            PassThru         = $true
            ErrorAction      = 'Stop'
        }
        $errorLog = Join-Path ([System.IO.Path]::GetTempPath()) "yuruna-execpolicy-$($entry.Leaf)-$PID.log"
        $proc     = $null
        try {
            $proc = Start-Process @launch -RedirectStandardError $errorLog
        } catch {
            # The redirect is a diagnostic, not the job. A host that refuses
            # the redirected handle still gets its policy set, just without
            # the child's own words if it fails.
            $errorLog = ''
            try {
                $proc = Start-Process @launch
            } catch {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_6526abeb32709165' -Arguments @{ leaf = "$($entry.Leaf)"; name = "$Name"; message = "$($_.Exception.Message)" })
                continue
            }
        }

        $said = ''
        if ($errorLog -and (Test-Path -LiteralPath $errorLog)) {
            $said = @(Get-Content -LiteralPath $errorLog -ErrorAction SilentlyContinue |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[0]
            Remove-Item -LiteralPath $errorLog -Force -ErrorAction SilentlyContinue
        }

        # An unreadable exit code means the launch worked and the result is
        # unknown; only a code that is present and non-zero is a failure.
        $code = $null
        try { $code = $proc.ExitCode } catch { $code = $null }
        if ($null -ne $code -and $code -ne 0) {
            $detail = if ($said) { " $said" } else { '' }
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_39bf9a1d65c34845' -Arguments @{ leaf = "$($entry.Leaf)"; code = "$code"; name = "$Name"; detail = "$detail" })
        } else {
            $null = $applied.Add($entry.Leaf)
        }
    }
    return $applied.ToArray()
}

function Register-WindowsUserExecutionPolicyTask {
    <#
        The no-usable-password path: an account created with -NoPassword, or
        flagged to change its password at the first login, cannot be logged
        on from here at all. A logon-triggered task carries the same command
        into the account's first sign-in, where the session is its own.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([string]$Name, [string]$TaskName, [string]$Command, [hashtable[]]$Shell)

    if (-not $PSCmdlet.ShouldProcess($Name, (Format-YurunaOperatorMessage -Key 'runner.operator_8a8eb73bf7a84874' -Arguments @{ taskName = "$TaskName" }))) { return $false }
    if (-not $Shell -or $Shell.Count -eq 0) { return $false }

    $encoded   = ConvertTo-EncodedCommand -Command $Command
    $qualified = "$env:COMPUTERNAME\$Name"
    try {
        # One action per host; a task runs its actions in order, in the same
        # logon session.
        $actions = foreach ($entry in $Shell) {
            New-ScheduledTaskAction -Execute $entry.Path -Argument "-NoProfile -NonInteractive -EncodedCommand $encoded"
        }
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $qualified
        # An end boundary plus DeleteExpiredTaskAfter is the only self-cleanup
        # the task can count on: the account it runs as is not elevated at
        # sign-in and cannot unregister a task an administrator registered.
        # Until it expires the task re-runs at every sign-in, writing the same
        # value again.
        $trigger.EndBoundary = (Get-Date).AddDays(30).ToString('yyyy-MM-ddTHH:mm:ss')
        $principal = New-ScheduledTaskPrincipal -UserId $qualified -LogonType Interactive
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        $settings.DeleteExpiredTaskAfter = 'PT0S'
        $null = Register-ScheduledTask -TaskName $TaskName -Force `
            -Action $actions -Trigger $trigger -Principal $principal -Settings $settings
        return $true
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_2ac10b82cfb7f59d' -Arguments @{ taskName = "$TaskName"; name = "$Name"; message = "$($_.Exception.Message)" })
        return $false
    }
}

# 'skipped' off Windows; the epilogue reports each of the other states, and
# the three lists below are what it reports them with.
$PolicyState       = 'skipped'
$PolicyAppliedHost = @()   # hosts whose policy is set now
$PolicyPendingHost = @()   # hosts a first-sign-in task will set
$PolicyOneUserHost = @()   # hosts no account but their owner's can run
if ($IsWindows) {
    $PolicyShell       = @(Get-WindowsShellCandidate)
    $PolicyOneUserHost = @($PolicyShell | Where-Object { -not $_.Usable })
    $PolicyUsableShell = @($PolicyShell | Where-Object { $_.Usable })
    foreach ($entry in $PolicyOneUserHost) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d6cee957ccc95679' -Arguments @{ leaf = "$($entry.Leaf)"; path = "$($entry.Path)"; accountName = "$AccountName" })
    }

    if ($WhatIfPreference) {
        $PolicyState = 'whatif'
    } elseif ($PolicyUsableShell.Count -eq 0) {
        $PolicyState = 'manual'
    } else {
        Write-Information ""
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_70f4ef82d6fff1cb' -Arguments @{ accountName = "$AccountName" })
        # A password the account cannot log in with yet -- none at all, or one
        # the first sign-in has to replace -- rules the direct logon out.
        if ($HasPassword -and -not $ShouldForceChange) {
            $PolicyAppliedHost = @(Set-WindowsUserExecutionPolicy -Name $AccountName -Secret $Password `
                -Command $PolicyCommand -Shell $PolicyUsableShell)
        }
        $PolicyPendingHost = @($PolicyUsableShell | Where-Object { $PolicyAppliedHost -notcontains $_.Leaf })

        if ($PolicyPendingHost.Count -eq 0) {
            $PolicyState = 'applied'
        } elseif (Register-WindowsUserExecutionPolicyTask -Name $AccountName -TaskName $PolicyTaskName `
                    -Command $PolicyCommand -Shell $PolicyPendingHost) {
            $PolicyState = 'deferred'
        } else {
            $PolicyState = 'manual'
        }

        if ($PolicyState -eq 'applied') {
            # A task left by an earlier passwordless run would keep firing at
            # sign-in against a principal a recreated account no longer is.
            # Inside the try with the lookup: a host without the ScheduledTasks
            # module raises a command-not-found that -ErrorAction cannot reach.
            try {
                if (Get-ScheduledTask -TaskName $PolicyTaskName -ErrorAction SilentlyContinue) {
                    Unregister-ScheduledTask -TaskName $PolicyTaskName -Confirm:$false -ErrorAction Stop
                }
            } catch {
                Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_440852a11f738607' -Arguments @{ policyTaskName = "$PolicyTaskName"; message = "$($_.Exception.Message)" })
            }
        }
    }
}

# --- REGION: Register in the runtime users.yml
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

function Initialize-UsersRuntimeFile {
    <#
        Seed the gitignored runtime users.yml from the committed template,
        the same way the authentication extension's own bootstrap does
        (default.psm1, Read-UsersConfig), so a host that has never run a
        cycle still gets its entry into the file the extension reads.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([string]$Path, [string]$Template)

    if (Test-Path -LiteralPath $Path) { return $true }
    if (-not $PSCmdlet.ShouldProcess($Path, (Format-YurunaOperatorMessage -Key 'runner.operator_f8a9850aa3fba4f6' -Arguments @{ template = "$Template" }))) { return $false }
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    Copy-Item -LiteralPath $Template -Destination $Path -Force
    return $true
}

$wrote       = New-Object System.Collections.Generic.List[string]
$SeededUsers = $false
if (-not $UsersEntryReused) {
    $SeededUsers = -not (Test-Path -LiteralPath $UsersRuntime)
    if ((Initialize-UsersRuntimeFile -Path $UsersRuntime -Template $UsersTemplate) -and
        $PSCmdlet.ShouldProcess($UsersRuntime, (Format-YurunaOperatorMessage -Key 'runner.operator_fd5b18a91f365cb8' -Arguments @{ accountName = "$AccountName" }))) {
        Add-Content -LiteralPath $UsersRuntime -Value $YamlEntry -NoNewline:$false
        # Re-read to confirm the new entry is reachable. With powershell-yaml
        # this also proves the whole file still parses as YAML, which the text
        # scan cannot establish -- the scan only proves the entry landed in the
        # shape it was written.
        try {
            if ($YamlAvailable) {
                $cfg = Get-Content -Raw -LiteralPath $UsersRuntime | ConvertFrom-Yaml -Ordered -ErrorAction Stop
                if ($null -eq $cfg.users -or -not $cfg.users.Contains($AccountName)) {
                    throw "Post-write parse did not surface the new entry."
                }
            } elseif (@(Get-DeclaredUserNameFromText -Lines (Get-Content -LiteralPath $UsersRuntime)) -notcontains $AccountName) {
                throw "Post-write scan did not surface the new entry."
            }
        } catch {
            throw "Wrote '$AccountName' to $UsersRuntime but post-write verification failed: $($_.Exception.Message). Delete the trailing entry (or the whole file -- the extension re-seeds it from the template), then re-run."
        }
        $null = $wrote.Add($UsersRuntime)
    }
}

# --- REGION: Inform the operator
$banner  = if ($WhatIfPreference) { 'Local test user WOULD BE created' }
           elseif ($Recreated)     { 'Local test user re-created' }
           else                    { 'Local test user created' }
$heading = if ($WhatIfPreference) { 'What a real run would leave behind:' } else { 'Action items + state:' }
Write-Information ""
Write-Information "========"
Write-Information "  ${banner}: $AccountName ($FullName)"
Write-Information "========"
Write-Information ""
Write-Information $heading
Write-Information ""

$step = 1
if ($Recreated) {
    $deleted  = if ($WhatIfPreference) { 'WOULD BE deleted' } else { 'was deleted' }
    $homeVerb = if ($WhatIfPreference) { 'would go' } else { 'went' }
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_2ce865cd89b0edf9' -Arguments @{ step = "$step"; accountName = "$AccountName"; deleted = "$deleted" })
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_d13b200888c6a2ae')
    if ($RemovedHome) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_82f0cd22ff5610aa' -Arguments @{ removedHome = "$RemovedHome"; homeVerb = "$homeVerb" })
    }
    Write-Information ""
    $step++
}

if ($HasPassword -or ($WhatIfPreference -and $WantsPassword)) {
    if ($WhatIfPreference -and $ReuseStored) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_65ea555d7c6b007e' -Arguments @{ step = "$step" })
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_085c897ff1b3b2eb' -Arguments @{ accountName = "$AccountName"; key = "$($StoredCredential.Key)" })
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b6bb67156bb6824a')
    } elseif ($WhatIfPreference -and $HasPassword) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_5103c2386d75f437' -Arguments @{ step = "$step" })
    } elseif ($WhatIfPreference) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_25ec9907cee8c3d0' -Arguments @{ step = "$step" })
    } elseif ($PasswordFromVault) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_74b20cd417e8817c' -Arguments @{ step = "$step" })
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_ea4164a81364283f' -Arguments @{ accountName = "$AccountName"; key = "$($StoredCredential.Key)" })
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_c32a98a17ba89dd9')
    } else {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_68164e927bcc0e9e' -Arguments @{ step = "$step" })
    }
    if (-not $ShouldForceChange) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_9afb7feae8a625ef')
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_f5355ca99920de09')
} else {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_6bc36c3e1265c23b' -Arguments @{ step = "$step"; accountName = "$AccountName" })
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_58b5a5c9f50f5bed')
    if ($IsWindows) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_14611400ea942a10' -Arguments @{ accountName = "$AccountName" })
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_f3932e86f1166a66')
    } elseif ($IsMacOS) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b0f17a6c92efa2d7' -Arguments @{ accountName = "$AccountName" })
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_a7bc16ca8ad50156')
    } elseif ($IsLinux) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b0f17a6c92efa2d7' -Arguments @{ accountName = "$AccountName" })
    }
}
Write-Information ""
$step++

if ($Admin) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_9f7c5863216cc042' -Arguments @{ step = "$step" })
    if ($IsWindows) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_ce0dbb11233015ec')
    } elseif ($IsMacOS) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_a6732496b1fd1e11')
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_9822f504b5c43500')
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_f86fd5765e14a20b')
    } elseif ($IsLinux) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_4c55f8e185ed596a')
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_ec9e341ad6d6e62a')
    }
    Write-Information ""
    $step++
} else {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_715d84e1ff4deba7' -Arguments @{ step = "$step" })
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_bd4f326517a4237a')
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_d138c41ccd0a05c4')
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_0eeb0f082780ca5f')
    if ($IsWindows) {
        # The group's NAME is localized, so the guidance resolves it by SID for
        # the same reason New-WindowsLocalUser does.
        Write-Information "       Add-LocalGroupMember -Member $AccountName ``"
        Write-Information "         -Group (Get-LocalGroup | Where-Object { `$_.SID.Value -eq 'S-1-5-32-544' }).Name"
    } elseif ($IsMacOS) {
        Write-Information "       sudo dseditgroup -o edit -a $AccountName -t user admin"
    } elseif ($IsLinux) {
        Write-Information "       sudo usermod -aG sudo $AccountName"
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_f360a3b3c52c7237')
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b4eec42f2cd69aeb' -Arguments @{ accountName = "$AccountName" })
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_a6e937a984ef59bc')
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_9a69333b784c7f9d')
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_a528ae45427ecf1f')
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_52cebdb9b046f8fe')
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_ffc71b673ec1b46f')
    Write-Information ""
    $step++
}

if ($ShouldForceChange) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_a9b463e8eefbc554' -Arguments @{ step = "$step" })
    if ($IsWindows) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_9ce00da594f93e57')
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_c2f406962277a0e6')
    } elseif ($IsMacOS) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_3980446c8dcd23f0')
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_68256ad6a8f47d12')
    } elseif ($IsLinux) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_6148001e471f7a7e')
    }
    Write-Information ""
    $step++
}

if ($PolicyState -ne 'skipped') {
    $appliedIn = ($PolicyAppliedHost -join ', ')
    $pendingIn = (@($PolicyPendingHost | ForEach-Object { $_.Leaf }) -join ', ')
    switch ($PolicyState) {
        'applied' {
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_ce945d6cc139f9f8' -Arguments @{ step = "$step" })
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_989a4da22ecc109d' -Arguments @{ appliedIn = "$appliedIn" })
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_cc4c31e1b2eeb4aa' -Arguments @{ accountName = "$AccountName" })
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_7a67605dbaf9e1a4')
        }
        'deferred' {
            $why = if (-not $HasPassword) {
                       @('The account has no password this run could log it on with.')
                   } elseif ($ShouldForceChange) {
                       @('The account must change its password at the first login, so',
                         'this run could not log it on.')
                   } else {
                       @('Logging the account on from here did not work -- the warnings',
                         'above say why.')
                   }
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_1c6dd74bf713ea0f' -Arguments @{ step = "$step"; pendingIn = "$pendingIn" })
            foreach ($line in $why) { Write-Information "     $line" }
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_bb4af2f3a3025c74')
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_93a6a19ab6710180')
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_878114d3a2fe825c' -Arguments @{ policyTaskName = "$PolicyTaskName" })
            if ($appliedIn) {
                Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_083efcacf651607c' -Arguments @{ appliedIn = "$appliedIn" })
            }
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_ae9aaf1b0c5d4459')
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_4df966af1ca31c35')
        }
        'manual' {
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_02a1066126f92854' -Arguments @{ step = "$step" })
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_23987bbbb4b24ea9')
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_1defe9aa2e99aade')
            Write-Information "     '$AccountName', run:"
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_7da73041a39f4b80')
        }
        'whatif' {
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_bb64a99aeac164e1' -Arguments @{ step = "$step" })
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_6b696d3285e8ca00' -Arguments @{ accountName = "$AccountName" })
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_10a793be596c4168')
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_a7b66a70890db579')
        }
    }
    foreach ($entry in $PolicyOneUserHost) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_aa76f347f02aaf4d' -Arguments @{ leaf = "$($entry.Leaf)" })
        Write-Information "       $($entry.Path)"
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_322a7712eada0ba2' -Arguments @{ accountName = "$AccountName" })
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_aab0c4b852934709')
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_5344b9e7147b1112')
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_41856668e101e1fc')
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_e7cfc0e93e3d317b')
    }
    Write-Information ""
    $step++
}

if ($UsersEntryReused) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_988bcc81b612252e' -Arguments @{ step = "$step" })
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_149acad0d480ff72')
    foreach ($p in $DeclaredIn) { Write-Information "       $p" }
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_0c5ca3e94b40c48f')
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_3f965b8f770b8f1a')
} elseif ($wrote.Count -gt 0) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_c507d87ba69cca7d' -Arguments @{ step = "$step" })
    foreach ($p in $wrote) { Write-Information "       $p" }
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_caf0ab7112acaa07')
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_41e429dcda992869')
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_8069f016af00b06d')
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_3d774626ea2cc3a3')
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_d73fcc096d8e1a4e')
    if ($SeededUsers) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b401dc408a31017a')
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_c3cec8d182e17227')
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_251d5f5cdbef69b0')
    }
    if (-not $YamlAvailable) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_c90d554bcabfe8e5')
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_87723d817eb7fefc')
    }
}
Write-Information ""
