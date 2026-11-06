<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42797929-4086-43ea-846a-16a46da5c267
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host kvm hyperv rename snapshot storage pester
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
    Pins that VM storage is deleted only when no registered VM uses it, and that
    a rename interrupted between the registration and the storage move is
    finished rather than read as an abandoned directory.
.DESCRIPTION
    Snapshot promotion renames the VM and then moves its storage. A failure or
    kill between the two leaves the promoted VM's disks under the vacated name,
    and the removal of that name, or the orphan sweep, used to delete the
    directory and with it the baseline every later cycle restores from. The KVM
    cases run the real driver against a fixture tree with virsh mocked; the
    Hyper-V cases run the driver's helpers against a stand-in Hyper-V module;
    the sweep case runs the KVM sweeper's own regions with a fake virsh.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'A stand-in for a native tool must be a global function.')]
param()

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Globalization.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
    $script:Stubbed = @()
    foreach ($nativeName in @('virsh')) {
        if (-not (Get-Command $nativeName -CommandType Application -ErrorAction SilentlyContinue)) {
            Set-Item -LiteralPath "Function:global:$nativeName" -Value { $global:LASTEXITCODE = 1 }
            $script:Stubbed += $nativeName
        }
    }
    Get-Module -Name 'Yuruna.Host' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $script:RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1') -Force -DisableNameChecking -Global -WarningAction SilentlyContinue

    function New-VirshResult {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Builds an in-memory fixture result.')]
        param([int]$ExitCode = 0, [string]$StdOut = '', [switch]$TimedOut)
        return @{ ExitCode = $ExitCode; StdOut = $StdOut; StdErr = ''; TimedOut = [bool]$TimedOut; Started = $true
            DrainTimedOut = $false; KillFailed = $false; OutputTruncated = $false; ElapsedMs = 1 }
    }
    function Get-BlockList {
        param([string]$Xml)
        $rows = foreach ($m in [regex]::Matches($Xml, "<source file='([^']+)'/>")) { " file   disk     vda      $($m.Groups[1].Value)" }
        return (@(' Type   Device   Target   Source', '------------------------------------------') + @($rows)) -join "`n"
    }
}

AfterAll {
    Get-Module -Name 'Yuruna.Host' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    foreach ($name in $script:Stubbed) { Remove-Item -LiteralPath "Function:global:$name" -ErrorAction SilentlyContinue }
}

