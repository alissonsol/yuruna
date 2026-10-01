<#PSScriptInfo
.VERSION 2026.09.30
.GUID 425947a5-2f05-4cc4-9b4d-22107bbf34be
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-refresh remote authorization proof pester
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
    The host side of remote refresh authorization: the shared golden vectors,
    the verdict table, the explicit-clock verifier, the verifier key's on-disk
    protections, the listener's authorization layer, provisioning, and the
    operator script.
.DESCRIPTION
    The vector file under test/extension/extension-sdk/hostrefresh/testdata is
    the one the Go SDK, pool-control and the aggregator also read, so a drift
    in any HMAC input, encoding or field order fails all of them against the
    same literal values.

    Run: Invoke-Pester -Path test/modules/Test.HostRefreshAuth.Tests.ps1
#>

BeforeDiscovery {
    $vectorPath = [IO.Path]::Combine($PSScriptRoot, '..', 'extension', 'extension-sdk', 'hostrefresh', 'testdata', 'vectors.json')
    $script:VectorCases = @((ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($vectorPath))).cases | ForEach-Object {
            @{ Name = $_.name; Wire = $_.wire; KeyName = $_.key; HostId = $_.hostId; RequestId = $_.requestId
                Tier = $_.tier; MaxRung = $_.maxRung; NowUnix = [long]$_.nowUnix; Want = $_.want }
        })
}

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    $script:ModulePath = Join-Path $here 'Test.HostRefreshAuth.psm1'
    $script:ScriptPath = [IO.Path]::Combine($script:RepoRoot, 'test', 'lab', 'Set-HostRefreshCredential.ps1')
    Import-Module $script:ModulePath -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking

    $vectorPath = [IO.Path]::Combine($script:RepoRoot, 'test', 'extension', 'extension-sdk', 'hostrefresh', 'testdata', 'vectors.json')
    $script:Vectors = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($vectorPath))
    $script:Authority = [Text.Encoding]::UTF8.GetBytes($script:Vectors.versioned.authorityText)
    [byte[]]$script:GoldenKey = Get-YurunaHostRefreshHostKey -AuthorityKey $script:Authority -HostId $script:Vectors.versioned.hostId
    $script:GoldenHost = $script:Vectors.versioned.hostId
    $script:GoldenRequest = $script:Vectors.versioned.requestId
    # The child reports its physical working directory, and macOS reaches the
    # temp root through /var -> /private/var, so the fixture root is canonical.
    $script:TempRoot = (Resolve-YurunaCanonicalPath -Path (New-YurunaTestTempDir -Prefix 'yuruna-hrauth')).Path

    function ConvertTo-TestBase64Url {
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory)][byte[]]$Bytes)
        [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }

    function New-TestPrivateRoot {
        # A private root owned by this test, created 0700 like the real one.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: creates a directory under this suite''s own temp root.')]
        [CmdletBinding()]
        [OutputType([string])]
        param()
        $dir = [IO.Path]::Combine($script:TempRoot, 'pr-' + [Guid]::NewGuid().ToString('N'), '.yuruna', 'host-refresh')
        if ($IsWindows) { [void][IO.Directory]::CreateDirectory($dir) }
        else { [void][IO.Directory]::CreateDirectory($dir, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute') }
        return $dir
    }

    function Set-TestKeyFile {
        # Writes a verifier key file with an explicit Unix mode.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes a file under this suite''s own temp root.')]
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][AllowEmptyString()][string]$Content, [string]$Mode = '600')
        $path = [IO.Path]::Combine($Root, 'remote-verifier.key')
        [IO.File]::WriteAllText($path, $Content)
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode][Convert]::ToInt32($Mode, 8))
        }
        return $path
    }

    function Get-TestGoldenKeyLine {
        [CmdletBinding()]
        [OutputType([string])]
        param()
        return $script:Vectors.versioned.hostKeyLine
    }

    function Get-TestUnixMode {
        [CmdletBinding()]
        [OutputType([int])]
        param([Parameter(Mandatory)][string]$Path)
        return [int][IO.File]::GetUnixFileMode($Path)
    }

    function ConvertTo-TestPlainText {
        [CmdletBinding()]
        [OutputType([string])]
        param([AllowEmptyString()][string]$Text)
        return ([regex]::Replace($Text, '\x1b\[[0-9;?]*[ -/]*[@-~]', '') -replace '[\x00-\x08\x0b\x0c\x0e-\x1f]', '')
    }

    function Invoke-TestChildProcess {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test helper: runs a bounded process with fixture-owned paths.')]
        [CmdletBinding()]
        [OutputType([hashtable])]
        param([Parameter(Mandatory)][Diagnostics.ProcessStartInfo]$StartInfo, [int]$TimeoutSeconds)
        $p = [Diagnostics.Process]::Start($StartInfo)
        try {
            $p.StandardInput.Close()
            $out = $p.StandardOutput.ReadToEndAsync()
            $err = $p.StandardError.ReadToEndAsync()
            if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
                $p.Kill($true)
                [void]$p.WaitForExit(5000)
                throw "child pwsh did not finish within $TimeoutSeconds s"
            }
            $p.WaitForExit()
            return @{ ExitCode = $p.ExitCode; StdOut = (ConvertTo-TestPlainText $out.Result); StdErr = (ConvertTo-TestPlainText $err.Result) }
        }
        finally { $p.Dispose() }
    }

    function Invoke-TestChildPwsh {
        # Probe the effective profile before starting a command that can change
        # credentials. Windows derives HOME from USERPROFILE; an OS/runtime that
        # ignores either override must fail this guard before touching a key.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test helper: runs short-lived child processes with fixture-owned paths.')]
        [CmdletBinding()]
        [OutputType([hashtable])]
        param(
            [Parameter(Mandatory)][string[]]$Argument,
            [Parameter(Mandatory)][string]$HomeDirectory,
            [string]$RuntimeDirectory = '',
            [int]$TimeoutSeconds = 180
        )
        $HomeDirectory = [IO.Path]::GetFullPath($HomeDirectory)
        if (-not $RuntimeDirectory) { $RuntimeDirectory = [IO.Path]::Combine($HomeDirectory, 'runtime') }
        $RuntimeDirectory = [IO.Path]::GetFullPath($RuntimeDirectory)
        $fixtureRoot = [IO.Path]::GetFullPath($script:TempRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        foreach ($path in @($HomeDirectory, $RuntimeDirectory)) {
            if (-not ($path.Equals($fixtureRoot, $comparison) -or $path.StartsWith($fixtureRoot + [IO.Path]::DirectorySeparatorChar, $comparison))) {
                throw "child path is outside the test fixture: $path"
            }
            [void][IO.Directory]::CreateDirectory($path)
        }
        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = (Get-Process -Id $PID).Path
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.WorkingDirectory = $HomeDirectory
        $psi.Environment['HOME'] = $HomeDirectory
        $psi.Environment['USERPROFILE'] = $HomeDirectory
        $psi.Environment['NO_COLOR'] = '1'
        $psi.Environment['YURUNA_NONINTERACTIVE'] = '1'
        $psi.Environment['YURUNA_RUNTIME_DIR'] = $RuntimeDirectory
        $probe = '[ordered]@{ Home = [string]$HOME; EnvHome = $env:HOME; UserProfile = $env:USERPROFILE; Runtime = $env:YURUNA_RUNTIME_DIR } | ConvertTo-Json -Compress'
        foreach ($a in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $probe)) { $psi.ArgumentList.Add($a) }
        $checked = Invoke-TestChildProcess -StartInfo $psi -TimeoutSeconds $TimeoutSeconds
        if ($checked.ExitCode -ne 0) { throw "child profile probe failed: $($checked.StdErr)" }
        $childProfile = ConvertFrom-Json -InputObject $checked.StdOut
        foreach ($value in @($childProfile.Home, $childProfile.EnvHome, $childProfile.UserProfile)) {
            if (-not [string]::Equals($HomeDirectory, [string]$value, $comparison)) {
                throw 'child profile did not resolve to the scratch home; requested command was not started'
            }
        }
        if (-not [string]::Equals($RuntimeDirectory, [string]$childProfile.Runtime, $comparison)) {
            throw 'child runtime did not resolve to the scratch runtime; requested command was not started'
        }
        # Reuse the exact executable, environment and working directory whose
        # effective profile was checked; only the requested arguments change.
        $psi.ArgumentList.Clear()
        foreach ($a in @('-NoLogo', '-NoProfile', '-NonInteractive') + $Argument) { $psi.ArgumentList.Add($a) }
        return (Invoke-TestChildProcess -StartInfo $psi -TimeoutSeconds $TimeoutSeconds)
    }

    function Invoke-TestCredentialScript {
        [CmdletBinding()]
        [OutputType([hashtable])]
        param([string[]]$Argument = @(), [Parameter(Mandatory)][string]$HomeDirectory, [string]$RuntimeDirectory = '')
        return (Invoke-TestChildPwsh -Argument (@('-File', $script:ScriptPath) + $Argument) -HomeDirectory $HomeDirectory -RuntimeDirectory $RuntimeDirectory)
    }
}

