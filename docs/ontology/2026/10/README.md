<a id="4268f34b-0001"></a>

# Yuruna ontology

This guide describes **version 2026/10** of the ontology in
[yuruna.owl](yuruna.owl): the English vocabulary of Yuruna, covering the kinds
of things the framework talks about, how they relate, and the diagnostic
associations between failure categories, checks, and recovery advice. It is one
self-contained OWL 2 file in RDF/XML with no remote imports, written for
translators, for operators debugging a lab, and for tools that need stable
identifiers. Its namespace, `https://yuruna.com/ontology/2026/10/yuruna#`,
supplies those identifiers; nothing is served at that address.

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
PREFIX y: <https://yuruna.com/ontology/2026/10/yuruna#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX skos: <http://www.w3.org/2004/02/skos/core#>
SELECT ?label ?definition WHERE {
  ?condition rdfs:subClassOf y:AssessmentCondition ;
             skos:prefLabel ?label ; skos:definition ?definition .
}
ORDER BY ?label
"""
for row in g.query(query):
    print(f"{row.label}: {row.definition}")
```

Replace the pattern to answer other questions: `y:NetworkTimeoutFailure
y:diagnosticCheck ?check` lists the checks that discriminate a transport
timeout; `?concept y:context "AmisAd"@en` lists one project's terms;
`?concept y:retiredLabel ?old` finds a concept by a name it no longer uses.

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

Last review: 2026.10.18

Back to [Yuruna ontology versions](../../README.md)
