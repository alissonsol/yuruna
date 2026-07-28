<#PSScriptInfo
.VERSION 2026.07.27
.GUID 42fcb367-61e9-49c5-a325-548305490c56
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test install checkout probe pester
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
    Behavioral Pester guard on the Windows installer's checkout-movable probe:
    it must never damage the checkout it is probing, and must never abort the
    install on its own.
.DESCRIPTION
    The probe renames the checkout to a '<dir>.locktest' sibling and back to
    learn early whether a re-clone could move it aside. Three properties are
    load-bearing and are asserted here against the real function bodies lifted
    out of install/windows.hyper-v.ps1:

      * the rename stays a rename. Move-Item degrades a failed directory rename
        into a recursive copy-then-delete, which half-moves a held-open checkout
        (.git included) into the probe name and deletes the originals it copied.
      * the process working directory is stepped out of the tree, not just the
        PowerShell location -- an open handle on the process's own current
        directory pins every parent of it against rename, so an installer
        launched from inside the checkout otherwise blocks its own update.
      * a checkout something else holds open warns and continues. Only a
        non-ff re-clone needs the rename; a plain pull does not.

    Recovery from a probe an interrupted run left behind is covered in both
    shapes: the whole tree under the probe name, and the tree split across both
    names. Throw-based assertions so the file runs under the OS-bundled
    Pester 3.4 and Pester 5+.
    Run: Invoke-Pester -Path test/modules/Test.InstallCheckoutProbe.Tests.ps1
#>

$here      = Split-Path -Parent $PSCommandPath
$repoRoot  = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
$installer = Join-Path $repoRoot 'install/windows.hyper-v.ps1'

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-False { param($Condition, [string]$Because='') if ($Condition) { throw "Expected false. $Because" } }

function Get-InstallerAst {
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Language.ScriptBlockAst])]
    param([Parameter(Mandatory)][string]$Path)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in ${Path}: $($errs[0].Message)" }
    return $ast
}

# The installer is a top-to-bottom script that elevates, installs packages and
# rewrites the checkout -- it cannot be dot-sourced. Lift the functions under
# test out of its AST and define them here, so these tests exercise the shipped
# bodies rather than a copy that can drift.
function Import-InstallerFunction {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$RootAst,
        [Parameter(Mandatory)][string[]]$Name
    )
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($n in $Name) {
        $fn = $RootAst.FindAll({
            param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true) | Where-Object { $_.Name -eq $n } | Select-Object -First 1
        if (-not $fn) { throw "Function '$n' not found in the installer." }
        $parts.Add($fn.Extent.Text)
    }
    return ($parts -join "`n")
}

$installerAst = Get-InstallerAst -Path $installer
$probeSource  = Import-InstallerFunction -RootAst $installerAst -Name @(
    'Move-YurunaDirectory', 'Test-YurunaPathInside',
    'Restore-YurunaCheckoutFromProbe', 'Assert-YurunaCheckoutMovable')
. ([scriptblock]::Create($probeSource))

# Output stubs. Write-Die is the installer's fatal exit (Write-Error under
# $ErrorActionPreference='Stop'), so it throws here; every message is captured
# so a test can assert on what the operator was told.
$script:Said = New-Object System.Collections.Generic.List[string]
function Write-Step { param([string]$m) $script:Said.Add("STEP $m") }
function Write-Warn { param([string]$m) $script:Said.Add("WARN $m") }
function Write-Die  { param([string]$m) $script:Said.Add("DIE $m"); throw $m }
function Test-SaidMatch {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Pattern)
    return (@($script:Said | Where-Object { $_ -match $Pattern }).Count -gt 0)
}

# A standalone run executes this file body twice (discovery, then run), so the
# trees are built per-It rather than at file scope. $PID keeps the root stable
# across the two passes.
$probeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "yuruna-checkoutprobe-tests-$PID"

function New-CheckoutFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture writer; touches only a temp dir removed in AfterEach.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Name)
    $dir = Join-Path $probeRoot $Name
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    $null = New-Item -ItemType Directory -Path (Join-Path $dir '.git/objects') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $dir 'install') -Force
    Set-Content -LiteralPath (Join-Path $dir '.git/HEAD')  -Value 'ref: refs/heads/main'
    Set-Content -LiteralPath (Join-Path $dir '.git/objects/pack.idx') -Value 'objects'
    Set-Content -LiteralPath (Join-Path $dir 'VERSION')    -Value '2026.07.27'
    Set-Content -LiteralPath (Join-Path $dir 'README.md')  -Value 'readme'
    Set-Content -LiteralPath (Join-Path $dir 'install/windows.hyper-v.ps1') -Value 'installer'
    return $dir
}

