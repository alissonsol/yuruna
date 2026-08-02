<#PSScriptInfo
.VERSION 2026.08.02
.GUID 42e0a5c9-71b4-4d38-a6f2-90c3d5e81b47
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test lab storage smb share pester
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
    Pester coverage for the pure (no-I/O) parts of Test.LocalLabStorage.psm1:
    data-drive selection, the per-platform default root, the tier descriptor,
    the generated Samba config, the smb.conf include edit, and the
    BackConnectionHostNames merge. The OS calls (accounts, shares, registry,
    mount) are integration-verified, since they mutate the host.
#>

$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.LocalLabStorage.psm1'
Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue

# Helpers sit at file scope, above the first Describe: a Describe body runs during
# the discovery pass and everything it declares is discarded before the first It,
# so a helper defined inside one surfaces as CommandNotFoundException.
function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-Null { param($Actual, [string]$Because = '') if ($null -ne $Actual) { throw "Expected null got [$Actual]. $Because" } }
function Assert-Match { param([string]$Pattern, [string]$Actual, [string]$Because = '') if ($Actual -notmatch $Pattern) { throw "Expected to match [$Pattern] in [$Actual]. $Because" } }

function Get-TestTier {
    param([string]$Platform = 'linux', [string]$Root = '/srv/yuruna', [string]$DriveLetter = 'y:')
    New-LocalLabStorageTier -Kind 'pool' -Root $Root -Account 'yuruna-pool' -Server 'ypool-nas' `
        -FolderName 'yuruna.pool' -ShareName 'yuruna.pool' -Platform $Platform -DriveLetter $DriveLetter
}

Describe 'Select-LocalLabStorageDataDrive' {
    It 'prefers the first fixed drive that is not the system drive' {
        Assert-Equal 'D:' (Select-LocalLabStorageDataDrive -Drive @('C:', 'D:', 'E:') -SystemDrive 'C:')
    }
    It 'falls back to the system drive when it is the only one' {
        Assert-Equal 'C:' (Select-LocalLabStorageDataDrive -Drive @('C:') -SystemDrive 'C:')
    }
    It 'falls back to the system drive when no drive is reported' {
        Assert-Equal 'C:' (Select-LocalLabStorageDataDrive -Drive @() -SystemDrive 'C:')
    }
    It 'treats a trailing separator and case as the same drive' {
        # $env:SystemDrive is 'C:' while a volume can be reported as 'c:\'; without
        # normalization the system drive would be picked as if it were a data drive.
        Assert-Equal 'D:' (Select-LocalLabStorageDataDrive -Drive @('c:\', 'D:') -SystemDrive 'C:')
    }
}

Describe 'Get-LocalLabStorageDefaultRoot' {
    It 'suggests /srv/yuruna on Ubuntu' {
        Assert-Equal '/srv/yuruna' (Get-LocalLabStorageDefaultRoot -Platform 'linux')
    }
    It 'suggests /Users/Shared/yuruna on macOS' {
        Assert-Equal '/Users/Shared/yuruna' (Get-LocalLabStorageDefaultRoot -Platform 'macos')
    }
    It 'suggests the data drive on Windows' {
        Assert-Equal 'D:\Shares\yuruna' (Get-LocalLabStorageDefaultRoot -Platform 'windows' -DataDrive 'D:')
    }
    It 'falls back to C: when no Windows drive is supplied' {
        Assert-Equal 'C:\Shares\yuruna' (Get-LocalLabStorageDefaultRoot -Platform 'windows' -DataDrive '')
    }
}

Describe 'New-LocalLabStorageTier' {
    It 'composes the unix folder, share, and mount paths' {
        $t = Get-TestTier -Platform 'linux'
        Assert-Equal '/srv/yuruna/yuruna.pool' $t.FolderPath
        Assert-Equal '//ypool-nas/yuruna.pool' $t.NetworkPath
        Assert-Equal '/mnt/ypool-nas' $t.LocalPath
    }
    It 'composes the macOS mount point under the operator home' {
        $t = Get-TestTier -Platform 'macos' -Root '/Users/Shared/yuruna'
        Assert-Equal '/Users/Shared/yuruna/yuruna.pool' $t.FolderPath
        Assert-Equal '~/Shares/ypool-nas' $t.LocalPath
    }
    It 'composes Windows paths with backslashes regardless of the running host' {
        # Join-Path would use the RUNNING platform's separator, so a Windows tier
        # evaluated on macOS/Linux would carry forward slashes into the config.
        $t = Get-TestTier -Platform 'windows' -Root 'D:\Shares\yuruna'
        Assert-Equal 'D:\Shares\yuruna\yuruna.pool' $t.FolderPath
        Assert-Equal '\\ypool-nas\yuruna.pool' $t.NetworkPath
        Assert-Equal 'y:' $t.LocalPath
    }
    It 'strips a trailing separator from the root' {
        $t = Get-TestTier -Platform 'linux' -Root '/srv/yuruna/'
        Assert-Equal '/srv/yuruna/yuruna.pool' $t.FolderPath
    }
    It 'namespaces the vault key so the credential never auto-generates' {
        Assert-Equal 'smb.yuruna-pool' (Get-TestTier).VaultKey
    }
    It 'maps the kind onto the test.config.yml key prefix' {
        Assert-Equal 'poolStorage' (Get-TestTier).ConfigPrefix
        $stash = New-LocalLabStorageTier -Kind 'stash' -Root '/srv/yuruna' -Account 'yuruna-stash' `
            -Server 'ystash-nas' -FolderName 'yuruna.stash' -ShareName 'yuruna.stash' -Platform 'linux'
        Assert-Equal 'stashStorage' $stash.ConfigPrefix
    }
}

