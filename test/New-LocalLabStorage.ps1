<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42c1f7a4-8e05-49bd-9d36-3f7ab2c48e91
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna lab storage smb share pool stash local
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
    Turn THIS machine into its own pool and stash storage server: create the
    folders, the two storage accounts, the SMB shares, mount them back over the
    network stack, and write the result into test.config.yml.

.DESCRIPTION
    A lab with no NAS still needs the pool and stash tiers. Standing them up by
    hand is a dozen elevated, per-platform steps -- create two folders, create
    two accounts, enable a file server, publish two shares, set ACLs, add host
    aliases, store two passwords in a vault, mount two shares, edit six config
    keys -- with nothing to check the result. This does all of it, on Windows,
    macOS, and Ubuntu, and is safe to re-run.

    FOR LOCAL MACHINES ONLY. The accounts and permissions it creates are local
    to this machine. A real NAS or a separate file server owns its own accounts
    and its own access control, and neither can be configured from here: on
    those, create the users and grant the share permissions ON THE REMOTE
    DEVICE, then point networkStorage.* at it (docs/test-config.md). The script
    says this and asks for confirmation before it changes anything.

    The shares are LOCAL but are consumed as if they were REMOTE. Each tier gets
    a host alias (ypool-nas, ystash-nas) resolving to the loopback address, and
    the share is mounted over SMB through that name by the same
    Connect-YurunaPoolStorage the unattended cycle uses. The benefit is
    uniformity: the runner, the config gate, the replication drain, and the
    guest seeds all take the one network path, so a single-machine lab exercises
    the same code as a lab with a NAS -- and moving to real hardware later
    changes the alias and nothing else.

    The storage root is resolved first (prompted, with the platform's convention
    offered as the default: /srv/yuruna on Ubuntu, /Users/Shared/yuruna on macOS,
    <drive>\Shares\yuruna on Windows -- the first fixed drive that is not the
    system drive). The eight numbered steps then run in this order:

      1. Folders, lab vault, and pool-intent repository, by calling New-Lab.ps1.
         The two share passwords are the ones it generates; a lab that already
         exists keeps the passwords it has, so a re-run does not rotate the
         credentials the lab's other machines are using.
      2. SMB server. Started (Windows), enabled (macOS File Sharing), or
         installed and configured (Ubuntu: samba + cifs-utils). Before the
         accounts so step 4 can publish and probe in the same run.
      3. Storage accounts. One local account per tier, each scoped to its own
         share: not an administrator, no interactive shell, and on Ubuntu the
         OS password stays locked (the SMB credential lives in Samba's passdb).
         On macOS the SMB-NT hash type is enabled and the password re-set, which
         is the only thing that makes the account usable over SMB at all.
      4. Shares. One per tier, each granting only that tier's account; on macOS
         each credential is then proved against the running SMB server.
      5. Loopback. Host aliases for both server names, plus, on Windows, the
         NTLM loopback exemption and EnableLinkedConnections.
      6. Vault. Each password is mapped to a vaultKey in users.yml and stored,
         so the harness never auto-generates a password the share would reject.
      7. Config. The six networkStorage keys in test/test.config.yml.
      8. Mount. Both shares, at the platform's conventional mount points --
         after the config, so what mounts is what the runner will later read.
         A share already standing at one of those points is unmounted first,
         so what is mounted is what step 5's alias now resolves to.

    Account names are deliberately NOT parameters -- they are the two script
    variables below. They have to agree with the accounts on a NAS if this lab
    ever moves to one, so they are a lab-wide constant to be edited once, not a
    per-run choice that could differ between machines.

.PARAMETER Root
    Storage root, skipping the prompt. Omit it for the interactive prompt,
    which offers this platform's convention as the default.

.PARAMETER LabName
    Lab name passed to New-Lab.ps1 (lowercase letters, digits, hyphens).
    Defaults to this machine's host name, normalized to that charset.

.PARAMETER EnableReplication
    Also set pool.networkReplicate to true, so finished cycles are archived to
    the pool share. Off by default: it is a runner behavior change, and with it
    on a broken share stops cycles from starting rather than being advisory.

.PARAMETER Force
    Skip this script's own confirmation prompts, including the local-only
    warning. The operating system may still prompt (UAC consent, sudo
    password).

.EXAMPLE
    pwsh test/New-LocalLabStorage.ps1
    # The common case: confirms the local-only warning, asks where storage
    # should live, and does everything else unattended.

.EXAMPLE
    pwsh test/New-LocalLabStorage.ps1 -Root /srv/yuruna -EnableReplication
    # Non-interactive about the location, and turns cycle archiving on.

.EXAMPLE
    pwsh test/New-LocalLabStorage.ps1 -WhatIf
    # Prints every change without making one. Elevation is not requested.

.NOTES
    Requires Administrator (Windows) or sudo (macOS / Ubuntu).

    Windows applies two of the changes at the next sign-in, not immediately:
    EnableLinkedConnections (so the mapped drives are visible outside the
    elevated session) and, if the Server service cannot be restarted, the
    NTLM loopback exemption.

    macOS mounts its own SMB server here. That is supported, but it is a
    self-referential I/O path: under heavy memory pressure a machine serving
    and consuming the same share can stall in a way a separate NAS cannot.
    For a machine that runs cycles continuously, prefer real remote storage.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)][string]$Root,
    [Parameter(Position = 1)][string]$LabName,
    [switch]$EnableReplication,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# Honor the caller's logLevel, published as $env:YURUNA_LOG_LEVEL by whatever
