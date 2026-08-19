<#PSScriptInfo
.VERSION 2026.08.19
.GUID 42d14c70-0d75-4092-84e4-29debef3a34b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host storage facts
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
    The machine's own hardware facts, in the shape /control/host-facts serves
    them. Storage lives here: it is the one fact no single API answers.

.DESCRIPTION
    "How much disk does this machine have" has two traps, and both inflate the
    answer:

      * ONE POOL, MANY MOUNTS. An APFS container publishes every volume it
        holds, and each volume reports the container's full size and the
        container's shared free space -- on macOS the boot volume, Data,
        Preboot, Update and VM are five mount points over ONE 2 TB pool. Adding
        mount points up turns that machine into a 10 TB one. Linux has the
        milder form (a bind mount, or two btrfs subvolumes, are one filesystem
        seen twice) and Windows has it when a volume spans disks.
      * STORAGE THAT IS NOT THE MACHINE'S. A USB or Thunderbolt drive, an SD
        card, a mounted disk image and a network share all mount like local
        storage. Capacity planning asks what a host has permanently -- an
        enclosure that leaves with the operator cannot be planned against, and
        a share counted on every host that mounts it is counted many times.

    So the rule, on every platform: group volumes by the space pool behind
    them, count each pool once, and sum only the pools on permanently attached
    devices.

    Where a platform cannot say whether a device is internal, the volume is
    COUNTED rather than dropped. Over-reporting an exotic disk controller is a
    smaller lie than reporting a machine with no storage at all, and the
    de-duplication -- which needs no such judgement -- still holds.

    Sizes come from [System.IO.DriveInfo] on all three platforms, so the free
    space reported is the space a filesystem would actually accept. The
    platform is asked only for what .NET does not expose: which device is
    behind a mount point, and whether that device is part of the machine.
#>

# Mount points that are the same string are the same mount; the trailing
# separator differs between .NET's view and the platform's mount table on some
# paths, and root must survive being trimmed to nothing.
function Get-MountPointKey {
    <#
    .SYNOPSIS
        Normalized mount-point string for matching a mount table against
        [System.IO.DriveInfo].
    .PARAMETER Path
        Mount point as either source spells it.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Path)
    $p = "$Path".Trim()
    if ($p.Length -gt 1) { $p = $p.TrimEnd('/', '\') }
    if ($p -eq '') { $p = '/' }
    return $p
}

function Measure-PermanentStorage {
    <#
    .SYNOPSIS
        Total and free bytes across the permanent storage pools in a list of
        volume records.

    .DESCRIPTION
        The single place the counting rule lives, so all three platform
        collectors agree on it: drop the volumes that are not permanent
        machine storage, collapse the rest by pool, and sum one figure per
        pool.

        Volumes sharing a pool report that pool's totals, so the pool's
        contribution is the largest figure seen for it rather than the sum --
        equal values collapse to one, and a stale or partially-read view
        cannot drag a pool below its real size.

        Zero-sized volumes contribute nothing and are dropped before the
        pool collapse, so a pseudo-mount that answers "0 bytes" cannot
        occupy a pool key and mask the real volume behind it.

    .PARAMETER Volume
        Volume records with Pool (the identity of the space pool behind the
        mount), TotalBytes, FreeBytes and Permanent.

    .OUTPUTS
        [pscustomobject] with TotalBytes and FreeBytes ([long] each).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([object[]]$Volume)
    $pools = @{}
    foreach ($v in $Volume) {
        if ($null -eq $v) { continue }
        if (-not $v.Permanent) { continue }
        $key = "$($v.Pool)"
        if ($key -eq '') { continue }
        $total = [long]$v.TotalBytes
        $free  = [long]$v.FreeBytes
        if ($total -le 0) { continue }
        if ($free -lt 0) { $free = [long]0 }
        if ($pools.ContainsKey($key)) {
            if ($total -gt $pools[$key].Total) { $pools[$key].Total = $total }
            if ($free  -gt $pools[$key].Free)  { $pools[$key].Free  = $free }
        } else {
            $pools[$key] = @{ Total = $total; Free = $free }
        }
    }
    $totalBytes = [long]0
    $freeBytes  = [long]0
    foreach ($pool in $pools.Values) {
        $totalBytes += [long]$pool.Total
        $freeBytes  += [long]$pool.Free
    }
    return [pscustomobject]@{ TotalBytes = $totalBytes; FreeBytes = $freeBytes }
}

function ConvertFrom-LinuxMountTable {
    <#
    .SYNOPSIS
        Parse /proc/self/mounts lines into device / mount point / filesystem.

    .DESCRIPTION
        The kernel writes mount points with the whitespace characters escaped
        in octal (a space is \040), so a mount point under a path with a space
        in it only matches [System.IO.DriveInfo]'s view after the escapes are
        undone.

        A later line for the same mount point is the mount actually reachable
        there -- an over-mount hides what it covers -- so callers keep the
        last entry per mount point.

    .PARAMETER Line
        Raw lines from /proc/self/mounts.

    .OUTPUTS
        [pscustomobject[]] with Device, MountPoint and FileSystem.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([string[]]$Line)
    $rows = @()
    foreach ($raw in $Line) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $field = $raw.Split(' ')
        if ($field.Count -lt 3) { continue }
        $unescape = {
            param($s)
            $s -replace '\\040', ' ' -replace '\\011', "`t" -replace '\\012', "`n" -replace '\\134', '\'
        }
        $rows += [pscustomobject]@{
            Device     = (& $unescape $field[0])
            MountPoint = (& $unescape $field[1])
            FileSystem = $field[2]
        }
    }
    return $rows
}

