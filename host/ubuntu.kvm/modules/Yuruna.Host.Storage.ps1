<#PSScriptInfo
.VERSION 2026.10.30
.GUID 42d2b83f-8a58-4d6d-9a83-a7a7ff4e90fd
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host ubuntu.kvm driver storage rename
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

# --- REGION: Storage references
function Get-KvmDomainDiskSource {
    <#
    .SYNOPSIS
        The file sources of a domain's disks and CD-ROMs, from its definition.
    .DESCRIPTION
        Bounded, and THROWS when libvirt gives no complete answer: a caller that
        read an unanswered query as "no disks" would delete storage a defined
        domain still uses.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$VMName)
    $result = Invoke-VirshBounded -VirshArgs @('domblklist', '--details', $VMName) -TimeoutSeconds $script:VirshQueryTimeoutSeconds
    if (-not (Test-DriverNativeResultComplete -Result $result) -or $result.ExitCode -ne 0) {
        throw (Format-YurunaOperatorMessage -Key 'host.vm_storage_reference_unknown' -Arguments @{ vmDir = "$VMName"; message = "$($result.StdErr)".Trim() })
    }
    $sources = foreach ($line in ("$($result.StdOut)" -split "`r?`n")) {
        $cols = $line.Trim() -split '\s+', 4
        if ($cols.Count -lt 4 -or $cols[0] -cne 'file' -or $cols[3] -eq '-') { continue }
        $cols[3]
    }
    return [string[]]@($sources)
}

function Get-KvmDirectoryDiskOwner {
    <#
    .SYNOPSIS
        The defined domains that use a file under a directory, as
        @{ VMName; Path } rows. THROWS when the inventory cannot be read.
    #>
    [CmdletBinding()]
    [OutputType([hashtable[]])]
    param([Parameter(Mandatory)][string]$Directory)
    $root = [System.IO.Path]::GetFullPath($Directory).TrimEnd('/') + '/'
    $owners = foreach ($domain in @(Get-VMName)) {
        if (-not $domain) { continue }
        foreach ($source in @(Get-KvmDomainDiskSource -VMName $domain)) {
            if ([System.IO.Path]::GetFullPath($source).StartsWith($root, [System.StringComparison]::Ordinal)) { @{ VMName = $domain; Path = $source } }
        }
    }
    return [hashtable[]]@($owners)
}

function Repair-KvmVMStorageLocation {
    <#
    .SYNOPSIS
        Finish an interrupted rename for a domain whose disks still live under
        another name's directory. $true when the domain's storage is under its
        own name afterwards (or already was).
    .DESCRIPTION
        The state to resume is read from libvirt, not from a journal: a disk
        source under <vms>/<old>/ names the rename that did not finish, and
        Complete-KvmDomainRename is the step it did not reach. Refused while the
        domain runs, and while the old directory also holds another domain's
        disks, because then it is not this rename's to move.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$VMName)
    $vmsRoot = [System.IO.Path]::GetFullPath($script:VmRootDir).TrimEnd('/') + '/'
    $foreign = $null
    foreach ($source in @(Get-KvmDomainDiskSource -VMName $VMName)) {
        $full = [System.IO.Path]::GetFullPath($source)
        if (-not $full.StartsWith($vmsRoot, [System.StringComparison]::Ordinal)) { continue }
        $leaf = $full.Substring($vmsRoot.Length).Split('/')[0]
        if ($leaf -and $leaf -cne $VMName) { $foreign = $leaf; break }
    }
    if (-not $foreign) { return $true }
    if (-not $PSCmdlet.ShouldProcess($VMName, (Format-YurunaOperatorMessage -Key 'host.vm_storage_relocate_action' -Arguments @{ fromName = "$foreign" }))) { return $false }
    $state = Get-KvmDomainState -VMName $VMName -TimeoutSeconds $script:VirshQueryTimeoutSeconds
    if ($state.Raw -ne 'shut off') {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.vm_storage_relocation_failed' -Arguments @{ vMName = "$VMName"; fromName = "$foreign"; reason = "domain state '$($state.Raw)'" })
        return $false
    }
    $others = @(Get-KvmDirectoryDiskOwner -Directory (Join-Path $script:VmRootDir $foreign) | Where-Object { $_.VMName -cne $VMName })
    if ($others.Count -gt 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.vm_storage_relocation_failed' -Arguments @{ vMName = "$VMName"; fromName = "$foreign"; reason = "also used by $(@($others | ForEach-Object { $_.VMName } | Select-Object -Unique) -join ', ')" })
        return $false
    }
    if (-not (Complete-KvmDomainRename -VMName $foreign -NewName $VMName -Confirm:$false)) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.vm_storage_relocation_failed' -Arguments @{ vMName = "$VMName"; fromName = "$foreign"; reason = 'the storage move did not complete' })
        return $false
    }
    Write-Information (Format-YurunaOperatorMessage -Key 'host.vm_storage_relocated' -Arguments @{ vMName = "$VMName"; fromName = "$foreign" }) -InformationAction Continue
    return $true
}

