<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42dd28f9-7cee-4413-a3f4-cd86d58bb561
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host storage facts pester
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
    Guards on Test.HostFacts.psm1: a host reports the storage it keeps, counted
    once.
.DESCRIPTION
    The two ways a host's disk figure goes wrong are both over-counting, and
    they need different answers:

      * a pool published as several mount points (an APFS container is five of
        them, each reporting the container's whole size, which multiplies a
        2 TB machine by five) is de-duplicated by pool identity;
      * storage that is merely attached -- a USB enclosure, a card, a disk
        image, a share -- is left out of the sum entirely.

    Pinned here: the pool collapse takes one figure per pool rather than
    adding them, distinct pools still add up (partitions of one disk are not
    one pool), the platform classifiers name the attached cases, and an
    unclassifiable device is COUNTED -- a host whose controller no platform
    recognizes must not report a machine with no storage.

    The throw-based Assert-* helpers live in the file's BeforeAll, which is the
    scope Pester 5 shares with the It blocks; defining them at script scope
    instead makes every It fail on a missing command rather than on an
    assertion.
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.HostFacts.psm1'

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue

function New-Volume {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: builds one in-memory volume record; changes no state.')]
    [OutputType([pscustomobject])]
    param($Pool, [long]$TotalBytes, [long]$FreeBytes, [bool]$Permanent = $true)
    [pscustomobject]@{ Pool = $Pool; TotalBytes = $TotalBytes; FreeBytes = $FreeBytes; Permanent = $Permanent }
}

# The mount table of a 2 TB Mac, with an external drive and a share attached.
# One APFS container (disk1) carries five mount points; each of them reports
# the container's whole size and its shared free space.
$script:MacMountText = @(
    '/dev/disk1s5s1 on / (apfs, sealed, local, read-only, journaled)'
    'devfs on /dev (devfs, local, nobrowse)'
    '/dev/disk1s6 on /System/Volumes/VM (apfs, local, noexec, journaled, noatime, nobrowse)'
    '/dev/disk1s2 on /System/Volumes/Preboot (apfs, local, journaled, nobrowse)'
    '/dev/disk1s4 on /System/Volumes/Update (apfs, local, journaled, nobrowse)'
    '/dev/disk1s5 on /System/Volumes/Data (apfs, local, journaled, nobrowse, protect)'
    'map auto_home on /System/Volumes/Data/home (autofs, automounted, nobrowse)'
    '/dev/disk4s2 on /Volumes/Backup Drive (hfs, local, nodev, nosuid, journaled)'
    '//guest@nas/_share on /Volumes/share (smbfs, nodev, nosuid, mounted by tester)'
)
$script:MacContainerSize = [long]1995511767040
$script:MacContainerFree = [long]1522564513792

# A sysfs tree: an internal NVMe with two partitions, a USB disk reached
# through a USB controller, a card reader whose media is removable, and an
# LVM volume mapped onto the internal disk.
function New-FakeSysRoot {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: builds a sysfs tree under a temp path; no production state.')]
    param([Parameter(Mandatory)][string]$Path)
    $block   = Join-Path $Path 'block'
    $devices = Join-Path $Path 'devices'
    $null = New-Item -ItemType Directory -Path $block -Force
    $pci    = Join-Path $devices 'pci0000:00'
    $nvme   = Join-Path $pci 'nvme0n1'
    $usbDev = Join-Path $pci 'usb2' | Join-Path -ChildPath '2-1' | Join-Path -ChildPath 'sdb'
    $cardDev = Join-Path $pci 'mmc0' | Join-Path -ChildPath 'mmcblk0'
    foreach ($d in @($nvme, $usbDev, $cardDev)) { $null = New-Item -ItemType Directory -Path $d -Force }
    $null = New-Item -ItemType Directory -Path (Join-Path $nvme 'nvme0n1p1') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $nvme 'nvme0n1p4') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $usbDev 'sdb1') -Force
    Set-Content -LiteralPath (Join-Path $nvme 'removable')    -Value '0' -NoNewline
    Set-Content -LiteralPath (Join-Path $usbDev 'removable')  -Value '0' -NoNewline
    Set-Content -LiteralPath (Join-Path $cardDev 'removable') -Value '1' -NoNewline
    foreach ($pair in @(@('nvme0n1', $nvme), @('sdb', $usbDev), @('mmcblk0', $cardDev))) {
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $block $pair[0]) -Target $pair[1] -Force
    }
    # dm-0 is mapped onto the internal disk's second partition, and carries no
    # removable flag of its own -- the properties come from what it is built on.
    $dm = Join-Path $devices 'virtual' | Join-Path -ChildPath 'block' | Join-Path -ChildPath 'dm-0'
    $null = New-Item -ItemType Directory -Path (Join-Path $dm 'slaves' | Join-Path -ChildPath 'nvme0n1p4') -Force
    $null = New-Item -ItemType SymbolicLink -Path (Join-Path $block 'dm-0') -Target $dm -Force
}
}