function ConvertFrom-MacMountTable {
    <#
    .SYNOPSIS
        Parse `mount` output on macOS into device / mount point / filesystem.

    .DESCRIPTION
        Shape: `<device> on <mount point> (<fs>, <option>, ...)`. The mount
        point is taken as everything between " on " and the trailing option
        list, because a volume mounted under a name with spaces in it -- the
        normal case under /Volumes -- is not a field split can find.

    .PARAMETER Line
        Raw lines from `mount`.

    .OUTPUTS
        [pscustomobject[]] with Device, MountPoint and FileSystem.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([string[]]$Line)
    $rows = @()
    foreach ($raw in $Line) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        if ($raw -notmatch '^(?<dev>.+?) on (?<mount>.+) \((?<opts>[^)]*)\)\s*$') { continue }
        $rows += [pscustomobject]@{
            Device     = $Matches['dev'].Trim()
            MountPoint = $Matches['mount'].Trim()
            FileSystem = ($Matches['opts'].Split(',')[0]).Trim()
        }
    }
    return $rows
}

function Get-MacStoragePoolKey {
    <#
    .SYNOPSIS
        The identity of the space pool behind a macOS volume device.

    .DESCRIPTION
        APFS volumes are named for the container that owns their space
        (/dev/disk3s5 and /dev/disk3s1s1 both live in container disk3), and
        every volume in a container reports that container's size and its
        shared free space. Collapsing them to the container name is what
        stops one pool from being counted once per volume.

        Any other filesystem owns its slice outright -- two HFS+ partitions on
        one disk really are two pools -- so the device itself is the identity.

    .PARAMETER Device
        Device as the mount table spells it, e.g. /dev/disk3s5.

    .PARAMETER FileSystem
        Filesystem name from the mount table, e.g. apfs.

    .OUTPUTS
        [string] Pool identity, or '' when the device is not a disk device.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Device,
        [string]$FileSystem
    )
    if ("$Device" -notmatch '^/dev/(?<whole>disk\d+)') { return '' }
    if ("$FileSystem" -eq 'apfs') { return $Matches['whole'] }
    return ("$Device" -replace '^/dev/', '')
}

