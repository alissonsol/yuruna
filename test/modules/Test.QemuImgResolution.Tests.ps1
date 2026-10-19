<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 42d1e8b3-6c4f-4a29-8e5b-3f7a9c0d2b61
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test qemu-img windows path precedence version floor pester
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
    Which qemu-img a host runs: the resolver in Yuruna.Image.psm1, the version
    floor probe in Yuruna.Requirement.yml, the standalone diagnostic's copy,
    and the Windows installer's note about it all rank the same copies the
    same way.
.DESCRIPTION
    The QEMU package the Windows installer manages never joins PATH, while
    other Windows packages that ship a qemu-img (the Cloudbase 2.3.0 port) do.
    A PATH-first rule would run a decade-old qemu-img for every cloud-image
    conversion and report "qemu-img BELOW: found 2.3.0" at the end of an
    install that had just put 11.x in Program Files. On Windows the newest copy
    wins; elsewhere the copy the name resolves to, because that is what the
    drivers run.

    Every case runs real code against fake qemu-img binaries (POSIX shell
    scripts printing a version banner), with the Windows layout forced where
    it is a parameter and the $IsWindows branch forced in the probe texts,
    which are taken from the files they ship in. The fakes cannot run on
    Windows, so those cases skip there and say so.
#>
BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
    Import-Module (Join-Path $script:RepoRoot 'host/modules/Yuruna.Image.psm1') -Force -DisableNameChecking
    $script:CanFake = -not $IsWindows
    $script:Skip = 'the fake qemu-img binaries are POSIX shell scripts'
    $script:Current = 'qemu-img version 11.1.0 (v11.1.0-12130-ge470268ff4)'
    $script:Cloudbase = 'qemu-img version 2.3.0, Copyright (c) 2004-2008 Fabrice Bellard'

    function New-FakeQemuImg {
        <#
        .SYNOPSIS
            Write an executable that prints the given banner for --version.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes one file under the test drive.')]
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Banner, [int]$ExitCode = 0)
        # PowerShell reads a Windows-style separator as one; .NET's file API
        # on a POSIX host does not, so the file is written at the normalized
        # path and the caller keeps the spelling the code under test uses.
        $onDisk = $Path.Replace('\', '/')
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $onDisk)
        $body = "#!/bin/sh`n"
        if ($Banner) { $body += "echo '$Banner'`necho 'Copyright (c) 2003-2025 Fabrice Bellard and the QEMU Project developers'`n" }
        $body += "exit $ExitCode`n"
        [System.IO.File]::WriteAllText($onDisk, $body)
        # Not chmod: the cases replace PATH with the fake directories alone.
        [System.IO.File]::SetUnixFileMode($onDisk, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute, OtherRead, OtherExecute')
        return $Path
    }

    function Enter-FakeHost {
        <#
        .SYNOPSIS
            Point PATH and the Program Files variables at a fresh fake tree.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: swaps process environment variables it restores in Exit-FakeHost.')]
        [CmdletBinding()]
        param([string[]]$PathDirectory = @())
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path $root
        $script:Saved = @{
            Path = $env:PATH
            ProgramFiles = $env:ProgramFiles
            ProgramFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
        }
        $env:ProgramFiles = Join-Path $root 'pf'
        [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', (Join-Path $root 'pf86'))
        $env:PATH = (@($PathDirectory | ForEach-Object { Join-Path $root $_ }) -join [IO.Path]::PathSeparator)
        return $root
    }

    function Exit-FakeHost {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: restores what Enter-FakeHost saved.')]
        [CmdletBinding()]
        param()
        if ($script:Saved) {
            $env:PATH = $script:Saved.Path
            $env:ProgramFiles = $script:Saved.ProgramFiles
            [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $script:Saved.ProgramFilesX86)
            $script:Saved = $null
        }
    }

    function Get-ManagedPath { param([string]$Root) return (Join-Path $Root 'pf') + '\qemu\qemu-img.exe' }

    # The probe texts are taken from the files that ship them, so these cases
    # exercise the copy a host runs rather than a re-typed one.
    $script:RequirementProbe = & {
        Import-Module powershell-yaml -ErrorAction Stop
        $doc = ConvertFrom-Yaml (Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'automation/Yuruna.Requirement.yml'))
        [string](@($doc.requirements | Where-Object { $_.tool -eq 'qemu-img' })[0].command)
    }
    $diagnosticAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'automation/Get-SystemDiagnostic.ps1'), [ref]$null, [ref]$null)
    $versionLine = $diagnosticAst.Find({ param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Get-VersionLine' -and
            $node.CommandElements.Count -ge 3 -and $node.CommandElements[1].Extent.Text -eq "'qemu-img'" }, $true)
    if (-not $versionLine) { throw "Get-SystemDiagnostic.ps1 no longer has a Get-VersionLine 'qemu-img' probe." }
    $script:DiagnosticProbe = $versionLine.CommandElements[2].ScriptBlock.EndBlock.Extent.Text

    function ConvertTo-WindowsBranch {
        <#
        .SYNOPSIS
            The probe text with its Windows branch taken, on any host.
        #>
        param([Parameter(Mandatory)][string]$Text)
        $count = ([regex]::Matches($Text, [regex]::Escape('$IsWindows'))).Count
        if ($count -ne 1) { throw "Expected the probe to test `$IsWindows exactly once; found $count." }
        return $Text.Replace('$IsWindows', '$true')
    }

    function Invoke-ProbeText {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingInvokeExpression', '',
            Justification = 'The probe is shipped as text and evaluated with Invoke-Expression by its consumer; the test does what the consumer does.')]
        param([Parameter(Mandatory)][string]$Text)
        return (Invoke-Expression $Text)
    }

    $installerAst = Get-YurunaTestFunctionAst -Path (Join-Path $script:RepoRoot 'install/windows.hyper-v.ps1') -Name 'Get-QemuImgPrecedenceNote'
    if (-not $installerAst) { throw 'install/windows.hyper-v.ps1 no longer defines Get-QemuImgPrecedenceNote.' }
    . ([scriptblock]::Create($installerAst.Extent.Text))
}