Describe 'KVM storage is deleted only when no defined domain uses it' {
    BeforeEach {
        $script:Vms = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Vms 'test-01') -Force
        Set-Content -LiteralPath (Join-Path $script:Vms 'test-01/test-01.qcow2') -Value 'baseline disk'
        InModuleScope Yuruna.Host -Parameters @{ Vms = $script:Vms } { param($Vms) $script:VmRootDir = $Vms }
        # The promoted domain was renamed, and the storage move never ran.
        $script:Domain = @{ 'snap-base' = "<domain><name>snap-base</name><devices><disk><source file='$($script:Vms)/test-01/test-01.qcow2'/></disk></devices></domain>" }
        $script:Defined = [System.Collections.Generic.List[string]]::new()
        $script:BlockListFails = $false
        Mock -ModuleName Yuruna.Host Get-VMName { @($script:Domain.Keys) }
        Mock -ModuleName Yuruna.Host Get-KvmDomainState { [pscustomobject]@{ State = 'stopped'; Raw = 'shut off'; Reason = '' } }
        Mock -ModuleName Yuruna.Host Invoke-VirshBounded {
            if ($VirshArgs[0] -eq 'domblklist') {
                if ($script:BlockListFails) { return (New-VirshResult -ExitCode 1 -TimedOut) }
                return (New-VirshResult -StdOut (Get-BlockList -Xml $script:Domain[$VirshArgs[-1]]))
            }
            return (New-VirshResult)
        }
        Mock -ModuleName Yuruna.Host Invoke-Virsh {
            $global:LASTEXITCODE = 0
            switch ($VirshArgs[0]) {
                'dumpxml' { return @($script:Domain[$VirshArgs[1]]) }
                'define' {
                    $xml = Get-Content -Raw -LiteralPath $VirshArgs[1]
                    $script:Defined.Add($xml)
                    $script:Domain['snap-base'] = $xml
                    return @()
                }
                default { return @() }
            }
        }
        Mock -ModuleName Yuruna.Host Stop-VMDhcpCapture { }
        Mock -ModuleName Yuruna.Host Write-Warning { }
        Mock -ModuleName Yuruna.Host Write-Information { }
    }

    It 'finishes the interrupted rename instead of deleting the promoted domain''s disks' {
        $removed = InModuleScope Yuruna.Host { Remove-VM -VMName 'test-01' -Confirm:$false }
        $removed | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Vms 'snap-base/snap-base.qcow2') | Should -BeTrue -Because 'the baseline moved under its own name'
        Get-Content -Raw -LiteralPath (Join-Path $script:Vms 'snap-base/snap-base.qcow2') | Should -Match 'baseline disk'
        $script:Defined.Count | Should -Be 1
        $script:Defined[0] | Should -Match ([regex]::Escape("$($script:Vms)/snap-base/snap-base.qcow2"))
    }
    It 'keeps the directory when the domains'' disks cannot be read' {
        $script:BlockListFails = $true
        $removed = InModuleScope Yuruna.Host { Remove-VM -VMName 'test-01' -Confirm:$false }
        $removed | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Vms 'test-01/test-01.qcow2') | Should -BeTrue
    }
    It 'deletes a directory no domain uses' {
        $script:Domain = @{}
        $removed = InModuleScope Yuruna.Host { Remove-VM -VMName 'test-01' -Confirm:$false }
        $removed | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Vms 'test-01') | Should -BeFalse
    }
    It 'refuses a rename into an existing directory before it renames anything' {
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Vms 'snap-next') -Force
        Mock -ModuleName Yuruna.Host Get-VMState { 'absent' }
        $renamed = InModuleScope Yuruna.Host { Rename-VM -VMName 'test-01' -NewName 'snap-next' -Confirm:$false }
        $renamed | Should -BeFalse
        Should -Invoke -ModuleName Yuruna.Host Invoke-Virsh -Times 0 -ParameterFilter { $VirshArgs[0] -eq 'domrename' }
    }
    It 'completes a rename the same way when it runs twice, including a name that extends the old one' {
        $script:Domain = @{ 'test-01.snap' = "<domain><name>test-01.snap</name><devices><disk><source file='$($script:Vms)/test-01/test-01.qcow2'/></disk></devices></domain>" }
        Mock -ModuleName Yuruna.Host Invoke-Virsh {
            $global:LASTEXITCODE = 0
            if ($VirshArgs[0] -eq 'dumpxml') { return @($script:Domain[$VirshArgs[1]]) }
            if ($VirshArgs[0] -eq 'define') { $xml = Get-Content -Raw -LiteralPath $VirshArgs[1]; $script:Defined.Add($xml); $script:Domain['test-01.snap'] = $xml }
            return @()
        }
        foreach ($pass in 1, 2) {
            InModuleScope Yuruna.Host { Complete-KvmDomainRename -VMName 'test-01' -NewName 'test-01.snap' -Confirm:$false } | Should -BeTrue
        }
        @(Get-ChildItem -LiteralPath (Join-Path $script:Vms 'test-01.snap') -Name) | Should -Be @('test-01.snap.qcow2')
        $script:Defined.Count | Should -Be 1 -Because 'the second run finds the definition already moved'
        $script:Domain['test-01.snap'] | Should -Not -Match 'test-01\.snap\.snap'
    }
    # The repair used to run only when a delete reached the vacated directory, so
    # anything else that reached it first -- a build into the slot, an operator
    # copying files -- met the promoted domain's disks under the wrong name.
    It 'finishes every interrupted rename at once, with no delete to trigger it' {
        $unrepaired = @(InModuleScope Yuruna.Host { Repair-VMStorageLocation -Confirm:$false })
        $unrepaired.Count | Should -Be 0
        Get-Content -Raw -LiteralPath (Join-Path $script:Vms 'snap-base/snap-base.qcow2') | Should -Match 'baseline disk'
        Test-Path -LiteralPath (Join-Path $script:Vms 'test-01') | Should -BeFalse -Because 'the directory moved with the rename it belonged to'
        $script:Defined[0] | Should -Match ([regex]::Escape("$($script:Vms)/snap-base/snap-base.qcow2"))
    }
    It 'names a domain it cannot repair now and leaves its storage where it is' {
        Mock -ModuleName Yuruna.Host Get-KvmDomainState { [pscustomobject]@{ State = 'running'; Raw = 'running'; Reason = '' } }
        $unrepaired = @(InModuleScope Yuruna.Host { Repair-VMStorageLocation -Confirm:$false })
        $unrepaired | Should -Be @('snap-base')
        Test-Path -LiteralPath (Join-Path $script:Vms 'test-01/test-01.qcow2') | Should -BeTrue
        $script:Defined.Count | Should -Be 0
    }
    # Whether the old directory is shared is a question about every domain, so an
    # unreadable one leaves that question open and nothing is moved on a guess.
    It 'moves nothing it cannot prove unshared when a domain cannot be read, and names every domain left' {
        $script:Domain['unreadable'] = $null
        Mock -ModuleName Yuruna.Host Invoke-VirshBounded {
            if ($VirshArgs[0] -eq 'domblklist') {
                if ($VirshArgs[-1] -eq 'unreadable') { return (New-VirshResult -ExitCode 1 -TimedOut) }
                return (New-VirshResult -StdOut (Get-BlockList -Xml $script:Domain[$VirshArgs[-1]]))
            }
            return (New-VirshResult)
        }
        $unrepaired = @(InModuleScope Yuruna.Host { Repair-VMStorageLocation -Confirm:$false })
        @($unrepaired | Sort-Object) | Should -Be @('snap-base', 'unreadable')
        Get-Content -Raw -LiteralPath (Join-Path $script:Vms 'test-01/test-01.qcow2') | Should -Match 'baseline disk'
        $script:Defined.Count | Should -Be 0
    }
    # A builder replaces the files in its slot by name right after this call, so
    # the call is where the slot's directory must be proven free.
    It 'finishes the interrupted rename before a rebuild replaces the slot''s files' {
        { InModuleScope Yuruna.Host { Remove-KvmDomainDefinition -VMName 'test-01' -Confirm:$false } } | Should -Not -Throw
        Get-Content -Raw -LiteralPath (Join-Path $script:Vms 'snap-base/snap-base.qcow2') | Should -Match 'baseline disk'
        Test-Path -LiteralPath (Join-Path $script:Vms 'test-01') | Should -BeFalse
    }
    It 'refuses a rebuild into a directory another domain still uses, before any file in it changes' {
        $script:Domain['other'] = "<domain><name>other</name><devices><disk><source file='$($script:Vms)/test-01/shared.qcow2'/></disk></devices></domain>"
        Set-Content -LiteralPath (Join-Path $script:Vms 'test-01/shared.qcow2') -Value 'shared disk'
        { InModuleScope Yuruna.Host { Remove-KvmDomainDefinition -VMName 'test-01' -Confirm:$false } } |
            Should -Throw -ExpectedMessage '*test-01*'
        Get-Content -Raw -LiteralPath (Join-Path $script:Vms 'test-01/test-01.qcow2') | Should -Match 'baseline disk'
        Get-Content -Raw -LiteralPath (Join-Path $script:Vms 'test-01/shared.qcow2') | Should -Match 'shared disk'
    }
    It 'refuses a rebuild when the slot directory''s use cannot be read' {
        $script:BlockListFails = $true
        { InModuleScope Yuruna.Host { Remove-KvmDomainDefinition -VMName 'test-01' -Confirm:$false } } | Should -Throw
        Test-Path -LiteralPath (Join-Path $script:Vms 'test-01/test-01.qcow2') | Should -BeTrue
    }
    It 'rebuilds into a slot directory nothing else uses' {
        $script:Domain = @{}
        { InModuleScope Yuruna.Host { Remove-KvmDomainDefinition -VMName 'test-01' -Confirm:$false } } | Should -Not -Throw
        Test-Path -LiteralPath (Join-Path $script:Vms 'test-01/test-01.qcow2') | Should -BeTrue -Because 'the builder, not this call, replaces the slot''s own files'
    }
}