# entry point started this script (install/setup.ps1, a runner cycle). After the
# line above on purpose: an explicit level is the operator's choice and replaces
# this script's own default. $InformationPreference is then re-read from the
# global the cascade writes, because the script-scoped assignment above shadows
# it for the rest of this file. See docs/loglevels.md.
Import-Module (Join-Path $PSScriptRoot 'modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
Use-LogLevelFromEnv
$InformationPreference = $global:InformationPreference
# The elevation gate reads sudo's exit code rather than catching an exception,
# and the per-OS steps probe the host with commands whose non-zero exit is the
# answer, not a failure. Pinned so an ambient preference (a profile, a wrapping
# script) cannot turn those into terminating errors.
$PSNativeCommandUseErrorActionPreference = $false

# --- REGION: Lab-wide constants
# Account and share naming. These are the same values the documentation and the
# guest seeds use, and they must match the accounts on a NAS if this lab is ever
# repointed at one -- change them here, once, for the whole lab.
$PoolAccount   = 'yuruna-pool'
$StashAccount  = 'yuruna-stash'
$PoolServer    = 'ypool-nas'
$StashServer   = 'ystash-nas'
$PoolFolder    = 'yuruna.pool'
$StashFolder   = 'yuruna.stash'
$PoolShare     = 'yuruna.pool'
$StashShare    = 'yuruna.stash'
# Windows mount points. The rest of the tree documents y: and z: for the two
# tiers, so a Windows host that later syncs its config from another one lands on
# the same letters.
$PoolDrive     = 'y:'
$StashDrive    = 'z:'

# --- REGION: Modules
Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
Import-Module (Join-Path $paths.ModulesDir 'Test.LocalLabStorage.psm1') -Global -Force
Import-Module (Join-Path $paths.ModulesDir 'Test.Lab.psm1') -Global -Force
Import-Module (Join-Path $paths.ModulesDir 'Test.StateFile.psm1') -Global -Force
Import-Module (Join-Path $paths.ModulesDir 'Test.PoolStorage.psm1') -Global -Force
Import-Module (Join-Path $paths.ModulesDir 'Test.Config.psm1') -Global -Force -ErrorAction SilentlyContinue
# Test-YurunaCanPrompt / Assert-YurunaPromptable. Test.LocalLabStorage.psm1
# already pulls this in -Global, but this script asks the two questions that
# decide whether it runs at all, so it states the dependency itself rather than
# inheriting it from a module that could stop needing it.
Import-Module (Join-Path $paths.RepoRoot 'automation/Yuruna.Common.psm1') -Global -Force -DisableNameChecking

$authExtension = Join-Path $paths.RepoRoot 'test/extension/authentication/default.psm1'
if (-not (Test-Path -LiteralPath $authExtension)) {
    throw "Authentication extension not found at $authExtension."
}
Import-Module $authExtension -Global -Force -DisableNameChecking

if (-not (Get-Module -ListAvailable -Name powershell-yaml -ErrorAction SilentlyContinue)) {
    throw "powershell-yaml is required to read the lab vault and write test.config.yml. Install it with: Install-Module powershell-yaml -Scope CurrentUser"
}
$PreviousWhatIf = $WhatIfPreference
try {
    # The module's own New-Alias calls read $WhatIfPreference out of the caller's
    # scope chain, so a dry run would narrate alias registrations nobody asked
    # about. Suppressed across the import only.
    $WhatIfPreference = $false
    Import-Module powershell-yaml -Verbose:$false -ErrorAction Stop
} finally {
    $WhatIfPreference = $PreviousWhatIf
}

$Platform = Get-LocalLabStoragePlatform

function Confirm-Step {
    param(
        [Parameter(Mandatory)][string]$Question,
        [bool]$SkipPrompt = $false,
        [bool]$DefaultYes = $false
    )
    if ($SkipPrompt) { return $true }
    # A consent gate must never answer itself. This script runs as a child of
    # install/setup.ps1 with stdin closed, where Read-Host returns EOF -- an
    # empty answer, which falls through to $DefaultYes and reads as a decision
    # somebody made. Nobody made it, and the cancel path exits 0, so the caller
    # would record a clean PASS over a step that created nothing.
    Assert-YurunaPromptable -Question $Question -ParameterName '-Force'
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "$Question $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes }
    return ($answer.Trim() -match '^(y|yes)$')
}

# --- REGION: Step progress
# Almost every second this script spends is inside a native tool that prints
# nothing until it is finished: `sysadminctl -addUser`, `pwpolicy`, `apt-get
# install`, a nested `sudo pwsh` for the hosts file, and two SMB mounts each
# bounded by a multi-second timeout. Announcing the work BEFORE it starts, and
# timing it, is what separates a slow step from a hung one for the operator
# watching it -- the same reason the module's own OS calls narrate themselves.
$Script:StepTimer = [System.Diagnostics.Stopwatch]::new()

function Complete-LabStorageStep {
    [CmdletBinding()]
    param()
    if (-not $Script:StepTimer.IsRunning) { return }
    $Script:StepTimer.Stop()
    # Only a slow step reports its time: on a fast one the line is noise, on a
    # slow one it answers "which part took all that".
    $seconds = $Script:StepTimer.Elapsed.TotalSeconds
    if ($seconds -ge 2) { Write-Information ("      ({0:N0}s)" -f $seconds) }
}

function Write-LabStorageStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Number,
        [Parameter(Mandatory)][string]$Title
    )
    Complete-LabStorageStep
    Write-Information ""
    Write-Information "[$Number/8] $Title"
    $Script:StepTimer.Restart()
}