AfterAll { Exit-FakeHost }

Describe 'Get-QemuImgVersion' {
    AfterEach { Exit-FakeHost }

    It 'reads <Case>' -TestCases @(
        @{ Case = 'a current build'; Banner = 'qemu-img version 11.1.0 (v11.1.0-12130-ge470268ff4)'; Expected = '11.1.0' }
        @{ Case = 'the Cloudbase Windows port'; Banner = 'qemu-img version 2.3.0, Copyright (c) 2004-2008 Fabrice Bellard'; Expected = '2.3.0' }
        @{ Case = 'a release with a fourth field'; Banner = 'qemu-img version 10.2.1.4'; Expected = '10.2.1.4' }
    ) {
        param($Case, $Banner, $Expected)
        if (-not $script:CanFake) { Set-ItResult -Skipped -Because $script:Skip; return }
        $root = Enter-FakeHost
        $fake = New-FakeQemuImg -Path (Join-Path $root 'bin/qemu-img') -Banner $Banner
        Assert-Equal ([version]$Expected) (Get-QemuImgVersion -Path $fake) -Because $Case
    }

    It 'answers nothing for a binary that prints no version or does not exist' {
        if (-not $script:CanFake) { Set-ItResult -Skipped -Because $script:Skip; return }
        $root = Enter-FakeHost
        $silent = New-FakeQemuImg -Path (Join-Path $root 'bin/qemu-img') -Banner '' -ExitCode 3
        Assert-Null (Get-QemuImgVersion -Path $silent) 'no banner, no version'
        Assert-Null (Get-QemuImgVersion -Path (Join-Path $root 'missing/qemu-img')) 'a missing binary is not an error'
    }
}