function Convert-PlistNode {
    <#
    .SYNOPSIS
        One property-list element as the PowerShell value it stands for.
    .PARAMETER Node
        Element node: dict, array, string, integer, real, true or false.
    .OUTPUTS
        The value. A dict becomes a [pscustomobject] so a caller can both read
        a key and ask whether it is there at all.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject], [object[]], [long], [double], [bool], [string])]
    param([System.Xml.XmlNode]$Node)
    if ($null -eq $Node) { return $null }
    switch ($Node.Name) {
        'dict' {
            $fields = [ordered]@{}
            $key = ''
            foreach ($child in $Node.ChildNodes) {
                if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
                if ($child.Name -eq 'key') { $key = $child.InnerText; continue }
                if ($key -eq '') { continue }
                $fields[$key] = Convert-PlistNode -Node $child
                $key = ''
            }
            return [pscustomobject]$fields
        }
        'array' {
            $items = @()
            foreach ($child in $Node.ChildNodes) {
                if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
                $items += , (Convert-PlistNode -Node $child)
            }
            return , $items
        }
        'integer' { return [long]$Node.InnerText }
        'real'    { return [double]$Node.InnerText }
        'true'    { return $true }
        'false'   { return $false }
        # string, and the types with no PowerShell equivalent worth having
        # here (data, date): the text as written.
        default   { return $Node.InnerText }
    }
}

function ConvertFrom-DiskUtilPlist {
    <#
    .SYNOPSIS
        A `diskutil -plist` property list as an object.

    .DESCRIPTION
        Read in process rather than through plutil, and read as a property
        list rather than scraped from diskutil's printed output: the plist
        keys are a contract macOS keeps, while the printed labels are
        formatting that has changed between releases.

        The document declares Apple's DTD by URL. .NET does not resolve
        external DTDs, so parsing stays offline -- which matters on a host
        whose only network path is the one this harness is testing.

    .PARAMETER Text
        The property list, as diskutil wrote it.

    .OUTPUTS
        [pscustomobject] the top-level dictionary, or $null when the text is
        not a property list.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string[]]$Text)
    $joined = (@($Text) -join "`n").Trim()
    if ($joined -eq '') { return $null }
    try {
        $document = [xml]$joined
    } catch {
        Write-Debug "ConvertFrom-DiskUtilPlist: not a property list: $($_.Exception.Message)"
        return $null
    }
    $root = $document.DocumentElement
    if ($null -eq $root) { return $null }
    foreach ($child in $root.ChildNodes) {
        if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
        return (Convert-PlistNode -Node $child)
    }
    return $null
}

function Get-MacDiskInfo {
    <#
    .SYNOPSIS
        `diskutil info` for one device, as an object.

    .PARAMETER Device
        Device identifier without /dev/, e.g. disk3 or disk0s2.

    .OUTPUTS
        [pscustomobject] the description, or $null when the device cannot be
        described.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Device)
    try {
        return (ConvertFrom-DiskUtilPlist -Text (& diskutil info -plist $Device 2>$null))
    } catch {
        Write-Debug "Get-MacDiskInfo: could not describe $Device`: $($_.Exception.Message)"
        return $null
    }
}

function Test-PermanentMacDisk {
    <#
    .SYNOPSIS
        Whether a `diskutil info` record describes storage that stays with the
        machine.

    .DESCRIPTION
        Internal is the property that answers the question; RemovableMediaOr-
        ExternalDevice is checked alongside it because a device can be
        internally attached and still leave (an optical drive, a card reader
        with a card in it). A disk image is a file on some other pool, so
        counting it would count that pool twice.

        A record without Internal answers nothing rather than "no": callers
        follow the device to its physical store, and count the volume if even
        that cannot say.

    .PARAMETER Info
        Record from Get-MacDiskInfo.

    .OUTPUTS
        [bool] permanent or not, or $null when the record does not say.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param($Info)
    if ($null -eq $Info) { return $null }
    if ("$($Info.BusProtocol)" -eq 'Disk Image') { return $false }
    if ($null -eq $Info.PSObject.Properties['Internal']) { return $null }
    if (-not $Info.Internal) { return $false }
    if ($Info.RemovableMediaOrExternalDevice) { return $false }
    return $true
}

