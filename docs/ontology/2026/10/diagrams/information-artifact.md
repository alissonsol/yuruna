# Information artifact diagram

`y:InformationArtifact` is recorded information with a role in configuration,
execution, communication, or evidence. This page draws it from version 2026/10
of the [Yuruna ontology](../yuruna.owl): the classes under it, the object
properties whose `rdfs:domain` is one of those classes, and their existential
restrictions.

Its largest branches are drawn on pages of their own: [Artifact](artifact.md),
[Identifier](identifier.md), [Quantity](quantity.md), [Protocol](protocol.md).

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
subgraph r_AmisAdActiveCampaign_usesCreative_AmisAdCreativeAsset_[Restriction &exist; R C]
r_AmisAdActiveCampaign_usesCreative_AmisAdCreativeAsset_thing((thing)) --> r_AmisAdActiveCampaign_usesCreative_AmisAdCreativeAsset_y:usesCreative[y:usesCreative]
r_AmisAdActiveCampaign_usesCreative_AmisAdCreativeAsset_y:usesCreative[y:usesCreative]
-- some --> r_AmisAdActiveCampaign_usesCreative_AmisAdCreativeAsset_y:AmisAdCreativeAsset((y:AmisAdCreativeAsset))
end
subgraph r_AmisAdAttribution_creditsCampaign_AmisAdCampaign_[Restriction &exist; R C]
r_AmisAdAttribution_creditsCampaign_AmisAdCampaign_thing((thing)) --> r_AmisAdAttribution_creditsCampaign_AmisAdCampaign_y:creditsCampaign[y:creditsCampaign]
r_AmisAdAttribution_creditsCampaign_AmisAdCampaign_y:creditsCampaign[y:creditsCampaign]
-- some --> r_AmisAdAttribution_creditsCampaign_AmisAdCampaign_y:AmisAdCampaign((y:AmisAdCampaign))
end
subgraph r_AmisAdAttribution_creditsCreative_AmisAdCreativeAsset_[Restriction &exist; R C]
r_AmisAdAttribution_creditsCreative_AmisAdCreativeAsset_thing((thing)) --> r_AmisAdAttribution_creditsCreative_AmisAdCreativeAsset_y:creditsCreative[y:creditsCreative]
r_AmisAdAttribution_creditsCreative_AmisAdCreativeAsset_y:creditsCreative[y:creditsCreative]
-- some --> r_AmisAdAttribution_creditsCreative_AmisAdCreativeAsset_y:AmisAdCreativeAsset((y:AmisAdCreativeAsset))
end
subgraph r_AmisAdMandate_authorizesDelegate_AmisAdDelegate_[Restriction &exist; R C]
r_AmisAdMandate_authorizesDelegate_AmisAdDelegate_thing((thing)) --> r_AmisAdMandate_authorizesDelegate_AmisAdDelegate_y:authorizesDelegate[y:authorizesDelegate]
r_AmisAdMandate_authorizesDelegate_AmisAdDelegate_y:authorizesDelegate[y:authorizesDelegate]
-- some --> r_AmisAdMandate_authorizesDelegate_AmisAdDelegate_y:AmisAdDelegate((y:AmisAdDelegate))
end
subgraph r_AmisAdMandate_representsPrincipal_AmisAdPrincipal_[Restriction &exist; R C]
r_AmisAdMandate_representsPrincipal_AmisAdPrincipal_thing((thing)) --> r_AmisAdMandate_representsPrincipal_AmisAdPrincipal_y:representsPrincipal[y:representsPrincipal]
r_AmisAdMandate_representsPrincipal_AmisAdPrincipal_y:representsPrincipal[y:representsPrincipal]
-- some --> r_AmisAdMandate_representsPrincipal_AmisAdPrincipal_y:AmisAdPrincipal((y:AmisAdPrincipal))
end
subgraph r_AmisAdMatch_matchesNeed_AmisAdNeed_[Restriction &exist; R C]
r_AmisAdMatch_matchesNeed_AmisAdNeed_thing((thing)) --> r_AmisAdMatch_matchesNeed_AmisAdNeed_y:matchesNeed[y:matchesNeed]
r_AmisAdMatch_matchesNeed_AmisAdNeed_y:matchesNeed[y:matchesNeed]
-- some --> r_AmisAdMatch_matchesNeed_AmisAdNeed_y:AmisAdNeed((y:AmisAdNeed))
end
subgraph r_AmisAdMatch_matchesOffer_AmisAdOffer_[Restriction &exist; R C]
r_AmisAdMatch_matchesOffer_AmisAdOffer_thing((thing)) --> r_AmisAdMatch_matchesOffer_AmisAdOffer_y:matchesOffer[y:matchesOffer]
r_AmisAdMatch_matchesOffer_AmisAdOffer_y:matchesOffer[y:matchesOffer]
-- some --> r_AmisAdMatch_matchesOffer_AmisAdOffer_y:AmisAdOffer((y:AmisAdOffer))
end
subgraph r_AmisAdNeed_requestedByBuyer_AmisAdBuyer_[Restriction &exist; R C]
r_AmisAdNeed_requestedByBuyer_AmisAdBuyer_thing((thing)) --> r_AmisAdNeed_requestedByBuyer_AmisAdBuyer_y:requestedByBuyer[y:requestedByBuyer]
r_AmisAdNeed_requestedByBuyer_AmisAdBuyer_y:requestedByBuyer[y:requestedByBuyer]
-- some --> r_AmisAdNeed_requestedByBuyer_AmisAdBuyer_y:AmisAdBuyer((y:AmisAdBuyer))
end
subgraph r_AmisAdOffer_offeredBySeller_AmisAdSeller_[Restriction &exist; R C]
r_AmisAdOffer_offeredBySeller_AmisAdSeller_thing((thing)) --> r_AmisAdOffer_offeredBySeller_AmisAdSeller_y:offeredBySeller[y:offeredBySeller]
r_AmisAdOffer_offeredBySeller_AmisAdSeller_y:offeredBySeller[y:offeredBySeller]
-- some --> r_AmisAdOffer_offeredBySeller_AmisAdSeller_y:AmisAdSeller((y:AmisAdSeller))
end
subgraph r_DHCPLease_leasesAddress_IPAddress_[Restriction &exist; R C]
r_DHCPLease_leasesAddress_IPAddress_thing((thing)) --> r_DHCPLease_leasesAddress_IPAddress_y:leasesAddress[y:leasesAddress]
r_DHCPLease_leasesAddress_IPAddress_y:leasesAddress[y:leasesAddress]
-- some --> r_DHCPLease_leasesAddress_IPAddress_y:IPAddress((y:IPAddress))
end
subgraph r_FailureRecord_hasSeverity_FailureSeverity_[Restriction &exist; R C]
r_FailureRecord_hasSeverity_FailureSeverity_thing((thing)) --> r_FailureRecord_hasSeverity_FailureSeverity_y:hasSeverity[y:hasSeverity]
r_FailureRecord_hasSeverity_FailureSeverity_y:hasSeverity[y:hasSeverity]
-- some --> r_FailureRecord_hasSeverity_FailureSeverity_y:FailureSeverity((y:FailureSeverity))
end
subgraph r_MessageCatalog_containsMessage_MessageTemplate_[Restriction &exist; R C]
r_MessageCatalog_containsMessage_MessageTemplate_thing((thing)) --> r_MessageCatalog_containsMessage_MessageTemplate_y:containsMessage[y:containsMessage]
r_MessageCatalog_containsMessage_MessageTemplate_y:containsMessage[y:containsMessage]
-- some --> r_MessageCatalog_containsMessage_MessageTemplate_y:MessageTemplate((y:MessageTemplate))
end
subgraph r_MessageTemplate_identifiedByKey_MessageKey_[Restriction &exist; R C]
r_MessageTemplate_identifiedByKey_MessageKey_thing((thing)) --> r_MessageTemplate_identifiedByKey_MessageKey_y:identifiedByKey[y:identifiedByKey]
r_MessageTemplate_identifiedByKey_MessageKey_y:identifiedByKey[y:identifiedByKey]
-- some --> r_MessageTemplate_identifiedByKey_MessageKey_y:MessageKey((y:MessageKey))
end
subgraph r_Project_selectsConfiguration_CloudConfiguration_[Restriction &exist; R C]
r_Project_selectsConfiguration_CloudConfiguration_thing((thing)) --> r_Project_selectsConfiguration_CloudConfiguration_y:selectsConfiguration[y:selectsConfiguration]
r_Project_selectsConfiguration_CloudConfiguration_y:selectsConfiguration[y:selectsConfiguration]
-- some --> r_Project_selectsConfiguration_CloudConfiguration_y:CloudConfiguration((y:CloudConfiguration))
end
subgraph r_TextSQLChurnEvent_forSubscription_TextSQLSubscription_[Restriction &exist; R C]
r_TextSQLChurnEvent_forSubscription_TextSQLSubscription_thing((thing)) --> r_TextSQLChurnEvent_forSubscription_TextSQLSubscription_y:forSubscription[y:forSubscription]
r_TextSQLChurnEvent_forSubscription_TextSQLSubscription_y:forSubscription[y:forSubscription]
-- some --> r_TextSQLChurnEvent_forSubscription_TextSQLSubscription_y:TextSQLSubscription((y:TextSQLSubscription))
end
subgraph r_TextSQLInvoice_forSubscription_TextSQLSubscription_[Restriction &exist; R C]
r_TextSQLInvoice_forSubscription_TextSQLSubscription_thing((thing)) --> r_TextSQLInvoice_forSubscription_TextSQLSubscription_y:forSubscription[y:forSubscription]
r_TextSQLInvoice_forSubscription_TextSQLSubscription_y:forSubscription[y:forSubscription]
-- some --> r_TextSQLInvoice_forSubscription_TextSQLSubscription_y:TextSQLSubscription((y:TextSQLSubscription))
end
subgraph r_TextSQLSubscription_forCustomer_TextSQLCustomer_[Restriction &exist; R C]
r_TextSQLSubscription_forCustomer_TextSQLCustomer_thing((thing)) --> r_TextSQLSubscription_forCustomer_TextSQLCustomer_y:forCustomer[y:forCustomer]
r_TextSQLSubscription_forCustomer_TextSQLCustomer_y:forCustomer[y:forCustomer]
-- some --> r_TextSQLSubscription_forCustomer_TextSQLCustomer_y:TextSQLCustomer((y:TextSQLCustomer))
end
subgraph r_TextSQLSubscription_usesTier_TextSQLPlanTier_[Restriction &exist; R C]
r_TextSQLSubscription_usesTier_TextSQLPlanTier_thing((thing)) --> r_TextSQLSubscription_usesTier_TextSQLPlanTier_y:usesTier[y:usesTier]
r_TextSQLSubscription_usesTier_TextSQLPlanTier_y:usesTier[y:usesTier]
-- some --> r_TextSQLSubscription_usesTier_TextSQLPlanTier_y:TextSQLPlanTier((y:TextSQLPlanTier))
end
subgraph r_Translation_translates_InformationArtifact_[Restriction &exist; R C]
r_Translation_translates_InformationArtifact_thing((thing)) --> r_Translation_translates_InformationArtifact_y:translates[y:translates]
r_Translation_translates_InformationArtifact_y:translates[y:translates]
-- some --> r_Translation_translates_InformationArtifact_y:InformationArtifact((y:InformationArtifact))
end
y:AMD64Architecture((y:AMD64Architecture)) -- subClassOf --> y:ProcessorArchitecture((y:ProcessorArchitecture))
y:ARM64Architecture((y:ARM64Architecture)) -- subClassOf --> y:ProcessorArchitecture((y:ProcessorArchitecture))
y:AccessKey((y:AccessKey)) -- subClassOf --> y:Credential((y:Credential))
y:AgentTimeline((y:AgentTimeline)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AgentTimeline((y:AgentTimeline)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:AlertNotification((y:AlertNotification)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AlternativeTerm((y:AlternativeTerm)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdActiveCampaign((y:AmisAdActiveCampaign)) -- subClassOf --> r_AmisAdActiveCampaign_usesCreative_AmisAdCreativeAsset_((Anonymous class))
y:AmisAdActiveCampaign((y:AmisAdActiveCampaign)) -- subClassOf --> y:AmisAdCampaign((y:AmisAdCampaign))
y:AmisAdAd((y:AmisAdAd)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdAd((y:AmisAdAd)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdAppointment((y:AmisAdAppointment)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdAppointment((y:AmisAdAppointment)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdAttestation((y:AmisAdAttestation)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdAttestation((y:AmisAdAttestation)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdAttribution -- y:creditsCampaign --> y:AmisAdCampaign
y:AmisAdAttribution -- y:creditsCreative --> y:AmisAdCreativeAsset
y:AmisAdAttribution((y:AmisAdAttribution)) -- subClassOf --> r_AmisAdAttribution_creditsCampaign_AmisAdCampaign_((Anonymous class))
y:AmisAdAttribution((y:AmisAdAttribution)) -- subClassOf --> r_AmisAdAttribution_creditsCreative_AmisAdCreativeAsset_((Anonymous class))
y:AmisAdAttribution((y:AmisAdAttribution)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdAttribution((y:AmisAdAttribution)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdAuditCertificate((y:AmisAdAuditCertificate)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdAuditCertificate((y:AmisAdAuditCertificate)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdCampaign -- y:promotesOffer --> y:AmisAdOffer
y:AmisAdCampaign -- y:usesCreative --> y:AmisAdCreativeAsset
y:AmisAdCampaign((y:AmisAdCampaign)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdCampaign((y:AmisAdCampaign)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdCompensatingEntry((y:AmisAdCompensatingEntry)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdCompensatingEntry((y:AmisAdCompensatingEntry)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdConsentGrant((y:AmisAdConsentGrant)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdConsentGrant((y:AmisAdConsentGrant)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdConsentLedger((y:AmisAdConsentLedger)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdConsentLedger((y:AmisAdConsentLedger)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdContributionGrant((y:AmisAdContributionGrant)) -- subClassOf --> y:AmisAdConsentGrant((y:AmisAdConsentGrant))
y:AmisAdCreativeBrief((y:AmisAdCreativeBrief)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdCreativeBrief((y:AmisAdCreativeBrief)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdDemandInsight((y:AmisAdDemandInsight)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdDemandInsight((y:AmisAdDemandInsight)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdDisclosureGrant((y:AmisAdDisclosureGrant)) -- subClassOf --> y:AmisAdConsentGrant((y:AmisAdConsentGrant))
y:AmisAdDraftCampaign((y:AmisAdDraftCampaign)) -- subClassOf --> y:AmisAdCampaign((y:AmisAdCampaign))
y:AmisAdHashChain((y:AmisAdHashChain)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdHashChain((y:AmisAdHashChain)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdIntegrationGrant((y:AmisAdIntegrationGrant)) -- subClassOf --> y:AmisAdConsentGrant((y:AmisAdConsentGrant))
y:AmisAdInventory((y:AmisAdInventory)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdInventory((y:AmisAdInventory)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdLifecycleEvidence((y:AmisAdLifecycleEvidence)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdLifecycleEvidence((y:AmisAdLifecycleEvidence)) -- subClassOf --> y:DiagnosticEvidence((y:DiagnosticEvidence))
y:AmisAdMandate -- y:authorizesDelegate --> y:AmisAdDelegate
y:AmisAdMandate -- y:representsPrincipal --> y:AmisAdPrincipal
y:AmisAdMandate((y:AmisAdMandate)) -- subClassOf --> r_AmisAdMandate_authorizesDelegate_AmisAdDelegate_((Anonymous class))
y:AmisAdMandate((y:AmisAdMandate)) -- subClassOf --> r_AmisAdMandate_representsPrincipal_AmisAdPrincipal_((Anonymous class))
y:AmisAdMandate((y:AmisAdMandate)) -- subClassOf --> y:AmisAdConsentGrant((y:AmisAdConsentGrant))
y:AmisAdMatch -- y:matchesNeed --> y:AmisAdNeed
y:AmisAdMatch -- y:matchesOffer --> y:AmisAdOffer
y:AmisAdMatch((y:AmisAdMatch)) -- subClassOf --> r_AmisAdMatch_matchesNeed_AmisAdNeed_((Anonymous class))
y:AmisAdMatch((y:AmisAdMatch)) -- subClassOf --> r_AmisAdMatch_matchesOffer_AmisAdOffer_((Anonymous class))
y:AmisAdMatch((y:AmisAdMatch)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdMatch((y:AmisAdMatch)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdNeed -- y:requestedByBuyer --> y:AmisAdBuyer
y:AmisAdNeed((y:AmisAdNeed)) -- subClassOf --> r_AmisAdNeed_requestedByBuyer_AmisAdBuyer_((Anonymous class))
y:AmisAdNeed((y:AmisAdNeed)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdNeed((y:AmisAdNeed)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdNeedEnvelope((y:AmisAdNeedEnvelope)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdNeedEnvelope((y:AmisAdNeedEnvelope)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdOffer -- y:offeredBySeller --> y:AmisAdSeller
y:AmisAdOffer((y:AmisAdOffer)) -- subClassOf --> r_AmisAdOffer_offeredBySeller_AmisAdSeller_((Anonymous class))
y:AmisAdOffer((y:AmisAdOffer)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdOffer((y:AmisAdOffer)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdOfferCatalog((y:AmisAdOfferCatalog)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdOfferCatalog((y:AmisAdOfferCatalog)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdOrder((y:AmisAdOrder)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdOrder((y:AmisAdOrder)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdParticipationGrant((y:AmisAdParticipationGrant)) -- subClassOf --> y:AmisAdConsentGrant((y:AmisAdConsentGrant))
y:AmisAdSettlementInstruction((y:AmisAdSettlementInstruction)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdSettlementInstruction((y:AmisAdSettlementInstruction)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdSettlementLedger((y:AmisAdSettlementLedger)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdSettlementLedger((y:AmisAdSettlementLedger)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdShortlist((y:AmisAdShortlist)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdShortlist((y:AmisAdShortlist)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdSupportCase((y:AmisAdSupportCase)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdSupportCase((y:AmisAdSupportCase)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdValueSplit((y:AmisAdValueSplit)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdValueSplit((y:AmisAdValueSplit)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:Archive((y:Archive)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:Artifact((y:Artifact)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:ArtifactGeneration((y:ArtifactGeneration)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:ArtifactManifest((y:ArtifactManifest)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AutomationResultManifest((y:AutomationResultManifest)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:BearerToken((y:BearerToken)) -- subClassOf --> y:Credential((y:Credential))
y:BearerToken((y:BearerToken)) -- subClassOf --> y:Secret((y:Secret))
y:CacheWarmSet((y:CacheWarmSet)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:CapabilityMatrix((y:CapabilityMatrix)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:CompletionSentinel((y:CompletionSentinel)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:ControlProof((y:ControlProof)) -- subClassOf --> y:Credential((y:Credential))
y:CounterMetric((y:CounterMetric)) -- subClassOf --> y:Metric((y:Metric))
y:Credential((y:Credential)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:CycleArchive((y:CycleArchive)) -- subClassOf --> y:Archive((y:Archive))
y:DHCPLease -- y:leasesAddress --> y:IPAddress
y:DHCPLease((y:DHCPLease)) -- subClassOf --> r_DHCPLease_leasesAddress_IPAddress_((Anonymous class))
y:DHCPLease((y:DHCPLease)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:DNSRecord((y:DNSRecord)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:DashboardPanel((y:DashboardPanel)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:DiagnosticEvidence((y:DiagnosticEvidence)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:DominantFailureClass((y:DominantFailureClass)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:EscalateRecommendation((y:EscalateRecommendation)) -- subClassOf --> y:RecoveryRecommendation((y:RecoveryRecommendation))
y:EventRecord((y:EventRecord)) -- subClassOf --> y:DiagnosticEvidence((y:DiagnosticEvidence))
y:ExampleProject((y:ExampleProject)) -- subClassOf --> y:Project((y:Project))
y:FailureClassHistogram((y:FailureClassHistogram)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:FailureRecord -- y:hasSeverity --> y:FailureSeverity
y:FailureRecord -- y:suggests --> y:RecoveryRecommendation
y:FailureRecord((y:FailureRecord)) -- subClassOf --> r_FailureRecord_hasSeverity_FailureSeverity_((Anonymous class))
y:FailureRecord((y:FailureRecord)) -- subClassOf --> y:DiagnosticEvidence((y:DiagnosticEvidence))
y:ForeignKey((y:ForeignKey)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:Framebuffer((y:Framebuffer)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:GaugeMetric((y:GaugeMetric)) -- subClassOf --> y:Metric((y:Metric))
y:GuestHostBinding((y:GuestHostBinding)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:HTTPRangeRequest((y:HTTPRangeRequest)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:Heartbeat((y:Heartbeat)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:HostAnnouncement((y:HostAnnouncement)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:Identifier((y:Identifier)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:InformationArtifact -- y:storedIn --> y:StorageResource
y:InformationArtifact((y:InformationArtifact)) -- subClassOf --> y:Entity((y:Entity))
y:IntegrityManifest((y:IntegrityManifest)) -- subClassOf --> y:ArtifactManifest((y:ArtifactManifest))
y:InternalServiceKey((y:InternalServiceKey)) -- subClassOf --> y:Credential((y:Credential))
y:InternalServiceKey((y:InternalServiceKey)) -- subClassOf --> y:Secret((y:Secret))
y:JSONWebToken((y:JSONWebToken)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:Keystroke((y:Keystroke)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:LabToken((y:LabToken)) -- subClassOf --> y:Credential((y:Credential))
y:LabToken((y:LabToken)) -- subClassOf --> y:Secret((y:Secret))
y:LanguageModelToken((y:LanguageModelToken)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:LogStream((y:LogStream)) -- subClassOf --> y:DiagnosticEvidence((y:DiagnosticEvidence))
y:MessageCatalog -- y:containsMessage --> y:MessageTemplate
y:MessageCatalog((y:MessageCatalog)) -- subClassOf --> r_MessageCatalog_containsMessage_MessageTemplate_((Anonymous class))
y:MessageCatalog((y:MessageCatalog)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:MessageTemplate -- y:identifiedByKey --> y:MessageKey
y:MessageTemplate((y:MessageTemplate)) -- subClassOf --> r_MessageTemplate_identifiedByKey_MessageKey_((Anonymous class))
y:MessageTemplate((y:MessageTemplate)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:Metric((y:Metric)) -- subClassOf --> y:Telemetry((y:Telemetry))
y:NDJSON((y:NDJSON)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:NaturalLanguageQuestion((y:NaturalLanguageQuestion)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:NaturalLanguageQuestion((y:NaturalLanguageQuestion)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:NeighborTable((y:NeighborTable)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:NonzeroScriptExitMarker((y:NonzeroScriptExitMarker)) -- subClassOf --> y:TextPattern((y:TextPattern))
y:OCRNearMiss((y:OCRNearMiss)) -- subClassOf --> y:DiagnosticEvidence((y:DiagnosticEvidence))
y:OCRText((y:OCRText)) -- subClassOf --> y:DiagnosticEvidence((y:DiagnosticEvidence))
y:OperatorInterventionRecommendation((y:OperatorInterventionRecommendation)) -- subClassOf --> y:RecoveryRecommendation((y:RecoveryRecommendation))
y:PackageMetadata((y:PackageMetadata)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:PauseAndInspectRecommendation((y:PauseAndInspectRecommendation)) -- subClassOf --> y:RecoveryRecommendation((y:RecoveryRecommendation))
y:PluralForm((y:PluralForm)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:PoolMembership((y:PoolMembership)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:PreferredTerm((y:PreferredTerm)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:ProcessTree((y:ProcessTree)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:ProcessorArchitecture((y:ProcessorArchitecture)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:ProgressAdvisory((y:ProgressAdvisory)) -- subClassOf --> y:DiagnosticEvidence((y:DiagnosticEvidence))
y:Project -- y:selectsConfiguration --> y:CloudConfiguration
y:Project((y:Project)) -- subClassOf --> r_Project_selectsConfiguration_CloudConfiguration_((Anonymous class))
y:Project((y:Project)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:ProjectTemplate((y:ProjectTemplate)) -- subClassOf --> y:Project((y:Project))
y:Protocol((y:Protocol)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:ProxyProtocolHeader((y:ProxyProtocolHeader)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:Quantity((y:Quantity)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:QueryResult((y:QueryResult)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:QueryResult((y:QueryResult)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:ReadinessVerdict((y:ReadinessVerdict)) -- subClassOf --> y:DiagnosticEvidence((y:DiagnosticEvidence))
y:ReconnectRecommendation((y:ReconnectRecommendation)) -- subClassOf --> y:RecoveryRecommendation((y:RecoveryRecommendation))
y:RecoveryLedger -- y:recordsAttempt --> y:RecoveryAction
y:RecoveryLedger((y:RecoveryLedger)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:RecoveryRecommendation((y:RecoveryRecommendation)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:RegistryRepository((y:RegistryRepository)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:ReleaseManifest((y:ReleaseManifest)) -- subClassOf --> y:ArtifactManifest((y:ArtifactManifest))
y:ReleaseSignature((y:ReleaseSignature)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:ReplicationBacklog((y:ReplicationBacklog)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:ReplicationLedger((y:ReplicationLedger)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:RestartFromSnapshotRecommendation((y:RestartFromSnapshotRecommendation)) -- subClassOf --> y:RecoveryRecommendation((y:RecoveryRecommendation))
y:RetryImmediatelyRecommendation((y:RetryImmediatelyRecommendation)) -- subClassOf --> y:RecoveryRecommendation((y:RecoveryRecommendation))
y:RetryWithBackoffRecommendation((y:RetryWithBackoffRecommendation)) -- subClassOf --> y:RecoveryRecommendation((y:RecoveryRecommendation))
y:RouterAdvertisement((y:RouterAdvertisement)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:RunnerStatus((y:RunnerStatus)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:SQLDecision((y:SQLDecision)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:SQLDecision((y:SQLDecision)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:SQLRefusal((y:SQLRefusal)) -- subClassOf --> y:SQLDecision((y:SQLDecision))
y:SSHHostKey((y:SSHHostKey)) -- subClassOf --> y:Credential((y:Credential))
y:SSHKeyPair((y:SSHKeyPair)) -- subClassOf --> y:Credential((y:Credential))
y:SchemaCatalog((y:SchemaCatalog)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:SchemaCatalog((y:SchemaCatalog)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:SchemaSlice((y:SchemaSlice)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:SchemaSlice((y:SchemaSlice)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:Screenshot((y:Screenshot)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:Secret((y:Secret)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:ServerNameIndication((y:ServerNameIndication)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:ShortLinkCatalog((y:ShortLinkCatalog)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:Snippet((y:Snippet)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:SoftwareBillOfMaterials((y:SoftwareBillOfMaterials)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:StaleContent((y:StaleContent)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:StatusDashboard((y:StatusDashboard)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:StorageCredential((y:StorageCredential)) -- subClassOf --> y:Credential((y:Credential))
y:StructuredLog((y:StructuredLog)) -- subClassOf --> y:LogStream((y:LogStream))
y:TLSCertificate((y:TLSCertificate)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:Telemetry((y:Telemetry)) -- subClassOf --> y:AssessmentView((y:AssessmentView))
y:Telemetry((y:Telemetry)) -- subClassOf --> y:DiagnosticEvidence((y:DiagnosticEvidence))
y:TerminologyGlossary((y:TerminologyGlossary)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:TextPattern((y:TextPattern)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:TextSQLAcquisitionChannel((y:TextSQLAcquisitionChannel)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:TextSQLAcquisitionChannel((y:TextSQLAcquisitionChannel)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:TextSQLChurnEvent((y:TextSQLChurnEvent)) -- subClassOf --> r_TextSQLChurnEvent_forSubscription_TextSQLSubscription_((Anonymous class))
y:TextSQLChurnEvent((y:TextSQLChurnEvent)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:TextSQLChurnEvent((y:TextSQLChurnEvent)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:TextSQLCustomer((y:TextSQLCustomer)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:TextSQLCustomer((y:TextSQLCustomer)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:TextSQLGeography((y:TextSQLGeography)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:TextSQLGeography((y:TextSQLGeography)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:TextSQLInvoice((y:TextSQLInvoice)) -- subClassOf --> r_TextSQLInvoice_forSubscription_TextSQLSubscription_((Anonymous class))
y:TextSQLInvoice((y:TextSQLInvoice)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:TextSQLInvoice((y:TextSQLInvoice)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:TextSQLPlanTier((y:TextSQLPlanTier)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:TextSQLPlanTier((y:TextSQLPlanTier)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:TextSQLSubscription -- y:forCustomer --> y:TextSQLCustomer
y:TextSQLSubscription -- y:usesTier --> y:TextSQLPlanTier
y:TextSQLSubscription((y:TextSQLSubscription)) -- subClassOf --> r_TextSQLSubscription_forCustomer_TextSQLCustomer_((Anonymous class))
y:TextSQLSubscription((y:TextSQLSubscription)) -- subClassOf --> r_TextSQLSubscription_usesTier_TextSQLPlanTier_((Anonymous class))
y:TextSQLSubscription((y:TextSQLSubscription)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:TextSQLSubscription((y:TextSQLSubscription)) -- subClassOf --> y:TextSQLDomainEntity((y:TextSQLDomainEntity))
y:TimeSeries((y:TimeSeries)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:Topology((y:Topology)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:Transcript((y:Transcript)) -- subClassOf --> y:DiagnosticEvidence((y:DiagnosticEvidence))
y:Translation -- y:translates --> y:InformationArtifact
y:Translation((y:Translation)) -- subClassOf --> r_Translation_translates_InformationArtifact_((Anonymous class))
y:Translation((y:Translation)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:TranslationProvenance((y:TranslationProvenance)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:WaitChannel((y:WaitChannel)) -- subClassOf --> y:DiagnosticEvidence((y:DiagnosticEvidence))
y:WriterLease((y:WriterLease)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.22

Back to [Yuruna ontology diagrams](../../../README.md#425aed30-0005)