Describe 'Get-LocalLabStorageSambaConfig' {
    It 'scopes each share to its own account' {
        $text = Get-LocalLabStorageSambaConfig -Tier @((Get-TestTier))
        Assert-Match '(?m)^\[yuruna\.pool\]$' $text
        Assert-Match '(?m)^\s+path = /srv/yuruna/yuruna\.pool$' $text
        Assert-Match '(?m)^\s+valid users = yuruna-pool$' $text
    }
    It 'refuses guest access and read-only mode' {
        $text = Get-LocalLabStorageSambaConfig -Tier @((Get-TestTier))
        Assert-Match '(?m)^\s+guest ok = no$' $text
        Assert-Match '(?m)^\s+read only = no$' $text
    }
    It 'emits one section per tier' {
        $stash = New-LocalLabStorageTier -Kind 'stash' -Root '/srv/yuruna' -Account 'yuruna-stash' `
            -Server 'ystash-nas' -FolderName 'yuruna.stash' -ShareName 'yuruna.stash' -Platform 'linux'
        $text = Get-LocalLabStorageSambaConfig -Tier @((Get-TestTier), $stash)
        Assert-Equal 2 (@([regex]::Matches($text, '(?m)^\[')).Count)
    }
}

Describe 'Add-LocalLabStorageSambaInclude' {
    It 'appends the include line to a config that lacks it' {
        $out = Add-LocalLabStorageSambaInclude -Content "[global]`n   workgroup = WORKGROUP`n" -IncludePath '/etc/samba/yuruna.conf'
        Assert-Match '(?m)^include = /etc/samba/yuruna\.conf$' $out
    }
    It 'returns null when the include is already present, so nothing is rewritten' {
        $existing = "[global]`n   workgroup = WORKGROUP`ninclude = /etc/samba/yuruna.conf`n"
        Assert-Null (Add-LocalLabStorageSambaInclude -Content $existing -IncludePath '/etc/samba/yuruna.conf')
    }
    It 'recognizes an existing include written with different spacing' {
        $existing = "[global]`n   include   =   /etc/samba/yuruna.conf`n"
        Assert-Null (Add-LocalLabStorageSambaInclude -Content $existing -IncludePath '/etc/samba/yuruna.conf')
    }
    It 'handles an empty or missing smb.conf' {
        $out = Add-LocalLabStorageSambaInclude -Content '' -IncludePath '/etc/samba/yuruna.conf'
        Assert-Match '(?m)^include = /etc/samba/yuruna\.conf$' $out
    }
    It 'does not glue the include onto an unterminated last line' {
        $out = Add-LocalLabStorageSambaInclude -Content '[global]' -IncludePath '/etc/samba/yuruna.conf'
        Assert-Match '(?m)^\[global\]$' $out
    }
}

Describe 'Merge-LocalLabStorageBackConnectionName' {
    It 'adds the wanted names to an unset value' {
        $m = Merge-LocalLabStorageBackConnectionName -Existing @() -Wanted @('ypool-nas', 'ystash-nas')
        Assert-Equal 2 $m.Count
        Assert-Equal 'ypool-nas' $m[0]
    }
    It 'returns null when every name is already registered, so nothing is written' {
        Assert-Null (Merge-LocalLabStorageBackConnectionName -Existing @('ypool-nas', 'ystash-nas') -Wanted @('ypool-nas'))
    }
    It 'preserves entries another product registered' {
        $m = Merge-LocalLabStorageBackConnectionName -Existing @('sharepoint.local') -Wanted @('ypool-nas')
        Assert-Equal 2 $m.Count
        Assert-Equal 'sharepoint.local' $m[0]
        Assert-Equal 'ypool-nas' $m[1]
    }
    It 'matches existing entries case-insensitively' {
        Assert-Null (Merge-LocalLabStorageBackConnectionName -Existing @('YPOOL-NAS') -Wanted @('ypool-nas'))
    }
    It 'ignores blank entries left in the value' {
        $m = Merge-LocalLabStorageBackConnectionName -Existing @('', '  ') -Wanted @('ypool-nas')
        Assert-Equal 1 $m.Count
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.

Describe 'Get-LocalLabStorageSmbAuthVerdict' {
    It 'reports ok on exit 0' {
        Assert-Equal 'ok' (Get-LocalLabStorageSmbAuthVerdict -ExitCode 0 -Output 'Share  Type')
    }
    It 'classifies a refused credential as auth' {
        # The reported macOS failure: the account has no SMB-NT hash, so smbd
        # refuses a password that every other authority accepts.
        Assert-Equal 'auth' (Get-LocalLabStorageSmbAuthVerdict -ExitCode 1 -Output 'smbutil: server rejected the connection: Authentication error')
    }
    It 'classifies a refused connection as unreachable, not auth' {
        # Reporting this as an authentication problem is the misdiagnosis the
        # probe exists to prevent: nothing is wrong with the credential.
        Assert-Equal 'unreachable' (Get-LocalLabStorageSmbAuthVerdict -ExitCode 1 -Output 'smbutil: could not connect: Connection refused')
    }
    It 'falls back to unknown rather than guessing' {
        Assert-Equal 'unknown' (Get-LocalLabStorageSmbAuthVerdict -ExitCode 2 -Output 'something else entirely')
    }
}