function Test-PermanentMacPool {
    <#
    .SYNOPSIS
        Whether a macOS space pool sits on permanent machine storage.

    .DESCRIPTION
        An APFS container is a synthesized device: it has no bus of its own,
        and the question is really about the physical store underneath it. So
        the container is followed to its first physical store and the verdict
        is taken there, which is also the record that carries the real bus and
        removable flags.

    .PARAMETER Pool
        Pool identity from Get-MacStoragePoolKey, e.g. disk3.

    .OUTPUTS
        [bool] permanent or not. True when macOS does not say, so a machine
        whose disks cannot be described still reports the storage it mounts.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Pool)
    $info = Get-MacDiskInfo -Device $Pool
    if ($null -eq $info) { return $true }
    $store = ''
    foreach ($entry in @($info.APFSPhysicalStores)) {
        if ($null -eq $entry) { continue }
        # Recorded as a dictionary keyed by APFSPhysicalStore; a plain string
        # is accepted too, so a shape change does not silently drop the store.
        $store = if ($entry -is [string]) { $entry } else { "$($entry.APFSPhysicalStore)" }
        if ($store -ne '') { break }
    }
    if ($store -ne '') {
        $storeInfo = Get-MacDiskInfo -Device $store
        $storeVerdict = Test-PermanentMacDisk -Info $storeInfo
        if ($null -ne $storeVerdict) { return [bool]$storeVerdict }
    }
    $verdict = Test-PermanentMacDisk -Info $info
    if ($null -ne $verdict) { return [bool]$verdict }
    return $true
}

function Get-MacStorageVolume {
    <#
    .SYNOPSIS
        Volume records for this Mac, one per mounted local volume.
    .OUTPUTS
        [pscustomobject[]] Pool, TotalBytes, FreeBytes, Permanent.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()
    $device = @{}
    foreach ($row in (ConvertFrom-MacMountTable -Line (& mount 2>$null))) {
        $device[(Get-MountPointKey -Path $row.MountPoint)] = $row
    }
    # One verdict per pool: the same container backs several mounts, and
    # describing a device costs a process launch each time.
    $verdict = @{}
    $volumes = @()
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady) { continue }
        $row = $device[(Get-MountPointKey -Path $drive.Name)]
        if ($null -eq $row) { continue }
        $pool = Get-MacStoragePoolKey -Device $row.Device -FileSystem $row.FileSystem
        # Not a disk device: devfs, autofs and the network filesystems mount
        # under a name rather than /dev/diskN, and none of them is storage
        # this machine owns.
        if ($pool -eq '') { continue }
        if (-not $verdict.ContainsKey($pool)) { $verdict[$pool] = Test-PermanentMacPool -Pool $pool }
        $volumes += [pscustomobject]@{
            Pool       = $pool
            TotalBytes = [long]$drive.TotalSize
            FreeBytes  = [long]$drive.AvailableFreeSpace
            Permanent  = [bool]$verdict[$pool]
        }
    }
    return $volumes
}

function Get-LinuxParentDisk {
    <#
    .SYNOPSIS
        The whole disk a block device's space ultimately comes from.

    .DESCRIPTION
        Three shapes lead to a disk. A whole disk is listed directly under
        /sys/block. A partition is listed under its own disk's directory, so
        the disk is the entry that contains it. A mapped device (LVM, RAID,
        dm-crypt) is under /sys/block with the devices it is built from listed
        in slaves/, and is followed through the first of them -- the removable
        and bus properties it inherits are the same for every leg of a normal
        mapping.

    .PARAMETER KernelName
        Kernel name of the device, e.g. nvme0n1p4, sda2, dm-0.

    .PARAMETER SysRoot
        Root of the sysfs tree. Overridden by tests.

    .OUTPUTS
        [string] Whole-disk kernel name, or '' when sysfs does not describe it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$KernelName,
        [string]$SysRoot = '/sys'
    )
    $name = $KernelName
    # Bounded rather than "until it resolves": a mapping stacked on a mapping
    # is normal (dm-crypt over LVM), a cycle is not, and this runs inside an
    # HTTP handler.
    for ($hop = 0; $hop -lt 8; $hop++) {
        if ($name -eq '') { return '' }
        $blockPath = Join-Path $SysRoot 'block' | Join-Path -ChildPath $name
        if (Test-Path -LiteralPath $blockPath) {
            $slaves = Join-Path $blockPath 'slaves'
            $first  = @(Get-ChildItem -LiteralPath $slaves -ErrorAction SilentlyContinue | Sort-Object -Property Name)
            if ($first.Count -eq 0) { return $name }
            $name = $first[0].Name
            continue
        }
        # Not a whole disk: find the disk that holds this partition.
        $parent = ''
        foreach ($disk in (Get-ChildItem -LiteralPath (Join-Path $SysRoot 'block') -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath (Join-Path $disk.FullName $name)) { $parent = $disk.Name; break }
        }
        if ($parent -eq '') { return '' }
        $name = $parent
    }
    return ''
}

