# System element diagram

`y:SystemElement` is a hardware, software, or logical part of a computing
installation that can participate in an operational relationship. This page
draws it from version 2026/10 of the [Yuruna ontology](../yuruna.owl): the
classes under it, the object properties whose `rdfs:domain` is one of those
classes, and their existential restrictions.

Circles are classes. A `subClassOf` arrow points from a class to its parent,
which can be drawn on another page. An arrow labeled with a property runs from
its domain to its range; a range class drawn as a box belongs to another page. A
frame titled Restriction is an existential restriction on the class whose
`subClassOf` arrow points at it: each instance of that class has at least one
value of the boxed property in the circled class.

```mermaid
%%{init: {"flowchart": {"useMaxWidth": 0}}}%%
graph LR
classDef Datatype fill:#9c6,stroke:#9c6;
subgraph r_ApplicationWorkload_usesComponent_DeployableComponent_[Restriction &exist; R C]
r_ApplicationWorkload_usesComponent_DeployableComponent_thing((thing)) --> r_ApplicationWorkload_usesComponent_DeployableComponent_y:usesComponent[y:usesComponent]
r_ApplicationWorkload_usesComponent_DeployableComponent_y:usesComponent[y:usesComponent]
-- some --> r_ApplicationWorkload_usesComponent_DeployableComponent_y:DeployableComponent((y:DeployableComponent))
end
subgraph r_Guest_hostedBy_Host_[Restriction &exist; R C]
r_Guest_hostedBy_Host_thing((thing)) --> r_Guest_hostedBy_Host_y:hostedBy[y:hostedBy]
r_Guest_hostedBy_Host_y:hostedBy[y:hostedBy]
-- some --> r_Guest_hostedBy_Host_y:Host((y:Host))
end
subgraph r_Guest_managedByHypervisor_Hypervisor_[Restriction &exist; R C]
r_Guest_managedByHypervisor_Hypervisor_thing((thing)) --> r_Guest_managedByHypervisor_Hypervisor_y:managedByHypervisor[y:managedByHypervisor]
r_Guest_managedByHypervisor_Hypervisor_y:managedByHypervisor[y:managedByHypervisor]
-- some --> r_Guest_managedByHypervisor_Hypervisor_y:Hypervisor((y:Hypervisor))
end
subgraph r_Guest_runsOperatingSystem_GuestOperatingSystem_[Restriction &exist; R C]
r_Guest_runsOperatingSystem_GuestOperatingSystem_thing((thing)) --> r_Guest_runsOperatingSystem_GuestOperatingSystem_y:runsOperatingSystem[y:runsOperatingSystem]
r_Guest_runsOperatingSystem_GuestOperatingSystem_y:runsOperatingSystem[y:runsOperatingSystem]
-- some --> r_Guest_runsOperatingSystem_GuestOperatingSystem_y:GuestOperatingSystem((y:GuestOperatingSystem))
end
subgraph r_Host_runsOperatingSystem_HostOperatingSystem_[Restriction &exist; R C]
r_Host_runsOperatingSystem_HostOperatingSystem_thing((thing)) --> r_Host_runsOperatingSystem_HostOperatingSystem_y:runsOperatingSystem[y:runsOperatingSystem]
r_Host_runsOperatingSystem_HostOperatingSystem_y:runsOperatingSystem[y:runsOperatingSystem]
-- some --> r_Host_runsOperatingSystem_HostOperatingSystem_y:HostOperatingSystem((y:HostOperatingSystem))
end
subgraph r_KubernetesPod_hasPart_Container_[Restriction &exist; R C]
r_KubernetesPod_hasPart_Container_thing((thing)) --> r_KubernetesPod_hasPart_Container_y:hasPart[y:hasPart]
r_KubernetesPod_hasPart_Container_y:hasPart[y:hasPart]
-- some --> r_KubernetesPod_hasPart_Container_y:Container((y:Container))
end
subgraph r_SequenceHandler_implementsAction_SequenceAction_[Restriction &exist; R C]
r_SequenceHandler_implementsAction_SequenceAction_thing((thing)) --> r_SequenceHandler_implementsAction_SequenceAction_y:implementsAction[y:implementsAction]
r_SequenceHandler_implementsAction_SequenceAction_y:implementsAction[y:implementsAction]
-- some --> r_SequenceHandler_implementsAction_SequenceAction_y:SequenceAction((y:SequenceAction))
end
subgraph r_ServiceGuest_hosts_SoftwareService_[Restriction &exist; R C]
r_ServiceGuest_hosts_SoftwareService_thing((thing)) --> r_ServiceGuest_hosts_SoftwareService_y:hosts[y:hosts]
r_ServiceGuest_hosts_SoftwareService_y:hosts[y:hosts]
-- some --> r_ServiceGuest_hosts_SoftwareService_y:SoftwareService((y:SoftwareService))
end
subgraph r_TestRunner_executesPlan_TestPlan_[Restriction &exist; R C]
r_TestRunner_executesPlan_TestPlan_thing((thing)) --> r_TestRunner_executesPlan_TestPlan_y:executesPlan[y:executesPlan]
r_TestRunner_executesPlan_TestPlan_y:executesPlan[y:executesPlan]
-- some --> r_TestRunner_executesPlan_TestPlan_y:TestPlan((y:TestPlan))
end
subgraph r_VNCTransport_usesProtocol_RemoteFramebufferProtocol_[Restriction &exist; R C]
r_VNCTransport_usesProtocol_RemoteFramebufferProtocol_thing((thing)) --> r_VNCTransport_usesProtocol_RemoteFramebufferProtocol_y:usesProtocol[y:usesProtocol]
r_VNCTransport_usesProtocol_RemoteFramebufferProtocol_y:usesProtocol[y:usesProtocol]
-- some --> r_VNCTransport_usesProtocol_RemoteFramebufferProtocol_y:RemoteFramebufferProtocol((y:RemoteFramebufferProtocol))
end
y:AmazonLinuxOperatingSystem((y:AmazonLinuxOperatingSystem)) -- subClassOf --> y:LinuxOperatingSystem((y:LinuxOperatingSystem))
y:AmisAdConnector((y:AmisAdConnector)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdConnector((y:AmisAdConnector)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:AmisAdCoordinator((y:AmisAdCoordinator)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdCoordinator((y:AmisAdCoordinator)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:AmisAdMatchingFabric((y:AmisAdMatchingFabric)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdMatchingFabric((y:AmisAdMatchingFabric)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:AmisAdResource((y:AmisAdResource)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdResource((y:AmisAdResource)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:AmisAdSlice((y:AmisAdSlice)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdSlice((y:AmisAdSlice)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:AppleVirtualizationFramework((y:AppleVirtualizationFramework)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:ApplicationWorkload -- y:deployedFrom --> y:HelmChart
y:ApplicationWorkload -- y:usesComponent --> y:DeployableComponent
y:ApplicationWorkload((y:ApplicationWorkload)) -- subClassOf --> r_ApplicationWorkload_usesComponent_DeployableComponent_((Anonymous class))
y:ApplicationWorkload((y:ApplicationWorkload)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:Bridge((y:Bridge)) -- subClassOf --> y:NetworkingResource((y:NetworkingResource))
y:BridgePort((y:BridgePort)) -- subClassOf --> y:NetworkingResource((y:NetworkingResource))
y:Cache((y:Cache)) -- subClassOf --> y:StorageResource((y:StorageResource))
y:CachingProxyService((y:CachingProxyService)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:CertificateAuthority((y:CertificateAuthority)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:CloudProvider((y:CloudProvider)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:ComputingNode -- y:hasInterface --> y:NetworkInterface
y:ComputingNode -- y:hosts --> y:SystemElement
y:ComputingNode -- y:runsOperatingSystem --> y:OperatingSystem
y:ComputingNode((y:ComputingNode)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:ConfigurationService((y:ConfigurationService)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:Container((y:Container)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:CredentialProvider((y:CredentialProvider)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:DHCPAddressPool((y:DHCPAddressPool)) -- subClassOf --> y:NetworkingResource((y:NetworkingResource))
y:DHCPClient((y:DHCPClient)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:DHCPServer((y:DHCPServer)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:DNSCache((y:DNSCache)) -- subClassOf --> y:Cache((y:Cache))
y:DNSResolver -- y:resolvesName --> y:Hostname
y:DNSResolver((y:DNSResolver)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:DeploymentResource((y:DeploymentResource)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:DeploymentTarget((y:DeploymentTarget)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:DifferencingDisk((y:DifferencingDisk)) -- subClassOf --> y:VirtualDisk((y:VirtualDisk))
y:DisplayBackend((y:DisplayBackend)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:Dnsmasq((y:Dnsmasq)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:DownloadAgentService((y:DownloadAgentService)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:DownloadPool((y:DownloadPool)) -- subClassOf --> y:StorageResource((y:StorageResource))
y:DurableStorage((y:DurableStorage)) -- subClassOf --> y:StorageResource((y:StorageResource))
y:Endpoint((y:Endpoint)) -- subClassOf --> y:NetworkingResource((y:NetworkingResource))
y:EphemeralStorage((y:EphemeralStorage)) -- subClassOf --> y:StorageResource((y:StorageResource))
y:ExtensionService((y:ExtensionService)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:FileSystem((y:FileSystem)) -- subClassOf --> y:StorageResource((y:StorageResource))
y:Firewall((y:Firewall)) -- subClassOf --> y:NetworkingResource((y:NetworkingResource))
y:Firmware((y:Firmware)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:ForwardProxy((y:ForwardProxy)) -- subClassOf --> y:Proxy((y:Proxy))
y:Forwarder((y:Forwarder)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:Gateway((y:Gateway)) -- subClassOf --> y:NetworkingResource((y:NetworkingResource))
y:Grafana((y:Grafana)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:Guest((y:Guest)) -- subClassOf --> r_Guest_hostedBy_Host_((Anonymous class))
y:Guest((y:Guest)) -- subClassOf --> r_Guest_managedByHypervisor_Hypervisor_((Anonymous class))
y:Guest((y:Guest)) -- subClassOf --> r_Guest_runsOperatingSystem_GuestOperatingSystem_((Anonymous class))
y:Guest((y:Guest)) -- subClassOf --> y:VirtualMachine((y:VirtualMachine))
y:GuestOperatingSystem((y:GuestOperatingSystem)) -- subClassOf --> y:OperatingSystem((y:OperatingSystem))
y:HTTPCache((y:HTTPCache)) -- subClassOf --> y:Cache((y:Cache))
y:HTTPConnectTunnel((y:HTTPConnectTunnel)) -- subClassOf --> y:NetworkingResource((y:NetworkingResource))
y:HelmRelease((y:HelmRelease)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:Host((y:Host)) -- subClassOf --> r_Host_runsOperatingSystem_HostOperatingSystem_((Anonymous class))
y:Host((y:Host)) -- subClassOf --> y:ComputingNode((y:ComputingNode))
y:HostIOProvider((y:HostIOProvider)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:HostOperatingSystem((y:HostOperatingSystem)) -- subClassOf --> y:OperatingSystem((y:OperatingSystem))
y:HostPool -- y:hasMember --> y:Host
y:HostPool((y:HostPool)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:HyperV((y:HyperV)) -- subClassOf --> y:Hypervisor((y:Hypervisor))
y:HyperVDefaultSwitch((y:HyperVDefaultSwitch)) -- subClassOf --> y:VirtualSwitch((y:VirtualSwitch))
y:HyperVExternalSwitch((y:HyperVExternalSwitch)) -- subClassOf --> y:VirtualSwitch((y:VirtualSwitch))
y:HyperVManagementAdapter((y:HyperVManagementAdapter)) -- subClassOf --> y:NetworkAdapter((y:NetworkAdapter))
y:HyperVManagementAdapter((y:HyperVManagementAdapter)) -- subClassOf --> y:VirtualNetworkInterface((y:VirtualNetworkInterface))
y:Hypervisor((y:Hypervisor)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:KVM((y:KVM)) -- subClassOf --> y:Hypervisor((y:Hypervisor))
y:KubernetesCluster((y:KubernetesCluster)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:KubernetesDeployment((y:KubernetesDeployment)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:KubernetesNode((y:KubernetesNode)) -- subClassOf --> y:ComputingNode((y:ComputingNode))
y:KubernetesPod((y:KubernetesPod)) -- subClassOf --> r_KubernetesPod_hasPart_Container_((Anonymous class))
y:KubernetesPod((y:KubernetesPod)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:KubernetesService((y:KubernetesService)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:LanguageModelClient((y:LanguageModelClient)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:LanguageModelClient((y:LanguageModelClient)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:Libvirt((y:Libvirt)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:Link((y:Link)) -- subClassOf --> y:NetworkingResource((y:NetworkingResource))
y:LinuxOperatingSystem((y:LinuxOperatingSystem)) -- subClassOf --> y:OperatingSystem((y:OperatingSystem))
y:Listener((y:Listener)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:LocalDeploymentTarget((y:LocalDeploymentTarget)) -- subClassOf --> y:DeploymentTarget((y:DeploymentTarget))
y:LocalStorage((y:LocalStorage)) -- subClassOf --> y:StorageResource((y:StorageResource))
y:Loki((y:Loki)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:LoopbackInterface((y:LoopbackInterface)) -- subClassOf --> y:NetworkInterface((y:NetworkInterface))
y:MacOSOperatingSystem((y:MacOSOperatingSystem)) -- subClassOf --> y:OperatingSystem((y:OperatingSystem))
y:Memory((y:Memory)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:MetricExporter((y:MetricExporter)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:NATNetwork((y:NATNetwork)) -- subClassOf --> y:Network((y:Network))
y:NVM((y:NVM)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:NestedHost((y:NestedHost)) -- subClassOf --> y:Guest((y:Guest))
y:NestedHost((y:NestedHost)) -- subClassOf --> y:Host((y:Host))
y:Netplan((y:Netplan)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:Network((y:Network)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:NetworkAdapter((y:NetworkAdapter)) -- subClassOf --> y:NetworkInterface((y:NetworkInterface))
y:NetworkAttachedStorage((y:NetworkAttachedStorage)) -- subClassOf --> y:StorageResource((y:StorageResource))
y:NetworkInterface -- y:assignedAddress --> y:IPAddress
y:NetworkInterface((y:NetworkInterface)) -- subClassOf --> y:NetworkingResource((y:NetworkingResource))
y:NetworkManager((y:NetworkManager)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:NetworkingResource((y:NetworkingResource)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:OCRProvider((y:OCRProvider)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:OpenGLContext((y:OpenGLContext)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:OperatingSystem((y:OperatingSystem)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:OperatingSystemProcess((y:OperatingSystemProcess)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:OriginServer((y:OriginServer)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:PackageManager((y:PackageManager)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:PackageRepository((y:PackageRepository)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:PersistentVolume((y:PersistentVolume)) -- subClassOf --> y:StorageResource((y:StorageResource))
y:PhysicalHost((y:PhysicalHost)) -- subClassOf --> y:Host((y:Host))
y:PhysicalHost((y:PhysicalHost)) -- subClassOf --> y:PhysicalMachine((y:PhysicalMachine))
y:PhysicalMachine((y:PhysicalMachine)) -- subClassOf --> y:ComputingNode((y:ComputingNode))
y:PoolAggregator((y:PoolAggregator)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:PoolControlService((y:PoolControlService)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:PoolStorage((y:PoolStorage)) -- subClassOf --> y:StorageResource((y:StorageResource))
y:PostgreSQL((y:PostgreSQL)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:Processor((y:Processor)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:Prometheus((y:Prometheus)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:Proxy((y:Proxy)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:PseudoTerminal((y:PseudoTerminal)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:PullThroughCache((y:PullThroughCache)) -- subClassOf --> y:RegistryMirror((y:RegistryMirror))
y:QEMU((y:QEMU)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:Registry((y:Registry)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:RegistryMirror((y:RegistryMirror)) -- subClassOf --> y:Registry((y:Registry))
y:Router((y:Router)) -- subClassOf --> y:NetworkingResource((y:NetworkingResource))
y:RuleBasedSQLGenerator((y:RuleBasedSQLGenerator)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:RuleBasedSQLGenerator((y:RuleBasedSQLGenerator)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:ScreenshotProvider((y:ScreenshotProvider)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:SequenceHandler -- y:implementsAction --> y:SequenceAction
y:SequenceHandler((y:SequenceHandler)) -- subClassOf --> r_SequenceHandler_implementsAction_SequenceAction_((Anonymous class))
y:SequenceHandler((y:SequenceHandler)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:ServiceGuest((y:ServiceGuest)) -- subClassOf --> r_ServiceGuest_hosts_SoftwareService_((Anonymous class))
y:ServiceGuest((y:ServiceGuest)) -- subClassOf --> y:Guest((y:Guest))
y:Socket((y:Socket)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:SoftwareService -- y:exposesEndpoint --> y:Endpoint
y:SoftwareService((y:SoftwareService)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:Squid((y:Squid)) -- subClassOf --> y:ForwardProxy((y:ForwardProxy))
y:StagingArea((y:StagingArea)) -- subClassOf --> y:StorageResource((y:StorageResource))
y:StashService((y:StashService)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:StashStorage((y:StashStorage)) -- subClassOf --> y:StorageResource((y:StorageResource))
y:StatusService((y:StatusService)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:StorageResource((y:StorageResource)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:StorageShare((y:StorageShare)) -- subClassOf --> y:StorageResource((y:StorageResource))
y:Subnet((y:Subnet)) -- subClassOf --> y:Network((y:Network))
y:Switch((y:Switch)) -- subClassOf --> y:NetworkingResource((y:NetworkingResource))
y:SystemElement -- y:affectedBy --> y:Incident
y:SystemElement -- y:configuredBy --> y:ConfigurationArtifact
y:SystemElement -- y:hostedBy --> y:ComputingNode
y:SystemElement -- y:usesProtocol --> y:Protocol
y:SystemElement((y:SystemElement)) -- subClassOf --> y:Entity((y:Entity))
y:SystemdNetworkd((y:SystemdNetworkd)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:TPM((y:TPM)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:TaskQueue((y:TaskQueue)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:TestGuest((y:TestGuest)) -- subClassOf --> y:Guest((y:Guest))
y:TestRunner -- y:executesPlan --> y:TestPlan
y:TestRunner((y:TestRunner)) -- subClassOf --> r_TestRunner_executesPlan_TestPlan_((Anonymous class))
y:TestRunner((y:TestRunner)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:TextSQLAgent -- y:answersQuestion --> y:NaturalLanguageQuestion
y:TextSQLAgent((y:TextSQLAgent)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:TextSQLAgent((y:TextSQLAgent)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:UEFI((y:UEFI)) -- subClassOf --> y:Firmware((y:Firmware))
y:USBNetworkAdapter((y:USBNetworkAdapter)) -- subClassOf --> y:NetworkAdapter((y:NetworkAdapter))
y:UTM((y:UTM)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:UTMSharedNetworking((y:UTMSharedNetworking)) -- subClassOf --> y:NATNetwork((y:NATNetwork))
y:UbuntuOperatingSystem((y:UbuntuOperatingSystem)) -- subClassOf --> y:LinuxOperatingSystem((y:LinuxOperatingSystem))
y:Uplink((y:Uplink)) -- subClassOf --> y:Link((y:Link))
y:VLAN((y:VLAN)) -- subClassOf --> y:Network((y:Network))
y:VNCTransport((y:VNCTransport)) -- subClassOf --> r_VNCTransport_usesProtocol_RemoteFramebufferProtocol_((Anonymous class))
y:VNCTransport((y:VNCTransport)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:Vault((y:Vault)) -- subClassOf --> y:StorageResource((y:StorageResource))
y:VirtualDisk((y:VirtualDisk)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:VirtualMachine -- y:managedByHypervisor --> y:Hypervisor
y:VirtualMachine((y:VirtualMachine)) -- subClassOf --> y:ComputingNode((y:ComputingNode))
y:VirtualNetworkInterface((y:VirtualNetworkInterface)) -- subClassOf --> y:NetworkInterface((y:NetworkInterface))
y:VirtualProcessor((y:VirtualProcessor)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:VirtualSwitch((y:VirtualSwitch)) -- subClassOf --> y:Switch((y:Switch))
y:VirtualizationExtension((y:VirtualizationExtension)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:Watchdog((y:Watchdog)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:WebsiteFrontend((y:WebsiteFrontend)) -- subClassOf --> y:ApplicationWorkload((y:ApplicationWorkload))
y:WindowsOperatingSystem((y:WindowsOperatingSystem)) -- subClassOf --> y:OperatingSystem((y:OperatingSystem))
y:WiredUplink((y:WiredUplink)) -- subClassOf --> y:Uplink((y:Uplink))
y:WirelessUplink((y:WirelessUplink)) -- subClassOf --> y:Uplink((y:Uplink))
y:Zot((y:Zot)) -- subClassOf --> y:Registry((y:Registry))
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.22

Back to [Yuruna ontology diagrams](../../../README.md#425aed30-0005)
