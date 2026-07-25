<#PSScriptInfo
.VERSION 2026.07.25
.GUID 9e51c7a3-4d08-4b62-8f19-73a05c1e6284
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test kvm snapshot rename pester
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
    Guards the rename-BEFORE-snapshot ordering in the KVM driver's
    Save-VMDiskSnapshot.
.DESCRIPTION
    A libvirt snapshot embeds a COPY of the domain definition as it stood when
    the snapshot was taken -- <name> and every <disk><source file=...>. Rename-VM
    rewrites the LIVE domain XML and moves ~/yuruna/vms/<old> -> .../<Id>, but
    nothing rewrites that embedded copy. Taking the snapshot first therefore
    recorded a path the rename immediately invalidated, and the next cycle's
    loadDiskSnapshot failed with libvirt's least helpful message:

        error: Failed to revert snapshot <id>
        error: An error occurred, but the cause is unknown

    Worse, Test-VMDiskSnapshot still reported the snapshot as PRESENT, so the
    warm-path probe skipped the rebuild and went straight to the broken restore.

    Verified end to end against a live libvirt domain during development; this
    file is the cheap standing guard, because the ordering reads as arbitrary
    and is exactly the kind of thing a later tidy-up would swap back. Source
    order is asserted via the AST -- no hypervisor needed, so it runs on any
    host. Throw-based assertions so it runs under Pester 4.10.1 and 5+.
    Run: Invoke-Pester -Path test/modules/Test.KvmSnapshotOrder.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
$repo = Split-Path -Parent (Split-Path -Parent $here)

function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }

function Get-FunctionText {
    param([string]$Path, [string]$Name)
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in ${Path}: $($errs[0].Message)" }
    $fn = $ast.FindAll({
        param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
    }, $true) | Select-Object -First 1
    if (-not $fn) { throw "Function '$Name' not found in $Path." }
    return $fn.Extent.Text
}

# Extracted at FILE scope: a Describe body runs during discovery and its
# variables are discarded before any It executes, and a $null -match guard
# passes vacuously -- silently un-testing the thing.
$kvmDriver   = Join-Path $repo 'host/ubuntu.kvm/modules/Yuruna.Host.psm1'
$utmDriver   = Join-Path $repo 'host/macos.utm/modules/Yuruna.Host.psm1'
$kvmSaveText   = Get-FunctionText -Path $kvmDriver -Name 'Save-VMDiskSnapshot'
$kvmRemoveText = Get-FunctionText -Path $kvmDriver -Name 'Remove-VM'
$utmSaveText   = Get-FunctionText -Path $utmDriver -Name 'Save-VMDiskSnapshot'

Describe 'KVM Save-VMDiskSnapshot -- renames BEFORE it snapshots' {
    It 'calls Rename-VM before snapshot-create-as' {
        $renameAt   = $kvmSaveText.IndexOf('Rename-VM')
        $snapshotAt = $kvmSaveText.IndexOf('snapshot-create-as')
        Assert-True ($renameAt   -ge 0) 'the domain must still be renamed to its persistent name'
        Assert-True ($snapshotAt -ge 0) 'the snapshot must still be created'
        Assert-True ($renameAt -lt $snapshotAt) 'rename MUST precede the snapshot: a libvirt snapshot embeds the domain name + disk paths, and nothing rewrites that copy afterwards'
    }
    It 'snapshots the RENAMED domain, not the original name' {
        # Passing $VMName to snapshot-create-as after a rename would target a
        # domain that no longer exists.
        Assert-True ($kvmSaveText -match "snapshot-create-as'\s*,\s*'--domain'\s*,\s*\`$domain") 'snapshot-create-as must target the post-rename domain variable'
        Assert-True ($kvmSaveText -match "snapshot-delete'\s*,\s*\`$domain") 'the idempotent delete must target the post-rename domain too'
    }
    It 'explains why the order matters, so a later tidy-up does not swap it back' {
        $fileText = Get-Content -Raw -LiteralPath $kvmDriver
        Assert-True ($fileText -match 'ORDER IS LOAD-BEARING') 'the rationale must live next to the code'
    }
    It 'warns that a post-rename snapshot failure leaves the destination name taken' {
        # Rename-VM refuses a destination that already exists, so a half-done
        # save would block the next rebuild until the stale domain is removed.
        Assert-True ($kvmSaveText -match 'WITHOUT a snapshot') 'the failure path must tell the operator the name is now taken'
    }
}

Describe 'KVM Remove-VM -- must be able to delete a SNAPSHOTTED domain' {
    # libvirt refuses `undefine` while snapshot metadata exists:
    #   "Requested operation is not valid: cannot delete inactive domain with N snapshots"
    # Every persisted topology VM has a snapshot by construction, so without
    # --snapshots-metadata the teardown could not remove the exact VMs it exists
    # to remove. The domain survived while its qcow2 was deleted anyway, and the
    # next cycle reused that wreckage and failed the snapshot restore.
    It 'passes --snapshots-metadata so a snapshotted domain can be undefined' {
        Assert-True ($kvmRemoveText -match '--snapshots-metadata') 'a persisted VM always has a snapshot; without this flag undefine always refuses'
    }
    It 'passes --managed-save, the sibling blocker' {
        Assert-True ($kvmRemoveText -match '--managed-save') 'a managed-save image refuses undefine the same way'
    }
    It 'checks the undefine exit code instead of always reporting success' {
        # The old code returned $true unconditionally, so a surviving domain was
        # announced as removed and only surfaced later as a post-sweep survivor.
        $undefineAt = $kvmRemoveText.IndexOf('undefine')
        $checkAt    = $kvmRemoveText.IndexOf('LASTEXITCODE', $undefineAt)
        Assert-True ($undefineAt -ge 0) 'Remove-VM must still undefine the domain'
        Assert-True ($checkAt -gt $undefineAt) 'the undefine result must be checked'
        Assert-True ($kvmRemoveText -match 'return \$false') 'a failed undefine must report failure to the caller'
    }
    It 'does not delete the disk before knowing the domain is gone' {
        # Deleting the qcow2 while the domain survives leaves a registered VM
        # pointing at a missing disk -- worse than either failure alone.
        $failReturnAt = $kvmRemoveText.IndexOf('return $false')
        $removeDirAt  = $kvmRemoveText.IndexOf('Remove-Item')
        Assert-True ($failReturnAt -ge 0) 'the failure path must exist'
        Assert-True ($removeDirAt -gt $failReturnAt) 'the artifact dir must only be deleted after a successful undefine'
    }
}

Describe 'UTM Save-VMDiskSnapshot -- unaffected, and deliberately so' {
    It 'stores the snapshot INSIDE the qcow2, so a later rename cannot invalidate it' {
        # qemu-img snapshot -c writes into the disk file itself; there is no
        # external metadata recording a name or path. Renaming the bundle
        # afterwards is therefore safe, and the KVM fix must NOT be copied here.
        Assert-True ($utmSaveText -match 'qemu-img') 'UTM snapshots via qemu-img'
        Assert-True ($utmSaveText -match 'qemu-img\s+snapshot\s+-c') 'the snapshot is written into the qcow2 itself'
    }
}