function Resolve-LinuxDevicePath {
    <#
    .SYNOPSIS
        A mount source as the device node it ends at.

    .DESCRIPTION
        The kernel records a mount under the path it was given, and the common
        installs give it a name that stands for a device rather than being one:
        an LVM volume mounts as /dev/mapper/<vg>-<lv>, which is a link to
        /dev/dm-N. Following the link is what lets the device be found in
        sysfs, and what makes two names for one filesystem collapse to a single
        pool.

    .PARAMETER Device
        Mount source, e.g. /dev/mapper/ubuntu--vg-ubuntu--lv.

    .OUTPUTS
        [string] The device node, or the input unchanged when it is not a link.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Device)
    if ("$Device" -eq '') { return '' }
    try {
        $target = (Get-Item -LiteralPath $Device -Force -ErrorAction Stop).ResolveLinkTarget($true)
        if ($target) { return $target.FullName }
    } catch {
        Write-Debug "Resolve-LinuxDevicePath: could not resolve $Device`: $($_.Exception.Message)"
    }
    return $Device
}

function Test-PermanentLinuxDisk {
    <#
    .SYNOPSIS
        Whether a Linux whole disk is part of the machine.

    .DESCRIPTION
        Two properties, because either alone misses a common case. The
        kernel's removable flag catches the media that can be taken out (SD
        cards, optical), but reads 0 for a USB hard disk -- the media stays in
        the enclosure, and the enclosure is what leaves. So the device's place
        in the sysfs device tree is checked too: storage reached over USB
        hangs off a USB controller, whatever its removable flag says.

    .PARAMETER Disk
        Whole-disk kernel name, e.g. nvme0n1.

    .PARAMETER SysRoot
        Root of the sysfs tree. Overridden by tests.

    .OUTPUTS
        [bool] permanent or not. True when sysfs does not describe the disk,
        so an unrecognised controller reports its storage rather than losing it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        # Not mandatory: the disk behind a device is what Get-LinuxParentDisk
        # could resolve, and it answers '' for a device sysfs does not list --
        # which is a verdict of "count it", not a call that should fail.
        [string]$Disk = '',
        [string]$SysRoot = '/sys'
    )
    if ($Disk -eq '') { return $true }
    $blockPath = Join-Path $SysRoot 'block' | Join-Path -ChildPath $Disk
    if (-not (Test-Path -LiteralPath $blockPath)) { return $true }
    $removable = ''
    try { $removable = (Get-Content -LiteralPath (Join-Path $blockPath 'removable') -Raw -ErrorAction Stop).Trim() } catch { $removable = '' }
    if ($removable -eq '1') { return $false }
    try {
        $target = (Get-Item -LiteralPath $blockPath -Force -ErrorAction Stop).ResolveLinkTarget($true)
        $path   = if ($target) { $target.FullName } else { $blockPath }
        if ($path -match '/usb\d*/') { return $false }
    } catch {
        Write-Debug "Test-PermanentLinuxDisk: could not resolve $blockPath`: $($_.Exception.Message)"
    }
    return $true
}