AfterAll {
    Remove-YurunaTestTempDir $script:TempRoot
}

Describe 'credential test children remain inside their fixture' {
    It 'overrides both platform profile inputs and isolates an omitted runtime' {
        $caseHome = [IO.Path]::Combine($script:TempRoot, 'profile-' + [guid]::NewGuid().ToString('N'))
        $parentHome = $env:HOME
        $parentProfile = $env:USERPROFILE
        $parentRuntime = $env:YURUNA_RUNTIME_DIR
        $command = '[ordered]@{ Home = [string]$HOME; EnvHome = $env:HOME; UserProfile = $env:USERPROFILE; Runtime = $env:YURUNA_RUNTIME_DIR; Directory = (Get-Location).Path } | ConvertTo-Json -Compress'
        $r = Invoke-TestChildPwsh -Argument @('-Command', $command) -HomeDirectory $caseHome
        Assert-Equal 0 $r.ExitCode
        $actual = ConvertFrom-Json -InputObject $r.StdOut
        foreach ($value in @($actual.Home, $actual.EnvHome, $actual.UserProfile, $actual.Directory)) { Assert-Equal $caseHome $value }
        Assert-Equal ([IO.Path]::Combine($caseHome, 'runtime')) $actual.Runtime
        Assert-Equal $parentHome $env:HOME
        Assert-Equal $parentProfile $env:USERPROFILE
        Assert-Equal $parentRuntime $env:YURUNA_RUNTIME_DIR
    }

    It 'never starts the requested command when effective HOME ignores the override' {
        $caseHome = [IO.Path]::Combine($script:TempRoot, 'profile-refused-' + [guid]::NewGuid().ToString('N'))
        Mock Invoke-TestChildProcess {
            param($StartInfo)
            Assert-Equal $caseHome $StartInfo.Environment['HOME']
            Assert-Equal $caseHome $StartInfo.Environment['USERPROFILE']
            Assert-True ($StartInfo.ArgumentList.Contains('-Command')) 'the first child must be the read-only probe'
            return @{ ExitCode = 0; StdOut = '{"Home":"outside-fixture","EnvHome":"outside-fixture","UserProfile":"outside-fixture","Runtime":"outside-fixture"}'; StdErr = '' }
        }
        Assert-Throw { Invoke-TestChildPwsh -Argument @('-File', $script:ScriptPath, '-NewAuthority') -HomeDirectory $caseHome } -Match 'scratch home'
        Should -Invoke Invoke-TestChildProcess -Times 1 -Exactly
        Assert-False ([IO.Directory]::Exists([IO.Path]::Combine($caseHome, '.yuruna'))) 'no private root was created'
    }

    It 'refuses paths outside the suite before starting a process' {
        Mock Invoke-TestChildProcess { throw 'no process may start' }
        Assert-Throw { Invoke-TestChildPwsh -Argument @('-Command', 'exit 0') -HomeDirectory ([IO.Path]::GetTempPath()) } -Match 'outside the test fixture'
        Should -Invoke Invoke-TestChildProcess -Times 0 -Exactly
    }
}

Describe 'shared golden vectors reproduce in PowerShell' {
    It 'derives the golden host key, key tag and authority tag' {
        Assert-Equal -Expected $script:Vectors.versioned.hostKey -Actual (ConvertTo-TestBase64Url -Bytes $script:GoldenKey)
        Assert-True ((Get-YurunaHostRefreshKeyTag -Key $script:GoldenKey) -ceq $script:Vectors.versioned.keyTag) 'key tag'
        Assert-True ((Get-YurunaHostRefreshAuthorityTag -Authority $script:Authority) -ceq $script:Vectors.versioned.authorityTag) 'authority tag'
    }

    It 'mints the golden wire byte for byte' {
        $v = $script:Vectors.versioned
        $wire = New-YurunaHostRefreshProof -HostKey $script:GoldenKey -HostId $v.hostId -RequestId $v.requestId -Tier $v.tier `
            -MaxRung $v.maxRung -IssuedUnixSeconds $v.issuedUnix -ExpiryUnixSeconds $v.expiryUnix
        Assert-True ($wire -ceq $v.wire) "wire mismatch: $wire"
    }

    It 'keeps the legacy control proof on the same shared vector' {
        Import-Module (Join-Path $PSScriptRoot 'Test.ConfigServiceSync.psm1') -Force -Global -DisableNameChecking
        $l = $script:Vectors.legacy
        Assert-True ((Get-YurunaControlProof -Token $l.token -ExpiryUnixSeconds $l.expiryUnix) -ceq $l.wire) 'legacy wire'
        Assert-True ((Get-YurunaControlTag -Token $l.token) -ceq $l.controlTag) 'legacy control tag'
    }

    It 'agrees with the package constants' {
        Assert-Equal -Expected 60 -Actual ([int]$script:Vectors.versioned.skewSeconds)
        Assert-Equal -Expected 300 -Actual ([int]$script:Vectors.versioned.maxLifetimeSeconds)
    }
}

Describe 'the shared verdict table through Test-YurunaHostRefreshProof' {
    It '<Name> -> <Want>' -ForEach $script:VectorCases {
        $key = switch ($KeyName) {
            'golden' { $script:GoldenKey }
            'empty' { [byte[]]@() }
            'authority' { $script:Authority }
        }
        $r = Test-YurunaHostRefreshProof -HostKey $key -Wire $Wire -HostId $HostId -RequestId $RequestId -Tier $Tier -MaxRung $MaxRung `
            -NowUnixSeconds $NowUnix -SkewSeconds 60
        Assert-Equal -Expected $Want -Actual $r.Reason
        Assert-Equal -Expected ($Want -ceq 'ok') -Actual $r.Valid
        if ($r.Valid) {
            Assert-True ($r.HostId -ceq $HostId -and $r.RequestId -ceq $RequestId -and $r.MaxRung -ceq $MaxRung) 'accepted claims'
        }
    }

    It 'never throws on a null key or a null wire' {
        $r = Test-YurunaHostRefreshProof -HostKey $null -Wire $null -HostId '' -RequestId '' -Tier '' -MaxRung '' -NowUnixSeconds 0 -SkewSeconds 60
        Assert-Equal -Expected 'refresh_proof_missing' -Actual $r.Reason
        $r = Test-YurunaHostRefreshProof -HostKey $null -Wire $script:Vectors.versioned.wire -HostId $script:GoldenHost -RequestId $script:GoldenRequest `
            -Tier 'restart' -MaxRung 'start-if-stopped' -NowUnixSeconds 1899999880 -SkewSeconds 60
        Assert-Equal -Expected 'refresh_proof_invalid' -Actual $r.Reason
    }

    It 'accepts a dashed spelling of its own host id' {
        $dashed = '42aaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $r = Test-YurunaHostRefreshProof -HostKey $script:GoldenKey -Wire $script:Vectors.versioned.wire -HostId $dashed -RequestId $script:GoldenRequest `
            -Tier 'restart' -MaxRung 'start-if-stopped' -NowUnixSeconds 1899999880 -SkewSeconds 60
        Assert-Equal -Expected 'ok' -Actual $r.Reason
    }
}

