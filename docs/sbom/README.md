<a id="427fb0be-0001"></a>

# Software bill of materials

Each repository carries separate inventories for repository dependencies, host
software, and guest software. Host and guest inventories cover software
installed or referenced by the shipped setup, provisioning, and workload
scripts, including VM and container image declarations. The repository
inventory records package manifests, existing lockfiles, and build tools.
Python 3.11+ and Git are included as requirements of the SBOM tooling itself.

| Scope | SPDX 2.2.1 JSON | CycloneDX 1.7 JSON | SWID 2015 XML |
|---|---|---|---|
| Repository | [repository.spdx.json](repository.spdx.json) | [repository.cdx.json](repository.cdx.json) | [repository.swidtag](repository.swidtag) |
| Hosts | [hosts.spdx.json](hosts.spdx.json) | [hosts.cdx.json](hosts.cdx.json) | [hosts.swidtag](hosts.swidtag) |
| Guests | [guests.spdx.json](guests.spdx.json) | [guests.cdx.json](guests.cdx.json) | [guests.swidtag](guests.swidtag) |

The formats follow [ISO/IEC 5962:2021, SPDX 2.2.1](https://www.iso.org/standard/81870.html),
[ECMA-424 second edition, CycloneDX 1.7](https://ecma-international.org/publications-and-standards/standards/ecma-424/),
and [ISO/IEC 19770-2:2015, SWID](https://www.iso.org/standard/65666.html).
SPDX 2.2.1 uses the `SPDX-2.2` wire identifier. Aggregate SWID corpus tags link
to individual component tags under `swid/`; corpus tags describe source
software and do not assert installation on a machine.

[inventory.json](inventory.json) contains the normalized source evidence,
component counts, source-input hashes, and coverage notes behind all three
formats. Evidence identifies the source path and line of each declaration.
Host/guest installation inputs and package dependency graphs are separate
views; consult the repository inventory for package dependencies established
by existing manifests and lockfiles.

Other repositories:
[yuruna-project](https://github.com/alissonsol/yuruna-project/blob/main/docs/sbom/README.md),
[yuruna.link](https://github.com/alissonsol/yuruna.link/blob/main/docs/sbom/README.md),
and [amisad.dev](https://github.com/alius-git/amisad.dev/blob/main/docs/sbom/README.md).

<a id="427fb0be-0002"></a>

## Evidence and unresolved dependencies

Collection uses the files in the repository. It performs no network requests,
package restores, container inspection, vulnerability scanning, or new
lockfile generation. Go module manifests and available checksum records,
Rust/npm locks, .NET and browser-library manifests, Flutter declarations,
Bazel pins, OpenTofu/Terraform declarations, external Helm chart actions,
Dockerfiles, installation commands, package arrays, cloud-init seeds, and
VM/image configuration supply the inventory
evidence. Host requirement floors and central guest provisioning pins are also
recorded; a floor or floating release line is a version constraint, not an
installed version.

Floating image tags, package ranges, variables that cannot be resolved from
source, and dependencies of externally downloaded installers remain explicit
constraints or coverage notes. Distribution package dependencies and image
contents require a deployed or build-time scan to establish. Known names are
listed without an invented version; unestablished licenses use `NOASSERTION`
in SPDX. CycloneDX compositions remain incomplete because this inventory does
not establish every runtime dependency graph.

The recorded creation date is the initial inventory creation date. A source
digest identifies each regenerated inventory; checksums already present in
package locks or download declarations retain their meaning and provenance.
Source-input hashes normalize CRLF to LF in UTF-8 text and preserve binary
bytes. Generated SBOMs and their documentation are excluded from their own
inputs. This makes maintenance reproducible across Windows, macOS, and Ubuntu.

<a id="427fb0be-0003"></a>

## Update and compare

Use Python 3.11 or newer and Git from a repository root:

```sh
python tools/Sync-Sbom.py --update
python tools/Sync-Sbom.py --check
```

Use `python3` where that is the Python command. Each generator and collector is
identical across the four repositories; `tools/sbom-policy.json` supplies the
repository name, source URL, creator, creation date, and declared license.
The canonical tool sources live in the framework's `tools/` folder. Copy all
three Python files together when changing their implementation, and run
`python -m unittest discover -s tools/tests -p 'test_sbom*.py'` in the framework.

Only changed output is written. Before replacement, its old bytes are saved
to the same filename with `.previous` appended. A newly created SBOM has no
prior version; an unchanged run preserves both current and previous files.
A retired component tag is removed while its `.previous` file remains.
The prior version is retained once, rather than building an accumulating
history directory.

```sh
git diff --no-index docs/sbom/hosts.spdx.json.previous docs/sbom/hosts.spdx.json
git diff --no-index docs/sbom/guests.cdx.json.previous docs/sbom/guests.cdx.json
```

<a id="427fb0be-0004"></a>

## Before a commit

The pre-commit hook runs SBOM maintenance after the existing generators. It
reads the exact staged source snapshot, regenerates all scopes locally, and
stages changed SBOMs and `.previous` files in one Git transaction. It does not
stage unrelated working-tree changes. Unstaged changes to the generator or
generated outputs block regeneration so they cannot be overwritten or
misrepresented. Staging failure restores the previous output files.

Enable the tracked hook in a clone with:

```sh
git config core.hooksPath tools/githooks
```

Hook activation is local Git configuration. Each clone needs this setting
unless its installer already enables the tracked hooks.
Missing Python 3.11+, generation errors, and unresolved index conflicts block
the commit. The existing framework BOM, source-metadata, translation, catalog,
and suite checks retain their behavior.

For an explicit staged update:

```sh
python tools/Sync-Sbom.py --update --staged --stage
python tools/Sync-Sbom.py --check --staged
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.18.1

Back to [Yuruna documentation](../README.md)