Describe 'Select-QemuImgCandidate' {
    BeforeAll {
        function Get-Record { param([string]$Path, [AllowNull()][string]$Version) [pscustomobject]@{ Path = $Path; Version = $(if ($Version) { [version]$Version } else { $null }) } }
    }

    It 'picks the newest whatever the order' {
        $pick = Select-QemuImgCandidate -Candidate @((Get-Record 'path' '2.3.0'), (Get-Record 'managed' '11.1.0'), (Get-Record 'other' '9.0.0'))
        Assert-StringEqual 'managed' $pick.Path
    }

    It 'keeps the earlier copy on a tie' {
        $pick = Select-QemuImgCandidate -Candidate @((Get-Record 'managed' '11.1.0'), (Get-Record 'path' '11.1.0'))
        Assert-StringEqual 'managed' $pick.Path
    }

    It 'prefers a copy that reports a version over one that does not' {
        $pick = Select-QemuImgCandidate -Candidate @((Get-Record 'silent' $null), (Get-Record 'path' '2.3.0'))
        Assert-StringEqual 'path' $pick.Path
    }

    It 'keeps the first copy when none reports a version, and answers nothing for none' {
        Assert-StringEqual 'first' (Select-QemuImgCandidate -Candidate @((Get-Record 'first' $null), (Get-Record 'second' $null))).Path
        Assert-Null (Select-QemuImgCandidate -Candidate @())
        Assert-Null (Select-QemuImgCandidate -Candidate $null)
    }
}

Describe 'Get-QemuImgCandidate' {
    AfterEach { Exit-FakeHost }

    It 'lists the installer location first, then every PATH copy in PATH order, once each (Windows layout)' {
        if (-not $script:CanFake) { Set-ItResult -Skipped -Because $script:Skip; return }
        $root = Enter-FakeHost -PathDirectory @('cloudbase', 'msys', 'cloudbase')
        $managed = New-FakeQemuImg -Path (Get-ManagedPath $root) -Banner $script:Current
        $cloudbase = New-FakeQemuImg -Path (Join-Path $root 'cloudbase/qemu-img') -Banner $script:Cloudbase
        $msys = New-FakeQemuImg -Path (Join-Path $root 'msys/qemu-img') -Banner 'qemu-img version 9.2.0'
        $list = @(Get-QemuImgCandidate -WindowsLayout $true)
        Assert-Equal 3 $list.Count -Because "a directory listed twice on PATH is one copy ($($list -join ', '))"
        Assert-StringEqual $managed $list[0] 'the installer location comes first'
        Assert-StringEqual $cloudbase $list[1]
        Assert-StringEqual $msys $list[2]
    }

    It 'skips installer locations that hold nothing' {
        if (-not $script:CanFake) { Set-ItResult -Skipped -Because $script:Skip; return }
        $root = Enter-FakeHost -PathDirectory @('cloudbase')
        $cloudbase = New-FakeQemuImg -Path (Join-Path $root 'cloudbase/qemu-img') -Banner $script:Cloudbase
        $list = @(Get-QemuImgCandidate -WindowsLayout $true)
        Assert-Equal 1 $list.Count
        Assert-StringEqual $cloudbase $list[0]
    }

    It 'lists only what the name resolves to outside the Windows layout' {
        if (-not $script:CanFake) { Set-ItResult -Skipped -Because $script:Skip; return }
        $root = Enter-FakeHost -PathDirectory @('old', 'new')
        $old = New-FakeQemuImg -Path (Join-Path $root 'old/qemu-img') -Banner $script:Cloudbase
        $null = New-FakeQemuImg -Path (Join-Path $root 'new/qemu-img') -Banner $script:Current
        $null = New-FakeQemuImg -Path (Get-ManagedPath $root) -Banner $script:Current
        $list = @(Get-QemuImgCandidate -WindowsLayout $false)
        Assert-Equal 1 $list.Count -Because 'the drivers run the name; repairing what it resolves to is the installer job'
        Assert-StringEqual $old $list[0]
    }
}

