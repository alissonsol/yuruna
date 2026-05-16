<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456810
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# Default authentication extension: file-backed plaintext vault scoped
# to a single test cycle. Initialize-VaultConnection runs once at cycle
# start; Get-Password / Set-Password / New-RandomPassword are called by
# New-VM scripts and the sequence runner. The runner deletes vault.yml
# at cycle-end on success; on failure the file stays for debugging.
# A named system mutex serializes vault.yml read-modify-write so two
# guests provisioning in parallel cannot race.

$script:VaultDir       = $PSScriptRoot
$script:VaultPath      = Join-Path $script:VaultDir 'vault.yml'
$script:LogDir         = $null
$script:LogPath        = $null
$script:Alphabet       = [char[]]'abcdefghijklmnopqrstuvwxyz0123456789'

function Get-VaultLogPath {
    if ($script:LogPath) { return $script:LogPath }
    $repoRoot = Split-Path -Parent (Split-Path -Parent $script:VaultDir)
    $script:LogDir  = Join-Path $repoRoot 'status/track/extension'
    $script:LogPath = Join-Path $script:LogDir 'authentication.events.log'
    if (-not (Test-Path $script:LogDir)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }
    return $script:LogPath
}

# Append one JSON-line event. Never logs password values. Parameter is
# named EventName because $Event is a PowerShell automatic variable.
function Write-VaultEvent {
    param(
        [Parameter(Mandatory)][ValidateSet('init','get','generate','set','cleanup')][string]$EventName,
        [Parameter(Mandatory)][ValidateSet('hit','miss','ok','error')][string]$Outcome,
        [string]$Username,
        [string]$Detail
    )
    try {
        $rec = [ordered]@{
            ts      = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            event   = $EventName
            outcome = $Outcome
        }
        if ($Username) { $rec.username = $Username }
        if ($Detail)   { $rec.detail   = $Detail }
        Add-Content -Path (Get-VaultLogPath) -Value ($rec | ConvertTo-Json -Compress -Depth 3) -Encoding utf8
    } catch {
        Write-Verbose "Vault log write failed: $($_.Exception.Message)"
    }
}

# Cooperative cross-process lock around vault.yml. SHA1 of the path is
# used as the mutex name so two checkouts under different paths get
# distinct mutexes. .NET named mutexes work cross-platform on PS7.
function Invoke-WithVaultLock {
    param([Parameter(Mandatory)][scriptblock]$Action)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($script:VaultPath.ToLowerInvariant())
        $hash  = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally { $sha.Dispose() }
    $name = "Yuruna.Vault.$hash"
    $mutex = [System.Threading.Mutex]::new($false, $name)
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(30))
        if (-not $acquired) { throw "Vault mutex '$name' could not be acquired within 30 s." }
        return & $Action
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# Read+parse vault.yml (or return an empty shape). Caller already holds
# the lock. Throws on malformed YAML so the cycle fails loudly rather
# than silently overwriting a half-written file.
function Read-VaultUnlocked {
    if (-not (Test-Path $script:VaultPath)) {
        return [ordered]@{ users = [ordered]@{} }
    }
    $raw = Get-Content -Raw $script:VaultPath
    if (-not $raw -or -not $raw.Trim()) {
        return [ordered]@{ users = [ordered]@{} }
    }
    return ($raw | ConvertFrom-Yaml -Ordered)
}

# Atomic write: temp + rename. Caller already holds the lock.
function Write-VaultUnlocked {
    param([System.Collections.IDictionary]$Vault)
    $tmp = "$($script:VaultPath).tmp"
    ($Vault | ConvertTo-Yaml) | Set-Content -Path $tmp -Encoding utf8 -NoNewline
    Move-Item -Path $tmp -Destination $script:VaultPath -Force
}

<#
.SYNOPSIS
    Wipes any existing vault file and creates a fresh empty one for the
    new cycle. Always starts from a clean slate.
.DESCRIPTION
    Each cycle rebuilds every VM, so a vault left over from a previous
    cycle (failed-cycle debugging aid, or a residual file from any
    other source) cannot be valid for the new guests. Wiping at cycle
    start keeps cycle isolation explicit -- the squid-cache's yuruna
    entry is rehydrated from the cross-cycle state file
    (<track>/yuruna-caching-proxy.yml, managed by Test.CachingProxy) on
    its New-VM.ps1's first call, so cross-cycle persistence for that
    one user is unaffected.

    The 'init' event log distinguishes the two cases via Detail:
      'created'  -- no prior vault file existed
      'replaced' -- a prior vault file was deleted before re-creation