Describe 'Measure-PermanentStorage counts each pool once' {
    It 'collapses the mount points of one pool to that pool''s size' {
        $volumes = 1..5 | ForEach-Object { New-Volume -Pool 'disk1' -TotalBytes 1995511767040 -FreeBytes 1522564513792 }
        $measured = Measure-PermanentStorage -Volume $volumes
        Assert-Equal -Expected 1995511767040 -Actual $measured.TotalBytes -Because 'five mounts over one container are one 2 TB pool'
        Assert-Equal -Expected 1522564513792 -Actual $measured.FreeBytes -Because 'the container free space is shared, not multiplied'
    }

    It 'adds distinct pools together' {
        $volumes = @(
            (New-Volume -Pool '/dev/nvme0n1p1' -TotalBytes 1069547520   -FreeBytes 997081088)
            (New-Volume -Pool '/dev/nvme0n1p4' -TotalBytes 675259146240 -FreeBytes 572642377728)
        )
        $measured = Measure-PermanentStorage -Volume $volumes
        Assert-Equal -Expected 676328693760 -Actual $measured.TotalBytes -Because 'partitions of one disk are separate pools'
        Assert-Equal -Expected 573639458816 -Actual $measured.FreeBytes -Because ''
    }

    It 'leaves out storage that is only attached' {
        $volumes = @(
            (New-Volume -Pool 'disk1'   -TotalBytes 1995511767040 -FreeBytes 1522564513792)
            (New-Volume -Pool 'disk4s2' -TotalBytes 4000787030016 -FreeBytes 2000393515008 -Permanent $false)
        )
        $measured = Measure-PermanentStorage -Volume $volumes
        Assert-Equal -Expected 1995511767040 -Actual $measured.TotalBytes -Because 'a 4 TB enclosure is not the machine''s storage'
    }

    It 'ignores a zero-sized mount without letting it mask its pool' {
        $volumes = @(
            (New-Volume -Pool '/dev/sda1' -TotalBytes 0             -FreeBytes 0)
            (New-Volume -Pool '/dev/sda1' -TotalBytes 1000000000000 -FreeBytes 400000000000)
        )
        $measured = Measure-PermanentStorage -Volume $volumes
        Assert-Equal -Expected 1000000000000 -Actual $measured.TotalBytes -Because ''
        Assert-Equal -Expected 400000000000 -Actual $measured.FreeBytes -Because ''
    }

    It 'reports zero for a host with nothing to count' {
        $measured = Measure-PermanentStorage -Volume @()
        Assert-Equal -Expected 0 -Actual $measured.TotalBytes -Because ''
        Assert-Equal -Expected 0 -Actual $measured.FreeBytes -Because ''
    }
}

