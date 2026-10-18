<#PSScriptInfo
.VERSION 2026.08.19
.GUID 42ad60ed-84b4-4a47-b987-ba4697aa06f2
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test config status-service seed new-vm
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
    Every guest seed takes the status-service port from one place, and that
    place behaves the way the seeds assume it does.
.DESCRIPTION
    A New-VM.ps1 bakes the host status-service address into its guest seed, so
    every one of them had to answer the same question: which port. Each
    answered it in its own copy of default-8080-then-read-the-config, and the
    copies drifted along four axes -- the variable holding the result, the
    variable holding the path, whether the existence test honored
    -LiteralPath, and whether the file went through Read-TestConfig or was
    parsed raw. The last one was the one with teeth: the raw readers bypassed
    the mtime-and-hash cache and re-parsed test.config.yml on every build.

    The rule here is that a guest builder does not read that config itself.
    Naming either the config path or the statusService key inside a New-VM.ps1
    means a fifth copy has started, which is how the previous ones appeared.

    The behavior tests pin what the seeds depend on. A guest that cannot read
    the config still has to build -- it boots and self-heals its host
    coordinates -- so an absent or unparseable config yields the default port
    rather than an error. And Config comes back beside Port because the
    callers that need the port usually need the document too; returning only
    the port would have left them parsing the same file again, which is the
    duplication this removes rather than a smaller version of it.
#>

BeforeAll {
    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)

    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.Config.psm1') -Force -DisableNameChecking

    $script:RepoRoot = $repoRoot
    $script:NewVmScripts = @(
        Get-ChildItem -Path (Join-Path $repoRoot 'host') -Recurse -Filter 'New-VM.ps1' |
            Sort-Object FullName)

    $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-statusseed-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path (Join-Path $script:TempRoot 'test') -Force | Out-Null
    $script:TempConfig = Join-Path $script:TempRoot 'test/test.config.yml'
}

AfterAll {
    if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'guest builders take the status-service port from one place' {
    It 'finds the guest New-VM.ps1 set' {
        Assert-True ($script:NewVmScripts.Count -ge 20) `
            "expected the full guest set, found $($script:NewVmScripts.Count)"
    }

    It 'reads test.config.yml from no guest directly' {
        $offenders = [Collections.Generic.List[string]]::new()
        foreach ($s in $script:NewVmScripts) {
            $rel = $s.FullName.Substring($script:RepoRoot.Length + 1)
            $n = 0
            foreach ($line in (Get-Content -LiteralPath $s.FullName)) {
                $n++
                if ($line -match 'Get-YurunaStatusServiceSeed') { continue }
                # '.statusService' is the config-key read; the -StatusServiceIp /
                # -StatusServicePort parameter names that pass the resolved values
                # on to the guest bootstrap are the point, not a second copy.
                if ($line -match 'test/test\.config\.yml' -or $line -match '\.statusService') {
                    $offenders.Add("${rel}:${n}  $($line.Trim())")
                }
            }
        }
        Assert-True ($offenders.Count -eq 0) @"
these guests resolve the status-service config themselves instead of calling
Get-YurunaStatusServiceSeed, so their port resolution can drift from every
other guest:
$($offenders -join "`n")
"@
    }

    It 'imports Test.Config.psm1 in every guest that calls the seed helper' {
        $missing = [Collections.Generic.List[string]]::new()
        foreach ($s in $script:NewVmScripts) {
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$null, [ref]$errors)
            if ($errors) { throw "$($s.FullName) does not parse: $($errors[0].Message)" }
            $calls = @($ast.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] -and
                        $n.GetCommandName() -eq 'Get-YurunaStatusServiceSeed'
                    }, $true))
            if ($calls.Count -eq 0) { continue }
            $imports = @($ast.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] -and
                        $n.GetCommandName() -eq 'Import-Module' -and
                        $n.Extent.Text -like '*Test.Config.psm1*'
                    }, $true))
            if ($imports.Count -eq 0) {
                $missing.Add($s.FullName.Substring($script:RepoRoot.Length + 1))
            }
        }
        Assert-True ($missing.Count -eq 0) @"
these guests call Get-YurunaStatusServiceSeed without importing the module
that defines it, which fails only when that guest is actually built:
$($missing -join "`n")
"@
    }

    It 'exports the seed helper from Test.Config.psm1' {
        Assert-NotNull (Get-Command -Name 'Get-YurunaStatusServiceSeed' -ErrorAction SilentlyContinue) `
            'Get-YurunaStatusServiceSeed is not exported from test/modules/Test.Config.psm1'
    }
}

Describe 'the seed helper answers what the guests ask it' {
    It 'takes the port from statusService.port when present' {
        Set-Content -LiteralPath $script:TempConfig -Value "statusService:`n  port: 9999`n"
        $r = Get-YurunaStatusServiceSeed -RepoRoot $script:TempRoot
        Assert-StringEqual '9999' $r.Port
    }

    It 'returns the parsed config beside the port' {
        Set-Content -LiteralPath $script:TempConfig -Value "statusService:`n  port: 9999`n"
        $r = Get-YurunaStatusServiceSeed -RepoRoot $script:TempRoot
        Assert-NotNull $r.Config 'callers needing pool storage and brand identity read this document'
    }

    It 'falls back to the default when the config omits statusService' {
        Set-Content -LiteralPath $script:TempConfig -Value "somethingElse:`n  x: 1`n"
        $r = Get-YurunaStatusServiceSeed -RepoRoot $script:TempRoot
        Assert-StringEqual '8080' $r.Port
    }

    It 'falls back to the default when the config does not parse' {
        Set-Content -LiteralPath $script:TempConfig -Value 'just: a: broken: [[['
        $r = Get-YurunaStatusServiceSeed -RepoRoot $script:TempRoot
        Assert-StringEqual '8080' $r.Port
        Assert-Null $r.Config
    }

    It 'falls back to the default when there is no config at all' {
        $bare = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-statusseed-bare-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $bare -Force | Out-Null
        try {
            $r = Get-YurunaStatusServiceSeed -RepoRoot $bare
            Assert-StringEqual '8080' $r.Port
            Assert-Null $r.Config 'a guest still builds and self-heals its host coordinates'
        } finally {
            Remove-Item -LiteralPath $bare -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'honors an explicit default port' {
        $bare = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-statusseed-bare2-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $bare -Force | Out-Null
        try {
            Assert-StringEqual '7070' (Get-YurunaStatusServiceSeed -RepoRoot $bare -DefaultPort '7070').Port
        } finally {
            Remove-Item -LiteralPath $bare -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