#>
function Initialize-VaultConnection {
    Invoke-WithVaultLock -Action {
        $hadPrior = Test-Path $script:VaultPath
        if ($hadPrior) {
            try { Remove-Item -Path $script:VaultPath -Force } catch {
                Write-VaultEvent -EventName 'init' -Outcome 'error' -Detail "remove failed: $($_.Exception.Message)"
                throw
            }
        }
        Write-VaultUnlocked -Vault @{ users = @{} }
        Write-VaultEvent -EventName 'init' -Outcome 'ok' -Detail ($hadPrior ? 'replaced' : 'created')
    }
}

<#
.SYNOPSIS
    Returns a fresh random alphanumeric password. Pure helper, does not
    touch storage.
.DESCRIPTION
    Alphabet is lowercase letters + digits only. Expanding to the
    full scope (uppercase + symbols) is blocked on the macOS UTM/AVF
    GUI sequence's per-character send path dropping or mis-routing
    shifted scancodes, which corrupts the typed password and bricks
    the rotation flow; tracked in docs/todo.md.

    The 'New-' verb is intentional even though the function does not
    mutate system state -- it constructs a fresh value, matching the
    PowerShell convention for object-creation helpers (New-Guid,
    New-Object). PSUseShouldProcessForStateChangingFunctions is
    suppressed for that reason.
#>
function New-RandomPassword {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure value constructor; does not mutate state.')]
    param([int]$Length = 10)
    if ($Length -lt 1) { throw "Length must be >= 1." }
    $sb = [System.Text.StringBuilder]::new($Length)
    for ($i = 0; $i -lt $Length; $i++) {
        $idx = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32(0, $script:Alphabet.Length)
        [void]$sb.Append($script:Alphabet[$idx])
    }
    Write-VaultEvent -EventName 'generate' -Outcome 'ok' -Detail "len=$Length"
    return $sb.ToString()
}

<#
.SYNOPSIS
    Returns the current password for $Username; auto-generates and
    stores one on first call.
#>
function Get-Password {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Username)
    $user = $Username
    return (Invoke-WithVaultLock -Action {
        $vault = Read-VaultUnlocked
        if (-not $vault.Contains('users')) { $vault.users = [ordered]@{} }
        if ($vault.users.Contains($user)) {
            Write-VaultEvent -EventName 'get' -Outcome 'hit' -Username $user
            return [string]$vault.users[$user].password
        }
        $pw = New-RandomPassword
        $vault.users[$user] = [ordered]@{
            password   = $pw
            updatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        }
        Write-VaultUnlocked -Vault $vault
        Write-VaultEvent -EventName 'get' -Outcome 'miss' -Username $user
        return $pw
    })
}

<#
.SYNOPSIS
    Commits a new password as the stored current value for $Username.
.DESCRIPTION
    Plaintext NewPassword is intentional: this vault is the per-cycle
    plaintext store from which cloud-init seeds, console rotation, and
    SSH workloads derive credentials. SecureString cannot survive the
    serialization to vault.yml on disk. The harness runs in a private
    development context (RFC1918 only, gitignored vault, no remote
    serving). Set-Password also genuinely mutates state but the body is
    a single atomic write under a mutex; no -WhatIf support is added
    because the caller (sequence runner) cannot meaningfully cancel
    once the OS has already rotated the password.
#>
function Set-Password {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Single atomic write; no actionable -WhatIf path for the caller.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', '',
        Justification = 'Vault stores plaintext on disk by design; SecureString round-trip would defeat the persistence model.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingUsernameAndPasswordParams', '',
        Justification = 'Identifier+secret pair stored as a vault entry; PSCredential is not appropriate for a YAML-on-disk vault.')]
    param(
        [Parameter(Mandatory)][string]$Username,
        [Parameter(Mandatory)][string]$NewPassword
    )
    $user = $Username
    $pw   = $NewPassword
    Invoke-WithVaultLock -Action {
        $vault = Read-VaultUnlocked
        if (-not $vault.Contains('users')) { $vault.users = [ordered]@{} }
        $vault.users[$user] = [ordered]@{
            password   = $pw
            updatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        }
        Write-VaultUnlocked -Vault $vault
        Write-VaultEvent -EventName 'set' -Outcome 'ok' -Username $user
    }
}

<#
.SYNOPSIS
    Removes the entire vault. Cycle-end success cleanup hook.
#>
function Clear-VaultStorage {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $PSCmdlet.ShouldProcess($script:VaultPath, 'Delete vault file')) { return }
    Invoke-WithVaultLock -Action {
        if (Test-Path $script:VaultPath) {
            Remove-Item -Path $script:VaultPath -Force
        }
        Write-VaultEvent -EventName 'cleanup' -Outcome 'ok'
    }
}

Export-ModuleMember -Function `
    Initialize-VaultConnection, `
    New-RandomPassword, `
    Get-Password, `
    Set-Password, `
    Clear-VaultStorage
