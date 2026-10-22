# Identifier diagram

`y:Identifier` is a value used to distinguish a logical object, code, or
contract element within an explicit scope. It is a branch of the [Information
artifact](information-artifact.md) domain. This page draws it from version
2026/10 of the [Yuruna ontology](../yuruna.owl): the classes under it, the
object properties whose `rdfs:domain` is one of those classes, and their
existential restrictions.

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
subgraph r_DHCPClientIdentifier_identifiesClient_DHCPClient_[Restriction &exist; R C]
r_DHCPClientIdentifier_identifiesClient_DHCPClient_thing((thing)) --> r_DHCPClientIdentifier_identifiesClient_DHCPClient_y:identifiesClient[y:identifiesClient]
r_DHCPClientIdentifier_identifiesClient_DHCPClient_y:identifiesClient[y:identifiesClient]
-- some --> r_DHCPClientIdentifier_identifiesClient_DHCPClient_y:DHCPClient((y:DHCPClient))
end
y:AmisAdInventoryVersion((y:AmisAdInventoryVersion)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdInventoryVersion((y:AmisAdInventoryVersion)) -- subClassOf --> y:Identifier((y:Identifier))
y:BaseURL((y:BaseURL)) -- subClassOf --> y:URL((y:URL))
y:ContentDigest((y:ContentDigest)) -- subClassOf --> y:Identifier((y:Identifier))
y:DHCPClientIdentifier -- y:identifiesClient --> y:DHCPClient
y:DHCPClientIdentifier((y:DHCPClientIdentifier)) -- subClassOf --> r_DHCPClientIdentifier_identifiesClient_DHCPClient_((Anonymous class))
y:DHCPClientIdentifier((y:DHCPClientIdentifier)) -- subClassOf --> y:Identifier((y:Identifier))
y:DUID((y:DUID)) -- subClassOf --> y:Identifier((y:Identifier))
y:DeterministicMACAddress((y:DeterministicMACAddress)) -- subClassOf --> y:MACAddress((y:MACAddress))
y:DocumentIdentifier((y:DocumentIdentifier)) -- subClassOf --> y:Identifier((y:Identifier))
y:FQDN((y:FQDN)) -- subClassOf --> y:Identifier((y:Identifier))
y:FileDescriptor((y:FileDescriptor)) -- subClassOf --> y:Identifier((y:Identifier))
y:GuestIdentity((y:GuestIdentity)) -- subClassOf --> y:Identifier((y:Identifier))
y:GuestReachableHostAddress((y:GuestReachableHostAddress)) -- subClassOf --> y:IPAddress((y:IPAddress))
y:HeadingAnchor((y:HeadingAnchor)) -- subClassOf --> y:Identifier((y:Identifier))
y:HostIdentity((y:HostIdentity)) -- subClassOf --> y:Identifier((y:Identifier))
y:Hostname((y:Hostname)) -- subClassOf --> y:Identifier((y:Identifier))
y:IPAddress((y:IPAddress)) -- subClassOf --> y:Identifier((y:Identifier))
y:IPv4Address((y:IPv4Address)) -- subClassOf --> y:IPAddress((y:IPAddress))
y:IPv4LinkLocalAddress((y:IPv4LinkLocalAddress)) -- subClassOf --> y:IPv4Address((y:IPv4Address))
y:IPv4LinkLocalAddress((y:IPv4LinkLocalAddress)) -- subClassOf --> y:LinkLocalAddress((y:LinkLocalAddress))
y:IPv6Address((y:IPv6Address)) -- subClassOf --> y:IPAddress((y:IPAddress))
y:Identifier((y:Identifier)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:ImageTag((y:ImageTag)) -- subClassOf --> y:Identifier((y:Identifier))
y:ImageVariant((y:ImageVariant)) -- subClassOf --> y:Identifier((y:Identifier))
y:IncidentFingerprint((y:IncidentFingerprint)) -- subClassOf --> y:Identifier((y:Identifier))
y:InterfaceAlias((y:InterfaceAlias)) -- subClassOf --> y:Identifier((y:Identifier))
y:KubernetesNamespace((y:KubernetesNamespace)) -- subClassOf --> y:Identifier((y:Identifier))
y:LinkAlias -- y:aliasOfLink --> y:ShortLink
y:LinkAlias((y:LinkAlias)) -- subClassOf --> y:Identifier((y:Identifier))
y:LinkLocalAddress((y:LinkLocalAddress)) -- subClassOf --> y:IPAddress((y:IPAddress))
y:Locale((y:Locale)) -- subClassOf --> y:Identifier((y:Identifier))
y:MACAddress((y:MACAddress)) -- subClassOf --> y:Identifier((y:Identifier))
y:MachineIdentifier((y:MachineIdentifier)) -- subClassOf --> y:Identifier((y:Identifier))
y:MessageKey((y:MessageKey)) -- subClassOf --> y:Identifier((y:Identifier))
y:MessagePlaceholder((y:MessagePlaceholder)) -- subClassOf --> y:Identifier((y:Identifier))
y:MetricLabel((y:MetricLabel)) -- subClassOf --> y:Identifier((y:Identifier))
y:MountPoint((y:MountPoint)) -- subClassOf --> y:Identifier((y:Identifier))
y:Port((y:Port)) -- subClassOf --> y:Identifier((y:Identifier))
y:Prefix((y:Prefix)) -- subClassOf --> y:Identifier((y:Identifier))
y:PrivateAddress((y:PrivateAddress)) -- subClassOf --> y:IPAddress((y:IPAddress))
y:ProtectedToken((y:ProtectedToken)) -- subClassOf --> y:Identifier((y:Identifier))
y:ShortLink((y:ShortLink)) -- subClassOf --> y:Identifier((y:Identifier))
y:SoftwareVersion((y:SoftwareVersion)) -- subClassOf --> y:Identifier((y:Identifier))
y:SourceHash((y:SourceHash)) -- subClassOf --> y:Identifier((y:Identifier))
y:SourceRevision((y:SourceRevision)) -- subClassOf --> y:Identifier((y:Identifier))
y:URL((y:URL)) -- subClassOf --> y:Identifier((y:Identifier))
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.22

Back to [Yuruna ontology diagrams](../../../README.md#425aed30-0005)
