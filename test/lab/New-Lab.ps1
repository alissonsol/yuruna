<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 425d0d82-ebe2-4d28-90df-3b22ff1c2915
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
    Create a lab: its storage folders, its credential vault, and its pool-configuration
    repository.

.DESCRIPTION
    See https://yuruna.link/42010605-0003.
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
    pwsh test/lab/New-Lab.ps1 -Name lab-a -Root D:\work
.EXAMPLE
    pwsh test/lab/New-Lab.ps1 -Name lab-b
    # A second lab on a machine that already serves its storage: the root, the
    # folders, and both share credentials come from what is already here.
.EXAMPLE
    pwsh test/lab/New-Lab.ps1 -Name lab-a -Root /srv -User yuruna-pool,yuruna-stash,internal-auth-key
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '../modules/Test.Prelude.psm1') -Global -Force
$paths = Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder
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

# --- REGION: Set-DirectoryPrivate
function Set-DirectoryPrivate {
    <#
    .SYNOPSIS
        Restrict a directory to the current user, before any secret is written into it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    if (-not $PSCmdlet.ShouldProcess($Path, (Format-YurunaOperatorMessage -Key 'runner.operator_258aa0a2968ed154'))) { return }
    if ($IsWindows) {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $output = @(& icacls $Path /inheritance:r /grant:r "*${sid}:(OI)(CI)F" 2>&1)
    } else {
        $output = @(& chmod 700 $Path 2>&1)
    }
    if ($LASTEXITCODE -ne 0) {
        throw ("Cannot secure directory '{0}' (exit {1}): {2}" -f $Path, $LASTEXITCODE, ($output -join ' '))
    }
}

# --- REGION: Storage root
# The vault directory is resolved before the banner because an omitted -Root is
# recovered from a lab vault already in it.
$vaultDir = Join-Path $paths.RepoRoot 'test/status/extension/authentication'

$rootReused = $false
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Get-YurunaLabStorageRoot -VaultDir $vaultDir
    if ([string]::IsNullOrWhiteSpace($Root)) {
        throw "No storage root was given and none could be read from a lab already on this machine. Pass -Root <folder>, or run test/lab/New-LocalLabStorage.ps1 first if this machine serves its own storage."
    }
    $rootReused = $true
}

Write-Output ""
Write-Output "========"
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_76f86f396906afe9' -Arguments @{ name = "$Name" })
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_ec6f1fb93e933915' -Arguments @{ root = "$Root"; machine = "$(if ($rootReused) { ' (from a lab already on this machine)' })" })
Write-Output "========"

# --- REGION: Test-DirectoryWritable
function Test-DirectoryWritable {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Path)
    $probe = Join-Path $Path ".yuruna-write-probe-$PID"
    try {
        $null = New-Item -ItemType File -Path $probe -Force -ErrorAction Stop -WhatIf:$false
        return $true
    } catch {
        return $false
    } finally {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
}

# --- REGION: New-DirectoryWithSudoFallback
function New-DirectoryWithSudoFallback {
    # Also reclaims a directory a previous elevated run left root-owned: every
    # step after this (git init, the vault write) runs unprivileged and needs
    # to write under $Path, so an existing-but-foreign-owned directory is the
    # same problem as a missing one.
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path)
    if ((Test-Path -LiteralPath $Path) -and (Test-DirectoryWritable -Path $Path)) { return }
    if (-not $PSCmdlet.ShouldProcess($Path, (Format-YurunaOperatorMessage -Key 'runner.operator_468e93d8ebdb6930'))) { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        try {
            $null = New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop -WhatIf:$false
            return
        } catch {
            Write-Verbose "New-Item denied for '$Path' ($($_.Exception.Message)); falling back to sudo."
        }
    }
    if (-not ($IsLinux -and (Get-Command sudo -ErrorAction SilentlyContinue))) {
        throw "'$Path' is not writable by the current user and there is no sudo fallback on this platform. Fix ownership by hand and re-run."
    }
    $owner = if ($env:USER) { $env:USER } else { (& id -un) }
    & sudo mkdir -p $Path 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sudo mkdir -p '$Path' failed (exit $LASTEXITCODE)." }
    & sudo chown $owner $Path 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sudo chown $owner '$Path' failed (exit $LASTEXITCODE)." }
}

# --- REGION: Storage folders
$poolPath  = Join-Path $Root 'yuruna.pool'
$stashPath = Join-Path $Root 'yuruna.stash'
foreach ($p in @($Root, $poolPath, $stashPath)) {
    $existed = Test-Path -LiteralPath $p
    New-DirectoryWithSudoFallback -Path $p
    Write-Output "[1/3] $(if ($existed) { 'confirmed' } else { 'created' }) $p"
}

