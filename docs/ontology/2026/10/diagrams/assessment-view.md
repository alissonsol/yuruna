# Assessment view diagram

`y:AssessmentView` is one of four kinds of evidence compared in a security
assessment of the same scope: the Baseline, the Configuration, the
Implementation, or the Telemetry. This page draws it from version 2026/10 of the
[Yuruna ontology](../yuruna.owl): the classes under it, the object properties
whose `rdfs:domain` is one of those classes, and their existential restrictions.

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
subgraph r_TestPlan_hasSequence_TestSequence_[Restriction &exist; R C]
r_TestPlan_hasSequence_TestSequence_thing((thing)) --> r_TestPlan_hasSequence_TestSequence_y:hasSequence[y:hasSequence]
r_TestPlan_hasSequence_TestSequence_y:hasSequence[y:hasSequence]
-- some --> r_TestPlan_hasSequence_TestSequence_y:TestSequence((y:TestSequence))
end
y:AccessibilityPermission((y:AccessibilityPermission)) -- subClassOf --> y:Policy((y:Policy))
y:AlertRule((y:AlertRule)) -- subClassOf --> y:Policy((y:Policy))
y:AmisAdAggregateTargeting((y:AmisAdAggregateTargeting)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdAggregateTargeting((y:AmisAdAggregateTargeting)) -- subClassOf --> y:Policy((y:Policy))
y:AmisAdClosingPolicy((y:AmisAdClosingPolicy)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdClosingPolicy((y:AmisAdClosingPolicy)) -- subClassOf --> y:Policy((y:Policy))
y:AmisAdNeedConstraint((y:AmisAdNeedConstraint)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdNeedConstraint((y:AmisAdNeedConstraint)) -- subClassOf --> y:Policy((y:Policy))
y:AmisAdPrivacyThreshold((y:AmisAdPrivacyThreshold)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdPrivacyThreshold((y:AmisAdPrivacyThreshold)) -- subClassOf --> y:Policy((y:Policy))
y:AmisAdSovereigntyPolicy((y:AmisAdSovereigntyPolicy)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdSovereigntyPolicy((y:AmisAdSovereigntyPolicy)) -- subClassOf --> y:Policy((y:Policy))
y:AssessmentView((y:AssessmentView)) -- subClassOf --> y:Entity((y:Entity))
y:Baseline((y:Baseline)) -- subClassOf --> y:AssessmentView((y:AssessmentView))
y:BridgedNetworking((y:BridgedNetworking)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:CapturePermission((y:CapturePermission)) -- subClassOf --> y:Policy((y:Policy))
y:CertificatePinning((y:CertificatePinning)) -- subClassOf --> y:Policy((y:Policy))
y:CloudConfiguration((y:CloudConfiguration)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:CloudInitConfiguration((y:CloudInitConfiguration)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:CloudInitOverlay((y:CloudInitOverlay)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:CloudInitSeed((y:CloudInitSeed)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:ConfigurationArtifact((y:ConfigurationArtifact)) -- subClassOf --> y:Artifact((y:Artifact))
y:ConfigurationArtifact((y:ConfigurationArtifact)) -- subClassOf --> y:AssessmentView((y:AssessmentView))
y:ContactPoint((y:ContactPoint)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:CopyMode((y:CopyMode)) -- subClassOf --> y:Policy((y:Policy))
y:CounterMetric((y:CounterMetric)) -- subClassOf --> y:Metric((y:Metric))
y:CurrentArtifactPointer((y:CurrentArtifactPointer)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:DHCPReservation((y:DHCPReservation)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:DefaultRoute((y:DefaultRoute)) -- subClassOf --> y:Route((y:Route))
y:DiagnosticLadder((y:DiagnosticLadder)) -- subClassOf --> y:Policy((y:Policy))
y:DispatchRegistry((y:DispatchRegistry)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:ExtensionCapability((y:ExtensionCapability)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:FirewallRule((y:FirewallRule)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:GaugeMetric((y:GaugeMetric)) -- subClassOf --> y:Metric((y:Metric))
y:GraphicsDeviceModel((y:GraphicsDeviceModel)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:HelmValues((y:HelmValues)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:HostCondition((y:HostCondition)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:Implementation((y:Implementation)) -- subClassOf --> y:AssessmentView((y:AssessmentView))
y:IncidentDetectionPolicy((y:IncidentDetectionPolicy)) -- subClassOf --> y:Policy((y:Policy))
y:InfrastructureAsCode((y:InfrastructureAsCode)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:Kubeconfig((y:Kubeconfig)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:KubernetesConfigMap((y:KubernetesConfigMap)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:KubernetesContext((y:KubernetesContext)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:KubernetesIngress((y:KubernetesIngress)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:KubernetesSecret((y:KubernetesSecret)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:LanguageFallback((y:LanguageFallback)) -- subClassOf --> y:Policy((y:Policy))
y:LogLevel((y:LogLevel)) -- subClassOf --> y:Policy((y:Policy))
y:Metric((y:Metric)) -- subClassOf --> y:Telemetry((y:Telemetry))
y:Mount((y:Mount)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:MoveMode((y:MoveMode)) -- subClassOf --> y:Policy((y:Policy))
y:NetworkProfile((y:NetworkProfile)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:NoUpstreamMode((y:NoUpstreamMode)) -- subClassOf --> y:Policy((y:Policy))
y:NotificationPolicy((y:NotificationPolicy)) -- subClassOf --> y:Policy((y:Policy))
y:OCRCombinePolicy((y:OCRCombinePolicy)) -- subClassOf --> y:Policy((y:Policy))
y:OfflineMode((y:OfflineMode)) -- subClassOf --> y:Policy((y:Policy))
y:OpenTofuConfiguration((y:OpenTofuConfiguration)) -- subClassOf --> y:InfrastructureAsCode((y:InfrastructureAsCode))
y:PauseRequest((y:PauseRequest)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:PersistentVolumeClaim((y:PersistentVolumeClaim)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:Policy((y:Policy)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:PoolIntent((y:PoolIntent)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:ProxyBypass((y:ProxyBypass)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:ReadOnlyRole((y:ReadOnlyRole)) -- subClassOf --> y:Policy((y:Policy))
y:ResolverConfiguration((y:ResolverConfiguration)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:RetentionPolicy((y:RetentionPolicy)) -- subClassOf --> y:Policy((y:Policy))
y:RetryBudget((y:RetryBudget)) -- subClassOf --> y:Policy((y:Policy))
y:RetryPolicy((y:RetryPolicy)) -- subClassOf --> y:Policy((y:Policy))
y:Route -- y:hasGateway --> y:Gateway
y:Route((y:Route)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:RoutingTable -- y:hasRoute --> y:Route
y:RoutingTable((y:RoutingTable)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:ScreenRecordingPermission((y:ScreenRecordingPermission)) -- subClassOf --> y:Policy((y:Policy))
y:SequenceAction((y:SequenceAction)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:SnapshotManifest((y:SnapshotManifest)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:StaticAddressConfiguration((y:StaticAddressConfiguration)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:StaticHostMapping((y:StaticHostMapping)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:TLSCertificateSecret((y:TLSCertificateSecret)) -- subClassOf --> y:KubernetesSecret((y:KubernetesSecret))
y:Telemetry((y:Telemetry)) -- subClassOf --> y:AssessmentView((y:AssessmentView))
y:Telemetry((y:Telemetry)) -- subClassOf --> y:DiagnosticEvidence((y:DiagnosticEvidence))
y:TestPlan -- y:hasSequence --> y:TestSequence
y:TestPlan((y:TestPlan)) -- subClassOf --> r_TestPlan_hasSequence_TestSequence_((Anonymous class))
y:TestPlan((y:TestPlan)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:TestSequence((y:TestSequence)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:TextDirection((y:TextDirection)) -- subClassOf --> y:Policy((y:Policy))
y:TopologySelectionPolicy((y:TopologySelectionPolicy)) -- subClassOf --> y:Policy((y:Policy))
y:TrustStore((y:TrustStore)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:UplinkBinding((y:UplinkBinding)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:VersionFloor((y:VersionFloor)) -- subClassOf --> y:Policy((y:Policy))
y:VersionPin((y:VersionPin)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.22

Back to [Yuruna ontology diagrams](../../../README.md#425aed30-0005)
