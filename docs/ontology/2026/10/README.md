<a id="4268f34b-0001"></a>

# Yuruna ontology

This guide describes **version 2026/10** of the ontology in
[yuruna.owl](yuruna.owl): the English vocabulary of Yuruna, covering the kinds
of things the framework talks about, how they relate, and the diagnostic
associations between failure categories, checks, and recovery advice. It is one
self-contained OWL 2 file in RDF/XML with no remote imports, written for
translators, for operators debugging a lab, and for tools that need stable
identifiers. Those identifiers live in namespaces under
`https://yuruna.com/ontology/2026/10/`, one per area of computing; nothing is
served at those addresses.

| Prefix | Namespace | Holds |
| --- | --- | --- |
| `y:` | `https://yuruna.com/ontology/2026/10/yuruna#` | The upper categories every area shares (`y:Entity` and its kinds `y:SystemElement`, `y:InformationArtifact`, `y:Process`, `y:Situation`, with `y:Artifact`, `y:Identifier`, `y:Quantity`, `y:State`, `y:SoftwareService`), the relations between them, and the annotation vocabulary. |
| `compute:` | `https://yuruna.com/ontology/2026/10/compute#` | Physical and virtual machines, hypervisors, operating systems, firmware, processors, memory, disks, images, snapshots, and guest provisioning. |
| `diagnostics:` | `https://yuruna.com/ontology/2026/10/diagnostics#` | Incidents, failures and their classification, evidence, checks, recovery, telemetry, logs, metrics, dashboards, and alerts. |
| `network:` | `https://yuruna.com/ontology/2026/10/network#` | Protocols, interfaces, links, addressing, name resolution, routing, proxies and caches, and the network conditions, failures, and checks. |
| `security:` | `https://yuruna.com/ontology/2026/10/security#` | Credentials, secrets, authentication, certificates, trust, permissions, and the assessment views and conditions. |
| `software:` | `https://yuruna.com/ontology/2026/10/software#` | Artifacts, releases, container images and registries, configuration, deployment, Kubernetes resources, packages, localization, and documentation. |
| `storage:` | `https://yuruna.com/ontology/2026/10/storage#` | Filesystems, mounts, shares, pools, replication, archives, the stash, downloads, and content addressing. |
| `testing:` | `https://yuruna.com/ontology/2026/10/testing#` | The runner, its cycles, plans, sequences, steps, pool, console input and recognition, retries, and sequence failures. |
| `examples:` | `https://yuruna.com/ontology/2026/10/examples#` | The concepts of the example projects: the AmisAd matching and settlement example, and the yuruna-project examples with their Text-to-SQL agent and website. |

A concept belongs to exactly one namespace and keeps its relationships across
them: an example's settlement is still a `y:Process`, and a network failure is
still a `diagnostics:Failure`. A failure, check, or configuration record lives in
the area it is about, so a DHCP lease check is `network:`, not `diagnostics:`.
Every concept's local name is unique within the version, so a reader who knows a
name can find it in any namespace.

The ontology describes kinds, not inventory: it contains no deployed hosts,
people, accounts, addresses, credentials, or incident occurrences. The security
assessment views (Baseline, Configuration, Implementation, Telemetry) and the
conditions compared between them (Authorized, Unavailability, Exposure,
Shortfall, Patch, Drift, Finding, Unmonitored, Nonconformity) follow the
definitions in [definition.md](../../../definition.md#42fa6f45-0041).

<a id="4268f34b-0002"></a>

## Open and explore it

| Tool | How |
| --- | --- |
| [Protege](https://protege.stanford.edu/) (desktop) | File > Open, choose `yuruna.owl`. The Entities tab lists classes and properties; Edit > Find (Ctrl+F, Cmd+F on macOS) searches labels, definitions, and retired names. Reasoner > HermiT > Start reasoner checks consistency. |
| [WebVOWL](https://service.tib.eu/webvowl/) (browser) | Ontology > Upload ontology, choose `yuruna.owl`, then pan and zoom the graph; selecting a node shows its annotations. |
| Python with [rdflib](https://rdflib.readthedocs.io/) | `python -m pip install rdflib`, then run the query below from this directory. |
| Any text editor | Plain RDF/XML, sorted by class name, one `<owl:Class>` block per concept. |

```python
from rdflib import Graph

g = Graph().parse("yuruna.owl", format="xml")
query = """
PREFIX security: <https://yuruna.com/ontology/2026/10/security#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX skos: <http://www.w3.org/2004/02/skos/core#>
SELECT ?label ?definition WHERE {
  ?condition rdfs:subClassOf security:AssessmentCondition ;
             skos:prefLabel ?label ; skos:definition ?definition .
}
ORDER BY ?label
"""
for row in g.query(query):
    print(f"{row.label}: {row.definition}")
```

Replace the pattern to answer other questions: `network:NetworkTimeoutFailure
y:diagnosticCheck ?check` lists the checks that discriminate a transport
timeout; `?concept y:context "AmisAd"@en` lists one project's terms;
`?concept y:retiredLabel ?old` finds a concept by a name it no longer uses. The
annotation vocabulary (`y:context`, `y:diagnosticCheck`, and the rest of the
table below) stays in the base namespace whichever namespace the concept is in.

<a id="4268f34b-0003"></a>

## Reading a concept

| Annotation | Meaning |
| --- | --- |
| `skos:prefLabel`, `rdfs:label` | Preferred English term (both carry the same value). |
| `skos:altLabel` | Recognized abbreviation or alternative wording. |
| `skos:definition`, `skos:scopeNote` | Meaning in context; distinctions, limits, and translation traps. |
| `y:context` | Shared, Yuruna, AmisAd, or Text-to-SQL. |
| `y:codeToken`, `y:codeVocabulary` | A machine-facing token and the enum it belongs to; translations preserve it verbatim. |
| `y:retiredLabel` | A former name, kept for recognition only. |
| `dcterms:source` | The source revision the concept was taken from. |

Named subclass axioms express taxonomy, and object properties have explicit
domains and ranges. `possibleCause`, `diagnosticCheck`, `suggestedRecovery`, and
`relatedConcept` are annotations between classes: they are queryable but entail
no diagnosis and authorize no action. The model is open-world, so an absent
assertion means unknown, not false.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.26

Back to [Yuruna ontology versions](../../README.md)