# --- REGION: Elevation -- Windows arm
# Windows refuses rather than prompting, so checking first costs the operator
# nothing: a session that cannot do the work should not be asked to confirm it
# or to name a storage root. The sudo arm is further down, after the local-only
# consent, because it spends a real password. -WhatIf skips both.
function Test-IsElevated {
    if ($IsWindows) {
        $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    return $true
}

if (-not $WhatIfPreference -and $IsWindows -and -not (Test-IsElevated)) {
    throw "Creating local accounts, SMB shares, and hosts-file entries requires an elevated session. Re-run this script from an Administrator PowerShell."
}

# --- REGION: The local-only warning
# Printed before anything is created, because the failure it prevents is
# expensive: pointing a NAS-backed lab at this script produces local accounts
# that the NAS has never heard of, and mounts that fail with a credential error
# whose real cause is on the other machine.
Write-Information ""
Write-Information "=================================================================="
Write-Information "  Local lab storage -- FOR THIS MACHINE ONLY"
Write-Information "=================================================================="
Write-Information ""
Write-Information "This creates pool and stash storage that lives on THIS machine and"
Write-Information "is served by THIS machine over SMB. It creates local OS accounts,"
Write-Information "local shares, and local permissions."
Write-Information ""
Write-Information "It is the right tool ONLY when the storage is local -- a single"
Write-Information "machine lab, or the machine that hosts the lab's shared services."
Write-Information ""
Write-Information "For a NAS device or a separate file server, do NOT use this script."
Write-Information "The accounts and the share permissions have to be created ON THAT"
Write-Information "DEVICE, by its own administration tool; nothing here can reach them."
Write-Information "Then set networkStorage.* to point at it and store the passwords in"
Write-Information "the vault -- see docs/test-config.md."
Write-Information ""
Write-Information "It changes this machine: local accounts, an SMB server, shares,"
Write-Information "hosts-file aliases$(if ($Platform -eq 'windows') { ', two registry values' } else { '' }), and mounted drives."
Write-Information ""
if ($WhatIfPreference) {
    Write-Information "-WhatIf: previewing only, so this confirmation is skipped."
} elseif (-not (Confirm-Step -Question "The storage for this lab is LOCAL to this machine. Continue" -SkipPrompt $Force.IsPresent)) {
    Write-Information "Cancelled. Nothing was changed."
    exit (Get-EntryPointExitCode -Outcome 'Ok')
}

# --- REGION: Elevation -- sudo arm
# The password is spent HERE: after the operator has consented to a local-only
# change, but ahead of the storage-root prompt and every state change, so the
# rest of the run needs no further attention. -WhatIf is a dry run and must not
# spend a sudo authentication; the ShouldProcess messages describe what a real
# run would do.
if ($WhatIfPreference) {
    Write-Information "-WhatIf: skipping the elevation request. A real run needs Administrator (Windows) or sudo (macOS / Ubuntu)."
} elseif (-not $IsWindows) {
    if (-not (Get-Command sudo -ErrorAction SilentlyContinue)) {
        throw "sudo not found on PATH. macOS / Ubuntu: sudo is required to create accounts and shares."
    }
    $invokingUser = if ($env:USER) { $env:USER } else { (& id -un) }
    # Ask the machine before asking the operator. `sudo -n -v` neither prompts
    # nor fails on an already-warm credential, so a run started by a caller that
    # primed sudo passes straight through and the banner below is not printed at
    # all -- the operator has already answered it once.
    & sudo -n -v 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        # sudo reads its password from /dev/tty, so neither the closed stdin nor
        # -NonInteractive that a parent gives this child can stop a bare
        # `sudo -v` from raising a prompt on a console the parent has taken over,
        # where it is invisible and waits forever. Fail with the remedy instead.
        if (-not (Test-YurunaCanPrompt)) {
            throw ("Creating accounts, shares and hosts entries needs root, and this run cannot ask for a password. " +
                   "Run 'sudo -v' in the same terminal first, or start this through install/setup.ps1, which takes the run's one authorization up front.")
        }
        Write-Information ""
        Write-Information "sudo will prompt for YOUR login password ($invokingUser) -- NOT for either storage account."
        Write-Information "  Elevation is needed to:"
        Write-Information "    * create the '$PoolAccount' and '$StashAccount' local OS accounts"
        Write-Information "    * enable the SMB server and publish both shares"
        Write-Information "    * add the storage server aliases to /etc/hosts"
        Write-Information ""
        & sudo -v
        if ($LASTEXITCODE -ne 0) {
            throw "sudo authentication failed (exit $LASTEXITCODE)."
        }
    }
}