Describe 'macOS mount table and pool identity' {
    It 'reads device, mount point and filesystem, including a name with spaces' {
        $rows = ConvertFrom-MacMountTable -Line $script:MacMountText
        Assert-Equal -Expected 9 -Actual $rows.Count -Because ''
        $backup = $rows | Where-Object { $_.Device -eq '/dev/disk4s2' }
        Assert-Equal -Expected '/Volumes/Backup Drive' -Actual $backup.MountPoint -Because 'a volume name with a space is one mount point'
        Assert-Equal -Expected 'hfs' -Actual $backup.FileSystem -Because ''
        Assert-Equal -Expected 'apfs' -Actual ($rows | Where-Object { $_.MountPoint -eq '/' }).FileSystem -Because ''
    }

    It 'names the container for APFS volumes and the device otherwise' {
        Assert-Equal -Expected 'disk1' -Actual (Get-MacStoragePoolKey -Device '/dev/disk1s5s1' -FileSystem 'apfs') -Because 'a sealed system volume is in its container'
        Assert-Equal -Expected 'disk1' -Actual (Get-MacStoragePoolKey -Device '/dev/disk1s5'   -FileSystem 'apfs') -Because ''
        Assert-Equal -Expected 'disk0s2' -Actual (Get-MacStoragePoolKey -Device '/dev/disk0s2'   -FileSystem 'hfs') -Because 'partitions own their space outright'
        Assert-Equal -Expected 'disk0s3' -Actual (Get-MacStoragePoolKey -Device '/dev/disk0s3'   -FileSystem 'hfs') -Because ''
    }

    It 'refuses sources that are not disk devices' {
        Assert-Equal -Expected '' -Actual (Get-MacStoragePoolKey -Device 'devfs'              -FileSystem 'devfs') -Because ''
        Assert-Equal -Expected '' -Actual (Get-MacStoragePoolKey -Device 'map auto_home'      -FileSystem 'autofs') -Because ''
        Assert-Equal -Expected '' -Actual (Get-MacStoragePoolKey -Device '//guest@nas/_share' -FileSystem 'smbfs') -Because 'a share belongs to the server, not to every host that mounts it'
    }

    It 'reports a 2 TB Mac as 2 TB with an enclosure and a share attached' {
        $volumes = foreach ($row in (ConvertFrom-MacMountTable -Line $script:MacMountText)) {
            $pool = Get-MacStoragePoolKey -Device $row.Device -FileSystem $row.FileSystem
            if ($pool -eq '') { continue }
            if ($pool -eq 'disk4s2') { New-Volume -Pool $pool -TotalBytes 4000787030016 -FreeBytes 2000393515008 -Permanent $false }
            else { New-Volume -Pool $pool -TotalBytes $script:MacContainerSize -FreeBytes $script:MacContainerFree }
        }
        $measured = Measure-PermanentStorage -Volume $volumes
        Assert-Equal -Expected $script:MacContainerSize -Actual $measured.TotalBytes -Because ''
        Assert-Equal -Expected $script:MacContainerFree -Actual $measured.FreeBytes -Because ''
    }
}

Describe 'diskutil property lists' {
    BeforeAll {
        # The shape `diskutil info -plist` writes, down to Apple's DTD
        # declaration -- the parse must stay offline, and a boolean must not
        # arrive as the string 'true'.
        $script:ContainerPlist = @'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>APFSContainerReference</key>
	<string>disk1</string>
	<key>APFSPhysicalStores</key>
	<array>
		<dict>
			<key>APFSPhysicalStore</key>
			<string>disk0s2</string>
		</dict>
	</array>
	<key>DeviceIdentifier</key>
	<string>disk1</string>
	<key>Size</key>
	<integer>1995511767040</integer>
	<key>VirtualOrPhysical</key>
	<string>Virtual</string>
</dict>
</plist>
'@
        $script:PhysicalStorePlist = @'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>BusProtocol</key>
	<string>PCI-Express</string>
	<key>DeviceIdentifier</key>
	<string>disk0s2</string>
	<key>Ejectable</key>
	<false/>
	<key>Internal</key>
	<true/>
	<key>RemovableMediaOrExternalDevice</key>
	<false/>
	<key>TotalSize</key>
	<integer>1995511767040</integer>
</dict>
</plist>
'@
        $script:UsbPlist = @'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>BusProtocol</key>
	<string>USB</string>
	<key>DeviceIdentifier</key>
	<string>disk4s2</string>
	<key>Internal</key>
	<false/>
	<key>RemovableMediaOrExternalDevice</key>
	<true/>
	<key>TotalSize</key>
	<integer>4000787030016</integer>
</dict>
</plist>
'@
    }

    It 'reads keys, typed values and the physical stores of a container' {
        $info = ConvertFrom-DiskUtilPlist -Text $script:ContainerPlist
        Assert-Equal -Expected 'disk1' -Actual $info.APFSContainerReference -Because ''
        Assert-Equal -Expected 1995511767040 -Actual $info.Size -Because 'an integer arrives as a number'
        Assert-Equal -Expected 'disk0s2' -Actual (@($info.APFSPhysicalStores)[0].APFSPhysicalStore) -Because 'the container is followed to the medium under it'
    }

    It 'reads booleans as booleans' {
        $info = ConvertFrom-DiskUtilPlist -Text $script:PhysicalStorePlist
        Assert-True  ($info.Internal -is [bool]) ''
        Assert-True  $info.Internal ''
        Assert-False $info.RemovableMediaOrExternalDevice ''
    }

    It 'returns nothing for output that is not a property list' {
        Assert-True ($null -eq (ConvertFrom-DiskUtilPlist -Text '')) ''
        Assert-True ($null -eq (ConvertFrom-DiskUtilPlist -Text 'Could not find disk: disk9')) ''
    }

    It 'classifies the parsed records the way the sum needs' {
        Assert-True  ($null -eq (Test-PermanentMacDisk -Info (ConvertFrom-DiskUtilPlist -Text $script:ContainerPlist))) 'a container answers for its store, not for itself'
        Assert-True  (Test-PermanentMacDisk -Info (ConvertFrom-DiskUtilPlist -Text $script:PhysicalStorePlist)) ''
        Assert-False (Test-PermanentMacDisk -Info (ConvertFrom-DiskUtilPlist -Text $script:UsbPlist)) ''
    }
}

