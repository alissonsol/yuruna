<#PSScriptInfo
.VERSION 2026.08.23
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
    exists is the one hard stop, and -Force is the way through it --
    the account is deleted, home directory included, and recreated.

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
    Skip this script's own confirmation prompts, and repair what the
    script otherwise refuses: an OS account that already exists is
    DELETED -- home directory and everything under it -- and recreated
    with the password and group membership asked for. The operating
    system may still prompt (UAC consent, sudo password).

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
    # Re-create the default test account: an existing `yurunatest` OS
    # account and its home directory are deleted first, while the Yuruna
    # users.yml entry and any vault password it points at are reused.
    # Add -WhatIf the first time to see exactly what would be removed.

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
    # -PromptForPassword is forwarded only when the operator asked for it: it
    # also means "do not reuse a stored vault password", and the elevated
    # window prompts by default anyway once no password reaches it.
    if (-not $WantsPassword)    { $argList += '-NoPassword' }
    elseif ($PromptForPassword) { $argList += '-PromptForPassword' }

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
            Write-Information "Canceled. Nothing was changed."
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
        Write-Information "Canceled. Nothing was changed."
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

function Remove-OsUser {
    <#
        Delete an existing account and its home directory, so the account
        recreated over it starts clean. A home directory left behind keeps
        the old owner's uid, which the new account cannot read and cannot
        be given without a recursive chown nobody asked for.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Name, [hashtable]$Fact)

    $target = if ($Fact.Home) { "$Name (and $($Fact.Home))" } else { $Name }
    if (-not $PSCmdlet.ShouldProcess($target, 'Delete the existing OS account')) { return }

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
                Write-Warning "Deleted the account but could not remove its profile at $($Fact.Home): $($_.Exception.Message)"
                Write-Warning "Remove it by hand, or the recreated account gets a second profile directory beside it."
            }
        }
        return
    }

    if ($IsMacOS) {
        # -deleteUser takes the home directory with it; -keepHome would
        # leave it owned by a uid that no longer resolves.
        $out = & sudo sysadminctl -deleteUser $Name 2>&1
        $rc  = $LASTEXITCODE
        # sysadminctl reports some failures on stderr while still exiting 0,
        # so the account itself is the verification.
        if (Test-OsUser -Name $Name) {
            throw "sysadminctl -deleteUser did not remove '$Name' (exit $rc): $out"
        }
        return
    }

    # -r takes the home directory and the mail spool with the account.
    $out = & sudo userdel -r $Name 2>&1
    $rc  = $LASTEXITCODE
    if ($rc -ne 0) {
        if (Test-OsUser -Name $Name) { throw "userdel -r exited $rc`: $out" }
        # Exit 12 is "account removed, home directory could not be": the
        # recreate below still works, on a directory that needs cleaning up.
        Write-Warning "userdel -r exited $rc but '$Name' is gone: $out"
        Write-Warning "Check $($Fact.Home) -- it may have survived the deletion."
    }
}

$Recreated   = $false
$RemovedHome = ''

if (Test-OsUser -Name $AccountName) {
    $existing = Get-OsUserFact -Name $AccountName
    $homeNote = if ($existing.Home) { $existing.Home } else { 'not found' }

    if (-not $Force) {
        throw @"
OS account '$AccountName' already exists on this host (home: $homeNote).
This script creates accounts; it does not adopt one it did not create,
because it cannot tell a stale test account from one in use. Recover by
either:
  1. re-running with -Force, which DELETES '$AccountName' -- home
     directory included -- and recreates it with the password and rights
     asked for here. See what that removes first with:  -Force -WhatIf
  2. re-running with a different -AccountName, leaving this one alone.
The Yuruna users.yml entry is not the obstacle: an entry that already
declares '$AccountName' is reused as-is, never overwritten.
"@
    }

    $invokingAccount = if ($IsWindows) { $env:USERNAME } else { $env:USER }
    if ([string]::IsNullOrWhiteSpace($invokingAccount) -and -not $IsWindows) { $invokingAccount = & id -un }

    if ($existing.IsSystem) {
        throw "OS account '$AccountName' is a system account (id $($existing.Id)); -Force will not delete it. Deleting it would break the host, not reset a test account. Choose a different -AccountName."
    }
    # Windows account names are case-insensitive; POSIX ones are not, so
    # `-ceq` there keeps a legitimately distinct name out of this guard.
    $isInvoker = if ($IsWindows) { $AccountName -eq $invokingAccount } else { $AccountName -ceq $invokingAccount }
    if ($isInvoker) {
        throw "'$AccountName' is the account running this script; -Force will not delete the account it is running as. Re-run from another administrator account, or choose a different -AccountName."
    }
    if ($existing.Active) {
        throw "OS account '$AccountName' has an open login session. Sign every session of it out and re-run: deleting it now would leave that session pointing at a uid and a home directory that no longer exist."
    }

    Write-Information ""
    Write-Warning "-Force: '$AccountName' already exists and is being deleted, then recreated from scratch."
    if ($existing.Home) {
        Write-Warning "This removes $($existing.Home) and everything under it. Nothing of the old account survives."
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
            Write-Warning "Could not parse $Path as YAML ($($_.Exception.Message)); -Force: falling back to a text scan for the '$Name' entry. Fix the file before the next cycle -- Test-Config.ps1 will refuse it."
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
    Write-Warning "'$AccountName' is already declared as a Yuruna user in $($DeclaredIn -join ' and '). The existing entry is kept as it is -- nothing is written to users.yml, and the credentials it points at are reused."
    if ($DeclaredIn -notcontains $UsersRuntime) {
        Write-Warning "That declaration is in the committed template. This run adds nothing to it; new entries go to $UsersRuntime, which inherits the template's entries when it is seeded."
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
            Write-Warning "Could not read $UsersPath to resolve the vault key: $($_.Exception.Message)"
        }
    }
    try {
        $vault = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Yaml -Ordered -ErrorAction Stop
    } catch {
        Write-Warning "Could not parse $Path as YAML: $($_.Exception.Message). Asking for a password instead."
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
        Write-Information "-WhatIf: a real run would $source."
    } elseif ($ReuseStored) {
        $Password          = $StoredCredential.Password
        $PasswordFromVault = $true
        Write-Information ""
        Write-Information "The authentication vault already holds a local-OS password for '$AccountName'"
        Write-Information "(vault key '$($StoredCredential.Key)'). Reusing it, so the account matches the"
        Write-Information "credential Yuruna already hands out. Pass -PromptForPassword to set a new one."
    } else {
        if ($StoredCredential) {
            Write-Warning "The vault holds a local-OS password for '$AccountName' (key '$($StoredCredential.Key)') and -PromptForPassword was given: the account gets what you type now, and the stored copy stops matching until you update $VaultPath (users.$($StoredCredential.Key).password)."
        }
        $Password = Read-NewPassword -Name $AccountName
    }
}
$HasPassword = -not [string]::IsNullOrEmpty($Password)