Describe 'Resolve-QemuImgCommand' {
    AfterEach { Exit-FakeHost }

    It 'runs the 11.1.0 in Program Files, not the 2.3.0 first on PATH (the Windows install that reported BELOW)' {
        if (-not $script:CanFake) { Set-ItResult -Skipped -Because $script:Skip; return }
        $root = Enter-FakeHost -PathDirectory @('cloudbase')
        $managed = New-FakeQemuImg -Path (Get-ManagedPath $root) -Banner $script:Current
        $null = New-FakeQemuImg -Path (Join-Path $root 'cloudbase/qemu-img') -Banner $script:Cloudbase
        Assert-StringEqual $managed (Resolve-QemuImgCommand -WindowsLayout $true)
    }

    It 'runs a newer copy on PATH over an older one in Program Files' {
        if (-not $script:CanFake) { Set-ItResult -Skipped -Because $script:Skip; return }
        $root = Enter-FakeHost -PathDirectory @('msys')
        $null = New-FakeQemuImg -Path (Get-ManagedPath $root) -Banner 'qemu-img version 10.2.1'
        $msys = New-FakeQemuImg -Path (Join-Path $root 'msys/qemu-img') -Banner $script:Current
        Assert-StringEqual $msys (Resolve-QemuImgCommand -WindowsLayout $true)
    }

    It 'still finds the Program Files copy when nothing is on PATH' {
        if (-not $script:CanFake) { Set-ItResult -Skipped -Because $script:Skip; return }
        $root = Enter-FakeHost
        $managed = New-FakeQemuImg -Path (Get-ManagedPath $root) -Banner $script:Current
        Assert-StringEqual $managed (Resolve-QemuImgCommand -WindowsLayout $true)
    }

    It 'runs what the name resolves to outside the Windows layout, even when a newer copy is later on PATH' {
        if (-not $script:CanFake) { Set-ItResult -Skipped -Because $script:Skip; return }
        $root = Enter-FakeHost -PathDirectory @('old', 'new')
        $old = New-FakeQemuImg -Path (Join-Path $root 'old/qemu-img') -Banner $script:Cloudbase
        $null = New-FakeQemuImg -Path (Join-Path $root 'new/qemu-img') -Banner $script:Current
        Assert-StringEqual $old (Resolve-QemuImgCommand -WindowsLayout $false)
    }

    It 'answers nothing when no copy is installed' {
        if (-not $script:CanFake) { Set-ItResult -Skipped -Because $script:Skip; return }
        $null = Enter-FakeHost
        Assert-Null (Resolve-QemuImgCommand -WindowsLayout $true)
        $detail = Resolve-QemuImgCommand -WindowsLayout $true -Detailed
        Assert-Null $detail.Path
        Assert-Null $detail.NamePath
        Assert-Equal 0 @($detail.Candidate).Count
    }

    It 'describes the chosen copy, every candidate and the copy the name runs with -Detailed' {
        if (-not $script:CanFake) { Set-ItResult -Skipped -Because $script:Skip; return }
        $root = Enter-FakeHost -PathDirectory @('cloudbase')
        $managed = New-FakeQemuImg -Path (Get-ManagedPath $root) -Banner $script:Current
        $cloudbase = New-FakeQemuImg -Path (Join-Path $root 'cloudbase/qemu-img') -Banner $script:Cloudbase
        $detail = Resolve-QemuImgCommand -WindowsLayout $true -Detailed
        Assert-StringEqual $managed $detail.Path
        Assert-Equal ([version]'11.1.0') $detail.Version
        Assert-StringEqual $cloudbase $detail.NamePath 'the name runs the PATH copy'
        Assert-Equal ([version]'2.3.0') $detail.NameVersion
        Assert-Equal 2 @($detail.Candidate).Count
        Assert-StringEqual 'Yuruna.QemuImgResolution' $detail.PSTypeNames[0]
    }
}

Describe 'The version floor probe ranks the copies the same way' {
    AfterEach { Exit-FakeHost }

    It 'reports the newest copy on Windows, not the one first on PATH' {
        if (-not $script:CanFake) { Set-ItResult -Skipped -Because $script:Skip; return }
        $root = Enter-FakeHost -PathDirectory @('cloudbase')
        $null = New-FakeQemuImg -Path (Get-ManagedPath $root) -Banner $script:Current
        $null = New-FakeQemuImg -Path (Join-Path $root 'cloudbase/qemu-img') -Banner $script:Cloudbase
        $found = Invoke-ProbeText (ConvertTo-WindowsBranch $script:RequirementProbe)
        Assert-StringEqual $script:Current ([string]$found) 'the floor is judged on the copy the harness runs'
    }

    It 'reports a Cloudbase-only Windows host as 2.3.0, without its Copyright tail' {
        if (-not $script:CanFake) { Set-ItResult -Skipped -Because $script:Skip; return }
        $root = Enter-FakeHost -PathDirectory @('cloudbase')
        $null = New-FakeQemuImg -Path (Join-Path $root 'cloudbase/qemu-img') -Banner $script:Cloudbase
        $found = Invoke-ProbeText (ConvertTo-WindowsBranch $script:RequirementProbe)
        Assert-StringEqual 'qemu-img version 2.3.0' ([string]$found) 'a genuine shortfall still reads as one'
    }

    It 'reports what the name resolves to elsewhere' {
        if (-not $script:CanFake) { Set-ItResult -Skipped -Because $script:Skip; return }
        $root = Enter-FakeHost -PathDirectory @('old', 'new')
        $null = New-FakeQemuImg -Path (Join-Path $root 'old/qemu-img') -Banner $script:Cloudbase
        $null = New-FakeQemuImg -Path (Join-Path $root 'new/qemu-img') -Banner $script:Current
        $found = Invoke-ProbeText $script:RequirementProbe
        Assert-StringEqual 'qemu-img version 2.3.0' ([string]$found) 'the macOS repair loop depends on this reading the copy the name runs'
    }
}

