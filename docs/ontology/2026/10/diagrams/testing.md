# Testing diagram

The `testing:` namespace, `https://yuruna.com/ontology/2026/10/testing#`, holds
the test automation vocabulary: the runner, its cycles, plans, sequences, steps,
pool, console input and recognition, retries, and sequence failures. This page
draws the testing namespace: its classes, the object properties declared in it,
and the existential restrictions on those classes, from version 2026/10 of the
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
subgraph r_SequenceHandler_implementsAction_SequenceAction_[Restriction &exist; R C]
r_SequenceHandler_implementsAction_SequenceAction_thing((thing)) --> r_SequenceHandler_implementsAction_SequenceAction_testing:implementsAction[testing:implementsAction]
r_SequenceHandler_implementsAction_SequenceAction_testing:implementsAction[testing:implementsAction]
-- some --> r_SequenceHandler_implementsAction_SequenceAction_testing:SequenceAction((testing:SequenceAction))
end
subgraph r_TestPlan_hasSequence_TestSequence_[Restriction &exist; R C]
r_TestPlan_hasSequence_TestSequence_thing((thing)) --> r_TestPlan_hasSequence_TestSequence_testing:hasSequence[testing:hasSequence]
r_TestPlan_hasSequence_TestSequence_testing:hasSequence[testing:hasSequence]
-- some --> r_TestPlan_hasSequence_TestSequence_testing:TestSequence((testing:TestSequence))
end
subgraph r_TestRunner_executesPlan_TestPlan_[Restriction &exist; R C]
r_TestRunner_executesPlan_TestPlan_thing((thing)) --> r_TestRunner_executesPlan_TestPlan_testing:executesPlan[testing:executesPlan]
r_TestRunner_executesPlan_TestPlan_testing:executesPlan[testing:executesPlan]
-- some --> r_TestRunner_executesPlan_TestPlan_testing:TestPlan((testing:TestPlan))
end
subgraph r_TestStep_executesAction_SequenceAction_[Restriction &exist; R C]
r_TestStep_executesAction_SequenceAction_thing((thing)) --> r_TestStep_executesAction_SequenceAction_testing:executesAction[testing:executesAction]
r_TestStep_executesAction_SequenceAction_testing:executesAction[testing:executesAction]
-- some --> r_TestStep_executesAction_SequenceAction_testing:SequenceAction((testing:SequenceAction))
end
subgraph r_VNCTransport_usesProtocol_RemoteFramebufferProtocol_[Restriction &exist; R C]
r_VNCTransport_usesProtocol_RemoteFramebufferProtocol_thing((thing)) --> r_VNCTransport_usesProtocol_RemoteFramebufferProtocol_network:usesProtocol[network:usesProtocol]
r_VNCTransport_usesProtocol_RemoteFramebufferProtocol_network:usesProtocol[network:usesProtocol]
-- some --> r_VNCTransport_usesProtocol_RemoteFramebufferProtocol_network:RemoteFramebufferProtocol((network:RemoteFramebufferProtocol))
end
testing:Backoff((testing:Backoff)) -- subClassOf --> y:Process[y:Process]
testing:CaptureHealthCheck((testing:CaptureHealthCheck)) -- subClassOf --> diagnostics:DiagnosticCheck[diagnostics:DiagnosticCheck]
testing:ComponentTestPhase((testing:ComponentTestPhase)) -- subClassOf --> y:Process[y:Process]
testing:ConsoleFloodedFailure((testing:ConsoleFloodedFailure)) -- subClassOf --> testing:SequenceFailure((testing:SequenceFailure))
testing:ConsoleInput((testing:ConsoleInput)) -- subClassOf --> y:Process[y:Process]
testing:ConsoleStaticDuration((testing:ConsoleStaticDuration)) -- subClassOf --> y:Quantity[y:Quantity]
testing:CycleKilledFault((testing:CycleKilledFault)) -- subClassOf --> testing:RunnerFault((testing:RunnerFault))
testing:CycleOutcome((testing:CycleOutcome)) -- subClassOf --> y:State[y:State]
testing:CycleSpawnFailure((testing:CycleSpawnFailure)) -- subClassOf --> testing:RunnerFault((testing:RunnerFault))
testing:CycleSuccessRatio((testing:CycleSuccessRatio)) -- subClassOf --> y:Quantity[y:Quantity]
testing:Deadline((testing:Deadline)) -- subClassOf --> y:Quantity[y:Quantity]
testing:DesiredState((testing:DesiredState)) -- subClassOf --> y:State[y:State]
testing:DispatchRegistry((testing:DispatchRegistry)) -- subClassOf --> software:ConfigurationArtifact[software:ConfigurationArtifact]
testing:DrainingIntent((testing:DrainingIntent)) -- subClassOf --> testing:DesiredState((testing:DesiredState))
testing:ExtensionCall((testing:ExtensionCall)) -- subClassOf --> y:Process[y:Process]
testing:ExtensionCapability((testing:ExtensionCapability)) -- subClassOf --> software:ConfigurationArtifact[software:ConfigurationArtifact]
testing:ExtensionErrorFailure((testing:ExtensionErrorFailure)) -- subClassOf --> testing:SequenceFailure((testing:SequenceFailure))
testing:ExtensionService((testing:ExtensionService)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
testing:FailurePause((testing:FailurePause)) -- subClassOf --> y:State[y:State]
testing:FetchAndExecute((testing:FetchAndExecute)) -- subClassOf --> y:Process[y:Process]
testing:Heartbeat((testing:Heartbeat)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
testing:HostAnnouncement((testing:HostAnnouncement)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
testing:HostCondition((testing:HostCondition)) -- subClassOf --> software:ConfigurationArtifact[software:ConfigurationArtifact]
testing:HostIOBlockedFailure((testing:HostIOBlockedFailure)) -- subClassOf --> testing:SequenceFailure((testing:SequenceFailure))
testing:HostIOProvider((testing:HostIOProvider)) -- subClassOf --> y:SystemElement[y:SystemElement]
testing:HostPool -- testing:hasMember --> compute:Host
testing:HostPool((testing:HostPool)) -- subClassOf --> y:SystemElement[y:SystemElement]
testing:HostPresence((testing:HostPresence)) -- subClassOf --> y:State[y:State]
testing:InnerLoop((testing:InnerLoop)) -- subClassOf --> y:Process[y:Process]
testing:InputLostFailure((testing:InputLostFailure)) -- subClassOf --> testing:SequenceFailure((testing:SequenceFailure))
testing:InvalidPlanFailure((testing:InvalidPlanFailure)) -- subClassOf --> diagnostics:InfrastructureFailure[diagnostics:InfrastructureFailure]
testing:Keystroke((testing:Keystroke)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
testing:NonzeroScriptExitMarker((testing:NonzeroScriptExitMarker)) -- subClassOf --> testing:TextPattern((testing:TextPattern))
testing:OCRCombinePolicy((testing:OCRCombinePolicy)) -- subClassOf --> software:Policy[software:Policy]
testing:OCRNearMiss((testing:OCRNearMiss)) -- subClassOf --> diagnostics:DiagnosticEvidence[diagnostics:DiagnosticEvidence]
testing:OCRProvider((testing:OCRProvider)) -- subClassOf --> y:SystemElement[y:SystemElement]
testing:OCRText((testing:OCRText)) -- subClassOf --> diagnostics:DiagnosticEvidence[diagnostics:DiagnosticEvidence]
testing:OCRTimeoutFailure((testing:OCRTimeoutFailure)) -- subClassOf --> testing:SequenceFailure((testing:SequenceFailure))
testing:OpticalCharacterRecognition((testing:OpticalCharacterRecognition)) -- subClassOf --> y:Process[y:Process]
testing:OutcomeUnrecordedFault((testing:OutcomeUnrecordedFault)) -- subClassOf --> testing:RunnerFault((testing:RunnerFault))
testing:OuterLoop((testing:OuterLoop)) -- subClassOf --> y:Process[y:Process]
testing:PatternMatch((testing:PatternMatch)) -- subClassOf --> y:Process[y:Process]
testing:PatternMatchedFailure((testing:PatternMatchedFailure)) -- subClassOf --> testing:SequenceFailure((testing:SequenceFailure))
testing:PauseRequest((testing:PauseRequest)) -- subClassOf --> software:ConfigurationArtifact[software:ConfigurationArtifact]
testing:PausedIntent((testing:PausedIntent)) -- subClassOf --> testing:DesiredState((testing:DesiredState))
testing:PayloadIntegrityMismatch((testing:PayloadIntegrityMismatch)) -- subClassOf --> diagnostics:Failure[diagnostics:Failure]
testing:PayloadUnavailableFailure((testing:PayloadUnavailableFailure)) -- subClassOf --> diagnostics:Failure[diagnostics:Failure]
testing:PlanValidation((testing:PlanValidation)) -- subClassOf --> y:Process[y:Process]
testing:Polling((testing:Polling)) -- subClassOf --> y:Process[y:Process]
testing:PoolAggregator((testing:PoolAggregator)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
testing:PoolControlService((testing:PoolControlService)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
testing:PoolIntent((testing:PoolIntent)) -- subClassOf --> software:ConfigurationArtifact[software:ConfigurationArtifact]
testing:PoolMembership((testing:PoolMembership)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
testing:PreambleStallFault((testing:PreambleStallFault)) -- subClassOf --> testing:RunnerFault((testing:RunnerFault))
testing:ResourceTestPhase((testing:ResourceTestPhase)) -- subClassOf --> y:Process[y:Process]
testing:RetryAttempt((testing:RetryAttempt)) -- subClassOf --> y:Process[y:Process]
testing:RetryExhaustedFailure((testing:RetryExhaustedFailure)) -- subClassOf --> diagnostics:Failure[diagnostics:Failure]
testing:RetryPolicy((testing:RetryPolicy)) -- subClassOf --> software:Policy[software:Policy]
testing:RunnerFault((testing:RunnerFault)) -- subClassOf --> diagnostics:Failure[diagnostics:Failure]
testing:RunnerStatus((testing:RunnerStatus)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
testing:RunningIntent((testing:RunningIntent)) -- subClassOf --> testing:DesiredState((testing:DesiredState))
testing:SCP((testing:SCP)) -- subClassOf --> y:Process[y:Process]
testing:SSHExecution((testing:SSHExecution)) -- subClassOf --> y:Process[y:Process]
testing:Screenshot((testing:Screenshot)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
testing:ScreenshotProvider((testing:ScreenshotProvider)) -- subClassOf --> y:SystemElement[y:SystemElement]
testing:ScriptErrorFailure((testing:ScriptErrorFailure)) -- subClassOf --> diagnostics:Failure[diagnostics:Failure]
testing:SequenceAction((testing:SequenceAction)) -- subClassOf --> software:ConfigurationArtifact[software:ConfigurationArtifact]
testing:SequenceFailure((testing:SequenceFailure)) -- subClassOf --> diagnostics:Failure[diagnostics:Failure]
testing:SequenceHandler -- testing:implementsAction --> testing:SequenceAction
testing:SequenceHandler((testing:SequenceHandler)) -- subClassOf --> r_SequenceHandler_implementsAction_SequenceAction_((Anonymous class))
testing:SequenceHandler((testing:SequenceHandler)) -- subClassOf --> y:SystemElement[y:SystemElement]
testing:SnapshotRestoreFailure((testing:SnapshotRestoreFailure)) -- subClassOf --> testing:SequenceFailure((testing:SequenceFailure))
testing:Snippet((testing:Snippet)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
testing:StatusService((testing:StatusService)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
testing:StreamDrain((testing:StreamDrain)) -- subClassOf --> y:Process[y:Process]
testing:TestCycle((testing:TestCycle)) -- subClassOf --> y:Process[y:Process]
testing:TestPlan -- testing:hasSequence --> testing:TestSequence
testing:TestPlan((testing:TestPlan)) -- subClassOf --> r_TestPlan_hasSequence_TestSequence_((Anonymous class))
testing:TestPlan((testing:TestPlan)) -- subClassOf --> software:ConfigurationArtifact[software:ConfigurationArtifact]
testing:TestRunner -- testing:executesPlan --> testing:TestPlan
testing:TestRunner((testing:TestRunner)) -- subClassOf --> r_TestRunner_executesPlan_TestPlan_((Anonymous class))
testing:TestRunner((testing:TestRunner)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
testing:TestSequence((testing:TestSequence)) -- subClassOf --> software:ConfigurationArtifact[software:ConfigurationArtifact]
testing:TestStep -- testing:executesAction --> testing:SequenceAction
testing:TestStep((testing:TestStep)) -- subClassOf --> r_TestStep_executesAction_SequenceAction_((Anonymous class))
testing:TestStep((testing:TestStep)) -- subClassOf --> y:Process[y:Process]
testing:TextPattern((testing:TextPattern)) -- subClassOf --> y:InformationArtifact[y:InformationArtifact]
testing:Timeout((testing:Timeout)) -- subClassOf --> y:Situation[y:Situation]
testing:VMAdmissionOccupiedFault((testing:VMAdmissionOccupiedFault)) -- subClassOf --> testing:RunnerFault((testing:RunnerFault))
testing:VMAdmissionUnknownFault((testing:VMAdmissionUnknownFault)) -- subClassOf --> testing:RunnerFault((testing:RunnerFault))
testing:VNCConnectionStale((testing:VNCConnectionStale)) -- subClassOf --> testing:HostIOBlockedFailure((testing:HostIOBlockedFailure))
testing:VNCTransport((testing:VNCTransport)) -- subClassOf --> r_VNCTransport_usesProtocol_RemoteFramebufferProtocol_((Anonymous class))
testing:VNCTransport((testing:VNCTransport)) -- subClassOf --> y:SystemElement[y:SystemElement]
testing:WaitTimeoutFailure((testing:WaitTimeoutFailure)) -- subClassOf --> testing:SequenceFailure((testing:SequenceFailure))
testing:WarmResume((testing:WarmResume)) -- subClassOf --> y:Process[y:Process]
testing:Watchdog((testing:Watchdog)) -- subClassOf --> y:SoftwareService[y:SoftwareService]
testing:WorkloadTestPhase((testing:WorkloadTestPhase)) -- subClassOf --> y:Process[y:Process]
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.30

Back to [Yuruna ontology diagrams](../../../README.md#425aed30-0005)