# --- REGION: Storage root
if ([string]::IsNullOrWhiteSpace($Root)) {
    # No self-defaulting here. The suggestion below is a good one for a person
    # to accept, but accepting it on their behalf creates OS accounts, SMB
    # shares and mounts at a path nobody chose -- and on a single-drive Windows
    # host that path is the system drive this script's own caution warns off.
    Assert-YurunaPromptable -Question "Where should the lab's storage live?" -ParameterName '-Root'
    $dataDrive = if ($Platform -eq 'windows') { Get-LocalLabStorageWindowsDataDrive } else { '' }
    $suggested = Get-LocalLabStorageDefaultRoot -Platform $Platform -DataDrive $dataDrive
    if ($Platform -eq 'windows') {
        $systemDrive = if ($env:SystemDrive) { $env:SystemDrive.TrimEnd('\', '/') } else { 'C:' }
        if ($dataDrive -ieq $systemDrive) {
            Write-Information ""
            Write-Information "NOTE: this machine has only the system drive ($systemDrive), so the"
            Write-Information "      suggestion below is on it. A pool share grows without bound"
            Write-Information "      (pruning retired hosts is manual), and a full system drive takes"
            Write-Information "      the whole machine down, not just the lab. Prefer another drive."
        }
    }
    Write-Information ""
    $answer = Read-Host "Where should the lab's storage live? [$suggested]"
    $Root = if ([string]::IsNullOrWhiteSpace($answer)) { $suggested } else { $answer.Trim() }
}
$Root = $Root.Trim().TrimEnd('\', '/')
if ([string]::IsNullOrWhiteSpace($Root)) { throw "A storage root is required." }

if ([string]::IsNullOrWhiteSpace($LabName)) {
    # New-Lab constrains the name to the pool-id charset so a lab and a pool can
    # never disagree; a host name can carry characters outside it.
    $LabName = ([System.Net.Dns]::GetHostName()).ToLowerInvariant() -replace '[^a-z0-9-]', '-'
    $LabName = $LabName.Trim('-')
    if ([string]::IsNullOrWhiteSpace($LabName)) { $LabName = 'lab' }
    if ($LabName.Length -gt 63) { $LabName = $LabName.Substring(0, 63).TrimEnd('-') }
}

$tiers = @(
    (New-LocalLabStorageTier -Kind 'pool'  -Root $Root -Account $PoolAccount  -Server $PoolServer `
        -FolderName $PoolFolder  -ShareName $PoolShare  -Platform $Platform -DriveLetter $PoolDrive),
    (New-LocalLabStorageTier -Kind 'stash' -Root $Root -Account $StashAccount -Server $StashServer `
        -FolderName $StashFolder -ShareName $StashShare -Platform $Platform -DriveLetter $StashDrive)
)

Write-Information ""
Write-Information "Plan:"
Write-Information "  lab name    : $LabName"
Write-Information "  storage root: $Root"
foreach ($t in $tiers) {
    Write-Information "  $($t.Kind.PadRight(5)) : $($t.FolderPath)"
    Write-Information "          share '$($t.ShareName)' as '$($t.Account)' -> $($t.NetworkPath) mounted at $($t.LocalPath)"
}
Write-Information ""

# --- REGION: Step 1 -- folders, lab vault, pool-intent repository
# Delegated to New-Lab so the folder layout, the vault schema, and the seeded
# intent repository have exactly one implementation. Its generated passwords
# become the two share credentials below.
Write-LabStorageStep -Number 1 -Title 'Lab storage folders, lab vault, and pool-intent repository'
$newLab = Join-Path $PSScriptRoot 'New-Lab.ps1'
if (-not (Test-Path -LiteralPath $newLab)) { throw "New-Lab.ps1 not found at $newLab." }
if ($WhatIfPreference) {
    # New-Lab takes a plain param block, so it has no -WhatIf to forward to.
    # Describing the call is the dry run; invoking it would create the folders.
    Write-Information "      What if: would run New-Lab.ps1 -Name $LabName -Root $Root -User $PoolAccount,$StashAccount"
} else {
    & $newLab -Name $LabName -Root $Root -User @($PoolAccount, $StashAccount)
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
        throw "New-Lab.ps1 exited $LASTEXITCODE; storage was not created."
    }
}

$labVault = Join-Path -Path $paths.RepoRoot -ChildPath 'test' `
    -AdditionalChildPath 'status', 'extension', 'authentication', "lab.$LabName.vault.yml"
$labPassword = Get-YurunaLabVaultPassword -Path $labVault
if (-not $WhatIfPreference) {
    foreach ($t in $tiers) {
        if ([string]::IsNullOrEmpty([string]$labPassword[$t.Account])) {
            throw "The lab vault at $labVault has no password for '$($t.Account)'. Re-run New-Lab.ps1 -Name $LabName -Root $Root -Force to regenerate it."
        }
    }
}

# --- REGION: Step 2 -- SMB server
# Before the accounts so the shares below can be published and the credentials
# probed in this same run. It does NOT give an account its SMB credential --
# only the pwpolicy call in step 3 does that.
Write-LabStorageStep -Number 2 -Title 'SMB server'
$serverState = Enable-LocalLabStorageServer
Write-Information "      $serverState"

# --- REGION: Step 3 -- storage accounts
Write-LabStorageStep -Number 3 -Title 'Storage accounts'
foreach ($t in $tiers) {
    $pw = [string]$labPassword[$t.Account]
    if ($WhatIfPreference -and [string]::IsNullOrEmpty($pw)) { $pw = '<generated by New-Lab>' }
    $state = Set-LocalLabStorageAccount -Name $t.Account -Password $pw -Description "Yuruna $($t.Kind) storage"
    Write-Information "      $($t.Account): $state"
}

# --- REGION: Step 4 -- shares
Write-LabStorageStep -Number 4 -Title 'SMB shares'
if ($WhatIfPreference) {
    # The folders are New-Lab's output, which a dry run never produced, so
    # checking their permissions here would only report their absence.
    foreach ($t in $tiers) { Write-Information "      What if: would grant '$($t.Account)' write access to $($t.FolderPath)." }
} else {
    foreach ($t in $tiers) {
        Write-Information "      granting '$($t.Account)' write access to $($t.FolderPath)..."
        $null = Set-LocalLabStorageFolderAccess -Tier $t
    }
}
$shareState = New-LocalLabStorageShare -Tier $tiers
foreach ($t in $tiers) {
    Write-Information "      $($t.ShareName): $($shareState[$t.ShareName]) -> $($t.FolderPath)"
}

# Prove each credential authenticates OVER SMB, now that there is a server AND a
# sharepoint to authenticate against. macOS keeps a separate credential per
# authentication authority, so an account can pass every local check and still be
# refused by smbd; catching that here names the cause, where the same failure at
# step 8 reads only as a mount that will not mount.
if ($Platform -eq 'macos' -and -not $WhatIfPreference) {
    foreach ($t in $tiers) {
        Write-Information "      $($t.Account): proving the credential against the SMB server..."
        $verdict = Test-LocalLabStorageSmbAuth -Account $t.Account -Password ([string]$labPassword[$t.Account])
        if ($verdict -eq 'auth') {
            # A refusal HERE is the real thing: the account exists, the password is
            # the vault's, and the sharepoint it authenticates against was
            # published above. That is the only point in the run where deleting
            # the account is justified, so it is the only place that does it.
            Write-Information "      $($t.Account): refused by the SMB server; rebuilding the account and retrying..."
            if (Reset-LocalLabStorageAccount -Name $t.Account -Password ([string]$labPassword[$t.Account]) `
                    -Description "Yuruna $($t.Kind) storage" -Confirm:$false) {
                # The folder grant is per-account and the account is a new one.
                $null = Set-LocalLabStorageFolderAccess -Tier $t
                $verdict = Test-LocalLabStorageSmbAuth -Account $t.Account -Password ([string]$labPassword[$t.Account])
            }
        }
        switch ($verdict) {
            'ok'          { Write-Information "      $($t.Account): authenticates over SMB" }
            'auth'        {
                # Step 3 writes the credential, verifies it, and rebuilds the
                # account when it cannot -- so reaching here means the account has
                # the record and smbd still refuses it, which is not something the
                # operator can fix by repeating what this script already did.
                # Stop rather than continue: the mount at step 8 would fail with
                # "No such file or directory", a message about a missing share for
                # a credential that was never accepted.
                throw ("'$($t.Account)' carries a password record but the SMB server still refuses it, so the $($t.Kind) share cannot be mounted. " +
                       "The account and its password are in $labVault.")
            }
            'unreachable' { Write-Warning "Could not reach the SMB server on this machine to verify '$($t.Account)'. File Sharing may not have finished starting; re-run this script (it is idempotent) before debugging the mount." }
            default       { Write-Verbose "SMB auth probe for '$($t.Account)': $verdict" }
        }
    }
}