function Get-RelativeFileList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$Dir)
    $prefix = $Dir.TrimEnd('\').Length
    return [string[]]@(Get-ChildItem -LiteralPath $Dir -Recurse -Force -File |
        ForEach-Object { $_.FullName.Substring($prefix).TrimStart('\') } | Sort-Object)
}

Describe 'install checkout probe -- the probe never damages the checkout' {

    BeforeEach {
        $script:Said.Clear()
        $null = New-Item -ItemType Directory -Path $probeRoot -Force
    }

    AfterEach {
        Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'renames a directory to its sibling probe name and back' {
        $dir   = New-CheckoutFixture -Name 'plain'
        $probe = "$dir.locktest"
        Assert-True (Move-YurunaDirectory -From $dir -To $probe) 'the rename must report success'
        Assert-True  (Test-Path -LiteralPath $probe) 'the probe name must exist after the rename'
        Assert-False (Test-Path -LiteralPath $dir)   'the original name must be gone after the rename'
        $null = Move-YurunaDirectory -From $probe -To $dir
        Assert-True  (Test-Path -LiteralPath $dir)   'the rename back must restore the original name'
    }

    It 'never degrades into a copy: a held-open tree fails with BOTH paths untouched' {
        $dir    = New-CheckoutFixture -Name 'held'
        $probe  = "$dir.locktest"
        $before = Get-RelativeFileList -Dir $dir
        # FileShare.None on a file inside the tree is what an editor or a
        # running process holding the checkout looks like: the directory can no
        # longer be renamed.
        $held = [System.IO.File]::Open((Join-Path $dir '.git/objects/pack.idx'), 'Open', 'ReadWrite', 'None')
        try {
            $threw = $false
            try { $null = Move-YurunaDirectory -From $dir -To $probe } catch { $threw = $true }
            Assert-True  $threw 'moving a held-open directory must fail'
            Assert-False (Test-Path -LiteralPath $probe) 'a failed move must not create the destination -- a partial copy there is a destroyed checkout'
            Assert-Equal -Expected ($before -join '|') -Actual ((Get-RelativeFileList -Dir $dir) -join '|') `
                -Because 'a failed move must leave every file where it was'
        } finally {
            $held.Dispose()
        }
    }

    It 'steps the process working directory out of the tree, not just the PowerShell location' {
        $dir = New-CheckoutFixture -Name 'selflock'
        $savedOsCwd = [System.Environment]::CurrentDirectory
        try {
            # Exactly how the installer is launched: from inside the checkout.
            # Set-Location alone would leave this handle open and the probe
            # would report the operator's own installer as the blocker.
            [System.IO.Directory]::SetCurrentDirectory((Join-Path $dir 'install'))
            Assert-YurunaCheckoutMovable -Dir $dir
            Assert-False (Test-YurunaPathInside -Path ([System.IO.Path]::GetFullPath([System.Environment]::CurrentDirectory).TrimEnd('\')) -Root $dir) 'the process working directory must be outside the checkout'
            Assert-False (Test-SaidMatch -Pattern 'cannot be renamed') 'a self-inflicted lock must not be reported as a blocked checkout'
            Assert-False (Test-Path -LiteralPath "$dir.locktest") 'a passing probe must leave no probe directory behind'
            Assert-True  (Test-Path -LiteralPath (Join-Path $dir '.git/HEAD')) 'the checkout must be intact after a passing probe'
        } finally {
            [System.IO.Directory]::SetCurrentDirectory($savedOsCwd)
        }
    }

    It 'warns and continues when something else holds the checkout open' {
        $dir    = New-CheckoutFixture -Name 'blocked'
        $before = Get-RelativeFileList -Dir $dir
        $held = [System.IO.File]::Open((Join-Path $dir '.git/objects/pack.idx'), 'Open', 'ReadWrite', 'None')
        try {
            Assert-YurunaCheckoutMovable -Dir $dir   # must not throw
            Assert-True  (Test-SaidMatch -Pattern 'cannot be renamed') 'the operator must be told the checkout is held open'
            Assert-False (Test-SaidMatch -Pattern '^DIE ') 'a held-open checkout must not abort the install -- a git pull update does not need the rename'
            Assert-False (Test-Path -LiteralPath "$dir.locktest") 'a failed probe must move nothing'
            Assert-Equal -Expected ($before -join '|') -Actual ((Get-RelativeFileList -Dir $dir) -join '|') `
                -Because 'a failed probe must leave every file where it was'
        } finally {
            $held.Dispose()
        }
    }
}

Describe 'install checkout probe -- recovering a probe an interrupted run left behind' {

    BeforeEach {
        $script:Said.Clear()
        $null = New-Item -ItemType Directory -Path $probeRoot -Force
    }

    AfterEach {
        Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'renames the whole tree back when only the probe name exists' {
        $dir   = New-CheckoutFixture -Name 'stranded'
        $probe = "$dir.locktest"
        $files = Get-RelativeFileList -Dir $dir
        [System.IO.Directory]::Move($dir, $probe)

        Assert-YurunaCheckoutMovable -Dir $dir

        Assert-False (Test-Path -LiteralPath $probe) 'the probe name must be gone once the checkout is back'
        Assert-Equal -Expected ($files -join '|') -Actual ((Get-RelativeFileList -Dir $dir) -join '|') `
            -Because 'every file must come back'
    }

    It 'merges a split tree back and removes the probe' {
        $dir   = New-CheckoutFixture -Name 'split'
        $probe = "$dir.locktest"
        $files = Get-RelativeFileList -Dir $dir
        # The shape a copy-then-delete move leaves: .git and the root files
        # under the probe name, the rest still under the checkout name.
        $null = New-Item -ItemType Directory -Path $probe -Force
        foreach ($rel in @('.git', 'VERSION', 'README.md')) {
            Move-Item -LiteralPath (Join-Path $dir $rel) -Destination (Join-Path $probe $rel) -Force
        }
        Assert-False (Test-Path -LiteralPath (Join-Path $dir '.git')) 'fixture check: .git must start out on the probe side'

        Assert-YurunaCheckoutMovable -Dir $dir

        Assert-False (Test-Path -LiteralPath $probe) 'the probe must be removed once its contents are merged back'
        Assert-Equal -Expected ($files -join '|') -Actual ((Get-RelativeFileList -Dir $dir) -join '|') `
            -Because 'the merged checkout must hold every file from both sides'
        Assert-True  (Test-SaidMatch -Pattern 'merging it back') 'the merge must be announced'
    }

    It 'keeps identical content when a file exists on both sides' {
        $dir   = New-CheckoutFixture -Name 'overlap'
        $probe = "$dir.locktest"
        $files = Get-RelativeFileList -Dir $dir
        $null  = New-Item -ItemType Directory -Path $probe -Force
        # A file whose copy succeeded and whose delete did not lands on both
        # sides; the two are byte-identical, so overwriting is safe.
        Copy-Item -LiteralPath (Join-Path $dir 'VERSION') -Destination (Join-Path $probe 'VERSION')

        Assert-YurunaCheckoutMovable -Dir $dir

        Assert-False (Test-Path -LiteralPath $probe) 'the probe must be removed after the merge'
        Assert-Equal -Expected ($files -join '|') -Actual ((Get-RelativeFileList -Dir $dir) -join '|') `
            -Because 'no file may be lost or added by the merge'
        Assert-Equal -Expected '2026.07.27' -Actual (Get-Content -LiteralPath (Join-Path $dir 'VERSION') -Raw).Trim() `
            -Because 'the surviving copy must keep its content'
    }
}

Describe 'install checkout probe -- the installer moves directories by rename only' {

    It 'calls no Move-Item anywhere: it silently copies-then-deletes on failure' {
        $calls = $installerAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Move-Item'
        }, $true)
        Assert-Equal -Expected 0 -Actual (@($calls).Count) `
            -Because 'every directory move must go through Move-YurunaDirectory ([System.IO.Directory]::Move), which cannot half-move a tree'
    }

    It 'routes the re-clone move-aside through the same rename helper' {
        $hits = $installerAst.FindAll({
            param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Move-YurunaDirectory'
        }, $true)
        Assert-True (@($hits).Count -ge 2) 'the probe and the backup-and-reclone move must both use the helper'
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
