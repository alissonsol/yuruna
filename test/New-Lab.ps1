<#PSScriptInfo
.VERSION 2026.07.31
.GUID 42f4c810-93a7-4b62-a15e-7d0c2be64f18
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna lab pool stash vault intent
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
    Create a lab: its storage folders, its credential vault, and its pool-intent
    repository.

.DESCRIPTION
    A lab is a physically local set of hosts, which are then grouped into pools and
    assigned test sets. Bringing one up by hand -- create two folders, share them,
    set ACLs, put passwords in a vault -- leaves nothing to check the result. This
    creates all three consistently and is safe to re-run.

    What it creates under -Root:
      <Root>/yuruna.pool          cycle-output replication + the intent repository
      <Root>/yuruna.stash         the stash service's own durable store
      <Root>/yuruna.pool/<name>.intent.git
                                  bare pool-intent repository, seeded schema-valid.
                                  pool-control service serves this over git:// and that URL
                                  becomes the lab's intentGitUrl.

    The vault it writes is plain YAML protected by filesystem permissions. That is
    deliberate and is the reason this script exists rather than reusing
    Export-Clixml: a lab vault has to be COPYABLE to the other hosts in the lab, and
    DPAPI-bound files do not decrypt on the machine they are copied to. See
    test/schemas/lab.vault.schema.yml.

    Sharing the folders over SMB is left to the operator: it is per-platform, needs
    elevation, and the account it grants is a decision this script should not make.
    The guide covers it. On a machine that serves its own storage,
    test/New-LocalLabStorage.ps1 does that half and calls this script for this one.

    ADDING A LAB TO A MACHINE THAT ALREADY HAS STORAGE. The share accounts are
    machine-wide, not per-lab: one `yuruna-pool` OS account serves every lab whose
    storage lives here. So a credential this machine already has is REUSED rather
    than regenerated -- a fresh random password would be recorded in the new lab
    vault while the OS account, the SMB server, and the other machines in the lab
    all still hold the old one, and every mount using the new vault would fail
    against a share that never had that password.

    Reuse reads the host vault (the store the harness itself reads) through the
    same vaultKey indirection Get-Password uses. It is strictly read-only: a user
    with no stored credential gets a freshly generated one, and no existing value
    is ever overwritten. -Force regenerates the lab vault file but still reuses
    the machine's credentials; rotating a password is a deliberate, separate act
    (Set-Password) that has to reach the OS account and the share too.

    -Root may be omitted once storage exists here: the root is read back from the
    lab vault of a lab already on this machine, so a second lab does not have to
    re-specify where the first one put its folders.

.PARAMETER Name
    Lab name. Same charset as a pool id, so the two cannot disagree.
.PARAMETER Root
    Folder the lab's storage is created under. Optional when another lab on this
    machine already recorded one, which is then reused.
.PARAMETER User
    Credential names to place in the lab vault. Defaults to the two NAS accounts
    every lab needs. A name this machine already has a credential for is reused;
    the rest are generated.
.PARAMETER PasswordLength
    Generated password length. Ignored for a reused credential.
.PARAMETER Force
    Overwrite an existing lab vault for this name. Credentials are still reused,
    not rotated.

.EXAMPLE
    pwsh test/New-Lab.ps1 -Name lab-a -Root D:\work
.EXAMPLE
    pwsh test/New-Lab.ps1 -Name lab-b
    # A second lab on a machine that already serves its storage: the root, the
    # folders, and both share credentials come from what is already here.
.EXAMPLE
    pwsh test/New-Lab.ps1 -Name lab-a -Root /srv -User yuruna-pool,yuruna-stash,lab-auth-token
#>

param(
    [Parameter(Mandatory, Position = 0)]
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,62}$')]
    [string]$Name,

    [Parameter(Position = 1)]
    [string]$Root,

    [string[]]$User = @('yuruna-pool', 'yuruna-stash'),

    [ValidateRange(8, 128)]
    [int]$PasswordLength = 20,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'modules/Test.Prelude.psm1') -Global -Force
$paths = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot
Import-Module (Join-Path $paths.ModulesDir 'Test.PoolAdmin.psm1') -Global -Force
Import-Module (Join-Path $paths.ModulesDir 'Test.StateFile.psm1') -Global -Force
Import-Module (Join-Path $paths.ModulesDir 'Test.Lab.psm1') -Global -Force

# New-RandomPassword lives in the authentication extension; its leading-character
# guard is the reason to reuse it rather than roll a generator here. A password
# starting with a YAML indicator forces the serializer to quote the scalar, and the
# cloud-init seed substitutes the value UNQUOTED, which mangles the guest's
# chpasswd and can abort the cloud-config stage so the VM never gets an IP.
$authExtension = Join-Path $paths.RepoRoot 'test/extension/authentication/default.psm1'
if (-not (Test-Path -LiteralPath $authExtension)) {
    throw "Authentication extension not found at $authExtension."
}
Import-Module $authExtension -Global -Force -DisableNameChecking

function Set-DirectoryPrivate {
    <#
    .SYNOPSIS
        Restrict a directory to the current user, before any secret is written into it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    if (-not $PSCmdlet.ShouldProcess($Path, 'Restrict to the current user')) { return }
    try {
        if ($IsWindows) {
            & icacls $Path /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)F" 2>&1 | Out-Null
        } else {
            & chmod 700 $Path 2>&1 | Out-Null
        }
    } catch {
        Write-Warning "Could not restrict permissions on '$Path': $($_.Exception.Message). The lab vault is plain text -- fix this before copying it anywhere."
    }
}