function Get-LinuxStorageVolume {
    <#
    .SYNOPSIS
        Volume records for this Linux host, one per mounted block device.
    .PARAMETER SysRoot
        Root of the sysfs tree. Overridden by tests.
    .OUTPUTS
        [pscustomobject[]] Pool, TotalBytes, FreeBytes, Permanent.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([string]$SysRoot = '/sys')
    $device = @{}
    $mounts = @()
    try { $mounts = Get-Content -LiteralPath '/proc/self/mounts' -ErrorAction Stop } catch { $mounts = @() }
    foreach ($row in (ConvertFrom-LinuxMountTable -Line $mounts)) {
        $device[(Get-MountPointKey -Path $row.MountPoint)] = $row
    }
    $verdict = @{}
    $volumes = @()
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady) { continue }
        $row = $device[(Get-MountPointKey -Path $drive.Name)]
        if ($null -eq $row) { continue }
        $dev = "$($row.Device)"
        # Only real block devices are the machine's storage. The kernel's own
        # filesystems (tmpfs, sysfs, cgroup, efivarfs) and the network ones
        # (nfs, cifs) mount under a source that is not a device node; a loop
        # device is a file on a pool already counted, so every installed snap
        # would otherwise be added to the machine's capacity; and a zram device
        # is memory that disappears with the power.
        if ($dev -notlike '/dev/*') { continue }
        if ($dev -like '/dev/loop*' -or $dev -like '/dev/zram*') { continue }
        $dev = Resolve-LinuxDevicePath -Device $dev
        $kernelName = Split-Path -Path $dev -Leaf
        if (-not $verdict.ContainsKey($dev)) {
            $disk = Get-LinuxParentDisk -KernelName $kernelName -SysRoot $SysRoot
            $verdict[$dev] = Test-PermanentLinuxDisk -Disk $disk -SysRoot $SysRoot
        }
        $volumes += [pscustomobject]@{
            # A filesystem, not the disk under it: separate partitions of one
            # disk are separate pools, while a bind mount and a btrfs
            # subvolume share the device they came from and collapse to one.
            Pool       = $dev
            TotalBytes = [long]$drive.TotalSize
            FreeBytes  = [long]$drive.AvailableFreeSpace
            Permanent  = [bool]$verdict[$dev]
        }
    }
    return $volumes
}

function Test-PermanentWindowsDisk {
    <#
    .SYNOPSIS
        Whether a Win32_DiskDrive describes storage that stays with the machine.

    .DESCRIPTION
        Windows answers this three ways and they do not overlap: the media
        type names the external and removable classes outright, the interface
        names the two buses a drive is carried on, and the device ID carries
        the enumerator that claimed it -- a USB hard disk arrives under
        USBSTOR with a media type that reads "Fixed hard disk media", so the
        enumerator is the only one of the three that catches it.

        Anything else counts, including a drive whose media type is blank or
        unknown: a machine whose controller Windows cannot classify still has
        its disks.

    .PARAMETER InterfaceType
        Win32_DiskDrive InterfaceType, e.g. SCSI, IDE, USB.

    .PARAMETER MediaType
        Win32_DiskDrive MediaType, e.g. "Fixed hard disk media".

    .PARAMETER PnpDeviceId
        Win32_DiskDrive PNPDeviceID, e.g. USBSTOR\DISK&VEN_...

    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$InterfaceType,
        [string]$MediaType,
        [string]$PnpDeviceId
    )
    if ("$InterfaceType" -in @('USB', '1394')) { return $false }
    if ("$PnpDeviceId" -match '^(USBSTOR|USB|1394)\\') { return $false }
    if ("$MediaType" -match 'Removable|External') { return $false }
    return $true
}