Describe 'The standalone diagnostic ranks the copies the same way' {
    AfterEach { Exit-FakeHost }

    It 'names the copy the harness runs and the older copy the name resolves to (Windows)' {
        if (-not $script:CanFake) { Set-ItResult -Skipped -Because $script:Skip; return }
        $root = Enter-FakeHost -PathDirectory @('cloudbase')
        $managed = New-FakeQemuImg -Path (Get-ManagedPath $root) -Banner $script:Current
        $cloudbase = New-FakeQemuImg -Path (Join-Path $root 'cloudbase/qemu-img') -Banner $script:Cloudbase
        $line = [string](& ([scriptblock]::Create((ConvertTo-WindowsBranch $script:DiagnosticProbe))))
        Assert-StringEqual "$($script:Current) [$managed]; the name qemu-img resolves to qemu-img version 2.3.0 [$cloudbase]" $line
    }

    It 'names only the copy when the name already runs it' {
        if (-not $script:CanFake) { Set-ItResult -Skipped -Because $script:Skip; return }
        $root = Enter-FakeHost -PathDirectory @('bin')
        $only = New-FakeQemuImg -Path (Join-Path $root 'bin/qemu-img') -Banner $script:Current
        $windows = [string](& ([scriptblock]::Create((ConvertTo-WindowsBranch $script:DiagnosticProbe))))
        Assert-StringEqual "$($script:Current) [$only]" $windows
        $elsewhere = [string](& ([scriptblock]::Create($script:DiagnosticProbe)))
        Assert-StringEqual "$($script:Current) [$only]" $elsewhere
    }

    It 'prints nothing when no copy is installed, so the report says not installed' {
        if (-not $script:CanFake) { Set-ItResult -Skipped -Because $script:Skip; return }
        $null = Enter-FakeHost
        $line = & ([scriptblock]::Create((ConvertTo-WindowsBranch $script:DiagnosticProbe)))
        Assert-True ([string]::IsNullOrWhiteSpace([string]$line)) "nothing to report ($line)"
    }
}

Describe 'The copies name the same installer locations' {
    It 'uses the resolver''s Program Files paths in the floor probe and the diagnostic' {
        $pattern = '"\$env:ProgramFiles\\qemu\\qemu-img\.exe"|"\$\{env:ProgramFiles\(x86\)\}\\qemu\\qemu-img\.exe"'
        $module = [IO.File]::ReadAllText((Join-Path $script:RepoRoot 'host/modules/Yuruna.Image.psm1'))
        $expected = @([regex]::Matches($module, $pattern) | ForEach-Object Value | Sort-Object -Unique)
        Assert-Equal 2 $expected.Count -Because 'the resolver names both installer locations'
        foreach ($copy in @(@{ Name = 'floor probe'; Text = $script:RequirementProbe }, @{ Name = 'diagnostic'; Text = $script:DiagnosticProbe })) {
            $found = @([regex]::Matches($copy.Text, $pattern) | ForEach-Object Value | Sort-Object -Unique)
            Assert-StringEqual ($expected -join '|') ($found -join '|') "the $($copy.Name) names the same locations"
            Assert-Match 'Get-Command qemu-img -CommandType Application -All' $copy.Text "the $($copy.Name) ranks every PATH copy"
            Assert-Match '\$copyVersion -gt \$bestVersion' $copy.Text "the $($copy.Name) keeps the newest, the earlier on a tie"
        }
    }
}