Describe 'the refresh proof and the legacy control proof cannot be confused' {
    It 'the legacy verifier refuses the refresh wire, and the refresh verifier the legacy wire' {
        Import-Module (Join-Path $PSScriptRoot 'Test.ConfigServiceSync.psm1') -Force -Global -DisableNameChecking
        Assert-False (Test-YurunaControlProof -Token $script:Vectors.legacy.token -Wire $script:Vectors.versioned.wire) 'legacy verifier accepted a refresh proof'
        $r = Test-YurunaHostRefreshProof -HostKey $script:GoldenKey -Wire $script:Vectors.legacy.wire -HostId $script:GoldenHost `
            -RequestId $script:GoldenRequest -Tier 'restart' -MaxRung 'start-if-stopped' -NowUnixSeconds $script:Vectors.legacy.verifyAtUnix -SkewSeconds 60
        Assert-Equal -Expected 'refresh_proof_malformed' -Actual $r.Reason
    }
}

Describe 'the verifier reads no clock and compares in constant time' {
    BeforeAll {
        $script:ModuleAst = Get-YurunaTestFileAst -Path $script:ModulePath
        function Get-TestFunctionText([string]$Name) {
            $fn = $script:ModuleAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
            if (-not $fn) { throw "function $Name not found" }
            return $fn.Extent.Text
        }
    }

    It 'Test-YurunaHostRefreshProof names no clock source' {
        $text = Get-TestFunctionText 'Test-YurunaHostRefreshProof'
        foreach ($clock in @('UtcNow', 'Get-Date', 'DateTimeOffset', 'DateTime]::Now', 'Stopwatch', 'TickCount')) {
            Assert-False ($text.Contains($clock)) "the verifier reads the clock through $clock"
        }
        Assert-True ($text.Contains('FixedTimeEquals([byte[]]$expected, [byte[]]$given)')) 'the MAC compare is constant-time on byte[] operands'
    }

    It 'Test-YurunaHostRefreshAuthorization reads the clock once, only without NowUnixSeconds' {
        $text = Get-TestFunctionText 'Test-YurunaHostRefreshAuthorization'
        Assert-Equal -Expected 1 -Actual ([regex]::Matches($text, 'UtcNow').Count)
        Assert-Match 'if \(\$null -ne \$NowUnixSeconds\)' $text
    }

    It 'the module imports only the globalization module and runs no native command' {
        $imports = @($script:ModuleAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Import-Module' }, $true))
        Assert-Equal -Expected 1 -Actual $imports.Count
        Assert-Match 'Yuruna\.Globalization\.psm1' $imports[0].Extent.Text
        foreach ($word in @('Invoke-BoundedNativeCommand', 'Start-Process', 'Yuruna.Common', 'Yuruna.Host')) {
            Assert-False ((Get-Content -Raw -LiteralPath $script:ModulePath).Contains($word)) "the module names $word"
        }
    }
}

Describe 'Read-YurunaHostRefreshVerifierKey' {
    It 'reports a missing key' {
        $root = New-TestPrivateRoot
        $r = Read-YurunaHostRefreshVerifierKey -HostId $script:GoldenHost -PrivateRoot $root
        Assert-Equal -Expected 'missing' -Actual $r.State
        Assert-Equal -Expected 'absent' -Actual $r.Reason
        Assert-Null $r.Key
    }

    It 'reads a valid key as provisioned with the golden key tag' {
        $root = New-TestPrivateRoot
        $null = Set-TestKeyFile -Root $root -Content ((Get-TestGoldenKeyLine) + "`n")
        $r = Read-YurunaHostRefreshVerifierKey -HostId $script:GoldenHost -PrivateRoot $root
        Assert-Equal -Expected 'provisioned' -Actual $r.State
        Assert-True ($r.KeyTag -ceq $script:Vectors.versioned.keyTag) 'golden key tag'
        Assert-Equal -Expected (ConvertTo-TestBase64Url -Bytes $script:GoldenKey) -Actual (ConvertTo-TestBase64Url -Bytes ([byte[]]$r.Key))
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'a malformed file'; Content = 'yhrk1.not-a-key'; Want = 'key_malformed' }
        @{ Name = 'an authority in the key slot'; Content = 'yhra1.' + ('A' * 43); Want = 'key_malformed' }
        @{ Name = 'two lines'; Content = 'LINE' + "`n" + 'LINE'; Want = 'key_malformed' }
        @{ Name = 'a key for another host'; Content = 'OTHER'; Want = 'key_host_mismatch' }
        @{ Name = 'an oversize file'; Content = ('x' * 5000); Want = 'key_malformed' }
    ) {
        $root = New-TestPrivateRoot
        $line = Get-TestGoldenKeyLine
        $text = $Content.Replace('LINE', $line).Replace('OTHER', $line.Replace($script:GoldenHost, '42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'))
        $null = Set-TestKeyFile -Root $root -Content $text
        $r = Read-YurunaHostRefreshVerifierKey -HostId $script:GoldenHost -PrivateRoot $root
        Assert-Equal -Expected 'invalid' -Actual $r.State
        Assert-Equal -Expected $Want -Actual $r.Reason
        Assert-Null $r.Key
    }

    It 'refuses a key file other users can read' -Skip:$IsWindows {
        $root = New-TestPrivateRoot
        $null = Set-TestKeyFile -Root $root -Content (Get-TestGoldenKeyLine) -Mode '644'
        $r = Read-YurunaHostRefreshVerifierKey -HostId $script:GoldenHost -PrivateRoot $root
        Assert-Equal -Expected 'key_permissions_open' -Actual $r.Reason
    }

    It 'refuses a key file that is a symbolic link, and a root that is one' -Skip:$IsWindows {
        $root = New-TestPrivateRoot
        $target = Set-TestKeyFile -Root (New-TestPrivateRoot) -Content (Get-TestGoldenKeyLine)
        $null = New-Item -ItemType SymbolicLink -Path ([IO.Path]::Combine($root, 'remote-verifier.key')) -Target $target
        Assert-Equal -Expected 'key_reparse_point' -Actual (Read-YurunaHostRefreshVerifierKey -HostId $script:GoldenHost -PrivateRoot $root).Reason

        $realRoot = New-TestPrivateRoot
        $null = Set-TestKeyFile -Root $realRoot -Content (Get-TestGoldenKeyLine)
        $linkRoot = [IO.Path]::Combine($script:TempRoot, 'link-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType SymbolicLink -Path $linkRoot -Target $realRoot
        Assert-Equal -Expected 'key_reparse_point' -Actual (Read-YurunaHostRefreshVerifierKey -HostId $script:GoldenHost -PrivateRoot $linkRoot).Reason
    }

    It 'reports an unknown host id as host_id_unavailable' {
        $root = New-TestPrivateRoot
        $null = Set-TestKeyFile -Root $root -Content (Get-TestGoldenKeyLine)
        foreach ($id in @('', 'not-a-host', '42AA')) {
            Assert-Equal -Expected 'host_id_unavailable' -Actual (Read-YurunaHostRefreshVerifierKey -HostId $id -PrivateRoot $root).Reason
        }
        Assert-Equal -Expected 'provisioned' -Actual (Read-YurunaHostRefreshVerifierKey -HostId '42AAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA' -PrivateRoot $root).State
    }
}