Describe 'KVM rename back to the name a domain had restores its address' {
    # A snapshot save that fails renames its guest back. A domain whose NIC is
    # pinned to the identity it was promoted to carries, on the way back, the
    # address the name being left derives.
    BeforeEach {
        $script:Vms = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Slot = 'test-guest.ubuntu.server.24-01'
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Vms $script:Slot) -Force
        Set-Content -LiteralPath (Join-Path $script:Vms "$($script:Slot)/$($script:Slot).qcow2") -Value 'disk'
        InModuleScope Yuruna.Host -Parameters @{ Vms = $script:Vms } { param($Vms) $script:VmRootDir = $Vms }
        $ledger = Get-Variable -Name 'YurunaRenameMacLedger' -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if ($ledger) { $ledger.Clear() }
        $script:Identity = (Get-YurunaGuestMacAddress -VMName 'amisad-build').ToLowerInvariant()
        # domrename already ran: the definition answers to the promoted name.
        $script:Domain = @{ 'amisad-build' = "<domain><name>amisad-build</name><devices><disk><source file='$($script:Vms)/$($script:Slot)/$($script:Slot).qcow2'/></disk><interface type='network'><mac address='$($script:Identity)'/></interface></devices></domain>" }
        Mock -ModuleName Yuruna.Host Invoke-Virsh {
            $global:LASTEXITCODE = 0
            if ($VirshArgs[0] -eq 'dumpxml') { return @($script:Domain[$VirshArgs[1]]) }
            if ($VirshArgs[0] -eq 'define') {
                $xml = Get-Content -Raw -LiteralPath $VirshArgs[1]
                $script:Domain[[regex]::Match($xml, '<name>([^<]+)</name>').Groups[1].Value] = $xml
            }
            return @()
        }
        Mock -ModuleName Yuruna.Host Write-Warning { }
        Mock -ModuleName Yuruna.Host Write-Information { }
    }

    It 'keeps a domain pinned to its promoted identity on its own address, there and back' {
        InModuleScope Yuruna.Host -Parameters @{ Slot = $script:Slot } { param($Slot) Complete-KvmDomainRename -VMName $Slot -NewName 'amisad-build' -Confirm:$false } | Should -BeTrue
        $script:Domain['amisad-build'] | Should -Match "<mac address='$($script:Identity)'/>"
        # The rename back: domrename again, then its completion.
        $back = $script:Domain['amisad-build'] -replace '<name>amisad-build</name>', "<name>$($script:Slot)</name>"
        $null = $script:Domain.Remove('amisad-build')
        $script:Domain[$script:Slot] = $back
        InModuleScope Yuruna.Host -Parameters @{ Slot = $script:Slot } { param($Slot) Complete-KvmDomainRename -VMName 'amisad-build' -NewName $Slot -Confirm:$false } | Should -BeTrue
        $script:Domain[$script:Slot] | Should -Match "<mac address='$($script:Identity)'/>"
        $script:Domain[$script:Slot] | Should -Match ([regex]::Escape("$($script:Vms)/$($script:Slot)/$($script:Slot).qcow2"))
    }
}

