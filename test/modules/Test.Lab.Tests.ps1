<#PSScriptInfo
.VERSION 2026.07.26
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
    Lab creation: the intent store's git settings and the lab vault's shape.
.DESCRIPTION
    Each assertion here stands for a failure that is silent in production:
    a store seeded at the wrong schemaVersion reads fine and fails every write; a
    store without receive.updateServerInfo serves stale refs to runners after the
    first push; and a password starting with a YAML indicator survives the vault
    only to mangle a guest's chpasswd during cloud-init.
#>

$ErrorActionPreference = 'Stop'
$testRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'Test.PoolAdmin.psm1') -Force -DisableNameChecking

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
    $work = Join-Path ([IO.Path]::GetTempPath()) ('yuruna-lab-v-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $labName = 'pester-lab'
    $vault = Join-Path $testRoot "status/extension/authentication/lab.$labName.vault.yml"
    & pwsh -NoProfile -File (Join-Path $testRoot 'New-Lab.ps1') -Name $labName -Root $work 2>&1 | Out-Null

    It 'writes the vault where the gitignore and the status-server deny-list already cover it' {
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
