# AmisAd domain entity diagram

`y:AmisAdDomainEntity` is a concept specific to the AmisAd privacy-oriented
matching and settlement example. This page draws it from version 2026/10 of the
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
subgraph r_AmisAdFulfillment_fulfillsOrder_AmisAdOrder_[Restriction &exist; R C]
r_AmisAdFulfillment_fulfillsOrder_AmisAdOrder_thing((thing)) --> r_AmisAdFulfillment_fulfillsOrder_AmisAdOrder_y:fulfillsOrder[y:fulfillsOrder]
r_AmisAdFulfillment_fulfillsOrder_AmisAdOrder_y:fulfillsOrder[y:fulfillsOrder]
-- some --> r_AmisAdFulfillment_fulfillsOrder_AmisAdOrder_y:AmisAdOrder((y:AmisAdOrder))
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
subgraph r_AmisAdSettlement_compensatesMatch_AmisAdMatch_[Restriction &exist; R C]
r_AmisAdSettlement_compensatesMatch_AmisAdMatch_thing((thing)) --> r_AmisAdSettlement_compensatesMatch_AmisAdMatch_y:compensatesMatch[y:compensatesMatch]
r_AmisAdSettlement_compensatesMatch_AmisAdMatch_y:compensatesMatch[y:compensatesMatch]
-- some --> r_AmisAdSettlement_compensatesMatch_AmisAdMatch_y:AmisAdMatch((y:AmisAdMatch))
end
y:AmisAdActiveCampaign((y:AmisAdActiveCampaign)) -- subClassOf --> r_AmisAdActiveCampaign_usesCreative_AmisAdCreativeAsset_((Anonymous class))
y:AmisAdActiveCampaign((y:AmisAdActiveCampaign)) -- subClassOf --> y:AmisAdCampaign((y:AmisAdCampaign))
y:AmisAdAd((y:AmisAdAd)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdAd((y:AmisAdAd)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdAgency((y:AmisAdAgency)) -- subClassOf --> y:AmisAdParticipantRole((y:AmisAdParticipantRole))
y:AmisAdAggregateTargeting((y:AmisAdAggregateTargeting)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdAggregateTargeting((y:AmisAdAggregateTargeting)) -- subClassOf --> y:Policy((y:Policy))
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
y:AmisAdAuditor((y:AmisAdAuditor)) -- subClassOf --> y:AmisAdParticipantRole((y:AmisAdParticipantRole))
y:AmisAdBuyer((y:AmisAdBuyer)) -- subClassOf --> y:AmisAdParticipantRole((y:AmisAdParticipantRole))
y:AmisAdCampaign -- y:promotesOffer --> y:AmisAdOffer
y:AmisAdCampaign -- y:usesCreative --> y:AmisAdCreativeAsset
y:AmisAdCampaign((y:AmisAdCampaign)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdCampaign((y:AmisAdCampaign)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdCampaignBudget((y:AmisAdCampaignBudget)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdCampaignBudget((y:AmisAdCampaignBudget)) -- subClassOf --> y:Quantity((y:Quantity))
y:AmisAdCarrier((y:AmisAdCarrier)) -- subClassOf --> y:AmisAdParticipantRole((y:AmisAdParticipantRole))
y:AmisAdClosingPolicy((y:AmisAdClosingPolicy)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdClosingPolicy((y:AmisAdClosingPolicy)) -- subClassOf --> y:Policy((y:Policy))
y:AmisAdCompensatingEntry((y:AmisAdCompensatingEntry)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdCompensatingEntry((y:AmisAdCompensatingEntry)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdConnector((y:AmisAdConnector)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdConnector((y:AmisAdConnector)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:AmisAdConsentGrant((y:AmisAdConsentGrant)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdConsentGrant((y:AmisAdConsentGrant)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdConsentLedger((y:AmisAdConsentLedger)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdConsentLedger((y:AmisAdConsentLedger)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdContributionGrant((y:AmisAdContributionGrant)) -- subClassOf --> y:AmisAdConsentGrant((y:AmisAdConsentGrant))
y:AmisAdCoordinator((y:AmisAdCoordinator)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdCoordinator((y:AmisAdCoordinator)) -- subClassOf --> y:SoftwareService((y:SoftwareService))
y:AmisAdCreativeAsset((y:AmisAdCreativeAsset)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdCreativeAsset((y:AmisAdCreativeAsset)) -- subClassOf --> y:Artifact((y:Artifact))
y:AmisAdCreativeBrief((y:AmisAdCreativeBrief)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdCreativeBrief((y:AmisAdCreativeBrief)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdCreativePartner((y:AmisAdCreativePartner)) -- subClassOf --> y:AmisAdParticipantRole((y:AmisAdParticipantRole))
y:AmisAdDelegate((y:AmisAdDelegate)) -- subClassOf --> y:AmisAdParticipantRole((y:AmisAdParticipantRole))
y:AmisAdDemandInsight((y:AmisAdDemandInsight)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdDemandInsight((y:AmisAdDemandInsight)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdDisclosureGrant((y:AmisAdDisclosureGrant)) -- subClassOf --> y:AmisAdConsentGrant((y:AmisAdConsentGrant))
y:AmisAdDomainEntity((y:AmisAdDomainEntity)) -- subClassOf --> y:Entity((y:Entity))
y:AmisAdDraftCampaign((y:AmisAdDraftCampaign)) -- subClassOf --> y:AmisAdCampaign((y:AmisAdCampaign))
y:AmisAdFulfillment -- y:fulfillsOrder --> y:AmisAdOrder
y:AmisAdFulfillment((y:AmisAdFulfillment)) -- subClassOf --> r_AmisAdFulfillment_fulfillsOrder_AmisAdOrder_((Anonymous class))
y:AmisAdFulfillment((y:AmisAdFulfillment)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdFulfillment((y:AmisAdFulfillment)) -- subClassOf --> y:Process((y:Process))
y:AmisAdHashChain((y:AmisAdHashChain)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdHashChain((y:AmisAdHashChain)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdIdempotentReplay((y:AmisAdIdempotentReplay)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdIdempotentReplay((y:AmisAdIdempotentReplay)) -- subClassOf --> y:Process((y:Process))
y:AmisAdIntegrationGrant((y:AmisAdIntegrationGrant)) -- subClassOf --> y:AmisAdConsentGrant((y:AmisAdConsentGrant))
y:AmisAdIntegrationPartner((y:AmisAdIntegrationPartner)) -- subClassOf --> y:AmisAdParticipantRole((y:AmisAdParticipantRole))
y:AmisAdInventory((y:AmisAdInventory)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdInventory((y:AmisAdInventory)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdInventoryVersion((y:AmisAdInventoryVersion)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdInventoryVersion((y:AmisAdInventoryVersion)) -- subClassOf --> y:Identifier((y:Identifier))
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
y:AmisAdMatchingFabric((y:AmisAdMatchingFabric)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdMatchingFabric((y:AmisAdMatchingFabric)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:AmisAdNeed -- y:requestedByBuyer --> y:AmisAdBuyer
y:AmisAdNeed((y:AmisAdNeed)) -- subClassOf --> r_AmisAdNeed_requestedByBuyer_AmisAdBuyer_((Anonymous class))
y:AmisAdNeed((y:AmisAdNeed)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdNeed((y:AmisAdNeed)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdNeedConstraint((y:AmisAdNeedConstraint)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdNeedConstraint((y:AmisAdNeedConstraint)) -- subClassOf --> y:Policy((y:Policy))
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
y:AmisAdParticipantRole((y:AmisAdParticipantRole)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdParticipationGrant((y:AmisAdParticipationGrant)) -- subClassOf --> y:AmisAdConsentGrant((y:AmisAdConsentGrant))
y:AmisAdPrincipal((y:AmisAdPrincipal)) -- subClassOf --> y:AmisAdParticipantRole((y:AmisAdParticipantRole))
y:AmisAdPrivacyThreshold((y:AmisAdPrivacyThreshold)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdPrivacyThreshold((y:AmisAdPrivacyThreshold)) -- subClassOf --> y:Policy((y:Policy))
y:AmisAdRefund((y:AmisAdRefund)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdRefund((y:AmisAdRefund)) -- subClassOf --> y:Process((y:Process))
y:AmisAdResource((y:AmisAdResource)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdResource((y:AmisAdResource)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:AmisAdSeller((y:AmisAdSeller)) -- subClassOf --> y:AmisAdParticipantRole((y:AmisAdParticipantRole))
y:AmisAdSettlement -- y:compensatesMatch --> y:AmisAdMatch
y:AmisAdSettlement((y:AmisAdSettlement)) -- subClassOf --> r_AmisAdSettlement_compensatesMatch_AmisAdMatch_((Anonymous class))
y:AmisAdSettlement((y:AmisAdSettlement)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdSettlement((y:AmisAdSettlement)) -- subClassOf --> y:Process((y:Process))
y:AmisAdSettlementInstruction((y:AmisAdSettlementInstruction)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdSettlementInstruction((y:AmisAdSettlementInstruction)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdSettlementLedger((y:AmisAdSettlementLedger)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdSettlementLedger((y:AmisAdSettlementLedger)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdShortlist((y:AmisAdShortlist)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdShortlist((y:AmisAdShortlist)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdSlice((y:AmisAdSlice)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdSlice((y:AmisAdSlice)) -- subClassOf --> y:SystemElement((y:SystemElement))
y:AmisAdSovereigntyPolicy((y:AmisAdSovereigntyPolicy)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdSovereigntyPolicy((y:AmisAdSovereigntyPolicy)) -- subClassOf --> y:Policy((y:Policy))
y:AmisAdSupportCase((y:AmisAdSupportCase)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdSupportCase((y:AmisAdSupportCase)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
y:AmisAdTenant((y:AmisAdTenant)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdValueSplit((y:AmisAdValueSplit)) -- subClassOf --> y:AmisAdDomainEntity((y:AmisAdDomainEntity))
y:AmisAdValueSplit((y:AmisAdValueSplit)) -- subClassOf --> y:InformationArtifact((y:InformationArtifact))
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.22

Back to [Yuruna ontology diagrams](../../../README.md#425aed30-0005)