Describe 'Test-PermanentMacDisk classification' {
    It 'counts an internal fixed device' {
        $info = [pscustomobject]@{ Internal = $true; RemovableMediaOrExternalDevice = $false; BusProtocol = 'PCI-Express' }
        Assert-True (Test-PermanentMacDisk -Info $info) ''
    }

    It 'refuses an external device, removable media and a disk image' {
        Assert-False (Test-PermanentMacDisk -Info ([pscustomobject]@{ Internal = $false; RemovableMediaOrExternalDevice = $true; BusProtocol = 'USB' })) ''
        Assert-False (Test-PermanentMacDisk -Info ([pscustomobject]@{ Internal = $true; RemovableMediaOrExternalDevice = $true; BusProtocol = 'Secure Digital' })) 'internal card readers still take the card out'
        Assert-False (Test-PermanentMacDisk -Info ([pscustomobject]@{ Internal = $true; RemovableMediaOrExternalDevice = $false; BusProtocol = 'Disk Image' })) 'an image is a file on a pool already counted'
    }

    It 'answers nothing when the record does not say' {
        Assert-True ($null -eq (Test-PermanentMacDisk -Info ([pscustomobject]@{ BusProtocol = 'Apple Fabric' }))) 'a synthesized container has no bus of its own'
        Assert-True ($null -eq (Test-PermanentMacDisk -Info $null)) ''
    }
}

Describe 'Linux mount table' {
    It 'undoes the octal escapes the kernel writes' {
        $rows = ConvertFrom-LinuxMountTable -Line @('/dev/sdb1 /media/My\040Disk ext4 rw,relatime 0 0')
        Assert-Equal -Expected '/media/My Disk' -Actual $rows[0].MountPoint -Because ''
        Assert-Equal -Expected '/dev/sdb1' -Actual $rows[0].Device -Because ''
        Assert-Equal -Expected 'ext4' -Actual $rows[0].FileSystem -Because ''
    }

    It 'reads the kernel and network sources as they are written' {
        $rows = ConvertFrom-LinuxMountTable -Line @(
            'tmpfs /run tmpfs rw,nosuid 0 0'
            '//nas/share /mnt/nas cifs rw 0 0'
            'garbage'
        )
        Assert-Equal -Expected 2 -Actual $rows.Count -Because 'a line without the three leading fields is not a mount'
        Assert-Equal -Expected 'tmpfs' -Actual $rows[0].Device -Because ''
        Assert-Equal -Expected '//nas/share' -Actual $rows[1].Device -Because ''
    }
}

