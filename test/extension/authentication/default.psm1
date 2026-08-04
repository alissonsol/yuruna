<#PSScriptInfo
.VERSION 2026.08.04
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456810
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

# Default authentication extension: file-backed plaintext vault simulating
# an EXTERNAL authentication provider. Vault read-modify-write is serialized
# by a named system mutex so parallel guest provisioning cannot race.
# Threat model and full rationale: https://yuruna.link/authentication

# Module file lives at test/extension/authentication/default.psm1; three
# Split-Path -Parent calls reach the repo root.
$script:ExtensionDir   = $PSScriptRoot
$script:RepoRoot       = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $script:ExtensionDir))
$script:VaultDir       = Join-Path -Path $script:RepoRoot -ChildPath 'test' `
                            -AdditionalChildPath 'status', 'extension', 'authentication'
$script:VaultPath      = Join-Path $script:VaultDir 'vault.yml'
$script:LogPath        = Join-Path $script:VaultDir 'events.log'
# users.yml lives alongside vault.yml under status/extension/authentication/;
# the committed template ships next to this .psm1. Bootstrap-from-template
# runs on first Read-UsersConfig so a fresh checkout needs no operator copy.
$script:UsersPath      = Join-Path $script:VaultDir 'users.yml'
$script:UsersTemplate  = Join-Path $script:ExtensionDir 'users.yml.template'
# Cached users.yml parse. Cleared by Reset-UsersConfigCache when callers
# (Test-Config.ps1) want to re-read after editing the file.
$script:UsersConfig    = $null
$script:Alphabet       = [char[]]('abcdefghijklmnopqrstuvwxyz' +
                                  'ABCDEFGHIJKLMNOPQRSTUVWXYZ' +
                                  '0123456789' +
                                  '!@#$%^&*()-_=+')
# Leading-character alphabet: alphanumerics ONLY (no symbols). A symbol in the
# first position -- notably a YAML indicator (! @ # % & *) -- makes the YAML
# serializer single-quote the whole scalar when the vault is written. The
# cloud-init seed then substitutes it UNQUOTED into `password: <value>` via
# literal .Replace (New-CloudInitUserData), where a leading indicator is an
# invalid scalar: it silently mangles the guest's chpasswd (login impossible)
# and can abort the cloud-config stage, so the VM never finishes cloud-init and
# never gets an IP. Interior symbols are safe -- the password has no spaces, so
# no `: ` / ` #` sequence forms and nothing needs quoting -- and the quoting
# characters (' ") are already absent from $script:Alphabet.
$script:AlphabetLeading = [char[]]('abcdefghijklmnopqrstuvwxyz' +
                                   'ABCDEFGHIJKLMNOPQRSTUVWXYZ' +
                                   '0123456789')

function Get-VaultLogPath {
    if (-not (Test-Path $script:VaultDir)) {
        New-Item -ItemType Directory -Path $script:VaultDir -Force | Out-Null
    }
    return $script:LogPath
}