function Test-KvmDirectoryFreeToDelete {
    <#
    .SYNOPSIS
        $true when no defined domain uses a file under a VM directory, after
        finishing any interrupted rename that left one there.
    .DESCRIPTION
        A directory named after a VM that no longer exists is not proof that its
        disks are abandoned: a snapshot promotion interrupted between domrename
        and the storage move leaves the promoted domain's disks under the old
        name. Those domains are repaired first; anything still referenced, or a
        reference check that cannot be answered, keeps the directory.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Directory)
    try {
        $owners = @(Get-KvmDirectoryDiskOwner -Directory $Directory)
        foreach ($owner in @($owners | ForEach-Object { $_.VMName } | Select-Object -Unique)) {
            $null = Repair-KvmVMStorageLocation -VMName $owner -Confirm:$false
        }
        if ($owners.Count -gt 0) { $owners = @(Get-KvmDirectoryDiskOwner -Directory $Directory) }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.vm_storage_reference_unknown' -Arguments @{ vmDir = "$Directory"; message = "$($_.Exception.Message)" })
        return $false
    }
    if ($owners.Count -gt 0) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.vm_storage_delete_refused' -Arguments @{ vmDir = "$Directory"; owners = "$(@($owners | ForEach-Object { $_.VMName } | Select-Object -Unique) -join ', ')" })
        return $false
    }
    return $true
}

# --- REGION: Repair-VMStorageLocation
function Repair-VMStorageLocation {
    <#
    .SYNOPSIS
        Finish every rename an interrupted snapshot promotion left half done,
        before a sweep, a build or a delete reaches the directory it vacated.
    .DESCRIPTION
        Repair-KvmVMStorageLocation for each defined domain, so the repair no
        longer waits for a delete to reach the old directory. The state comes
        from libvirt, as for one domain: a disk under another name's directory
        names the rename that did not finish. A domain that cannot be repaired
        now (it runs, its old directory is shared, or its disks cannot be read)
        keeps its storage, is warned about and named in the result, and the
        next call tries again. THROWS when the domain list cannot be read.
    .OUTPUTS
        [string[]] the domains whose storage is still under another name.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string[]])]
    param()
    if (-not $PSCmdlet.ShouldProcess($script:VmRootDir, (Format-YurunaOperatorMessage -Key 'host.vm_storage_reconcile_action'))) { return [string[]]@() }
    $unrepaired = foreach ($domain in @(Get-VMName)) {
        if (-not $domain) { continue }
        try {
            if (-not (Repair-KvmVMStorageLocation -VMName $domain -Confirm:$false)) { $domain }
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.vm_storage_repair_unknown' -Arguments @{ vMName = "$domain"; message = "$($_.Exception.Message)" })
            $domain
        }
    }
    return [string[]]@($unrepaired)
}

