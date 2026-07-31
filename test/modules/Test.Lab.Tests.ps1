<#PSScriptInfo
.VERSION 2026.07.31
.GUID 42d1e7b3-5a94-4c26-b0f8-3e17a9d5c082
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna lab vault intent pester
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
    Lab creation: the intent store's git settings, the lab vault's shape, and
    Test.Lab.psm1 -- storage-root discovery and the machine-credential reuse
    that keeps a second lab from minting a conflicting password.
.DESCRIPTION
    Each assertion here stands for a failure that is silent in production:
    a store seeded at the wrong schemaVersion reads fine and fails every write; a
    store without receive.updateServerInfo serves stale refs to runners after the
    first push; a password starting with a YAML indicator survives the vault
    only to mangle a guest's chpasswd during cloud-init; and a regenerated share
    credential produces a lab vault that disagrees with the OS account, the SMB
    server, and every machine the earlier vault was copied to.

    The credential lookup is exercised with STUB authentication commands rather
    than the real extension: that module binds its vault path at import time from
    its own location, so a test using it would read -- and, on the auto-generate
    path this function exists to avoid, WRITE -- the developer's real vault.
#>

$ErrorActionPreference = 'Stop'
$testRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'Test.PoolAdmin.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.Lab.psm1') -Force -DisableNameChecking

# Stubs for the authentication extension. The FUNCTIONS are global because that
# is the only session state the module under test can reach: it looks a command
# up in its own scope first and then falls back to global, so a merely
# script-scoped function would never be found. Their STATE stays script-scoped --
# a function keeps the scope chain of the file that defined it, so $script: here
# still resolves to this file even when the module invokes the stub.
$script:StubVault = @{}
$script:StubUserMap = @{}
$script:StubGetPasswordCalled = $false
function global:Test-VaultEntry { param([string]$VaultKey) return $script:StubVault.ContainsKey($VaultKey) }
function global:Get-Password {
    param([string]$Username)
    $script:StubGetPasswordCalled = $true
    $k = if ($script:StubUserMap.ContainsKey($Username)) { $script:StubUserMap[$Username] } else { $Username }
    if (-not $script:StubVault.ContainsKey($k)) { throw "no entry for $k" }
    return $script:StubVault[$k]
}
function global:Get-EffectiveUser {
    param([string]$LogicalUser)
    $k = if ($script:StubUserMap.ContainsKey($LogicalUser)) { $script:StubUserMap[$LogicalUser] } else { '' }
    return @{ vaultKey = $k }
}

# Helpers sit at file scope, above the first Describe: a Describe body runs during
# the discovery pass and everything it declares is discarded before the first It.
function New-TempLabDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: creates a throwaway temp directory the test removes again; there is no operator-facing action to confirm.')]
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $p = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-labtest-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $p -Force
    return $p
}

function Write-TestLabVault {
    param([string]$Dir, [string]$Name, [string]$PoolPath)
    $body = "schemaVersion: 1`nlab:`n  name: $Name`n  poolPath: '$PoolPath'`nusers: {}`n"
    $path = Join-Path $Dir "lab.$Name.vault.yml"
    [IO.File]::WriteAllText($path, $body, [Text.UTF8Encoding]::new($false))
    return $path
}

