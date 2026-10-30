<#PSScriptInfo
.VERSION 2026.10.30
.GUID 42f88b85-1359-4e89-a7fb-e0e5795a448b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test guest seed credential windows pester
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
    The guest GitHub token goes to github.com alone, through git's URL-scoped
    credential helpers, and the Windows seed renders for the host architecture.
.DESCRIPTION
    The Linux helper is taken from both seeds and run under sh; the Windows
    helper is taken from the first-logon bootstrap and run under pwsh, which
    reads the same token file through the profile folder. The Windows seed
    cases read the shipped scripts' text or evaluate their own statements.
#>

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $script:Sh = Get-Command sh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $script:Pwsh = (Get-Process -Id $PID).Path
    $script:Bootstrap = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'automation/windows-guest-bootstrap.ps1'))

    function Get-SeedCredentialHelper {
        <# .SYNOPSIS
            The helper script a seed installs, without the seed's indentation.
        #>
        [CmdletBinding()]
        [OutputType([string])]
        param([string]$Seed)
        $lines = [IO.File]::ReadAllLines((Join-Path $script:RepoRoot "host/vmconfig/$Seed"))
        $marker = [Array]::FindIndex($lines, [Predicate[string]] { param($l) $l.Trim() -eq '# git credential helper. /etc/gitconfig registers it for https://github.com' })
        if ($marker -lt 1) { throw "No credential helper in $Seed" }
        $start = $marker - 1
        $end = [Array]::FindIndex($lines, $marker, [Predicate[string]] { param($l) $l.Trim().StartsWith("printf 'username=x-access-token") })
        $indent = $lines[$start].Length - $lines[$start].TrimStart().Length
        return (($lines[$start..$end] | ForEach-Object { if ($_.Length -ge $indent) { $_.Substring($indent) } else { $_.TrimStart() } }) -join "`n") + "`n"
    }

    function Invoke-CredentialHelper {
        <# .SYNOPSIS
            Run a helper with a git credential request; return what it printed.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Writes isolated test fixture files only.')]
        [CmdletBinding()]
        [OutputType([string])]
        param([string[]]$Command, [string]$Request, [string]$Token, [string]$FileToken)
        $fakeHome = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $fakeHome '.config/yuruna') -Force
        if ($FileToken) { [IO.File]::WriteAllText((Join-Path $fakeHome '.config/yuruna/github-token'), $FileToken) }
        $priorHome = $env:HOME; $priorToken = $env:GH_TOKEN
        try {
            $env:HOME = $fakeHome
            if ($Token) { $env:GH_TOKEN = $Token } else { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue }
            $PSNativeCommandUseErrorActionPreference = $false
            $exe = $Command[0]
            $rest = @($Command | Select-Object -Skip 1)
            return ($Request | & $exe @rest 2>&1 | Out-String).Replace("`r", '')
        } finally {
            $env:HOME = $priorHome
            if ($null -eq $priorToken) { Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue } else { $env:GH_TOKEN = $priorToken }
        }
    }

    $script:GitHubGet = "protocol=https`nhost=github.com`n`n"
}

Describe 'The Linux credential helper answers github.com alone' {
    It 'is the same script in both seeds' {
        Get-SeedCredentialHelper -Seed 'amazon.linux.2023.base.user-data' |
            Should -BeExactly (Get-SeedCredentialHelper -Seed 'ubuntu.server.base.user-data')
    }
    It 'answers <Case> with <Expected>' -TestCases @(
        @{ Case = 'a github.com get with the token in the environment'; Verb = 'get'; Request = "protocol=https`nhost=github.com`n`n"; Token = 'env-token'; File = 'file-token'; Expected = "username=x-access-token`npassword=env-token`n" }
        @{ Case = 'a github.com get with the token in the file'; Verb = 'get'; Request = "protocol=https`nhost=github.com`n`n"; Token = ''; File = 'file-token'; Expected = "username=x-access-token`npassword=file-token`n" }
        @{ Case = 'a get for another host'; Verb = 'get'; Request = "protocol=https`nhost=mirror.lab.example`n`n"; Token = 'env-token'; File = 'file-token'; Expected = '' }
        @{ Case = 'a get for a look-alike host'; Verb = 'get'; Request = "protocol=https`nhost=github.com.example`n`n"; Token = 'env-token'; File = 'file-token'; Expected = '' }
        @{ Case = 'a plain-HTTP get for github.com'; Verb = 'get'; Request = "protocol=http`nhost=github.com`n`n"; Token = 'env-token'; File = 'file-token'; Expected = '' }
        @{ Case = 'a store request'; Verb = 'store'; Request = "protocol=https`nhost=github.com`nusername=u`npassword=p`n`n"; Token = 'env-token'; File = ''; Expected = '' }
        @{ Case = 'a get with no token anywhere'; Verb = 'get'; Request = "protocol=https`nhost=github.com`n`n"; Token = ''; File = ''; Expected = '' }
    ) {
        if (-not $script:Sh) { Set-ItResult -Skipped -Because 'sh is not available on this host'; return }
        $helper = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.sh')
        [IO.File]::WriteAllText($helper, (Get-SeedCredentialHelper -Seed 'ubuntu.server.base.user-data'))
        $answer = Invoke-CredentialHelper -Command @($script:Sh.Source, $helper, $Verb) -Request $Request -Token $Token -FileToken $File
        $answer | Should -BeExactly $Expected
    }
    It 'registers the helper for https://github.com only in <Seed>' -TestCases @(
        @{ Seed = 'ubuntu.server.base.user-data' }, @{ Seed = 'amazon.linux.2023.base.user-data' }
    ) {
        $text = [IO.File]::ReadAllText((Join-Path $script:RepoRoot "host/vmconfig/$Seed"))
        $text | Should -Match '\[credential "https://github\.com"\](\\n|\r?\n\s*)\s*helper = /usr/local/lib/yuruna/git-credential-github'
        $text | Should -Not -Match '(?m)^\s*\[credential\]'
    }
}