# --- REGION: Complete-KvmDomainRename
function Complete-KvmDomainRename {
    <#
    .SYNOPSIS
        Move a renamed domain's storage to its new name: the per-VM directory,
        the files named after the old name, and the disk paths and NIC address in
        its definition.
    .DESCRIPTION
        virsh domrename changes only <name>; everything that still carries the
        old name follows here, and every step can be run again: a directory
        already moved is not moved twice, a file already renamed is skipped, and
        the definition is rewritten only while it still names the old directory.
        Rename-VM runs it right after domrename, and Repair-KvmVMStorageLocation
        runs it for a domain an interrupted rename left with its disks under the
        old name, which is the state Remove-VM and the orphan sweep would
        otherwise read as an abandoned directory and delete.
    .PARAMETER VMName
        The name being vacated.
    .PARAMETER NewName
        The domain's current name.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$NewName
    )
    if (-not $PSCmdlet.ShouldProcess($NewName, (Format-YurunaOperatorMessage -Key 'host.operator_e9e1683d4b60f469' -Arguments @{ newName = "$NewName" }))) { return $false }
    # Move the per-VM artifact dir. The qcow2 and seed.iso inside still
    # carry the old basename; rename them too so the on-disk layout is
    # self-consistent (handy when an operator goes looking with `ls`).
    $oldDir = Join-Path $script:VmRootDir $VMName
    $newDir = Join-Path $script:VmRootDir $NewName
    if (Test-Path -LiteralPath $oldDir) {
        # A directory under the destination name means an earlier attempt got
        # further than this one thinks; merging into it could overwrite disks.
        if (Test-Path -LiteralPath $newDir) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.kvm_rename_destination_dir_exists' -Arguments @{ newName = "$NewName"; newDir = "$newDir" })
            return $false
        }
        try {
            Rename-Item -LiteralPath $oldDir -NewName $NewName -ErrorAction Stop
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_69d94670b398f46b' -Arguments @{ newName = "$NewName"; oldDir = "$oldDir"; newDir = "$newDir"; message = "$($_.Exception.Message)" })
            return $false
        }
    }
    if (Test-Path -LiteralPath $newDir) {
        # A file already carrying the new name is skipped, so a second run does
        # not rename it again when the new name extends the old one.
        $extendsOldName = $NewName.StartsWith($VMName, [System.StringComparison]::Ordinal)
        foreach ($f in (Get-ChildItem -LiteralPath $newDir -File -ErrorAction SilentlyContinue)) {
            $alreadyRenamed = $extendsOldName -and $f.Name.StartsWith($NewName, [System.StringComparison]::Ordinal)
            if ($f.Name.StartsWith($VMName, [System.StringComparison]::Ordinal) -and -not $alreadyRenamed) {
                $renamed = $NewName + $f.Name.Substring($VMName.Length)
                try { Rename-Item -LiteralPath $f.FullName -NewName $renamed -ErrorAction Stop }
                catch { Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_7f8fa391d73801ba' -Arguments @{ fullName = "$($f.FullName)"; renamed = "$renamed"; message = "$($_.Exception.Message)" }) }
            }
        }
    }
    # Rewrite XML disk paths. virsh domrename only touches <name>; disk
    # sources still point at the old dir + old basename. dumpxml ->
    # sed-replace -> define is the idiomatic libvirt way; we keep the
    # destination scope narrow by only replacing $oldDir occurrences.
    $xml = Invoke-Virsh -VirshArgs @('dumpxml', $NewName)
    if ($LASTEXITCODE -eq 0 -and $xml) {
        $xmlText = ($xml -join "`n")
        # Replace path AND the leaf basename when it was derived from $VMName.
        # A plain Replace rather than a regex, because names carry regex
        # metacharacters ('.' in 'ubuntu.server.24').
        # Anchored on the separator, and the basename only inside the moved
        # directory: a bare $oldDir is also a prefix of $newDir whenever the
        # new name extends the old one, and a second run would then rewrite
        # paths that are already right.
        $newXmlText = $xmlText.Replace("$oldDir/$VMName.", "$newDir/$NewName.").Replace("$oldDir/", "$newDir/")
        # See https://yuruna.link/42e220c4-0004
        $renameMacBefore = Get-GuestMacFromDomainXml -DomainXml $newXmlText
        $renameMac = Resolve-YurunaRenameMac -MacAddress $renameMacBefore -VMName $VMName -NewName $NewName
        if ($renameMac) {
            $newXmlText = Set-GuestMacInDomainXml -DomainXml $newXmlText -VMName $NewName -MacAddress $renameMac
        }
        if ($newXmlText -ne $xmlText) {
            $tmpXml = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-rename-{0}.xml" -f [Guid]::NewGuid())
            try {
                Set-Content -LiteralPath $tmpXml -Value $newXmlText -Encoding utf8 -NoNewline -Force
                Invoke-Virsh -VirshArgs @('define', $tmpXml) 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_0da8dccbc6a8c66f')
                    return $false
                }
            } finally {
                Remove-Item -LiteralPath $tmpXml -Force -ErrorAction SilentlyContinue
            }
        }
        Register-YurunaRenameMac -VMName $VMName -NewName $NewName -Before $renameMacBefore -After $(if ($renameMac) { $renameMac } else { $renameMacBefore })
    }
    return $true
}
