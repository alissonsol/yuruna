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

<a id="420b66d2-0004"></a>

## Translating a source revision

`tools/Export-Localization.ps1` prepares a request covering terminology,
catalogs, mapped documents, and official project display values in the paired
[project repository](https://github.com/alissonsol/yuruna-project).
JSON, CSV, and XLIFF 2 are supported. The request README explains the selected
format and the translator and independent reviewer attestations.

`tools/Import-Localization.ps1` validates source digests, schemas, placeholders,
variants, and review identities in staging before applying either repository.
`-WhatIf` writes nothing. Partial reviewed returns retain unanswered catalog
entries and remain incomplete; `-RequireComplete` rejects missing rows.
`-EnableLocale` additionally requires complete accepted content and a pinned
plural rule before setting a locale supported. Never replace missing human
reviews with generated approvals.

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
