<#PSScriptInfo
.VERSION 2026.11.23
.GUID 425947a5-2f05-4cc4-9b4d-22107bbf34be
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host-repair remote authorization proof pester
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
    The host side of remote repair authorization: the shared golden vectors,
    the verdict table, the explicit-clock verifier, the verifier key's on-disk
    protections, the listener's authorization layer, provisioning, and the
    operator script.
.DESCRIPTION
    The vector file under test/extension/extension-sdk/hostrepair/testdata is
    the one the Go SDK, pool-control and the aggregator also read, so a drift
    in any HMAC input, encoding or field order fails all of them against the
    same literal values.

    Run: Invoke-Pester -Path test/modules/Test.HostRepairAuth.Tests.ps1
#>

BeforeDiscovery {
    $vectorPath = [IO.Path]::Combine($PSScriptRoot, '..', 'extension', 'extension-sdk', 'hostrepair', 'testdata', 'vectors.json')
    $script:VectorCases = @((ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($vectorPath))).cases | ForEach-Object {
            @{ Name = $_.name; Wire = $_.wire; KeyName = $_.key; HostId = $_.hostId; RequestId = $_.requestId
                Tier = $_.tier; MaxRung = $_.maxRung; NowUnix = [long]$_.nowUnix; Want = $_.want }
        })
    if ($script:VectorCases.Count -eq 0) { throw "discovery produced no host-repair vector cases: $vectorPath lists none" }
    $updateVectorPath = [IO.Path]::Combine($PSScriptRoot, '..', 'extension', 'extension-sdk', 'hostupdate', 'testdata', 'vectors.json')
    $script:UpdateVectorCases = @((ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($updateVectorPath))).cases | ForEach-Object {
            @{ Name = $_.name; Wire = $_.wire; KeyName = $_.key; HostId = $_.hostId; RequestId = $_.requestId; Scope = $_.scope
                DrainSeconds = [int]$_.drainSeconds; ExpectCommit = $_.expectCommit; NowUnix = [long]$_.nowUnix; Want = $_.want }
        })
    if ($script:UpdateVectorCases.Count -eq 0) { throw "discovery produced no host-update vector cases: $updateVectorPath lists none" }
}

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    $script:ModulePath = Join-Path $here 'Test.HostRepairAuth.psm1'
    $script:ScriptPath = [IO.Path]::Combine($script:RepoRoot, 'test', 'lab', 'Set-HostRepairCredential.ps1')
    Import-Module $script:ModulePath -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking

    $vectorPath = [IO.Path]::Combine($script:RepoRoot, 'test', 'extension', 'extension-sdk', 'hostrepair', 'testdata', 'vectors.json')
    $script:Vectors = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($vectorPath))
    $script:Authority = [Text.Encoding]::UTF8.GetBytes($script:Vectors.versioned.authorityText)
    [byte[]]$script:GoldenKey = Get-YurunaHostRepairHostKey -AuthorityKey $script:Authority -HostId $script:Vectors.versioned.hostId
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
        $fixtureHome = [IO.Path]::Combine($script:TempRoot, 'pr-' + [Guid]::NewGuid().ToString('N'))
        $dir = [IO.Path]::Combine($fixtureHome, '.yuruna', 'host-repair')
        if ($IsWindows) {
            $privateRoot = Get-YurunaPrivateStateRoot -HomePath $fixtureHome
            if (-not $privateRoot.Resolved) { throw "Private test root could not be secured: $($privateRoot.Reason)" }
            return $privateRoot.Path
        }
        [void][IO.Directory]::CreateDirectory($dir, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
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

    $updateVectorDir = [IO.Path]::Combine($script:RepoRoot, 'test', 'extension', 'extension-sdk', 'hostupdate', 'testdata')
    $script:UpdateVectors = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText([IO.Path]::Combine($updateVectorDir, 'vectors.json')))
    $script:UpdateKeyPem = [IO.File]::ReadAllText([IO.Path]::Combine($updateVectorDir, 'test-key.pem'))
    $script:OtherKeyPem = [IO.File]::ReadAllText([IO.Path]::Combine($updateVectorDir, 'other-key.pem'))

    function Get-TestUpdateWire {
        # A yup1 proof signed the way pool-control signs one, for the claims
        # given.
        [CmdletBinding()]
        [OutputType([string])]
        param(
            [Parameter(Mandatory)][string]$KeyPem, [Parameter(Mandatory)][string]$HostId, [Parameter(Mandatory)][string]$RequestId,
            [string]$Scope = 'restart', [int]$DrainSeconds = 7200, [string]$ExpectCommit = '',
            [Parameter(Mandatory)][long]$Iat, [Parameter(Mandatory)][long]$Exp
        )
        $fields = @($HostId, $RequestId, $Scope, "$DrainSeconds", $ExpectCommit, "$Iat", "$Exp")
        $rsa = [Security.Cryptography.RSA]::Create()
        try {
            $rsa.ImportFromPem($KeyPem)
            $sig = $rsa.SignData([Text.Encoding]::UTF8.GetBytes('yuruna-host-update|v2|' + ($fields -join '|')),
                [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
        } finally { $rsa.Dispose() }
        return (@('yup1') + $fields + @(ConvertTo-TestBase64Url -Bytes $sig)) -join '.'
    }

    function Set-TestRecordFile {
        # Writes a pool-control record with an explicit Unix mode.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes a file under this suite''s own temp root.')]
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][AllowEmptyString()][string]$Content, [string]$Mode = '600')
        $path = [IO.Path]::Combine($Root, 'pool-control.record')
        [IO.File]::WriteAllText($path, $Content)
        if (-not $IsWindows) { [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode][Convert]::ToInt32($Mode, 8)) }
        return $path
    }

    function Get-TestRecordText {
        [CmdletBinding()]
        [OutputType([string])]
        param([string]$PoolControl = 'http://192.0.2.10', [string]$UpdateKey = $script:UpdateVectors.publicKey, [string]$Schema = 'yuruna.pool-control-record/v1')
        return ([ordered]@{ schema = $Schema; poolControl = $PoolControl; updateKey = $UpdateKey } | ConvertTo-Json -Compress)
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
        Assert-True ((Get-YurunaHostRepairKeyTag -Key $script:GoldenKey) -ceq $script:Vectors.versioned.keyTag) 'key tag'
        Assert-True ((Get-YurunaHostRepairAuthorityTag -Authority $script:Authority) -ceq $script:Vectors.versioned.authorityTag) 'authority tag'
    }

    It 'mints the golden wire byte for byte' {
        $v = $script:Vectors.versioned
        $wire = New-YurunaHostRepairProof -HostKey $script:GoldenKey -HostId $v.hostId -RequestId $v.requestId -Tier $v.tier `
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

Describe 'the shared verdict table through Test-YurunaHostRepairProof' {
    It '<Name> -> <Want>' -ForEach $script:VectorCases {
        $key = switch ($KeyName) {
            'golden' { $script:GoldenKey }
            'empty' { [byte[]]@() }
            'authority' { $script:Authority }
        }
        $r = Test-YurunaHostRepairProof -HostKey $key -Wire $Wire -HostId $HostId -RequestId $RequestId -Tier $Tier -MaxRung $MaxRung `
            -NowUnixSeconds $NowUnix -SkewSeconds 60
        Assert-Equal -Expected $Want -Actual $r.Reason
        Assert-Equal -Expected ($Want -ceq 'ok') -Actual $r.Valid
        if ($r.Valid) {
            Assert-True ($r.HostId -ceq $HostId -and $r.RequestId -ceq $RequestId -and $r.MaxRung -ceq $MaxRung) 'accepted claims'
        }
    }

    It 'never throws on a null key or a null wire' {
        $r = Test-YurunaHostRepairProof -HostKey $null -Wire $null -HostId '' -RequestId '' -Tier '' -MaxRung '' -NowUnixSeconds 0 -SkewSeconds 60
        Assert-Equal -Expected 'repair_proof_missing' -Actual $r.Reason
        $r = Test-YurunaHostRepairProof -HostKey $null -Wire $script:Vectors.versioned.wire -HostId $script:GoldenHost -RequestId $script:GoldenRequest `
            -Tier 'restart' -MaxRung 'start-if-stopped' -NowUnixSeconds 1899999880 -SkewSeconds 60
        Assert-Equal -Expected 'repair_proof_invalid' -Actual $r.Reason
    }

    It 'accepts a dashed spelling of its own host id' {
        $dashed = '42aaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $r = Test-YurunaHostRepairProof -HostKey $script:GoldenKey -Wire $script:Vectors.versioned.wire -HostId $dashed -RequestId $script:GoldenRequest `
            -Tier 'restart' -MaxRung 'start-if-stopped' -NowUnixSeconds 1899999880 -SkewSeconds 60
        Assert-Equal -Expected 'ok' -Actual $r.Reason
    }
}

