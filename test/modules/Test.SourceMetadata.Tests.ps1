<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 42ba21e6-945f-48b7-aacb-cdc136e03c30
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test license copyright guid metadata pester
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
    Hold tools/Test-SourceMetadata.ps1 to its rules: the copyright line, the
    license pointer above it, a unique 42-prefixed PowerShell GUID, the three
    exemption kinds, and the line between a gap a commit introduces and one it
    merely inherits.
.DESCRIPTION
    Every case builds a disposable git repository under TestDrive, named after
    the repository the exemptions file talks about, and runs the real tool
    against it in its own process: the verdict that matters is the exit code
    and the text a person sees at commit time.

    Run: Invoke-Pester -Path test/modules/Test.SourceMetadata.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
$script:RepoRoot = Get-YurunaTestRepoRoot -SuiteDirectory $here
$script:Tool = Join-Path $script:RepoRoot 'tools/Test-SourceMetadata.ps1'
$script:SavedEnvironment = @{}
foreach ($name in 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM', 'GIT_DIR', 'GIT_INDEX_FILE', 'GIT_WORK_TREE') {
    $script:SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
# The user's global git configuration (signing, hooks, autocrlf) must not reach
# the fixture repositories, and a hook that runs this suite must not point git
# at its own index.
$script:EmptyGitConfig = Join-Path $TestDrive 'empty-gitconfig'
[IO.File]::WriteAllText($script:EmptyGitConfig, '')
$env:GIT_CONFIG_GLOBAL = $script:EmptyGitConfig
$env:GIT_CONFIG_NOSYSTEM = '1'
foreach ($name in 'GIT_DIR', 'GIT_INDEX_FILE', 'GIT_WORK_TREE') { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }

$script:Wrapper = @{
    hash = '# {0}'; slash = '// {0}'; block = '/* {0} */'; xml = '<!-- {0} -->'
    razor = '@* {0} *@'; sql = '-- {0}'; cmd = '@REM {0}'
}
$script:Pointer = 'LICENSEURI https://yuruna.link/license'
$script:Copyright = 'Copyright (c) 2019-2026 by Alisson Sol et al.'

function Write-FixtureFile {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only inside TestDrive.')]
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $full = Join-Path $Repository $Path
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $full))
    [IO.File]::WriteAllText($full, $Text, [Text.UTF8Encoding]::new($false))
}

function Invoke-FixtureGit {
    param([Parameter(Mandatory)][string]$Repository, [Parameter(Mandatory)][string[]]$Argument)
    $output = & git -C $Repository -c commit.gpgsign=false -c core.autocrlf=false @Argument 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Argument -join ' ') failed in ${Repository}: $output" }
    return @($output | ForEach-Object { [string]$_ })
}

function New-FixtureRepository {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates a disposable repository under TestDrive.')]
    param([Parameter(Mandatory)][string]$Name, [string]$Leaf = 'yuruna')
    $repository = Join-Path (Join-Path $TestDrive $Name) $Leaf
    [void][IO.Directory]::CreateDirectory($repository)
    $null = Invoke-FixtureGit -Repository $repository -Argument @('init', '--quiet', '--initial-branch=main')
    foreach ($setting in @(@('user.name', 'Synthetic test'), @('user.email', 'fixture@example.invalid'))) {
        $null = Invoke-FixtureGit -Repository $repository -Argument (@('config') + $setting)
    }
    return $repository
}

function Save-FixtureCommit {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Commits inside a disposable repository.')]
    param([Parameter(Mandatory)][string]$Repository)
    $null = Invoke-FixtureGit -Repository $Repository -Argument @('add', '-A')
    $null = Invoke-FixtureGit -Repository $Repository -Argument @('commit', '--quiet', '-m', 'seed')
}

function Add-FixtureStage {
    param([Parameter(Mandatory)][string]$Repository, [string[]]$Path = @('-A'))
    $null = Invoke-FixtureGit -Repository $Repository -Argument (@('add') + $Path)
}

function Get-HeaderText {
    param([Parameter(Mandatory)][string]$Style)
    return ($script:Wrapper[$Style] -f $script:Pointer) + "`n" + ($script:Wrapper[$Style] -f $script:Copyright) + "`n"
}

function Get-TestGuid {
    $n = [guid]::NewGuid().ToString('N')
    return '42' + $n.Substring(2, 6) + '-' + $n.Substring(8, 4) + '-' + $n.Substring(12, 4) + '-' + $n.Substring(16, 4) + '-' + $n.Substring(20, 12)
}

function Get-PsInfoText {
    param([string]$Guid = (Get-TestGuid), [switch]$NoGuid, [switch]$NoCopyright, [switch]$NoPointer)
    $lines = @('<#PSScriptInfo', '.VERSION 2026.10.18.2')
    if (-not $NoGuid) { $lines += ".GUID $Guid" }
    $lines += '.AUTHOR Alisson Sol et al.'
    if (-not $NoCopyright) { $lines += '.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.' }
    if (-not $NoPointer) { $lines += '.LICENSEURI https://yuruna.link/license' }
    $lines += '.PROJECTURI https://yuruna.com'
    $lines += '#>'
    return ($lines -join "`n") + "`n`nparam()`n"
}

function Write-Exemption {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Writes only inside TestDrive.')]
    param([Parameter(Mandatory)][string]$Name, $Body)
    $path = Join-Path $TestDrive "$Name.exemptions.json"
    if ($Body -isnot [string]) {
        $document = [ordered]@{ schema = 'yuruna.source-metadata/v1' }
        foreach ($key in $Body.Keys) { $document[$key] = $Body[$key] }
        $Body = ConvertTo-Json -InputObject $document -Depth 8
    }
    [IO.File]::WriteAllText($path, $Body, [Text.UTF8Encoding]::new($false))
    return $path
}

function Invoke-MetadataGate {
    param([Parameter(Mandatory)][string[]]$Argument)
    $output = & pwsh -NoProfile -File $script:Tool @Argument 2>&1 | ForEach-Object { [string]$_ } | Out-String
    return @{ Code = $LASTEXITCODE; Output = ($output -replace "`r`n", "`n") }
}