function Get-WindowsStorageVolume {
    <#
    .SYNOPSIS
        Volume records for this Windows host, one per fixed logical disk.

    .DESCRIPTION
        The logical disk is the pool -- Windows publishes a volume once, under
        one letter -- so the fan-out through partitions exists only to learn
        which physical disk each letter sits on, and therefore whether the
        letter is the machine's own storage. A letter that maps to several
        disks (a spanned volume) is permanent only if every disk under it is.

        A letter no disk claims is counted. Storage that presents itself
        through a virtual layer (a storage pool, a dynamic disk) reaches
        DriveInfo without reaching this association, and dropping it would
        take a real filesystem off the machine.

    .OUTPUTS
        [pscustomobject[]] Pool, TotalBytes, FreeBytes, Permanent.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param()
    $verdict = @{}
    try {
        foreach ($disk in (Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop)) {
            $permanent = Test-PermanentWindowsDisk -InterfaceType $disk.InterfaceType -MediaType $disk.MediaType -PnpDeviceId $disk.PNPDeviceID
            $partitions = @(Get-CimAssociatedInstance -InputObject $disk -ResultClassName Win32_DiskPartition -ErrorAction SilentlyContinue)
            foreach ($partition in $partitions) {
                $logical = @(Get-CimAssociatedInstance -InputObject $partition -ResultClassName Win32_LogicalDisk -ErrorAction SilentlyContinue)
                foreach ($volume in $logical) {
                    $id = "$($volume.DeviceID)".ToUpperInvariant()
                    if ($id -eq '') { continue }
                    if ($verdict.ContainsKey($id)) { $verdict[$id] = $verdict[$id] -and $permanent }
                    else { $verdict[$id] = $permanent }
                }
            }
        }
    } catch {
        Write-Debug "Get-WindowsStorageVolume: could not enumerate disk drives: $($_.Exception.Message)"
    }
    $volumes = @()
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady) { continue }
        # DriveType is trustworthy here in a way it is not on the Unix
        # platforms: Windows classifies the drive itself, so removable media,
        # optical drives and mapped network drives are already out.
        if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) { continue }
        $id = "$($drive.Name)"
        if ($id.Length -ge 2) { $id = $id.Substring(0, 2).ToUpperInvariant() }
        $permanent = $true
        if ($verdict.ContainsKey($id)) { $permanent = [bool]$verdict[$id] }
        $volumes += [pscustomobject]@{
            Pool       = $id
            TotalBytes = [long]$drive.TotalSize
            FreeBytes  = [long]$drive.AvailableFreeSpace
            Permanent  = $permanent
        }
    }
    return $volumes
}

function Get-HostStorageFact {
    <#
    .SYNOPSIS
        This machine's permanent storage: total and free bytes.

    .DESCRIPTION
        Counts each space pool once and only where the pool is on a device
        that stays with the machine, so the figure is the storage a host can
        be planned against rather than the sum of everything it currently
        mounts.

        Never throws: a host that cannot describe its disks reports zero and
        the consumer renders that, which is why the collectors are the only
        code allowed to fail here.

    .OUTPUTS
        [pscustomobject] with TotalBytes and FreeBytes ([long] each).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    try {
        $volumes = if ($IsWindows) { Get-WindowsStorageVolume }
                   elseif ($IsMacOS) { Get-MacStorageVolume }
                   else { Get-LinuxStorageVolume }
        return (Measure-PermanentStorage -Volume $volumes)
    } catch {
        Write-Debug "Get-HostStorageFact: could not measure storage: $($_.Exception.Message)"
        return [pscustomobject]@{ TotalBytes = [long]0; FreeBytes = [long]0 }
    }
}

Export-ModuleMember -Function Get-HostStorageFact, Measure-PermanentStorage, Get-MountPointKey,
    ConvertFrom-LinuxMountTable, ConvertFrom-MacMountTable, Get-MacStoragePoolKey,
    ConvertFrom-DiskUtilPlist, Get-MacDiskInfo, Test-PermanentMacDisk, Test-PermanentMacPool, Get-MacStorageVolume,
    Get-LinuxParentDisk, Resolve-LinuxDevicePath, Test-PermanentLinuxDisk, Get-LinuxStorageVolume,
    Test-PermanentWindowsDisk, Get-WindowsStorageVolume