Describe 'The Windows bootstrap keeps the token in the user''s own file' {
    BeforeAll {
        $start = $script:Bootstrap.IndexOf("Set-Content -Path `$helper -Encoding Ascii -Value @'", [StringComparison]::Ordinal)
        $bodyStart = $script:Bootstrap.IndexOf("`n", $start) + 1
        $bodyEnd = $script:Bootstrap.IndexOf("`n'@", $bodyStart, [StringComparison]::Ordinal)
        $script:WindowsHelper = $script:Bootstrap.Substring($bodyStart, $bodyEnd - $bodyStart) + "`n"
    }
    It 'answers <Case> with <Expected>' -TestCases @(
        @{ Case = 'a github.com get with the token in the file'; Verb = 'get'; Request = "protocol=https`nhost=github.com`n`n"; Token = ''; File = 'file-token'; Expected = "username=x-access-token`npassword=file-token`n" }
        @{ Case = 'a github.com get with the token in the environment'; Verb = 'get'; Request = "protocol=https`nhost=github.com`n`n"; Token = 'env-token'; File = ''; Expected = "username=x-access-token`npassword=env-token`n" }
        @{ Case = 'a get for another host'; Verb = 'get'; Request = "protocol=https`nhost=mirror.lab.example`n`n"; Token = 'env-token'; File = 'file-token'; Expected = '' }
        @{ Case = 'an erase request'; Verb = 'erase'; Request = "protocol=https`nhost=github.com`n`n"; Token = 'env-token'; File = 'file-token'; Expected = '' }
    ) {
        $helper = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.ps1')
        [IO.File]::WriteAllText($helper, $script:WindowsHelper)
        $answer = Invoke-CredentialHelper -Command @($script:Pwsh, '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $helper, $Verb) -Request $Request -Token $Token -FileToken $File
        $answer | Should -BeExactly $Expected
    }
    It 'no longer publishes the token as a Machine-scope variable or embeds it in the profile' {
        $script:Bootstrap | Should -Not -Match "SetEnvironmentVariable\('GH_TOKEN'"
        $profileStart = $script:Bootstrap.IndexOf('$profileText = @''', [StringComparison]::Ordinal)
        $script:Bootstrap.Substring($profileStart) | Should -Not -Match '__TOKEN__'
    }
    It 'writes the token file with an ACL limited to the user and SYSTEM before registering the helper' {
        $write = $script:Bootstrap.IndexOf('[IO.File]::WriteAllText($tokenFile, $token)', [StringComparison]::Ordinal)
        $protect = $script:Bootstrap.IndexOf('$tokenAcl.SetAccessRuleProtection($true, $false)', [StringComparison]::Ordinal)
        $setAcl = $script:Bootstrap.IndexOf('Set-Acl -LiteralPath $tokenFile -AclObject $tokenAcl', [StringComparison]::Ordinal)
        $write | Should -BeGreaterThan 0
        $protect | Should -BeGreaterThan $write
        $setAcl | Should -BeGreaterThan $protect
        $script:Bootstrap | Should -Match ([regex]::Escape("New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'"))
    }
    It 'scopes the helper to github.com and clears other helpers for that host' {
        $script:Bootstrap | Should -Match '\[credential "https://github\.com"\]\r?\n\s+helper =\r?\n\s+helper = "!powershell\.exe'
    }
    It 'lets the askpass shim read the token file when no variable carries it' {
        $script:Bootstrap | Should -Match ([regex]::Escape('if exist "%USERPROFILE%\.config\yuruna\github-token" (type "%USERPROFILE%\.config\yuruna\github-token"'))
        $script:Bootstrap | Should -Match ([regex]::Escape(@'
findstr /i /c:"//github.com'" /c:"@github.com'" >nul
'@.Trim()))
    }
    It 'asks Windows to eject the seed media after its last read and before the token check' {
        $copy = $script:Bootstrap.IndexOf("Copy-Item -LiteralPath (Join-Path `$PSScriptRoot 'yuruna-host-locate.ps1')", [StringComparison]::Ordinal)
        $eject = $script:Bootstrap.IndexOf("InvokeVerb('Eject')", [StringComparison]::Ordinal)
        $tokenReturn = $script:Bootstrap.IndexOf('if (-not $token) { return }', [StringComparison]::Ordinal)
        $copy | Should -BeGreaterThan 0
        $eject | Should -BeGreaterThan $copy
        $tokenReturn | Should -BeGreaterThan $eject
    }
}

Describe 'The Hyper-V Windows answer file matches the host architecture' {
    BeforeAll {
        $builderPath = Join-Path $script:RepoRoot 'host/windows.hyper-v/guest.windows.11/New-VM.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile($builderPath, [ref]$null, [ref]$null)
        $assignments = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] }, $true))
        $script:ArchStatement = @($assignments | Where-Object { $_.Left.Extent.Text -eq '$answerArch' })[0]
        $script:RenderStatement = @($assignments | Where-Object { $_.Left.Extent.Text -eq '$AnswerFile' })[0]
    }
    It 'renders every component for arm64 on an ARM64 host and for amd64 otherwise' {
        $script:ArchStatement | Should -Not -BeNullOrEmpty
        $script:ArchStatement.Extent.Text | Should -Match 'OSArchitecture -eq \[System\.Runtime\.InteropServices\.Architecture\]::Arm64'
        foreach ($arch in 'arm64', 'amd64') {
            $AnswerFileTemplate = Join-Path $script:RepoRoot 'host/windows.hyper-v/guest.windows.11/vmconfig/autounattend.xml'
            $VMName = 'fixture-vm'
            $guestBootstrap = [pscustomobject]@{ EncodedCommand = 'fixture-command' }
            $answerArch = $arch
            $null = $AnswerFileTemplate, $VMName, $guestBootstrap, $answerArch
            $AnswerFile = $null
            . ([scriptblock]::Create($script:RenderStatement.Extent.Text))
            $AnswerFile | Should -Match "processorArchitecture=`"$arch`""
            $other = if ($arch -eq 'arm64') { 'amd64' } else { 'arm64' }
            $AnswerFile | Should -Not -Match "processorArchitecture=`"$other`""
        }
        $utm = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'host/macos.utm/guest.windows.11/vmconfig/autounattend.xml')) `
            -replace 'COMPUTERNAME_PLACEHOLDER', 'fixture-vm' -replace 'GUEST_BOOTSTRAP_B64_PLACEHOLDER', 'fixture-command'
        $answerArch = 'arm64'
        . ([scriptblock]::Create($script:RenderStatement.Extent.Text))
        ($AnswerFile -replace '(?m)^<!-- GUID: [^>]+ -->\r?\n', '') | Should -BeExactly ($utm -replace '(?m)^<!-- GUID: [^>]+ -->\r?\n', '')
    }
}

Describe 'Windows workloads report the steps they could not complete' {
    BeforeAll {
        $script:K8sWin = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'guest/windows.11/windows.11.k8s.ps1'))
        $script:CodeWin = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'guest/windows.11/windows.11.code.ps1'))
    }
    It 'prints the OpenSSH outcome it observed instead of a fixed success line' {
        $script:K8sWin | Should -Not -Match 'OpenSSH\.Server~~~~0\.0\.1\.0 -ErrorAction SilentlyContinue'
        $script:K8sWin | Should -Not -Match 'Start-Service sshd -ErrorAction SilentlyContinue'
        $script:K8sWin | Should -Match 'Basic Tools installation complete, without the OpenSSH server'
    }
    It 'stops when the mkcert root cannot be trusted' {
        $script:K8sWin | Should -Not -Match 'Cert:\\LocalMachine\\Root -ErrorAction SilentlyContinue'
        $script:K8sWin | Should -Match ([regex]::Escape('Import-Certificate -FilePath $rootCert -CertStoreLocation Cert:\LocalMachine\Root -ErrorAction Stop'))
    }
    It 'keeps the machine PATH an expandable string' {
        $script:CodeWin | Should -Not -Match "SetEnvironmentVariable\('Path'"
        $script:CodeWin | Should -Match ([regex]::Escape("GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)"))
        $script:CodeWin | Should -Match ([regex]::Escape('[Microsoft.Win32.RegistryValueKind]::ExpandString'))
    }
}