Describe 'the repair proof and the legacy control proof cannot be confused' {
    It 'the legacy verifier refuses the repair wire, and the repair verifier the legacy wire' {
        Import-Module (Join-Path $PSScriptRoot 'Test.ConfigServiceSync.psm1') -Force -Global -DisableNameChecking
        Assert-False (Test-YurunaControlProof -Token $script:Vectors.legacy.token -Wire $script:Vectors.versioned.wire) 'legacy verifier accepted a repair proof'
        $r = Test-YurunaHostRepairProof -HostKey $script:GoldenKey -Wire $script:Vectors.legacy.wire -HostId $script:GoldenHost `
            -RequestId $script:GoldenRequest -Tier 'restart' -MaxRung 'start-if-stopped' -NowUnixSeconds $script:Vectors.legacy.verifyAtUnix -SkewSeconds 60
        Assert-Equal -Expected 'repair_proof_malformed' -Actual $r.Reason
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

    It 'Test-YurunaHostRepairProof names no clock source' {
        $text = Get-TestFunctionText 'Test-YurunaHostRepairProof'
        foreach ($clock in @('UtcNow', 'Get-Date', 'DateTimeOffset', 'DateTime]::Now', 'Stopwatch', 'TickCount')) {
            Assert-False ($text.Contains($clock)) "the verifier reads the clock through $clock"
        }
        Assert-True ($text.Contains('FixedTimeEquals([byte[]]$expected, [byte[]]$given)')) 'the MAC compare is constant-time on byte[] operands'
    }

    It 'Test-YurunaHostRepairAuthorization reads the clock once, only without NowUnixSeconds' {
        $text = Get-TestFunctionText 'Test-YurunaHostRepairAuthorization'
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

Describe 'Read-YurunaHostRepairVerifierKey' {
    It 'reports a missing key' {
        $root = New-TestPrivateRoot
        $r = Read-YurunaHostRepairVerifierKey -HostId $script:GoldenHost -PrivateRoot $root
        Assert-Equal -Expected 'missing' -Actual $r.State
        Assert-Equal -Expected 'absent' -Actual $r.Reason
        Assert-Null $r.Key
    }

    It 'reads a valid key as provisioned with the golden key tag' {
        $root = New-TestPrivateRoot
        $null = Set-TestKeyFile -Root $root -Content ((Get-TestGoldenKeyLine) + "`n")
        $r = Read-YurunaHostRepairVerifierKey -HostId $script:GoldenHost -PrivateRoot $root
        Assert-Equal -Expected 'provisioned' -Actual $r.State
        Assert-True ($r.KeyTag -ceq $script:Vectors.versioned.keyTag) 'golden key tag'
        Assert-Equal -Expected (ConvertTo-TestBase64Url -Bytes $script:GoldenKey) -Actual (ConvertTo-TestBase64Url -Bytes ([byte[]]$r.Key))
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'a malformed file'; Content = 'yrpk1.not-a-key'; Want = 'key_malformed' }
        @{ Name = 'an authority in the key slot'; Content = 'yrpa1.' + ('A' * 43); Want = 'key_malformed' }
        @{ Name = 'two lines'; Content = 'LINE' + "`n" + 'LINE'; Want = 'key_malformed' }
        @{ Name = 'a key for another host'; Content = 'OTHER'; Want = 'key_host_mismatch' }
        @{ Name = 'an oversize file'; Content = ('x' * 5000); Want = 'key_malformed' }
    ) {
        $root = New-TestPrivateRoot
        $line = Get-TestGoldenKeyLine
        $text = $Content.Replace('LINE', $line).Replace('OTHER', $line.Replace($script:GoldenHost, '42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'))
        $null = Set-TestKeyFile -Root $root -Content $text
        $r = Read-YurunaHostRepairVerifierKey -HostId $script:GoldenHost -PrivateRoot $root
        Assert-Equal -Expected 'invalid' -Actual $r.State
        Assert-Equal -Expected $Want -Actual $r.Reason
        Assert-Null $r.Key
    }

    It 'refuses a key file other users can read' -Skip:$IsWindows {
        $root = New-TestPrivateRoot
        $null = Set-TestKeyFile -Root $root -Content (Get-TestGoldenKeyLine) -Mode '644'
        $r = Read-YurunaHostRepairVerifierKey -HostId $script:GoldenHost -PrivateRoot $root
        Assert-Equal -Expected 'key_permissions_open' -Actual $r.Reason
    }

    It 'creates Windows fixtures with only owner access before writing key bytes' -Skip:(-not $IsWindows) {
        $root = New-TestPrivateRoot
        $rootAcl = Get-Acl -LiteralPath $root -ErrorAction Stop
        Assert-True $rootAcl.AreAccessRulesProtected 'the private root must not inherit the temp directory ACL'
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        foreach ($rule in $rootAcl.Access) {
            Assert-Equal -Expected $identity -Actual $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        }
        $text = (Get-TestGoldenKeyLine) + "`n"
        $path = Set-TestKeyFile -Root $root -Content $text
        Assert-Equal -Expected $text -Actual ([IO.File]::ReadAllText($path))
        foreach ($rule in (Get-Acl -LiteralPath $path -ErrorAction Stop).Access) {
            Assert-Equal -Expected $identity -Actual $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        }
        Assert-Equal -Expected 'provisioned' -Actual (Read-YurunaHostRepairVerifierKey -HostId $script:GoldenHost -PrivateRoot $root).State
    }

    It 'refuses a Windows key file with a foreign reader' -Skip:(-not $IsWindows) {
        $root = New-TestPrivateRoot
        $path = Set-TestKeyFile -Root $root -Content (Get-TestGoldenKeyLine)
        $acl = Get-Acl -LiteralPath $path -ErrorAction Stop
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'), 'Read', 'Allow'))
        Set-Acl -LiteralPath $path -AclObject $acl -ErrorAction Stop -WhatIf:$false -Confirm:$false
        Assert-Equal -Expected 'key_permissions_open' -Actual (Read-YurunaHostRepairVerifierKey -HostId $script:GoldenHost -PrivateRoot $root).Reason
    }

    It 'refuses a key file that is a symbolic link, and a root that is one' -Skip:$IsWindows {
        $root = New-TestPrivateRoot
        $target = Set-TestKeyFile -Root (New-TestPrivateRoot) -Content (Get-TestGoldenKeyLine)
        $null = New-Item -ItemType SymbolicLink -Path ([IO.Path]::Combine($root, 'remote-verifier.key')) -Target $target
        Assert-Equal -Expected 'key_reparse_point' -Actual (Read-YurunaHostRepairVerifierKey -HostId $script:GoldenHost -PrivateRoot $root).Reason

        $realRoot = New-TestPrivateRoot
        $null = Set-TestKeyFile -Root $realRoot -Content (Get-TestGoldenKeyLine)
        $linkRoot = [IO.Path]::Combine($script:TempRoot, 'link-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType SymbolicLink -Path $linkRoot -Target $realRoot
        Assert-Equal -Expected 'key_reparse_point' -Actual (Read-YurunaHostRepairVerifierKey -HostId $script:GoldenHost -PrivateRoot $linkRoot).Reason
    }

    It 'reports an unknown host id as host_id_unavailable' {
        $root = New-TestPrivateRoot
        $null = Set-TestKeyFile -Root $root -Content (Get-TestGoldenKeyLine)
        foreach ($id in @('', 'not-a-host', '42AA')) {
            Assert-Equal -Expected 'host_id_unavailable' -Actual (Read-YurunaHostRepairVerifierKey -HostId $id -PrivateRoot $root).Reason
        }
        Assert-Equal -Expected 'provisioned' -Actual (Read-YurunaHostRepairVerifierKey -HostId '42AAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA' -PrivateRoot $root).State
    }
}

