# Process diagram

`y:Process` is an activity or execution that changes, checks, or observes system
state. This page draws it from version 2026/10 of the [Yuruna
ontology](../yuruna.owl): the classes under it, the object properties whose
`rdfs:domain` is one of those classes, and their existential restrictions.

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
subgraph r_AmisAdFulfillment_fulfillsOrder_AmisAdOrder_[Restriction &exist; R C]
r_AmisAdFulfillment_fulfillsOrder_AmisAdOrder_thing((thing)) --> r_AmisAdFulfillment_fulfillsOrder_AmisAdOrder_y:fulfillsOrder[y:fulfillsOrder]
r_AmisAdFulfillment_fulfillsOrder_AmisAdOrder_y:fulfillsOrder[y:fulfillsOrder]
-- some --> r_AmisAdFulfillment_fulfillsOrder_AmisAdOrder_y:AmisAdOrder((y:AmisAdOrder))
end
subgraph r_AmisAdSettlement_compensatesMatch_AmisAdMatch_[Restriction &exist; R C]
r_AmisAdSettlement_compensatesMatch_AmisAdMatch_thing((thing)) --> r_AmisAdSettlement_compensatesMatch_AmisAdMatch_y:compensatesMatch[y:compensatesMatch]
r_AmisAdSettlement_compensatesMatch_AmisAdMatch_y:compensatesMatch[y:compensatesMatch]
-- some --> r_AmisAdSettlement_compensatesMatch_AmisAdMatch_y:AmisAdMatch((y:AmisAdMatch))
end
subgraph r_ChecksumVerification_verifiesArtifact_Artifact_[Restriction &exist; R C]
r_ChecksumVerification_verifiesArtifact_Artifact_thing((thing)) --> r_ChecksumVerification_verifiesArtifact_Artifact_y:verifiesArtifact[y:verifiesArtifact]
r_ChecksumVerification_verifiesArtifact_Artifact_y:verifiesArtifact[y:verifiesArtifact]
-- some --> r_ChecksumVerification_verifiesArtifact_Artifact_y:Artifact((y:Artifact))
end
subgraph r_DeploymentPipeline_hasPart_ComponentPublication_[Restriction &exist; R C]
r_DeploymentPipeline_hasPart_ComponentPublication_thing((thing)) --> r_DeploymentPipeline_hasPart_ComponentPublication_y:hasPart[y:hasPart]
r_DeploymentPipeline_hasPart_ComponentPublication_y:hasPart[y:hasPart]
-- some --> r_DeploymentPipeline_hasPart_ComponentPublication_y:ComponentPublication((y:ComponentPublication))
end
subgraph r_DeploymentPipeline_hasPart_ResourceProvisioning_[Restriction &exist; R C]
r_DeploymentPipeline_hasPart_ResourceProvisioning_thing((thing)) --> r_DeploymentPipeline_hasPart_ResourceProvisioning_y:hasPart[y:hasPart]
r_DeploymentPipeline_hasPart_ResourceProvisioning_y:hasPart[y:hasPart]
-- some --> r_DeploymentPipeline_hasPart_ResourceProvisioning_y:ResourceProvisioning((y:ResourceProvisioning))
end
subgraph r_DeploymentPipeline_hasPart_WorkloadDeployment_[Restriction &exist; R C]
r_DeploymentPipeline_hasPart_WorkloadDeployment_thing((thing)) --> r_DeploymentPipeline_hasPart_WorkloadDeployment_y:hasPart[y:hasPart]
r_DeploymentPipeline_hasPart_WorkloadDeployment_y:hasPart[y:hasPart]
-- some --> r_DeploymentPipeline_hasPart_WorkloadDeployment_y:WorkloadDeployment((y:WorkloadDeployment))
end
subgraph r_LocaleNegotiation_selectsLocale_Locale_[Restriction &exist; R C]
r_LocaleNegotiation_selectsLocale_Locale_thing((thing)) --> r_LocaleNegotiation_selectsLocale_Locale_y:selectsLocale[y:selectsLocale]
r_LocaleNegotiation_selectsLocale_Locale_y:selectsLocale[y:selectsLocale]
-- some --> r_LocaleNegotiation_selectsLocale_Locale_y:Locale((y:Locale))
end
subgraph r_RecoveryAction_addressesIncident_Incident_[Restriction &exist; R C]
r_RecoveryAction_addressesIncident_Incident_thing((thing)) --> r_RecoveryAction_addressesIncident_Incident_y:addressesIncident[y:addressesIncident]
r_RecoveryAction_addressesIncident_Incident_y:addressesIncident[y:addressesIncident]
-- some --> r_RecoveryAction_addressesIncident_Incident_y:Incident((y:Incident))
end
subgraph r_SignatureVerification_verifiesArtifact_Artifact_[Restriction &exist; R C]
r_SignatureVerification_verifiesArtifact_Artifact_thing((thing)) --> r_SignatureVerification_verifiesArtifact_Artifact_y:verifiesArtifact[y:verifiesArtifact]
r_SignatureVerification_verifiesArtifact_Artifact_y:verifiesArtifact[y:verifiesArtifact]
-- some --> r_SignatureVerification_verifiesArtifact_Artifact_y:Artifact((y:Artifact))
end
subgraph r_StorageReplication_replicatesTo_PoolStorage_[Restriction &exist; R C]
r_StorageReplication_replicatesTo_PoolStorage_thing((thing)) --> r_StorageReplication_replicatesTo_PoolStorage_y:replicatesTo[y:replicatesTo]
r_StorageReplication_replicatesTo_PoolStorage_y:replicatesTo[y:replicatesTo]
-- some --> r_StorageReplication_replicatesTo_PoolStorage_y:PoolStorage((y:PoolStorage))
end
subgraph r_TestStep_executesAction_SequenceAction_[Restriction &exist; R C]
r_TestStep_executesAction_SequenceAction_thing((thing)) --> r_TestStep_executesAction_SequenceAction_y:executesAction[y:executesAction]
r_TestStep_executesAction_SequenceAction_y:executesAction[y:executesAction]
-- some --> r_TestStep_executesAction_SequenceAction_y:SequenceAction((y:SequenceAction))
end
subgraph r_TranslationReview_usesGlossary_TerminologyGlossary_[Restriction &exist; R C]
r_TranslationReview_usesGlossary_TerminologyGlossary_thing((thing)) --> r_TranslationReview_usesGlossary_TerminologyGlossary_y:usesGlossary[y:usesGlossary]
r_TranslationReview_usesGlossary_TerminologyGlossary_y:usesGlossary[y:usesGlossary]
-- some --> r_TranslationReview_usesGlossary_TerminologyGlossary_y:TerminologyGlossary((y:TerminologyGlossary))
end
y:APIPA((y:APIPA)) -- subClassOf --> y:Process((y:Process))
y:AddressDiscoveryCheck((y:AddressDiscoveryCheck)) -- subClassOf --> y:DiagnosticCheck((y:DiagnosticCheck))
y:AmisAdFulfillment -- y:fulfillsOrder --> y:AmisAdOrder
y:AmisAdFulfillment((y:AmisAdFulfillment)) -- subClassOf --> r_AmisAdFulfillment_fulfillsOrder_AmisAdOrder_((Anonymous class))
y:AmisAdFulfillment((y:AmisAdFulfillment)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdFulfillment((y:AmisAdFulfillment)) -- subClassOf --> y:Process((y:Process))
y:AmisAdIdempotentReplay((y:AmisAdIdempotentReplay)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdIdempotentReplay((y:AmisAdIdempotentReplay)) -- subClassOf --> y:Process((y:Process))
y:AmisAdRefund((y:AmisAdRefund)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdRefund((y:AmisAdRefund)) -- subClassOf --> y:Process((y:Process))
y:AmisAdSettlement -- y:compensatesMatch --> y:AmisAdMatch
y:AmisAdSettlement((y:AmisAdSettlement)) -- subClassOf --> r_AmisAdSettlement_compensatesMatch_AmisAdMatch_((Anonymous class))
y:AmisAdSettlement((y:AmisAdSettlement)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdSettlement((y:AmisAdSettlement)) -- subClassOf --> y:Process((y:Process))
y:ArtifactIntegrityCheck((y:ArtifactIntegrityCheck)) -- subClassOf --> y:DiagnosticCheck((y:DiagnosticCheck))
y:AtomicPromotion((y:AtomicPromotion)) -- subClassOf --> y:Process((y:Process))
y:Authentication((y:Authentication)) -- subClassOf --> y:Process((y:Process))
y:Authorization((y:Authorization)) -- subClassOf --> y:Process((y:Process))
y:Autoinstall((y:Autoinstall)) -- subClassOf --> y:Process((y:Process))
y:Backoff((y:Backoff)) -- subClassOf --> y:Process((y:Process))
y:Bootstrap((y:Bootstrap)) -- subClassOf --> y:Process((y:Process))
y:CacheBust((y:CacheBust)) -- subClassOf --> y:Process((y:Process))
y:CacheRevalidation((y:CacheRevalidation)) -- subClassOf --> y:Process((y:Process))
y:CacheWarmup((y:CacheWarmup)) -- subClassOf --> y:Process((y:Process))
y:CaptureHealthCheck((y:CaptureHealthCheck)) -- subClassOf --> y:DiagnosticCheck((y:DiagnosticCheck))
y:ChecksumVerification((y:ChecksumVerification)) -- subClassOf --> r_ChecksumVerification_verifiesArtifact_Artifact_((Anonymous class))
y:ChecksumVerification((y:ChecksumVerification)) -- subClassOf --> y:Process((y:Process))
y:ClearStaleGitLock((y:ClearStaleGitLock)) -- subClassOf --> y:RecoveryAction((y:RecoveryAction))
y:ClientAddressAttribution((y:ClientAddressAttribution)) -- subClassOf --> y:Process((y:Process))
y:ComponentPublication((y:ComponentPublication)) -- subClassOf --> y:DeploymentOperation((y:DeploymentOperation))
y:ComponentTestPhase((y:ComponentTestPhase)) -- subClassOf --> y:Process((y:Process))
y:ConsoleInput((y:ConsoleInput)) -- subClassOf --> y:Process((y:Process))
y:ContentAddressing((y:ContentAddressing)) -- subClassOf --> y:Process((y:Process))
y:DHCPLeaseCheck((y:DHCPLeaseCheck)) -- subClassOf --> y:DiagnosticCheck((y:DiagnosticCheck))
y:DNSResolutionCheck((y:DNSResolutionCheck)) -- subClassOf --> y:DiagnosticCheck((y:DiagnosticCheck))
y:Deduplication((y:Deduplication)) -- subClassOf --> y:Process((y:Process))
y:DeploymentOperation((y:DeploymentOperation)) -- subClassOf --> y:Process((y:Process))
y:DeploymentPipeline((y:DeploymentPipeline)) -- subClassOf --> r_DeploymentPipeline_hasPart_ComponentPublication_((Anonymous class))
y:DeploymentPipeline((y:DeploymentPipeline)) -- subClassOf --> r_DeploymentPipeline_hasPart_ResourceProvisioning_((Anonymous class))
y:DeploymentPipeline((y:DeploymentPipeline)) -- subClassOf --> r_DeploymentPipeline_hasPart_WorkloadDeployment_((Anonymous class))
y:DeploymentPipeline((y:DeploymentPipeline)) -- subClassOf --> y:Process((y:Process))
y:DiagnosticCheck -- y:checksElement --> y:SystemElement
y:DiagnosticCheck -- y:observes --> y:DiagnosticEvidence
y:DiagnosticCheck((y:DiagnosticCheck)) -- subClassOf --> y:Process((y:Process))
y:DownloadResume((y:DownloadResume)) -- subClassOf --> y:Process((y:Process))
y:Egress((y:Egress)) -- subClassOf --> y:Process((y:Process))
y:EndFailurePauseEarly((y:EndFailurePauseEarly)) -- subClassOf --> y:RecoveryAction((y:RecoveryAction))
y:EndToEndFetchCheck((y:EndToEndFetchCheck)) -- subClassOf --> y:DiagnosticCheck((y:DiagnosticCheck))
y:ExplainCardinalityGate((y:ExplainCardinalityGate)) -- subClassOf --> y:Process((y:Process))
y:ExplainCardinalityGate((y:ExplainCardinalityGate)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:ExtensionCall((y:ExtensionCall)) -- subClassOf --> y:Process((y:Process))
y:FailureClassification((y:FailureClassification)) -- subClassOf --> y:Process((y:Process))
y:FetchAndExecute((y:FetchAndExecute)) -- subClassOf --> y:Process((y:Process))
y:Globalization((y:Globalization)) -- subClassOf --> y:Process((y:Process))
y:GraphicsConfigurationCheck((y:GraphicsConfigurationCheck)) -- subClassOf --> y:DiagnosticCheck((y:DiagnosticCheck))
y:GuestAddressDiscovery((y:GuestAddressDiscovery)) -- subClassOf --> y:NetworkDiscovery((y:NetworkDiscovery))
y:GuestProcessCheck((y:GuestProcessCheck)) -- subClassOf --> y:DiagnosticCheck((y:DiagnosticCheck))
y:HealthProbe((y:HealthProbe)) -- subClassOf --> y:Process((y:Process))
y:HistoryBackfill((y:HistoryBackfill)) -- subClassOf --> y:Process((y:Process))
y:IdempotentOperation((y:IdempotentOperation)) -- subClassOf --> y:Process((y:Process))
y:ImageBuild((y:ImageBuild)) -- subClassOf --> y:Process((y:Process))
y:ImageResolver((y:ImageResolver)) -- subClassOf --> y:Process((y:Process))
y:Ingress((y:Ingress)) -- subClassOf --> y:Process((y:Process))
y:InnerLoop((y:InnerLoop)) -- subClassOf --> y:Process((y:Process))
y:LeaseRelease((y:LeaseRelease)) -- subClassOf --> y:Process((y:Process))
y:LeaseRenewal((y:LeaseRenewal)) -- subClassOf --> y:Process((y:Process))
y:LivenessProbe((y:LivenessProbe)) -- subClassOf --> y:HealthProbe((y:HealthProbe))
y:LocalFirstImagePull((y:LocalFirstImagePull)) -- subClassOf --> y:Process((y:Process))
y:LocaleNegotiation -- y:selectsLocale --> y:Locale
y:LocaleNegotiation((y:LocaleNegotiation)) -- subClassOf --> r_LocaleNegotiation_selectsLocale_Locale_((Anonymous class))
y:LocaleNegotiation((y:LocaleNegotiation)) -- subClassOf --> y:Process((y:Process))
y:LocaleRedirect((y:LocaleRedirect)) -- subClassOf --> y:Process((y:Process))
y:Localization((y:Localization)) -- subClassOf --> y:Process((y:Process))
y:LogRotation((y:LogRotation)) -- subClassOf --> y:Process((y:Process))
y:ManualImageDrop((y:ManualImageDrop)) -- subClassOf --> y:Process((y:Process))
y:MemoryBallooning((y:MemoryBallooning)) -- subClassOf --> y:Process((y:Process))
y:MetricScrape((y:MetricScrape)) -- subClassOf --> y:Process((y:Process))
y:MutualTLSAuthentication((y:MutualTLSAuthentication)) -- subClassOf --> y:Authentication((y:Authentication))
y:NAT((y:NAT)) -- subClassOf --> y:Process((y:Process))
y:NATFallback((y:NATFallback)) -- subClassOf --> y:Process((y:Process))
y:NameResolution((y:NameResolution)) -- subClassOf --> y:Process((y:Process))
y:NestedVirtualization((y:NestedVirtualization)) -- subClassOf --> y:Process((y:Process))
y:NetworkDiscovery((y:NetworkDiscovery)) -- subClassOf --> y:Process((y:Process))
y:OpticalCharacterRecognition((y:OpticalCharacterRecognition)) -- subClassOf --> y:Process((y:Process))
y:OuterLoop((y:OuterLoop)) -- subClassOf --> y:Process((y:Process))
y:PacketCapture((y:PacketCapture)) -- subClassOf --> y:DiagnosticCheck((y:DiagnosticCheck))
y:PatternMatch((y:PatternMatch)) -- subClassOf --> y:Process((y:Process))
y:PlanValidation((y:PlanValidation)) -- subClassOf --> y:Process((y:Process))
y:Polling((y:Polling)) -- subClassOf --> y:Process((y:Process))
y:PortForwarding((y:PortForwarding)) -- subClassOf --> y:Process((y:Process))
y:PrivilegeElevation((y:PrivilegeElevation)) -- subClassOf --> y:Process((y:Process))
y:Process -- y:consumes --> y:Entity
y:Process -- y:precedes --> y:Process
y:Process -- y:produces --> y:Entity
y:Process -- y:verifiesArtifact --> y:Artifact
y:Process((y:Process)) -- subClassOf --> y:Entity((y:Entity))
y:ProcessWaitCheck((y:ProcessWaitCheck)) -- subClassOf --> y:DiagnosticCheck((y:DiagnosticCheck))
y:Provisioning((y:Provisioning)) -- subClassOf --> y:Process((y:Process))
y:ProxyCheck((y:ProxyCheck)) -- subClassOf --> y:DiagnosticCheck((y:DiagnosticCheck))
y:ProxyTunnelCheck((y:ProxyTunnelCheck)) -- subClassOf --> y:DiagnosticCheck((y:DiagnosticCheck))
y:Pseudolocalization((y:Pseudolocalization)) -- subClassOf --> y:Process((y:Process))
y:QueryExecution((y:QueryExecution)) -- subClassOf --> y:Process((y:Process))
y:QueryExecution((y:QueryExecution)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:ReadinessProbe((y:ReadinessProbe)) -- subClassOf --> y:HealthProbe((y:HealthProbe))
y:RecloneProject((y:RecloneProject)) -- subClassOf --> y:RecoveryAction((y:RecoveryAction))
y:RecoveryAction -- y:addressesIncident --> y:Incident
y:RecoveryAction((y:RecoveryAction)) -- subClassOf --> r_RecoveryAction_addressesIncident_Incident_((Anonymous class))
y:RecoveryAction((y:RecoveryAction)) -- subClassOf --> y:Process((y:Process))
y:RegistryAuthentication((y:RegistryAuthentication)) -- subClassOf --> y:Process((y:Process))
y:ReleaseDryRun((y:ReleaseDryRun)) -- subClassOf --> y:Process((y:Process))
y:ResourceProvisioning((y:ResourceProvisioning)) -- subClassOf --> y:DeploymentOperation((y:DeploymentOperation))
y:ResourceTestPhase((y:ResourceTestPhase)) -- subClassOf --> y:Process((y:Process))
y:RetryAttempt((y:RetryAttempt)) -- subClassOf --> y:Process((y:Process))
y:RoutingCheck((y:RoutingCheck)) -- subClassOf --> y:DiagnosticCheck((y:DiagnosticCheck))
y:SCP((y:SCP)) -- subClassOf --> y:Process((y:Process))
y:SLAAC((y:SLAAC)) -- subClassOf --> y:Process((y:Process))
y:SQLGeneration -- y:generatesDecision --> y:SQLDecision
y:SQLGeneration((y:SQLGeneration)) -- subClassOf --> y:Process((y:Process))
y:SQLGeneration((y:SQLGeneration)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:SSHExecution((y:SSHExecution)) -- subClassOf --> y:Process((y:Process))
y:SchemaRetrieval -- y:retrievesSchema --> y:SchemaSlice
y:SchemaRetrieval((y:SchemaRetrieval)) -- subClassOf --> y:Process((y:Process))
y:SchemaRetrieval((y:SchemaRetrieval)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:SecureBoot((y:SecureBoot)) -- subClassOf --> y:Process((y:Process))
y:ServiceDiscovery((y:ServiceDiscovery)) -- subClassOf --> y:NetworkDiscovery((y:NetworkDiscovery))
y:SignatureVerification((y:SignatureVerification)) -- subClassOf --> r_SignatureVerification_verifiesArtifact_Artifact_((Anonymous class))
y:SignatureVerification((y:SignatureVerification)) -- subClassOf --> y:Process((y:Process))
y:SingleFlightDownload((y:SingleFlightDownload)) -- subClassOf --> y:Process((y:Process))
y:SocketStateCheck((y:SocketStateCheck)) -- subClassOf --> y:DiagnosticCheck((y:DiagnosticCheck))
y:StashUpload((y:StashUpload)) -- subClassOf --> y:Process((y:Process))
y:StaticSQLValidation((y:StaticSQLValidation)) -- subClassOf --> y:Process((y:Process))
y:StaticSQLValidation((y:StaticSQLValidation)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:StorageCapacityCheck((y:StorageCapacityCheck)) -- subClassOf --> y:DiagnosticCheck((y:DiagnosticCheck))
y:StorageReplication -- y:replicatesTo --> y:StorageResource
y:StorageReplication((y:StorageReplication)) -- subClassOf --> r_StorageReplication_replicatesTo_PoolStorage_((Anonymous class))
y:StorageReplication((y:StorageReplication)) -- subClassOf --> y:Process((y:Process))
y:StreamDrain((y:StreamDrain)) -- subClassOf --> y:Process((y:Process))
y:SystemDiagnostic((y:SystemDiagnostic)) -- subClassOf --> y:DiagnosticCheck((y:DiagnosticCheck))
y:TCPReachabilityCheck((y:TCPReachabilityCheck)) -- subClassOf --> y:DiagnosticCheck((y:DiagnosticCheck))
y:TLSInterception((y:TLSInterception)) -- subClassOf --> y:Process((y:Process))
y:TestCycle((y:TestCycle)) -- subClassOf --> y:Process((y:Process))
y:TestStep -- y:executesAction --> y:SequenceAction
y:TestStep((y:TestStep)) -- subClassOf --> r_TestStep_executesAction_SequenceAction_((Anonymous class))
y:TestStep((y:TestStep)) -- subClassOf --> y:Process((y:Process))
y:TranslationReview -- y:usesGlossary --> y:TerminologyGlossary
y:TranslationReview((y:TranslationReview)) -- subClassOf --> r_TranslationReview_usesGlossary_TerminologyGlossary_((Anonymous class))
y:TranslationReview((y:TranslationReview)) -- subClassOf --> y:Process((y:Process))
y:UnattendedInstallation((y:UnattendedInstallation)) -- subClassOf --> y:Process((y:Process))
y:UplinkBindingCheck((y:UplinkBindingCheck)) -- subClassOf --> y:DiagnosticCheck((y:DiagnosticCheck))
y:VMAdmission((y:VMAdmission)) -- subClassOf --> y:Process((y:Process))
y:WarmResume((y:WarmResume)) -- subClassOf --> y:Process((y:Process))
y:WorkloadDeployment((y:WorkloadDeployment)) -- subClassOf --> y:DeploymentOperation((y:DeploymentOperation))
y:WorkloadTestPhase((y:WorkloadTestPhase)) -- subClassOf --> y:Process((y:Process))
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.22

Back to [Yuruna ontology diagrams](../../../README.md#425aed30-0005)