Describe 'Hyper-V storage is deleted only when no registered VM uses it' {
    BeforeAll {
        $hostFile = Join-Path $script:RepoRoot 'host/windows.hyper-v/modules/Yuruna.Host.psm1'
        $ast = Get-YurunaTestFileAst -Path $hostFile
        $script:HyperVHelpers = (@('Get-HyperVDirectoryDiskOwner', 'Repair-HyperVVMStorageLocation', 'Test-HyperVDirectoryFreeToDelete',
                'Repair-VMStorageLocation', 'Remove-HyperVGuestDefinition', 'Rename-VM', 'Invoke-HyperVLifecycleCmdlet') |
            ForEach-Object { (Get-YurunaTestFunctionAst -Ast $ast -Name $_).Extent.Text }) -join "`n"
        # A lifecycle cmdlet runs in a child pwsh on a host; here it runs in
        # this runspace, where the stand-in Hyper-V module answers it.
        $script:HyperVHelpers += @'

function Invoke-HyperVBoundedCall {
    param([scriptblock]$ScriptBlock, [object[]]$ArgumentList = @(), [int]$TimeoutSeconds)
    $null = $TimeoutSeconds
    try { @{ TimedOut = $false; Error = $null; Output = @(& $ScriptBlock @ArgumentList) } }
    catch { @{ TimedOut = $false; Error = $_; Output = @() } }
}
'@
        $script:RemoveBody = (Get-YurunaTestFunctionAst -Ast $ast -Name 'Remove-HyperVTestVM').Extent.Text
    }
    BeforeEach {
        $global:__HyperV = @{
            Disks = @{ 'snap-base' = @('C:\VHD\test-01\test-01.vhdx') }
            Mac = (Get-YurunaGuestMacAddress -VMName 'test-01')
            Moves = [System.Collections.Generic.List[string]]::new()
            StaticMac = ''
            Renames = [System.Collections.Generic.List[string]]::new()
            Removed = [System.Collections.Generic.List[string]]::new()
            Dirs = @{}
            # A resolved VM is removed by its Id.
            Ids = @{ 'test-01' = [guid]'5b1f0d8e-3c2a-4e6f-9a7b-1c2d3e4f5a6b' }
        }
        # Built from text so the stand-in cmdlets are not read as this suite's own functions.
        $fakeHyperV = @'
            function Get-VMHost { [pscustomobject]@{ VirtualHardDiskPath = 'C:\VHD' } }
            function Get-VM {
                param($Name, $Id)
                if ($Id) {
                    $named = @($global:__HyperV.Ids.Keys | Where-Object { $global:__HyperV.Ids[$_] -eq $Id })
                    if ($named) { return [pscustomobject]@{ Name = $named[0]; State = 'Off'; Id = $Id } }
                    throw "No VM has Id $Id"
                }
                if ($Name) { [pscustomobject]@{ Name = $Name; State = 'Off' } } else { $global:__HyperV.Disks.Keys | ForEach-Object { [pscustomobject]@{ Name = $_; State = 'Off' } } }
            }
            function Get-VMHardDiskDrive { param($VMName, $VMCheckpoint) if ($VMCheckpoint) { return @() }; @($global:__HyperV.Disks[$VMName]) | ForEach-Object { [pscustomobject]@{ Path = $_ } } }
            function Get-VMSnapshot { param($VMName) @() }
            function Get-VMNetworkAdapter { param($VMName) [pscustomobject]@{ MacAddress = ($global:__HyperV.Mac -replace ':', '') } }
            function Set-VMNetworkAdapter { param([Parameter(ValueFromPipeline)]$InputObject, $StaticMacAddress) process { $global:__HyperV.StaticMac = $StaticMacAddress } }
            function Move-VMStorage {
                param($VMName, $DestinationStoragePath, [switch]$Confirm)
                $global:__HyperV.Moves.Add("$VMName->$DestinationStoragePath")
                $global:__HyperV.Disks[$VMName] = @("$DestinationStoragePath\$VMName.vhdx")
            }
            function Rename-VM { param($Name, $NewName, [switch]$Confirm) $global:__HyperV.Renames.Add("$Name->$NewName") }
            function Stop-VM { param($VM, [switch]$Force) }
            function Remove-VM { param($VM, [switch]$Force) $global:__HyperV.Removed.Add([string]$VM.Name); $global:__HyperV.Disks.Remove([string]$VM.Name) }
            Export-ModuleMember -Function *
'@
        New-Module -Name 'Hyper-V' -ScriptBlock ([scriptblock]::Create($fakeHyperV)) | Import-Module -Force
        $WarningPreference = 'SilentlyContinue'
        . ([scriptblock]::Create($script:HyperVHelpers))
    }
    AfterEach {
        Remove-Module -Name 'Hyper-V' -Force -ErrorAction SilentlyContinue
        Remove-Variable -Name __HyperV -Scope Global -ErrorAction SilentlyContinue
    }

    It 'moves a promoted VM''s storage out of the vacated directory, re-pinning only the vacated address, before the directory may go' {
        Test-HyperVDirectoryFreeToDelete -Directory 'C:\VHD\test-01' | Should -BeTrue
        @($global:__HyperV.Moves) | Should -Be @('snap-base->C:\VHD\snap-base')
        $global:__HyperV.StaticMac | Should -Be ((Get-YurunaGuestMacAddress -VMName 'snap-base') -replace ':', '')
    }
    It 'leaves a VM already on its own identity on the address it has' {
        $global:__HyperV.Mac = '00:15:5d:01:02:03'
        Test-HyperVDirectoryFreeToDelete -Directory 'C:\VHD\test-01' | Should -BeTrue
        $global:__HyperV.StaticMac | Should -Be ''
    }
    It 'keeps a directory whose disks another VM also uses' {
        $global:__HyperV.Disks['other'] = @('C:\VHD\test-01\shared.vhdx')
        Test-HyperVDirectoryFreeToDelete -Directory 'C:\VHD\test-01' | Should -BeFalse
        $global:__HyperV.Moves.Count | Should -Be 0
    }
    It 'gates the removal of a VM directory on that check' {
        $script:RemoveBody | Should -Match 'Test-HyperVDirectoryFreeToDelete -Directory \$vmDir'
        $gate = $script:RemoveBody.IndexOf('Test-HyperVDirectoryFreeToDelete')
        $delete = $script:RemoveBody.IndexOf('Remove-Item -LiteralPath $vmDir -Recurse')
        ($gate -ge 0 -and $delete -gt $gate) | Should -BeTrue
    }

    Context 'with Windows path semantics' {
        BeforeEach {
            # The helpers join and probe VirtualHardDiskPath the way Windows does;
            # these stand-ins keep the fixture's C:\ paths meaningful on any host.
            # Built from text, like the stand-in module, so they shadow the
            # cmdlets for the dot-sourced helpers without being this suite's own.
            . ([scriptblock]::Create(@'
                function Join-Path { param($Path, $ChildPath) "$(([string]$Path).TrimEnd('\'))\$ChildPath" }
                function Test-Path { param($LiteralPath) $global:__HyperV.Dirs.ContainsKey([string]$LiteralPath) }
                function Get-ChildItem { [CmdletBinding()] param($LiteralPath, [switch]$Recurse, [switch]$File, [switch]$Force) @($global:__HyperV.Dirs[[string]$LiteralPath]) | Where-Object { $_ } }
                function Resolve-HyperVVM { param($VMName) if ($global:__HyperV.Present -contains $VMName) { @{ Presence = 'present'; VM = [pscustomobject]@{ Name = $VMName; State = 'Off'; Id = $global:__HyperV.Ids[$VMName] } } } else { @{ Presence = 'absent' } } }
'@))
            $global:__HyperV.Present = @()
            $global:__HyperV.Dirs['C:\VHD\test-01'] = @('test-01.vhdx')
        }

        It 'finishes every interrupted rename at once, with no delete to trigger it' {
            @(Repair-VMStorageLocation -Confirm:$false).Count | Should -Be 0
            @($global:__HyperV.Moves) | Should -Be @('snap-base->C:\VHD\snap-base')
        }
        It 'names a VM it cannot repair now and leaves its storage where it is' {
            $global:__HyperV.Disks['other'] = @('C:\VHD\test-01\shared.vhdx')
            @(Repair-VMStorageLocation -Confirm:$false | Sort-Object) | Should -Be @('other', 'snap-base')
            $global:__HyperV.Moves.Count | Should -Be 0
        }
        It 'finishes the interrupted rename before a rebuild into the vacated slot, with no VM of that name left' {
            { Remove-HyperVGuestDefinition -VMName 'test-01' -Confirm:$false } | Should -Not -Throw
            @($global:__HyperV.Moves) | Should -Be @('snap-base->C:\VHD\snap-base')
        }
        It 'removes the slot''s own VM and refuses the rebuild while another VM still uses the directory' {
            $global:__HyperV.Present = @('test-01')
            $global:__HyperV.Disks['test-01'] = @('C:\VHD\test-01\test-01.vhdx')
            $global:__HyperV.Disks['other'] = @('C:\VHD\test-01\shared.vhdx')
            { Remove-HyperVGuestDefinition -VMName 'test-01' -Confirm:$false } | Should -Throw -ExpectedMessage '*test-01*'
            @($global:__HyperV.Removed) | Should -Be @('test-01')
            $global:__HyperV.Moves.Count | Should -Be 0 -Because 'a directory two VMs share is not one rename''s to move'
        }
        It 'refuses a rename into a directory that already holds files, before the registration moves' {
            $global:__HyperV.Present = @('test-01')
            $global:__HyperV.Dirs['C:\VHD\snap-next'] = @('test-01.vhdx')
            Rename-VM -VMName 'test-01' -NewName 'snap-next' -Confirm:$false | Should -BeFalse
            $global:__HyperV.Renames.Count | Should -Be 0
            $global:__HyperV.Moves.Count | Should -Be 0
        }
        It 'renames into an empty or missing destination directory' {
            $global:__HyperV.Present = @('test-01')
            $global:__HyperV.Dirs['C:\VHD\snap-next'] = @()
            Rename-VM -VMName 'test-01' -NewName 'snap-next' -Confirm:$false | Should -BeTrue
            @($global:__HyperV.Renames) | Should -Be @('test-01->snap-next')
        }
    }
}

Describe 'the KVM orphan sweep keeps a directory a defined domain still uses' {
    BeforeAll {
        $source = Get-Content -Raw -LiteralPath (Join-Path $script:RepoRoot 'host/ubuntu.kvm/Remove-OrphanedVMFiles.ps1')
        $script:SweepTail = $source.Substring($source.IndexOf('# --- REGION: Collect the disks registered domains use', [StringComparison]::Ordinal))
    }
    It 'deletes only the unreferenced orphan when <Case>' -ForEach @(
        @{ Case = 'every domain answers'; Fail = $false; Expected = 0; StaleKept = $false }
        @{ Case = 'a domain cannot be read'; Fail = $true; Expected = 1; StaleKept = $true }
    ) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($dir in 'test-01', 'stale-02') { $null = New-Item -ItemType Directory -Path (Join-Path $root $dir) -Force; Set-Content -LiteralPath (Join-Path $root "$dir/$dir.qcow2") -Value 'disk' }
        $fixture = @'
param([string]$Root, [string]$Fail)
$ErrorActionPreference = 'Stop'
$Force = $true
$vmRoot = $Root
$virshUri = 'fixture'
$registered = @{ 'snap-base' = $true }
function Format-YurunaOperatorMessage { param($Key, $Arguments, $FormatValues, $FormatBindings); return $Key }
function Write-CleanupMessage { param($Message) }
function Get-VMFolderSize { param($Path) return [int64]1 }
function virsh {
    if ($args -contains 'domblklist') {
        if ($Fail -eq 'True') { $global:LASTEXITCODE = 1; return 'error: failed to connect' }
        $global:LASTEXITCODE = 0
        return @(' Type   Device   Target   Source', '----', " file   disk     vda      $Root/test-01/test-01.qcow2")
    }
    $global:LASTEXITCODE = 1
    return 'error: failed to get domain'
}
'@
        $path = Join-Path $root 'sweep.ps1'
        [IO.File]::WriteAllText($path, $fixture + "`n" + $script:SweepTail)
        $output = & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -File $path -Root $root -Fail "$Fail" 2>&1
        $LASTEXITCODE | Should -Be $Expected -Because (($output | Out-String).Trim())
        Test-Path -LiteralPath (Join-Path $root 'test-01/test-01.qcow2') | Should -BeTrue -Because 'a defined domain uses it'
        Test-Path -LiteralPath (Join-Path $root 'stale-02') | Should -Be $StaleKept
    }
}