# --- REGION: Step 5 -- loopback reachability
Write-LabStorageStep -Number 5 -Title 'Loopback reachability'
$aliasCount = Set-LocalLabStorageHostAlias -RepoRoot $paths.RepoRoot -Name @($PoolServer, $StashServer)
Write-Information "      hosts file: $aliasCount alias(es) mapped to the loopback address"
if ($Platform -eq 'windows') {
    $loopback = Set-LocalLabStorageLoopbackException -Name @($PoolServer, $StashServer)
    Write-Information "      NTLM loopback exemption: $loopback"
    $linked = Set-LocalLabStorageLinkedConnection
    Write-Information "      EnableLinkedConnections: $linked"
    if ($linked -eq 'updated') {
        Write-Warning "EnableLinkedConnections takes effect at the next sign-in. Until then the mapped drives are visible only to elevated processes."
    }
}

# --- REGION: Step 6 -- vault
# A non-empty vaultKey is what takes Get-Password off the auto-generate path.
# Without it a missing entry silently mints a random password, and every mount
# fails against a share that never had that credential.
Write-LabStorageStep -Number 6 -Title 'Vault'
if ($WhatIfPreference) {
    foreach ($t in $tiers) { Write-Information "      What if: would map '$($t.Account)' to vaultKey '$($t.VaultKey)' and store its password." }
} else {
    Write-Information "      opening the vault..."
    Initialize-VaultConnection
    foreach ($t in $tiers) {
        $changed = Set-UserVaultKey -LogicalUser $t.Account -VaultKey $t.VaultKey -Confirm:$false
        Set-Password -Username $t.VaultKey -NewPassword ([string]$labPassword[$t.Account])
        $note = if ($changed) { 'vaultKey mapped' } else { 'vaultKey already correct' }
        Write-Information "      $($t.Account) -> $($t.VaultKey) ($note), password stored"
    }
}