if ($StoredCredential -and $HasPassword -and -not $PasswordFromVault -and $Password -ne $StoredCredential.Password) {
    Write-Warning "The password being set on '$AccountName' differs from the one the vault stores under key '$($StoredCredential.Key)'. Yuruna keeps handing out the stored one until you update $VaultPath (users.$($StoredCredential.Key).password)."
}
if ($StoredCredential -and $NoPassword) {
    Write-Warning "'$AccountName' is being created without a password while the vault still stores one under key '$($StoredCredential.Key)'. Nothing can log in with it until the account's password is set to match."
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
    if (-not $PSCmdlet.ShouldProcess($Path, "Seed users.yml from $Template")) { return $false }
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
        $PSCmdlet.ShouldProcess($UsersRuntime, "Append yuruna users entry '$AccountName'")) {
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
    Write-Information "  $step. The '$AccountName' account that existed before this run $deleted"
    Write-Information "     and recreated from scratch: nothing of the old account survives."
    if ($RemovedHome) {
        Write-Information "     Its home directory ($RemovedHome) $homeVerb with it."
    }
    Write-Information ""
    $step++
}

if ($HasPassword -or ($WhatIfPreference -and $WantsPassword)) {
    if ($WhatIfPreference -and $ReuseStored) {
        Write-Information "  $step. A real run would reuse the password the authentication vault"
        Write-Information "     already holds for '$AccountName' (vault key '$($StoredCredential.Key)')"
        Write-Information "     and set it as usable."
    } elseif ($WhatIfPreference -and $HasPassword) {
        Write-Information "  $step. A real run would set the password supplied on the command line."
    } elseif ($WhatIfPreference) {
        Write-Information "  $step. A real run would ask for the password and set it as usable."
    } elseif ($PasswordFromVault) {
        Write-Information "  $step. The password is the one the authentication vault already held"
        Write-Information "     for '$AccountName' (vault key '$($StoredCredential.Key)'); it is set"
        Write-Information "     and usable, and Yuruna's copy still matches."
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
        Write-Information "     member of the 'admin' group, which is what grants sudo."
        Write-Information "     The group list is fixed when a session starts, so it takes"
        Write-Information "     effect on the account's next sign-in."
    } elseif ($IsLinux) {
        Write-Information "     member of the 'sudo' group. Group membership is read at login,"
        Write-Information "     so it takes effect on the account's next sign-in."
    }
    Write-Information ""
    $step++
} else {
    Write-Information "  $step. The account is NOT a local machine administrator."
    Write-Information "     It cannot run the host installer or Enable-TestAutomation:"
    Write-Information "     both need root / Administrator and will refuse. Grant the"
    Write-Information "     rights from an account that already has them:"
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
    Write-Information "     The group list is fixed when a session starts, so sign"
    Write-Information "     '$AccountName' out and back in before retrying -- a session"
    Write-Information "     opened before the grant keeps the list it started with."
    Write-Information "     Re-running with -Force is the other way out: it deletes the"
    Write-Information "     account, home directory included, and recreates it with the"
    Write-Information "     rights asked for. The grant above keeps the home directory."
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

if ($UsersEntryReused) {
    Write-Information "  $step. Already registered with the default Yuruna authentication"
    Write-Information "     extension; the existing entry was kept, not rewritten:"
    foreach ($p in $DeclaredIn) { Write-Information "       $p" }
    Write-Information "     Whatever corporate mapping / vaultKey / localOsPasswordRef it"
    Write-Information "     already carries still applies -- this run changed none of it."
} elseif ($wrote.Count -gt 0) {
    Write-Information "  $step. Added to the default Yuruna authentication extension:"
    foreach ($p in $wrote) { Write-Information "       $p" }
    Write-Information "     corporate.* / vaultKey / localOsPasswordRef are empty --"
    Write-Information "     the account is registered as a purely-local Yuruna user,"
    Write-Information "     NOT yet bound to any corporate (AD / Entra / etc.) identity."
    Write-Information "     See test/extension/authentication/users.yml.template for how"
    Write-Information "     to bind a vault key / corporate identity later."
    if ($SeededUsers) {
        Write-Information "     This host had no runtime users.yml, so it was seeded from the"
        Write-Information "     committed template before the entry was appended. The template"
        Write-Information "     itself is never written to."
    }
    if (-not $YamlAvailable) {
        Write-Information "     The entry was confirmed by text scan; install powershell-yaml"
        Write-Information "     to have the whole file re-validated as YAML on future runs."
    }
}
Write-Information ""
