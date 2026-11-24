<#PSScriptInfo
.VERSION 2026.11.23
.GUID 426f60c6-12ae-47e8-bf91-92c9c1eadd18
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test nas credential mtls seed service pester
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
    Pins that a service guest gets its NAS password over mutual TLS at first
    boot, and that no service seed carries it.
.DESCRIPTION
    The stash, pool-control and download-agent seeds used to render the NAS
    password into user-data, so it sat in the seed media and in the staging
    files a failed build left behind. The guest helper is run under sh with a
    stand-in curl on PATH; the seeds are rendered with the real renderer.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    $script:Helper = Join-Path $script:RepoRoot 'automation/yuruna-nas-credential.sh'

    function Invoke-NasCredentialHelper {
        param([string]$Root, [string]$Name = 'pool', [string]$Json = '', [int]$CurlExit = 0, [switch]$NoMaterial,
            [string]$Mount = '', [switch]$Mounted, [int]$MountExit = 0, [string]$Existing, [switch]$Unanswering,
            [switch]$MountpointFails, [switch]$FindmntUnavailable, [int]$PrimaryMountExit = 0)
        $bin = Join-Path $Root 'bin'
        $cdir = Join-Path $Root 'host-config'
        $null = New-Item -ItemType Directory -Force -Path $bin, $cdir
        Set-Content -LiteralPath (Join-Path $Root 'host.env') -Value "YURUNA_STATUS_SERVICE_IP=192.0.2.7`nYURUNA_STATUS_SERVICE_PORT=8080" -NoNewline
        Set-Content -LiteralPath (Join-Path $cdir 'config.env') -Value 'YURUNA_CONFIG_SERVICE_PORT=9443' -NoNewline
        if (-not $NoMaterial) { foreach ($f in 'ca.crt', 'client.crt', 'client.key') { Set-Content -LiteralPath (Join-Path $cdir $f) -Value 'pem' } }
        $curl = Join-Path $bin 'curl'
        [IO.File]::WriteAllText($curl, "#!/bin/sh`nprintf '%s\n' `"`$*`" > '$Root/curl.args'`nprintf '%s' '$Json'`nexit $CurlExit`n")
        & chmod +x $curl
        # Stand-ins for the refresh path: whether the share is mounted, and a
        # mount that records how it was asked to remount.
        $mountedExit = if ($Mounted -and -not $MountpointFails) { 0 } else { 1 }
        $findmntExit = if ($FindmntUnavailable) { 127 } elseif ($Mounted) { 0 } else { 1 }
        [IO.File]::WriteAllText((Join-Path $bin 'mountpoint'), "#!/bin/sh`nexit $mountedExit`n")
        [IO.File]::WriteAllText((Join-Path $bin 'findmnt'), "#!/bin/sh`nprintf '%s\n' `"`$*`" > '$Root/findmnt.args'`n" +
            "case `"`$*`" in *--json*) printf '%s' '{`"filesystems`":[{`"source`":`"//nas/pool`",`"options`":`"rw,vers=3.1.1,cache=none,username=ypool,credentials=/old/cred,password=old-secret,pass=old-alias,password2=old-alt,pass2=old-alt-alias`"}]}' ;; esac`nexit $findmntExit`n")
        $primaryExit = if ($PrimaryMountExit) { $PrimaryMountExit } else { $MountExit }
        [IO.File]::WriteAllText((Join-Path $bin 'mount'), "#!/bin/sh`nprintf '%s\n' `"`$*`" >> '$Root/mount.args'`n" +
            "if [ `"`$1`" = '-o' ]; then exit $primaryExit; fi`n" +
            "for option in `"`$@`"; do case `"`$option`" in *credentials=*) file=`${option##*credentials=}; cp -p `"`$file`" '$Root/alternate.cred' ;; esac; done`nexit $MountExit`n")
        [IO.File]::WriteAllText((Join-Path $bin 'timeout'), "#!/bin/sh`nshift`nexec `"`$@`"`n")
        $statExit = if ($Unanswering) { 1 } else { 0 }
        [IO.File]::WriteAllText((Join-Path $bin 'stat'), "#!/bin/sh`nexit $statExit`n")
        & chmod +x (Join-Path $bin 'mountpoint') (Join-Path $bin 'findmnt') (Join-Path $bin 'mount') (Join-Path $bin 'timeout') (Join-Path $bin 'stat')
        $cred = Join-Path $Root 'nas.cifs.cred'
        if ($PSBoundParameters.ContainsKey('Existing')) { [IO.File]::WriteAllText($cred, $Existing) }
        $saved = Save-YurunaTestEnvironment -Name 'PATH', 'YURUNA_HOST_CONFIG_DIR', 'YURUNA_HOST_ENV_FILE', 'YURUNA_NAS_CREDENTIAL_ATTEMPTS', 'YURUNA_NAS_CREDENTIAL_PAUSE_SECONDS'
        try {
            $env:PATH = "${bin}:$($env:PATH)"
            $env:YURUNA_HOST_CONFIG_DIR = $cdir
            $env:YURUNA_HOST_ENV_FILE = Join-Path $Root 'host.env'
            $env:YURUNA_NAS_CREDENTIAL_ATTEMPTS = '2'
            $env:YURUNA_NAS_CREDENTIAL_PAUSE_SECONDS = '0'
            $helperArgs = @($Name, $cred)
            if ($Mount) { $helperArgs += $Mount }
            $out = & /bin/sh $script:Helper @helperArgs 2>&1
            $code = $LASTEXITCODE
        } finally { Restore-YurunaTestEnvironment -Saved $saved }
        return [pscustomobject]@{ Code = $code; Output = ($out -join "`n"); Cred = $cred; Args = (Join-Path $Root 'curl.args'); MountArgs = (Join-Path $Root 'mount.args') }
    }
}

