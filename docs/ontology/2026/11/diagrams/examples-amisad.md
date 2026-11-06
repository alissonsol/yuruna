# AmisAd example diagram

The `examples:` namespace, `https://yuruna.com/ontology/2026/11/examples#`,
holds the vocabulary of the example projects: the AmisAd matching and settlement
example, and the yuruna-project examples with their Text-to-SQL agent and
website. This page draws the AmisAd privacy-oriented matching and settlement
example: these classes, the object properties of the namespace drawn here, and
the existential restrictions on these classes, from version 2026/11 of the
[Yuruna ontology](../yuruna.owl).

The namespace's other pages: [yuruna-project
examples](examples-yuruna-project.md).

Circles are classes drawn on this page and boxes are classes drawn on another
page. A `subClassOf` arrow points from a class to its parent. An arrow labeled
with a property runs from its domain to its range. A frame titled Restriction is
an existential restriction on the class whose `subClassOf` arrow points at it:
each instance of that class has at least one value of the boxed property in the
circled class.

```mermaid
%%{init: {"flowchart": {"useMaxWidth": 0}}}%%
graph LR
classDef Datatype fill:#9c6,stroke:#9c6;
examples:AmisAdActiveCampaign((examples:AmisAdActiveCampaign)) -- subClassOf --> examples:AmisAdCampaign((examples:AmisAdCampaign))
examples:AmisAdActiveCampaign((examples:AmisAdActiveCampaign)) -- subClassOf --> r_AmisAdActiveCampaign_usesCreative_AmisAdCreativeAsset_((Anonymous class))
examples:AmisAdAd((examples:AmisAdAd)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdAd((examples:AmisAdAd)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdAgency((examples:AmisAdAgency)) -- subClassOf --> examples:AmisAdParticipantRole((examples:AmisAdParticipantRole))
examples:AmisAdAggregateTargeting((examples:AmisAdAggregateTargeting)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdAggregateTargeting((examples:AmisAdAggregateTargeting)) -- subClassOf --> y:Policy[y:Policy]
examples:AmisAdAppointment((examples:AmisAdAppointment)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdAppointment((examples:AmisAdAppointment)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdAttestation((examples:AmisAdAttestation)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdAttestation((examples:AmisAdAttestation)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdAttribution -- examples:creditsCampaign --> examples:AmisAdCampaign
examples:AmisAdAttribution -- examples:creditsCreative --> examples:AmisAdCreativeAsset
examples:AmisAdAttribution((examples:AmisAdAttribution)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdAttribution((examples:AmisAdAttribution)) -- subClassOf --> r_AmisAdAttribution_creditsCampaign_AmisAdCampaign_((Anonymous class))
examples:AmisAdAttribution((examples:AmisAdAttribution)) -- subClassOf --> r_AmisAdAttribution_creditsCreative_AmisAdCreativeAsset_((Anonymous class))
examples:AmisAdAttribution((examples:AmisAdAttribution)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdAuditCertificate((examples:AmisAdAuditCertificate)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdAuditCertificate((examples:AmisAdAuditCertificate)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdAuditor((examples:AmisAdAuditor)) -- subClassOf --> examples:AmisAdParticipantRole((examples:AmisAdParticipantRole))
examples:AmisAdBuyer((examples:AmisAdBuyer)) -- subClassOf --> examples:AmisAdParticipantRole((examples:AmisAdParticipantRole))
examples:AmisAdCampaign -- examples:promotesOffer --> examples:AmisAdOffer
examples:AmisAdCampaign -- examples:usesCreative --> examples:AmisAdCreativeAsset
examples:AmisAdCampaign((examples:AmisAdCampaign)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdCampaign((examples:AmisAdCampaign)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdCampaignBudget((examples:AmisAdCampaignBudget)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdCampaignBudget((examples:AmisAdCampaignBudget)) -- subClassOf --> y:Quantity[y:Quantity]
examples:AmisAdCarrier((examples:AmisAdCarrier)) -- subClassOf --> examples:AmisAdParticipantRole((examples:AmisAdParticipantRole))
examples:AmisAdClosingPolicy((examples:AmisAdClosingPolicy)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdClosingPolicy((examples:AmisAdClosingPolicy)) -- subClassOf --> y:Policy[y:Policy]
examples:AmisAdCompensatingEntry((examples:AmisAdCompensatingEntry)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdCompensatingEntry((examples:AmisAdCompensatingEntry)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdConnector((examples:AmisAdConnector)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdConnector((examples:AmisAdConnector)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
examples:AmisAdConsentGrant((examples:AmisAdConsentGrant)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdConsentGrant((examples:AmisAdConsentGrant)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdConsentLedger((examples:AmisAdConsentLedger)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdConsentLedger((examples:AmisAdConsentLedger)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdContributionGrant((examples:AmisAdContributionGrant)) -- subClassOf --> examples:AmisAdConsentGrant((examples:AmisAdConsentGrant))
examples:AmisAdCoordinator((examples:AmisAdCoordinator)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdCoordinator((examples:AmisAdCoordinator)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
examples:AmisAdCreativeAsset((examples:AmisAdCreativeAsset)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdCreativeAsset((examples:AmisAdCreativeAsset)) -- subClassOf --> y:Artifact[y:Artifact]
examples:AmisAdCreativeBrief((examples:AmisAdCreativeBrief)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdCreativeBrief((examples:AmisAdCreativeBrief)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdCreativePartner((examples:AmisAdCreativePartner)) -- subClassOf --> examples:AmisAdParticipantRole((examples:AmisAdParticipantRole))
examples:AmisAdDelegate((examples:AmisAdDelegate)) -- subClassOf --> examples:AmisAdParticipantRole((examples:AmisAdParticipantRole))
examples:AmisAdDemandInsight((examples:AmisAdDemandInsight)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdDemandInsight((examples:AmisAdDemandInsight)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdDisclosureGrant((examples:AmisAdDisclosureGrant)) -- subClassOf --> examples:AmisAdConsentGrant((examples:AmisAdConsentGrant))
examples:AmisAdDomainEntity((examples:AmisAdDomainEntity)) -- subClassOf --> y:Entity[y:Entity]
examples:AmisAdDraftCampaign((examples:AmisAdDraftCampaign)) -- subClassOf --> examples:AmisAdCampaign((examples:AmisAdCampaign))
examples:AmisAdFulfillment -- examples:fulfillsOrder --> examples:AmisAdOrder
examples:AmisAdFulfillment((examples:AmisAdFulfillment)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdFulfillment((examples:AmisAdFulfillment)) -- subClassOf --> r_AmisAdFulfillment_fulfillsOrder_AmisAdOrder_((Anonymous class))
examples:AmisAdFulfillment((examples:AmisAdFulfillment)) -- subClassOf --> y:Process[y:Process]
examples:AmisAdHashChain((examples:AmisAdHashChain)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdHashChain((examples:AmisAdHashChain)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdIdempotentReplay((examples:AmisAdIdempotentReplay)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdIdempotentReplay((examples:AmisAdIdempotentReplay)) -- subClassOf --> y:Process[y:Process]
examples:AmisAdIntegrationGrant((examples:AmisAdIntegrationGrant)) -- subClassOf --> examples:AmisAdConsentGrant((examples:AmisAdConsentGrant))
examples:AmisAdIntegrationPartner((examples:AmisAdIntegrationPartner)) -- subClassOf --> examples:AmisAdParticipantRole((examples:AmisAdParticipantRole))
examples:AmisAdInventory((examples:AmisAdInventory)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdInventory((examples:AmisAdInventory)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdInventoryVersion((examples:AmisAdInventoryVersion)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdInventoryVersion((examples:AmisAdInventoryVersion)) -- subClassOf --> y:Identifier[y:Identifier]
examples:AmisAdLifecycleEvidence((examples:AmisAdLifecycleEvidence)) -- subClassOf --> diagnostics:DiagnosticEvidence[diagnostics:DiagnosticEvidence]
examples:AmisAdLifecycleEvidence((examples:AmisAdLifecycleEvidence)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdMandate -- examples:authorizesDelegate --> examples:AmisAdDelegate
examples:AmisAdMandate -- examples:representsPrincipal --> examples:AmisAdPrincipal
examples:AmisAdMandate((examples:AmisAdMandate)) -- subClassOf --> examples:AmisAdConsentGrant((examples:AmisAdConsentGrant))
examples:AmisAdMandate((examples:AmisAdMandate)) -- subClassOf --> r_AmisAdMandate_authorizesDelegate_AmisAdDelegate_((Anonymous class))
examples:AmisAdMandate((examples:AmisAdMandate)) -- subClassOf --> r_AmisAdMandate_representsPrincipal_AmisAdPrincipal_((Anonymous class))
examples:AmisAdMatch -- examples:matchesNeed --> examples:AmisAdNeed
examples:AmisAdMatch -- examples:matchesOffer --> examples:AmisAdOffer
examples:AmisAdMatch((examples:AmisAdMatch)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdMatch((examples:AmisAdMatch)) -- subClassOf --> r_AmisAdMatch_matchesNeed_AmisAdNeed_((Anonymous class))
examples:AmisAdMatch((examples:AmisAdMatch)) -- subClassOf --> r_AmisAdMatch_matchesOffer_AmisAdOffer_((Anonymous class))
examples:AmisAdMatch((examples:AmisAdMatch)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdMatchingFabric((examples:AmisAdMatchingFabric)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdMatchingFabric((examples:AmisAdMatchingFabric)) -- subClassOf --> y:SystemElement[y:SystemElement]
examples:AmisAdNeed -- examples:requestedByBuyer --> examples:AmisAdBuyer
examples:AmisAdNeed((examples:AmisAdNeed)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdNeed((examples:AmisAdNeed)) -- subClassOf --> r_AmisAdNeed_requestedByBuyer_AmisAdBuyer_((Anonymous class))
examples:AmisAdNeed((examples:AmisAdNeed)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdNeedConstraint((examples:AmisAdNeedConstraint)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdNeedConstraint((examples:AmisAdNeedConstraint)) -- subClassOf --> y:Policy[y:Policy]
examples:AmisAdNeedEnvelope((examples:AmisAdNeedEnvelope)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdNeedEnvelope((examples:AmisAdNeedEnvelope)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdOffer -- examples:offeredBySeller --> examples:AmisAdSeller
examples:AmisAdOffer((examples:AmisAdOffer)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdOffer((examples:AmisAdOffer)) -- subClassOf --> r_AmisAdOffer_offeredBySeller_AmisAdSeller_((Anonymous class))
examples:AmisAdOffer((examples:AmisAdOffer)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdOfferCatalog((examples:AmisAdOfferCatalog)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdOfferCatalog((examples:AmisAdOfferCatalog)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdOrder((examples:AmisAdOrder)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdOrder((examples:AmisAdOrder)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdParticipantRole((examples:AmisAdParticipantRole)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdParticipationGrant((examples:AmisAdParticipationGrant)) -- subClassOf --> examples:AmisAdConsentGrant((examples:AmisAdConsentGrant))
examples:AmisAdPrincipal((examples:AmisAdPrincipal)) -- subClassOf --> examples:AmisAdParticipantRole((examples:AmisAdParticipantRole))
examples:AmisAdPrivacyThreshold((examples:AmisAdPrivacyThreshold)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdPrivacyThreshold((examples:AmisAdPrivacyThreshold)) -- subClassOf --> y:Policy[y:Policy]
examples:AmisAdRefund((examples:AmisAdRefund)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdRefund((examples:AmisAdRefund)) -- subClassOf --> y:Process[y:Process]
examples:AmisAdResource((examples:AmisAdResource)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdResource((examples:AmisAdResource)) -- subClassOf --> y:SystemElement[y:SystemElement]
examples:AmisAdSeller((examples:AmisAdSeller)) -- subClassOf --> examples:AmisAdParticipantRole((examples:AmisAdParticipantRole))
examples:AmisAdSettlement -- examples:compensatesMatch --> examples:AmisAdMatch
examples:AmisAdSettlement((examples:AmisAdSettlement)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdSettlement((examples:AmisAdSettlement)) -- subClassOf --> r_AmisAdSettlement_compensatesMatch_AmisAdMatch_((Anonymous class))
examples:AmisAdSettlement((examples:AmisAdSettlement)) -- subClassOf --> y:Process[y:Process]
examples:AmisAdSettlementInstruction((examples:AmisAdSettlementInstruction)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdSettlementInstruction((examples:AmisAdSettlementInstruction)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdSettlementLedger((examples:AmisAdSettlementLedger)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdSettlementLedger((examples:AmisAdSettlementLedger)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdShortlist((examples:AmisAdShortlist)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdShortlist((examples:AmisAdShortlist)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdSlice((examples:AmisAdSlice)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdSlice((examples:AmisAdSlice)) -- subClassOf --> y:SystemElement[y:SystemElement]
examples:AmisAdSovereigntyPolicy((examples:AmisAdSovereigntyPolicy)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdSovereigntyPolicy((examples:AmisAdSovereigntyPolicy)) -- subClassOf --> y:Policy[y:Policy]
examples:AmisAdSupportCase((examples:AmisAdSupportCase)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdSupportCase((examples:AmisAdSupportCase)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:AmisAdTenant((examples:AmisAdTenant)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdValueSplit((examples:AmisAdValueSplit)) -- subClassOf --> examples:AmisAdDomainEntity((examples:AmisAdDomainEntity))
examples:AmisAdValueSplit((examples:AmisAdValueSplit)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
subgraph r_AmisAdActiveCampaign_usesCreative_AmisAdCreativeAsset_[Restriction &exist; R C]
r_AmisAdActiveCampaign_usesCreative_AmisAdCreativeAsset_thing((thing)) --> r_AmisAdActiveCampaign_usesCreative_AmisAdCreativeAsset_examples:usesCreative[examples:usesCreative]
r_AmisAdActiveCampaign_usesCreative_AmisAdCreativeAsset_examples:usesCreative[examples:usesCreative]
-- some --> r_AmisAdActiveCampaign_usesCreative_AmisAdCreativeAsset_examples:AmisAdCreativeAsset((examples:AmisAdCreativeAsset))
end
subgraph r_AmisAdAttribution_creditsCampaign_AmisAdCampaign_[Restriction &exist; R C]
r_AmisAdAttribution_creditsCampaign_AmisAdCampaign_thing((thing)) --> r_AmisAdAttribution_creditsCampaign_AmisAdCampaign_examples:creditsCampaign[examples:creditsCampaign]
r_AmisAdAttribution_creditsCampaign_AmisAdCampaign_examples:creditsCampaign[examples:creditsCampaign]
-- some --> r_AmisAdAttribution_creditsCampaign_AmisAdCampaign_examples:AmisAdCampaign((examples:AmisAdCampaign))
end
subgraph r_AmisAdAttribution_creditsCreative_AmisAdCreativeAsset_[Restriction &exist; R C]
r_AmisAdAttribution_creditsCreative_AmisAdCreativeAsset_thing((thing)) --> r_AmisAdAttribution_creditsCreative_AmisAdCreativeAsset_examples:creditsCreative[examples:creditsCreative]
r_AmisAdAttribution_creditsCreative_AmisAdCreativeAsset_examples:creditsCreative[examples:creditsCreative]
-- some --> r_AmisAdAttribution_creditsCreative_AmisAdCreativeAsset_examples:AmisAdCreativeAsset((examples:AmisAdCreativeAsset))
end
subgraph r_AmisAdFulfillment_fulfillsOrder_AmisAdOrder_[Restriction &exist; R C]
r_AmisAdFulfillment_fulfillsOrder_AmisAdOrder_thing((thing)) --> r_AmisAdFulfillment_fulfillsOrder_AmisAdOrder_examples:fulfillsOrder[examples:fulfillsOrder]
r_AmisAdFulfillment_fulfillsOrder_AmisAdOrder_examples:fulfillsOrder[examples:fulfillsOrder]
-- some --> r_AmisAdFulfillment_fulfillsOrder_AmisAdOrder_examples:AmisAdOrder((examples:AmisAdOrder))
end
subgraph r_AmisAdMandate_authorizesDelegate_AmisAdDelegate_[Restriction &exist; R C]
r_AmisAdMandate_authorizesDelegate_AmisAdDelegate_thing((thing)) --> r_AmisAdMandate_authorizesDelegate_AmisAdDelegate_examples:authorizesDelegate[examples:authorizesDelegate]
r_AmisAdMandate_authorizesDelegate_AmisAdDelegate_examples:authorizesDelegate[examples:authorizesDelegate]
-- some --> r_AmisAdMandate_authorizesDelegate_AmisAdDelegate_examples:AmisAdDelegate((examples:AmisAdDelegate))
end
subgraph r_AmisAdMandate_representsPrincipal_AmisAdPrincipal_[Restriction &exist; R C]
r_AmisAdMandate_representsPrincipal_AmisAdPrincipal_thing((thing)) --> r_AmisAdMandate_representsPrincipal_AmisAdPrincipal_examples:representsPrincipal[examples:representsPrincipal]
r_AmisAdMandate_representsPrincipal_AmisAdPrincipal_examples:representsPrincipal[examples:representsPrincipal]
-- some --> r_AmisAdMandate_representsPrincipal_AmisAdPrincipal_examples:AmisAdPrincipal((examples:AmisAdPrincipal))
end
subgraph r_AmisAdMatch_matchesNeed_AmisAdNeed_[Restriction &exist; R C]
r_AmisAdMatch_matchesNeed_AmisAdNeed_thing((thing)) --> r_AmisAdMatch_matchesNeed_AmisAdNeed_examples:matchesNeed[examples:matchesNeed]
r_AmisAdMatch_matchesNeed_AmisAdNeed_examples:matchesNeed[examples:matchesNeed]
-- some --> r_AmisAdMatch_matchesNeed_AmisAdNeed_examples:AmisAdNeed((examples:AmisAdNeed))
end
subgraph r_AmisAdMatch_matchesOffer_AmisAdOffer_[Restriction &exist; R C]
r_AmisAdMatch_matchesOffer_AmisAdOffer_thing((thing)) --> r_AmisAdMatch_matchesOffer_AmisAdOffer_examples:matchesOffer[examples:matchesOffer]
r_AmisAdMatch_matchesOffer_AmisAdOffer_examples:matchesOffer[examples:matchesOffer]
-- some --> r_AmisAdMatch_matchesOffer_AmisAdOffer_examples:AmisAdOffer((examples:AmisAdOffer))
end
subgraph r_AmisAdNeed_requestedByBuyer_AmisAdBuyer_[Restriction &exist; R C]
r_AmisAdNeed_requestedByBuyer_AmisAdBuyer_thing((thing)) --> r_AmisAdNeed_requestedByBuyer_AmisAdBuyer_examples:requestedByBuyer[examples:requestedByBuyer]
r_AmisAdNeed_requestedByBuyer_AmisAdBuyer_examples:requestedByBuyer[examples:requestedByBuyer]
-- some --> r_AmisAdNeed_requestedByBuyer_AmisAdBuyer_examples:AmisAdBuyer((examples:AmisAdBuyer))
end
subgraph r_AmisAdOffer_offeredBySeller_AmisAdSeller_[Restriction &exist; R C]
r_AmisAdOffer_offeredBySeller_AmisAdSeller_thing((thing)) --> r_AmisAdOffer_offeredBySeller_AmisAdSeller_examples:offeredBySeller[examples:offeredBySeller]
r_AmisAdOffer_offeredBySeller_AmisAdSeller_examples:offeredBySeller[examples:offeredBySeller]
-- some --> r_AmisAdOffer_offeredBySeller_AmisAdSeller_examples:AmisAdSeller((examples:AmisAdSeller))
end
subgraph r_AmisAdSettlement_compensatesMatch_AmisAdMatch_[Restriction &exist; R C]
r_AmisAdSettlement_compensatesMatch_AmisAdMatch_thing((thing)) --> r_AmisAdSettlement_compensatesMatch_AmisAdMatch_examples:compensatesMatch[examples:compensatesMatch]
r_AmisAdSettlement_compensatesMatch_AmisAdMatch_examples:compensatesMatch[examples:compensatesMatch]
-- some --> r_AmisAdSettlement_compensatesMatch_AmisAdMatch_examples:AmisAdMatch((examples:AmisAdMatch))
end
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.11.05

Back to [Yuruna ontology diagrams](../../../README.md#425aed30-0005)