Describe 'Test-YurunaHostRefreshAuthorization' {
    BeforeAll {
        $script:AuthRoot = New-TestPrivateRoot
        $null = Set-TestKeyFile -Root $script:AuthRoot -Content (Get-TestGoldenKeyLine)
        function Invoke-TestAuthorization {
            [CmdletBinding()]
            [OutputType([hashtable])]
            param([AllowEmptyString()][string]$Wire, [string]$Tier = 'restart', [string]$MaxRung = 'start-if-stopped',
                [string]$Root = $script:AuthRoot, [string]$Platform = 'linux', [long]$Now = 1899999880)
            return (Test-YurunaHostRefreshAuthorization -ProofWire $Wire -HostId $script:GoldenHost -RequestId $script:GoldenRequest `
                    -Tier $Tier -MaxRung $MaxRung -NowUnixSeconds $Now -PrivateRoot $Root -Platform $Platform)
        }
    }

    It 'authorizes the golden proof with 200 and its instants' {
        $r = Invoke-TestAuthorization -Wire $script:Vectors.versioned.wire
        Assert-True $r.Authorized 'authorized'
        Assert-Equal -Expected 'ok' -Actual $r.Reason
        Assert-Equal -Expected 200 -Actual $r.HttpStatus
        Assert-Equal -Expected 1899999880 -Actual $r.IssuedUnixSeconds
        Assert-Equal -Expected 1900000000 -Actual $r.ExpiryUnixSeconds
    }

    It 'refuses <Name> with 403 <Want>' -ForEach @(
        @{ Name = 'an unqualified platform'; Platform = 'macos'; Want = 'refresh_remote_unqualified' }
        @{ Name = 'Windows'; Platform = 'windows'; Want = 'refresh_remote_unqualified' }
        @{ Name = 'the full tier'; Tier = 'full'; Want = 'refresh_tier_not_remote' }
        @{ Name = 'a local-only rung'; MaxRung = 'reboot'; Want = 'refresh_tier_not_remote' }
        @{ Name = 'an unknown rung'; MaxRung = 'everything'; Want = 'refresh_tier_not_remote' }
        @{ Name = 'an empty wire'; Wire = ''; Want = 'refresh_proof_missing' }
        @{ Name = 'an expired proof'; Now = 1900000061; Want = 'refresh_proof_expired' }
        @{ Name = 'a proof for a lower ceiling'; MaxRung = 'probe'; Want = 'refresh_proof_policy_mismatch' }
    ) {
        $call = @{ Wire = $script:Vectors.versioned.wire }
        foreach ($k in @('Platform', 'Tier', 'MaxRung', 'Now', 'Wire')) { if ($_.ContainsKey($k)) { $call[$k] = $_[$k] } }
        $r = Invoke-TestAuthorization @call
        Assert-False $r.Authorized 'refused'
        Assert-Equal -Expected $Want -Actual $r.Reason
        Assert-Equal -Expected 403 -Actual $r.HttpStatus
    }

    It 'refuses a host with no key as unprovisioned, and a loose key as invalid' {
        Assert-Equal -Expected 'refresh_remote_unprovisioned' -Actual (Invoke-TestAuthorization -Wire $script:Vectors.versioned.wire -Root (New-TestPrivateRoot)).Reason
        if (-not $IsWindows) {
            $loose = New-TestPrivateRoot
            $null = Set-TestKeyFile -Root $loose -Content (Get-TestGoldenKeyLine) -Mode '640'
            Assert-Equal -Expected 'refresh_remote_key_invalid' -Actual (Invoke-TestAuthorization -Wire $script:Vectors.versioned.wire -Root $loose).Reason
        }
    }

    It 'reports a host id the listener cannot supply as its own failure, not as a bad key' {
        foreach ($id in @('', 'not-a-host', '42AA')) {
            $r = Test-YurunaHostRefreshAuthorization -ProofWire $script:Vectors.versioned.wire -HostId $id -RequestId $script:GoldenRequest `
                -Tier restart -MaxRung start-if-stopped -NowUnixSeconds 1899999880 -PrivateRoot $script:AuthRoot -Platform linux
            Assert-False $r.Authorized "host id '$id'"
            Assert-Equal -Expected 'refresh_verifier_failed' -Actual $r.Reason
            Assert-Equal -Expected 403 -Actual $r.HttpStatus
        }
    }

    It 'refuses proofs minted from the lab key, as a host key or as an authority' {
        $labKey = [Text.Encoding]::UTF8.GetBytes('the-shared-internal-auth-key-from-the-lab-token-exchange')
        $asHostKey = New-YurunaHostRefreshProof -HostKey $labKey -HostId $script:GoldenHost -RequestId $script:GoldenRequest -Tier restart `
            -MaxRung start-if-stopped -IssuedUnixSeconds 1899999880 -ExpiryUnixSeconds 1900000000
        Assert-Equal -Expected 'refresh_proof_invalid' -Actual (Invoke-TestAuthorization -Wire $asHostKey).Reason
        [byte[]]$derived = Get-YurunaHostRefreshHostKey -AuthorityKey $labKey -HostId $script:GoldenHost
        $asAuthority = New-YurunaHostRefreshProof -HostKey $derived -HostId $script:GoldenHost -RequestId $script:GoldenRequest -Tier restart `
            -MaxRung start-if-stopped -IssuedUnixSeconds 1899999880 -ExpiryUnixSeconds 1900000000
        Assert-Equal -Expected 'refresh_proof_invalid' -Actual (Invoke-TestAuthorization -Wire $asAuthority).Reason
        Import-Module (Join-Path $PSScriptRoot 'Test.ConfigServiceSync.psm1') -Force -Global -DisableNameChecking
        $legacy = Get-YurunaControlProof -Token 'the-shared-internal-auth-key-from-the-lab-token-exchange' -ExpiryUnixSeconds 1900000000
        Assert-Equal -Expected 'refresh_proof_malformed' -Actual (Invoke-TestAuthorization -Wire $legacy).Reason
    }

    It 'reads the clock when no instant is given' {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $fresh = New-YurunaHostRefreshProof -HostKey $script:GoldenKey -HostId $script:GoldenHost -RequestId $script:GoldenRequest -Tier restart `
            -MaxRung start-if-stopped -IssuedUnixSeconds $now -ExpiryUnixSeconds ($now + 120)
        $r = Test-YurunaHostRefreshAuthorization -ProofWire $fresh -HostId $script:GoldenHost -RequestId $script:GoldenRequest -Tier restart `
            -MaxRung start-if-stopped -PrivateRoot $script:AuthRoot -Platform linux
        Assert-True $r.Authorized "fresh proof: $($r.Reason)"
        Assert-False (Test-YurunaHostRefreshAuthorization -ProofWire $script:Vectors.versioned.wire -HostId $script:GoldenHost -RequestId $script:GoldenRequest `
                -Tier restart -MaxRung start-if-stopped -PrivateRoot $script:AuthRoot -Platform linux).Authorized 'a proof expired against the real clock'
    }

    It 'turns any exception into refresh_verifier_failed without throwing' {
        Mock -ModuleName Test.HostRefreshAuth Read-YurunaHostRefreshVerifierKey { throw 'injected failure' }
        $r = Invoke-TestAuthorization -Wire $script:Vectors.versioned.wire
        Assert-False $r.Authorized 'refused'
        Assert-Equal -Expected 'refresh_verifier_failed' -Actual $r.Reason
        Assert-Equal -Expected 403 -Actual $r.HttpStatus
    }
}

Describe 'remote qualification and state' {
    It 'judges the current platform when none is named, as the listener calls it' {
        $expected = if ($IsLinux) { 'linux' } elseif ($IsMacOS) { 'macos' } else { 'windows' }
        $q = Get-YurunaHostRefreshRemoteQualification
        Assert-Equal -Expected ($expected -eq 'linux') -Actual $q.Qualified
        $root = New-TestPrivateRoot
        $null = Set-TestKeyFile -Root $root -Content (Get-TestGoldenKeyLine)
        $state = Get-YurunaHostRefreshRemoteState -HostId $script:GoldenHost -PrivateRoot $root
        $auth = Test-YurunaHostRefreshAuthorization -ProofWire $script:Vectors.versioned.wire -HostId $script:GoldenHost -RequestId $script:GoldenRequest `
            -Tier restart -MaxRung start-if-stopped -NowUnixSeconds 1899999880 -PrivateRoot $root
        if ($IsLinux) {
            Assert-Equal -Expected 'provisioned' -Actual $state.Remote
            Assert-True $auth.Authorized "authorization without -Platform: $($auth.Reason)"
        } else {
            Assert-Equal -Expected 'unqualified' -Actual $state.Remote
            Assert-Equal -Expected 'refresh_remote_unqualified' -Actual $auth.Reason
        }
    }

    It 'declares linux qualified and macos and windows unqualified' {
        Assert-True (Get-YurunaHostRefreshRemoteQualification -Platform linux).Qualified 'linux'
        foreach ($p in @('macos', 'windows')) {
            $q = Get-YurunaHostRefreshRemoteQualification -Platform $p
            Assert-False $q.Qualified $p
            Assert-Equal -Expected 'platform_unqualified' -Actual $q.Reason
        }
    }

    It 'summarizes the key without key material' {
        $root = New-TestPrivateRoot
        Assert-Equal -Expected 'missing' -Actual (Get-YurunaHostRefreshRemoteState -HostId $script:GoldenHost -PrivateRoot $root -Platform linux).Remote
        $null = Set-TestKeyFile -Root $root -Content (Get-TestGoldenKeyLine)
        $s = Get-YurunaHostRefreshRemoteState -HostId $script:GoldenHost -PrivateRoot $root -Platform linux
        Assert-Equal -Expected 'provisioned' -Actual $s.Remote
        Assert-True ($s.KeyTag -ceq $script:Vectors.versioned.keyTag) 'key tag'
        Assert-False ($s.ContainsKey('Key')) 'the summary carries no key'
        Assert-Equal -Expected 'unqualified' -Actual (Get-YurunaHostRefreshRemoteState -HostId $script:GoldenHost -PrivateRoot $root -Platform macos).Remote
        Assert-Equal -Expected 'invalid' -Actual (Get-YurunaHostRefreshRemoteState -HostId '42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -PrivateRoot $root -Platform linux).Remote
    }
}

Describe 'provisioning: authority, export, install, remove' {
    BeforeAll {
        # The key, not the English, is what these assertions pin: new catalog
        # entries render as their key until the catalogs are compiled.
        Mock -ModuleName Test.HostRefreshAuth Format-YurunaOperatorMessage { param($Key) "KEY:$Key" }
    }

    It 'creates the authority and credential owner-only, and refuses to replace them without -Rotate' {
        $dir = [IO.Path]::Combine($script:TempRoot, 'auth-' + [Guid]::NewGuid().ToString('N'))
        $r = New-YurunaHostRefreshAuthority -Directory $dir -Confirm:$false
        Assert-True $r.Created 'created'
        $authorityText = [IO.File]::ReadAllText($r.AuthorityPath)
        $credentialText = [IO.File]::ReadAllText($r.CredentialPath)
        Assert-Match '\Ayhra1\.[A-Za-z0-9_-]{43}\n\z' $authorityText
        Assert-Match '\Ayhrc1\.[A-Za-z0-9_-]{43}\n\z' $credentialText
        if (-not $IsWindows) {
            Assert-Equal -Expected 384 -Actual (Get-TestUnixMode -Path $r.AuthorityPath) 'authority mode 0600'
            Assert-Equal -Expected 384 -Actual (Get-TestUnixMode -Path $r.CredentialPath) 'credential mode 0600'
            Assert-Equal -Expected 448 -Actual (Get-TestUnixMode -Path $dir) 'directory mode 0700'
        }
        $json = $r | ConvertTo-Json -Compress
        foreach ($secret in @($authorityText.Trim().Substring(6), $credentialText.Trim().Substring(6))) {
            Assert-False ($json.Contains($secret)) 'the record carries a secret'
        }
        $again = New-YurunaHostRefreshAuthority -Directory $dir -Confirm:$false
        Assert-False $again.Created 'no silent replacement'
        Assert-Equal -Expected 'exists' -Actual $again.Reason
        Assert-True ([IO.File]::ReadAllText($r.AuthorityPath) -ceq $authorityText) 'the authority is unchanged'
        $rotated = New-YurunaHostRefreshAuthority -Directory $dir -Rotate -Confirm:$false
        Assert-True ($rotated.Created -and $rotated.Rotated) 'rotated'
        Assert-True ($rotated.AuthorityTag -cne $r.AuthorityTag) 'a rotation is a new authority'
        $loaded = Read-YurunaHostRefreshAuthority -Directory $dir
        Assert-True ($loaded.AuthorityTag -ceq $rotated.AuthorityTag) 'the loaded authority is the rotated one'
    }

    It 'exports a host key the verifier reads back, owner-only, and never over an existing file' {
        $dir = [IO.Path]::Combine($script:TempRoot, 'auth-' + [Guid]::NewGuid().ToString('N'))
        $null = New-YurunaHostRefreshAuthority -Directory $dir -Confirm:$false
        $out = [IO.Path]::Combine($script:TempRoot, 'export-' + [Guid]::NewGuid().ToString('N') + '.key')
        $e = Export-YurunaHostRefreshHostKey -AuthorityDirectory $dir -HostId '42CCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC' -OutputPath $out -Confirm:$false
        Assert-True $e.Written 'written'
        Assert-Equal -Expected '42cccccccccccccccccccccccccccccc' -Actual $e.HostId
        if (-not $IsWindows) { Assert-Equal -Expected 384 -Actual (Get-TestUnixMode -Path $out) 'export mode 0600' }
        $line = [IO.File]::ReadAllText($out)
        Assert-False (($e | ConvertTo-Json -Compress).Contains($line.Trim().Split('.')[2])) 'the record carries the key'
        $again = Export-YurunaHostRefreshHostKey -AuthorityDirectory $dir -HostId '42cccccccccccccccccccccccccccccc' -OutputPath $out -Confirm:$false
        Assert-Equal -Expected 'exists' -Actual $again.Reason

        $root = New-TestPrivateRoot
        $i = Install-YurunaHostRefreshVerifierKey -KeyText $line -HostId '42cccccccccccccccccccccccccccccc' -PrivateRoot $root -Confirm:$false
        Assert-True $i.Installed 'installed'
        Assert-Equal -Expected $e.KeyTag -Actual $i.KeyTag
        if (-not $IsWindows) { Assert-Equal -Expected 384 -Actual (Get-TestUnixMode -Path $i.Path) 'installed mode 0600' }
        $state = Get-YurunaHostRefreshRemoteState -HostId '42cccccccccccccccccccccccccccccc' -PrivateRoot $root -Platform linux
        Assert-Equal -Expected 'provisioned' -Actual $state.Remote
        Assert-Equal -Expected $e.KeyTag -Actual $state.KeyTag

        # A proof minted from the same authority verifies against the installed key.
        [byte[]]$authority = (Read-YurunaHostRefreshAuthority -Directory $dir).Authority
        [byte[]]$hostKey = Get-YurunaHostRefreshHostKey -AuthorityKey $authority -HostId '42cccccccccccccccccccccccccccccc'
        $wire = New-YurunaHostRefreshProof -HostKey $hostKey -HostId '42cccccccccccccccccccccccccccccc' -RequestId $script:GoldenRequest -Tier restart `
            -MaxRung reclaim -IssuedUnixSeconds 1899999880 -ExpiryUnixSeconds 1900000000
        $auth = Test-YurunaHostRefreshAuthorization -ProofWire $wire -HostId '42cccccccccccccccccccccccccccccc' -RequestId $script:GoldenRequest `
            -Tier restart -MaxRung reclaim -NowUnixSeconds 1899999900 -PrivateRoot $root -Platform linux
        Assert-True $auth.Authorized "round trip: $($auth.Reason)"
    }

    It 'refuses to install a key for another host or a malformed key' {
        $root = New-TestPrivateRoot
        Assert-Throw { Install-YurunaHostRefreshVerifierKey -KeyText (Get-TestGoldenKeyLine) -HostId '42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -PrivateRoot $root -Confirm:$false } `
            'KEY:exceptions\.host_refresh_auth_host_id_mismatch'
        Assert-Throw { Install-YurunaHostRefreshVerifierKey -KeyText 'yhra1.x' -HostId $script:GoldenHost -PrivateRoot $root -Confirm:$false } `
            'KEY:exceptions\.host_refresh_auth_key_malformed'
        Assert-Throw { Install-YurunaHostRefreshVerifierKey -KeyText (Get-TestGoldenKeyLine) -HostId $script:GoldenHost -PrivateRoot ([IO.Path]::Combine($root, 'absent')) -Confirm:$false } `
            'KEY:exceptions\.host_refresh_auth_private_root_unavailable'
        Assert-False ([IO.File]::Exists([IO.Path]::Combine($root, 'remote-verifier.key'))) 'nothing was written'
    }

    It 'refuses a private root that is a link, previewed or not' -Skip:$IsWindows {
        $link = [IO.Path]::Combine($script:TempRoot, 'root-link-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType SymbolicLink -Path $link -Target (New-TestPrivateRoot)
        Assert-Throw { Install-YurunaHostRefreshVerifierKey -KeyText (Get-TestGoldenKeyLine) -HostId $script:GoldenHost -PrivateRoot $link -WhatIf } `
            'KEY:exceptions\.host_refresh_auth_private_root_unavailable'
        Assert-Throw { Install-YurunaHostRefreshVerifierKey -KeyText (Get-TestGoldenKeyLine) -HostId $script:GoldenHost -PrivateRoot $link -Confirm:$false } `
            'KEY:exceptions\.host_refresh_auth_private_root_unavailable'
        Assert-False ([IO.File]::Exists([IO.Path]::Combine($link, 'remote-verifier.key'))) 'a key was written through the link'
    }

    It 'encodes a host key line that the verifier reads back, as the golden vector spells it' {
        Assert-True ((ConvertTo-YurunaHostRefreshHostKeyLine -HostId $script:GoldenHost -Key $script:GoldenKey) -ceq (Get-TestGoldenKeyLine)) 'golden line'
        Assert-True ((ConvertTo-YurunaHostRefreshHostKeyLine -HostId '42AAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA' -Key $script:GoldenKey) -ceq (Get-TestGoldenKeyLine)) 'dashed id'
        Assert-Throw { ConvertTo-YurunaHostRefreshHostKeyLine -HostId 'not-a-host' -Key $script:GoldenKey } 'KEY:exceptions\.host_refresh_auth_invalid_claim'
        Assert-Throw { ConvertTo-YurunaHostRefreshHostKeyLine -HostId $script:GoldenHost -Key ([byte[]]::new(16)) } 'KEY:exceptions\.host_refresh_auth_invalid_claim'
        $scriptText = [IO.File]::ReadAllText($script:ScriptPath)
        foreach ($spelling in @("'yhrk1", 'ToBase64String')) {
            Assert-False ($scriptText.Contains($spelling)) "the operator script spells the key encoding itself ($spelling)"
        }
    }

    It 'checks the temporary file is private before writing any secret, and leaves nothing behind when it is not' {
        Mock -ModuleName Test.HostRefreshAuth Test-HostRefreshPrivateFileMode { $false }
        $dir = [IO.Path]::Combine($script:TempRoot, 'mode-' + [Guid]::NewGuid().ToString('N'))
        Assert-Throw { New-YurunaHostRefreshAuthority -Directory $dir -Confirm:$false } 'KEY:exceptions\.host_refresh_auth_key_write_failed'
        Assert-Equal -Expected 0 -Actual @([IO.Directory]::GetFileSystemEntries($dir)).Count 'files left in the authority directory'

        $root = New-TestPrivateRoot
        $keyPath = Set-TestKeyFile -Root $root -Content ((Get-TestGoldenKeyLine) + "`n")
        $other = ConvertTo-YurunaHostRefreshHostKeyLine -HostId $script:GoldenHost -Key ([byte[]]::new(32))
        Assert-Throw { Install-YurunaHostRefreshVerifierKey -KeyText $other -HostId $script:GoldenHost -PrivateRoot $root -Confirm:$false } 'KEY:exceptions\.host_refresh_auth_key_write_failed'
        Assert-True ([IO.File]::ReadAllText($keyPath) -ceq ((Get-TestGoldenKeyLine) + "`n")) 'the installed key changed'
        Assert-Equal -Expected 1 -Actual @([IO.Directory]::GetFileSystemEntries($root)).Count 'files left in the private root'
    }

    It 'stages both authority files before replacing either, so a failed rotation changes neither' {
        $dir = [IO.Path]::Combine($script:TempRoot, 'rotate-' + [Guid]::NewGuid().ToString('N'))
        $first = New-YurunaHostRefreshAuthority -Directory $dir -Confirm:$false
        $authorityText = [IO.File]::ReadAllText($first.AuthorityPath)
        $credentialText = [IO.File]::ReadAllText($first.CredentialPath)
        # The first staged file passes its check; the second does not.
        $script:ModeChecks = 0
        Mock -ModuleName Test.HostRefreshAuth Test-HostRefreshPrivateFileMode { $script:ModeChecks++; $script:ModeChecks -lt 2 }
        Assert-Throw { New-YurunaHostRefreshAuthority -Directory $dir -Rotate -Confirm:$false } 'KEY:exceptions\.host_refresh_auth_key_write_failed'
        Assert-Equal -Expected 2 -Actual $script:ModeChecks 'both files were staged'
        Assert-True ([IO.File]::ReadAllText($first.AuthorityPath) -ceq $authorityText) 'the authority changed'
        Assert-True ([IO.File]::ReadAllText($first.CredentialPath) -ceq $credentialText) 'the credential changed'
        Assert-Equal -Expected 2 -Actual @([IO.Directory]::GetFileSystemEntries($dir)).Count 'a temporary file was left behind'
    }

    It 'names the file it wrote when only the second move fails' {
        $dir = [IO.Path]::Combine($script:TempRoot, 'partial-' + [Guid]::NewGuid().ToString('N'))
        # A directory where the credential belongs: not an existing credential,
        # so creation proceeds, but no file can be moved onto it.
        [void][IO.Directory]::CreateDirectory([IO.Path]::Combine($dir, 'operator.credential'))
        Assert-Throw { New-YurunaHostRefreshAuthority -Directory $dir -Confirm:$false } 'KEY:exceptions\.host_refresh_auth_authority_incomplete'
        $files = @([IO.Directory]::GetFiles($dir) | ForEach-Object { [IO.Path]::GetFileName($_) })
        Assert-Equal -Expected 'authority.key' -Actual ($files -join ',') 'only the file that was moved remains'
    }

    It 'names why an authority file cannot be used instead of calling it malformed' -Skip:$IsWindows {
        $real = [IO.Path]::Combine($script:TempRoot, 'auth-' + [Guid]::NewGuid().ToString('N'))
        $null = New-YurunaHostRefreshAuthority -Directory $real -Confirm:$false
        $linked = [IO.Path]::Combine($script:TempRoot, 'linked-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($linked)
        $null = New-Item -ItemType SymbolicLink -Path ([IO.Path]::Combine($linked, 'authority.key')) -Target ([IO.Path]::Combine($real, 'authority.key'))
        Assert-Throw { Read-YurunaHostRefreshAuthority -Directory $linked } 'KEY:exceptions\.host_refresh_auth_key_unusable'

        $notFile = [IO.Path]::Combine($script:TempRoot, 'dir-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory([IO.Path]::Combine($notFile, 'authority.key'))
        Assert-Throw { Read-YurunaHostRefreshAuthority -Directory $notFile } 'KEY:exceptions\.host_refresh_auth_key_unusable'

        $large = [IO.Path]::Combine($script:TempRoot, 'large-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($large)
        $null = Set-TestKeyFile -Root $large -Content ('x' * 5000)
        [IO.File]::Move([IO.Path]::Combine($large, 'remote-verifier.key'), [IO.Path]::Combine($large, 'authority.key'))
        Assert-Throw { Read-YurunaHostRefreshAuthority -Directory $large } 'KEY:exceptions\.host_refresh_auth_key_unusable'

        $bad = [IO.Path]::Combine($script:TempRoot, 'bad-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($bad)
        $null = Set-TestKeyFile -Root $bad -Content 'yhra1.too-short'
        [IO.File]::Move([IO.Path]::Combine($bad, 'remote-verifier.key'), [IO.Path]::Combine($bad, 'authority.key'))
        Assert-Throw { Read-YurunaHostRefreshAuthority -Directory $bad } 'KEY:exceptions\.host_refresh_auth_key_malformed'
    }

    It 'throws on a missing or open authority' {
        Assert-Throw { Read-YurunaHostRefreshAuthority -Directory ([IO.Path]::Combine($script:TempRoot, 'no-authority')) } 'KEY:exceptions\.host_refresh_auth_authority_missing'
        if (-not $IsWindows) {
            $dir = [IO.Path]::Combine($script:TempRoot, 'auth-' + [Guid]::NewGuid().ToString('N'))
            $r = New-YurunaHostRefreshAuthority -Directory $dir -Confirm:$false
            [IO.File]::SetUnixFileMode($r.AuthorityPath, [IO.UnixFileMode]'UserRead, UserWrite, GroupRead')
            Assert-Throw { Read-YurunaHostRefreshAuthority -Directory $dir } 'KEY:exceptions\.host_refresh_auth_key_permissions_open'
        }
    }

    It '-WhatIf writes nothing anywhere' {
        $dir = [IO.Path]::Combine($script:TempRoot, 'whatif-' + [Guid]::NewGuid().ToString('N'))
        $r = New-YurunaHostRefreshAuthority -Directory $dir -WhatIf
        Assert-Equal -Expected 'preview' -Actual $r.Reason
        Assert-False ([IO.Directory]::Exists($dir)) 'the preview created the directory'

        $real = [IO.Path]::Combine($script:TempRoot, 'auth-' + [Guid]::NewGuid().ToString('N'))
        $null = New-YurunaHostRefreshAuthority -Directory $real -Confirm:$false
        $out = [IO.Path]::Combine($script:TempRoot, 'whatif-' + [Guid]::NewGuid().ToString('N') + '.key')
        Assert-Equal -Expected 'preview' -Actual (Export-YurunaHostRefreshHostKey -AuthorityDirectory $real -HostId $script:GoldenHost -OutputPath $out -WhatIf).Reason
        Assert-False ([IO.File]::Exists($out)) 'the preview exported a key'

        $root = New-TestPrivateRoot
        Assert-Equal -Expected 'preview' -Actual (Install-YurunaHostRefreshVerifierKey -KeyText (Get-TestGoldenKeyLine) -HostId $script:GoldenHost -PrivateRoot $root -WhatIf).Reason
        Assert-False ([IO.File]::Exists([IO.Path]::Combine($root, 'remote-verifier.key'))) 'the preview installed a key'

        # The real run creates the root after the preview would have looked.
        $notYet = [IO.Path]::Combine($script:TempRoot, 'not-yet-' + [Guid]::NewGuid().ToString('N'), '.yuruna', 'host-refresh')
        Assert-Equal -Expected 'preview' -Actual (Install-YurunaHostRefreshVerifierKey -KeyText (Get-TestGoldenKeyLine) -HostId $script:GoldenHost -PrivateRoot $notYet -WhatIf).Reason
        Assert-False ([IO.Directory]::Exists($notYet)) 'the preview created the private root'

        $null = Set-TestKeyFile -Root $root -Content (Get-TestGoldenKeyLine)
        Assert-False (Remove-YurunaHostRefreshVerifierKey -PrivateRoot $root -WhatIf).Removed 'the preview removed the key'
        Assert-True ([IO.File]::Exists([IO.Path]::Combine($root, 'remote-verifier.key'))) 'the key is still there'
        Assert-True (Remove-YurunaHostRefreshVerifierKey -PrivateRoot $root -Confirm:$false).Removed 'removed'
        Assert-Equal -Expected 'missing' -Actual (Get-YurunaHostRefreshRemoteState -HostId $script:GoldenHost -PrivateRoot $root -Platform linux).Remote
        Assert-False (Remove-YurunaHostRefreshVerifierKey -PrivateRoot $root -Confirm:$false).Removed 'removing an absent key reports nothing removed'
    }
}

Describe 'Set-HostRefreshCredential.ps1 in a child process' {
    BeforeAll {
        $script:ScriptAst = Get-YurunaTestFileAst -Path $script:ScriptPath
        $script:ChildHome = [IO.Path]::Combine($script:TempRoot, 'home-' + [Guid]::NewGuid().ToString('N'))
        $script:ChildRuntime = [IO.Path]::Combine($script:TempRoot, 'runtime-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:ChildHome)
        [void][IO.Directory]::CreateDirectory($script:ChildRuntime)
        $script:ChildHost = '42dddddddddddddddddddddddddddddd'
        $script:ChildPrivateRoot = [IO.Path]::Combine($script:ChildHome, '.yuruna', 'host-refresh')
        $script:ChildAuthorityDir = [IO.Path]::Combine($script:ChildPrivateRoot, 'authority')
        function Get-TestSecretFragment {
            # Every base64url secret body under the child's home, to prove none
            # of them reached the script's output.
            [CmdletBinding()]
            [OutputType([string[]])]
            param()
            foreach ($f in [IO.Directory]::GetFiles($script:TempRoot, '*', [IO.SearchOption]::AllDirectories)) {
                $name = [IO.Path]::GetFileName($f)
                if ($name -notin @('authority.key', 'operator.credential', 'remote-verifier.key') -and -not $name.EndsWith('.key')) { continue }
                $text = [IO.File]::ReadAllText($f).Trim()
                $text.Substring($text.LastIndexOf('.') + 1)
            }
        }
    }

    It 'declares a binding, prompts for nothing, and ends with an explicit exit' {
        $names = @($script:ScriptAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        foreach ($forbidden in @('Read-Host', 'Confirm-Step', 'Get-Credential')) { Assert-False ($names -contains $forbidden) "the script calls $forbidden" }
        Assert-False ((Get-Content -Raw -LiteralPath $script:ScriptPath).Contains('ShouldContinue')) 'the script calls ShouldContinue'
        Assert-NotNull $script:ScriptAst.ParamBlock 'param block'
        Assert-True (@($script:ScriptAst.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }).Count -eq 1) 'CmdletBinding'
        $last = $script:ScriptAst.EndBlock.Statements[-1].Extent.Text
        Assert-Equal -Expected 'exit $exitCode' -Actual $last
    }

    It 'refuses an unknown switch and an ambiguous request' {
        $r = Invoke-TestCredentialScript -Argument @('-Bogus') -HomeDirectory $script:ChildHome -RuntimeDirectory $script:ChildRuntime
        Assert-NotEqual 0 $r.ExitCode 'an unknown switch was absorbed'
        $r = Invoke-TestCredentialScript -Argument @('-InstallHostKey') -HomeDirectory $script:ChildHome -RuntimeDirectory $script:ChildRuntime
        Assert-NotEqual 0 $r.ExitCode 'an ambiguous parameter set was accepted'
        Assert-False ([IO.Directory]::Exists($script:ChildPrivateRoot)) 'a refused call created the private root'
    }

    It 'previews -NewAuthority without creating anything' {
        $r = Invoke-TestCredentialScript -Argument @('-NewAuthority', '-WhatIf') -HomeDirectory $script:ChildHome -RuntimeDirectory $script:ChildRuntime
        Assert-Equal -Expected 0 -Actual $r.ExitCode "stderr: $($r.StdErr.Length) chars"
        Assert-False ([IO.Directory]::Exists([IO.Path]::Combine($script:ChildHome, '.yuruna'))) 'the preview created state'
    }

    It 'previews -InstallHostKey on a host whose private root does not exist yet' {
        $freshHome = [IO.Path]::Combine($script:TempRoot, 'fresh-' + [Guid]::NewGuid().ToString('N'))
        $freshRuntime = [IO.Path]::Combine($script:TempRoot, 'fresh-runtime-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($freshHome)
        [void][IO.Directory]::CreateDirectory($freshRuntime)
        [IO.File]::WriteAllText([IO.Path]::Combine($freshRuntime, 'host.uuid'), "$($script:GoldenHost)`n")
        $keyFile = [IO.Path]::Combine($script:TempRoot, 'fresh-' + [Guid]::NewGuid().ToString('N') + '.key')
        [IO.File]::WriteAllText($keyFile, (Get-TestGoldenKeyLine) + "`n")
        $r = Invoke-TestCredentialScript -Argument @('-InstallHostKey', '-KeyPath', $keyFile, '-WhatIf') -HomeDirectory $freshHome -RuntimeDirectory $freshRuntime
        Assert-Equal -Expected 0 -Actual $r.ExitCode "preview exit code; stderr: $($r.StdErr.Length) chars"
        Assert-False ([IO.Directory]::Exists([IO.Path]::Combine($freshHome, '.yuruna'))) 'the preview created state'
        Assert-False ($r.StdOut.Contains($script:Vectors.versioned.hostKey)) 'the preview printed the key'
    }

    It 'reports status without a host id and without an authority' {
        $r = Invoke-TestCredentialScript -Argument @() -HomeDirectory $script:ChildHome -RuntimeDirectory $script:ChildRuntime
        Assert-Equal -Expected 0 -Actual $r.ExitCode 'status exit code'
        Assert-True ($r.StdOut.Trim().Length -gt 0) 'status printed a line'
    }

    It 'creates an authority, refuses a second one, exports, installs and removes a key' {
        $r = Invoke-TestCredentialScript -Argument @('-NewAuthority') -HomeDirectory $script:ChildHome -RuntimeDirectory $script:ChildRuntime
        Assert-Equal -Expected 0 -Actual $r.ExitCode 'NewAuthority exit code'
        Assert-True ([IO.File]::Exists([IO.Path]::Combine($script:ChildAuthorityDir, 'authority.key'))) 'authority.key'
        Assert-True ([IO.File]::Exists([IO.Path]::Combine($script:ChildAuthorityDir, 'operator.credential'))) 'operator.credential'
        if (-not $IsWindows) {
            Assert-Equal -Expected 448 -Actual (Get-TestUnixMode -Path $script:ChildPrivateRoot) 'private root 0700'
            Assert-Equal -Expected 384 -Actual (Get-TestUnixMode -Path ([IO.Path]::Combine($script:ChildAuthorityDir, 'authority.key'))) 'authority 0600'
        }
        $outputs = @($r.StdOut + $r.StdErr)

        $r = Invoke-TestCredentialScript -Argument @('-NewAuthority') -HomeDirectory $script:ChildHome -RuntimeDirectory $script:ChildRuntime
        Assert-Equal -Expected 1 -Actual $r.ExitCode 'a second authority without -Rotate'
        $outputs += $r.StdOut + $r.StdErr

        $exported = [IO.Path]::Combine($script:TempRoot, 'child-export-' + [Guid]::NewGuid().ToString('N') + '.key')
        $r = Invoke-TestCredentialScript -Argument @('-ExportHostKey', '-HostId', $script:ChildHost, '-OutputPath', $exported) -HomeDirectory $script:ChildHome -RuntimeDirectory $script:ChildRuntime
        Assert-Equal -Expected 0 -Actual $r.ExitCode 'Export exit code'
        Assert-True ([IO.File]::Exists($exported)) 'the key file'
        $outputs += $r.StdOut + $r.StdErr
        $r = Invoke-TestCredentialScript -Argument @('-ExportHostKey', '-HostId', $script:ChildHost, '-OutputPath', $exported) -HomeDirectory $script:ChildHome -RuntimeDirectory $script:ChildRuntime
        Assert-Equal -Expected 1 -Actual $r.ExitCode 'an export over an existing file'

        $r = Invoke-TestCredentialScript -Argument @('-InstallHostKey', '-KeyPath', $exported) -HomeDirectory $script:ChildHome -RuntimeDirectory $script:ChildRuntime
        Assert-Equal -Expected 1 -Actual $r.ExitCode 'an install without host.uuid must refuse, never mint an id'
        Assert-False ([IO.File]::Exists([IO.Path]::Combine($script:ChildRuntime, 'host.uuid'))) 'the script minted a host id'

        [IO.File]::WriteAllText([IO.Path]::Combine($script:ChildRuntime, 'host.uuid'), "42eeeeeeeeeeeeeeeeeeeeeeeeeeeeee`n")
        $r = Invoke-TestCredentialScript -Argument @('-InstallHostKey', '-KeyPath', $exported) -HomeDirectory $script:ChildHome -RuntimeDirectory $script:ChildRuntime
        Assert-Equal -Expected 1 -Actual $r.ExitCode 'a key for another host must refuse'

        [IO.File]::WriteAllText([IO.Path]::Combine($script:ChildRuntime, 'host.uuid'), "$($script:ChildHost)`n")
        $r = Invoke-TestCredentialScript -Argument @('-InstallHostKey', '-KeyPath', $exported) -HomeDirectory $script:ChildHome -RuntimeDirectory $script:ChildRuntime
        Assert-Equal -Expected 0 -Actual $r.ExitCode 'Install exit code'
        $outputs += $r.StdOut + $r.StdErr
        Assert-Equal -Expected 'provisioned' -Actual (Get-YurunaHostRefreshRemoteState -HostId $script:ChildHost -PrivateRoot $script:ChildPrivateRoot -Platform linux).Remote

        $r = Invoke-TestCredentialScript -Argument @('-InstallHostKey', '-AuthorityDirectory', $script:ChildAuthorityDir) -HomeDirectory $script:ChildHome -RuntimeDirectory $script:ChildRuntime
        Assert-Equal -Expected 0 -Actual $r.ExitCode 'InstallFromAuthority exit code'
        $outputs += $r.StdOut + $r.StdErr

        $r = Invoke-TestCredentialScript -Argument @() -HomeDirectory $script:ChildHome -RuntimeDirectory $script:ChildRuntime
        Assert-Equal -Expected 0 -Actual $r.ExitCode 'status exit code'
        $outputs += $r.StdOut + $r.StdErr

        $r = Invoke-TestCredentialScript -Argument @('-RemoveHostKey', '-WhatIf') -HomeDirectory $script:ChildHome -RuntimeDirectory $script:ChildRuntime
        Assert-Equal -Expected 0 -Actual $r.ExitCode 'Remove preview exit code'
        Assert-True ([IO.File]::Exists([IO.Path]::Combine($script:ChildPrivateRoot, 'remote-verifier.key'))) 'the preview removed the key'
        $r = Invoke-TestCredentialScript -Argument @('-RemoveHostKey') -HomeDirectory $script:ChildHome -RuntimeDirectory $script:ChildRuntime
        Assert-Equal -Expected 0 -Actual $r.ExitCode 'Remove exit code'
        Assert-False ([IO.File]::Exists([IO.Path]::Combine($script:ChildPrivateRoot, 'remote-verifier.key'))) 'the key is gone'

        $all = $outputs -join "`n"
        foreach ($secret in @(Get-TestSecretFragment)) {
            Assert-False ($all.Contains($secret)) 'a secret reached the script output'
        }
    }
}

Describe 'the module loads alone and agrees with the private root' {
    It 'imports in a fresh -NoProfile process without a driver or Yuruna.Common' {
        $cmd = "Import-Module '$($script:ModulePath)'; " +
        "if (-not (Get-Command Test-YurunaHostRefreshAuthorization -ErrorAction SilentlyContinue)) { exit 3 }; " +
        "exit @(Get-Module -Name 'Yuruna.Host', 'default', 'Yuruna.Common').Count"
        $r = Invoke-TestChildPwsh -Argument @('-Command', $cmd) -HomeDirectory $script:TempRoot
        Assert-Equal -Expected 0 -Actual $r.ExitCode "fresh import: $($r.StdErr)"
    }

    It 'computes the verifier key path inside the root Get-YurunaPrivateStateRoot secures' {
        $childHome = [IO.Path]::Combine($script:TempRoot, 'parity-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($childHome)
        $common = [IO.Path]::Combine($script:RepoRoot, 'automation', 'Yuruna.Common.psm1')
        $cmd = "Import-Module '$common' -DisableNameChecking; Import-Module '$($script:ModulePath)'; " +
        '$root = Get-YurunaPrivateStateRoot; if (-not $root.Resolved) { Write-Output ("UNRESOLVED " + $root.Reason); exit 4 }; ' +
        'Write-Output ("ROOT=" + $root.Path); Write-Output ("KEYDIR=" + [IO.Path]::GetDirectoryName((Get-YurunaHostRefreshVerifierKeyPath)))'
        $r = Invoke-TestChildPwsh -Argument @('-Command', $cmd) -HomeDirectory $childHome
        Assert-Equal -Expected 0 -Actual $r.ExitCode "parity child: $($r.StdOut) $($r.StdErr)"
        $rootLine = @($r.StdOut -split "`n" | Where-Object { $_ -like 'ROOT=*' })[0].Substring(5).Trim()
        $keyLine = @($r.StdOut -split "`n" | Where-Object { $_ -like 'KEYDIR=*' })[0].Substring(7).Trim()
        Assert-Equal -Expected $rootLine -Actual $keyLine
        Assert-Equal -Expected ([IO.Path]::Combine($childHome, '.yuruna', 'host-refresh')) -Actual $keyLine
    }
}

Describe 'rung vocabulary parity' {
    It 'the module, the Go SDK and the host rung declaration name the same ladder in the same order' {
        Import-Module (Join-Path $PSScriptRoot 'Test.HostRefresh.psm1') -Force -Global -DisableNameChecking
        $declared = @(Get-VirtualizationRepairRung -HostType 'host.ubuntu.kvm' | Sort-Object Order)
        $declaredNames = @($declared | ForEach-Object { $_.Name })
        for ($i = 0; $i -lt $declared.Count; $i++) { Assert-Equal -Expected $i -Actual ([int]$declared[$i].Order) "order of $($declared[$i].Name)" }
        $moduleNames = @(& (Get-Module Test.HostRefreshAuth) { $script:HostRefreshRungNames })
        $poolGo = [IO.File]::ReadAllText([IO.Path]::Combine($script:RepoRoot, 'test', 'extension', 'extension-sdk', 'pool', 'pool.go'))
        $m = [regex]::Match($poolGo, 'refreshRungNames = \[\.\.\.\]string\{([^}]*)\}')
        Assert-True $m.Success 'the Go ladder literal'
        $goNames = @([regex]::Matches($m.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        Assert-Equal -Expected ($declaredNames -join ',') -Actual ($moduleNames -join ',') 'module vs declaration'
        Assert-Equal -Expected ($declaredNames -join ',') -Actual ($goNames -join ',') 'Go vs declaration'
        $remote = @($moduleNames | Where-Object { (Test-YurunaHostRefreshAuthorization -ProofWire '' -HostId $script:GoldenHost -Tier restart -MaxRung $_ -Platform linux -PrivateRoot (New-TestPrivateRoot)).Reason -ne 'refresh_tier_not_remote' })
        Assert-Equal -Expected (($declaredNames[0..4]) -join ',') -Actual ($remote -join ',') 'the remote set is Order 0 through 4'
    }
}