Describe 'yuruna-nas-credential.sh' -Skip:$IsWindows {
    It 'writes an owner-only credentials file from the config service answer, over mutual TLS to the seeded host' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $r = Invoke-NasCredentialHelper -Root $root -Json '{"name":"pool","networkPath":"//nas/pool","username":"ypool","password":"p@ss w$rd!","version":"v1"}'
        $r.Code | Should -Be 0 -Because $r.Output
        Get-Content -Raw -LiteralPath $r.Cred | Should -Be "username=ypool`npassword=p@ss w`$rd!`n"
        ((Get-Item -LiteralPath $r.Cred).UnixFileMode.value__ -band 0x3F) | Should -Be 0 -Because 'group and other have no access'
        $curlArgs = Get-Content -Raw -LiteralPath $r.Args
        $curlArgs | Should -Match '--cert .*client\.crt --key .*client\.key'
        $curlArgs | Should -Match 'yuruna-host-config:9443:192\.0\.2\.7:9443'
        $curlArgs | Should -Match '/v1/nas/pool'
    }
    It 'fails without writing a file when <Case>' -ForEach @(
        @{ Case = 'the config service does not answer'; Json = ''; CurlExit = 7; NoMaterial = $false }
        @{ Case = 'the answer carries no password'; Json = '{"username":"ypool","password":""}'; CurlExit = 0; NoMaterial = $false }
        @{ Case = 'the mutual-TLS material is absent'; Json = '{"username":"ypool","password":"x"}'; CurlExit = 0; NoMaterial = $true }
    ) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $r = Invoke-NasCredentialHelper -Root $root -Json $Json -CurlExit $CurlExit -NoMaterial:$NoMaterial
        $r.Code | Should -Be 1 -Because $r.Output
        Test-Path -LiteralPath $r.Cred | Should -BeFalse
    }
    It 'refuses a name other than stash or pool' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        (Invoke-NasCredentialHelper -Root $root -Name 'other' -Json '{}').Code | Should -Be 1
    }
}