# --- REGION: Step 7 -- test.config.yml
# Written BEFORE the mount so the mount can be driven from the file rather than
# from the in-memory tiers: what mounts is then exactly what the runner will
# later read, and a value that does not survive the round trip fails here
# instead of on the first unattended cycle.
Write-LabStorageStep -Number 7 -Title 'test.config.yml'
$configPath = $paths.ConfigPath
if (-not (Test-Path -LiteralPath $configPath) -and -not $WhatIfPreference) {
    # Seed from the template so the write EXTENDS a complete config instead of
    # producing a networkStorage-only file that drops every other setting.
    $template = Join-Path $PSScriptRoot 'test.config.yml.template'
    if (Test-Path -LiteralPath $template) {
        Copy-Item -LiteralPath $template -Destination $configPath -Force
        Write-Information "      created test.config.yml from the template"
    }
}
$wrote = Set-LocalLabStorageConfigValue -ConfigPath $configPath -Tier $tiers -EnableReplication:$EnableReplication
if ($wrote) {
    foreach ($t in $tiers) {
        Write-Information "      $($t.ConfigPrefix)NetworkPath: $($t.NetworkPath)"
        Write-Information "      $($t.ConfigPrefix)NetworkUser: $($t.Account)"
        Write-Information "      $($t.ConfigPrefix)LocalPath  : $($t.LocalPath)"
    }
    if ($EnableReplication) { Write-Information "      pool.networkReplicate: true" }
}

