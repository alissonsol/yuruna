# Software localization and documentation diagram

The `software:` namespace, `https://yuruna.com/ontology/2026/10/software#`,
holds the software engineering vocabulary: artifacts, releases, container images
and registries, configuration, deployment, Kubernetes resources, packages,
localization, and documentation. This page draws the localization and
documentation part of the namespace (locales, translations, glossaries, message
catalogs, and the short links of the documentation): these classes, the object
properties of the namespace drawn here, and the existential restrictions on
these classes, from version 2026/10 of the [Yuruna ontology](../yuruna.owl).

The namespace's other pages: [Software delivery and
configuration](software-delivery.md).

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
software:DocumentIdentifier((software:DocumentIdentifier)) -- subClassOf --> y:Identifier[y:Identifier]
software:Globalization((software:Globalization)) -- subClassOf --> y:Process[y:Process]
software:HeadingAnchor((software:HeadingAnchor)) -- subClassOf --> y:Identifier[y:Identifier]
software:LanguageFallback((software:LanguageFallback)) -- subClassOf --> y:Policy[y:Policy]
software:LinkAlias -- software:aliasOfLink --> software:ShortLink
software:LinkAlias((software:LinkAlias)) -- subClassOf --> y:Identifier[y:Identifier]
software:Locale((software:Locale)) -- subClassOf --> y:Identifier[y:Identifier]
software:LocaleNegotiation -- software:selectsLocale --> software:Locale
software:LocaleNegotiation((software:LocaleNegotiation)) -- subClassOf --> r_LocaleNegotiation_selectsLocale_Locale_((Anonymous class))
software:LocaleNegotiation((software:LocaleNegotiation)) -- subClassOf --> y:Process[y:Process]
software:LocaleRedirect((software:LocaleRedirect)) -- subClassOf --> y:Process[y:Process]
software:Localization((software:Localization)) -- subClassOf --> y:Process[y:Process]
software:MessageCatalog -- software:containsMessage --> software:MessageTemplate
software:MessageCatalog((software:MessageCatalog)) -- subClassOf --> r_MessageCatalog_containsMessage_MessageTemplate_((Anonymous class))
software:MessageCatalog((software:MessageCatalog)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
software:MessageKey((software:MessageKey)) -- subClassOf --> y:Identifier[y:Identifier]
software:MessagePlaceholder((software:MessagePlaceholder)) -- subClassOf --> y:Identifier[y:Identifier]
software:MessageTemplate -- software:identifiedByKey --> software:MessageKey
software:MessageTemplate((software:MessageTemplate)) -- subClassOf --> r_MessageTemplate_identifiedByKey_MessageKey_((Anonymous class))
software:MessageTemplate((software:MessageTemplate)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
software:PluralForm((software:PluralForm)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
software:ProtectedToken((software:ProtectedToken)) -- subClassOf --> y:Identifier[y:Identifier]
software:Pseudolocalization((software:Pseudolocalization)) -- subClassOf --> y:Process[y:Process]
software:ShortLink((software:ShortLink)) -- subClassOf --> y:Identifier[y:Identifier]
software:ShortLinkCatalog((software:ShortLinkCatalog)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
software:TerminologyGlossary((software:TerminologyGlossary)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
software:TextDirection((software:TextDirection)) -- subClassOf --> y:Policy[y:Policy]
software:Translation -- software:translates --> y:InformationArtifact
software:Translation((software:Translation)) -- subClassOf --> r_Translation_translates_InformationArtifact_((Anonymous class))
software:Translation((software:Translation)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
software:TranslationProvenance((software:TranslationProvenance)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
software:TranslationReview -- software:usesGlossary --> software:TerminologyGlossary
software:TranslationReview((software:TranslationReview)) -- subClassOf --> r_TranslationReview_usesGlossary_TerminologyGlossary_((Anonymous class))
software:TranslationReview((software:TranslationReview)) -- subClassOf --> y:Process[y:Process]
subgraph r_LocaleNegotiation_selectsLocale_Locale_[Restriction &exist; R C]
r_LocaleNegotiation_selectsLocale_Locale_thing((thing)) --> r_LocaleNegotiation_selectsLocale_Locale_software:selectsLocale[software:selectsLocale]
r_LocaleNegotiation_selectsLocale_Locale_software:selectsLocale[software:selectsLocale]
-- some --> r_LocaleNegotiation_selectsLocale_Locale_software:Locale((software:Locale))
end
subgraph r_MessageCatalog_containsMessage_MessageTemplate_[Restriction &exist; R C]
r_MessageCatalog_containsMessage_MessageTemplate_thing((thing)) --> r_MessageCatalog_containsMessage_MessageTemplate_software:containsMessage[software:containsMessage]
r_MessageCatalog_containsMessage_MessageTemplate_software:containsMessage[software:containsMessage]
-- some --> r_MessageCatalog_containsMessage_MessageTemplate_software:MessageTemplate((software:MessageTemplate))
end
subgraph r_MessageTemplate_identifiedByKey_MessageKey_[Restriction &exist; R C]
r_MessageTemplate_identifiedByKey_MessageKey_thing((thing)) --> r_MessageTemplate_identifiedByKey_MessageKey_software:identifiedByKey[software:identifiedByKey]
r_MessageTemplate_identifiedByKey_MessageKey_software:identifiedByKey[software:identifiedByKey]
-- some --> r_MessageTemplate_identifiedByKey_MessageKey_software:MessageKey((software:MessageKey))
end
subgraph r_TranslationReview_usesGlossary_TerminologyGlossary_[Restriction &exist; R C]
r_TranslationReview_usesGlossary_TerminologyGlossary_thing((thing)) --> r_TranslationReview_usesGlossary_TerminologyGlossary_software:usesGlossary[software:usesGlossary]
r_TranslationReview_usesGlossary_TerminologyGlossary_software:usesGlossary[software:usesGlossary]
-- some --> r_TranslationReview_usesGlossary_TerminologyGlossary_software:TerminologyGlossary((software:TerminologyGlossary))
end
subgraph r_Translation_translates_InformationArtifact_[Restriction &exist; R C]
r_Translation_translates_InformationArtifact_thing((thing)) --> r_Translation_translates_InformationArtifact_software:translates[software:translates]
r_Translation_translates_InformationArtifact_software:translates[software:translates]
-- some --> r_Translation_translates_InformationArtifact_y:InformationArtifact((y:InformationArtifact))
end
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.11.05

Back to [Yuruna ontology diagrams](../../../README.md#425aed30-0005)
