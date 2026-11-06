# Compute diagram

The `compute:` namespace, `https://yuruna.com/ontology/2026/10/compute#`, holds
the computing vocabulary: physical and virtual machines, hypervisors, operating
systems, firmware, processors, memory, disks, images, snapshots, and guest
provisioning. This page draws the compute namespace: its classes, the object
properties declared in it, and the existential restrictions on those classes,
from version 2026/10 of the [Yuruna ontology](../yuruna.owl).

Circles are classes drawn on this page and boxes are classes drawn on another
page. A `subClassOf` arrow points from a class to its parent. An arrow labeled
with a property runs from its domain to its range. A frame titled Restriction is
an existential restriction on the class whose `subClassOf` arrow points at it:
each instance of that class has at least one value of the boxed property in the
circled class.

```mermaid
%%{init: {"flowchart": {"useMaxWidth": 0}}}%%
graph LR
classDef Datatype fill:#9c6,stroke:#9c6;
compute:AMD64Architecture((compute:AMD64Architecture)) -- subClassOf --> compute:ProcessorArchitecture((compute:ProcessorArchitecture))
compute:ARM64Architecture((compute:ARM64Architecture)) -- subClassOf --> compute:ProcessorArchitecture((compute:ProcessorArchitecture))
compute:AmazonLinuxOperatingSystem((compute:AmazonLinuxOperatingSystem)) -- subClassOf --> compute:LinuxOperatingSystem((compute:LinuxOperatingSystem))
compute:AppleVirtualizationFramework((compute:AppleVirtualizationFramework)) -- subClassOf --> y:SystemElement[y:SystemElement]
compute:ArchitectureCompatibility((compute:ArchitectureCompatibility)) -- subClassOf --> y:Situation[y:Situation]
compute:Autoinstall((compute:Autoinstall)) -- subClassOf --> y:Process[y:Process]
compute:BackingImage((compute:BackingImage)) -- subClassOf --> compute:DiskImage((compute:DiskImage))
compute:ClockSkew((compute:ClockSkew)) -- subClassOf --> y:Situation[y:Situation]
compute:CloudImage((compute:CloudImage)) -- subClassOf --> compute:InstallationImage((compute:InstallationImage))
compute:CloudInitConfiguration((compute:CloudInitConfiguration)) -- subClassOf --> y:ConfigurationArtifact[y:ConfigurationArtifact]
compute:CloudInitOverlay((compute:CloudInitOverlay)) -- subClassOf --> y:ConfigurationArtifact[y:ConfigurationArtifact]
compute:CloudInitSeed((compute:CloudInitSeed)) -- subClassOf --> y:ConfigurationArtifact[y:ConfigurationArtifact]
compute:CommittedMemory((compute:CommittedMemory)) -- subClassOf --> y:Quantity[y:Quantity]
compute:ComputingNode -- compute:hasInterface --> network:NetworkInterface
compute:ComputingNode -- compute:hosts --> y:SystemElement
compute:ComputingNode -- compute:runsOperatingSystem --> compute:OperatingSystem
compute:ComputingNode((compute:ComputingNode)) -- subClassOf --> y:SystemElement[y:SystemElement]
compute:DifferencingDisk((compute:DifferencingDisk)) -- subClassOf --> compute:VirtualDisk((compute:VirtualDisk))
compute:DiskImage((compute:DiskImage)) -- subClassOf --> y:Artifact[y:Artifact]
compute:DiskSnapshot((compute:DiskSnapshot)) -- subClassOf --> compute:Snapshot((compute:Snapshot))
compute:DisplayBackend((compute:DisplayBackend)) -- subClassOf --> y:SystemElement[y:SystemElement]
compute:DisplayContextFailure((compute:DisplayContextFailure)) -- subClassOf --> compute:ProvisioningFailure((compute:ProvisioningFailure))
compute:EndOfFile((compute:EndOfFile)) -- subClassOf --> y:State[y:State]
compute:FileDescriptor((compute:FileDescriptor)) -- subClassOf --> y:Identifier[y:Identifier]
compute:Firmware((compute:Firmware)) -- subClassOf --> y:SystemElement[y:SystemElement]
compute:Framebuffer((compute:Framebuffer)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
compute:GraphicsConfigurationCheck((compute:GraphicsConfigurationCheck)) -- subClassOf --> diagnostics:DiagnosticCheck[diagnostics:DiagnosticCheck]
compute:GraphicsDeviceModel((compute:GraphicsDeviceModel)) -- subClassOf --> y:ConfigurationArtifact[y:ConfigurationArtifact]
compute:Guest((compute:Guest)) -- subClassOf --> compute:VirtualMachine((compute:VirtualMachine))
compute:Guest((compute:Guest)) -- subClassOf --> r_Guest_hostedBy_Host_((Anonymous class))
compute:Guest((compute:Guest)) -- subClassOf --> r_Guest_managedByHypervisor_Hypervisor_((Anonymous class))
compute:Guest((compute:Guest)) -- subClassOf --> r_Guest_runsOperatingSystem_GuestOperatingSystem_((Anonymous class))
compute:GuestIdentity((compute:GuestIdentity)) -- subClassOf --> y:Identifier[y:Identifier]
compute:GuestKernelStall((compute:GuestKernelStall)) -- subClassOf --> y:Situation[y:Situation]
compute:GuestOperatingSystem((compute:GuestOperatingSystem)) -- subClassOf --> compute:OperatingSystem((compute:OperatingSystem))
compute:GuestProcessCheck((compute:GuestProcessCheck)) -- subClassOf --> diagnostics:DiagnosticCheck[diagnostics:DiagnosticCheck]
compute:Host((compute:Host)) -- subClassOf --> compute:ComputingNode((compute:ComputingNode))
compute:Host((compute:Host)) -- subClassOf --> r_Host_runsOperatingSystem_HostOperatingSystem_((Anonymous class))
compute:HostIdentity((compute:HostIdentity)) -- subClassOf --> y:Identifier[y:Identifier]
compute:HostOperatingSystem((compute:HostOperatingSystem)) -- subClassOf --> compute:OperatingSystem((compute:OperatingSystem))
compute:HyperV((compute:HyperV)) -- subClassOf --> compute:Hypervisor((compute:Hypervisor))
compute:Hypervisor((compute:Hypervisor)) -- subClassOf --> y:SystemElement[y:SystemElement]
compute:HypervisorUnresponsiveFailure((compute:HypervisorUnresponsiveFailure)) -- subClassOf --> diagnostics:InfrastructureFailure[diagnostics:InfrastructureFailure]
compute:ISOImage((compute:ISOImage)) -- subClassOf --> compute:InstallationImage((compute:InstallationImage))
compute:ImageArchitectureMismatch((compute:ImageArchitectureMismatch)) -- subClassOf --> compute:ProvisioningFailure((compute:ProvisioningFailure))
compute:InstallationImage((compute:InstallationImage)) -- subClassOf --> y:Artifact[y:Artifact]
compute:KVM((compute:KVM)) -- subClassOf --> compute:Hypervisor((compute:Hypervisor))
compute:Libvirt((compute:Libvirt)) -- subClassOf --> y:SystemElement[y:SystemElement]
compute:LinuxOperatingSystem((compute:LinuxOperatingSystem)) -- subClassOf --> compute:OperatingSystem((compute:OperatingSystem))
compute:MacOSOperatingSystem((compute:MacOSOperatingSystem)) -- subClassOf --> compute:OperatingSystem((compute:OperatingSystem))
compute:MachineIdentifier((compute:MachineIdentifier)) -- subClassOf --> y:Identifier[y:Identifier]
compute:Memory((compute:Memory)) -- subClassOf --> y:SystemElement[y:SystemElement]
compute:MemoryExhaustion((compute:MemoryExhaustion)) -- subClassOf --> diagnostics:Failure[diagnostics:Failure]
compute:MemoryHeadroom((compute:MemoryHeadroom)) -- subClassOf --> y:Quantity[y:Quantity]
compute:NestedHost((compute:NestedHost)) -- subClassOf --> compute:Guest((compute:Guest))
compute:NestedHost((compute:NestedHost)) -- subClassOf --> compute:Host((compute:Host))
compute:NestedVirtualization((compute:NestedVirtualization)) -- subClassOf --> y:Process[y:Process]
compute:OpenGLContext((compute:OpenGLContext)) -- subClassOf --> y:SystemElement[y:SystemElement]
compute:OperatingSystem((compute:OperatingSystem)) -- subClassOf --> y:SystemElement[y:SystemElement]
compute:PhysicalMachine((compute:PhysicalMachine)) -- subClassOf --> compute:ComputingNode((compute:ComputingNode))
compute:ProcessTree((compute:ProcessTree)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
compute:ProcessWaitCheck((compute:ProcessWaitCheck)) -- subClassOf --> diagnostics:DiagnosticCheck[diagnostics:DiagnosticCheck]
compute:Processor((compute:Processor)) -- subClassOf --> y:SystemElement[y:SystemElement]
compute:ProcessorArchitecture((compute:ProcessorArchitecture)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
compute:Provisioning((compute:Provisioning)) -- subClassOf --> y:Process[y:Process]
compute:ProvisioningFailure((compute:ProvisioningFailure)) -- subClassOf --> diagnostics:InfrastructureFailure[diagnostics:InfrastructureFailure]
compute:PseudoTerminal((compute:PseudoTerminal)) -- subClassOf --> y:SystemElement[y:SystemElement]
compute:QEMU((compute:QEMU)) -- subClassOf --> y:SystemElement[y:SystemElement]
compute:ResidentMemory((compute:ResidentMemory)) -- subClassOf --> y:Quantity[y:Quantity]
compute:SecureBoot((compute:SecureBoot)) -- subClassOf --> y:Process[y:Process]
compute:SeedImage((compute:SeedImage)) -- subClassOf --> y:Artifact[y:Artifact]
compute:ServiceGuest((compute:ServiceGuest)) -- subClassOf --> compute:Guest((compute:Guest))
compute:ServiceGuest((compute:ServiceGuest)) -- subClassOf --> r_ServiceGuest_hosts_SoftwareService_((Anonymous class))
compute:Snapshot((compute:Snapshot)) -- subClassOf --> y:Artifact[y:Artifact]
compute:SnapshotManifest((compute:SnapshotManifest)) -- subClassOf --> y:ConfigurationArtifact[y:ConfigurationArtifact]
compute:TPM((compute:TPM)) -- subClassOf --> y:SystemElement[y:SystemElement]
compute:TestGuest((compute:TestGuest)) -- subClassOf --> compute:Guest((compute:Guest))
compute:UEFI((compute:UEFI)) -- subClassOf --> compute:Firmware((compute:Firmware))
compute:UTM((compute:UTM)) -- subClassOf --> y:SystemElement[y:SystemElement]
compute:UbuntuOperatingSystem((compute:UbuntuOperatingSystem)) -- subClassOf --> compute:LinuxOperatingSystem((compute:LinuxOperatingSystem))
compute:VMAdmission((compute:VMAdmission)) -- subClassOf --> y:Process[y:Process]
compute:VMNotStoppedFailure((compute:VMNotStoppedFailure)) -- subClassOf --> testing:SequenceFailure[testing:SequenceFailure]
compute:VirtualDisk((compute:VirtualDisk)) -- subClassOf --> y:SystemElement[y:SystemElement]
compute:VirtualMachine -- compute:managedByHypervisor --> compute:Hypervisor
compute:VirtualMachine((compute:VirtualMachine)) -- subClassOf --> compute:ComputingNode((compute:ComputingNode))
compute:VirtualProcessor((compute:VirtualProcessor)) -- subClassOf --> y:SystemElement[y:SystemElement]
compute:VirtualizationExtension((compute:VirtualizationExtension)) -- subClassOf --> y:SystemElement[y:SystemElement]
compute:WaitChannel((compute:WaitChannel)) -- subClassOf --> diagnostics:DiagnosticEvidence[diagnostics:DiagnosticEvidence]
compute:WindowsOperatingSystem((compute:WindowsOperatingSystem)) -- subClassOf --> compute:OperatingSystem((compute:OperatingSystem))
subgraph r_Guest_hostedBy_Host_[Restriction &exist; R C]
r_Guest_hostedBy_Host_thing((thing)) --> r_Guest_hostedBy_Host_compute:hostedBy[compute:hostedBy]
r_Guest_hostedBy_Host_compute:hostedBy[compute:hostedBy]
-- some --> r_Guest_hostedBy_Host_compute:Host((compute:Host))
end
subgraph r_Guest_managedByHypervisor_Hypervisor_[Restriction &exist; R C]
r_Guest_managedByHypervisor_Hypervisor_thing((thing)) --> r_Guest_managedByHypervisor_Hypervisor_compute:managedByHypervisor[compute:managedByHypervisor]
r_Guest_managedByHypervisor_Hypervisor_compute:managedByHypervisor[compute:managedByHypervisor]
-- some --> r_Guest_managedByHypervisor_Hypervisor_compute:Hypervisor((compute:Hypervisor))
end
subgraph r_Guest_runsOperatingSystem_GuestOperatingSystem_[Restriction &exist; R C]
r_Guest_runsOperatingSystem_GuestOperatingSystem_thing((thing)) --> r_Guest_runsOperatingSystem_GuestOperatingSystem_compute:runsOperatingSystem[compute:runsOperatingSystem]
r_Guest_runsOperatingSystem_GuestOperatingSystem_compute:runsOperatingSystem[compute:runsOperatingSystem]
-- some --> r_Guest_runsOperatingSystem_GuestOperatingSystem_compute:GuestOperatingSystem((compute:GuestOperatingSystem))
end
subgraph r_Host_runsOperatingSystem_HostOperatingSystem_[Restriction &exist; R C]
r_Host_runsOperatingSystem_HostOperatingSystem_thing((thing)) --> r_Host_runsOperatingSystem_HostOperatingSystem_compute:runsOperatingSystem[compute:runsOperatingSystem]
r_Host_runsOperatingSystem_HostOperatingSystem_compute:runsOperatingSystem[compute:runsOperatingSystem]
-- some --> r_Host_runsOperatingSystem_HostOperatingSystem_compute:HostOperatingSystem((compute:HostOperatingSystem))
end
subgraph r_ServiceGuest_hosts_SoftwareService_[Restriction &exist; R C]
r_ServiceGuest_hosts_SoftwareService_thing((thing)) --> r_ServiceGuest_hosts_SoftwareService_compute:hosts[compute:hosts]
r_ServiceGuest_hosts_SoftwareService_compute:hosts[compute:hosts]
-- some --> r_ServiceGuest_hosts_SoftwareService_y:SoftwareService((y:SoftwareService))
end
y:SystemElement -- compute:hostedBy --> compute:ComputingNode
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.11.05

Back to [Yuruna ontology diagrams](../../../README.md#425aed30-0005)
