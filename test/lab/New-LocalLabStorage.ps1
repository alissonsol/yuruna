<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 425548c6-683c-4519-9712-2f32b36e15e8
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
    See https://yuruna.link/42010605-0003.
.PARAMETER Root
    Storage root, skipping the prompt. Omit it for the interactive prompt,
    which offers this platform's convention as the default.

.PARAMETER LabName
    Lab name passed to New-Lab.ps1 (lowercase letters, digits, hyphens).
    Defaults to this machine's host name, normalized to that charset.

.PARAMETER MoveLogs
    Select MOVE mode for the pool tier: each finished cycle is copied to the
    share, verified, and then deleted locally, so the share holds the only copy.
    Off by default (copy mode keeps the local folder) -- move mode makes a broken
    or full share stop cycles rather than merely warn. Writing the pool paths
    already turns archiving on; this only chooses the mode.

.PARAMETER Force
    Skip this script's own confirmation prompts, including the local-only
    warning. The operating system may still prompt (UAC consent, sudo
    password).

.EXAMPLE
    pwsh test/lab/New-LocalLabStorage.ps1
    # The common case: confirms the local-only warning, asks where storage
    # should live, and does everything else unattended.

.EXAMPLE
    pwsh test/lab/New-LocalLabStorage.ps1 -Root /srv/yuruna -MoveLogs
    # Non-interactive about the location, and archives in move mode.

.EXAMPLE
    pwsh test/lab/New-LocalLabStorage.ps1 -WhatIf
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
    [switch]$MoveLogs,
    [switch]$Force
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# --- REGION: Log level from environment
# See https://yuruna.link/42010605-0003
Import-Module (Join-Path $PSScriptRoot '../modules/Test.LogLevel.psm1') -Global -Force -DisableNameChecking
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
Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force
$paths = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
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

# --- REGION: Confirm-Step
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
# See https://yuruna.link/42010605-0003
$Script:StepTimer = [System.Diagnostics.Stopwatch]::new()

# --- REGION: Complete-LabStorageStep
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

# --- REGION: Write-LabStorageStep
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

# --- REGION: Test-IsElevated
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
Write-Information "========"
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_2aaf7049d95f40bd')
Write-Information "========"
Write-Information ""
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_8afd8c38c3b8731d')
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_023108e4be9f3912')
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_9476575e311f2d3e')
Write-Information ""
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_6068a5ddfdf6d6e5')
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_93c79167e83d00ed')
Write-Information ""
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_58b4a3724ed799af')
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_c5d900851d3d42ed')
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_42cc6832338a82ba')
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_c99546cd0b6770c1')
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_1e9af1644d738edc')
Write-Information ""
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_ed4603d7c4fbd0cd')
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b54150c020377016' -Arguments @{ else = "$(if ($Platform -eq 'windows') { ', two registry values' } else { '' })" })
Write-Information ""
if ($WhatIfPreference) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_5dd7c992e8f01cbf')
} elseif (-not (Confirm-Step -Question "The storage for this lab is LOCAL to this machine. Continue" -SkipPrompt $Force.IsPresent)) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_04265e41f16edc05')
    exit (Get-EntryPointExitCode -Outcome 'Ok')
}

# --- REGION: Elevation -- sudo arm
# The password is spent HERE: after the operator has consented to a local-only
# change, but ahead of the storage-root prompt and every state change, so the
# rest of the run needs no further attention. -WhatIf is a dry run and must not
# spend a sudo authentication; the ShouldProcess messages describe what a real
# run would do.
if ($WhatIfPreference) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_85f773939904ad98')
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
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_9c1ed292a1d4be12')
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_0f3a9b6b8be0ca79' -Arguments @{ poolAccount = "$PoolAccount"; stashAccount = "$StashAccount" })
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_991c952416c4a937')
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_3a2e2fe3744a8041')
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
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_74909a37781500c7' -Arguments @{ systemDrive = "$systemDrive" })
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_212e789fdf43dbc6')
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_9d6fc2cc7c948ae2')
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_d326284fec834a78')
        }
    }
    Write-Information ""
    $answer = Read-Host (Format-YurunaOperatorMessage -Key 'runner.operator_78bb755d4fa4c047' -Arguments @{ suggested = "$suggested" })
    $Root = if ([string]::IsNullOrWhiteSpace($answer)) { $suggested } else { $answer.Trim() }
}
$Root = $Root.Trim()
if ([string]::IsNullOrWhiteSpace($Root)) { throw "A storage root is required." }
$Root = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root)

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
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_03e696b55b8c6579' -Arguments @{ labName = "$LabName" })
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_5f87f120a40e8157' -Arguments @{ root = "$Root" })
foreach ($t in $tiers) {
    Write-Information "  $($t.Kind.PadRight(5)) : $($t.FolderPath)"
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_4aad448ce6d21c71' -Arguments @{ shareName = "$($t.ShareName)"; account = "$($t.Account)"; networkPath = "$($t.NetworkPath)"; localPath = "$($t.LocalPath)" })
}
Write-Information ""