Describe 'yuruna-nas-credential.sh as the periodic refresh' -Skip:$IsWindows {
    BeforeAll {
        $script:Rotated = '{"username":"ypool","password":"rotated"}'
    }
    It 'leaves a current credentials file and the share alone' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path $root
        $current = "username=ypool`npassword=rotated`n"
        [IO.File]::WriteAllText((Join-Path $root 'nas.cifs.cred'), $current)
        $before = (Get-Item -LiteralPath (Join-Path $root 'nas.cifs.cred')).LastWriteTimeUtc
        Start-Sleep -Milliseconds 20
        $r = Invoke-NasCredentialHelper -Root $root -Json $script:Rotated -Mount '/mnt/yuruna-pool' -Mounted
        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'are current'
        (Get-Item -LiteralPath $r.Cred).LastWriteTimeUtc | Should -Be $before
        Test-Path -LiteralPath $r.MountArgs | Should -BeFalse
    }
    It 'replaces a stale credential and remounts the mounted share in place' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path $root
        $r = Invoke-NasCredentialHelper -Root $root -Json $script:Rotated -Mount '/mnt/yuruna-pool' -Mounted -Existing "username=ypool`npassword=old`n"
        $r.Code | Should -Be 0 -Because $r.Output
        Get-Content -Raw -LiteralPath $r.Cred | Should -Be "username=ypool`npassword=rotated`n"
        (Get-Content -Raw -LiteralPath $r.MountArgs).Trim() | Should -BeExactly '-o remount /mnt/yuruna-pool'
    }
    It 'remounts a mounted share that stops answering even when the credential is current' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path $root
        [IO.File]::WriteAllText((Join-Path $root 'nas.cifs.cred'), "username=ypool`npassword=rotated`n")
        $r = Invoke-NasCredentialHelper -Root $root -Json $script:Rotated -Mount '/mnt/yuruna-pool' -Mounted -Unanswering
        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'does not answer; remounting it'
        (Get-Content -Raw -LiteralPath $r.MountArgs).Trim() | Should -BeExactly '-o remount /mnt/yuruna-pool'
    }
    It 'remounts a disconnected share still in the mount table when <Case>' -ForEach @(
        @{ Case='the credential changed'; Previous='old'; Unanswering=$false },
        @{ Case='the credential is current but the share does not answer'; Previous='rotated'; Unanswering=$true }
    ) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $r = Invoke-NasCredentialHelper -Root $root -Json $script:Rotated -Mount '/mnt/yuruna-pool' `
            -Mounted -MountpointFails -Unanswering:$Unanswering -Existing "username=ypool`npassword=$Previous`n"
        $r.Code | Should -Be 0 -Because $r.Output
        Get-Content -Raw -LiteralPath $r.Cred | Should -Be "username=ypool`npassword=rotated`n"
        (Get-Content -Raw -LiteralPath $r.MountArgs).Trim() | Should -BeExactly '-o remount /mnt/yuruna-pool'
        (Get-Content -Raw -LiteralPath (Join-Path $root 'findmnt.args')).Trim() |
            Should -BeExactly '--nocanonicalize --mountpoint /mnt/yuruna-pool --noheadings --output TARGET'
    }
    It 'keeps the mountpoint fallback when the mount-table lookup is unavailable' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $r = Invoke-NasCredentialHelper -Root $root -Json $script:Rotated -Mount '/mnt/yuruna-pool' `
            -Mounted -FindmntUnavailable -Existing "username=ypool`npassword=old`n"
        $r.Code | Should -Be 0 -Because $r.Output
        (Get-Content -Raw -LiteralPath $r.MountArgs).Trim() | Should -BeExactly '-o remount /mnt/yuruna-pool'
    }
    It 'replaces a stale credential but never mounts a share that is not mounted' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path $root
        $r = Invoke-NasCredentialHelper -Root $root -Json $script:Rotated -Mount '/mnt/yuruna-pool' -Existing "username=ypool`npassword=old`n"
        $r.Code | Should -Be 0 -Because $r.Output
        Get-Content -Raw -LiteralPath $r.Cred | Should -Be "username=ypool`npassword=rotated`n"
        Test-Path -LiteralPath $r.MountArgs | Should -BeFalse
    }
    It 'reports failure and keeps the new credential when <Case>' -ForEach @(
        @{ Case='both primary and alternate remounts fail'; PrimaryExit=32; AlternateExit=32; FindmntUnavailable=$false },
        @{ Case='the alternate-password lookup is unavailable'; PrimaryExit=22; AlternateExit=0; FindmntUnavailable=$true }
    ) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path $root
        $r = Invoke-NasCredentialHelper -Root $root -Json $script:Rotated -Mount '/mnt/yuruna-pool' -Mounted `
            -PrimaryMountExit $PrimaryExit -MountExit $AlternateExit -FindmntUnavailable:$FindmntUnavailable -Existing "username=ypool`npassword=old`n"
        $r.Code | Should -Be 1
        $r.Output | Should -Match 'could not be remounted'
        Get-Content -Raw -LiteralPath $r.Cred | Should -Be "username=ypool`npassword=rotated`n"
        @(Get-ChildItem -LiteralPath $root -Filter '.nas-remount-*').Count | Should -Be 0
    }
    It 'uses only the alternate password for successive active-session rotations' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($password in @('rotated', 'rotated-again')) {
            $json = @{ username='ypool'; password=$password } | ConvertTo-Json -Compress
            $r = Invoke-NasCredentialHelper -Root $root -Json $json -Mount '/mnt/yuruna-pool' -Mounted -PrimaryMountExit 22
            $r.Code | Should -Be 0 -Because $r.Output
            Get-Content -Raw -LiteralPath $r.Cred | Should -Be "username=ypool`npassword=$password`n"
            $alternate = Join-Path $root 'alternate.cred'
            Get-Content -Raw -LiteralPath $alternate | Should -Be "username=ypool`npassword2=$password`n"
            ((Get-Item -LiteralPath $alternate).UnixFileMode.value__ -band 0x3F) | Should -Be 0
            $calls = Get-Content -LiteralPath $r.MountArgs
            $calls[-1] | Should -Match '^-t cifs -o remount,rw,vers=3.1.1,cache=none,credentials=.* //nas/pool /mnt/yuruna-pool$'
            ($calls -join ' ') | Should -Not -Match 'password=|password2=|old-secret|old-alias|old-alt'
            @(Get-ChildItem -LiteralPath $root -Filter '.nas-remount-*').Count | Should -Be 0
        }
        @(Get-Content -LiteralPath $r.MountArgs).Count | Should -Be 4
    }
    It 'keeps the first-boot call writing the file even when it is current' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path $root
        $r = Invoke-NasCredentialHelper -Root $root -Json $script:Rotated -Mounted -Existing "username=ypool`npassword=rotated`n"
        $r.Code | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'credentials written to'
        Test-Path -LiteralPath $r.MountArgs | Should -BeFalse
    }
    It '<Seed> refreshes its own credential and share, and starts the timer where the NAS is configured' -ForEach @(
        @{ Seed = 'stash-service.base.user-data'; Line = 'yuruna-nas-credential.sh stash /etc/yuruna/ystash-nas.cifs.cred /mnt/ystash-nas' }
        @{ Seed = 'pool-control-service.base.user-data'; Line = 'yuruna-nas-credential.sh pool /etc/yuruna/pool-nas.cifs.cred /mnt/yuruna-pool' }
        @{ Seed = 'download-agent-service.base.user-data'; Line = 'yuruna-nas-credential.sh pool /etc/yuruna/pool-nas.cifs.cred /mnt/yuruna-pool' }
    ) {
        $text = [IO.File]::ReadAllText((Join-Path $script:RepoRoot "host/vmconfig/$Seed"))
        $text | Should -Match ([regex]::Escape("ExecStart=/usr/local/bin/$Line"))
        $fetch = $text.IndexOf('/usr/local/bin/yuruna-nas-credential.sh ' + ($Line -split ' ')[1] + ' ', [StringComparison]::Ordinal)
        $enable = $text.IndexOf('systemctl enable --now yuruna-nas-credential-refresh.timer', [StringComparison]::Ordinal)
        $fetch | Should -BeGreaterThan 0
        $enable | Should -BeGreaterThan $fetch
    }
}

Describe 'service seeds carry no NAS password' {
    It '<Seed> fetches the credential at first boot instead of rendering it' -ForEach @(
        @{ Seed = 'stash-service'; Name = 'stash'; Cred = '/etc/yuruna/ystash-nas.cifs.cred' }
        @{ Seed = 'pool-control-service'; Name = 'pool'; Cred = '/etc/yuruna/pool-nas.cifs.cred' }
        @{ Seed = 'download-agent-service'; Name = 'pool'; Cred = '/etc/yuruna/pool-nas.cifs.cred' }
    ) {
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot "host/vmconfig/$Seed.base.user-data")
        $text | Should -Not -Match 'NAS_PASSWORD_PLACEHOLDER'
        $text | Should -Match ([regex]::Escape("/usr/local/bin/yuruna-nas-credential.sh $Name $Cred"))
        foreach ($placeholder in 'YURUNA_NAS_CREDENTIAL_BASE64_PLACEHOLDER', 'YURUNA_CONFIG_SERVICE_CLIENT_KEY_BASE64_PLACEHOLDER', 'YURUNA_CONFIG_SERVICE_CA_CERT_BASE64_PLACEHOLDER') {
            $text | Should -Match $placeholder
        }
    }
    It 'no service builder passes a NAS password to the renderer: <Builder>' -ForEach @(
        foreach ($h in 'ubuntu.kvm', 'windows.hyper-v', 'macos.utm') { foreach ($s in 'stash', 'pool-control', 'download-agent') { @{ Builder = "host/$h/guest.$s-service/New-VM.ps1" } } }
    ) {
        $text = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot $Builder)
        $text | Should -Not -Match 'NAS_PASSWORD_PLACEHOLDER'
        $text | Should -Match 'Get-YurunaConfigServiceSeedMaterial'
    }
    It 'the renderer embeds the helper byte for byte' {
        Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force
        $b64 = Get-YurunaGuestScriptBase64 -RepoRoot $script:RepoRoot
        [Convert]::FromBase64String($b64.NasCredential) | Should -Be ([IO.File]::ReadAllBytes($script:Helper))
    }
}

Describe 'service guests can reach the config service' {
    It 'serves the host-resolved remote NAS address over the authenticated configuration channel' {
        Import-Module (Join-Path $script:RepoRoot 'test/modules/Test.Config.psm1') -Force -DisableNameChecking
        Import-Module (Join-Path $script:RepoRoot 'test/modules/Test.PoolStorage.psm1') -Force -DisableNameChecking
        $ast = Get-YurunaTestFileAst -Path (Join-Path $script:RepoRoot 'test/service/Start-ConfigService.ps1')
        $definition = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Resolve-YurunaNasPayload' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        $configPath = Join-Path $TestDrive 'nas-config.yml'
        Set-Content -LiteralPath $configPath -Value 'fixture'
        function Get-EffectiveUser { @{vaultKey='fixture-key'} }
        function Test-VaultEntry { $true }
        function Get-Password { 'fixture-secret' }
        Mock Read-TestConfig { @{} }
        Mock Get-YurunaPoolStorageConfig { @{NetworkPath='//nas/work/pool';NetworkUser='fixture';LocalPath='/mnt/pool'} }
        Mock Get-PoolStorageServerName { '192.0.2.25' }
        $payload = Resolve-YurunaNasPayload -Name pool -ConfigPath $configPath
        $payload.networkIp | Should -BeExactly '192.0.2.25'
        $payload.networkPath | Should -BeExactly '//nas/work/pool'
        $payload.password | Should -BeExactly 'fixture-secret'
    }
    It 'opens the config port through the shared host firewall helper, without a prompt, on Linux' -Skip:(-not $IsLinux) {
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:RepoRoot 'test/service/Start-ConfigService.ps1'), [ref]$null, [ref]$null)
        $block = $ast.Find({ param($n) $n -is [Management.Automation.Language.IfStatementAst] -and
                $n.Clauses[0].Item1.Extent.Text -eq '$IsLinux' }, $true)
        $block | Should -Not -BeNullOrEmpty
        # $PSScriptRoot is empty in a created scriptblock; the block runs as the script would.
        $serviceDir = (Join-Path $script:RepoRoot 'test/service').Replace("'", "''")
        $text = $block.Extent.Text.Replace('$PSScriptRoot', "'$serviceDir'")
        $Port = 8443
        $null = $Port # Read by the extracted production block.
        # The launcher imports the message catalog above the block, for the
        # warning a rule it cannot confirm raises.
        Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Globalization.psm1') -DisableNameChecking
        Import-Module (Join-Path $script:RepoRoot 'test/modules/Test.StatusFirewall.psm1') -Force
        Mock Set-YurunaStatusFirewallRule { [pscustomobject]@{ Message = 'fixture' } }
        . ([scriptblock]::Create($text))
        Should -Invoke Set-YurunaStatusFirewallRule -Times 1 -Exactly -ParameterFilter { $Port -eq 8443 -and $NonInteractive }
    }
}