function Test-Flagged {
    param([Parameter(Mandatory)][string]$Output, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Rule, [string]$Label = 'FAIL')
    return $Output -match ('(?m)^{0}\s+{1}\s+\[{2}\]' -f $Label, [regex]::Escape($Path), [regex]::Escape($Rule))
}

$script:NoExemption = Write-Exemption -Name 'none' -Body @{}
}

AfterAll {
    foreach ($name in $script:SavedEnvironment.Keys) {
        if ($null -eq $script:SavedEnvironment[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue }
        else { Set-Item -LiteralPath "Env:$name" -Value $script:SavedEnvironment[$name] }
    }
}

Describe 'the copyright rule' {
    BeforeAll {
        $script:FormatRepo = New-FixtureRepository -Name 'formats'
        $script:Sample = @(
            @{ Path = 'a.sh'; Style = 'hash'; Lead = "#!/bin/sh`n" }
            @{ Path = 'b.py'; Style = 'hash'; Lead = '' }
            @{ Path = 'c.go'; Style = 'slash'; Lead = '' }
            @{ Path = 'd.css'; Style = 'block'; Lead = '' }
            @{ Path = 'e.html'; Style = 'xml'; Lead = "<!doctype html>`n" }
            @{ Path = 'f.cshtml'; Style = 'razor'; Lead = '' }
            @{ Path = 'g.sql'; Style = 'sql'; Lead = '' }
            @{ Path = 'h.cmd'; Style = 'cmd'; Lead = '' }
            @{ Path = 'i.yml'; Style = 'hash'; Lead = '' }
            @{ Path = 'j.toml'; Style = 'hash'; Lead = '' }
            @{ Path = 'Dockerfile'; Style = 'hash'; Lead = '' }
            @{ Path = 'k.cs'; Style = 'slash'; Lead = '' }
            @{ Path = 'l.csproj'; Style = 'xml'; Lead = '' }
            @{ Path = 'noext-script'; Style = 'hash'; Lead = "#!/usr/bin/env bash`n" }
        )
        foreach ($sample in $script:Sample) {
            Write-FixtureFile -Repository $script:FormatRepo -Path "good/$($sample.Path)" -Text ($sample.Lead + (Get-HeaderText -Style $sample.Style) + "body`n")
            Write-FixtureFile -Repository $script:FormatRepo -Path "bad/$($sample.Path)" -Text ($sample.Lead + "body`n")
        }
        # No comment syntax (json), a footer convention (md), data (txt, lock),
        # no extension and no shebang, and a dotfile: none is covered.
        foreach ($path in 'skip/data.json', 'skip/notes.md', 'skip/plain.txt', 'skip/blob.lock', 'skip/no-extension', 'skip/.gitignore') {
            Write-FixtureFile -Repository $script:FormatRepo -Path $path -Text "no header`n"
        }
        Add-FixtureStage -Repository $script:FormatRepo
        $script:Run = Invoke-MetadataGate -Argument @('-Staged', '-Root', $script:FormatRepo, '-ExemptionsPath', $script:NoExemption)
    }

    It 'blocks the commit' {
        Assert-Equal -Expected 1 -Actual $script:Run.Code -Because $script:Run.Output
    }

    It 'flags a covered file without the header, in every comment style' {
        foreach ($sample in $script:Sample) {
            Assert-True (Test-Flagged -Output $script:Run.Output -Path "bad/$($sample.Path)" -Rule 'copyright') "bad/$($sample.Path) was not flagged:`n$($script:Run.Output)"
        }
    }

    It 'passes a covered file that carries the header' {
        Assert-False ($script:Run.Output -match 'good/') "a compliant file was reported:`n$($script:Run.Output)"
    }

    It 'leaves alone the formats that cannot or do not carry one' {
        Assert-False ($script:Run.Output -match 'skip/') "an uncovered file was reported:`n$($script:Run.Output)"
    }

    It 'prints the two header lines in the comment syntax of the file' {
        Assert-Match -Pattern '<!-- LICENSEURI https://yuruna\.link/license -->' -Actual $script:Run.Output
        Assert-Match -Pattern '@REM Copyright \(c\) 2019-\d{4} by Alisson Sol et al\.' -Actual $script:Run.Output
        Assert-Match -Pattern '/\* Copyright \(c\) 2019-\d{4} by Alisson Sol et al\. \*/' -Actual $script:Run.Output
    }

    It 'prints a fix once, and gives each further file that needs the same fix one line' {
        Assert-Equal -Expected 1 -Actual @([regex]::Matches($script:Run.Output, '(?m)^\s+# LICENSEURI https://yuruna\.link/license$')).Count `
            -Because $script:Run.Output
        Assert-Match -Pattern "(?m)^FAIL  bad/b\.py  \[copyright\]  no 'Copyright" -Actual $script:Run.Output
    }

    It 'names how a generated or vendored file avoids the rule' {
        Assert-Match -Pattern 'tools/source-metadata\.exemptions\.json' -Actual $script:Run.Output
    }
}

Describe 'what counts as a copyright line' {
    BeforeAll {
        $script:LineRepo = New-FixtureRepository -Name 'copyright-lines'
        $r = $script:LineRepo
        $hash = Get-HeaderText -Style 'hash'
        Write-FixtureFile -Repository $r -Path 'ok/one-year.sh' -Text "# $script:Pointer`n# Copyright (c) 2026 by Alisson Sol et al.`n"
        Write-FixtureFile -Repository $r -Path 'ok/crlf.sh' -Text ($hash -replace "`n", "`r`n")
        Write-FixtureFile -Repository $r -Path 'ok/bom.go' -Text ([string][char]0xFEFF + (Get-HeaderText -Style 'slash'))
        Write-FixtureFile -Repository $r -Path 'ok/last-line-of-window.sh' -Text ((('#' + "`n") * 38) + $hash)
        Write-FixtureFile -Repository $r -Path 'bad/other-holder.sh' -Text "# $script:Pointer`n# Copyright (c) 2019-2026 by Someone Else`n"
        Write-FixtureFile -Repository $r -Path 'bad/no-years.sh' -Text "# $script:Pointer`n# Copyright (c) by Alisson Sol et al.`n"
        Write-FixtureFile -Repository $r -Path 'bad/past-the-window.sh' -Text ((('# filler' + "`n") * 40) + $hash)
        Add-FixtureStage -Repository $r
        $script:Run = Invoke-MetadataGate -Argument @('-Staged', '-Root', $r, '-ExemptionsPath', $script:NoExemption)
    }

    It 'accepts a single year, CRLF line endings, a byte-order mark and a header ending on line 40' {
        Assert-False ($script:Run.Output -match 'ok/') "a compliant file was reported:`n$($script:Run.Output)"
    }

    It 'rejects another holder, a missing year and a header past line 40' {
        foreach ($path in 'bad/other-holder.sh', 'bad/no-years.sh', 'bad/past-the-window.sh') {
            Assert-True (Test-Flagged -Output $script:Run.Output -Path $path -Rule 'copyright') "$path was not flagged:`n$($script:Run.Output)"
        }
    }
}

Describe 'the license pointer rule' {
    BeforeAll {
        $script:PointerRepo = New-FixtureRepository -Name 'pointer'
        $r = $script:PointerRepo
        $copyright = "# $script:Copyright`n"
        Write-FixtureFile -Repository $r -Path 'bad/missing.sh' -Text $copyright
        Write-FixtureFile -Repository $r -Path 'bad/apart.sh' -Text "# $script:Pointer`n# Maintained by hand.`n$copyright"
        Write-FixtureFile -Repository $r -Path 'bad/after.sh' -Text "$copyright# $script:Pointer`n"
        Write-FixtureFile -Repository $r -Path 'bad/wrong-url.sh' -Text "# LICENSEURI https://example.invalid/license`n$copyright"
        Write-FixtureFile -Repository $r -Path 'bad/longer-url.sh' -Text "# LICENSEURI https://yuruna.link/license-old`n$copyright"
        Write-FixtureFile -Repository $r -Path 'bad/no-uri.ps1' -Text (Get-PsInfoText -NoPointer)
        Write-FixtureFile -Repository $r -Path 'ok/blank-between.sh' -Text "# $script:Pointer`n`n$copyright"
        Write-FixtureFile -Repository $r -Path 'ok/one-block.html' -Text "<!--`n  $script:Pointer`n  $script:Copyright`n-->`n"
        Write-FixtureFile -Repository $r -Path 'ok/after-shebang.sh' -Text "#!/bin/sh`n# Version: 1`n# $script:Pointer`n$copyright"
        Write-FixtureFile -Repository $r -Path 'ok/psinfo.ps1' -Text (Get-PsInfoText)
        Add-FixtureStage -Repository $r
        $script:Run = Invoke-MetadataGate -Argument @('-Staged', '-Root', $r, '-ExemptionsPath', $script:NoExemption)
    }

    It 'flags a copyright with no pointer, a pointer that is not directly above it, and a pointer to another URL' {
        foreach ($path in 'bad/missing.sh', 'bad/apart.sh', 'bad/after.sh', 'bad/wrong-url.sh', 'bad/longer-url.sh') {
            Assert-True (Test-Flagged -Output $script:Run.Output -Path $path -Rule 'license-pointer') "$path was not flagged:`n$($script:Run.Output)"
        }
    }

    It 'flags a PSScriptInfo block that has no .LICENSEURI' {
        Assert-True (Test-Flagged -Output $script:Run.Output -Path 'bad/no-uri.ps1' -Rule 'license-pointer') $script:Run.Output
    }

    It 'accepts blank lines between the two, one comment block holding both, and a PSScriptInfo block' {
        Assert-False ($script:Run.Output -match 'ok/') "a compliant file was reported:`n$($script:Run.Output)"
    }

    It 'shows the line to add' {
        Assert-Match -Pattern '(?s)Put this line directly above the copyright line:\s+# LICENSEURI https://yuruna\.link/license' -Actual $script:Run.Output
    }
}

Describe 'the PowerShell identity rule' {
    BeforeAll {
        $script:IdentityRepo = New-FixtureRepository -Name 'identity'
        $r = $script:IdentityRepo
        Write-FixtureFile -Repository $r -Path 'ok/script.ps1' -Text (Get-PsInfoText)
        Write-FixtureFile -Repository $r -Path 'ok/module.psm1' -Text (Get-PsInfoText)
        Write-FixtureFile -Repository $r -Path 'ok/data.psd1' -Text (Get-PsInfoText)
        Write-FixtureFile -Repository $r -Path 'bad/no-block.ps1' -Text "# $script:Pointer`n# $script:Copyright`nparam()`n"
        Write-FixtureFile -Repository $r -Path 'bad/no-guid.ps1' -Text (Get-PsInfoText -NoGuid)
        Write-FixtureFile -Repository $r -Path 'bad/not-42.ps1' -Text (Get-PsInfoText -Guid '1f2e3d4c-aaaa-4bbb-8ccc-0123456789ab')
        Write-FixtureFile -Repository $r -Path 'bad/malformed.ps1' -Text (Get-PsInfoText -Guid '42-not-a-guid')
        Write-FixtureFile -Repository $r -Path 'bad/no-copyright.ps1' -Text (Get-PsInfoText -NoCopyright)
        Add-FixtureStage -Repository $r
        $script:Run = Invoke-MetadataGate -Argument @('-Staged', '-Root', $r, '-ExemptionsPath', $script:NoExemption)
    }

    It 'accepts a script, a module and a data file with a complete block' {
        Assert-False ($script:Run.Output -match 'ok/') "a compliant file was reported:`n$($script:Run.Output)"
    }

    It 'wants the PSScriptInfo block itself, not loose comment lines' {
        Assert-True (Test-Flagged -Output $script:Run.Output -Path 'bad/no-block.ps1' -Rule 'psscriptinfo') $script:Run.Output
    }

    It 'flags a missing, non-42 and malformed GUID, and a block without .COPYRIGHT' {
        Assert-True (Test-Flagged -Output $script:Run.Output -Path 'bad/no-guid.ps1' -Rule 'guid') $script:Run.Output
        Assert-True (Test-Flagged -Output $script:Run.Output -Path 'bad/not-42.ps1' -Rule 'guid') $script:Run.Output
        Assert-True (Test-Flagged -Output $script:Run.Output -Path 'bad/malformed.ps1' -Rule 'guid') $script:Run.Output
        Assert-True (Test-Flagged -Output $script:Run.Output -Path 'bad/no-copyright.ps1' -Rule 'copyright') $script:Run.Output
    }

    It 'offers a fresh 42-prefixed GUID to use' {
        Assert-Match -Pattern '(?m)^\s+fix: \.GUID 42[0-9a-f]{6}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -Actual $script:Run.Output
    }
}

Describe 'GUID uniqueness' {
    BeforeAll {
        $script:GuidRepo = New-FixtureRepository -Name 'unique'
        $r = $script:GuidRepo
        $script:Taken = Get-TestGuid
        $script:Twin = Get-TestGuid
        Write-FixtureFile -Repository $r -Path 'lib/taken.psm1' -Text (Get-PsInfoText -Guid $script:Taken.ToUpperInvariant())
        Write-FixtureFile -Repository $r -Path 'lib/other.psm1' -Text (Get-PsInfoText)
        Save-FixtureCommit -Repository $r
        Write-FixtureFile -Repository $r -Path 'new/copied.ps1' -Text (Get-PsInfoText -Guid $script:Taken)
        Write-FixtureFile -Repository $r -Path 'new/twin-a.ps1' -Text (Get-PsInfoText -Guid $script:Twin)
        Write-FixtureFile -Repository $r -Path 'new/twin-b.ps1' -Text (Get-PsInfoText -Guid $script:Twin)
        Write-FixtureFile -Repository $r -Path 'new/fresh.ps1' -Text (Get-PsInfoText)
        Write-FixtureFile -Repository $r -Path 'lib/taken.psm1' -Text ((Get-PsInfoText -Guid $script:Taken.ToUpperInvariant()) + "# edited`n")
        Add-FixtureStage -Repository $r
        $script:Run = Invoke-MetadataGate -Argument @('-Staged', '-Root', $r, '-ExemptionsPath', $script:NoExemption)
    }

    It 'flags a new file that reuses the GUID of a tracked one, whatever the letter case, and names the owner' {
        Assert-True (Test-Flagged -Output $script:Run.Output -Path 'new/copied.ps1' -Rule 'guid') $script:Run.Output
        Assert-Match -Pattern 'new/copied\.ps1[\s\S]*?is also declared by lib/taken\.psm1' -Actual $script:Run.Output
    }

    It 'flags two new files that share a GUID' {
        Assert-True (Test-Flagged -Output $script:Run.Output -Path 'new/twin-a.ps1' -Rule 'guid') $script:Run.Output
        Assert-True (Test-Flagged -Output $script:Run.Output -Path 'new/twin-b.ps1' -Rule 'guid') $script:Run.Output
    }

    It 'does not blame a file for the GUID it has always held, nor a file with its own' {
        Assert-False (Test-Flagged -Output $script:Run.Output -Path 'lib/taken.psm1' -Rule 'guid') $script:Run.Output
        Assert-False ($script:Run.Output -match 'new/fresh\.ps1') $script:Run.Output
    }

    It 'points at the synchronized-copy declaration for deliberate copies' {
        Assert-Match -Pattern 'synchronizedCopies in tools/source-metadata\.exemptions\.json' -Actual $script:Run.Output
    }
}

Describe 'the exemptions' {
    BeforeAll {
        $script:ExemptRepo = New-FixtureRepository -Name 'exempt'
        $r = $script:ExemptRepo
        $script:Shared = Get-TestGuid
        $script:ExemptFile = Write-Exemption -Name 'exempt' -Body @{
            generated = @(@{ repo = 'yuruna'; generator = 'tools/Make-Stuff.ps1'; paths = @('gen/*.go'); reason = 'Written whole by the fixture generator.' })
            vendored = @(@{ repo = 'yuruna'; paths = @('third/*.js'); reason = 'Upstream header kept.' })
            synchronizedCopies = @(@{
                    repo = 'yuruna'; syncTool = 'tools/Sync.ps1'; files = @('a/Copy.psm1', 'b/Copy.psm1')
                    reason = 'Identical copies kept in step by the fixture sync tool.' })
        }
        Write-FixtureFile -Repository $r -Path 'a/Copy.psm1' -Text (Get-PsInfoText -Guid $script:Shared)
        Write-FixtureFile -Repository $r -Path 'b/Copy.psm1' -Text (Get-PsInfoText -Guid $script:Shared)
        Save-FixtureCommit -Repository $r
        Write-FixtureFile -Repository $r -Path 'gen/named.go' -Text "// Generated by tools/Make-Stuff.ps1 from nothing.`npackage gen`n"
        Write-FixtureFile -Repository $r -Path 'gen/imposter.go' -Text "package gen`n"
        Write-FixtureFile -Repository $r -Path 'gen/headed.go' -Text ((Get-HeaderText -Style 'slash') + "package gen`n")
        Write-FixtureFile -Repository $r -Path 'gen/not-go.py' -Text "print('x')`n"
        Write-FixtureFile -Repository $r -Path 'third/lib.js' -Text "/* (c) Someone Else, MIT */`n"
        Write-FixtureFile -Repository $r -Path 'elsewhere/new.go' -Text "package elsewhere`n"
        Write-FixtureFile -Repository $r -Path 'a/Copy.psm1' -Text ((Get-PsInfoText -Guid $script:Shared) + "# synced edit`n")
        Write-FixtureFile -Repository $r -Path 'b/Copy.psm1' -Text ((Get-PsInfoText -Guid $script:Shared) + "# synced edit`n")
        Write-FixtureFile -Repository $r -Path 'c/Copy.psm1' -Text (Get-PsInfoText -Guid $script:Shared)
        Add-FixtureStage -Repository $r
        $script:Run = Invoke-MetadataGate -Argument @('-Staged', '-Root', $r, '-ExemptionsPath', $script:ExemptFile)
    }

    It 'passes a generated file that names its generator, without any header' {
        Assert-False ($script:Run.Output -match 'gen/named\.go') $script:Run.Output
    }

    It 'passes a file under a generated path that carries the standard header instead' {
        Assert-False ($script:Run.Output -match 'gen/headed\.go') $script:Run.Output
    }

    It 'flags a file under a generated path that neither names the generator nor has a header' {
        Assert-True (Test-Flagged -Output $script:Run.Output -Path 'gen/imposter.go' -Rule 'generated-banner') $script:Run.Output
        Assert-Match -Pattern 'tools/Make-Stuff\.ps1' -Actual $script:Run.Output
    }

    It 'does not stretch a generated path to another extension or directory' {
        Assert-True (Test-Flagged -Output $script:Run.Output -Path 'gen/not-go.py' -Rule 'copyright') $script:Run.Output
        Assert-True (Test-Flagged -Output $script:Run.Output -Path 'elsewhere/new.go' -Rule 'copyright') $script:Run.Output
    }

    It 'leaves a vendored path alone' {
        Assert-False ($script:Run.Output -match 'third/lib\.js') $script:Run.Output
    }

    It 'lets declared synchronized copies share a GUID' {
        Assert-False (Test-Flagged -Output $script:Run.Output -Path 'a/Copy.psm1' -Rule 'guid') $script:Run.Output
        Assert-False (Test-Flagged -Output $script:Run.Output -Path 'b/Copy.psm1' -Rule 'guid') $script:Run.Output
    }

    It 'flags a further file that takes the shared GUID without being declared' {
        Assert-True (Test-Flagged -Output $script:Run.Output -Path 'c/Copy.psm1' -Rule 'guid') $script:Run.Output
    }

    It 'applies the entries of one repository to that repository only' {
        $clone = New-FixtureRepository -Name 'exempt-other-name' -Leaf 'not-yuruna'
        Write-FixtureFile -Repository $clone -Path 'gen/named.go' -Text "// Generated by tools/Make-Stuff.ps1 from nothing.`npackage gen`n"
        Add-FixtureStage -Repository $clone
        $other = Invoke-MetadataGate -Argument @('-Staged', '-Root', $clone, '-ExemptionsPath', $script:ExemptFile)
        Assert-Equal -Expected 1 -Actual $other.Code -Because $other.Output
        Assert-True (Test-Flagged -Output $other.Output -Path 'gen/named.go' -Rule 'copyright') $other.Output
        $named = Invoke-MetadataGate -Argument @('-Staged', '-Root', $clone, '-RepoName', 'yuruna', '-ExemptionsPath', $script:ExemptFile)
        Assert-Equal -Expected 0 -Actual $named.Code -Because $named.Output
    }

    It 'treats a linked worktree as the repository it belongs to, whatever its folder is called' {
        $main = New-FixtureRepository -Name 'worktree'
        Write-FixtureFile -Repository $main -Path 'seed.txt' -Text "seed`n"
        Save-FixtureCommit -Repository $main
        $linked = Join-Path (Split-Path -Parent $main) 'scratch-checkout'
        $null = Invoke-FixtureGit -Repository $main -Argument @('worktree', 'add', '--quiet', '--detach', $linked)
        Write-FixtureFile -Repository $linked -Path 'gen/named.go' -Text "// Generated by tools/Make-Stuff.ps1 from nothing.`npackage gen`n"
        Add-FixtureStage -Repository $linked
        $run = Invoke-MetadataGate -Argument @('-Staged', '-Root', $linked, '-ExemptionsPath', $script:ExemptFile)
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
    }
}

Describe 'an exemptions file the gate cannot trust' {
    BeforeAll {
        $script:BrokenRepo = New-FixtureRepository -Name 'broken'
        Write-FixtureFile -Repository $script:BrokenRepo -Path 'a.sh' -Text (Get-HeaderText -Style 'hash')
        Add-FixtureStage -Repository $script:BrokenRepo
        $script:Valid = @{ repo = 'yuruna'; generator = 'tools/Make.ps1'; paths = @('gen/*.go'); reason = 'Fixture.' }
    }

    It 'refuses to give a verdict, with a reason, when the file does not parse' {
        $path = Write-Exemption -Name 'garbage' -Body '{ not json'
        $run = Invoke-MetadataGate -Argument @('-Staged', '-Root', $script:BrokenRepo, '-ExemptionsPath', $path)
        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
        Assert-Match -Pattern 'is not usable' -Actual $run.Output
    }

    It 'refuses when the file is missing' {
        $run = Invoke-MetadataGate -Argument @('-Staged', '-Root', $script:BrokenRepo, '-ExemptionsPath', (Join-Path $TestDrive 'nonexistent.json'))
        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
    }

    It 'refuses an entry with no reason and names the entry' {
        $entry = @{} + $script:Valid; $entry['reason'] = ' '
        $run = Invoke-MetadataGate -Argument @('-Staged', '-Root', $script:BrokenRepo, '-ExemptionsPath', (Write-Exemption -Name 'no-reason' -Body @{ generated = @($entry) }))
        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
        Assert-Match -Pattern "generated\[0\] needs a non-empty 'reason'" -Actual $run.Output
    }

    It 'refuses a generated entry that does not name its generator' {
        $entry = @{} + $script:Valid; $entry.Remove('generator')
        $run = Invoke-MetadataGate -Argument @('-Staged', '-Root', $script:BrokenRepo, '-ExemptionsPath', (Write-Exemption -Name 'no-generator' -Body @{ generated = @($entry) }))
        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
        Assert-Match -Pattern "needs a non-empty 'generator'" -Actual $run.Output
    }

    It 'refuses a misspelled key instead of silently exempting nothing' {
        $entry = @{} + $script:Valid; $entry['path'] = @('x/*')
        $run = Invoke-MetadataGate -Argument @('-Staged', '-Root', $script:BrokenRepo, '-ExemptionsPath', (Write-Exemption -Name 'typo' -Body @{ generated = @($entry) }))
        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
        Assert-Match -Pattern "unknown key 'path'" -Actual $run.Output
        $top = Invoke-MetadataGate -Argument @('-Staged', '-Root', $script:BrokenRepo, '-ExemptionsPath', (Write-Exemption -Name 'typo-top' -Body @{ genarated = @($script:Valid) }))
        Assert-Equal -Expected 2 -Actual $top.Code -Because $top.Output
        Assert-Match -Pattern "unknown top-level key 'genarated'" -Actual $top.Output
    }

    It 'refuses a synchronized group of one file' {
        $group = @{ repo = 'yuruna'; syncTool = 'tools/Sync.ps1'; files = @('only.psm1'); reason = 'Fixture.' }
        $run = Invoke-MetadataGate -Argument @('-Staged', '-Root', $script:BrokenRepo, '-ExemptionsPath', (Write-Exemption -Name 'one-file' -Body @{ synchronizedCopies = @($group) }))
        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
        Assert-Match -Pattern 'at least two' -Actual $run.Output
    }

    It 'refuses a file written for another schema' {
        $run = Invoke-MetadataGate -Argument @('-Staged', '-Root', $script:BrokenRepo, '-ExemptionsPath', (Write-Exemption -Name 'schema' -Body '{ "schema": "other/v2" }'))
        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
    }
}

Describe 'staged-only scoping' {
    BeforeAll {
        function New-HistoryRepository {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Creates a disposable repository under TestDrive.')]
            param([Parameter(Mandatory)][string]$Name)
            $r = New-FixtureRepository -Name $Name
            Write-FixtureFile -Repository $r -Path 'old/debt.sh' -Text "#!/bin/sh`necho debt`n"
            Write-FixtureFile -Repository $r -Path 'old/good.sh' -Text ("#!/bin/sh`n" + (Get-HeaderText -Style 'hash') + "echo good`n")
            Write-FixtureFile -Repository $r -Path 'old/renamed-debt.sh' -Text "#!/bin/sh`necho renamed debt`n"
            Write-FixtureFile -Repository $r -Path 'old/gone.sh' -Text "#!/bin/sh`necho gone`n"
            Save-FixtureCommit -Repository $r
            return $r
        }
    }

    It 'ignores a violating file that is not staged, and says nothing when quiet' {
        $r = New-HistoryRepository -Name 'unstaged'
        Write-FixtureFile -Repository $r -Path 'new/untracked.sh' -Text "#!/bin/sh`necho no header`n"
        Write-FixtureFile -Repository $r -Path 'old/good.sh' -Text "#!/bin/sh`necho header gone from the working copy only`n"
        $run = Invoke-MetadataGate -Argument @('-Staged', '-Quiet', '-Root', $r, '-ExemptionsPath', $script:NoExemption)
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
        Assert-Equal -Expected '' -Actual "$($run.Output)".Trim() -Because 'a clean quiet run prints nothing'
    }

    It 'judges what is staged, not what the working copy has since become' {
        $r = New-HistoryRepository -Name 'index-wins'
        Write-FixtureFile -Repository $r -Path 'new/a.sh' -Text "#!/bin/sh`necho staged without header`n"
        Add-FixtureStage -Repository $r
        Write-FixtureFile -Repository $r -Path 'new/a.sh' -Text ("#!/bin/sh`n" + (Get-HeaderText -Style 'hash') + "echo fixed afterwards`n")
        $blocked = Invoke-MetadataGate -Argument @('-Staged', '-Root', $r, '-ExemptionsPath', $script:NoExemption)
        Assert-Equal -Expected 1 -Actual $blocked.Code -Because $blocked.Output
        Assert-True (Test-Flagged -Output $blocked.Output -Path 'new/a.sh' -Rule 'copyright') $blocked.Output
        Add-FixtureStage -Repository $r -Path @('new/a.sh')
        $passed = Invoke-MetadataGate -Argument @('-Staged', '-Root', $r, '-ExemptionsPath', $script:NoExemption)
        Assert-Equal -Expected 0 -Actual $passed.Code -Because $passed.Output
        Write-FixtureFile -Repository $r -Path 'new/a.sh' -Text "#!/bin/sh`necho header broken after staging`n"
        $still = Invoke-MetadataGate -Argument @('-Staged', '-Root', $r, '-ExemptionsPath', $script:NoExemption)
        Assert-Equal -Expected 0 -Actual $still.Code -Because $still.Output
    }

    It 'reports a gap in a file the commit only edits, without blocking' {
        $r = New-HistoryRepository -Name 'inherited'
        Write-FixtureFile -Repository $r -Path 'old/debt.sh' -Text "#!/bin/sh`necho debt`necho more`n"
        Add-FixtureStage -Repository $r
        $run = Invoke-MetadataGate -Argument @('-Staged', '-Root', $r, '-ExemptionsPath', $script:NoExemption)
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
        Assert-True (Test-Flagged -Output $run.Output -Path 'old/debt.sh' -Rule 'copyright' -Label 'NOTE') $run.Output
        $strict = Invoke-MetadataGate -Argument @('-Staged', '-FailOnDebt', '-Root', $r, '-ExemptionsPath', $script:NoExemption)
        Assert-Equal -Expected 1 -Actual $strict.Code -Because $strict.Output
        Assert-True (Test-Flagged -Output $strict.Output -Path 'old/debt.sh' -Rule 'copyright') $strict.Output
    }

    It 'blocks an edit that removes the header from a file that had one' {
        $r = New-HistoryRepository -Name 'regression'
        Write-FixtureFile -Repository $r -Path 'old/good.sh' -Text "#!/bin/sh`necho header removed`n"
        Add-FixtureStage -Repository $r
        $run = Invoke-MetadataGate -Argument @('-Staged', '-Root', $r, '-ExemptionsPath', $script:NoExemption)
        Assert-Equal -Expected 1 -Actual $run.Code -Because $run.Output
        Assert-True (Test-Flagged -Output $run.Output -Path 'old/good.sh' -Rule 'copyright') $run.Output
    }

    It 'does not blame a rename for a gap the file already had' {
        $r = New-HistoryRepository -Name 'rename'
        $null = Invoke-FixtureGit -Repository $r -Argument @('mv', 'old/renamed-debt.sh', 'moved-debt.sh')
        $run = Invoke-MetadataGate -Argument @('-Staged', '-Root', $r, '-ExemptionsPath', $script:NoExemption)
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
        Assert-True (Test-Flagged -Output $run.Output -Path 'moved-debt.sh' -Rule 'copyright' -Label 'NOTE') $run.Output
    }

    It 'ignores a deleted file' {
        $r = New-HistoryRepository -Name 'deleted'
        $null = Invoke-FixtureGit -Repository $r -Argument @('rm', '--quiet', 'old/gone.sh')
        $run = Invoke-MetadataGate -Argument @('-Staged', '-Root', $r, '-ExemptionsPath', $script:NoExemption)
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
        Assert-False ($run.Output -match 'gone\.sh') $run.Output
    }

    It 'says so when nothing is staged' {
        $r = New-HistoryRepository -Name 'nothing'
        $run = Invoke-MetadataGate -Argument @('-Staged', '-Root', $r, '-ExemptionsPath', $script:NoExemption)
        Assert-Equal -Expected 0 -Actual $run.Code -Because $run.Output
        Assert-Match -Pattern '0 file\(s\) checked' -Actual $run.Output
    }

    It 'checks the first commit of a repository that has no HEAD yet' {
        $r = New-FixtureRepository -Name 'unborn'
        Write-FixtureFile -Repository $r -Path 'first.sh' -Text "#!/bin/sh`necho first`n"
        Add-FixtureStage -Repository $r
        $run = Invoke-MetadataGate -Argument @('-Staged', '-Root', $r, '-ExemptionsPath', $script:NoExemption)
        Assert-Equal -Expected 1 -Actual $run.Code -Because $run.Output
        Assert-True (Test-Flagged -Output $run.Output -Path 'first.sh' -Rule 'copyright') $run.Output
    }
}

Describe 'the whole-tree report' {
    BeforeAll {
        $script:TreeRepo = New-FixtureRepository -Name 'tree'
        $r = $script:TreeRepo
        $script:Anchor = Get-TestGuid
        Write-FixtureFile -Repository $r -Path 'ok/a.sh' -Text ("#!/bin/sh`n" + (Get-HeaderText -Style 'hash'))
        Write-FixtureFile -Repository $r -Path 'ok/b.go' -Text (Get-HeaderText -Style 'slash')
        Write-FixtureFile -Repository $r -Path 'debt/c.sh' -Text "#!/bin/sh`necho c`n"
        Write-FixtureFile -Repository $r -Path 'debt/d.py' -Text "print('d')`n"
        Write-FixtureFile -Repository $r -Path 'gen/e.go' -Text "// Generated by tools/Make.ps1`npackage gen`n"
        Write-FixtureFile -Repository $r -Path 'ps/f.ps1' -Text (Get-PsInfoText -Guid $script:Anchor)
        Write-FixtureFile -Repository $r -Path 'skip/data.json' -Text "{}`n"
        Save-FixtureCommit -Repository $r
        $script:TreeExemption = Write-Exemption -Name 'tree' -Body @{
            generated = @(
                @{ repo = 'yuruna'; generator = 'tools/Make.ps1'; paths = @('gen/*.go'); reason = 'Fixture generator.' }
                @{ repo = 'yuruna'; generator = 'tools/Gone.ps1'; paths = @('nothing/*.go'); reason = 'Matches nothing.' })
            vendored = @(@{ repo = 'yuruna'; paths = @('ok/*.sh'); reason = 'Already compliant.' })
            synchronizedCopies = @(@{ repo = 'yuruna'; syncTool = 'tools/Sync.ps1'; files = @('ps/f.ps1', 'ps/missing.ps1'); reason = 'Fixture.' })
        }
        $script:Report = Invoke-MetadataGate -Argument @('-All', '-Root', $r, '-ExemptionsPath', $script:TreeExemption)
    }

    It 'reports the debt and still exits 0' {
        Assert-Equal -Expected 0 -Actual $script:Report.Code -Because $script:Report.Output
        Assert-Match -Pattern '6 checked file\(s\): 2 compliant \(1 of them synchronized copies\), 1 generated and exempt, 1 vendored and exempt, 2 with findings' -Actual $script:Report.Output
    }

    It 'counts the findings per rule and per directory' {
        Assert-Match -Pattern 'findings by rule: exemption 3, copyright 2' -Actual $script:Report.Output
        Assert-Match -Pattern '(?m)^\s+2\s+yuruna/debt$' -Actual $script:Report.Output
    }

    It 'lists every finding with -Detail' {
        $run = Invoke-MetadataGate -Argument @('-All', '-Detail', '-Root', $script:TreeRepo, '-ExemptionsPath', $script:TreeExemption)
        Assert-True (Test-Flagged -Output $run.Output -Path 'debt/c.sh' -Rule 'copyright' -Label 'GAP') $run.Output
        Assert-True (Test-Flagged -Output $run.Output -Path 'debt/d.py' -Rule 'copyright' -Label 'GAP') $run.Output
    }

    It 'calls out an exemption that matches nothing, one that covers only compliant files, and a broken sync group' {
        $run = Invoke-MetadataGate -Argument @('-All', '-Detail', '-Root', $script:TreeRepo, '-ExemptionsPath', $script:TreeExemption)
        Assert-Match -Pattern 'generated entry for tools/Gone\.ps1 matches no tracked file in yuruna' -Actual $run.Output
        Assert-Match -Pattern 'vendored entry covers only files that already carry the standard header' -Actual $run.Output
        Assert-Match -Pattern 'synchronized copies kept by tools/Sync\.ps1 are not all tracked files' -Actual $run.Output
    }

    It 'fails only when asked to' {
        $run = Invoke-MetadataGate -Argument @('-All', '-FailOnDebt', '-Quiet', '-Root', $script:TreeRepo, '-ExemptionsPath', $script:TreeExemption)
        Assert-Equal -Expected 1 -Actual $run.Code -Because $run.Output
        Assert-Equal -Expected 1 -Actual @($run.Output.Trim() -split "`n").Count -Because 'quiet prints the summary line only'
    }

    It 'reads the working tree, so a fix shows at once without staging' {
        $r = New-FixtureRepository -Name 'tree-edit'
        Write-FixtureFile -Repository $r -Path 'a.sh' -Text "#!/bin/sh`necho a`n"
        Save-FixtureCommit -Repository $r
        $before = Invoke-MetadataGate -Argument @('-All', '-FailOnDebt', '-Root', $r, '-ExemptionsPath', $script:NoExemption)
        Assert-Equal -Expected 1 -Actual $before.Code -Because $before.Output
        Write-FixtureFile -Repository $r -Path 'a.sh' -Text ("#!/bin/sh`n" + (Get-HeaderText -Style 'hash'))
        $after = Invoke-MetadataGate -Argument @('-All', '-FailOnDebt', '-Root', $r, '-ExemptionsPath', $script:NoExemption)
        Assert-Equal -Expected 0 -Actual $after.Code -Because $after.Output
    }

    It 'checks an extensionless script whose whole content is its shebang line, staged and tracked' {
        # One line and no trailing newline is the one head that holds a single
        # line; its first line must still be the line, not its first character.
        $r = New-FixtureRepository -Name 'shebang-only'
        Write-FixtureFile -Repository $r -Path 'run-me' -Text '#!/bin/sh'
        Add-FixtureStage -Repository $r
        $staged = Invoke-MetadataGate -Argument @('-Staged', '-Root', $r, '-ExemptionsPath', $script:NoExemption)
        Assert-True (Test-Flagged -Output $staged.Output -Path 'run-me' -Rule 'copyright') $staged.Output
        Save-FixtureCommit -Repository $r
        $tracked = Invoke-MetadataGate -Argument @('-All', '-Detail', '-Root', $r, '-ExemptionsPath', $script:NoExemption)
        Assert-True (Test-Flagged -Output $tracked.Output -Path 'run-me' -Rule 'copyright' -Label 'GAP') $tracked.Output
    }

    It 'compares GUIDs across the repositories it is given' {
        $shared = Get-TestGuid
        $one = New-FixtureRepository -Name 'cross-one' -Leaf 'yuruna'
        $two = New-FixtureRepository -Name 'cross-two' -Leaf 'yuruna-project'
        Write-FixtureFile -Repository $one -Path 'a.ps1' -Text (Get-PsInfoText -Guid $shared)
        Write-FixtureFile -Repository $two -Path 'b.ps1' -Text (Get-PsInfoText -Guid $shared)
        Save-FixtureCommit -Repository $one
        Save-FixtureCommit -Repository $two
        $run = Invoke-MetadataGate -Argument @('-All', '-Detail', '-Root', "$one,$two", '-ExemptionsPath', $script:NoExemption)
        Assert-True (Test-Flagged -Output $run.Output -Path 'a.ps1' -Rule 'guid' -Label 'GAP') $run.Output
        Assert-True (Test-Flagged -Output $run.Output -Path 'b.ps1' -Rule 'guid' -Label 'GAP') $run.Output
        Assert-Match -Pattern 'also declared by yuruna-project/b\.ps1' -Actual $run.Output
    }

    It 'reports synchronized copies whose GUIDs have drifted apart' {
        $r = New-FixtureRepository -Name 'drift'
        Write-FixtureFile -Repository $r -Path 'a/Copy.psm1' -Text (Get-PsInfoText)
        Write-FixtureFile -Repository $r -Path 'b/Copy.psm1' -Text (Get-PsInfoText)
        Save-FixtureCommit -Repository $r
        $exemption = Write-Exemption -Name 'drift' -Body @{
            synchronizedCopies = @(@{ repo = 'yuruna'; syncTool = 'tools/Sync.ps1'; files = @('a/Copy.psm1', 'b/Copy.psm1'); reason = 'Fixture.' })
        }
        $run = Invoke-MetadataGate -Argument @('-All', '-Detail', '-Root', $r, '-ExemptionsPath', $exemption)
        Assert-Match -Pattern 'tools/Sync\.ps1 declare 2 different GUIDs' -Actual $run.Output
    }
}

Describe 'arguments' {
    BeforeAll {
        $script:ArgumentRepo = New-FixtureRepository -Name 'arguments'
    }

    It 'wants exactly one of -Staged and -All' {
        $none = Invoke-MetadataGate -Argument @('-Root', $script:ArgumentRepo, '-ExemptionsPath', $script:NoExemption)
        Assert-Equal -Expected 2 -Actual $none.Code -Because $none.Output
        Assert-Match -Pattern 'exactly one of -Staged or -All' -Actual $none.Output
        $both = Invoke-MetadataGate -Argument @('-Staged', '-All', '-Root', $script:ArgumentRepo, '-ExemptionsPath', $script:NoExemption)
        Assert-Equal -Expected 2 -Actual $both.Code -Because $both.Output
    }

    It 'checks one repository when staging' {
        $run = Invoke-MetadataGate -Argument @('-Staged', '-Root', "$script:ArgumentRepo,$script:ArgumentRepo", '-ExemptionsPath', $script:NoExemption)
        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
    }

    It 'cannot judge a folder that is not a git repository' {
        $plain = Join-Path $TestDrive 'not-a-repository'
        [void][IO.Directory]::CreateDirectory($plain)
        $run = Invoke-MetadataGate -Argument @('-All', '-Root', $plain, '-ExemptionsPath', $script:NoExemption)
        Assert-Equal -Expected 2 -Actual $run.Code -Because $run.Output
        Assert-Match -Pattern 'is not a git repository' -Actual $run.Output
    }
}

Describe 'this repository' {
    BeforeAll {
        $script:ShippedRun = Invoke-MetadataGate -Argument @('-All', '-Detail', '-Root', $script:RepoRoot, '-RepoName', 'yuruna')
    }

    It 'loads the shipped exemptions file and finishes the whole-tree report' {
        Assert-Equal -Expected 0 -Actual $script:ShippedRun.Code -Because $script:ShippedRun.Output
        Assert-Match -Pattern 'Test-SourceMetadata \[all\]' -Actual $script:ShippedRun.Output
    }

    It 'has no pointer-less copyright, bad GUID, missing PSScriptInfo block, unnamed generator or stale exemption' {
        $found = @([regex]::Matches($script:ShippedRun.Output, '(?m)^GAP\s+(\S+)\s+\[(license-pointer|guid|psscriptinfo|generated-banner|exemption)\]') |
                ForEach-Object { "$($_.Groups[1].Value) [$($_.Groups[2].Value)]" })
        Assert-Equal -Expected 0 -Actual $found.Count -Because "fix these or declare them in tools/source-metadata.exemptions.json: $($found -join ', ')"
    }
}
