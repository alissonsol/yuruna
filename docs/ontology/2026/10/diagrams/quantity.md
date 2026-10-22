# Quantity diagram

`y:Quantity` is a measured or configured magnitude with an explicit unit and
scope. It is a branch of the [Information artifact](information-artifact.md)
domain. This page draws it from version 2026/10 of the [Yuruna
ontology](../yuruna.owl): the classes under it, the object properties whose
`rdfs:domain` is one of those classes, and their existential restrictions.

Circles are classes. A `subClassOf` arrow points from a class to its parent,
which can be drawn on another page. An arrow labeled with a property runs from
its domain to its range; a range class drawn as a box belongs to another page.

```mermaid
%%{init: {"flowchart": {"useMaxWidth": 0}}}%%
graph LR
classDef Datatype fill:#9c6,stroke:#9c6;
y:AddressFootprint((y:AddressFootprint)) -- subClassOf --> y:Quantity((y:Quantity))
y:AmisAdCampaignBudget((y:AmisAdCampaignBudget)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdCampaignBudget((y:AmisAdCampaignBudget)) -- subClassOf --> y:Quantity((y:Quantity))
y:Bandwidth((y:Bandwidth)) -- subClassOf --> y:Quantity((y:Quantity))
y:CacheHitRatio((y:CacheHitRatio)) -- subClassOf --> y:Quantity((y:Quantity))
y:CommittedMemory((y:CommittedMemory)) -- subClassOf --> y:Quantity((y:Quantity))
y:ConsoleStaticDuration((y:ConsoleStaticDuration)) -- subClassOf --> y:Quantity((y:Quantity))
y:CycleSuccessRatio((y:CycleSuccessRatio)) -- subClassOf --> y:Quantity((y:Quantity))
y:Deadline((y:Deadline)) -- subClassOf --> y:Quantity((y:Quantity))
y:EstimatedRowCount((y:EstimatedRowCount)) -- subClassOf --> y:Quantity((y:Quantity))
y:EstimatedRowCount((y:EstimatedRowCount)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:FreeSpace((y:FreeSpace)) -- subClassOf --> y:Quantity((y:Quantity))
y:InterfaceMetric((y:InterfaceMetric)) -- subClassOf --> y:Quantity((y:Quantity))
y:Latency((y:Latency)) -- subClassOf --> y:Quantity((y:Quantity))
y:LatencyPercentile((y:LatencyPercentile)) -- subClassOf --> y:Quantity((y:Quantity))
y:MTU((y:MTU)) -- subClassOf --> y:Quantity((y:Quantity))
y:MemoryCapacity((y:MemoryCapacity)) -- subClassOf --> y:Quantity((y:Quantity))
y:MemoryHeadroom((y:MemoryHeadroom)) -- subClassOf --> y:Quantity((y:Quantity))
y:ObservedAddressCount((y:ObservedAddressCount)) -- subClassOf --> y:Quantity((y:Quantity))
y:PrefixLength((y:PrefixLength)) -- subClassOf --> y:Quantity((y:Quantity))
y:Quantity((y:Quantity)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:ResidentMemory((y:ResidentMemory)) -- subClassOf --> y:Quantity((y:Quantity))
y:RouteMetric((y:RouteMetric)) -- subClassOf --> y:Quantity((y:Quantity))
y:SocketReceiveQueue((y:SocketReceiveQueue)) -- subClassOf --> y:Quantity((y:Quantity))
y:SocketSendQueue((y:SocketSendQueue)) -- subClassOf --> y:Quantity((y:Quantity))
y:StorageCapacity((y:StorageCapacity)) -- subClassOf --> y:Quantity((y:Quantity))
y:TextSQLAnnualRecurringRevenue((y:TextSQLAnnualRecurringRevenue)) -- subClassOf --> y:Quantity((y:Quantity))
y:TextSQLAnnualRecurringRevenue((y:TextSQLAnnualRecurringRevenue)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:TextSQLMonthlyRecurringRevenue((y:TextSQLMonthlyRecurringRevenue)) -- subClassOf --> y:Quantity((y:Quantity))
y:TextSQLMonthlyRecurringRevenue((y:TextSQLMonthlyRecurringRevenue)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:Throughput((y:Throughput)) -- subClassOf --> y:Quantity((y:Quantity))
y:WorkerCapacity((y:WorkerCapacity)) -- subClassOf --> y:Quantity((y:Quantity))
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.22

Back to [Yuruna ontology diagrams](../../../README.md#425aed30-0005)