# --- REGION: storage root
# The vault directory is resolved before the banner because an omitted -Root is
# recovered from a lab vault already in it.
$vaultDir = Join-Path $paths.RepoRoot 'test/status/extension/authentication'

$rootReused = $false
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Get-YurunaLabStorageRoot -VaultDir $vaultDir
    if ([string]::IsNullOrWhiteSpace($Root)) {
        throw "No storage root was given and none could be read from a lab already on this machine. Pass -Root <folder>, or run test/New-LocalLabStorage.ps1 first if this machine serves its own storage."
    }
    $rootReused = $true
}

Write-Output ""
Write-Output "============================================="
Write-Output "  Creating lab '$Name'"
Write-Output "  Root: $Root$(if ($rootReused) { ' (from a lab already on this machine)' })"
Write-Output "============================================="

# --- REGION: storage folders
$poolPath  = Join-Path $Root 'yuruna.pool'
$stashPath = Join-Path $Root 'yuruna.stash'
foreach ($p in @($Root, $poolPath, $stashPath)) {
    if (-not (Test-Path -LiteralPath $p)) {
        $null = New-Item -ItemType Directory -Path $p -Force
        Write-Output "[1/3] created $p"
    } else {
        Write-Output "[1/3] $p already exists"
    }
}

# --- REGION: pool-intent repository
$intentPath = Join-Path $poolPath "$Name.intent.git"
$store = New-YurunaPoolIntentStore -Path $intentPath -Confirm:$false
if ($store.Created) {
    Write-Output "[2/3] pool-intent store seeded at $intentPath"
} else {
    Write-Output "[2/3] pool-intent store already present at $intentPath ($($store.Reason))"
}

# --- REGION: lab vault
# $vaultDir is under test/status/extension/authentication/ so it inherits the two
# protections the per-host vault already has: the `test/status/*/` gitignore rule,
# and the status service's `extension/*` deny-list entry that keeps it off HTTP. A
# file of the same shape placed anywhere else under test/status/ WOULD be served.
if (-not (Test-Path -LiteralPath $vaultDir)) { $null = New-Item -ItemType Directory -Path $vaultDir -Force }
Set-DirectoryPrivate -Path $vaultDir -Confirm:$false
$labVault = Join-Path $vaultDir "lab.$Name.vault.yml"

if ((Test-Path -LiteralPath $labVault) -and -not $Force) {
    Write-Output "[3/3] lab vault already exists at $labVault (use -Force to regenerate)"
} else {
    $nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('schemaVersion: 1')
    $lines.Add('lab:')
    $lines.Add("  name: $Name")
    $lines.Add("  createdUtc: '$nowUtc'")
    $lines.Add("  poolPath: '$poolPath'")
    $lines.Add("  stashPath: '$stashPath'")
    $lines.Add("  intentGitPath: '$intentPath'")
    $lines.Add('users:')
    $reused = [System.Collections.Generic.List[string]]::new()
    foreach ($u in $User) {
        if ($u -notmatch '^[A-Za-z0-9._-]+$') {
            throw "Credential name '$u' is not usable as a vault key (allowed: letters, digits, dot, underscore, hyphen)."
        }
        $pw = Get-YurunaMachineCredential -LogicalUser $u
        if ($pw) {
            $null = $reused.Add($u)
        } else {
            $pw = New-RandomPassword -Length $PasswordLength
        }
        $lines.Add("  ${u}:")
        # Unquoted on purpose: New-RandomPassword never emits a leading YAML
        # indicator, and the value is substituted unquoted downstream.
        $lines.Add("    password: $pw")
        $lines.Add("    previousPassword: ''")
        $lines.Add("    updatedUtc: '$nowUtc'")
    }
    # $null =: the writer returns [bool], which uncaptured would print a bare
    # value into the step lines this script prints.
    $null = Write-YurunaStateFile -Path $labVault -Content (($lines -join "`n") + "`n") -Confirm:$false
    $generatedCount = $User.Count - $reused.Count
    $detail = if ($reused.Count -gt 0) {
        "$generatedCount generated, $($reused.Count) reused from this machine ($($reused -join ', '))"
    } else {
        "$($User.Count) credential(s)"
    }
    Write-Output "[3/3] lab vault written to $labVault ($detail)"
}

Write-Output ""
Write-Output "Lab '$Name' ready."
Write-Output "  pool folder : $poolPath"
Write-Output "  stash folder: $stashPath"
Write-Output "  intent repo : $intentPath"
Write-Output "  lab vault   : $labVault"
Write-Output ""
Write-Output "Next:"
# A reused root or a reused credential both mean this machine already carries
# storage for another lab -- its folders are already shared and its accounts
# already exist, so repeating the "share these folders" step would send the
# operator to redo work that is done (and, on a share already in use, to
# second-guess a working configuration).
$storageAlreadyHere = $rootReused -or ($reused -and $reused.Count -gt 0)
if ($storageAlreadyHere) {
    Write-Output "  1. The folders and the share accounts are already in place on this machine;"
    Write-Output "     this lab reuses them. Confirm with: pwsh test/Test-Config.ps1"
} else {
    Write-Output "  1. Share $poolPath and $stashPath over SMB and grant the lab's NAS accounts."
    Write-Output "     Storage on THIS machine? pwsh test/New-LocalLabStorage.ps1 does that step for you."
}
Write-Output "  2. Set networkStorage.* in test/test.config.yml on each host."
Write-Output "  3. Stand up pool-control service; it serves the intent repo and that URL becomes pool.intentGitUrl."
Write-Output "  See https://yuruna.link/operator and https://yuruna.link/pool-admin."
exit 0
