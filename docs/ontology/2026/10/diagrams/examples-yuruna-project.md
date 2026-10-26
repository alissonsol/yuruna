# yuruna-project examples diagram

The `examples:` namespace, `https://yuruna.com/ontology/2026/10/examples#`,
holds the vocabulary of the example projects: the AmisAd matching and settlement
example, and the yuruna-project examples with their Text-to-SQL agent and
website. This page draws the yuruna-project examples (the Text-to-SQL agent with
its subscription schema, the website, and the project template): these classes,
the object properties of the namespace drawn here, and the existential
restrictions on these classes, from version 2026/10 of the [Yuruna
ontology](../yuruna.owl).

The namespace's other pages: [AmisAd example](examples-amisad.md).

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
examples:AgentTimeline((examples:AgentTimeline)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:AgentTimeline((examples:AgentTimeline)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:CallerCancellation((examples:CallerCancellation)) -- subClassOf --> y:Situation[y:Situation]
examples:DependencyFailure((examples:DependencyFailure)) -- subClassOf --> diagnostics:Failure[diagnostics:Failure]
examples:EstimatedRowCount((examples:EstimatedRowCount)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:EstimatedRowCount((examples:EstimatedRowCount)) -- subClassOf --> y:Quantity[y:Quantity]
examples:ExampleProject((examples:ExampleProject)) -- subClassOf --> software:Project[software:Project]
examples:ExplainCardinalityGate((examples:ExplainCardinalityGate)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:ExplainCardinalityGate((examples:ExplainCardinalityGate)) -- subClassOf --> y:Process[y:Process]
examples:ForeignKey((examples:ForeignKey)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:LanguageModelClient((examples:LanguageModelClient)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:LanguageModelClient((examples:LanguageModelClient)) -- subClassOf --> y:SystemElement[y:SystemElement]
examples:LanguageModelToken((examples:LanguageModelToken)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:NaturalLanguageQuestion((examples:NaturalLanguageQuestion)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:NaturalLanguageQuestion((examples:NaturalLanguageQuestion)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:PostgreSQL((examples:PostgreSQL)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
examples:ProjectTemplate((examples:ProjectTemplate)) -- subClassOf --> software:Project[software:Project]
examples:QueryExecution((examples:QueryExecution)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:QueryExecution((examples:QueryExecution)) -- subClassOf --> y:Process[y:Process]
examples:QueryResult((examples:QueryResult)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:QueryResult((examples:QueryResult)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:RateLimitFailure((examples:RateLimitFailure)) -- subClassOf --> examples:DependencyFailure((examples:DependencyFailure))
examples:ReadOnlyRole((examples:ReadOnlyRole)) -- subClassOf --> software:Policy[software:Policy]
examples:ResponseParseFailure((examples:ResponseParseFailure)) -- subClassOf --> examples:DependencyFailure((examples:DependencyFailure))
examples:RetryBudget((examples:RetryBudget)) -- subClassOf --> software:Policy[software:Policy]
examples:RuleBasedSQLGenerator((examples:RuleBasedSQLGenerator)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:RuleBasedSQLGenerator((examples:RuleBasedSQLGenerator)) -- subClassOf --> y:SystemElement[y:SystemElement]
examples:SQLDecision((examples:SQLDecision)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:SQLDecision((examples:SQLDecision)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:SQLGeneration -- examples:generatesDecision --> examples:SQLDecision
examples:SQLGeneration((examples:SQLGeneration)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:SQLGeneration((examples:SQLGeneration)) -- subClassOf --> y:Process[y:Process]
examples:SQLRefusal((examples:SQLRefusal)) -- subClassOf --> examples:SQLDecision((examples:SQLDecision))
examples:SchemaCatalog((examples:SchemaCatalog)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:SchemaCatalog((examples:SchemaCatalog)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:SchemaRetrieval -- examples:retrievesSchema --> examples:SchemaSlice
examples:SchemaRetrieval((examples:SchemaRetrieval)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:SchemaRetrieval((examples:SchemaRetrieval)) -- subClassOf --> y:Process[y:Process]
examples:SchemaSlice((examples:SchemaSlice)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:SchemaSlice((examples:SchemaSlice)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:StaticSQLValidation((examples:StaticSQLValidation)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:StaticSQLValidation((examples:StaticSQLValidation)) -- subClassOf --> y:Process[y:Process]
examples:TextSQLAcquisitionChannel((examples:TextSQLAcquisitionChannel)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:TextSQLAcquisitionChannel((examples:TextSQLAcquisitionChannel)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:TextSQLAgent -- examples:answersQuestion --> examples:NaturalLanguageQuestion
examples:TextSQLAgent((examples:TextSQLAgent)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:TextSQLAgent((examples:TextSQLAgent)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
examples:TextSQLAnnualRecurringRevenue((examples:TextSQLAnnualRecurringRevenue)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:TextSQLAnnualRecurringRevenue((examples:TextSQLAnnualRecurringRevenue)) -- subClassOf --> y:Quantity[y:Quantity]
examples:TextSQLChurnEvent((examples:TextSQLChurnEvent)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:TextSQLChurnEvent((examples:TextSQLChurnEvent)) -- subClassOf --> r_TextSQLChurnEvent_forSubscription_TextSQLSubscription_((Anonymous class))
examples:TextSQLChurnEvent((examples:TextSQLChurnEvent)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:TextSQLCustomer((examples:TextSQLCustomer)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:TextSQLCustomer((examples:TextSQLCustomer)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:TextSQLDomainEntity -- examples:forSubscription --> examples:TextSQLSubscription
examples:TextSQLDomainEntity((examples:TextSQLDomainEntity)) -- subClassOf --> y:Entity[y:Entity]
examples:TextSQLGeography((examples:TextSQLGeography)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:TextSQLGeography((examples:TextSQLGeography)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:TextSQLInvoice((examples:TextSQLInvoice)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:TextSQLInvoice((examples:TextSQLInvoice)) -- subClassOf --> r_TextSQLInvoice_forSubscription_TextSQLSubscription_((Anonymous class))
examples:TextSQLInvoice((examples:TextSQLInvoice)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:TextSQLMonthlyRecurringRevenue((examples:TextSQLMonthlyRecurringRevenue)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:TextSQLMonthlyRecurringRevenue((examples:TextSQLMonthlyRecurringRevenue)) -- subClassOf --> y:Quantity[y:Quantity]
examples:TextSQLPlanTier((examples:TextSQLPlanTier)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:TextSQLPlanTier((examples:TextSQLPlanTier)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:TextSQLSubscription -- examples:forCustomer --> examples:TextSQLCustomer
examples:TextSQLSubscription -- examples:usesTier --> examples:TextSQLPlanTier
examples:TextSQLSubscription((examples:TextSQLSubscription)) -- subClassOf --> examples:TextSQLDomainEntity((examples:TextSQLDomainEntity))
examples:TextSQLSubscription((examples:TextSQLSubscription)) -- subClassOf --> r_TextSQLSubscription_forCustomer_TextSQLCustomer_((Anonymous class))
examples:TextSQLSubscription((examples:TextSQLSubscription)) -- subClassOf --> r_TextSQLSubscription_usesTier_TextSQLPlanTier_((Anonymous class))
examples:TextSQLSubscription((examples:TextSQLSubscription)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
examples:WebsiteFrontend((examples:WebsiteFrontend)) -- subClassOf --> software:ApplicationWorkload[software:ApplicationWorkload]
subgraph r_TextSQLChurnEvent_forSubscription_TextSQLSubscription_[Restriction &exist; R C]
r_TextSQLChurnEvent_forSubscription_TextSQLSubscription_thing((thing)) --> r_TextSQLChurnEvent_forSubscription_TextSQLSubscription_examples:forSubscription[examples:forSubscription]
r_TextSQLChurnEvent_forSubscription_TextSQLSubscription_examples:forSubscription[examples:forSubscription]
-- some --> r_TextSQLChurnEvent_forSubscription_TextSQLSubscription_examples:TextSQLSubscription((examples:TextSQLSubscription))
end
subgraph r_TextSQLInvoice_forSubscription_TextSQLSubscription_[Restriction &exist; R C]
r_TextSQLInvoice_forSubscription_TextSQLSubscription_thing((thing)) --> r_TextSQLInvoice_forSubscription_TextSQLSubscription_examples:forSubscription[examples:forSubscription]
r_TextSQLInvoice_forSubscription_TextSQLSubscription_examples:forSubscription[examples:forSubscription]
-- some --> r_TextSQLInvoice_forSubscription_TextSQLSubscription_examples:TextSQLSubscription((examples:TextSQLSubscription))
end
subgraph r_TextSQLSubscription_forCustomer_TextSQLCustomer_[Restriction &exist; R C]
r_TextSQLSubscription_forCustomer_TextSQLCustomer_thing((thing)) --> r_TextSQLSubscription_forCustomer_TextSQLCustomer_examples:forCustomer[examples:forCustomer]
r_TextSQLSubscription_forCustomer_TextSQLCustomer_examples:forCustomer[examples:forCustomer]
-- some --> r_TextSQLSubscription_forCustomer_TextSQLCustomer_examples:TextSQLCustomer((examples:TextSQLCustomer))
end
subgraph r_TextSQLSubscription_usesTier_TextSQLPlanTier_[Restriction &exist; R C]
r_TextSQLSubscription_usesTier_TextSQLPlanTier_thing((thing)) --> r_TextSQLSubscription_usesTier_TextSQLPlanTier_examples:usesTier[examples:usesTier]
r_TextSQLSubscription_usesTier_TextSQLPlanTier_examples:usesTier[examples:usesTier]
-- some --> r_TextSQLSubscription_usesTier_TextSQLPlanTier_examples:TextSQLPlanTier((examples:TextSQLPlanTier))
end
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.26

Back to [Yuruna ontology diagrams](../../../README.md#425aed30-0005)
