<a id="420b66d2-0001"></a>

# Languages and localization

<!-- yuruna-locale-support {"manifest":"globalization/locale-manifest.json","predicate":"status=supported","catalogSet":"globalization/manifests/catalog-set.json"} -->

The [locale manifest](../globalization/locale-manifest.json) shipped with each
version lists its runtime languages. Entries marked `supported` have complete
compiled catalogs for that candidate; `planned` entries are unavailable, and
`pseudo` entries are developer checks. English (`en-US`) is the default.
Translated operator documents are listed in the
[Portuguese documentation index](pt-BR/index.md). A translated document does
not by itself enable a runtime language.

<a id="420b66d2-0002"></a>

## Choosing a language

The `language` setting in `test/test.config.yml` defaults to `auto`. An explicit
supported language locks the run to that language. Automatic selection uses a
validated browser preference, the HTTP `Accept-Language` header, then the
process UI culture, with English as the fallback. Unsupported values never
load arbitrary files. The effective context is fixed for a run or request so
its page, log, and transcript use the same choice.

Expanded (`qps-Ploc`) and mirrored (`qps-Plocm`) pseudo-locales are development
checks, not supported translations. Service deployments must explicitly allow
pseudo-locales before browsers can request them. They expose clipped labels,
untranslated text, and direction assumptions without changing identifiers or
commands.

<a id="420b66d2-0003"></a>

## Adding or changing messages

Write a whole message in `globalization/catalogs/en-US/<domain>.json` with a
stable domain key, context for the translator, and named typed placeholders.
Keep IDs, routes, paths, protocol values, and command tokens out of translated
text. Compare stable codes and typed values rather than rendered prose.
External details are arguments and must be escaped at their output boundary.

PowerShell uses `Format-CatalogMessage`; Go services use the shared `i18n`
package; browser code uses `YurunaI18n.t`. Static HTML marks leaf text with
`data-i18n` and presentation attributes with `data-i18n-title`,
`data-i18n-aria-label`, or `data-i18n-placeholder`. Catalog text never becomes
executable HTML. Generated tables and embedded runtimes are rebuilt together:

```powershell
pwsh tools/Invoke-CatalogCompile.ps1 -Update
pwsh tools/Invoke-CatalogEmbed.ps1
pwsh tools/Invoke-CatalogCompile.ps1 -Check
pwsh tools/Invoke-CatalogEmbed.ps1 -Check
```

The compiler returns `1` when `-Update` changes artifacts; a subsequent check
must return `0`. Do not hand-edit generated files. Supported locale delivery is
derived from the manifest for PowerShell, browser assets, and Go registries.
Plural rules and number separators are pinned in that same authority; host
locale databases do not decide message variants.

Console output: PowerShell writes catalog text in the console's code page. A
Windows console on cp437 or cp1252 prints Chinese and Hebrew as question
marks; the operator entry points switch the process to UTF-8, and Windows
Terminal is UTF-8 already. No console applies bidirectional reordering, so
Hebrew command output and transcripts appear in logical order.

<a id="420b66d2-0004"></a>

## Translating a source revision

Contributors change only the English catalogs. The project maintains
every other listed language. New or changed English is first drafted by
machine translation and marked in the catalog as a draft
(`"origin": "machine"`). Professional translations then replace the drafts
in batches that the maintainers import. An entry is either accepted (no
marker) or a machine draft; drafts ship, and the marker is removed only
when a professional return replaces the text. The commit that lands a
translation is its record.

In a public clone the commit hook has no drafter, so a change that adds
or edits English is refused until the maintainers' repository drafts the
other languages; open the change with the English only and say so in its
description.

Imports validate source digests, schemas, placeholders, and variants in
staging before either repository changes. They apply only rows whose
English is unchanged since the request was prepared, and list the rest
for the next request.

Source changes create a delta request. Accepted answers are carried forward
only for unchanged source rows. Translation, generated catalogs, and source
hash metadata form one versioned pair. Rollback restores the corresponding
code, catalogs, and manifests together; it must not mix artifacts from versions.

<a id="420b66d2-0005"></a>

## Checking a change

Run the catalog, UTF-8, terminology, document translation, project locale-map,
accessibility, and performance gates, then the full paired test gate.
Use expanded and mirrored locales, keyboard-only navigation, zoom, narrow
layouts, Unicode input, and the supported browser floor. Measured browser and
runtime budgets need real samples; unit fixtures do not replace native browser
or independent language review.

See [contributing](../CONTRIBUTING.md), [operator configuration](operator.md),
and [project display text](https://github.com/alissonsol/yuruna-project/blob/main/docs/globalization.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.
