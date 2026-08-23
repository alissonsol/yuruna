<#PSScriptInfo
.VERSION 2026.08.19
.GUID 421ce51f-cd50-4db0-a15a-54de5b80a7ab
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test image new-vm preamble
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
    Every New-VM.ps1 reaches its base image through one shared gate, and that
    gate behaves the way the guests assume it does.
.DESCRIPTION
    Each guest needs its base artifact on disk before it touches the
    hypervisor, and each one used to carry its own copy of the fetch-and-
    recheck logic. Copies drift: the same block existed in seven spellings
    across the guests, three of which tested for the file in ways that differ
    on paths containing glob characters, and one of which reported an IPSW as
    a missing "base image".

    Two rules keep that from regrowing. A guest must not run Get-Image.ps1
    itself -- that is what makes the shared gate the only fetch path -- and a
    guest that calls the gate must import the module defining it, because a
    missing import fails at VM-creation time on a host that may be the only
    one exercising that guest.

    The behavior tests pin what the call sites depend on: a plain $true or
    $false, never a collection. The gate writes operator progress to the
    information stream for exactly this reason -- text written to the success
    stream would be collected into the return value, and a negation against a
    populated array does not mean what the call sites read it to mean.
#>

BeforeAll {
    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)

    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $repoRoot 'host/modules/Yuruna.Image.psm1') -Force

    $script:RepoRoot = $repoRoot
    $script:NewVmScripts = @(
        Get-ChildItem -Path (Join-Path $repoRoot 'host') -Recurse -Filter 'New-VM.ps1' |
            Sort-Object FullName)

    function Get-NewVmAst {
        param([string]$Path)
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errors)
        if ($errors) { throw "$Path does not parse: $($errors[0].Message)" }
        $ast
    }

    $script:TempRoot = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-baseimage-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
    $script:GuestDir = Join-Path $script:TempRoot 'guest'
    New-Item -ItemType Directory -Path $script:GuestDir -Force | Out-Null
}

AfterAll {
    if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'the base-image gate is the only fetch path' {
    It 'finds the guest New-VM.ps1 set' {
        Assert-True ($script:NewVmScripts.Count -ge 20)             "expected the full guest set, found $($script:NewVmScripts.Count)"
    }

    It 'runs Get-Image.ps1 from no guest directly' {
        $offenders = [Collections.Generic.List[string]]::new()
        foreach ($s in $script:NewVmScripts) {
            $ast = Get-NewVmAst -Path $s.FullName
            foreach ($a in $ast.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                        $n.Left.Extent.Text -match '^\$getImageScript$'
                    }, $true)) {
                $rel = $s.FullName.Substring($script:RepoRoot.Length + 1)
                $offenders.Add("${rel}:$($a.Extent.StartLineNumber)")
            }
        }
        Assert-True ($offenders.Count -eq 0) @"
these guests resolve Get-Image.ps1 themselves instead of calling
Assert-YurunaBaseImage, so their fetch behavior can drift from every
other guest:
$($offenders -join "`n")
"@
    }

    It 'imports Yuruna.Image.psm1 in every guest that calls the gate' {
        $missing = [Collections.Generic.List[string]]::new()
        foreach ($s in $script:NewVmScripts) {
            $ast = Get-NewVmAst -Path $s.FullName
            $calls = @($ast.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] -and
                        $n.GetCommandName() -eq 'Assert-YurunaBaseImage'
                    }, $true))
            if ($calls.Count -eq 0) { continue }
            $imports = @($ast.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] -and
                        $n.GetCommandName() -eq 'Import-Module' -and
                        $n.Extent.Text -like '*Yuruna.Image.psm1*'
                    }, $true))
            if ($imports.Count -eq 0) {
                $missing.Add($s.FullName.Substring($script:RepoRoot.Length + 1))
            }
        }
        Assert-True ($missing.Count -eq 0) @"
these guests call Assert-YurunaBaseImage without importing the module that
defines it, which fails only when that guest is actually built:
$($missing -join "`n")
"@
    }

    It 'exports the gate from Yuruna.Image.psm1' {
        Assert-NotNull (Get-Command -Name 'Assert-YurunaBaseImage' -ErrorAction SilentlyContinue)             'Assert-YurunaBaseImage is not exported from host/modules/Yuruna.Image.psm1'
    }
}

Describe 'the gate returns what its call sites read' {
    BeforeAll {
        $script:Present = Join-Path $script:TempRoot 'present.qcow2'
        Set-Content -LiteralPath $script:Present -Value 'image'
    }

    It 'returns a plain boolean, never a collection' {
        $r = Assert-YurunaBaseImage -BaseImageFile $script:Present -GuestFolder $script:GuestDir
        Assert-StringEqual 'Boolean' $r.GetType().Name 'progress text leaked into the success stream'
        Assert-True (@($r).Count -eq 1) 'the gate returned more than one object'
    }

    It 'accepts an artifact that is already present' {
        Assert-True (Assert-YurunaBaseImage -BaseImageFile $script:Present -GuestFolder $script:GuestDir)
    }

    It 'rejects a missing artifact when the guest has no Get-Image.ps1' {
        $r = Assert-YurunaBaseImage -BaseImageFile (Join-Path $script:TempRoot 'absent.qcow2')                 -GuestFolder $script:GuestDir -ErrorAction SilentlyContinue
        Assert-False $r
    }

    It 'accepts an artifact that Get-Image.ps1 produces' {
        $made = Join-Path $script:TempRoot 'fetched.qcow2'
        Set-Content -LiteralPath (Join-Path $script:GuestDir 'Get-Image.ps1')             -Value "Set-Content -LiteralPath '$made' -Value 'fetched'"
        try {
            Assert-True (Assert-YurunaBaseImage -BaseImageFile $made -GuestFolder $script:GuestDir)
        } finally {
            Remove-Item -LiteralPath (Join-Path $script:GuestDir 'Get-Image.ps1') -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects when Get-Image.ps1 exits non-zero' {
        Set-Content -LiteralPath (Join-Path $script:GuestDir 'Get-Image.ps1') -Value 'exit 3'
        try {
            $r = Assert-YurunaBaseImage -BaseImageFile (Join-Path $script:TempRoot 'never.qcow2')                     -GuestFolder $script:GuestDir -ErrorAction SilentlyContinue
            Assert-False $r
        } finally {
            Remove-Item -LiteralPath (Join-Path $script:GuestDir 'Get-Image.ps1') -Force -ErrorAction SilentlyContinue
        }
    }

    It 'rejects when any one of several artifacts is missing' {
        $r = Assert-YurunaBaseImage                 -BaseImageFile @($script:Present, (Join-Path $script:TempRoot 'gone.iso'))                 -GuestFolder $script:GuestDir -ErrorAction SilentlyContinue
        Assert-False $r 'a guest needing several artifacts must not proceed on a partial set'
    }
}
