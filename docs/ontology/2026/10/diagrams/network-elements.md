# Network system elements diagram

The `network:` namespace, `https://yuruna.com/ontology/2026/10/network#`, holds
the networking vocabulary: protocols, interfaces, links, addressing, name
resolution, routing, proxies and caches, and the network conditions, failures,
and checks. This page draws the system elements of the network namespace: these
classes, the object properties of the namespace drawn here, and the existential
restrictions on these classes, from version 2026/10 of the [Yuruna
ontology](../yuruna.owl).

The namespace's other pages: [Network information
artifacts](network-information.md), [Network processes and
situations](network-processes.md).

Circles are classes drawn on this page and boxes are classes drawn on another
page. A `subClassOf` arrow points from a class to its parent. An arrow labeled
with a property runs from its domain to its range.

```mermaid
%%{init: {"flowchart": {"useMaxWidth": 0}}}%%
graph LR
classDef Datatype fill:#9c6,stroke:#9c6;
network:Bridge((network:Bridge)) -- subClassOf --> network:NetworkingResource((network:NetworkingResource))
network:BridgePort((network:BridgePort)) -- subClassOf --> network:NetworkingResource((network:NetworkingResource))
network:CachingProxyService((network:CachingProxyService)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
network:DHCPAddressPool((network:DHCPAddressPool)) -- subClassOf --> network:NetworkingResource((network:NetworkingResource))
network:DHCPClient((network:DHCPClient)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
network:DHCPServer((network:DHCPServer)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
network:DNSCache((network:DNSCache)) -- subClassOf --> storage:Cache[storage:Cache]
network:DNSResolver -- network:resolvesName --> network:Hostname
network:DNSResolver((network:DNSResolver)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
network:Dnsmasq((network:Dnsmasq)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
network:Endpoint((network:Endpoint)) -- subClassOf --> network:NetworkingResource((network:NetworkingResource))
network:Firewall((network:Firewall)) -- subClassOf --> network:NetworkingResource((network:NetworkingResource))
network:ForwardProxy((network:ForwardProxy)) -- subClassOf --> network:Proxy((network:Proxy))
network:Forwarder((network:Forwarder)) -- subClassOf --> y:SystemElement[y:SystemElement]
network:Gateway((network:Gateway)) -- subClassOf --> network:NetworkingResource((network:NetworkingResource))
network:HTTPCache((network:HTTPCache)) -- subClassOf --> storage:Cache[storage:Cache]
network:HTTPConnectTunnel((network:HTTPConnectTunnel)) -- subClassOf --> network:NetworkingResource((network:NetworkingResource))
network:HostAddressBeacon((network:HostAddressBeacon)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
network:HyperVDefaultSwitch((network:HyperVDefaultSwitch)) -- subClassOf --> network:VirtualSwitch((network:VirtualSwitch))
network:HyperVExternalSwitch((network:HyperVExternalSwitch)) -- subClassOf --> network:VirtualSwitch((network:VirtualSwitch))
network:HyperVManagementAdapter((network:HyperVManagementAdapter)) -- subClassOf --> network:NetworkAdapter((network:NetworkAdapter))
network:HyperVManagementAdapter((network:HyperVManagementAdapter)) -- subClassOf --> network:VirtualNetworkInterface((network:VirtualNetworkInterface))
network:Link((network:Link)) -- subClassOf --> network:NetworkingResource((network:NetworkingResource))
network:Listener((network:Listener)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
network:LoopbackInterface((network:LoopbackInterface)) -- subClassOf --> network:NetworkInterface((network:NetworkInterface))
network:NATNetwork((network:NATNetwork)) -- subClassOf --> network:Network((network:Network))
network:Netplan((network:Netplan)) -- subClassOf --> y:SystemElement[y:SystemElement]
network:Network((network:Network)) -- subClassOf --> y:SystemElement[y:SystemElement]
network:NetworkAdapter((network:NetworkAdapter)) -- subClassOf --> network:NetworkInterface((network:NetworkInterface))
network:NetworkInterface -- network:assignedAddress --> network:IPAddress
network:NetworkInterface((network:NetworkInterface)) -- subClassOf --> network:NetworkingResource((network:NetworkingResource))
network:NetworkManager((network:NetworkManager)) -- subClassOf --> y:SystemElement[y:SystemElement]
network:NetworkingResource((network:NetworkingResource)) -- subClassOf --> y:SystemElement[y:SystemElement]
network:OriginServer((network:OriginServer)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
network:Proxy((network:Proxy)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
network:Router((network:Router)) -- subClassOf --> network:NetworkingResource((network:NetworkingResource))
network:Socket((network:Socket)) -- subClassOf --> y:SystemElement[y:SystemElement]
network:Squid((network:Squid)) -- subClassOf --> network:ForwardProxy((network:ForwardProxy))
network:Subnet((network:Subnet)) -- subClassOf --> network:Network((network:Network))
network:Switch((network:Switch)) -- subClassOf --> network:NetworkingResource((network:NetworkingResource))
network:SystemdNetworkd((network:SystemdNetworkd)) -- subClassOf --> y:SystemElement[y:SystemElement]
network:USBNetworkAdapter((network:USBNetworkAdapter)) -- subClassOf --> network:NetworkAdapter((network:NetworkAdapter))
network:UTMSharedNetworking((network:UTMSharedNetworking)) -- subClassOf --> network:NATNetwork((network:NATNetwork))
network:Uplink((network:Uplink)) -- subClassOf --> network:Link((network:Link))
network:VLAN((network:VLAN)) -- subClassOf --> network:Network((network:Network))
network:VirtualNetworkInterface((network:VirtualNetworkInterface)) -- subClassOf --> network:NetworkInterface((network:NetworkInterface))
network:VirtualSwitch((network:VirtualSwitch)) -- subClassOf --> network:Switch((network:Switch))
network:WiredUplink((network:WiredUplink)) -- subClassOf --> network:Uplink((network:Uplink))
network:WirelessUplink((network:WirelessUplink)) -- subClassOf --> network:Uplink((network:Uplink))
y:SoftwareService -- network:exposesEndpoint --> network:Endpoint
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.11.05

Back to [Yuruna ontology diagrams](../../../README.md#425aed30-0005)
