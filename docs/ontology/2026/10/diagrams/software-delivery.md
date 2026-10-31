# Software delivery and configuration diagram

The `software:` namespace, `https://yuruna.com/ontology/2026/10/software#`,
holds the software engineering vocabulary: artifacts, releases, container images
and registries, configuration, deployment, Kubernetes resources, packages,
localization, and documentation. This page draws the delivery and configuration
part of the namespace (artifacts, releases, images, registries, configuration,
deployment, Kubernetes resources, and packages): these classes, the object
properties of the namespace drawn here, and the existential restrictions on
these classes, from version 2026/10 of the [Yuruna ontology](../yuruna.owl).

The namespace's other pages: [Software localization and
documentation](software-localization.md).

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
software:ApplicationWorkload -- software:deployedFrom --> software:HelmChart
software:ApplicationWorkload -- software:usesComponent --> software:DeployableComponent
software:ApplicationWorkload((software:ApplicationWorkload)) -- subClassOf --> r_ApplicationWorkload_usesComponent_DeployableComponent_((Anonymous class))
software:ApplicationWorkload((software:ApplicationWorkload)) -- subClassOf --> y:SystemElement[y:SystemElement]
software:ArtifactGeneration((software:ArtifactGeneration)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
software:ArtifactIntegrityCheck((software:ArtifactIntegrityCheck)) -- subClassOf --> diagnostics:DiagnosticCheck[diagnostics:DiagnosticCheck]
software:ArtifactManifest((software:ArtifactManifest)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
software:AutomationChartInvalid((software:AutomationChartInvalid)) -- subClassOf --> software:AutomationFailure((software:AutomationFailure))
software:AutomationClusterUnreachable((software:AutomationClusterUnreachable)) -- subClassOf --> software:AutomationFailure((software:AutomationFailure))
software:AutomationConfigError((software:AutomationConfigError)) -- subClassOf --> software:AutomationFailure((software:AutomationFailure))
software:AutomationFailure((software:AutomationFailure)) -- subClassOf --> diagnostics:Failure[diagnostics:Failure]
software:AutomationResultManifest((software:AutomationResultManifest)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
software:AutomationSuccessStatus((software:AutomationSuccessStatus)) -- subClassOf --> y:State[y:State]
software:AutomationToolFailed((software:AutomationToolFailed)) -- subClassOf --> software:AutomationFailure((software:AutomationFailure))
software:AutomationToolTimeout((software:AutomationToolTimeout)) -- subClassOf --> software:AutomationFailure((software:AutomationFailure))
software:AutomationUnknownFailure((software:AutomationUnknownFailure)) -- subClassOf --> software:AutomationFailure((software:AutomationFailure))
software:Bootstrap((software:Bootstrap)) -- subClassOf --> y:Process[y:Process]
software:BootstrapSyncFailure((software:BootstrapSyncFailure)) -- subClassOf --> diagnostics:InfrastructureFailure[diagnostics:InfrastructureFailure]
software:CapabilityMatrix((software:CapabilityMatrix)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
software:CloudConfiguration((software:CloudConfiguration)) -- subClassOf --> y:ConfigurationArtifact[y:ConfigurationArtifact]
software:CloudProvider((software:CloudProvider)) -- subClassOf --> y:SystemElement[y:SystemElement]
software:ComponentPublication((software:ComponentPublication)) -- subClassOf --> software:DeploymentOperation((software:DeploymentOperation))
software:ConfigurationService((software:ConfigurationService)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
software:Container((software:Container)) -- subClassOf --> y:SystemElement[y:SystemElement]
software:ContainerImage((software:ContainerImage)) -- subClassOf --> software:SoftwareArtifact((software:SoftwareArtifact))
software:DeployPhaseLedger((software:DeployPhaseLedger)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
software:DeployableComponent((software:DeployableComponent)) -- subClassOf --> software:SoftwareArtifact((software:SoftwareArtifact))
software:DeploymentOperation((software:DeploymentOperation)) -- subClassOf --> y:Process[y:Process]
software:DeploymentPipeline((software:DeploymentPipeline)) -- subClassOf --> r_DeploymentPipeline_hasPart_ComponentPublication_((Anonymous class))
software:DeploymentPipeline((software:DeploymentPipeline)) -- subClassOf --> r_DeploymentPipeline_hasPart_ResourceProvisioning_((Anonymous class))
software:DeploymentPipeline((software:DeploymentPipeline)) -- subClassOf --> r_DeploymentPipeline_hasPart_WorkloadDeployment_((Anonymous class))
software:DeploymentPipeline((software:DeploymentPipeline)) -- subClassOf --> y:Process[y:Process]
software:DeploymentResource((software:DeploymentResource)) -- subClassOf --> y:SystemElement[y:SystemElement]
software:DeploymentTarget((software:DeploymentTarget)) -- subClassOf --> y:SystemElement[y:SystemElement]
software:HealthProbe((software:HealthProbe)) -- subClassOf --> y:Process[y:Process]
software:HelmChart((software:HelmChart)) -- subClassOf --> software:SoftwareArtifact((software:SoftwareArtifact))
software:HelmRelease((software:HelmRelease)) -- subClassOf --> y:SystemElement[y:SystemElement]
software:HelmValues((software:HelmValues)) -- subClassOf --> y:ConfigurationArtifact[y:ConfigurationArtifact]
software:IdempotentOperation((software:IdempotentOperation)) -- subClassOf --> y:Process[y:Process]
software:ImageBuild((software:ImageBuild)) -- subClassOf --> y:Process[y:Process]
software:ImageTag((software:ImageTag)) -- subClassOf --> y:Identifier[y:Identifier]
software:InfrastructureAsCode((software:InfrastructureAsCode)) -- subClassOf --> y:ConfigurationArtifact[y:ConfigurationArtifact]
software:IntegrityManifest((software:IntegrityManifest)) -- subClassOf --> software:ArtifactManifest((software:ArtifactManifest))
software:Kubeconfig((software:Kubeconfig)) -- subClassOf --> y:ConfigurationArtifact[y:ConfigurationArtifact]
software:KubernetesCluster((software:KubernetesCluster)) -- subClassOf --> y:SystemElement[y:SystemElement]
software:KubernetesContext((software:KubernetesContext)) -- subClassOf --> y:ConfigurationArtifact[y:ConfigurationArtifact]
software:KubernetesDeployment((software:KubernetesDeployment)) -- subClassOf --> y:SystemElement[y:SystemElement]
software:KubernetesIngress((software:KubernetesIngress)) -- subClassOf --> y:ConfigurationArtifact[y:ConfigurationArtifact]
software:KubernetesNamespace((software:KubernetesNamespace)) -- subClassOf --> y:Identifier[y:Identifier]
software:KubernetesNode((software:KubernetesNode)) -- subClassOf --> compute:ComputingNode[compute:ComputingNode]
software:KubernetesPod((software:KubernetesPod)) -- subClassOf --> r_KubernetesPod_hasPart_Container_((Anonymous class))
software:KubernetesPod((software:KubernetesPod)) -- subClassOf --> y:SystemElement[y:SystemElement]
software:KubernetesSecret((software:KubernetesSecret)) -- subClassOf --> y:ConfigurationArtifact[y:ConfigurationArtifact]
software:KubernetesService((software:KubernetesService)) -- subClassOf --> y:SystemElement[y:SystemElement]
software:LivenessProbe((software:LivenessProbe)) -- subClassOf --> software:HealthProbe((software:HealthProbe))
software:LocalDeploymentTarget((software:LocalDeploymentTarget)) -- subClassOf --> software:DeploymentTarget((software:DeploymentTarget))
software:ManualImageDrop((software:ManualImageDrop)) -- subClassOf --> y:Process[y:Process]
software:N8n((software:N8n)) -- subClassOf --> r_N8n_dependsOn_NodeJS_((Anonymous class))
software:N8n((software:N8n)) -- subClassOf --> software:SoftwareArtifact((software:SoftwareArtifact))
software:NVM((software:NVM)) -- subClassOf --> y:SystemElement[y:SystemElement]
software:NodeJS((software:NodeJS)) -- subClassOf --> software:SoftwareArtifact((software:SoftwareArtifact))
software:OpenClaw((software:OpenClaw)) -- subClassOf --> r_OpenClaw_dependsOn_NodeJS_((Anonymous class))
software:OpenClaw((software:OpenClaw)) -- subClassOf --> software:SoftwareArtifact((software:SoftwareArtifact))
software:OpenTofuConfiguration((software:OpenTofuConfiguration)) -- subClassOf --> software:InfrastructureAsCode((software:InfrastructureAsCode))
software:PackageManager((software:PackageManager)) -- subClassOf --> y:SystemElement[y:SystemElement]
software:PackageMetadata((software:PackageMetadata)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
software:PackageRepository((software:PackageRepository)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
software:PackageTransactionStall((software:PackageTransactionStall)) -- subClassOf --> diagnostics:Failure[diagnostics:Failure]
software:Project -- software:selectsConfiguration --> software:CloudConfiguration
software:Project((software:Project)) -- subClassOf --> r_Project_selectsConfiguration_CloudConfiguration_((Anonymous class))
software:Project((software:Project)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
software:PullThroughCache((software:PullThroughCache)) -- subClassOf --> software:RegistryMirror((software:RegistryMirror))
software:ReadinessProbe((software:ReadinessProbe)) -- subClassOf --> software:HealthProbe((software:HealthProbe))
software:Registry((software:Registry)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
software:RegistryManifestUnavailable((software:RegistryManifestUnavailable)) -- subClassOf --> diagnostics:Failure[diagnostics:Failure]
software:RegistryMirror((software:RegistryMirror)) -- subClassOf --> software:Registry((software:Registry))
software:RegistryRepository((software:RegistryRepository)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
software:ReleaseManifest((software:ReleaseManifest)) -- subClassOf --> software:ArtifactManifest((software:ArtifactManifest))
software:ReleaseSignature((software:ReleaseSignature)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
software:ResourceProvisioning((software:ResourceProvisioning)) -- subClassOf --> software:DeploymentOperation((software:DeploymentOperation))
software:SoftwareArtifact -- software:builtFrom --> y:InformationArtifact
software:SoftwareArtifact((software:SoftwareArtifact)) -- subClassOf --> y:Artifact[y:Artifact]
software:SoftwareBillOfMaterials((software:SoftwareBillOfMaterials)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
software:SoftwareDependency((software:SoftwareDependency)) -- subClassOf --> software:SoftwareArtifact((software:SoftwareArtifact))
software:SoftwareVersion((software:SoftwareVersion)) -- subClassOf --> y:Identifier[y:Identifier]
software:SourceHash((software:SourceHash)) -- subClassOf --> y:Identifier[y:Identifier]
software:SourceRevision((software:SourceRevision)) -- subClassOf --> y:Identifier[y:Identifier]
software:TLSCertificateSecret((software:TLSCertificateSecret)) -- subClassOf --> software:KubernetesSecret((software:KubernetesSecret))
software:TaskQueue((software:TaskQueue)) -- subClassOf --> y:SystemElement[y:SystemElement]
software:VersionFloor((software:VersionFloor)) -- subClassOf --> y:Policy[y:Policy]
software:VersionPin((software:VersionPin)) -- subClassOf --> y:ConfigurationArtifact[y:ConfigurationArtifact]
software:WorkerCapacity((software:WorkerCapacity)) -- subClassOf --> y:Quantity[y:Quantity]
software:WorkloadDeployment((software:WorkloadDeployment)) -- subClassOf --> software:DeploymentOperation((software:DeploymentOperation))
software:Zot((software:Zot)) -- subClassOf --> software:Registry((software:Registry))
subgraph r_ApplicationWorkload_usesComponent_DeployableComponent_[Restriction &exist; R C]
r_ApplicationWorkload_usesComponent_DeployableComponent_thing((thing)) --> r_ApplicationWorkload_usesComponent_DeployableComponent_software:usesComponent[software:usesComponent]
r_ApplicationWorkload_usesComponent_DeployableComponent_software:usesComponent[software:usesComponent]
-- some --> r_ApplicationWorkload_usesComponent_DeployableComponent_software:DeployableComponent((software:DeployableComponent))
end
subgraph r_DeploymentPipeline_hasPart_ComponentPublication_[Restriction &exist; R C]
r_DeploymentPipeline_hasPart_ComponentPublication_thing((thing)) --> r_DeploymentPipeline_hasPart_ComponentPublication_y:hasPart[y:hasPart]
r_DeploymentPipeline_hasPart_ComponentPublication_y:hasPart[y:hasPart]
-- some --> r_DeploymentPipeline_hasPart_ComponentPublication_software:ComponentPublication((software:ComponentPublication))
end
subgraph r_DeploymentPipeline_hasPart_ResourceProvisioning_[Restriction &exist; R C]
r_DeploymentPipeline_hasPart_ResourceProvisioning_thing((thing)) --> r_DeploymentPipeline_hasPart_ResourceProvisioning_y:hasPart[y:hasPart]
r_DeploymentPipeline_hasPart_ResourceProvisioning_y:hasPart[y:hasPart]
-- some --> r_DeploymentPipeline_hasPart_ResourceProvisioning_software:ResourceProvisioning((software:ResourceProvisioning))
end
subgraph r_DeploymentPipeline_hasPart_WorkloadDeployment_[Restriction &exist; R C]
r_DeploymentPipeline_hasPart_WorkloadDeployment_thing((thing)) --> r_DeploymentPipeline_hasPart_WorkloadDeployment_y:hasPart[y:hasPart]
r_DeploymentPipeline_hasPart_WorkloadDeployment_y:hasPart[y:hasPart]
-- some --> r_DeploymentPipeline_hasPart_WorkloadDeployment_software:WorkloadDeployment((software:WorkloadDeployment))
end
subgraph r_KubernetesPod_hasPart_Container_[Restriction &exist; R C]
r_KubernetesPod_hasPart_Container_thing((thing)) --> r_KubernetesPod_hasPart_Container_y:hasPart[y:hasPart]
r_KubernetesPod_hasPart_Container_y:hasPart[y:hasPart]
-- some --> r_KubernetesPod_hasPart_Container_software:Container((software:Container))
end
subgraph r_N8n_dependsOn_NodeJS_[Restriction &exist; R C]
r_N8n_dependsOn_NodeJS_thing((thing)) --> r_N8n_dependsOn_NodeJS_y:dependsOn[y:dependsOn]
r_N8n_dependsOn_NodeJS_y:dependsOn[y:dependsOn]
-- some --> r_N8n_dependsOn_NodeJS_software:NodeJS((software:NodeJS))
end
subgraph r_OpenClaw_dependsOn_NodeJS_[Restriction &exist; R C]
r_OpenClaw_dependsOn_NodeJS_thing((thing)) --> r_OpenClaw_dependsOn_NodeJS_y:dependsOn[y:dependsOn]
r_OpenClaw_dependsOn_NodeJS_y:dependsOn[y:dependsOn]
-- some --> r_OpenClaw_dependsOn_NodeJS_software:NodeJS((software:NodeJS))
end
subgraph r_Project_selectsConfiguration_CloudConfiguration_[Restriction &exist; R C]
r_Project_selectsConfiguration_CloudConfiguration_thing((thing)) --> r_Project_selectsConfiguration_CloudConfiguration_software:selectsConfiguration[software:selectsConfiguration]
r_Project_selectsConfiguration_CloudConfiguration_software:selectsConfiguration[software:selectsConfiguration]
-- some --> r_Project_selectsConfiguration_CloudConfiguration_software:CloudConfiguration((software:CloudConfiguration))
end
y:SystemElement -- software:configuredBy --> y:ConfigurationArtifact
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.31

Back to [Yuruna ontology diagrams](../../../README.md#425aed30-0005)