Describe 'New-YurunaPoolIntentStore' {
    $work = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-lab-t-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $store = Join-Path $work 'x.intent.git'
    $created = New-YurunaPoolIntentStore -Path $store -Confirm:$false

    It 'creates a bare repository on main' {
        $created.Created | Should -Be $true
        (& git -C $store symbolic-ref --short HEAD) | Should -Be 'main'
    }
    It 'seeds pools.yml at schemaVersion 2' {
        # A store seeded at 1 READS fine -- nothing validates on read -- and then
        # fails every write at schema validation, so the UI looks healthy right up
        # until the operator creates a pool.
        ((& git -C $store show main:pools.yml) -join "`n") | Should -Match 'schemaVersion:\s*2'
    }
    It 'sets core.fileMode false so a NAS mount does not look like a permission change' {
        (& git -C $store config core.fileMode) | Should -Be 'false'
    }
    It 'sets receive.updateServerInfo so dumb-HTTP refs do not go stale after a push' {
        # The usual post-update hook never becomes executable on a CIFS mount, so
        # without this readers keep being served the refs from before the push.
        (& git -C $store config receive.updateServerInfo) | Should -Be 'true'
    }
    It 'is clonable the way a runner clones it' {
        $clone = Join-Path $work 'clone'
        & git clone --depth 1 --quiet -- $store $clone 2>&1 | Out-Null
        (Test-Path (Join-Path $clone 'pools.yml')) | Should -Be $true
    }
    It 'is idempotent: a second call leaves the existing repository alone' {
        $again = New-YurunaPoolIntentStore -Path $store -Confirm:$false
        $again.Created | Should -Be $false
    }

    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'New-Lab writes a usable lab vault' {
    $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $work = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-lab-v-$stamp")
    $labName = 'pester-lab'
    $vault = Join-Path $testRoot "status/extension/authentication/lab.$labName.vault.yml"
    # Credential names unique to this run. The subject here is what New-Lab
    # GENERATES, and the default names (yuruna-pool / yuruna-stash) are exactly
    # the ones a machine that already serves storage holds a credential for --
    # which New-Lab reuses by design, so those assertions would be measuring an
    # operator's existing password instead of the generator. Unique names cannot
    # collide with anything on the machine, and touch no real vault entry.
    $u1 = "pester-cred-a-$stamp"
    $u2 = "pester-cred-b-$stamp"
    $labScript = Join-Path $testRoot 'New-Lab.ps1'
    # Invoked through -Command, not -File: with -File every argument arrives as a
    # literal string, so a comma-separated -User would bind as ONE name.
    & pwsh -NoProfile -Command "& `"$labScript`" -Name `"$labName`" -Root `"$work`" -User `"$u1`",`"$u2`"" 2>&1 | Out-Null

    It 'writes the vault where the gitignore and the status-service deny-list already cover it' {
        # test/status/*/ is gitignored and 'extension/*' is denied over HTTP. The
        # same file placed elsewhere under test/status/ would be SERVED.
        (Test-Path $vault) | Should -Be $true
    }
    It 'produces a parseable document carrying the lab identity' {
        $doc = Get-Content -Raw $vault | ConvertFrom-Yaml -Ordered
        $doc.schemaVersion | Should -Be 1
        $doc.lab.name      | Should -Be $labName
        $doc.users.Keys.Count | Should -BeGreaterThan 0
    }
    It 'records the storage root it was given, so a later lab can adopt it' {
        $doc = Get-Content -Raw $vault | ConvertFrom-Yaml -Ordered
        # @() around the call: PowerShell unrolls a single-element array on
        # return, so an unwrapped [0] would index the first CHARACTER of the
        # root string instead of the first root.
        $roots = @(Select-YurunaLabStorageRoot -PoolPath @([string]$doc.lab.poolPath))
        $roots[0] | Should -Be $work
    }
    It 'never generates a password starting with a YAML indicator' {
        # Such a value forces the serializer to quote the scalar, and the cloud-init
        # seed substitutes it UNQUOTED -- which mangles the guest's chpasswd and can
        # abort the cloud-config stage so the VM never gets an IP.
        $doc = Get-Content -Raw $vault | ConvertFrom-Yaml -Ordered
        foreach ($k in $doc.users.Keys) {
            $doc.users[$k].password | Should -Not -Match '^[!@#%&*\-?:,\[\]{}|>''"`]'
            $doc.users[$k].password.Length | Should -BeGreaterThan 8
        }
    }
    It 'gives each credential a distinct password' {
        $doc = Get-Content -Raw $vault | ConvertFrom-Yaml -Ordered
        $pw = @($doc.users.Keys | ForEach-Object { $doc.users[$_].password })
        ($pw | Select-Object -Unique).Count | Should -Be $pw.Count
    }

    Remove-Item $vault -Force -ErrorAction SilentlyContinue
    Remove-Item $work  -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Select-YurunaLabStorageRoot' {
    It 'reduces a lab pool path to its storage root' {
        $r = @(Select-YurunaLabStorageRoot -PoolPath @('/srv/yuruna/yuruna.pool'))
        $r.Count  | Should -Be 1
        $r[0]     | Should -Be '/srv/yuruna'
    }
    It 'collapses labs that agree to a single root' {
        @(Select-YurunaLabStorageRoot -PoolPath @('/srv/yuruna/yuruna.pool', '/srv/yuruna/yuruna.pool')).Count | Should -Be 1
    }
    It 'keeps labs that disagree separate, so the caller refuses to guess' {
        # Guessing would put a new lab's folders somewhere its siblings are not --
        # exactly the mistake an inferred root exists to prevent.
        @(Select-YurunaLabStorageRoot -PoolPath @('/srv/yuruna/yuruna.pool', '/data/lab/yuruna.pool')).Count | Should -Be 2
    }
    It 'handles a Windows path on any host' {
        # Split-Path recognizes only the RUNNING platform's separator, so a
        # Windows-written vault read elsewhere would yield no root at all.
        @(Select-YurunaLabStorageRoot -PoolPath @('D:\Shares\yuruna\yuruna.pool'))[0] | Should -Be 'D:\Shares\yuruna'
    }
    It 'tolerates a trailing separator' {
        @(Select-YurunaLabStorageRoot -PoolPath @('/srv/yuruna/yuruna.pool/'))[0] | Should -Be '/srv/yuruna'
    }
    It 'reports a share sitting directly at the filesystem root' {
        @(Select-YurunaLabStorageRoot -PoolPath @('/yuruna.pool'))[0] | Should -Be '/'
    }
    It 'ignores blank and parentless entries' {
        @(Select-YurunaLabStorageRoot -PoolPath @('', '   ', 'yuruna.pool', '/srv/yuruna/yuruna.pool')).Count | Should -Be 1
    }
    It 'returns nothing for no input' {
        @(Select-YurunaLabStorageRoot -PoolPath @()).Count | Should -Be 0
    }
}

Describe 'Resolve-YurunaLabVaultKey' {
    It 'uses the mapped vaultKey when one is set' {
        Resolve-YurunaLabVaultKey -LogicalUser 'yuruna-pool' -MappedVaultKey 'smb.yuruna-pool' | Should -Be 'smb.yuruna-pool'
    }
    It 'falls back to the user name when the mapping is empty' {
        Resolve-YurunaLabVaultKey -LogicalUser 'yuruna-pool' -MappedVaultKey '' | Should -Be 'yuruna-pool'
    }
    It 'treats a whitespace-only mapping as unset' {
        Resolve-YurunaLabVaultKey -LogicalUser 'yuruna-pool' -MappedVaultKey '   ' | Should -Be 'yuruna-pool'
    }
    It 'falls back when no mapping is supplied at all' {
        Resolve-YurunaLabVaultKey -LogicalUser 'yuruna-pool' | Should -Be 'yuruna-pool'
    }
    It 'trims a mapped key' {
        Resolve-YurunaLabVaultKey -LogicalUser 'x' -MappedVaultKey '  smb.x  ' | Should -Be 'smb.x'
    }
}

Describe 'Get-YurunaLabVaultPassword' {
    $dir = New-TempLabDir
    $good = Join-Path $dir 'lab.good.vault.yml'
    [IO.File]::WriteAllText($good,
        "schemaVersion: 1`nlab:`n  name: good`nusers:`n  yuruna-pool:`n    password: p1`n  yuruna-stash:`n    password: s1`n",
        [Text.UTF8Encoding]::new($false))
    $notAVault = Join-Path $dir 'lab.plain.vault.yml'
    [IO.File]::WriteAllText($notAVault, "just: a scalar`n", [Text.UTF8Encoding]::new($false))

    It 'reads every credential out of a lab vault' {
        $m = Get-YurunaLabVaultPassword -Path $good
        $m['yuruna-pool']  | Should -Be 'p1'
        $m['yuruna-stash'] | Should -Be 's1'
    }
    It 'returns an empty map for a missing file rather than throwing' {
        (Get-YurunaLabVaultPassword -Path (Join-Path $dir 'absent.vault.yml')).Count | Should -Be 0
    }
    It 'returns an empty map for a document that is not a lab vault' {
        (Get-YurunaLabVaultPassword -Path $notAVault).Count | Should -Be 0
    }

    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Get-YurunaLabStorageRoot' {
    It 'adopts the root when every lab on the machine agrees' {
        $d = New-TempLabDir
        try {
            $null = Write-TestLabVault -Dir $d -Name 'lab-a' -PoolPath '/srv/yuruna/yuruna.pool'
            $null = Write-TestLabVault -Dir $d -Name 'lab-b' -PoolPath '/srv/yuruna/yuruna.pool'
            Get-YurunaLabStorageRoot -VaultDir $d | Should -Be '/srv/yuruna'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'refuses to guess when the labs disagree' {
        $d = New-TempLabDir
        try {
            $null = Write-TestLabVault -Dir $d -Name 'lab-a' -PoolPath '/srv/yuruna/yuruna.pool'
            $null = Write-TestLabVault -Dir $d -Name 'lab-b' -PoolPath '/data/lab/yuruna.pool'
            Get-YurunaLabStorageRoot -VaultDir $d -WarningAction SilentlyContinue | Should -Be ''
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'returns nothing when the machine has no lab yet' {
        $d = New-TempLabDir
        try { Get-YurunaLabStorageRoot -VaultDir $d | Should -Be '' }
        finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'returns nothing when the vault directory does not exist' {
        Get-YurunaLabStorageRoot -VaultDir (Join-Path ([IO.Path]::GetTempPath()) 'yuruna-no-such-dir-42') | Should -Be ''
    }
    It 'still answers when one vault file is corrupt' {
        # One unreadable file must not block a machine whose other labs answer.
        $d = New-TempLabDir
        try {
            $null = Write-TestLabVault -Dir $d -Name 'lab-a' -PoolPath '/srv/yuruna/yuruna.pool'
            [IO.File]::WriteAllText((Join-Path $d 'lab.bad.vault.yml'), "lab:`n  - [broken`n", [Text.UTF8Encoding]::new($false))
            Get-YurunaLabStorageRoot -VaultDir $d | Should -Be '/srv/yuruna'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'ignores files that are not lab vaults' {
        # The host vault lives in the same folder and must never be mistaken for one.
        $d = New-TempLabDir
        try {
            $null = Write-TestLabVault -Dir $d -Name 'lab-a' -PoolPath '/srv/yuruna/yuruna.pool'
            [IO.File]::WriteAllText((Join-Path $d 'vault.yml'), "users:`n  x:`n    password: p`n", [Text.UTF8Encoding]::new($false))
            Get-YurunaLabStorageRoot -VaultDir $d | Should -Be '/srv/yuruna'
        } finally { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-YurunaMachineCredential' {
    It 'returns the password the machine already holds, resolved through the vaultKey' {
        # Stored under the MAPPED key only: a lookup by bare user name would miss
        # it, and the caller would mint a password the share never had.
        $script:StubVault = @{ 'smb.yuruna-pool' = 'kept-secret' }
        $script:StubUserMap = @{ 'yuruna-pool' = 'smb.yuruna-pool' }
        Get-YurunaMachineCredential -LogicalUser 'yuruna-pool' | Should -Be 'kept-secret'
    }
    It 'finds a credential stored under the bare user name when no vaultKey is mapped' {
        $script:StubVault = @{ 'yuruna-stash' = 'legacy-value' }
        $script:StubUserMap = @{}
        Get-YurunaMachineCredential -LogicalUser 'yuruna-stash' | Should -Be 'legacy-value'
    }
    It 'returns empty when the machine holds nothing for the user' {
        $script:StubVault = @{}
        $script:StubUserMap = @{}
        Get-YurunaMachineCredential -LogicalUser 'lab-auth-token' | Should -Be ''
    }
    It 'never reaches Get-Password when no entry exists, so nothing is auto-generated' {
        # Get-Password on a vaultKey-less user with no entry CREATES one as a side
        # effect. Reporting on a credential must not bring it into being.
        $script:StubVault = @{}
        $script:StubUserMap = @{}
        $script:StubGetPasswordCalled = $false
        Get-YurunaMachineCredential -LogicalUser 'fresh-user' | Should -Be ''
        $script:StubGetPasswordCalled | Should -Be $false
    }
    It 'degrades to empty when the authentication extension is not loaded' {
        # New-Lab can run before the extension is imported; that must generate a
        # credential, not fail the lab.
        $saved = ${function:global:Test-VaultEntry}
        Remove-Item -LiteralPath 'Function:\Test-VaultEntry' -Force
        try {
            Get-YurunaMachineCredential -LogicalUser 'yuruna-pool' | Should -Be ''
        } finally {
            Set-Item -LiteralPath 'Function:\global:Test-VaultEntry' -Value $saved
        }
    }
}