# --- REGION: Step 8 -- mount
# Mounted through Connect-YurunaPoolStorage rather than a mount call of its own:
# it is the same code the unattended cycle runs, so a share that mounts here is
# a share the cycle can mount, and a failure here is a failure the cycle would
# otherwise have hit later with nobody watching.
#
# The tier records are re-read from the written config through the harness's own
# readers, which is also what applies the '~' expansion the macOS mount point
# needs -- passed through unexpanded, mount_smbfs would create a directory
# literally named '~' and the mount check would never match it again.
Write-LabStorageStep -Number 8 -Title 'Mount'
if ($IsLinux) {
    # The cifs mount runs `sudo -n`, which never prompts; without the drop-in it
    # fails and the runner buffers locally instead of archiving.
    #
    # -NonInteractive is bound from the same predicate every other question in
    # this script uses, because installing the drop-in writes /etc/sudoers.d
    # through a bare `sudo tee`. sudo takes its password from /dev/tty, so under
    # a caller that has taken the console -- stdin closed, stdout captured -- that
    # write raises a prompt nothing displays and nothing answers, and the run
    # stops there having already created the accounts and the shares. Declined,
    # the call returns the exact commands to install the drop-in by hand.
    $sudoers = Set-PoolStorageSudoers -NonInteractive:(-not (Test-YurunaCanPrompt)) -WhatIf:$WhatIfPreference
    Write-Information "      passwordless sudo for mount: $($sudoers.Action) -- $($sudoers.Message)"
}
$mounted = @{}
foreach ($t in $tiers) { $mounted[$t.Kind] = $false }
if ($WhatIfPreference -or -not $wrote) {
    foreach ($t in $tiers) {
        Write-Information "      What if: would mount $($t.NetworkPath) at $($t.LocalPath) as '$($t.Account)'."
    }
} else {
    $configDoc  = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Yaml -Ordered
    $mountConfig = @{
        pool  = Get-YurunaPoolStorageConfig  -Config $configDoc -IgnoreReplicate
        stash = Get-YurunaStashStorageConfig -Config $configDoc
    }
    foreach ($t in $tiers) {
        $cfg = $mountConfig[$t.Kind]
        if (-not $cfg) {
            Write-Warning "The $($t.Kind) tier did not resolve back out of $configPath; skipping its mount."
            continue
        }
        # Clear what would otherwise serve this mount from the wrong place. Two
        # kinds, and the second is the one that is invisible: an SMB client keeps
        # ONE session per server name and reuses it, so while any share from the
        # old NAS is still mounted under 'ypool-nas', a mount of the repointed
        # 'ypool-nas' is answered by the OLD session -- it looks for our share on
        # the NAS, does not find it, and mount_smbfs says "No such file or
        # directory". Step 5 repointing the alias does not undo that; only
        # dropping the session does, and the session goes when its mounts do.
        $superseded = @(Get-PoolStorageSupersededMount -Config $cfg)
        $blocked = $false
        foreach ($old in $superseded) {
            $note = if ($old.Reason -eq 'server-session') { "holds the '$($t.Server)' session" } else { 'stands on our mount point' }
            Write-Information "      unmounting $($old.MountPoint) [$($old.Remote)] -- $note..."
            if (-not (Dismount-PoolStoragePoint -MountPoint $old.MountPoint)) {
                # Reported as a failed tier rather than warned about: with the old
                # session still up, the mount below would either fail or -- worse --
                # succeed against the previous server, and "ready" over one of
                # those is the false green this whole step exists to prevent.
                Write-Warning ("Could not unmount $($old.MountPoint) [$($old.Remote)], so the $($t.Kind) tier was left alone: " +
                    "until it goes, '$($t.Server)' keeps resolving to the server that mount was made against.")
                $blocked = $true
                break
            }
        }
        if ($blocked) { continue }
        Write-Information "      mounting $($cfg.NetworkPath) at $($cfg.LocalPath) as '$($t.Account)'..."
        $ok = Connect-YurunaPoolStorage -Config $cfg
        $mounted[$t.Kind] = $ok
        Write-Information "      $($cfg.NetworkPath) at $($cfg.LocalPath): $(if ($ok) { 'mounted' } else { 'FAILED' })"
    }
}

