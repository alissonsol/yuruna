# Artifact diagram

`y:Artifact` is an output or input retained for execution, distribution,
inspection, or evidence. It is a branch of the [Information
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
subgraph r_N8n_dependsOn_NodeJS_[Restriction &exist; R C]
r_N8n_dependsOn_NodeJS_thing((thing)) --> r_N8n_dependsOn_NodeJS_y:dependsOn[y:dependsOn]
r_N8n_dependsOn_NodeJS_y:dependsOn[y:dependsOn]
-- some --> r_N8n_dependsOn_NodeJS_y:NodeJS((y:NodeJS))
end
subgraph r_OpenClaw_dependsOn_NodeJS_[Restriction &exist; R C]
r_OpenClaw_dependsOn_NodeJS_thing((thing)) --> r_OpenClaw_dependsOn_NodeJS_y:dependsOn[y:dependsOn]
r_OpenClaw_dependsOn_NodeJS_y:dependsOn[y:dependsOn]
-- some --> r_OpenClaw_dependsOn_NodeJS_y:NodeJS((y:NodeJS))
end
subgraph r_StashEntry_storedIn_StashStorage_[Restriction &exist; R C]
r_StashEntry_storedIn_StashStorage_thing((thing)) --> r_StashEntry_storedIn_StashStorage_y:storedIn[y:storedIn]
r_StashEntry_storedIn_StashStorage_y:storedIn[y:storedIn]
-- some --> r_StashEntry_storedIn_StashStorage_y:StashStorage((y:StashStorage))
end
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
y:AmisAdCreativeAsset((y:AmisAdCreativeAsset)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdCreativeAsset((y:AmisAdCreativeAsset)) -- subClassOf --> y:Artifact((y:Artifact))
y:AmisAdNeedConstraint((y:AmisAdNeedConstraint)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdNeedConstraint((y:AmisAdNeedConstraint)) -- subClassOf --> y:Policy((y:Policy))
y:AmisAdPrivacyThreshold((y:AmisAdPrivacyThreshold)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdPrivacyThreshold((y:AmisAdPrivacyThreshold)) -- subClassOf --> y:Policy((y:Policy))
y:AmisAdSovereigntyPolicy((y:AmisAdSovereigntyPolicy)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdSovereigntyPolicy((y:AmisAdSovereigntyPolicy)) -- subClassOf --> y:Policy((y:Policy))
y:Artifact((y:Artifact)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:BackingImage((y:BackingImage)) -- subClassOf --> y:DiskImage((y:DiskImage))
y:BridgedNetworking((y:BridgedNetworking)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:CapturePermission((y:CapturePermission)) -- subClassOf --> y:Policy((y:Policy))
y:CertificatePinning((y:CertificatePinning)) -- subClassOf --> y:Policy((y:Policy))
y:CloudConfiguration((y:CloudConfiguration)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:CloudImage((y:CloudImage)) -- subClassOf --> y:InstallationImage((y:InstallationImage))
y:CloudInitConfiguration((y:CloudInitConfiguration)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:CloudInitOverlay((y:CloudInitOverlay)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:CloudInitSeed((y:CloudInitSeed)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:ConfigurationArtifact((y:ConfigurationArtifact)) -- subClassOf --> y:Artifact((y:Artifact))
y:ConfigurationArtifact((y:ConfigurationArtifact)) -- subClassOf --> y:AssessmentView((y:AssessmentView))
y:ContactPoint((y:ContactPoint)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:ContainerImage((y:ContainerImage)) -- subClassOf --> y:SoftwareArtifact((y:SoftwareArtifact))
y:CopyMode((y:CopyMode)) -- subClassOf --> y:Policy((y:Policy))
y:CurrentArtifactPointer((y:CurrentArtifactPointer)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:DHCPReservation((y:DHCPReservation)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:DefaultRoute((y:DefaultRoute)) -- subClassOf --> y:Route((y:Route))
y:DeployableComponent((y:DeployableComponent)) -- subClassOf --> y:SoftwareArtifact((y:SoftwareArtifact))
y:DiagnosticLadder((y:DiagnosticLadder)) -- subClassOf --> y:Policy((y:Policy))
y:DiskImage((y:DiskImage)) -- subClassOf --> y:Artifact((y:Artifact))
y:DiskSnapshot((y:DiskSnapshot)) -- subClassOf --> y:Snapshot((y:Snapshot))
y:DispatchRegistry((y:DispatchRegistry)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:ExtensionCapability((y:ExtensionCapability)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:FirewallRule((y:FirewallRule)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:GraphicsDeviceModel((y:GraphicsDeviceModel)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:HelmChart((y:HelmChart)) -- subClassOf --> y:SoftwareArtifact((y:SoftwareArtifact))
y:HelmValues((y:HelmValues)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:HostCondition((y:HostCondition)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:ISOImage((y:ISOImage)) -- subClassOf --> y:InstallationImage((y:InstallationImage))
y:IncidentDetectionPolicy((y:IncidentDetectionPolicy)) -- subClassOf --> y:Policy((y:Policy))
y:InfrastructureAsCode((y:InfrastructureAsCode)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:InstallationImage((y:InstallationImage)) -- subClassOf --> y:Artifact((y:Artifact))
y:Kubeconfig((y:Kubeconfig)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:KubernetesConfigMap((y:KubernetesConfigMap)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:KubernetesContext((y:KubernetesContext)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:KubernetesIngress((y:KubernetesIngress)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:KubernetesSecret((y:KubernetesSecret)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:LanguageFallback((y:LanguageFallback)) -- subClassOf --> y:Policy((y:Policy))
y:LogLevel((y:LogLevel)) -- subClassOf --> y:Policy((y:Policy))
y:Mount((y:Mount)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:MoveMode((y:MoveMode)) -- subClassOf --> y:Policy((y:Policy))
y:N8n((y:N8n)) -- subClassOf --> r_N8n_dependsOn_NodeJS_((Anonymous class))
y:N8n((y:N8n)) -- subClassOf --> y:SoftwareArtifact((y:SoftwareArtifact))
y:NetworkProfile((y:NetworkProfile)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:NoUpstreamMode((y:NoUpstreamMode)) -- subClassOf --> y:Policy((y:Policy))
y:NodeJS((y:NodeJS)) -- subClassOf --> y:SoftwareArtifact((y:SoftwareArtifact))
y:NotificationPolicy((y:NotificationPolicy)) -- subClassOf --> y:Policy((y:Policy))
y:OCRCombinePolicy((y:OCRCombinePolicy)) -- subClassOf --> y:Policy((y:Policy))
y:OfflineMode((y:OfflineMode)) -- subClassOf --> y:Policy((y:Policy))
y:OpenClaw((y:OpenClaw)) -- subClassOf --> r_OpenClaw_dependsOn_NodeJS_((Anonymous class))
y:OpenClaw((y:OpenClaw)) -- subClassOf --> y:SoftwareArtifact((y:SoftwareArtifact))
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
y:SeedImage((y:SeedImage)) -- subClassOf --> y:Artifact((y:Artifact))
y:SequenceAction((y:SequenceAction)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:Snapshot((y:Snapshot)) -- subClassOf --> y:Artifact((y:Artifact))
y:SnapshotManifest((y:SnapshotManifest)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:SoftwareArtifact -- y:builtFrom --> y:InformationArtifact
y:SoftwareArtifact((y:SoftwareArtifact)) -- subClassOf --> y:Artifact((y:Artifact))
y:SoftwareDependency((y:SoftwareDependency)) -- subClassOf --> y:SoftwareArtifact((y:SoftwareArtifact))
y:StashEntry((y:StashEntry)) -- subClassOf --> r_StashEntry_storedIn_StashStorage_((Anonymous class))
y:StashEntry((y:StashEntry)) -- subClassOf --> y:Artifact((y:Artifact))
y:StaticAddressConfiguration((y:StaticAddressConfiguration)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:StaticHostMapping((y:StaticHostMapping)) -- subClassOf --> y:ConfigurationArtifact((y:ConfigurationArtifact))
y:TLSCertificateSecret((y:TLSCertificateSecret)) -- subClassOf --> y:KubernetesSecret((y:KubernetesSecret))
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