# --- REGION: Pool-configuration repository
# See https://yuruna.link/42010605-0003
$configurationPath = Join-Path $poolPath 'pool-configuration.git'
# Adopt a store created under the older lab-name-derived name rather than
# leaving its seeded history orphaned beside a fresh empty repo.
foreach ($legacyName in @('pool-intent.git', "$Name.intent.git")) {
    $legacyIntentPath = Join-Path $poolPath $legacyName
    if ((Test-Path -LiteralPath $legacyIntentPath) -and -not (Test-Path -LiteralPath $configurationPath)) {
        Move-Item -LiteralPath $legacyIntentPath -Destination $configurationPath
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_4154b8f8b4c44fe5' -Arguments @{ legacyIntentPath = "$legacyIntentPath"; configurationPath = "$configurationPath" })
    }
}
$store = New-YurunaPoolConfigurationStore -Path $configurationPath -Confirm:$false
if ($store.Created) {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_8fcfdcefeec6d978' -Arguments @{ configurationPath = "$configurationPath" })
} else {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_a57aeed80b0cf28a' -Arguments @{ configurationPath = "$configurationPath"; reason = "$($store.Reason)" })
}

# --- REGION: Lab vault
# $vaultDir is under test/status/extension/authentication/ so it inherits the two
# protections the per-host vault already has: the `test/status/*/` gitignore rule,
# and the status service's `extension/*` deny-list entry that keeps it off HTTP. A
# file of the same shape placed anywhere else under test/status/ WOULD be served.
if (-not (Test-Path -LiteralPath $vaultDir)) { $null = New-Item -ItemType Directory -Path $vaultDir -Force }
Set-DirectoryPrivate -Path $vaultDir -Confirm:$false
$labVault = Join-Path $vaultDir "lab.$Name.vault.yml"

if ((Test-Path -LiteralPath $labVault) -and -not $Force) {
    $vault = Get-Content -Raw -LiteralPath $labVault | ConvertFrom-Yaml -Ordered
    if ([int]$vault.schemaVersion -eq 1) {
        $vault.schemaVersion = 2
        if ($vault.lab.Contains('intentGitPath')) {
            $vault.lab.configurationGitPath = $configurationPath
            $vault.lab.Remove('intentGitPath')
        }
        $null = Write-YurunaStateFile -Path $labVault -Content ($vault | ConvertTo-Yaml) -Confirm:$false
    }
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_3ef003e468ca0535' -Arguments @{ labVault = "$labVault" })
} else {
    $nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('schemaVersion: 2')
    $lines.Add('lab:')
    $lines.Add("  name: $(ConvertTo-Json -InputObject $Name -Compress)")
    $lines.Add("  createdUtc: '$nowUtc'")
    $lines.Add("  poolPath: $(ConvertTo-Json -InputObject $poolPath -Compress)")
    $lines.Add("  stashPath: $(ConvertTo-Json -InputObject $stashPath -Compress)")
    $lines.Add("  configurationGitPath: $(ConvertTo-Json -InputObject $configurationPath -Compress)")
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
        # JSON string quoting is valid YAML and preserves reused credentials.
        $lines.Add("    password: $(ConvertTo-Json -InputObject $pw -Compress)")
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
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_b4b4c986060e9c0d' -Arguments @{ labVault = "$labVault"; detail = "$detail" })
}

Write-Output ""
Write-Output "Lab '$Name' ready."
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_4ccbfa081fc1ccc8' -Arguments @{ poolPath = "$poolPath" })
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_be3425294035d6f8' -Arguments @{ stashPath = "$stashPath" })
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_8b14250671a04bd9' -Arguments @{ configurationPath = "$configurationPath" })
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_671e06827d6b0716' -Arguments @{ labVault = "$labVault" })
Write-Output ""
Write-Output "Next:"
# A reused root or a reused credential both mean this machine already carries
# storage for another lab -- its folders are already shared and its accounts
# already exist, so repeating the "share these folders" step would send the
# operator to redo work that is done (and, on a share already in use, to
# second-guess a working configuration).
$storageAlreadyHere = $rootReused -or ($reused -and $reused.Count -gt 0)
if ($storageAlreadyHere) {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_e3487a152e2f3308')
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_2a442af02dcd51fd')
} else {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_eb02e6d6c1eff301' -Arguments @{ poolPath = "$poolPath"; stashPath = "$stashPath" })
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_e8a392f69b5b09a9')
}
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_103bc82ee070925d')
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_3f91d27857293eb6')
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_ae9fe58ef5b4ba36')
exit 0
