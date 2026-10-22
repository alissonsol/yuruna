# Protocol diagram

`y:Protocol` is a defined set of communication rules and message meanings used
between participating endpoints. It is a branch of the [Information
artifact](information-artifact.md) domain. This page draws it from version
2026/10 of the [Yuruna ontology](../yuruna.owl): the classes under it, the
object properties whose `rdfs:domain` is one of those classes, and their
existential restrictions.

Circles are classes. A `subClassOf` arrow points from a class to its parent,
which can be drawn on another page. An arrow labeled with a property runs from
its domain to its range; a range class drawn as a box belongs to another page.

```mermaid
%%{init: {"flowchart": {"useMaxWidth": 0}}}%%
graph LR
classDef Datatype fill:#9c6,stroke:#9c6;
y:ARP((y:ARP)) -- subClassOf --> y:Protocol((y:Protocol))
y:CIFS((y:CIFS)) -- subClassOf --> y:Protocol((y:Protocol))
y:DHCP((y:DHCP)) -- subClassOf --> y:Protocol((y:Protocol))
y:DNS((y:DNS)) -- subClassOf --> y:Protocol((y:Protocol))
y:Ethernet((y:Ethernet)) -- subClassOf --> y:Protocol((y:Protocol))
y:HTTP((y:HTTP)) -- subClassOf --> y:Protocol((y:Protocol))
y:HTTPS((y:HTTPS)) -- subClassOf --> y:Protocol((y:Protocol))
y:ICMP((y:ICMP)) -- subClassOf --> y:Protocol((y:Protocol))
y:OAuth2((y:OAuth2)) -- subClassOf --> y:Protocol((y:Protocol))
y:OpenIDConnect((y:OpenIDConnect)) -- subClassOf --> y:Protocol((y:Protocol))
y:Protocol((y:Protocol)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:ProxyProtocol((y:ProxyProtocol)) -- subClassOf --> y:Protocol((y:Protocol))
y:RemoteFramebufferProtocol((y:RemoteFramebufferProtocol)) -- subClassOf --> y:Protocol((y:Protocol))
y:SFTP((y:SFTP)) -- subClassOf --> y:Protocol((y:Protocol))
y:SMB((y:SMB)) -- subClassOf --> y:Protocol((y:Protocol))
y:SSH((y:SSH)) -- subClassOf --> y:Protocol((y:Protocol))
y:TCP((y:TCP)) -- subClassOf --> y:Protocol((y:Protocol))
y:TLS((y:TLS)) -- subClassOf --> y:Protocol((y:Protocol))
y:UDP((y:UDP)) -- subClassOf --> y:Protocol((y:Protocol))
y:WiFi((y:WiFi)) -- subClassOf --> y:Protocol((y:Protocol))
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.22

Back to [Yuruna ontology diagrams](../../../README.md#425aed30-0005)