Describe 'Test-YurunaHostRepairAuthorization' {
    BeforeAll {
        $script:AuthRoot = New-TestPrivateRoot
        $null = Set-TestKeyFile -Root $script:AuthRoot -Content (Get-TestGoldenKeyLine)
        function Invoke-TestAuthorization {
            [CmdletBinding()]
            [OutputType([hashtable])]
            param([AllowEmptyString()][string]$Wire, [string]$Tier = 'restart', [string]$MaxRung = 'start-if-stopped',
                [string]$Root = $script:AuthRoot, [string]$Platform = 'linux', [long]$Now = 1899999880)
            return (Test-YurunaHostRepairAuthorization -ProofWire $Wire -HostId $script:GoldenHost -RequestId $script:GoldenRequest `
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
        @{ Name = 'an unqualified platform'; Platform = 'macos'; Want = 'repair_remote_unqualified' }
        @{ Name = 'Windows'; Platform = 'windows'; Want = 'repair_remote_unqualified' }
        @{ Name = 'the full tier'; Tier = 'full'; Want = 'repair_tier_not_remote' }
        @{ Name = 'a local-only rung'; MaxRung = 'reboot'; Want = 'repair_tier_not_remote' }
        @{ Name = 'an unknown rung'; MaxRung = 'everything'; Want = 'repair_tier_not_remote' }
        @{ Name = 'an empty wire'; Wire = ''; Want = 'repair_proof_missing' }
        @{ Name = 'an expired proof'; Now = 1900000061; Want = 'repair_proof_expired' }
        @{ Name = 'a proof for a lower ceiling'; MaxRung = 'probe'; Want = 'repair_proof_policy_mismatch' }
    ) {
        $call = @{ Wire = $script:Vectors.versioned.wire }
        foreach ($k in @('Platform', 'Tier', 'MaxRung', 'Now', 'Wire')) { if ($_.ContainsKey($k)) { $call[$k] = $_[$k] } }
        $r = Invoke-TestAuthorization @call
        Assert-False $r.Authorized 'refused'
        Assert-Equal -Expected $Want -Actual $r.Reason
        Assert-Equal -Expected 403 -Actual $r.HttpStatus
    }

    It 'refuses a host with no key as unprovisioned, and a loose key as invalid' {
        Assert-Equal -Expected 'repair_remote_unprovisioned' -Actual (Invoke-TestAuthorization -Wire $script:Vectors.versioned.wire -Root (New-TestPrivateRoot)).Reason
        if (-not $IsWindows) {
            $loose = New-TestPrivateRoot
            $null = Set-TestKeyFile -Root $loose -Content (Get-TestGoldenKeyLine) -Mode '640'
            Assert-Equal -Expected 'repair_remote_key_invalid' -Actual (Invoke-TestAuthorization -Wire $script:Vectors.versioned.wire -Root $loose).Reason
        }
    }

    It 'reports a host id the listener cannot supply as its own failure, not as a bad key' {
        foreach ($id in @('', 'not-a-host', '42AA')) {
            $r = Test-YurunaHostRepairAuthorization -ProofWire $script:Vectors.versioned.wire -HostId $id -RequestId $script:GoldenRequest `
                -Tier restart -MaxRung start-if-stopped -NowUnixSeconds 1899999880 -PrivateRoot $script:AuthRoot -Platform linux
            Assert-False $r.Authorized "host id '$id'"
            Assert-Equal -Expected 'repair_verifier_failed' -Actual $r.Reason
            Assert-Equal -Expected 403 -Actual $r.HttpStatus
        }
    }

    It 'refuses proofs minted from the lab key, as a host key or as an authority' {
        $labKey = [Text.Encoding]::UTF8.GetBytes('the-shared-internal-auth-key-from-the-lab-token-exchange')
        $asHostKey = New-YurunaHostRepairProof -HostKey $labKey -HostId $script:GoldenHost -RequestId $script:GoldenRequest -Tier restart `
            -MaxRung start-if-stopped -IssuedUnixSeconds 1899999880 -ExpiryUnixSeconds 1900000000
        Assert-Equal -Expected 'repair_proof_invalid' -Actual (Invoke-TestAuthorization -Wire $asHostKey).Reason
        [byte[]]$derived = Get-YurunaHostRepairHostKey -AuthorityKey $labKey -HostId $script:GoldenHost
        $asAuthority = New-YurunaHostRepairProof -HostKey $derived -HostId $script:GoldenHost -RequestId $script:GoldenRequest -Tier restart `
            -MaxRung start-if-stopped -IssuedUnixSeconds 1899999880 -ExpiryUnixSeconds 1900000000
        Assert-Equal -Expected 'repair_proof_invalid' -Actual (Invoke-TestAuthorization -Wire $asAuthority).Reason
        Import-Module (Join-Path $PSScriptRoot 'Test.ConfigServiceSync.psm1') -Force -Global -DisableNameChecking
        $legacy = Get-YurunaControlProof -Token 'the-shared-internal-auth-key-from-the-lab-token-exchange' -ExpiryUnixSeconds 1900000000
        Assert-Equal -Expected 'repair_proof_malformed' -Actual (Invoke-TestAuthorization -Wire $legacy).Reason
    }

    It 'reads the clock when no instant is given' {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $fresh = New-YurunaHostRepairProof -HostKey $script:GoldenKey -HostId $script:GoldenHost -RequestId $script:GoldenRequest -Tier restart `
            -MaxRung start-if-stopped -IssuedUnixSeconds $now -ExpiryUnixSeconds ($now + 120)
        $r = Test-YurunaHostRepairAuthorization -ProofWire $fresh -HostId $script:GoldenHost -RequestId $script:GoldenRequest -Tier restart `
            -MaxRung start-if-stopped -PrivateRoot $script:AuthRoot -Platform linux
        Assert-True $r.Authorized "fresh proof: $($r.Reason)"
        Assert-False (Test-YurunaHostRepairAuthorization -ProofWire $script:Vectors.versioned.wire -HostId $script:GoldenHost -RequestId $script:GoldenRequest `
                -Tier restart -MaxRung start-if-stopped -PrivateRoot $script:AuthRoot -Platform linux).Authorized 'a proof expired against the real clock'
    }

    It 'turns any exception into repair_verifier_failed without throwing' {
        Mock -ModuleName Test.HostRepairAuth Read-YurunaHostRepairVerifierKey { throw 'injected failure' }
        $r = Invoke-TestAuthorization -Wire $script:Vectors.versioned.wire
        Assert-False $r.Authorized 'refused'
        Assert-Equal -Expected 'repair_verifier_failed' -Actual $r.Reason
        Assert-Equal -Expected 403 -Actual $r.HttpStatus
    }
}

Describe 'remote qualification and state' {
    It 'judges the current platform when none is named, as the listener calls it' {
        $expected = if ($IsLinux) { 'linux' } elseif ($IsMacOS) { 'macos' } else { 'windows' }
        $q = Get-YurunaHostRepairRemoteQualification
        Assert-Equal -Expected ($expected -eq 'linux') -Actual $q.Qualified
        $root = New-TestPrivateRoot
        $null = Set-TestKeyFile -Root $root -Content (Get-TestGoldenKeyLine)
        $state = Get-YurunaHostRepairRemoteState -HostId $script:GoldenHost -PrivateRoot $root
        $auth = Test-YurunaHostRepairAuthorization -ProofWire $script:Vectors.versioned.wire -HostId $script:GoldenHost -RequestId $script:GoldenRequest `
            -Tier restart -MaxRung start-if-stopped -NowUnixSeconds 1899999880 -PrivateRoot $root
        if ($IsLinux) {
            Assert-Equal -Expected 'provisioned' -Actual $state.Remote
            Assert-True $auth.Authorized "authorization without -Platform: $($auth.Reason)"
        } else {
            Assert-Equal -Expected 'unqualified' -Actual $state.Remote
            Assert-Equal -Expected 'repair_remote_unqualified' -Actual $auth.Reason
        }
    }

    It 'declares linux qualified and macos and windows unqualified' {
        Assert-True (Get-YurunaHostRepairRemoteQualification -Platform linux).Qualified 'linux'
        foreach ($p in @('macos', 'windows')) {
            $q = Get-YurunaHostRepairRemoteQualification -Platform $p
            Assert-False $q.Qualified $p
            Assert-Equal -Expected 'platform_unqualified' -Actual $q.Reason
        }
    }

    It 'summarizes the key without key material' {
        $root = New-TestPrivateRoot
        Assert-Equal -Expected 'missing' -Actual (Get-YurunaHostRepairRemoteState -HostId $script:GoldenHost -PrivateRoot $root -Platform linux).Remote
        $null = Set-TestKeyFile -Root $root -Content (Get-TestGoldenKeyLine)
        $s = Get-YurunaHostRepairRemoteState -HostId $script:GoldenHost -PrivateRoot $root -Platform linux
        Assert-Equal -Expected 'provisioned' -Actual $s.Remote
        Assert-True ($s.KeyTag -ceq $script:Vectors.versioned.keyTag) 'key tag'
        Assert-False ($s.ContainsKey('Key')) 'the summary carries no key'
        Assert-Equal -Expected 'unqualified' -Actual (Get-YurunaHostRepairRemoteState -HostId $script:GoldenHost -PrivateRoot $root -Platform macos).Remote
        Assert-Equal -Expected 'invalid' -Actual (Get-YurunaHostRepairRemoteState -HostId '42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -PrivateRoot $root -Platform linux).Remote
    }
}

Describe 'provisioning: authority, export, install, remove' {
    BeforeAll {
        # The key, not the English, is what these assertions pin: new catalog
        # entries render as their key until the catalogs are compiled.
        Mock -ModuleName Test.HostRepairAuth Format-YurunaOperatorMessage { param($Key) "KEY:$Key" }
    }

    It 'creates the authority and credential owner-only, and refuses to replace them without -Rotate' {
        $dir = [IO.Path]::Combine($script:TempRoot, 'auth-' + [Guid]::NewGuid().ToString('N'))
        $r = New-YurunaHostRepairAuthority -Directory $dir -Confirm:$false
        Assert-True $r.Created 'created'
        $authorityText = [IO.File]::ReadAllText($r.AuthorityPath)
        $credentialText = [IO.File]::ReadAllText($r.CredentialPath)
        Assert-Match '\Ayrpa1\.[A-Za-z0-9_-]{43}\n\z' $authorityText
        Assert-Match '\Ayoc1\.[A-Za-z0-9_-]{43}\n\z' $credentialText
        if (-not $IsWindows) {
            Assert-Equal -Expected 384 -Actual (Get-TestUnixMode -Path $r.AuthorityPath) 'authority mode 0600'
            Assert-Equal -Expected 384 -Actual (Get-TestUnixMode -Path $r.CredentialPath) 'credential mode 0600'
            Assert-Equal -Expected 448 -Actual (Get-TestUnixMode -Path $dir) 'directory mode 0700'
        }
        $json = $r | ConvertTo-Json -Compress
        foreach ($secret in @($authorityText.Trim().Substring(6), $credentialText.Trim().Substring(6))) {
            Assert-False ($json.Contains($secret)) 'the record carries a secret'
        }
        $again = New-YurunaHostRepairAuthority -Directory $dir -Confirm:$false
        Assert-False $again.Created 'no silent replacement'
        Assert-Equal -Expected 'exists' -Actual $again.Reason
        Assert-True ([IO.File]::ReadAllText($r.AuthorityPath) -ceq $authorityText) 'the authority is unchanged'
        $rotated = New-YurunaHostRepairAuthority -Directory $dir -Rotate -Confirm:$false
        Assert-True ($rotated.Created -and $rotated.Rotated) 'rotated'
        Assert-True ($rotated.AuthorityTag -cne $r.AuthorityTag) 'a rotation is a new authority'
        $loaded = Read-YurunaHostRepairAuthority -Directory $dir
        Assert-True ($loaded.AuthorityTag -ceq $rotated.AuthorityTag) 'the loaded authority is the rotated one'
    }

    It 'exports a host key the verifier reads back, owner-only, and never over an existing file' {
        $dir = [IO.Path]::Combine($script:TempRoot, 'auth-' + [Guid]::NewGuid().ToString('N'))
        $null = New-YurunaHostRepairAuthority -Directory $dir -Confirm:$false
        $out = [IO.Path]::Combine($script:TempRoot, 'export-' + [Guid]::NewGuid().ToString('N') + '.key')
        $e = Export-YurunaHostRepairHostKey -AuthorityDirectory $dir -HostId '42CCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC' -OutputPath $out -Confirm:$false
        Assert-True $e.Written 'written'
        Assert-Equal -Expected '42cccccccccccccccccccccccccccccc' -Actual $e.HostId
        if (-not $IsWindows) { Assert-Equal -Expected 384 -Actual (Get-TestUnixMode -Path $out) 'export mode 0600' }
        $line = [IO.File]::ReadAllText($out)
        Assert-False (($e | ConvertTo-Json -Compress).Contains($line.Trim().Split('.')[2])) 'the record carries the key'
        $again = Export-YurunaHostRepairHostKey -AuthorityDirectory $dir -HostId '42cccccccccccccccccccccccccccccc' -OutputPath $out -Confirm:$false
        Assert-Equal -Expected 'exists' -Actual $again.Reason

        $root = New-TestPrivateRoot
        $i = Install-YurunaHostRepairVerifierKey -KeyText $line -HostId '42cccccccccccccccccccccccccccccc' -PrivateRoot $root -Confirm:$false
        Assert-True $i.Installed 'installed'
        Assert-Equal -Expected $e.KeyTag -Actual $i.KeyTag
        if (-not $IsWindows) { Assert-Equal -Expected 384 -Actual (Get-TestUnixMode -Path $i.Path) 'installed mode 0600' }
        $state = Get-YurunaHostRepairRemoteState -HostId '42cccccccccccccccccccccccccccccc' -PrivateRoot $root -Platform linux
        Assert-Equal -Expected 'provisioned' -Actual $state.Remote
        Assert-Equal -Expected $e.KeyTag -Actual $state.KeyTag

        # A proof minted from the same authority verifies against the installed key.
        [byte[]]$authority = (Read-YurunaHostRepairAuthority -Directory $dir).Authority
        [byte[]]$hostKey = Get-YurunaHostRepairHostKey -AuthorityKey $authority -HostId '42cccccccccccccccccccccccccccccc'
        $wire = New-YurunaHostRepairProof -HostKey $hostKey -HostId '42cccccccccccccccccccccccccccccc' -RequestId $script:GoldenRequest -Tier restart `
            -MaxRung reclaim -IssuedUnixSeconds 1899999880 -ExpiryUnixSeconds 1900000000
        $auth = Test-YurunaHostRepairAuthorization -ProofWire $wire -HostId '42cccccccccccccccccccccccccccccc' -RequestId $script:GoldenRequest `
            -Tier restart -MaxRung reclaim -NowUnixSeconds 1899999900 -PrivateRoot $root -Platform linux
        Assert-True $auth.Authorized "round trip: $($auth.Reason)"
    }

    It 'refuses to install a key for another host or a malformed key' {
        $root = New-TestPrivateRoot
        Assert-Throw { Install-YurunaHostRepairVerifierKey -KeyText (Get-TestGoldenKeyLine) -HostId '42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' -PrivateRoot $root -Confirm:$false } `
            'KEY:exceptions\.host_repair_auth_host_id_mismatch'
        Assert-Throw { Install-YurunaHostRepairVerifierKey -KeyText 'yrpa1.x' -HostId $script:GoldenHost -PrivateRoot $root -Confirm:$false } `
            'KEY:exceptions\.host_repair_auth_key_malformed'
        Assert-Throw { Install-YurunaHostRepairVerifierKey -KeyText (Get-TestGoldenKeyLine) -HostId $script:GoldenHost -PrivateRoot ([IO.Path]::Combine($root, 'absent')) -Confirm:$false } `
            'KEY:exceptions\.host_repair_auth_private_root_unavailable'
        Assert-False ([IO.File]::Exists([IO.Path]::Combine($root, 'remote-verifier.key'))) 'nothing was written'
    }

    It 'refuses a private root that is a link, previewed or not' -Skip:$IsWindows {
        $link = [IO.Path]::Combine($script:TempRoot, 'root-link-' + [Guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType SymbolicLink -Path $link -Target (New-TestPrivateRoot)
        Assert-Throw { Install-YurunaHostRepairVerifierKey -KeyText (Get-TestGoldenKeyLine) -HostId $script:GoldenHost -PrivateRoot $link -WhatIf } `
            'KEY:exceptions\.host_repair_auth_private_root_unavailable'
        Assert-Throw { Install-YurunaHostRepairVerifierKey -KeyText (Get-TestGoldenKeyLine) -HostId $script:GoldenHost -PrivateRoot $link -Confirm:$false } `
            'KEY:exceptions\.host_repair_auth_private_root_unavailable'
        Assert-False ([IO.File]::Exists([IO.Path]::Combine($link, 'remote-verifier.key'))) 'a key was written through the link'
    }

    It 'encodes a host key line that the verifier reads back, as the golden vector spells it' {
        Assert-True ((ConvertTo-YurunaHostRepairHostKeyLine -HostId $script:GoldenHost -Key $script:GoldenKey) -ceq (Get-TestGoldenKeyLine)) 'golden line'
        Assert-True ((ConvertTo-YurunaHostRepairHostKeyLine -HostId '42AAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA' -Key $script:GoldenKey) -ceq (Get-TestGoldenKeyLine)) 'dashed id'
        Assert-Throw { ConvertTo-YurunaHostRepairHostKeyLine -HostId 'not-a-host' -Key $script:GoldenKey } 'KEY:exceptions\.host_repair_auth_invalid_claim'
        Assert-Throw { ConvertTo-YurunaHostRepairHostKeyLine -HostId $script:GoldenHost -Key ([byte[]]::new(16)) } 'KEY:exceptions\.host_repair_auth_invalid_claim'
        $scriptText = [IO.File]::ReadAllText($script:ScriptPath)
        foreach ($spelling in @("'yrpk1", 'ToBase64String')) {
            Assert-False ($scriptText.Contains($spelling)) "the operator script spells the key encoding itself ($spelling)"
        }
    }

    It 'checks the temporary file is private before writing any secret, and leaves nothing behind when it is not' {
        Mock -ModuleName Test.HostRepairAuth Test-HostRepairPrivateFileMode { $false }
        $dir = [IO.Path]::Combine($script:TempRoot, 'mode-' + [Guid]::NewGuid().ToString('N'))
        Assert-Throw { New-YurunaHostRepairAuthority -Directory $dir -Confirm:$false } 'KEY:exceptions\.host_repair_auth_key_write_failed'
        Assert-Equal -Expected 0 -Actual @([IO.Directory]::GetFileSystemEntries($dir)).Count 'files left in the authority directory'

        $root = New-TestPrivateRoot
        $keyPath = Set-TestKeyFile -Root $root -Content ((Get-TestGoldenKeyLine) + "`n")
        $other = ConvertTo-YurunaHostRepairHostKeyLine -HostId $script:GoldenHost -Key ([byte[]]::new(32))
        Assert-Throw { Install-YurunaHostRepairVerifierKey -KeyText $other -HostId $script:GoldenHost -PrivateRoot $root -Confirm:$false } 'KEY:exceptions\.host_repair_auth_key_write_failed'
        Assert-True ([IO.File]::ReadAllText($keyPath) -ceq ((Get-TestGoldenKeyLine) + "`n")) 'the installed key changed'
        Assert-Equal -Expected 1 -Actual @([IO.Directory]::GetFileSystemEntries($root)).Count 'files left in the private root'
    }

    It 'stages both authority files before replacing either, so a failed rotation changes neither' {
        $dir = [IO.Path]::Combine($script:TempRoot, 'rotate-' + [Guid]::NewGuid().ToString('N'))
        $first = New-YurunaHostRepairAuthority -Directory $dir -Confirm:$false
        $authorityText = [IO.File]::ReadAllText($first.AuthorityPath)
        $credentialText = [IO.File]::ReadAllText($first.CredentialPath)
        # The first staged file passes its check; the second does not.
        $script:ModeChecks = 0
        Mock -ModuleName Test.HostRepairAuth Test-HostRepairPrivateFileMode { $script:ModeChecks++; $script:ModeChecks -lt 2 }
        Assert-Throw { New-YurunaHostRepairAuthority -Directory $dir -Rotate -Confirm:$false } 'KEY:exceptions\.host_repair_auth_key_write_failed'
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
        Assert-Throw { New-YurunaHostRepairAuthority -Directory $dir -Confirm:$false } 'KEY:exceptions\.host_repair_auth_authority_incomplete'
        $files = @([IO.Directory]::GetFiles($dir) | ForEach-Object { [IO.Path]::GetFileName($_) })
        Assert-Equal -Expected 'authority.key' -Actual ($files -join ',') 'only the file that was moved remains'
    }

    It 'names why an authority file cannot be used instead of calling it malformed' -Skip:$IsWindows {
        $real = [IO.Path]::Combine($script:TempRoot, 'auth-' + [Guid]::NewGuid().ToString('N'))
        $null = New-YurunaHostRepairAuthority -Directory $real -Confirm:$false
        $linked = [IO.Path]::Combine($script:TempRoot, 'linked-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($linked)
        $null = New-Item -ItemType SymbolicLink -Path ([IO.Path]::Combine($linked, 'authority.key')) -Target ([IO.Path]::Combine($real, 'authority.key'))
        Assert-Throw { Read-YurunaHostRepairAuthority -Directory $linked } 'KEY:exceptions\.host_repair_auth_key_unusable'

        $notFile = [IO.Path]::Combine($script:TempRoot, 'dir-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory([IO.Path]::Combine($notFile, 'authority.key'))
        Assert-Throw { Read-YurunaHostRepairAuthority -Directory $notFile } 'KEY:exceptions\.host_repair_auth_key_unusable'

        $large = [IO.Path]::Combine($script:TempRoot, 'large-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($large)
        $null = Set-TestKeyFile -Root $large -Content ('x' * 5000)
        [IO.File]::Move([IO.Path]::Combine($large, 'remote-verifier.key'), [IO.Path]::Combine($large, 'authority.key'))
        Assert-Throw { Read-YurunaHostRepairAuthority -Directory $large } 'KEY:exceptions\.host_repair_auth_key_unusable'

        $bad = [IO.Path]::Combine($script:TempRoot, 'bad-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($bad)
        $null = Set-TestKeyFile -Root $bad -Content 'yrpa1.too-short'
        [IO.File]::Move([IO.Path]::Combine($bad, 'remote-verifier.key'), [IO.Path]::Combine($bad, 'authority.key'))
        Assert-Throw { Read-YurunaHostRepairAuthority -Directory $bad } 'KEY:exceptions\.host_repair_auth_key_malformed'
    }

    It 'throws on a missing or open authority' {
        Assert-Throw { Read-YurunaHostRepairAuthority -Directory ([IO.Path]::Combine($script:TempRoot, 'no-authority')) } 'KEY:exceptions\.host_repair_auth_authority_missing'
        if (-not $IsWindows) {
            $dir = [IO.Path]::Combine($script:TempRoot, 'auth-' + [Guid]::NewGuid().ToString('N'))
            $r = New-YurunaHostRepairAuthority -Directory $dir -Confirm:$false
            [IO.File]::SetUnixFileMode($r.AuthorityPath, [IO.UnixFileMode]'UserRead, UserWrite, GroupRead')
            Assert-Throw { Read-YurunaHostRepairAuthority -Directory $dir } 'KEY:exceptions\.host_repair_auth_key_permissions_open'
        }
    }

    It '-WhatIf writes nothing anywhere' {
        $dir = [IO.Path]::Combine($script:TempRoot, 'whatif-' + [Guid]::NewGuid().ToString('N'))
        $r = New-YurunaHostRepairAuthority -Directory $dir -WhatIf
        Assert-Equal -Expected 'preview' -Actual $r.Reason
        Assert-False ([IO.Directory]::Exists($dir)) 'the preview created the directory'

        $real = [IO.Path]::Combine($script:TempRoot, 'auth-' + [Guid]::NewGuid().ToString('N'))
        $null = New-YurunaHostRepairAuthority -Directory $real -Confirm:$false
        $out = [IO.Path]::Combine($script:TempRoot, 'whatif-' + [Guid]::NewGuid().ToString('N') + '.key')
        Assert-Equal -Expected 'preview' -Actual (Export-YurunaHostRepairHostKey -AuthorityDirectory $real -HostId $script:GoldenHost -OutputPath $out -WhatIf).Reason
        Assert-False ([IO.File]::Exists($out)) 'the preview exported a key'

        $root = New-TestPrivateRoot
        Assert-Equal -Expected 'preview' -Actual (Install-YurunaHostRepairVerifierKey -KeyText (Get-TestGoldenKeyLine) -HostId $script:GoldenHost -PrivateRoot $root -WhatIf).Reason
        Assert-False ([IO.File]::Exists([IO.Path]::Combine($root, 'remote-verifier.key'))) 'the preview installed a key'

        # The real run creates the root after the preview would have looked.
        $notYet = [IO.Path]::Combine($script:TempRoot, 'not-yet-' + [Guid]::NewGuid().ToString('N'), '.yuruna', 'host-repair')
        Assert-Equal -Expected 'preview' -Actual (Install-YurunaHostRepairVerifierKey -KeyText (Get-TestGoldenKeyLine) -HostId $script:GoldenHost -PrivateRoot $notYet -WhatIf).Reason
        Assert-False ([IO.Directory]::Exists($notYet)) 'the preview created the private root'

        $null = Set-TestKeyFile -Root $root -Content (Get-TestGoldenKeyLine)
        Assert-False (Remove-YurunaHostRepairVerifierKey -PrivateRoot $root -WhatIf).Removed 'the preview removed the key'
        Assert-True ([IO.File]::Exists([IO.Path]::Combine($root, 'remote-verifier.key'))) 'the key is still there'
        Assert-True (Remove-YurunaHostRepairVerifierKey -PrivateRoot $root -Confirm:$false).Removed 'removed'
        Assert-Equal -Expected 'missing' -Actual (Get-YurunaHostRepairRemoteState -HostId $script:GoldenHost -PrivateRoot $root -Platform linux).Remote
        Assert-False (Remove-YurunaHostRepairVerifierKey -PrivateRoot $root -Confirm:$false).Removed 'removing an absent key reports nothing removed'
    }
}

Describe 'Set-HostRepairCredential.ps1 in a child process' {
    BeforeAll {
        $script:ScriptAst = Get-YurunaTestFileAst -Path $script:ScriptPath
        $script:ChildHome = [IO.Path]::Combine($script:TempRoot, 'home-' + [Guid]::NewGuid().ToString('N'))
        $script:ChildRuntime = [IO.Path]::Combine($script:TempRoot, 'runtime-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:ChildHome)
        [void][IO.Directory]::CreateDirectory($script:ChildRuntime)
        $script:ChildHost = '42dddddddddddddddddddddddddddddd'
        $script:ChildPrivateRoot = [IO.Path]::Combine($script:ChildHome, '.yuruna', 'host-repair')
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
        Assert-Equal -Expected 'provisioned' -Actual (Get-YurunaHostRepairRemoteState -HostId $script:ChildHost -PrivateRoot $script:ChildPrivateRoot -Platform linux).Remote

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
        "if (-not (Get-Command Test-YurunaHostRepairAuthorization -ErrorAction SilentlyContinue)) { exit 3 }; " +
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
        'Write-Output ("ROOT=" + $root.Path); Write-Output ("KEYDIR=" + [IO.Path]::GetDirectoryName((Get-YurunaHostRepairVerifierKeyPath)))'
        $r = Invoke-TestChildPwsh -Argument @('-Command', $cmd) -HomeDirectory $childHome
        Assert-Equal -Expected 0 -Actual $r.ExitCode "parity child: $($r.StdOut) $($r.StdErr)"
        $rootLine = @($r.StdOut -split "`n" | Where-Object { $_ -like 'ROOT=*' })[0].Substring(5).Trim()
        $keyLine = @($r.StdOut -split "`n" | Where-Object { $_ -like 'KEYDIR=*' })[0].Substring(7).Trim()
        Assert-Equal -Expected $rootLine -Actual $keyLine
        Assert-Equal -Expected ([IO.Path]::Combine($childHome, '.yuruna', 'host-repair')) -Actual $keyLine
    }
}

Describe 'rung vocabulary parity' {
    It 'the module, the Go SDK and the host rung declaration name the same ladder in the same order' {
        Import-Module (Join-Path $PSScriptRoot 'Test.HostRepair.psm1') -Force -Global -DisableNameChecking
        $declared = @(Get-VirtualizationRepairRung -HostType 'host.ubuntu.kvm' | Sort-Object Order)
        $declaredNames = @($declared | ForEach-Object { $_.Name })
        for ($i = 0; $i -lt $declared.Count; $i++) { Assert-Equal -Expected $i -Actual ([int]$declared[$i].Order) "order of $($declared[$i].Name)" }
        $moduleNames = @(& (Get-Module Test.HostRepairAuth) { $script:HostRepairRungNames })
        $poolGo = [IO.File]::ReadAllText([IO.Path]::Combine($script:RepoRoot, 'test', 'extension', 'extension-sdk', 'pool', 'pool.go'))
        $m = [regex]::Match($poolGo, 'repairRungNames = \[\.\.\.\]string\{([^}]*)\}')
        Assert-True $m.Success 'the Go ladder literal'
        $goNames = @([regex]::Matches($m.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        Assert-Equal -Expected ($declaredNames -join ',') -Actual ($moduleNames -join ',') 'module vs declaration'
        Assert-Equal -Expected ($declaredNames -join ',') -Actual ($goNames -join ',') 'Go vs declaration'
        $remote = @($moduleNames | Where-Object { (Test-YurunaHostRepairAuthorization -ProofWire '' -HostId $script:GoldenHost -Tier restart -MaxRung $_ -Platform linux -PrivateRoot (New-TestPrivateRoot)).Reason -ne 'repair_tier_not_remote' })
        Assert-Equal -Expected (($declaredNames[0..4]) -join ',') -Actual ($remote -join ',') 'the remote set is Order 0 through 4'
    }
}

Describe 'the shared yup1 verdict table through Test-YurunaHostUpdateProof' {
    It '<Name> -> <Want>' -ForEach $script:UpdateVectorCases {
        $key = if ($KeyName -ceq 'golden') { $script:UpdateVectors.publicKey } else { '' }
        $r = Test-YurunaHostUpdateProof -PublicKeyText $key -Wire $Wire -HostId $HostId -RequestId $RequestId -Scope $Scope `
            -DrainSeconds $DrainSeconds -ExpectCommit $ExpectCommit -NowUnixSeconds $NowUnix `
            -SkewSeconds $script:UpdateVectors.skewSeconds -MaxLifetimeSeconds $script:UpdateVectors.maxLifetimeSeconds
        Assert-StringEqual -Expected $Want -Actual $r.Reason
        Assert-Equal -Expected ($Want -ceq 'ok') -Actual $r.Valid
    }

    It 'signs the reference wire byte for byte, so the fixtures below sign as pool-control does' {
        $c = $script:UpdateVectors.claims
        $wire = Get-TestUpdateWire -KeyPem $script:UpdateKeyPem -HostId $c.hostId -RequestId $c.requestId -Scope $c.scope `
            -DrainSeconds $c.drainSeconds -ExpectCommit $c.expectCommit -Iat $c.iat -Exp $c.exp
        Assert-StringEqual -Expected $script:UpdateVectors.wire -Actual $wire
    }

    It 'never throws on a null wire or a key that is not a key' {
        foreach ($key in @('', 'yupk1.AAAA', 'yrpk1.x.y', ($script:UpdateVectors.publicKey + '='))) {
            $r = Test-YurunaHostUpdateProof -PublicKeyText $key -Wire $script:UpdateVectors.wire -HostId $script:UpdateVectors.claims.hostId `
                -RequestId $script:UpdateVectors.claims.requestId -Scope restart -DrainSeconds 7200 -ExpectCommit $script:UpdateVectors.claims.expectCommit `
                -NowUnixSeconds $script:UpdateVectors.claims.iat -SkewSeconds 60
            Assert-StringEqual -Expected 'update_proof_invalid' -Actual $r.Reason "key '$key'"
        }
        $r = Test-YurunaHostUpdateProof -PublicKeyText $script:UpdateVectors.publicKey -Wire $null -HostId '' -RequestId '' -Scope '' -DrainSeconds 0 -NowUnixSeconds 0 -SkewSeconds 60
        Assert-StringEqual -Expected 'update_proof_missing' -Actual $r.Reason
    }
}

Describe 'ConvertTo-YurunaPoolControlUrl' {
    It 'keeps <Url> as <Want>' -ForEach @(
        @{ Url = 'http://192.0.2.10'; Want = 'http://192.0.2.10' }
        @{ Url = 'https://pool-control.lab.example:8443/'; Want = 'https://pool-control.lab.example:8443' }
        @{ Url = 'http://[2001:db8::10]:80/pool/'; Want = 'http://[2001:db8::10]:80/pool' }
    ) {
        Assert-StringEqual -Expected $Want -Actual (ConvertTo-YurunaPoolControlUrl -Url $Url)
    }

    It 'refuses <Url>' -ForEach @(
        @{ Url = '' }, @{ Url = 'ftp://192.0.2.10' }, @{ Url = 'javascript:alert(1)' }, @{ Url = 'http://user:pw@192.0.2.10' }
        @{ Url = 'http://192.0.2.10/?next=x' }, @{ Url = 'http://192.0.2.10/#x' }, @{ Url = 'http://192.0.2.10/a b' }
        @{ Url = '192.0.2.10' }, @{ Url = '//192.0.2.10' }, @{ Url = 'HTTP://192.0.2.10' }, @{ Url = "http://192.0.2.10`n" }
        @{ Url = 'http://h.example/' + ('a' * 240) }
    ) {
        Assert-StringEqual -Expected '' -Actual (ConvertTo-YurunaPoolControlUrl -Url $Url)
    }
}

Describe 'Read-YurunaPoolControlRecord' {
    It 'reports a missing record' {
        $r = Read-YurunaPoolControlRecord -PrivateRoot (New-TestPrivateRoot)
        Assert-StringEqual -Expected 'missing' -Actual $r.State
        Assert-StringEqual -Expected '' -Actual $r.PoolControl
    }

    It 'reads an installed record with the golden key tag' {
        $root = New-TestPrivateRoot
        $null = Set-TestRecordFile -Root $root -Content (Get-TestRecordText)
        $r = Read-YurunaPoolControlRecord -PrivateRoot $root
        Assert-StringEqual -Expected 'provisioned' -Actual $r.State
        Assert-StringEqual -Expected 'http://192.0.2.10' -Actual $r.PoolControl
        Assert-StringEqual -Expected $script:UpdateVectors.keyTag -Actual $r.KeyTag
        $remote = Get-YurunaHostUpdateRemoteState -PrivateRoot $root
        Assert-StringEqual -Expected 'provisioned' -Actual $remote.Remote
        Assert-False ($remote.Keys -contains 'PublicKey') 'the advertised state carries no key'
    }

    It 'refuses <Name>' -ForEach @(
        @{ Name = 'an unknown key'; Content = '{"schema":"yuruna.pool-control-record/v1","poolControl":"http://192.0.2.10","updateKey":"K","extra":"x"}' }
        @{ Name = 'a missing key'; Content = '{"schema":"yuruna.pool-control-record/v1","poolControl":"http://192.0.2.10"}' }
        @{ Name = 'another schema'; Content = 'SCHEMA2' }
        @{ Name = 'a URL that is not canonical'; Content = 'TRAILING' }
        @{ Name = 'a URL the Diagnostics page must not follow'; Content = 'JAVASCRIPT' }
        @{ Name = 'a key of another kind'; Content = 'BADKEY' }
        @{ Name = 'a repeated name'; Content = 'DUPLICATE' }
        @{ Name = 'not JSON'; Content = 'yupk1.abc' }
    ) {
        $text = switch ($Content) {
            'SCHEMA2' { Get-TestRecordText -Schema 'yuruna.pool-control-record/v2' }
            'TRAILING' { Get-TestRecordText -PoolControl 'http://192.0.2.10/' }
            'JAVASCRIPT' { Get-TestRecordText -PoolControl 'javascript:alert(1)' }
            'BADKEY' { Get-TestRecordText -UpdateKey $script:Vectors.versioned.hostKeyLine }
            'DUPLICATE' { (Get-TestRecordText).TrimEnd('}') + ',"poolControl":"http://192.0.2.99"}' }
            default { $Content.Replace('"K"', '"' + $script:UpdateVectors.publicKey + '"') }
        }
        $root = New-TestPrivateRoot
        $null = Set-TestRecordFile -Root $root -Content $text
        $r = Read-YurunaPoolControlRecord -PrivateRoot $root
        Assert-StringEqual -Expected 'invalid' -Actual $r.State
        Assert-StringEqual -Expected 'record_malformed' -Actual $r.Reason
    }

    It 'refuses a key below 3072 bits' {
        $rsa = [Security.Cryptography.RSA]::Create(2048)
        try { $small = 'yupk1.' + (ConvertTo-TestBase64Url -Bytes $rsa.ExportSubjectPublicKeyInfo()) } finally { $rsa.Dispose() }
        $root = New-TestPrivateRoot
        $null = Set-TestRecordFile -Root $root -Content (Get-TestRecordText -UpdateKey $small)
        Assert-StringEqual -Expected 'record_malformed' -Actual (Read-YurunaPoolControlRecord -PrivateRoot $root).Reason
    }

    It 'refuses a record other users can access' -Skip:$IsWindows {
        $root = New-TestPrivateRoot
        $null = Set-TestRecordFile -Root $root -Content (Get-TestRecordText) -Mode '644'
        Assert-StringEqual -Expected 'record_permissions_open' -Actual (Read-YurunaPoolControlRecord -PrivateRoot $root).Reason
    }

    It 'refuses a record that is a symbolic link' -Skip:$IsWindows {
        $target = Set-TestRecordFile -Root (New-TestPrivateRoot) -Content (Get-TestRecordText)
        $root = New-TestPrivateRoot
        $null = New-Item -ItemType SymbolicLink -Path ([IO.Path]::Combine($root, 'pool-control.record')) -Target $target
        Assert-StringEqual -Expected 'record_reparse_point' -Actual (Read-YurunaPoolControlRecord -PrivateRoot $root).Reason
    }
}

Describe 'Test-YurunaHostUpdateAuthorization' {
    BeforeAll {
        $script:UpRoot = New-TestPrivateRoot
        $null = Set-TestRecordFile -Root $script:UpRoot -Content (Get-TestRecordText)
        $script:UpHost = $script:UpdateVectors.claims.hostId
        $script:UpRequest = $script:UpdateVectors.claims.requestId
        $script:UpNow = [long]1900000000
    }

    It 'admits a proof signed by the record''s key for exactly this request' {
        $wire = Get-TestUpdateWire -KeyPem $script:UpdateKeyPem -HostId $script:UpHost -RequestId $script:UpRequest -Iat $script:UpNow -Exp ($script:UpNow + 120)
        $r = Test-YurunaHostUpdateAuthorization -ProofWire $wire -HostId $script:UpHost -RequestId $script:UpRequest -Scope restart -DrainSeconds 7200 `
            -NowUnixSeconds $script:UpNow -PrivateRoot $script:UpRoot
        Assert-True $r.Authorized $r.Reason
        Assert-Equal -Expected 200 -Actual $r.HttpStatus
    }

    It 'answers <Want> for <Name>' -ForEach @(
        @{ Name = 'no record'; Want = 'update_remote_unprovisioned'; Case = 'norecord' }
        @{ Name = 'a record that does not read'; Want = 'update_remote_invalid'; Case = 'badrecord' }
        @{ Name = 'no host id of its own'; Want = 'update_verifier_failed'; Case = 'nohost' }
        @{ Name = 'another key'; Want = 'update_proof_invalid'; Case = 'otherkey' }
        @{ Name = 'another request'; Want = 'update_proof_request_mismatch'; Case = 'otherrequest' }
        @{ Name = 'another scope'; Want = 'update_proof_policy_mismatch'; Case = 'otherscope' }
        @{ Name = 'an expired proof'; Want = 'update_proof_expired'; Case = 'expired' }
        @{ Name = 'no proof'; Want = 'update_proof_missing'; Case = 'noproof' }
    ) {
        $root = $script:UpRoot
        $hostId = $script:UpHost
        $request = $script:UpRequest
        $scope = 'restart'
        $now = $script:UpNow
        $pem = $script:UpdateKeyPem
        switch ($Case) {
            'norecord' { $root = New-TestPrivateRoot }
            'badrecord' { $root = New-TestPrivateRoot; $null = Set-TestRecordFile -Root $root -Content '{}' }
            'nohost' { $hostId = '' }
            'otherkey' { $pem = $script:OtherKeyPem }
            'otherrequest' { $request = '1c7a4d3f-9b62-4e1f-8a5d-3e8b2f7c6da1' }
            'otherscope' { $scope = 'full' }
            'expired' { $now = $script:UpNow + 181 }
        }
        $wire = if ($Case -ceq 'noproof') { '' } else { Get-TestUpdateWire -KeyPem $pem -HostId $script:UpHost -RequestId $script:UpRequest -Iat $script:UpNow -Exp ($script:UpNow + 120) }
        $r = Test-YurunaHostUpdateAuthorization -ProofWire $wire -HostId $hostId -RequestId $request -Scope $scope -DrainSeconds 7200 -NowUnixSeconds $now -PrivateRoot $root
        Assert-False $r.Authorized
        Assert-StringEqual -Expected $Want -Actual $r.Reason
        Assert-Equal -Expected 403 -Actual $r.HttpStatus
    }
}

Describe 'host update provisioning' {
    It 'creates an owner-only signing key whose public line a record accepts and whose proofs it verifies' {
        $dir = [IO.Path]::Combine($script:TempRoot, 'usk-' + [Guid]::NewGuid().ToString('N'))
        $preview = New-YurunaHostUpdateSigningKey -Directory $dir -WhatIf
        Assert-StringEqual -Expected 'preview' -Actual $preview.Reason
        Assert-False ([IO.Directory]::Exists($dir)) 'a preview created the directory'
        $r = New-YurunaHostUpdateSigningKey -Directory $dir -Confirm:$false
        Assert-True $r.Created
        Assert-Match '\Ayupk1\.[A-Za-z0-9_-]+\z' $r.PublicKey
        if (-not $IsWindows) { Assert-Equal -Expected 384 -Actual (Get-TestUnixMode -Path $r.KeyPath) 'the key file is 0600' }
        $pem = [IO.File]::ReadAllText($r.KeyPath)
        Assert-Match '\A-----BEGIN PRIVATE KEY-----' $pem
        $read = Read-YurunaHostUpdateSigningKey -Directory $dir
        Assert-StringEqual -Expected $r.PublicKey -Actual $read.PublicKey
        Assert-StringEqual -Expected $r.KeyTag -Actual $read.KeyTag

        $again = New-YurunaHostUpdateSigningKey -Directory $dir -Confirm:$false
        Assert-StringEqual -Expected 'exists' -Actual $again.Reason
        Assert-StringEqual -Expected $pem -Actual ([IO.File]::ReadAllText($r.KeyPath)) 'an existing key was replaced without -Rotate'

        $root = New-TestPrivateRoot
        $installed = Install-YurunaPoolControlRecord -PublicKey $r.PublicKey -PoolControlUrl 'http://192.0.2.10/' -PrivateRoot $root -Confirm:$false
        Assert-True $installed.Installed
        Assert-StringEqual -Expected 'http://192.0.2.10' -Actual $installed.PoolControl
        if (-not $IsWindows) { Assert-Equal -Expected 384 -Actual (Get-TestUnixMode -Path $installed.Path) 'the record is 0600' }
        $wire = Get-TestUpdateWire -KeyPem $pem -HostId $script:GoldenHost -RequestId $script:GoldenRequest -Iat 1900000000 -Exp 1900000120
        $auth = Test-YurunaHostUpdateAuthorization -ProofWire $wire -HostId $script:GoldenHost -RequestId $script:GoldenRequest -Scope restart `
            -DrainSeconds 7200 -NowUnixSeconds 1900000000 -PrivateRoot $root
        Assert-True $auth.Authorized $auth.Reason

        $rotated = New-YurunaHostUpdateSigningKey -Directory $dir -Rotate -Confirm:$false
        Assert-True ($rotated.Created -and $rotated.Rotated)
        Assert-False ($rotated.KeyTag -ceq $r.KeyTag) 'a rotation kept the old key'
        Assert-StringEqual -Expected 'update_proof_invalid' -Actual (Test-YurunaHostUpdateAuthorization -ProofWire (Get-TestUpdateWire -KeyPem ([IO.File]::ReadAllText($r.KeyPath)) `
                    -HostId $script:GoldenHost -RequestId $script:GoldenRequest -Iat 1900000000 -Exp 1900000120) -HostId $script:GoldenHost `
                -RequestId $script:GoldenRequest -Scope restart -DrainSeconds 7200 -NowUnixSeconds 1900000000 -PrivateRoot $root).Reason
    }

    It 'refuses a URL or a key it cannot use, and writes nothing' {
        $root = New-TestPrivateRoot
        foreach ($case in @(@{ Url = 'ftp://192.0.2.10'; Key = $script:UpdateVectors.publicKey }, @{ Url = 'http://192.0.2.10'; Key = 'yupk1.AAAA' })) {
            $threw = $false
            try { $null = Install-YurunaPoolControlRecord -PublicKey $case.Key -PoolControlUrl $case.Url -PrivateRoot $root -Confirm:$false } catch { $threw = $true }
            Assert-True $threw "accepted $($case.Url) $($case.Key)"
        }
        Assert-StringEqual -Expected 'missing' -Actual (Read-YurunaPoolControlRecord -PrivateRoot $root).State
    }

    It 'reports a signing key it cannot read' {
        $dir = [IO.Path]::Combine($script:TempRoot, 'usk-absent-' + [Guid]::NewGuid().ToString('N'))
        $threw = ''
        try { $null = Read-YurunaHostUpdateSigningKey -Directory $dir } catch { $threw = $_.Exception.Message }
        Assert-Match 'absent' $threw
    }

    It 'removes the record' {
        $root = New-TestPrivateRoot
        $null = Set-TestRecordFile -Root $root -Content (Get-TestRecordText)
        Assert-False (Remove-YurunaPoolControlRecord -PrivateRoot $root -WhatIf).Removed
        Assert-StringEqual -Expected 'provisioned' -Actual (Read-YurunaPoolControlRecord -PrivateRoot $root).State
        Assert-True (Remove-YurunaPoolControlRecord -PrivateRoot $root -Confirm:$false).Removed
        Assert-StringEqual -Expected 'missing' -Actual (Read-YurunaPoolControlRecord -PrivateRoot $root).State
    }
}

Describe 'the pool-control record keeps the operator''s values' {
    It 'reports nothing for the same values and leaves the record as it was' {
        $root = New-TestPrivateRoot
        $seeded = Get-TestRecordText -PoolControl 'http://192.0.2.77:9090/pool'
        $path = Set-TestRecordFile -Root $root -Content $seeded
        Assert-Equal -Expected 0 -Actual @(Get-YurunaPoolControlRecordChange -PublicKey $script:UpdateVectors.publicKey -PoolControlUrl 'http://192.0.2.77:9090/pool/' -PrivateRoot $root).Count
        $null = Install-YurunaPoolControlRecord -PublicKey $script:UpdateVectors.publicKey -PoolControlUrl 'http://192.0.2.77:9090/pool' -PrivateRoot $root -Confirm:$false
        Assert-StringEqual -Expected 'http://192.0.2.77:9090/pool' -Actual (Read-YurunaPoolControlRecord -PrivateRoot $root).PoolControl
        Assert-StringEqual -Expected $seeded -Actual ([IO.File]::ReadAllText($path)).TrimEnd("`n")
    }

    It 'names each replaced value as previous -> new' {
        $root = New-TestPrivateRoot
        $null = Set-TestRecordFile -Root $root -Content (Get-TestRecordText -PoolControl 'http://192.0.2.77:9090/pool')
        $changes = @(Get-YurunaPoolControlRecordChange -PublicKey $script:UpdateVectors.otherPublicKey -PoolControlUrl 'http://192.0.2.20' -PrivateRoot $root)
        Assert-Equal -Expected 2 -Actual $changes.Count
        Assert-StringEqual -Expected 'poolControl|http://192.0.2.77:9090/pool|http://192.0.2.20' -Actual (($changes[0].Key, $changes[0].Previous, $changes[0].Current) -join '|')
        Assert-StringEqual -Expected ('updateKey|' + $script:UpdateVectors.publicKey + '|' + $script:UpdateVectors.otherPublicKey) -Actual (($changes[1].Key, $changes[1].Previous, $changes[1].Current) -join '|')
        Assert-Equal -Expected 0 -Actual @(Get-YurunaPoolControlRecordChange -PublicKey 'yupk1.AAAA' -PoolControlUrl 'http://192.0.2.20' -PrivateRoot $root).Count 'a refused install replaces nothing'
        $broken = New-TestPrivateRoot
        $null = Set-TestRecordFile -Root $broken -Content '{}'
        $row = @(Get-YurunaPoolControlRecordChange -PublicKey $script:UpdateVectors.publicKey -PoolControlUrl 'http://192.0.2.20' -PrivateRoot $broken)
        Assert-StringEqual -Expected 'record|record_malformed|replaced' -Actual (($row[0].Key, $row[0].Previous, $row[0].Current) -join '|')
    }
}

Describe 'Set-HostRepairCredential host update modes' {
    BeforeAll {
        $script:UpChildHome = [IO.Path]::Combine($script:TempRoot, 'up-child-' + [Guid]::NewGuid().ToString('N'))
        $script:UpChildRuntime = [IO.Path]::Combine($script:UpChildHome, 'runtime')
        [void][IO.Directory]::CreateDirectory($script:UpChildRuntime)
        [IO.File]::WriteAllText([IO.Path]::Combine($script:UpChildRuntime, 'host.uuid'), $script:GoldenHost)
        $script:UpAuthority = [IO.Path]::Combine($script:UpChildHome, 'authority')
        $script:UpChildRecord = [IO.Path]::Combine($script:UpChildHome, '.yuruna', 'host-repair', 'pool-control.record')
    }

    It 'creates the signing key, installs and replaces the record with a report, shows status and removes it' {
        $r = Invoke-TestCredentialScript -Argument @('-NewUpdateSigningKey', '-AuthorityDirectory', $script:UpAuthority) -HomeDirectory $script:UpChildHome -RuntimeDirectory $script:UpChildRuntime
        Assert-Equal -Expected 0 -Actual $r.ExitCode "create: $($r.StdErr)"
        $line = [regex]::Match($r.StdOut, 'yupk1\.[A-Za-z0-9_-]+').Value
        Assert-True ($line.Length -gt 400) 'the public key line is printed'
        $pem = [IO.File]::ReadAllText([IO.Path]::Combine($script:UpAuthority, 'update-signing.key'))
        Assert-False ($r.StdOut.Contains('PRIVATE KEY') -or $r.StdOut.Contains(($pem -split "`n")[1])) 'the private key reached the output'
        $r = Invoke-TestCredentialScript -Argument @('-NewUpdateSigningKey', '-AuthorityDirectory', $script:UpAuthority) -HomeDirectory $script:UpChildHome -RuntimeDirectory $script:UpChildRuntime
        Assert-Equal -Expected 1 -Actual $r.ExitCode 'a second create without -Rotate'

        $r = Invoke-TestCredentialScript -Argument @('-InstallPoolControlRecord', '-PoolControlUrl', 'http://192.0.2.77:9090', '-PublicKey', $line, '-WhatIf') -HomeDirectory $script:UpChildHome -RuntimeDirectory $script:UpChildRuntime
        Assert-Equal -Expected 0 -Actual $r.ExitCode "preview: $($r.StdErr)"
        Assert-False ([IO.File]::Exists($script:UpChildRecord)) 'a preview wrote the record'
        $r = Invoke-TestCredentialScript -Argument @('-InstallPoolControlRecord', '-PoolControlUrl', 'http://192.0.2.77:9090', '-PublicKey', $line) -HomeDirectory $script:UpChildHome -RuntimeDirectory $script:UpChildRuntime
        Assert-Equal -Expected 0 -Actual $r.ExitCode "install: $($r.StdErr)"
        Assert-Match 'http://192\.0\.2\.77:9090' $r.StdOut
        Assert-False ($r.StdOut -match '->') 'a first install replaces nothing'

        $r = Invoke-TestCredentialScript -Argument @('-InstallPoolControlRecord', '-PoolControlUrl', 'http://192.0.2.88', '-AuthorityDirectory', $script:UpAuthority) -HomeDirectory $script:UpChildHome -RuntimeDirectory $script:UpChildRuntime
        Assert-Equal -Expected 0 -Actual $r.ExitCode "reinstall: $($r.StdErr)"
        $report = $r.StdOut.IndexOf('http://192.0.2.77:9090 -> http://192.0.2.88')
        Assert-True ($report -ge 0) "the replaced value is reported as previous -> new: $($r.StdOut)"
        Assert-True ($report -lt $r.StdOut.LastIndexOf('http://192.0.2.88')) 'the report comes before the install line'
        Assert-Match '"poolControl":"http://192\.0\.2\.88"' ([IO.File]::ReadAllText($script:UpChildRecord))

        $r = Invoke-TestCredentialScript -Argument @('-AuthorityDirectory', $script:UpAuthority) -HomeDirectory $script:UpChildHome -RuntimeDirectory $script:UpChildRuntime
        Assert-Equal -Expected 0 -Actual $r.ExitCode "status: $($r.StdErr)"
        Assert-Match 'provisioned \(ok; pool-control http://192\.0\.2\.88' $r.StdOut
        Assert-Match 'signing key present' $r.StdOut

        $r = Invoke-TestCredentialScript -Argument @('-RemovePoolControlRecord') -HomeDirectory $script:UpChildHome -RuntimeDirectory $script:UpChildRuntime
        Assert-Equal -Expected 0 -Actual $r.ExitCode "remove: $($r.StdErr)"
        Assert-False ([IO.File]::Exists($script:UpChildRecord)) 'the record is gone'
    }

    It 'refuses an unusable URL without writing' {
        $r = Invoke-TestCredentialScript -Argument @('-InstallPoolControlRecord', '-PoolControlUrl', 'javascript:alert(1)', '-PublicKey', $script:UpdateVectors.publicKey) -HomeDirectory $script:UpChildHome -RuntimeDirectory $script:UpChildRuntime
        Assert-Equal -Expected 1 -Actual $r.ExitCode
        Assert-Match 'javascript:alert\(1\)' $r.StdErr
        Assert-False ([IO.File]::Exists($script:UpChildRecord)) 'a refused URL wrote a record'
    }
}