Describe 'Linux device classification' -Skip:($IsWindows) {
    BeforeAll {
        $script:SysRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-sysfs-" + [guid]::NewGuid().ToString('N'))
        New-FakeSysRoot -Path $script:SysRoot
    }

    AfterAll {
        Remove-Item -LiteralPath $script:SysRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'follows a partition to the disk that holds it' {
        Assert-Equal -Expected 'nvme0n1' -Actual (Get-LinuxParentDisk -KernelName 'nvme0n1p4' -SysRoot $script:SysRoot) -Because ''
        Assert-Equal -Expected 'sdb' -Actual (Get-LinuxParentDisk -KernelName 'sdb1'      -SysRoot $script:SysRoot) -Because ''
    }

    It 'follows a mount source that names a device rather than being one' {
        $devDir = Join-Path $script:SysRoot 'dev'
        $null = New-Item -ItemType Directory -Path $devDir -Force
        $node = Join-Path $devDir 'dm-0'
        Set-Content -LiteralPath $node -Value '' -NoNewline
        $link = Join-Path $devDir 'ubuntu--vg-ubuntu--lv'
        $null = New-Item -ItemType SymbolicLink -Path $link -Target $node -Force
        Assert-Equal -Expected $node -Actual (Resolve-LinuxDevicePath -Device $link) -Because 'an LVM volume mounts under a name that links to the device node'
        Assert-Equal -Expected $node -Actual (Resolve-LinuxDevicePath -Device $node) -Because 'a device node resolves to itself'
        Assert-Equal -Expected '/dev/nowhere' -Actual (Resolve-LinuxDevicePath -Device '/dev/nowhere') -Because 'a source that is not there is left as written'
    }

    It 'follows a mapped device through what it is built on' {
        Assert-Equal -Expected 'nvme0n1' -Actual (Get-LinuxParentDisk -KernelName 'dm-0' -SysRoot $script:SysRoot) -Because 'an LVM volume is as permanent as its disk'
    }

    It 'names a whole disk as its own parent' {
        Assert-Equal -Expected 'nvme0n1' -Actual (Get-LinuxParentDisk -KernelName 'nvme0n1' -SysRoot $script:SysRoot) -Because ''
    }

    It 'says nothing about a device sysfs does not list' {
        Assert-Equal -Expected '' -Actual (Get-LinuxParentDisk -KernelName 'zram0' -SysRoot $script:SysRoot) -Because ''
    }

    It 'counts the internal disk' {
        Assert-True (Test-PermanentLinuxDisk -Disk 'nvme0n1' -SysRoot $script:SysRoot) ''
    }

    It 'refuses a disk reached over USB even though its media is not removable' {
        Assert-False (Test-PermanentLinuxDisk -Disk 'sdb' -SysRoot $script:SysRoot) 'the enclosure leaves with the operator'
    }

    It 'refuses removable media' {
        Assert-False (Test-PermanentLinuxDisk -Disk 'mmcblk0' -SysRoot $script:SysRoot) ''
    }

    It 'counts a disk sysfs cannot describe' {
        Assert-True (Test-PermanentLinuxDisk -Disk 'unknown0' -SysRoot $script:SysRoot) 'an unrecognized controller must not zero a host'
        Assert-True (Test-PermanentLinuxDisk -Disk '' -SysRoot $script:SysRoot) ''
    }
}

Describe 'Windows disk classification' {
    It 'counts a fixed internal disk' {
        Assert-True (Test-PermanentWindowsDisk -InterfaceType 'SCSI' -MediaType 'Fixed hard disk media' -PnpDeviceId 'SCSI\DISK&VEN_NVME&PROD_SAMSUNG\5&1') ''
        Assert-True (Test-PermanentWindowsDisk -InterfaceType 'IDE' -MediaType 'Fixed hard disk media' -PnpDeviceId 'IDE\DISKST2000\4&2') ''
    }

    It 'refuses a USB disk however it announces itself' {
        Assert-False (Test-PermanentWindowsDisk -InterfaceType 'USB' -MediaType 'Removable Media' -PnpDeviceId 'USBSTOR\DISK&VEN_SANDISK\7&1') ''
        Assert-False (Test-PermanentWindowsDisk -InterfaceType 'SCSI' -MediaType 'Fixed hard disk media' -PnpDeviceId 'USBSTOR\DISK&VEN_WD&PROD_ELEMENTS\9&2') 'a USB hard disk reports fixed media on a SCSI-speaking bridge'
        Assert-False (Test-PermanentWindowsDisk -InterfaceType 'SCSI' -MediaType 'External hard disk media' -PnpDeviceId 'SCSI\DISK&VEN_\1&3') ''
    }

    It 'counts a disk Windows will not classify' {
        Assert-True (Test-PermanentWindowsDisk -InterfaceType '' -MediaType '' -PnpDeviceId '') 'unknown is not the same as attached'
    }
}

Describe 'Get-HostStorageFact on this host' {
    It 'reports storage without throwing' {
        $fact = Get-HostStorageFact
        Assert-True ($fact.TotalBytes -ge 0) ''
        Assert-True ($fact.FreeBytes -le $fact.TotalBytes) 'free space is part of the total, never more than it'
    }
}
