# Security diagram

The `security:` namespace, `https://yuruna.com/ontology/2026/10/security#`,
holds the security vocabulary: credentials, secrets, authentication,
certificates, trust, permissions, and the assessment views and conditions. This
page draws the security namespace: its classes, the object properties declared
in it, and the existential restrictions on those classes, from version 2026/10
of the [Yuruna ontology](../yuruna.owl).

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
security:AccessKey((security:AccessKey)) -- subClassOf --> security:Credential((security:Credential))
security:AccessibilityPermission((security:AccessibilityPermission)) -- subClassOf --> y:Policy[y:Policy]
security:AssessmentCondition((security:AssessmentCondition)) -- subClassOf --> y:Situation[y:Situation]
security:AssessmentView((security:AssessmentView)) -- subClassOf --> y:Entity[y:Entity]
security:Authentication((security:Authentication)) -- subClassOf --> y:Process[y:Process]
security:Authorization((security:Authorization)) -- subClassOf --> y:Process[y:Process]
security:Authorized((security:Authorized)) -- subClassOf --> security:AssessmentCondition((security:AssessmentCondition))
security:Baseline((security:Baseline)) -- subClassOf --> security:AssessmentView((security:AssessmentView))
security:BearerToken((security:BearerToken)) -- subClassOf --> security:Credential((security:Credential))
security:BearerToken((security:BearerToken)) -- subClassOf --> security:Secret((security:Secret))
security:CapturePermission((security:CapturePermission)) -- subClassOf --> y:Policy[y:Policy]
security:CertificateAuthority((security:CertificateAuthority)) -- subClassOf --> y:SystemElement[y:SystemElement]
security:CertificatePinning((security:CertificatePinning)) -- subClassOf --> y:Policy[y:Policy]
security:CertificateTrustFailure((security:CertificateTrustFailure)) -- subClassOf --> diagnostics:Failure[diagnostics:Failure]
security:ChecksumVerification((security:ChecksumVerification)) -- subClassOf --> r_ChecksumVerification_verifiesArtifact_Artifact_((Anonymous class))
security:ChecksumVerification((security:ChecksumVerification)) -- subClassOf --> y:Process[y:Process]
security:ControlProof((security:ControlProof)) -- subClassOf --> security:Credential((security:Credential))
security:Credential((security:Credential)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
security:CredentialExpiredFailure((security:CredentialExpiredFailure)) -- subClassOf --> diagnostics:Failure[diagnostics:Failure]
security:CredentialProvider((security:CredentialProvider)) -- subClassOf --> y:SystemElement[y:SystemElement]
security:Drift((security:Drift)) -- subClassOf --> security:AssessmentCondition((security:AssessmentCondition))
security:ElevationRequiredFailure((security:ElevationRequiredFailure)) -- subClassOf --> diagnostics:InfrastructureFailure[diagnostics:InfrastructureFailure]
security:Exposure((security:Exposure)) -- subClassOf --> security:AssessmentCondition((security:AssessmentCondition))
security:Finding((security:Finding)) -- subClassOf --> security:AssessmentCondition((security:AssessmentCondition))
security:GuestChannelKey((security:GuestChannelKey)) -- subClassOf --> security:Credential((security:Credential))
security:GuestChannelKey((security:GuestChannelKey)) -- subClassOf --> security:Secret((security:Secret))
security:Implementation((security:Implementation)) -- subClassOf --> security:AssessmentView((security:AssessmentView))
security:InternalServiceKey((security:InternalServiceKey)) -- subClassOf --> security:Credential((security:Credential))
security:InternalServiceKey((security:InternalServiceKey)) -- subClassOf --> security:Secret((security:Secret))
security:JSONWebToken((security:JSONWebToken)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
security:LabToken((security:LabToken)) -- subClassOf --> security:Credential((security:Credential))
security:LabToken((security:LabToken)) -- subClassOf --> security:Secret((security:Secret))
security:MutualTLSAuthentication((security:MutualTLSAuthentication)) -- subClassOf --> security:Authentication((security:Authentication))
security:Nonconformity((security:Nonconformity)) -- subClassOf --> security:AssessmentCondition((security:AssessmentCondition))
security:Patch((security:Patch)) -- subClassOf --> security:AssessmentCondition((security:AssessmentCondition))
security:ProjectAccessDeniedFailure((security:ProjectAccessDeniedFailure)) -- subClassOf --> diagnostics:InfrastructureFailure[diagnostics:InfrastructureFailure]
security:RegistryAuthentication((security:RegistryAuthentication)) -- subClassOf --> y:Process[y:Process]
security:SSHHostKey((security:SSHHostKey)) -- subClassOf --> security:Credential((security:Credential))
security:SSHKeyPair((security:SSHKeyPair)) -- subClassOf --> security:Credential((security:Credential))
security:ScreenRecordingPermission((security:ScreenRecordingPermission)) -- subClassOf --> y:Policy[y:Policy]
security:Secret((security:Secret)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
security:Shortfall((security:Shortfall)) -- subClassOf --> security:AssessmentCondition((security:AssessmentCondition))
security:SignatureVerification((security:SignatureVerification)) -- subClassOf --> r_SignatureVerification_verifiesArtifact_Artifact_((Anonymous class))
security:SignatureVerification((security:SignatureVerification)) -- subClassOf --> y:Process[y:Process]
security:SourceIntegrityFailure((security:SourceIntegrityFailure)) -- subClassOf --> diagnostics:InfrastructureFailure[diagnostics:InfrastructureFailure]
security:StorageCredential((security:StorageCredential)) -- subClassOf --> security:Credential((security:Credential))
security:TLSCertificate((security:TLSCertificate)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
security:TrustStore((security:TrustStore)) -- subClassOf --> y:ConfigurationArtifact[y:ConfigurationArtifact]
security:Unavailability((security:Unavailability)) -- subClassOf --> security:AssessmentCondition((security:AssessmentCondition))
security:Unmonitored((security:Unmonitored)) -- subClassOf --> security:AssessmentCondition((security:AssessmentCondition))
subgraph r_ChecksumVerification_verifiesArtifact_Artifact_[Restriction &exist; R C]
r_ChecksumVerification_verifiesArtifact_Artifact_thing((thing)) --> r_ChecksumVerification_verifiesArtifact_Artifact_y:verifiesArtifact[y:verifiesArtifact]
r_ChecksumVerification_verifiesArtifact_Artifact_y:verifiesArtifact[y:verifiesArtifact]
-- some --> r_ChecksumVerification_verifiesArtifact_Artifact_y:Artifact((y:Artifact))
end
subgraph r_SignatureVerification_verifiesArtifact_Artifact_[Restriction &exist; R C]
r_SignatureVerification_verifiesArtifact_Artifact_thing((thing)) --> r_SignatureVerification_verifiesArtifact_Artifact_y:verifiesArtifact[y:verifiesArtifact]
r_SignatureVerification_verifiesArtifact_Artifact_y:verifiesArtifact[y:verifiesArtifact]
-- some --> r_SignatureVerification_verifiesArtifact_Artifact_y:Artifact((y:Artifact))
end
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.31

Back to [Yuruna ontology diagrams](../../../README.md#425aed30-0005)
