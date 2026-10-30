# Diagnostics diagram

The `diagnostics:` namespace,
`https://yuruna.com/ontology/2026/10/diagnostics#`, holds the diagnostics
vocabulary: incidents, failures and their classification, evidence, checks,
recovery, telemetry, logs, metrics, dashboards, and alerts. This page draws the
diagnostics namespace: its classes, the object properties declared in it, and
the existential restrictions on those classes, from version 2026/10 of the
[Yuruna ontology](../yuruna.owl).

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
diagnostics:AlertNotification((diagnostics:AlertNotification)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
diagnostics:AlertRule((diagnostics:AlertRule)) -- subClassOf --> software:Policy[software:Policy]
diagnostics:ClearStaleGitLock((diagnostics:ClearStaleGitLock)) -- subClassOf --> diagnostics:RecoveryAction((diagnostics:RecoveryAction))
diagnostics:ContactPoint((diagnostics:ContactPoint)) -- subClassOf --> software:ConfigurationArtifact[software:ConfigurationArtifact]
diagnostics:CounterMetric((diagnostics:CounterMetric)) -- subClassOf --> diagnostics:Metric((diagnostics:Metric))
diagnostics:CrossHostIncident((diagnostics:CrossHostIncident)) -- subClassOf --> diagnostics:RepeatedFailureIncident((diagnostics:RepeatedFailureIncident))
diagnostics:DashboardPanel((diagnostics:DashboardPanel)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
diagnostics:DataSourceError((diagnostics:DataSourceError)) -- subClassOf --> diagnostics:Failure((diagnostics:Failure))
diagnostics:DiagnosticCheck -- diagnostics:checksElement --> y:SystemElement
diagnostics:DiagnosticCheck -- diagnostics:observes --> diagnostics:DiagnosticEvidence
diagnostics:DiagnosticCheck((diagnostics:DiagnosticCheck)) -- subClassOf --> y:Process[y:Process]
diagnostics:DiagnosticEvidence((diagnostics:DiagnosticEvidence)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
diagnostics:DiagnosticLadder((diagnostics:DiagnosticLadder)) -- subClassOf --> software:Policy[software:Policy]
diagnostics:DominantFailureClass((diagnostics:DominantFailureClass)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
diagnostics:EndFailurePauseEarly((diagnostics:EndFailurePauseEarly)) -- subClassOf --> diagnostics:RecoveryAction((diagnostics:RecoveryAction))
diagnostics:EscalateRecommendation((diagnostics:EscalateRecommendation)) -- subClassOf --> diagnostics:RecoveryRecommendation((diagnostics:RecoveryRecommendation))
diagnostics:EventRecord((diagnostics:EventRecord)) -- subClassOf --> diagnostics:DiagnosticEvidence((diagnostics:DiagnosticEvidence))
diagnostics:Failure((diagnostics:Failure)) -- subClassOf --> diagnostics:Incident((diagnostics:Incident))
diagnostics:FailureClassHistogram((diagnostics:FailureClassHistogram)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
diagnostics:FailureClassification((diagnostics:FailureClassification)) -- subClassOf --> y:Process[y:Process]
diagnostics:FailureRecord -- diagnostics:hasSeverity --> diagnostics:FailureSeverity
diagnostics:FailureRecord -- diagnostics:suggests --> diagnostics:RecoveryRecommendation
diagnostics:FailureRecord((diagnostics:FailureRecord)) -- subClassOf --> diagnostics:DiagnosticEvidence((diagnostics:DiagnosticEvidence))
diagnostics:FailureRecord((diagnostics:FailureRecord)) -- subClassOf --> r_FailureRecord_hasSeverity_FailureSeverity_((Anonymous class))
diagnostics:FailureSeverity((diagnostics:FailureSeverity)) -- subClassOf --> y:State[y:State]
diagnostics:GaugeMetric((diagnostics:GaugeMetric)) -- subClassOf --> diagnostics:Metric((diagnostics:Metric))
diagnostics:Grafana((diagnostics:Grafana)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
diagnostics:GuestIncident((diagnostics:GuestIncident)) -- subClassOf --> diagnostics:Incident((diagnostics:Incident))
diagnostics:GuestIncident((diagnostics:GuestIncident)) -- subClassOf --> r_GuestIncident_affects_Guest_((Anonymous class))
diagnostics:HardFailureSeverity((diagnostics:HardFailureSeverity)) -- subClassOf --> diagnostics:FailureSeverity((diagnostics:FailureSeverity))
diagnostics:HistoryBackfill((diagnostics:HistoryBackfill)) -- subClassOf --> y:Process[y:Process]
diagnostics:HostIncident((diagnostics:HostIncident)) -- subClassOf --> diagnostics:Incident((diagnostics:Incident))
diagnostics:HostIncident((diagnostics:HostIncident)) -- subClassOf --> r_HostIncident_affects_Host_((Anonymous class))
diagnostics:Incident -- diagnostics:affects --> y:SystemElement
diagnostics:Incident -- diagnostics:hasEvidence --> diagnostics:DiagnosticEvidence
diagnostics:Incident -- diagnostics:hasFingerprint --> diagnostics:IncidentFingerprint
diagnostics:Incident -- diagnostics:recursAfter --> diagnostics:Incident
diagnostics:Incident((diagnostics:Incident)) -- subClassOf --> y:Situation[y:Situation]
diagnostics:IncidentDetectionPolicy((diagnostics:IncidentDetectionPolicy)) -- subClassOf --> software:Policy[software:Policy]
diagnostics:IncidentFingerprint((diagnostics:IncidentFingerprint)) -- subClassOf --> y:Identifier[y:Identifier]
diagnostics:InfrastructureFailure((diagnostics:InfrastructureFailure)) -- subClassOf --> diagnostics:Failure((diagnostics:Failure))
diagnostics:InstrumentationFailure((diagnostics:InstrumentationFailure)) -- subClassOf --> diagnostics:Failure((diagnostics:Failure))
diagnostics:LogLevel((diagnostics:LogLevel)) -- subClassOf --> software:Policy[software:Policy]
diagnostics:LogRotation((diagnostics:LogRotation)) -- subClassOf --> y:Process[y:Process]
diagnostics:LogStream((diagnostics:LogStream)) -- subClassOf --> diagnostics:DiagnosticEvidence((diagnostics:DiagnosticEvidence))
diagnostics:Loki((diagnostics:Loki)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
diagnostics:Metric((diagnostics:Metric)) -- subClassOf --> diagnostics:Telemetry((diagnostics:Telemetry))
diagnostics:MetricExporter((diagnostics:MetricExporter)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
diagnostics:MetricLabel((diagnostics:MetricLabel)) -- subClassOf --> y:Identifier[y:Identifier]
diagnostics:MetricScrape((diagnostics:MetricScrape)) -- subClassOf --> y:Process[y:Process]
diagnostics:NDJSON((diagnostics:NDJSON)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
diagnostics:NoDataState((diagnostics:NoDataState)) -- subClassOf --> y:State[y:State]
diagnostics:NotificationPolicy((diagnostics:NotificationPolicy)) -- subClassOf --> software:Policy[software:Policy]
diagnostics:OpenIncidentState((diagnostics:OpenIncidentState)) -- subClassOf --> y:State[y:State]
diagnostics:OperatorInterventionRecommendation((diagnostics:OperatorInterventionRecommendation)) -- subClassOf --> diagnostics:RecoveryRecommendation((diagnostics:RecoveryRecommendation))
diagnostics:PauseAndInspectRecommendation((diagnostics:PauseAndInspectRecommendation)) -- subClassOf --> diagnostics:RecoveryRecommendation((diagnostics:RecoveryRecommendation))
diagnostics:ProgressAdvisory((diagnostics:ProgressAdvisory)) -- subClassOf --> diagnostics:DiagnosticEvidence((diagnostics:DiagnosticEvidence))
diagnostics:Prometheus((diagnostics:Prometheus)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
diagnostics:ReadinessVerdict((diagnostics:ReadinessVerdict)) -- subClassOf --> diagnostics:DiagnosticEvidence((diagnostics:DiagnosticEvidence))
diagnostics:RecloneProject((diagnostics:RecloneProject)) -- subClassOf --> diagnostics:RecoveryAction((diagnostics:RecoveryAction))
diagnostics:ReconnectRecommendation((diagnostics:ReconnectRecommendation)) -- subClassOf --> diagnostics:RecoveryRecommendation((diagnostics:RecoveryRecommendation))
diagnostics:RecoveryAction -- diagnostics:addressesIncident --> diagnostics:Incident
diagnostics:RecoveryAction((diagnostics:RecoveryAction)) -- subClassOf --> r_RecoveryAction_addressesIncident_Incident_((Anonymous class))
diagnostics:RecoveryAction((diagnostics:RecoveryAction)) -- subClassOf --> y:Process[y:Process]
diagnostics:RecoveryLedger -- diagnostics:recordsAttempt --> diagnostics:RecoveryAction
diagnostics:RecoveryLedger((diagnostics:RecoveryLedger)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
diagnostics:RecoveryRecommendation((diagnostics:RecoveryRecommendation)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
diagnostics:RecoveryState((diagnostics:RecoveryState)) -- subClassOf --> y:State[y:State]
diagnostics:RecurringHostIncident((diagnostics:RecurringHostIncident)) -- subClassOf --> diagnostics:HostIncident((diagnostics:HostIncident))
diagnostics:RecurringHostIncident((diagnostics:RecurringHostIncident)) -- subClassOf --> diagnostics:RecurringIncident((diagnostics:RecurringIncident))
diagnostics:RecurringIncident((diagnostics:RecurringIncident)) -- subClassOf --> diagnostics:Incident((diagnostics:Incident))
diagnostics:RecurringIncident((diagnostics:RecurringIncident)) -- subClassOf --> r_RecurringIncident_recursAfter_Incident_((Anonymous class))
diagnostics:RepeatedFailureIncident((diagnostics:RepeatedFailureIncident)) -- subClassOf --> diagnostics:Incident((diagnostics:Incident))
diagnostics:ResolvedIncidentState((diagnostics:ResolvedIncidentState)) -- subClassOf --> y:State[y:State]
diagnostics:RestartFromSnapshotRecommendation((diagnostics:RestartFromSnapshotRecommendation)) -- subClassOf --> diagnostics:RecoveryRecommendation((diagnostics:RecoveryRecommendation))
diagnostics:RetryImmediatelyRecommendation((diagnostics:RetryImmediatelyRecommendation)) -- subClassOf --> diagnostics:RecoveryRecommendation((diagnostics:RecoveryRecommendation))
diagnostics:RetryWithBackoffRecommendation((diagnostics:RetryWithBackoffRecommendation)) -- subClassOf --> diagnostics:RecoveryRecommendation((diagnostics:RecoveryRecommendation))
diagnostics:SoftFailureSeverity((diagnostics:SoftFailureSeverity)) -- subClassOf --> diagnostics:FailureSeverity((diagnostics:FailureSeverity))
diagnostics:StatusDashboard((diagnostics:StatusDashboard)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
diagnostics:StructuredLog((diagnostics:StructuredLog)) -- subClassOf --> diagnostics:LogStream((diagnostics:LogStream))
diagnostics:SystemDiagnostic((diagnostics:SystemDiagnostic)) -- subClassOf --> diagnostics:DiagnosticCheck((diagnostics:DiagnosticCheck))
diagnostics:Telemetry((diagnostics:Telemetry)) -- subClassOf --> diagnostics:DiagnosticEvidence((diagnostics:DiagnosticEvidence))
diagnostics:Telemetry((diagnostics:Telemetry)) -- subClassOf --> security:AssessmentView[security:AssessmentView]
diagnostics:TimeSeries((diagnostics:TimeSeries)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
diagnostics:Transcript((diagnostics:Transcript)) -- subClassOf --> diagnostics:DiagnosticEvidence((diagnostics:DiagnosticEvidence))
diagnostics:UnknownFailure((diagnostics:UnknownFailure)) -- subClassOf --> diagnostics:Failure((diagnostics:Failure))
diagnostics:UnknownFailureSeverity((diagnostics:UnknownFailureSeverity)) -- subClassOf --> diagnostics:FailureSeverity((diagnostics:FailureSeverity))
subgraph r_FailureRecord_hasSeverity_FailureSeverity_[Restriction &exist; R C]
r_FailureRecord_hasSeverity_FailureSeverity_thing((thing)) --> r_FailureRecord_hasSeverity_FailureSeverity_diagnostics:hasSeverity[diagnostics:hasSeverity]
r_FailureRecord_hasSeverity_FailureSeverity_diagnostics:hasSeverity[diagnostics:hasSeverity]
-- some --> r_FailureRecord_hasSeverity_FailureSeverity_diagnostics:FailureSeverity((diagnostics:FailureSeverity))
end
subgraph r_GuestIncident_affects_Guest_[Restriction &exist; R C]
r_GuestIncident_affects_Guest_thing((thing)) --> r_GuestIncident_affects_Guest_diagnostics:affects[diagnostics:affects]
r_GuestIncident_affects_Guest_diagnostics:affects[diagnostics:affects]
-- some --> r_GuestIncident_affects_Guest_compute:Guest((compute:Guest))
end
subgraph r_HostIncident_affects_Host_[Restriction &exist; R C]
r_HostIncident_affects_Host_thing((thing)) --> r_HostIncident_affects_Host_diagnostics:affects[diagnostics:affects]
r_HostIncident_affects_Host_diagnostics:affects[diagnostics:affects]
-- some --> r_HostIncident_affects_Host_compute:Host((compute:Host))
end
subgraph r_RecoveryAction_addressesIncident_Incident_[Restriction &exist; R C]
r_RecoveryAction_addressesIncident_Incident_thing((thing)) --> r_RecoveryAction_addressesIncident_Incident_diagnostics:addressesIncident[diagnostics:addressesIncident]
r_RecoveryAction_addressesIncident_Incident_diagnostics:addressesIncident[diagnostics:addressesIncident]
-- some --> r_RecoveryAction_addressesIncident_Incident_diagnostics:Incident((diagnostics:Incident))
end
subgraph r_RecurringIncident_recursAfter_Incident_[Restriction &exist; R C]
r_RecurringIncident_recursAfter_Incident_thing((thing)) --> r_RecurringIncident_recursAfter_Incident_diagnostics:recursAfter[diagnostics:recursAfter]
r_RecurringIncident_recursAfter_Incident_diagnostics:recursAfter[diagnostics:recursAfter]
-- some --> r_RecurringIncident_recursAfter_Incident_diagnostics:Incident((diagnostics:Incident))
end
y:SystemElement -- diagnostics:affectedBy --> diagnostics:Incident
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.30

Back to [Yuruna ontology diagrams](../../../README.md#425aed30-0005)
