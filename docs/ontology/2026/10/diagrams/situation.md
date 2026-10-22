# Situation diagram

`y:Situation` is a state of affairs relevant to operation or diagnosis,
including conditions and incidents. This page draws it from version 2026/10 of
the [Yuruna ontology](../yuruna.owl): the classes under it, the object
properties whose `rdfs:domain` is one of those classes, and their existential
restrictions.

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
subgraph r_GuestIncident_affects_Guest_[Restriction &exist; R C]
r_GuestIncident_affects_Guest_thing((thing)) --> r_GuestIncident_affects_Guest_y:affects[y:affects]
r_GuestIncident_affects_Guest_y:affects[y:affects]
-- some --> r_GuestIncident_affects_Guest_y:Guest((y:Guest))
end
subgraph r_HostIncident_affects_Host_[Restriction &exist; R C]
r_HostIncident_affects_Host_thing((thing)) --> r_HostIncident_affects_Host_y:affects[y:affects]
r_HostIncident_affects_Host_y:affects[y:affects]
-- some --> r_HostIncident_affects_Host_y:Host((y:Host))
end
subgraph r_RecurringIncident_recursAfter_Incident_[Restriction &exist; R C]
r_RecurringIncident_recursAfter_Incident_thing((thing)) --> r_RecurringIncident_recursAfter_Incident_y:recursAfter[y:recursAfter]
r_RecurringIncident_recursAfter_Incident_y:recursAfter[y:recursAfter]
-- some --> r_RecurringIncident_recursAfter_Incident_y:Incident((y:Incident))
end
y:AbortedRequest((y:AbortedRequest)) -- subClassOf --> y:Situation((y:Situation))
y:AddressChurn((y:AddressChurn)) -- subClassOf --> y:Situation((y:Situation))
y:AddressConflict((y:AddressConflict)) -- subClassOf --> y:Failure((y:Failure))
y:ArchitectureCompatibility((y:ArchitectureCompatibility)) -- subClassOf --> y:Situation((y:Situation))
y:AssessmentCondition((y:AssessmentCondition)) -- subClassOf --> y:Situation((y:Situation))
y:Authorized((y:Authorized)) -- subClassOf --> y:AssessmentCondition((y:AssessmentCondition))
y:AutomationChartInvalid((y:AutomationChartInvalid)) -- subClassOf --> y:AutomationFailure((y:AutomationFailure))
y:AutomationClusterUnreachable((y:AutomationClusterUnreachable)) -- subClassOf --> y:AutomationFailure((y:AutomationFailure))
y:AutomationConfigError((y:AutomationConfigError)) -- subClassOf --> y:AutomationFailure((y:AutomationFailure))
y:AutomationFailure((y:AutomationFailure)) -- subClassOf --> y:Failure((y:Failure))
y:AutomationSuccessStatus((y:AutomationSuccessStatus)) -- subClassOf --> y:State((y:State))
y:AutomationToolFailed((y:AutomationToolFailed)) -- subClassOf --> y:AutomationFailure((y:AutomationFailure))
y:AutomationUnknownFailure((y:AutomationUnknownFailure)) -- subClassOf --> y:AutomationFailure((y:AutomationFailure))
y:BootstrapSyncFailure((y:BootstrapSyncFailure)) -- subClassOf --> y:InfrastructureFailure((y:InfrastructureFailure))
y:CacheFreshness((y:CacheFreshness)) -- subClassOf --> y:State((y:State))
y:CacheHit((y:CacheHit)) -- subClassOf --> y:Situation((y:Situation))
y:CacheMiss((y:CacheMiss)) -- subClassOf --> y:Situation((y:Situation))
y:CallerCancellation((y:CallerCancellation)) -- subClassOf --> y:Situation((y:Situation))
y:CertificateTrustFailure((y:CertificateTrustFailure)) -- subClassOf --> y:Failure((y:Failure))
y:ClockSkew((y:ClockSkew)) -- subClassOf --> y:Situation((y:Situation))
y:ColdCacheState((y:ColdCacheState)) -- subClassOf --> y:State((y:State))
y:ConnectionRefused((y:ConnectionRefused)) -- subClassOf --> y:Failure((y:Failure))
y:ConnectionReset((y:ConnectionReset)) -- subClassOf --> y:Failure((y:Failure))
y:Connectivity((y:Connectivity)) -- subClassOf --> y:Situation((y:Situation))
y:ConsoleFloodedFailure((y:ConsoleFloodedFailure)) -- subClassOf --> y:SequenceFailure((y:SequenceFailure))
y:CredentialExpiredFailure((y:CredentialExpiredFailure)) -- subClassOf --> y:Failure((y:Failure))
y:CrossHostIncident((y:CrossHostIncident)) -- subClassOf --> y:RepeatedFailureIncident((y:RepeatedFailureIncident))
y:CycleKilledFault((y:CycleKilledFault)) -- subClassOf --> y:RunnerFault((y:RunnerFault))
y:CycleOutcome((y:CycleOutcome)) -- subClassOf --> y:State((y:State))
y:CycleSpawnFailure((y:CycleSpawnFailure)) -- subClassOf --> y:RunnerFault((y:RunnerFault))
y:DHCPIdentityUnboundedFailure((y:DHCPIdentityUnboundedFailure)) -- subClassOf --> y:InfrastructureFailure((y:InfrastructureFailure))
y:DHCPPoolExhaustion((y:DHCPPoolExhaustion)) -- subClassOf --> y:Failure((y:Failure))
y:DataSourceError((y:DataSourceError)) -- subClassOf --> y:Failure((y:Failure))
y:DependencyFailure((y:DependencyFailure)) -- subClassOf --> y:Failure((y:Failure))
y:DesiredState((y:DesiredState)) -- subClassOf --> y:State((y:State))
y:DisplayContextFailure((y:DisplayContextFailure)) -- subClassOf --> y:ProvisioningFailure((y:ProvisioningFailure))
y:DrainingIntent((y:DrainingIntent)) -- subClassOf --> y:DesiredState((y:DesiredState))
y:Drift((y:Drift)) -- subClassOf --> y:AssessmentCondition((y:AssessmentCondition))
y:DuplicateIPAddress((y:DuplicateIPAddress)) -- subClassOf --> y:AddressConflict((y:AddressConflict))
y:ElevationRequiredFailure((y:ElevationRequiredFailure)) -- subClassOf --> y:InfrastructureFailure((y:InfrastructureFailure))
y:EndOfFile((y:EndOfFile)) -- subClassOf --> y:State((y:State))
y:Exposure((y:Exposure)) -- subClassOf --> y:AssessmentCondition((y:AssessmentCondition))
y:ExtensionErrorFailure((y:ExtensionErrorFailure)) -- subClassOf --> y:SequenceFailure((y:SequenceFailure))
y:Failure((y:Failure)) -- subClassOf --> y:Incident((y:Incident))
y:FailurePause((y:FailurePause)) -- subClassOf --> y:State((y:State))
y:FailureSeverity((y:FailureSeverity)) -- subClassOf --> y:State((y:State))
y:Finding((y:Finding)) -- subClassOf --> y:AssessmentCondition((y:AssessmentCondition))
y:GuestIncident((y:GuestIncident)) -- subClassOf --> r_GuestIncident_affects_Guest_((Anonymous class))
y:GuestIncident((y:GuestIncident)) -- subClassOf --> y:Incident((y:Incident))
y:HardFailureSeverity((y:HardFailureSeverity)) -- subClassOf --> y:FailureSeverity((y:FailureSeverity))
y:HostAddressRenumbering((y:HostAddressRenumbering)) -- subClassOf --> y:Situation((y:Situation))
y:HostIOBlockedFailure((y:HostIOBlockedFailure)) -- subClassOf --> y:SequenceFailure((y:SequenceFailure))
y:HostIncident((y:HostIncident)) -- subClassOf --> r_HostIncident_affects_Host_((Anonymous class))
y:HostIncident((y:HostIncident)) -- subClassOf --> y:Incident((y:Incident))
y:HostNetworkDegradedFailure((y:HostNetworkDegradedFailure)) -- subClassOf --> y:HostIncident((y:HostIncident))
y:HostNetworkDegradedFailure((y:HostNetworkDegradedFailure)) -- subClassOf --> y:InfrastructureFailure((y:InfrastructureFailure))
y:HostPresence((y:HostPresence)) -- subClassOf --> y:State((y:State))
y:IPNotDiscoveredFailure((y:IPNotDiscoveredFailure)) -- subClassOf --> y:InfrastructureFailure((y:InfrastructureFailure))
y:ImageArchitectureMismatch((y:ImageArchitectureMismatch)) -- subClassOf --> y:ProvisioningFailure((y:ProvisioningFailure))
y:Incident -- y:affects --> y:SystemElement
y:Incident -- y:hasEvidence --> y:DiagnosticEvidence
y:Incident -- y:hasFingerprint --> y:IncidentFingerprint
y:Incident -- y:recursAfter --> y:Incident
y:Incident((y:Incident)) -- subClassOf --> y:Situation((y:Situation))
y:InfrastructureFailure((y:InfrastructureFailure)) -- subClassOf --> y:Failure((y:Failure))
y:InputLostFailure((y:InputLostFailure)) -- subClassOf --> y:SequenceFailure((y:SequenceFailure))
y:InstrumentationFailure((y:InstrumentationFailure)) -- subClassOf --> y:Failure((y:Failure))
y:InvalidPlanFailure((y:InvalidPlanFailure)) -- subClassOf --> y:InfrastructureFailure((y:InfrastructureFailure))
y:LabDependencyDownFailure((y:LabDependencyDownFailure)) -- subClassOf --> y:InfrastructureFailure((y:InfrastructureFailure))
y:LinkState((y:LinkState)) -- subClassOf --> y:State((y:State))
y:MemoryExhaustion((y:MemoryExhaustion)) -- subClassOf --> y:Failure((y:Failure))
y:NameResolutionFailure((y:NameResolutionFailure)) -- subClassOf --> y:Failure((y:Failure))
y:NetworkTimeoutFailure((y:NetworkTimeoutFailure)) -- subClassOf --> y:Failure((y:Failure))
y:NoDataState((y:NoDataState)) -- subClassOf --> y:State((y:State))
y:Nonconformity((y:Nonconformity)) -- subClassOf --> y:AssessmentCondition((y:AssessmentCondition))
y:OCRTimeoutFailure((y:OCRTimeoutFailure)) -- subClassOf --> y:SequenceFailure((y:SequenceFailure))
y:OpenIncidentState((y:OpenIncidentState)) -- subClassOf --> y:State((y:State))
y:OutcomeUnrecordedFault((y:OutcomeUnrecordedFault)) -- subClassOf --> y:RunnerFault((y:RunnerFault))
y:PackageTransactionStall((y:PackageTransactionStall)) -- subClassOf --> y:Failure((y:Failure))
y:PacketLoss((y:PacketLoss)) -- subClassOf --> y:Situation((y:Situation))
y:Patch((y:Patch)) -- subClassOf --> y:AssessmentCondition((y:AssessmentCondition))
y:PatternMatchedFailure((y:PatternMatchedFailure)) -- subClassOf --> y:SequenceFailure((y:SequenceFailure))
y:PausedIntent((y:PausedIntent)) -- subClassOf --> y:DesiredState((y:DesiredState))
y:PayloadIntegrityMismatch((y:PayloadIntegrityMismatch)) -- subClassOf --> y:Failure((y:Failure))
y:PayloadUnavailableFailure((y:PayloadUnavailableFailure)) -- subClassOf --> y:Failure((y:Failure))
y:PoolStorageFullFailure((y:PoolStorageFullFailure)) -- subClassOf --> y:InfrastructureFailure((y:InfrastructureFailure))
y:PortBindingConflict((y:PortBindingConflict)) -- subClassOf --> y:AddressConflict((y:AddressConflict))
y:PreambleStallFault((y:PreambleStallFault)) -- subClassOf --> y:RunnerFault((y:RunnerFault))
y:ProjectAccessDeniedFailure((y:ProjectAccessDeniedFailure)) -- subClassOf --> y:InfrastructureFailure((y:InfrastructureFailure))
y:ProvisioningFailure((y:ProvisioningFailure)) -- subClassOf --> y:InfrastructureFailure((y:InfrastructureFailure))
y:RateLimitFailure((y:RateLimitFailure)) -- subClassOf --> y:DependencyFailure((y:DependencyFailure))
y:Reachability((y:Reachability)) -- subClassOf --> y:Situation((y:Situation))
y:RecoveryState((y:RecoveryState)) -- subClassOf --> y:State((y:State))
y:RecurringHostIncident((y:RecurringHostIncident)) -- subClassOf --> y:HostIncident((y:HostIncident))
y:RecurringHostIncident((y:RecurringHostIncident)) -- subClassOf --> y:RecurringIncident((y:RecurringIncident))
y:RecurringIncident((y:RecurringIncident)) -- subClassOf --> r_RecurringIncident_recursAfter_Incident_((Anonymous class))
y:RecurringIncident((y:RecurringIncident)) -- subClassOf --> y:Incident((y:Incident))
y:RegistryManifestUnavailable((y:RegistryManifestUnavailable)) -- subClassOf --> y:Failure((y:Failure))
y:RepeatedFailureIncident((y:RepeatedFailureIncident)) -- subClassOf --> y:Incident((y:Incident))
y:ResolvedIncidentState((y:ResolvedIncidentState)) -- subClassOf --> y:State((y:State))
y:ResponseParseFailure((y:ResponseParseFailure)) -- subClassOf --> y:DependencyFailure((y:DependencyFailure))
y:RetransmissionTimer((y:RetransmissionTimer)) -- subClassOf --> y:State((y:State))
y:RetryExhaustedFailure((y:RetryExhaustedFailure)) -- subClassOf --> y:Failure((y:Failure))
y:RunnerFault((y:RunnerFault)) -- subClassOf --> y:Failure((y:Failure))
y:RunningIntent((y:RunningIntent)) -- subClassOf --> y:DesiredState((y:DesiredState))
y:ScriptErrorFailure((y:ScriptErrorFailure)) -- subClassOf --> y:Failure((y:Failure))
y:SequenceFailure((y:SequenceFailure)) -- subClassOf --> y:Failure((y:Failure))
y:Shortfall((y:Shortfall)) -- subClassOf --> y:AssessmentCondition((y:AssessmentCondition))
y:Situation((y:Situation)) -- subClassOf --> y:Entity((y:Entity))
y:SnapshotRestoreFailure((y:SnapshotRestoreFailure)) -- subClassOf --> y:SequenceFailure((y:SequenceFailure))
y:SoftFailureSeverity((y:SoftFailureSeverity)) -- subClassOf --> y:FailureSeverity((y:FailureSeverity))
y:StaleMount((y:StaleMount)) -- subClassOf --> y:Failure((y:Failure))
y:StaleUplinkBinding((y:StaleUplinkBinding)) -- subClassOf --> y:InfrastructureFailure((y:InfrastructureFailure))
y:StalledTransfer((y:StalledTransfer)) -- subClassOf --> y:Failure((y:Failure))
y:State((y:State)) -- subClassOf --> y:Situation((y:Situation))
y:StorageIOFailure((y:StorageIOFailure)) -- subClassOf --> y:Failure((y:Failure))
y:TCPConnectionState((y:TCPConnectionState)) -- subClassOf --> y:State((y:State))
y:Timeout((y:Timeout)) -- subClassOf --> y:Situation((y:Situation))
y:Unavailability((y:Unavailability)) -- subClassOf --> y:AssessmentCondition((y:AssessmentCondition))
y:UnknownFailure((y:UnknownFailure)) -- subClassOf --> y:Failure((y:Failure))
y:UnknownFailureSeverity((y:UnknownFailureSeverity)) -- subClassOf --> y:FailureSeverity((y:FailureSeverity))
y:Unmonitored((y:Unmonitored)) -- subClassOf --> y:AssessmentCondition((y:AssessmentCondition))
y:VMAdmissionOccupiedFault((y:VMAdmissionOccupiedFault)) -- subClassOf --> y:RunnerFault((y:RunnerFault))
y:VMAdmissionUnknownFault((y:VMAdmissionUnknownFault)) -- subClassOf --> y:RunnerFault((y:RunnerFault))
y:VNCConnectionStale((y:VNCConnectionStale)) -- subClassOf --> y:HostIOBlockedFailure((y:HostIOBlockedFailure))
y:WaitTimeoutFailure((y:WaitTimeoutFailure)) -- subClassOf --> y:SequenceFailure((y:SequenceFailure))
y:WarmCacheState((y:WarmCacheState)) -- subClassOf --> y:State((y:State))
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.22

Back to [Yuruna ontology diagrams](../../../README.md#425aed30-0005)