# --- REGION: Step 1 -- folders, lab vault, pool-configuration repository
# Delegated to New-Lab so the folder layout, the vault schema, and the seeded
# configuration repository have exactly one implementation. Its generated passwords
# become the two share credentials below.
Write-LabStorageStep -Number 1 -Title 'Lab storage folders, lab vault, and pool-configuration repository'
$newLab = Join-Path $PSScriptRoot 'New-Lab.ps1'
if (-not (Test-Path -LiteralPath $newLab)) { throw "New-Lab.ps1 not found at $newLab." }
if ($WhatIfPreference) {
    # New-Lab takes a plain param block, so it has no -WhatIf to forward to.
    # Describing the call is the dry run; invoking it would create the folders.
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_945bb3e94bf9f06d' -Arguments @{ labName = "$LabName"; root = "$Root"; poolAccount = "$PoolAccount"; stashAccount = "$StashAccount" })
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
    foreach ($t in $tiers) { Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_371575ad8c14edb8' -Arguments @{ account = "$($t.Account)"; folderPath = "$($t.FolderPath)" }) }
} else {
    foreach ($t in $tiers) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_fe666771e4980c5b' -Arguments @{ account = "$($t.Account)"; folderPath = "$($t.FolderPath)" })
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
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_50a159114961f9a1' -Arguments @{ account = "$($t.Account)" })
        $verdict = Test-LocalLabStorageSmbAuth -Account $t.Account -Password ([string]$labPassword[$t.Account])
        if ($verdict -eq 'auth') {
            # A refusal HERE is the real thing: the account exists, the password is
            # the vault's, and the sharepoint it authenticates against was
            # published above. That is the only point in the run where deleting
            # the account is justified, so it is the only place that does it.
            Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_c03297466bf30bf9' -Arguments @{ account = "$($t.Account)" })
            if (Reset-LocalLabStorageAccount -Name $t.Account -Password ([string]$labPassword[$t.Account]) `
                    -Description "Yuruna $($t.Kind) storage" -Confirm:$false) {
                # The folder grant is per-account and the account is a new one.
                $null = Set-LocalLabStorageFolderAccess -Tier $t
                $verdict = Test-LocalLabStorageSmbAuth -Account $t.Account -Password ([string]$labPassword[$t.Account])
            }
        }
        switch ($verdict) {
            'ok'          { Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_5833b283f23b8ad6' -Arguments @{ account = "$($t.Account)" }) }
            'auth'        {
                # See https://yuruna.link/42010605-0003
                throw ("'$($t.Account)' carries a password record but the SMB server still refuses it, so the $($t.Kind) share cannot be mounted. " +
                       "The account and its password are in $labVault.")
            }
            'unreachable' { Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_3e112f1a7b94390b' -Arguments @{ account = "$($t.Account)" }) }
            default       { Write-Verbose "SMB auth probe for '$($t.Account)': $verdict" }
        }
    }
}

# --- REGION: Step 5 -- loopback reachability
Write-LabStorageStep -Number 5 -Title 'Loopback reachability'
$aliasCount = Set-LocalLabStorageHostAlias -RepoRoot $paths.RepoRoot -Name @($PoolServer, $StashServer)
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_eb395853b2605723' -Arguments @{ aliasCount = "$aliasCount" })
if ($Platform -eq 'windows') {
    $loopback = Set-LocalLabStorageLoopbackException -Name @($PoolServer, $StashServer)
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_e65ab9d1c0be44ef' -Arguments @{ loopback = "$loopback" })
    $linked = Set-LocalLabStorageLinkedConnection
    Write-Information "      EnableLinkedConnections: $linked"
    if ($linked -eq 'updated') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_09f40058a4152d34')
    }
}

# --- REGION: Step 6 -- vault
# A non-empty vaultKey is what takes Get-Password off the auto-generate path.
# Without it a missing entry silently mints a random password, and every mount
# fails against a share that never had that credential.
Write-LabStorageStep -Number 6 -Title 'Vault'
if ($WhatIfPreference) {
    foreach ($t in $tiers) { Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_505ccadf1de096e0' -Arguments @{ account = "$($t.Account)"; vaultKey = "$($t.VaultKey)" }) }
} else {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_617cd0cc79f8a3aa')
    Initialize-VaultConnection
    foreach ($t in $tiers) {
        $changed = Set-UserVaultKey -LogicalUser $t.Account -VaultKey $t.VaultKey -Confirm:$false
        Set-Password -Username $t.VaultKey -NewPassword ([string]$labPassword[$t.Account])
        $note = if ($changed) { 'vaultKey mapped' } else { 'vaultKey already correct' }
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_7206039f449ff3cc' -Arguments @{ account = "$($t.Account)"; vaultKey = "$($t.VaultKey)"; note = "$note" })
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
    $template = Join-Path $PSScriptRoot '../test.config.yml.template'
    if (Test-Path -LiteralPath $template) {
        Copy-Item -LiteralPath $template -Destination $configPath -Force
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_0662379096e5f8cc')
    }
}
$wrote = Set-LocalLabStorageConfigValue -ConfigPath $configPath -Tier $tiers -MoveLogs:$MoveLogs
if ($wrote) {
    foreach ($t in $tiers) {
        Write-Information "      $($t.ConfigPrefix)NetworkPath: $($t.NetworkPath)"
        Write-Information "      $($t.ConfigPrefix)NetworkUser: $($t.Account)"
        Write-Information "      $($t.ConfigPrefix)LocalPath  : $($t.LocalPath)"
    }
    Write-Information "      moveLogsToPoolStorage: $([bool]$MoveLogs)"
}

# --- REGION: Step 8 -- mount
# See https://yuruna.link/42010605-0003
Write-LabStorageStep -Number 8 -Title 'Mount'
if ($IsLinux) {
    # See https://yuruna.link/42010605-0003
    $sudoers = Set-PoolStorageSudoers -NonInteractive:(-not (Test-YurunaCanPrompt)) -WhatIf:$WhatIfPreference
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_c70a278ff660af73' -Arguments @{ action = "$($sudoers.Action)"; message = "$($sudoers.Message)" })
}
$mounted = @{}
foreach ($t in $tiers) { $mounted[$t.Kind] = $false }
if ($WhatIfPreference -or -not $wrote) {
    foreach ($t in $tiers) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_b641c763e543a0f7' -Arguments @{ networkPath = "$($t.NetworkPath)"; localPath = "$($t.LocalPath)"; account = "$($t.Account)" })
    }
} else {
    $configDoc  = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Yaml -Ordered
    $mountConfig = @{
        pool  = Get-YurunaPoolStorageConfig  -Config $configDoc
        stash = Get-YurunaStashStorageConfig -Config $configDoc
    }
    foreach ($t in $tiers) {
        $cfg = $mountConfig[$t.Kind]
        if (-not $cfg) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_d86220aef2724166' -Arguments @{ kind = "$($t.Kind)"; configPath = "$configPath" })
            continue
        }
        # See https://yuruna.link/42010605-0003
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
                Write-Warning ((Format-YurunaOperatorMessage -Key 'runner.operator_7eb620577dbc6b59' -Arguments @{ mountPoint = "$($old.MountPoint)"; remote = "$($old.Remote)"; kind = "$($t.Kind)"; server = "$($t.Server)" }))
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
Write-Information "========"
if ($WhatIfPreference) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_3d948aab566ac2da')
} elseif ($failed.Count -eq 0) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_849afde193574fb0')
} else {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_0c2563432acd6897' -Arguments @{ count = "$($failed.Count)" })
}
Write-Information "========"
Write-Information ""
Write-Information "Next:"
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_6b74a80cbd7dbcb7')
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_a4bcb961c720c665')
if (-not $MoveLogs) {
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_e2174bc99a4ce57e')
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_bce901e7a9cde02e')
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_a21c13da46635b03')
}
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_79de44609e5248d4')
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_8b5c070b4b3e57dc')
Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_936654f35dc1384e')
Write-Information "     $labVault"
Write-Information ""
if ($failed.Count -gt 0 -and -not $WhatIfPreference) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_30db5523f6c10308' -Arguments @{ join = "$(($failed | ForEach-Object { $_.Kind }) -join ', ')" })
    if ($Platform -eq 'windows') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.operator_bcb4366f0c81a203')
    }
    exit (Get-EntryPointExitCode -Outcome 'Failure')
}
exit (Get-EntryPointExitCode -Outcome 'Ok')

# Copyright (c) 2019-2026 by Alisson Sol et al.