# Append one JSON-line event. Never logs password values. Parameter is
# named EventName because $Event is a PowerShell automatic variable.
function Write-VaultEvent {
    param(
        [Parameter(Mandatory)][ValidateSet('init','get','generate','set','vaultkey')][string]$EventName,
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
        $logPath = Get-VaultLogPath
        # Byte-bounded rotation: caps the live file at LOG_BYTE_LIMIT (1 MB)
        # and keeps .1..10 archives. Test-LogRotationDue throttles the check
        # to a 60 s window, so a tight Write-VaultEvent loop skips the Get-Item.
        if (Get-Command Invoke-LogRotation -ErrorAction SilentlyContinue) {
            $null = Invoke-LogRotation -Path $logPath -Confirm:$false
        }
        Add-Content -Path $logPath -Value ($rec | ConvertTo-Json -Compress -Depth 3) -Encoding utf8
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
    if (-not (Test-Path $script:VaultDir)) {
        New-Item -ItemType Directory -Path $script:VaultDir -Force | Out-Null
    }
    $tmp = "$($script:VaultPath).tmp"
    ($Vault | ConvertTo-Yaml) | Set-Content -Path $tmp -Encoding utf8 -NoNewline
    Move-Item -Path $tmp -Destination $script:VaultPath -Force
}

# === users.yml -- logical -> corporate-identity mapping ====================

<#
.SYNOPSIS
    Adds template-declared, credential-free logical users that a
    pre-existing runtime users.yml has never seen.
.DESCRIPTION
    The template is copied exactly once -- on the first call that finds no
    runtime file. A host provisioned before a logical user was added to the
    template therefore never learns that name, and strict mode refuses the
    cycle over a name the operator was never asked about. Service VMs hit
    this first, because each one arrives with its own administrator.

    Only entries carrying no operator meaning are merged: empty vaultKey,
    empty localOsPasswordRef, empty corporate fields. Anything an operator
    could have curated is left alone, so this can neither overwrite a
    mapping nor introduce a secret -- an entry whose template default is
    inert (lab-auth-token with no vaultKey names an un-enrolled host)
    arrives just as inert.

    The append is textual rather than a YAML round-trip because the runtime
    file is operator-editable and a re-render would discard its comments and
    ordering. It is skipped unless 'users:' is the last top-level key, the
    only shape in which appending at end-of-file lands inside that map.
.OUTPUTS
    None. Best-effort: any failure leaves the file untouched.
#>
function Merge-UsersTemplateEntry {
    [CmdletBinding()]
    param()
    if (-not (Test-Path -LiteralPath $script:UsersPath)) { return }
    if (-not (Test-Path -LiteralPath $script:UsersTemplate)) { return }
    try {
        $liveRaw = Get-Content -Raw -LiteralPath $script:UsersPath
        if (-not $liveRaw -or -not $liveRaw.Trim()) { return }
        $live = $liveRaw | ConvertFrom-Yaml -Ordered
        $tmpl = Get-Content -Raw -LiteralPath $script:UsersTemplate | ConvertFrom-Yaml -Ordered
        if ($live -isnot [System.Collections.IDictionary] -or $tmpl -isnot [System.Collections.IDictionary]) { return }
        if (-not $tmpl.Contains('users') -or $tmpl['users'] -isnot [System.Collections.IDictionary]) { return }
        if (-not $live.Contains('users') -or $live['users'] -isnot [System.Collections.IDictionary]) { return }
        $liveUsers = $live['users']

        $lines = $liveRaw -split "`r?`n"
        $usersLine = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^users:\s*$') { $usersLine = $i; break }
        }
        if ($usersLine -lt 0) { return }
        for ($i = $usersLine + 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^[^\s#]') { return }
        }

        $added = New-Object System.Collections.Generic.List[string]
        $block = New-Object System.Collections.Generic.List[string]
        foreach ($name in $tmpl['users'].Keys) {
            if ($liveUsers.Contains($name)) { continue }
            $rec = $tmpl['users'][$name]
            if ($rec -isnot [System.Collections.IDictionary]) { continue }
            $vk = if ($rec.Contains('vaultKey')) { "$($rec['vaultKey'])".Trim() } else { '' }
            $ref = if ($rec.Contains('localOsPasswordRef')) { "$($rec['localOsPasswordRef'])".Trim() } else { '' }
            if ($vk -or $ref) { continue }
            $corp = if ($rec.Contains('corporate')) { $rec['corporate'] } else { $null }
            if ($corp -is [System.Collections.IDictionary]) {
                $curated = @('domain', 'sam', 'upn') | Where-Object { $corp.Contains($_) -and "$($corp[$_])".Trim() }
                if ($curated) { continue }
            }
            $osUser = if ($rec.Contains('localOsUser')) { "$($rec['localOsUser'])" } else { '' }
            [void]$added.Add([string]$name)
            [void]$block.Add("  ${name}:")
            [void]$block.Add("    localOsUser: `"$osUser`"")
            [void]$block.Add('    corporate:')
            [void]$block.Add('      domain: ""')
            [void]$block.Add('      sam: ""')
            [void]$block.Add('      upn: ""')
            [void]$block.Add('    vaultKey: ""')
            [void]$block.Add('    localOsPasswordRef: ""')
        }
        if ($added.Count -eq 0) { return }
        $prefix = if ($liveRaw.EndsWith("`n")) { '' } else { [Environment]::NewLine }
        Add-Content -LiteralPath $script:UsersPath -Value ($prefix + ($block -join [Environment]::NewLine))
        Write-VaultEvent -EventName 'init' -Outcome 'ok' -Detail "users.yml gained template entries: $($added -join ', ')"
    } catch {
        Write-Verbose "users.yml template merge skipped: $($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Returns the parsed users.yml content (cached). On first call,
    bootstraps users.yml from the committed users.yml.template if the
    runtime file is missing.
.DESCRIPTION
    users.yml maps logical (sequence-level) usernames onto corporate
    identities (Active Directory / Entra / etc.) and onto the vault
    keys that hold the corresponding passwords. The mapping is operator-
    curated; the template ships pre-seeded with the four bundled Yuruna
    logical users (yuuser24, yuuser26, yauser1, ywuser1) plus the four
    service-VM administrators (caching-proxy-service-admin, pool-control-service-admin,
    stash-admin, download-agent-service-admin), all with empty corporate
    fields so the out-of-the-box behavior stays local-only.

    A runtime file that predates an entry gains it through
    Merge-UsersTemplateEntry: the template copy happens only once, so later
    additions would otherwise never reach a host that already has the file.

    The return shape:
        @{ strict = $true; users = @{ <name> = @{ ... } } }
    A missing or malformed file degrades to @{ strict = $true; users = @{} }
    so callers don't have to null-guard; Test-Config.ps1 surfaces the
    parse error separately.
.OUTPUTS
    [hashtable]
#>
function Read-UsersConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    if ($script:UsersConfig) { return $script:UsersConfig }
    # Bootstrap from the committed template on first call.
    if (-not (Test-Path -LiteralPath $script:UsersPath)) {
        if (Test-Path -LiteralPath $script:UsersTemplate) {
            try {
                if (-not (Test-Path -LiteralPath $script:VaultDir)) {
                    New-Item -ItemType Directory -Path $script:VaultDir -Force | Out-Null
                }
                Copy-Item -LiteralPath $script:UsersTemplate -Destination $script:UsersPath -Force
                Write-VaultEvent -EventName 'init' -Outcome 'ok' -Detail 'users.yml bootstrapped from template'
            } catch {
                Write-Warning "Could not bootstrap users.yml from template: $($_.Exception.Message)"
            }
        }
    }
    Merge-UsersTemplateEntry
    $cfg = [ordered]@{ strict = $true; users = [ordered]@{} }
    if (Test-Path -LiteralPath $script:UsersPath) {
        try {
            $raw = Get-Content -Raw -LiteralPath $script:UsersPath
            if ($raw -and $raw.Trim()) {
                $parsed = $raw | ConvertFrom-Yaml -Ordered
                if ($parsed -is [System.Collections.IDictionary]) {
                    if ($parsed.Contains('strict')) { $cfg.strict = [bool]$parsed['strict'] }
                    if ($parsed.Contains('users') -and $parsed['users'] -is [System.Collections.IDictionary]) {
                        $cfg.users = $parsed['users']
                    }
                }
            }
        } catch {
            Write-Warning "users.yml parse failed ($($_.Exception.Message)); proceeding with empty mapping."
        }
    }
    $script:UsersConfig = $cfg
    return $cfg
}

<#
.SYNOPSIS
    Clears the in-process users.yml cache. Use after editing the file
    in a long-running process (status service / dev REPL).
#>
function Reset-UsersConfigCache {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (-not $PSCmdlet.ShouldProcess('users.yml cache', 'Reset')) { return }
    $script:UsersConfig = $null
}

# Internal: resolve a logical user to its mapping entry. Returns a normalized
# hashtable with every field present (empty string when unset), so callers
# never null-guard. An undeclared logical user yields a lenient "local-only"
# entry (localOsUser = logical name, no corporate, no vault overrides).
# Strict-mode enforcement happens in Test-Config; this never throws.
function Resolve-UserMapping {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$LogicalUser)
    $cfg = Read-UsersConfig
    $entry = $null
    if ($cfg.users -and $cfg.users.Contains($LogicalUser)) {
        $entry = $cfg.users[$LogicalUser]
    }
    $localOsUser = $LogicalUser
    $corpDomain  = ''
    $corpSam     = ''
    $corpUpn     = ''
    $vaultKey    = ''
    $localRef    = ''
    if ($entry -is [System.Collections.IDictionary]) {
        if ($entry.Contains('localOsUser') -and "$($entry['localOsUser'])".Trim()) {
            $localOsUser = [string]$entry['localOsUser']
        }
        if ($entry.Contains('corporate') -and $entry['corporate'] -is [System.Collections.IDictionary]) {
            $c = $entry['corporate']
            if ($c.Contains('domain')) { $corpDomain = [string]$c['domain'] }
            if ($c.Contains('sam'))    { $corpSam    = [string]$c['sam'] }
            if ($c.Contains('upn'))    { $corpUpn    = [string]$c['upn'] }
        }
        if ($entry.Contains('vaultKey'))           { $vaultKey = [string]$entry['vaultKey'] }
        if ($entry.Contains('localOsPasswordRef')) { $localRef = [string]$entry['localOsPasswordRef'] }
    }
    # Render loginUser. DOMAIN\sam wins over UPN when both are populated
    # (what Windows login prompts expect). With no corporate identity,
    # loginUser is localOsUser, keeping the local-only behavior where
    # ${loginUser} renders as e.g. "yuuser26".
    if ($corpDomain -and $corpSam) {
        $loginUser = "$corpDomain\$corpSam"
    } elseif ($corpSam) {
        $loginUser = $corpSam
    } elseif ($corpUpn) {
        $loginUser = $corpUpn
    } else {
        $loginUser = $localOsUser
    }
    return @{
        logicalUser        = $LogicalUser
        localOsUser        = $localOsUser
        loginUser          = $loginUser
        corporateDomain    = $corpDomain
        corporateSam       = $corpSam
        corporateUpn       = $corpUpn
        vaultKey           = $vaultKey
        localOsPasswordRef = $localRef
        declared           = [bool]$entry
    }
}

<#
.SYNOPSIS
    Returns the effective identity for a logical user as a hashtable.
.DESCRIPTION
    Sequences call this via the ${ext:authentication.GetEffectiveUser(...)}
    substitution form when they need any individual field (loginUser,
    localOsUser, ...) by itself. For the common case of "give me the
    login string and the password together", prefer Get-LoginCredential.
.OUTPUTS
    [hashtable] with keys: logicalUser, localOsUser, loginUser,
    corporateDomain, corporateSam, corporateUpn, vaultKey,
    localOsPasswordRef, declared.
#>
function Get-EffectiveUser {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$LogicalUser)
    return (Resolve-UserMapping -LogicalUser $LogicalUser)
}

<#
.SYNOPSIS
    Ensures vault.yml exists. Idempotent: a no-op when the file is
    already present.
.DESCRIPTION
    External-auth simulation requires user state to persist across
    cycles -- the harness must never silently delete users or rotate
    passwords without an explicit Set-Password call. This function
    therefore only creates the file when it is absent; an existing
    vault is left untouched and its contents are re-used as-is.

    The 'init' event log distinguishes the two cases via Detail:
      'created'  -- no prior vault file existed, an empty one is written
      'reused'   -- vault file was already present; left untouched
#>
function Initialize-VaultConnection {
    Invoke-WithVaultLock -Action {
        if (Test-Path $script:VaultPath) {
            Write-VaultEvent -EventName 'init' -Outcome 'ok' -Detail 'reused'
            return
        }
        Write-VaultUnlocked -Vault @{ users = @{} }
        Write-VaultEvent -EventName 'init' -Outcome 'ok' -Detail 'created'
    }
}

<#
.SYNOPSIS
    Returns a fresh random password drawn from the full mixed-case
    alphanumeric + symbol alphabet. Pure helper, does not touch
    storage.
.DESCRIPTION
    Alphabet covers a-z, A-Z, 0-9, and the common shifted-symbol set
    `!@#$%^&*()-_=+`. Symbols are limited to characters that survive
    every typing back-end (Hyper-V PS/2 scancodes, KVM libvirt
    send-key, VNC/X11 keysyms) and that don't snag YAML scalar
    quoting in vault.yml or cloud-init user-data. Excluded on
    purpose: quoting characters (`'` `"`), backslash, and YAML/shell
    separators (`:` `,` `<` `>` `|` `;` `~` `` ` ``).

    The FIRST character is drawn from alphanumerics only
    ($script:AlphabetLeading): a symbol there -- notably a YAML
    indicator (! @ # % & *) -- makes the serialized vault value need
    single-quote wrapping, which the literal-.Replace cloud-init bake
    then substitutes UNQUOTED into `password: <value>`, mangling
    chpasswd (login impossible) and stalling cloud-init (no guest IP).
    Interior positions keep the full symbol set.

    The 'New-' verb is intentional even though nothing system-level
    mutates: this constructs a fresh value, matching the PowerShell
    convention for object-creation helpers (New-Guid, New-Object),
    which is why PSUseShouldProcessForStateChangingFunctions is
    suppressed.
#>
function New-RandomPassword {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure value constructor; does not mutate state.')]
    param([int]$Length = 10)
    if ($Length -lt 1) { throw "Length must be >= 1." }
    $sb = [System.Text.StringBuilder]::new($Length)
    for ($i = 0; $i -lt $Length; $i++) {
        # Position 0 draws from alphanumerics only so the value never needs YAML
        # quoting (see the alphabet comment); interior positions use the full set.
        $pool = if ($i -eq 0) { $script:AlphabetLeading } else { $script:Alphabet }
        $idx = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32(0, $pool.Length)
        [void]$sb.Append($pool[$idx])
    }
    Write-VaultEvent -EventName 'generate' -Outcome 'ok' -Detail "len=$Length"
    return $sb.ToString()
}

# Internal: vault lookup keyed by an explicit vault key (NOT the logical user
# name). Get-Password and Get-LocalOsPassword call it after resolving the key
# via users.yml. AutoGenerate decides what a missing entry means: $true (the
# logical/local-OS path) mints and stores a fresh random password; $false (the
# corporate / operator-supplied path) throws, so Test-Config.ps1 surfaces the
# unpopulated vault key instead of the cycle inventing a password AD rejects.
function Get-PasswordByVaultKey {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VaultKey,
        [Parameter(Mandatory)][string]$LogicalUser,
        [bool]$AutoGenerate = $true
    )
    $key = $VaultKey
    # $LogicalUser and $AutoGenerate are consumed inside the -Action scriptblock
    # below via closure capture. PSReviewUnusedParameter doesn't follow
    # scriptblock arguments back to the param block, so touch them here.
    $null = $LogicalUser
    $null = $AutoGenerate
    return (Invoke-WithVaultLock -Action {
        $vault = Read-VaultUnlocked
        if (-not $vault.Contains('users')) { $vault.users = [ordered]@{} }
        if ($vault.users.Contains($key)) {
            Write-VaultEvent -EventName 'get' -Outcome 'hit' -Username $LogicalUser -Detail "vaultKey=$key"
            return [string]$vault.users[$key].password
        }
        if (-not $AutoGenerate) {
            Write-VaultEvent -EventName 'get' -Outcome 'error' -Username $LogicalUser -Detail "vaultKey=$key missing; operator-supplied entry required"
            throw "Authentication vault has no entry for key '$key' (resolved from logical user '$LogicalUser' via users.yml vaultKey). The vault NEVER auto-generates for an operator-supplied vaultKey -- populate vault.yml[users][$key].password manually with the real corporate password before re-running the cycle."
        }
        $pw = New-RandomPassword
        $vault.users[$key] = [ordered]@{
            password         = $pw
            previousPassword = ''
            updatedUtc       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        }
        Write-VaultUnlocked -Vault $vault
        Write-VaultEvent -EventName 'get' -Outcome 'miss' -Username $LogicalUser -Detail "vaultKey=$key"
        return $pw
    })
}

<#
.SYNOPSIS
    Returns the password used at the sequence-login prompt for the
    logical user. Routes through users.yml's `vaultKey` indirection.
.DESCRIPTION
    For a logical user X:
      * users.yml entry missing OR empty vaultKey      -> vault[X]
        (today's behavior: auto-generated on first reference)
      * users.yml entry with non-empty vaultKey K      -> vault[K]
        (NEVER auto-generated; throws if the operator hasn't pre-
        populated the entry, so a missing corporate password is a
        cycle-fatal error rather than a silent random-password mint)

    Cloud-init / New-VM.ps1 callers want a DIFFERENT password (the
    one set on the local OS account at provisioning time, independent
    of any corporate identity). Those call Get-LocalOsPassword which
    routes through `localOsPasswordRef` instead.
#>
function Get-Password {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Username)
    $m = Resolve-UserMapping -LogicalUser $Username
    $key = if ($m.vaultKey) { $m.vaultKey } else { $Username }
    $autoGen = -not $m.vaultKey   # empty vaultKey == legacy auto-gen path
    return (Get-PasswordByVaultKey -VaultKey $key -LogicalUser $Username -AutoGenerate $autoGen)
}

<#
.SYNOPSIS
    Returns the password to set on the LOCAL OS account during
    cloud-init provisioning. Routes through users.yml's
    `localOsPasswordRef` indirection.
.DESCRIPTION
    Default decoupled behavior:
    `localOsPasswordRef` empty -> vault[logicalUser] auto-generated.
    The local OS account on the transient test VM receives a fresh
    random secret that nobody needs to know; sequence-login uses the
    SEPARATE `vaultKey` indirection so corporate plaintext never lands
    in the local /etc/shadow.

    Operator-coupled behavior: set
    `localOsPasswordRef` = same value as `vaultKey` in users.yml when
    you want the local OS account to share its password with the
    corporate identity (e.g. for emergency console access using the
    operator's known corporate password).
#>
function Get-LocalOsPassword {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Username)
    $m = Resolve-UserMapping -LogicalUser $Username
    $key = if ($m.localOsPasswordRef) { $m.localOsPasswordRef } else { $Username }
    # The local OS account always auto-generates: a named-but-unpopulated
    # vault key still mints one. The asymmetry vs Get-Password is intentional
    # -- this password is ours to own, not one to align with a directory.
    return (Get-PasswordByVaultKey -VaultKey $key -LogicalUser $Username -AutoGenerate $true)
}

<#
.SYNOPSIS
    Returns @{ Username; Password } resolved through users.yml so a
    single substitution covers both the login text and the password.
.DESCRIPTION
    Sequence-side convenience for AD-joined scenarios: the login
    prompt receives the corporate identity (DOMAIN\sam or UPN) and
    the matching password in one resolution call.
#>
function Get-LoginCredential {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$LogicalUser)
    $m = Resolve-UserMapping -LogicalUser $LogicalUser
    $pw = Get-Password -Username $LogicalUser
    return @{ Username = $m.loginUser; Password = $pw }
}

<#
.SYNOPSIS
    Commits a new password as the stored current value for $Username.
.DESCRIPTION
    Plaintext NewPassword is intentional: this vault is the per-cycle
    plaintext store from which cloud-init seeds, console rotation, and
    SSH workloads derive credentials, and SecureString cannot survive
    serialization to vault.yml on disk. The harness runs in a private
    development context (RFC1918 only, gitignored vault, no remote
    serving). The body is a single atomic write under a mutex, and no
    -WhatIf is offered: the caller (sequence runner) cannot cancel
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
        # Carry the outgoing password into previousPassword before overwriting.
        # A failed cycle leaves vault.yml on disk, where that field shows
        # whether -- and from what -- the password rotated after New-VM created
        # the entry. Empty the first time a user is written.
        $priorPassword = ''
        if ($vault.users.Contains($user)) {
            $priorPassword = [string]$vault.users[$user].password
        }
        $vault.users[$user] = [ordered]@{
            password         = $pw
            previousPassword = $priorPassword
            updatedUtc       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        }
        Write-VaultUnlocked -Vault $vault
        $setDetail = if ($priorPassword) { 'rotated' } else { 'created' }
        Write-VaultEvent -EventName 'set' -Outcome 'ok' -Username $user -Detail $setDetail
    }
}

<#
.SYNOPSIS
    Read-only: does vault.yml already hold a non-empty password under VaultKey?
.DESCRIPTION
    Peeks the vault WITHOUT auto-generating or creating anything, so a caller can
    distinguish "a real credential is already stored" from "calling Get-Password
    here would silently mint a junk random password". poolStorage's loud-fail
    pre-check uses this to refuse mounting an SMB share with an auto-generated
    password the NAS would reject. Never writes; returns $false for a missing
    vault, missing key, or empty password.
#>
function Test-VaultEntry {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VaultKey)
    $key = $VaultKey
    return (Invoke-WithVaultLock -Action {
        $vault = Read-VaultUnlocked
        if (-not $vault.Contains('users')) { return $false }
        if (-not $vault.users.Contains($key)) { return $false }
        $entry = $vault.users[$key]
        if (-not ($entry -is [System.Collections.IDictionary])) { return $false }
        return -not [string]::IsNullOrEmpty([string]$entry['password'])
    })
}

<#
.SYNOPSIS
    Set (or create) the vaultKey for a logical user in users.yml. Returns
    $true when the file changed, $false when it was already at $VaultKey (or
    under -WhatIf).
.DESCRIPTION
    Idempotent, structured edit of the runtime users.yml this module reads
    ($script:UsersPath), so the mapping the process resolves and this write
    can never diverge on path. Creates a minimal entry when the logical user
    is absent. Clears the in-process users.yml cache so a later resolve in
    THIS runspace sees the change; a SEPARATE long-running process (the
    status service) keeps its own cached copy until restarted, because
    Import-Extension skips re-import once a module is loaded.

    A non-empty vaultKey is the switch that moves an operator-supplied
    credential (e.g. lab-auth-token) off the auto-generate-junk path onto
    the operator-owned path Get-Password/Test-VaultEntry require.
#>
function Set-UserVaultKey {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$LogicalUser,
        [Parameter(Mandatory)][string]$VaultKey
    )
    # Bootstrap users.yml from the template when the runtime file is absent.
    $null = Read-UsersConfig
    $doc = [ordered]@{ strict = $true; users = [ordered]@{} }
    if (Test-Path -LiteralPath $script:UsersPath) {
        $raw = Get-Content -Raw -LiteralPath $script:UsersPath
        if ($raw -and $raw.Trim()) {
            $parsed = $raw | ConvertFrom-Yaml -Ordered
            if ($parsed -is [System.Collections.IDictionary]) { $doc = $parsed }
        }
    }
    if (-not $doc.Contains('users') -or -not ($doc['users'] -is [System.Collections.IDictionary])) {
        $doc['users'] = [ordered]@{}
    }
    $users = $doc['users']
    if (-not $users.Contains($LogicalUser) -or -not ($users[$LogicalUser] -is [System.Collections.IDictionary])) {
        $users[$LogicalUser] = [ordered]@{
            localOsUser        = ''
            corporate          = [ordered]@{ domain = ''; sam = ''; upn = '' }
            vaultKey           = ''
            localOsPasswordRef = ''
        }
    }
    $entry = $users[$LogicalUser]
    $current = if ($entry.Contains('vaultKey')) { [string]$entry['vaultKey'] } else { '' }
    if ($current -eq $VaultKey) { return $false }
    if (-not $PSCmdlet.ShouldProcess("$script:UsersPath [$LogicalUser].vaultKey", "Set to '$VaultKey'")) {
        return $false
    }
    $entry['vaultKey'] = $VaultKey
    $yaml = ConvertTo-Yaml $doc
    [System.IO.File]::WriteAllText($script:UsersPath, $yaml, [System.Text.UTF8Encoding]::new($false))
    $null = Write-VaultEvent -EventName 'vaultkey' -Outcome 'ok' -Username $LogicalUser -Detail "vaultKey=$VaultKey"
    Reset-UsersConfigCache -Confirm:$false
    return $true
}

Export-ModuleMember -Function `
    Initialize-VaultConnection, `
    New-RandomPassword, `
    Get-Password, `
    Get-LocalOsPassword, `
    Get-LoginCredential, `
    Get-EffectiveUser, `
    Test-VaultEntry, `
    Read-UsersConfig, `
    Reset-UsersConfigCache, `
    Set-Password, `
    Set-UserVaultKey