# --- REGION: Summary
Complete-LabStorageStep
$failed = @($tiers | Where-Object { -not $mounted[$_.Kind] })
Write-Information ""
Write-Information "=================================================================="
if ($WhatIfPreference) {
    Write-Information "  -WhatIf: nothing was changed"
} elseif ($failed.Count -eq 0) {
    Write-Information "  Local lab storage ready"
} else {
    Write-Information "  Local lab storage created, but $($failed.Count) share did not mount"
}
Write-Information "=================================================================="
Write-Information ""
Write-Information "Next:"
Write-Information "  1. Validate:  pwsh test/Test-Config.ps1"
if (-not $EnableReplication) {
    Write-Information "  2. To archive finished cycles to the pool share, set"
    Write-Information "     pool.networkReplicate: true in test/test.config.yml (or re-run"
    Write-Information "     this script with -EnableReplication)."
}
Write-Information "  3. Other machines in this lab mount the SAME shares over the LAN."
Write-Information "     They need their hosts entries pointing at THIS machine's LAN"
Write-Information "     address instead of the loopback address, and a copy of"
Write-Information "     $labVault"
Write-Information ""
if ($failed.Count -gt 0 -and -not $WhatIfPreference) {
    Write-Warning "The mount failed for: $(($failed | ForEach-Object { $_.Kind }) -join ', '). See docs/pool-storage.md (Operating & troubleshooting)."
    if ($Platform -eq 'windows') {
        Write-Warning "On Windows an access-denied mount right after this script usually means the NTLM loopback exemption has not taken effect yet -- reboot and re-run."
    }
    exit (Get-EntryPointExitCode -Outcome 'Failure')
}
exit (Get-EntryPointExitCode -Outcome 'Ok')

# Copyright (c) 2019-2026 by Alisson Sol et al.