Describe 'Get-QemuImgPrecedenceNote (Windows installer)' {
    It 'warns when the name runs an older copy than the harness, naming both and the fix' {
        $note = Get-QemuImgPrecedenceNote -Resolution ([pscustomobject]@{
                Path = 'C:\Program Files\qemu\qemu-img.exe'; Version = '11.1.0'
                NamePath = 'C:\ProgramData\chocolatey\bin\qemu-img.exe'; NameVersion = '2.3.0' })
        Assert-StringEqual '  qemu-img the harness uses: 11.1.0 at C:\Program Files\qemu\qemu-img.exe' $note.Step
        Assert-Match ([regex]::Escape('qemu-img 2.3.0 at C:\ProgramData\chocolatey\bin\qemu-img.exe')) $note.Warning 'the older copy is named with its path'
        Assert-Match '11\.1\.0 copy the harness uses' $note.Warning 'and set against the copy the harness runs'
        Assert-Match 'winget uninstall --id cloudbase\.qemu-img' $note.Warning 'the winget removal is spelled out'
        Assert-Match 'choco uninstall qemu-img' $note.Warning 'and the Chocolatey one'
    }

    It 'says nothing more when <Case>' -TestCases @(
        @{ Case = 'the name runs the same copy';            NamePath = 'c:\program files\qemu\qemu-img.exe'; NameVersion = '11.1.0' }
        @{ Case = 'nothing is on PATH';                      NamePath = '';                                   NameVersion = '' }
        @{ Case = 'the copy on PATH is just as new';         NamePath = 'C:\msys64\usr\bin\qemu-img.exe';     NameVersion = '11.1.0' }
    ) {
        param($Case, $NamePath, $NameVersion)
        $note = Get-QemuImgPrecedenceNote -Resolution ([pscustomobject]@{
                Path = 'C:\Program Files\qemu\qemu-img.exe'; Version = '11.1.0'; NamePath = $NamePath; NameVersion = $NameVersion })
        Assert-True ([bool]$note.Step) "$Case still names the copy the harness runs"
        Assert-Null $note.Warning $Case
    }

    It 'warns about a copy on PATH that reports no version' {
        $note = Get-QemuImgPrecedenceNote -Resolution ([pscustomobject]@{
                Path = 'C:\Program Files\qemu\qemu-img.exe'; Version = '11.1.0'; NamePath = 'C:\tools\qemu-img.exe'; NameVersion = '' })
        Assert-Match 'a qemu-img that reports no version at C:\\tools\\qemu-img\.exe' $note.Warning
    }

    It 'says nothing at all when no copy is installed' {
        foreach ($resolution in @($null, [pscustomobject]@{ Path = $null; Version = ''; NamePath = $null; NameVersion = '' })) {
            $note = Get-QemuImgPrecedenceNote -Resolution $resolution
            Assert-Null $note.Step
            Assert-Null $note.Warning
        }
    }

    It 'is fed by the child command the installer runs, with the fields it reads' {
        if (-not $script:CanFake) { Set-ItResult -Skipped -Because $script:Skip; return }
        $installer = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'install/windows.hyper-v.ps1'), [ref]$null, [ref]$null)
        $command = $installer.Find({ param($node)
                $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -match 'Resolve-QemuImgCommand -Detailed' }, $true)
        Assert-NotNull $command 'the installer still asks the resolver in a child pwsh'
        $root = Enter-FakeHost -PathDirectory @('bin')
        try {
            $only = New-FakeQemuImg -Path (Join-Path $root 'bin/qemu-img') -Banner $script:Current
            $env:YURUNA_IMAGE_MODULE = Join-Path $script:RepoRoot 'host/modules/Yuruna.Image.psm1'
            $json = & ([Environment]::ProcessPath) -NoProfile -NonInteractive -Command $command.Value 2>$null
            $resolution = (@($json) -join '') | ConvertFrom-Json
            Assert-StringEqual $only $resolution.Path
            Assert-StringEqual '11.1.0' $resolution.Version 'versions cross the process boundary as strings'
            Assert-StringEqual $only $resolution.NamePath
            $note = Get-QemuImgPrecedenceNote -Resolution $resolution
            Assert-Match ([regex]::Escape($only)) $note.Step
            Assert-Null $note.Warning
        } finally {
            Remove-Item -LiteralPath 'Env:YURUNA_IMAGE_MODULE' -ErrorAction SilentlyContinue
            Exit-FakeHost
        }
    }
}
