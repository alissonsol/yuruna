# Installer and in-guest script integrity — design plan (P0)

> Status: DESIGN, awaiting operator approval. No code changes are made by
> this document. Every security value below is marked **CONFIRM BEFORE
> IMPLEMENTING** and must be verified against the live upstream source at
> implementation time. Several choices are deliberately left as operator
> DECISIONS rather than decided here — see the Decisions-required table.
>
> **Operator decisions folded into this revision:** (1) **Item 4** is reduced
> to a one-line transparency message in `fetch-and-execute.sh`; guest-side
> sha/sidecar verification is **declined** — the guest is a disposable test VM
> fetching from the same trust domain, so per-fetch verification adds OCR
> failure-marker surface for negligible gain. (2) **Item 7** (host tool/image
> download verification) is added so the design's focus stays on genuine
> *install* integrity. The remaining items still await approval.

## 1. Summary and threat-ranked overview

The Yuruna bootstrap chain pipes fetched bytes straight into a privileged
shell or package install at every hop, with **no integrity gate anywhere**:
no signature, no pinned hash, no pinned commit, no pinned key fingerprint.
An attacker who controls any single hop gets code execution on the host
(as Administrator/root after elevation) and, transitively, on every guest
the host provisions. The very first install on a fresh host is
trust-on-first-use (TOFU) over TLS alone. Worse, the chain re-derives trust
from `main` (a moving ref) at several independent moments, so the exposure
is not a point but a window that stays open from the operator's paste
through guest provisioning.

The tracked P0 items each close one hop. Ranking the hops by
exploitability (likelihood × reachability × blast radius) gives the
operator the priority order and shows which fixes are highest-leverage.
Items 1–3, 5, and 6 harden the operator-trust bootstrap chain; Item 7
hardens the host's tool/image downloads; Item 4 is a transparency message
(verification declined). This document also corrects three places where
`docs/opportunities.md` is wrong or stale, and surfaces additional
supply-chain hops left for the P1 follow-on.

| Rank | Hop | What a compromise yields | Closed by | Honest limit |
|---|---|---|---|---|
| 1 | `git clone --branch main` (all 3 installers) | One force-push or malicious merge to `main` compromises every install, every re-pull, and propagates into guests | Item 2 (pin to tag) | Tag name is still mutable; needs signed tag / recorded SHA |
| 2 | First fetch `irm\|iex` / `curl\|bash` from `refs/heads/main` | RCE-as-admin on a fresh host before any trust exists | Item 1 (publish + verify sha256) | Hash travels the same channel — defends cache-poisoning / partial / corruption / `main`-drift, NOT a full MITM. Real root of trust needs a signature |
| 3 | In-guest `wget <status-server>/yuruna-repo/<path> \| bash` | Root RCE in guest; also the benign working-tree-rename race runs truncated content | Item 4 (transparency message; verification **declined**) | A disposable guest fetching from the same trust domain — verification adds OCR-marker cost for negligible gain; the rename race is handled operationally by the capture self-heal, not an integrity gate |
| 4 | Windows installer multi-fetch (up to 3 fetches of a moving ref) | Each re-fetch is an independent swing; the elevated re-fetch can serve different bytes than the operator approved | Item 3 (materialize once, `-File` everywhere) | The FIRST fetch is irreducible under `irm\|iex`; covered by Item 1 |
| 5 | MS / GitHub CLI apt key fetch (no fingerprint check) | MITM installs an attacker key as the permanent trust anchor for the repo | Item 5 (verify-before-trust) | Pinning trusts the vendor's key infra; rotation can hard-fail installs |
| 6 | No-BOM regression on the Windows bootstrap | A stray BOM bricks PS5.1 `irm\|iex` at the param block (denial-of-bootstrap) | Item 6 (enforce existing gate at commit/release) | Pre-commit hook is advisory; release gate is the real backstop |
| 7 | Host tool/image downloads — Get-Image ISOs/cloud images (warn-only checksum) and the Windows 11 ISO via `Fido.ps1` (no checksum) | A poisoned base image/ISO compromises **every guest** built from it | Item 7 (hard-fail checksums + Ubuntu `SHA256SUMS` GPG verify + pin `Fido.ps1` to a commit) | Different trust axis (vendor CDNs/keys, not the project `main`), so ranked low on *likelihood* despite high blast radius; Windows 11 has no stable upstream hash |

**Doc corrections folded in:** (a) Item 3's proposed `-EncodedCommand` is
**infeasible** — the 44,367-byte installer base64-encodes to ~118,000
chars, ~3.6× over the 32,767 CreateProcess command-line cap. The real fix
is one BOM-less temp file via `-File`. (b) Item 4 has been **reduced to a
transparency message** — guest-side verification is declined (operator
decision), so the earlier analysis of where a sha check would have to live is
now moot. (c)
Item 6 is **~80% already built** — `test/Test-AsciiNoBom.ps1` exists and is
wired into the per-cycle `Test-Config.ps1` gate; what is missing is
commit-time / release-time enforcement.

## 2. Decisions required (approval checklist)

Approval of this plan is approval of the recommendations below unless the
operator overrides them. None of these is decided unilaterally; each is a
policy or security-posture choice.

| # | Decision | Recommendation | Why it is an operator call |
|---|---|---|---|
| D1 | Root of trust for the first fetch (Item 1): sha256 only, or a real signature? | sha256 now (closes cache-poisoning / partial / corruption / `main`-drift and gives Item 4 a working hash primitive); open a **P1 for a detached signature** so the operator consciously owns the residual MITM gap | A signature adds key management and a new trust surface |
| D2 | Canonical tag scheme (Item 2). Three live dialects: tag `2026.05.29` (no `v`), tag `v2026.05.22` (with `v`), installer `.VERSION 2026.07.03` | Bare CalVer `YYYY.MM.DD` — already matches the newest tag AND the installer's own `.VERSION`, minimizing churn. Pin URLs/clones to the tag **and record the tag→commit SHA** in the manifest | Tag naming is project policy; do not pick unilaterally |
| D3 | Pin granularity: tag name vs full commit SHA | Tag in URLs/clones for readability; record + (optionally) verify the tag→SHA mapping in `install.sha256`; pair with D5 | Trades usability vs immutability |
| D4 | `main`-fallback policy when the pinned tag clone fails | Fall back to `main` **only on explicit operator opt-in** (`-YurunaBranch main` / env var) with a loud warning — never silently | Silent fallback re-opens the moving-target hole |
| D5 | Fail-hard vs warn on mismatch (Items 4, 5, and the clone fallback) | **Hard-fail** on guest sha mismatch (Item 4) and key-fingerprint mismatch (Item 5) — a mismatch there is corruption or attack, never benign. **Warn-and-fall-back** on a missing clone tag (Item 2 / D4), since a missing tag on a fresh checkout is an operational reality | Hard-fail trades availability for integrity on upstream rotations |
| D6 | GitHub CLI key pin given the in-flight rotation (cli/cli #13118) | Accept an **allow-set {old, new}** during the rotation window and document a refresh procedure (mirroring the usbmmidd SHA-256 refresh pattern). Require the NEW key present (old expires 2026-09-05) | A single hard pin breaks the moment GitHub flips the key |
| D7 | Microsoft key: switch to `microsoft-2025.asc`, or select by repo generation? | Switch to `microsoft-2025.asc` (AA86…) for the documented target (Ubuntu 26.04+), keeping a `VERSION_ID` guard to also support ≤24.04 via the legacy key. This also fixes a latent NO_PUBKEY correctness bug | Changing the trusted key constant is a security-posture change |
| D8 | ~~Behavior when no guest sha is available~~ | **RESOLVED — moot.** Operator declined guest-side verification (Item 4 is message-only), so no sha is ever computed or required | — |
| D9 | ~~Layer for Item 4: detection vs per-cycle snapshot cure~~ | **RESOLVED — neither.** Verification declined; the working-tree-rename race is handled operationally by the existing capture self-heal (`feedback_status_server_working_tree_rename_race`, `feedback_frozen_capture_feed_idle_tail`), not an integrity gate. Per-cycle snapshot serving may be revisited as a separate robustness item, but is no longer part of #1 | — |
| D10 | No-BOM gate enforcement point (Item 6) — there is no `.github/` today | Ship a repo-tracked **pre-commit hook** (`core.hooksPath`) + make the **release script a hard gate**. Treat adding CI (`.github/`) as a separate operator decision | Adding CI introduces a new trust/infra surface |
| D11 | Scope of the missed hops (Homebrew, PowerShell .deb, libosinfo) for THIS P0 | Document as same-shape **P1 follow-on**; keep this P0 to the tracked items to bound effort | Scope/effort bound |
| D12 | Image checksum policy (Item 7): warn-only vs hard-fail on mismatch | **Hard-fail on mismatch** (a mismatch is corruption or tamper, never benign — consistent with D5); keep **warn-and-continue on a *missing* upstream checksum** (publisher lag on dailies is operational reality) | Trades availability for integrity on upstream hiccups |
| D13 | Authenticate the Ubuntu image hash + pin the Windows 11 downloader (Item 7) | Verify `SHA256SUMS` against `SHA256SUMS.gpg`/`Release.gpg` with a **pinned Ubuntu archive signing-key fingerprint** (upgrades warn-only hash to authenticated integrity); pin `Fido.ps1` to a **commit SHA**, not `master` | Adds a vendor-key trust anchor + a refresh task on key rotation |

## 3. Values to confirm (all CONFIRM BEFORE IMPLEMENTING)

Nothing below may be hardcoded from this document. Every fingerprint/hash
must be re-verified against the live source at implementation time.

| Value | Proposed (confirm) | Source / how to verify |
|---|---|---|
| Microsoft 2025 apt key fingerprint (`microsoft-2025.asc`, Ubuntu 25.10+/26.04) | `AA86F75E427A19DD33346403EE4D7792F748182B` | learn.microsoft.com/linux/packages → section `microsoft-2025.asc`. Verify: `curl -fsSL https://packages.microsoft.com/keys/microsoft-2025.asc \| gpg --show-keys --with-fingerprint` |
| Microsoft legacy apt key fingerprint (`microsoft.asc`, Ubuntu ≤24.04) | `BC528686B50D79E339D3721CEB3E94ADBE1229CF` | learn.microsoft.com/linux/packages → section `microsoft.asc` |
| GitHub CLI NEW key fingerprint (post-rotation) | `7F38BBB59D064DBCB3D84D725612B36462313325` | github.com/cli/cli issue #13118; `curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \| gpg --show-keys --with-fingerprint` |
| GitHub CLI OLD key fingerprint (expires 2026-09-05) | `2C6106201985B60E6C7AC87323F3D4EA75716059` | cli/cli #13118; the fetched keyring lists both keys |
| PowerShell release checksum artifact | `hashes.sha256` asset at `…/releases/download/v${ver}/hashes.sha256`; lines `<64-hex>  <filename>` (two spaces) | GitHub release asset list for the pinned `v${ver}`. Hash VALUES are per-version — fetch at install time, never pin in-script |
| `install.sha256` contents (3 installers) | Computed from the **tagged** tree at release time (`git archive <TAG>` / clean checkout, then `sha256sum`) — NOT the working tree | Generated by the release script. No external value |
| Canonical release tag + its commit SHA | A fresh release tag cut for the pinned release (newest existing is `2026.05.29` → `e849b65`) | `git for-each-ref refs/tags` |
| `refs/tags/<TAG>` raw URL resolves | URL format established (mirrors existing `refs/heads/main` one-liners) | Smoke-test `curl -fsSL …/refs/tags/<TAG>/install/README.md` once the tag exists |
| macOS hash-check command | macOS default is `shasum -a 256 -c` (BSD), not GNU `sha256sum` | BSD/macOS base tooling |
| `$MyInvocation.MyCommand.ScriptBlock.ToString()` returns full source under PS5.1 `irm\|iex` | Believed yes; load-bearing for Item 3 | Live test on a real Windows PowerShell 5.1 host before merge |

## 4. Item-by-item design

### Item 1 — Publish `install.sha256` and verify before piping

**Threat.** The first fetch (`irm\|iex` / `curl\|bash` from
`refs/heads/main`) has zero integrity check; TLS is the only protection and
it is unauthenticated TOFU on a fresh host. A network/CDN/MITM attacker who
serves different bytes runs arbitrary code (Administrator after the Windows
UAC relaunch). Even absent a MITM, `main` is a moving target: the operator
approves "the installer" but receives whatever was last pushed.

**Current (file:line).** `install/README.md` L31/38/44 — all three
one-liners fetch `refs/heads/main/install/<file>?nocache=<ts>` and pipe
straight to `iex`/`bash`. No hash is printed and no `sha256sum -c` runs.

**Proposed fix.** Build `install/install.sha256` from the EXACT tagged tree
at release time, listing the three installers' sha256sums, and publish it
in the repo (fetchable at the tag) and ideally as a GitHub Release asset.
Add a **verified two-step path** next to the convenience one-liner (a
single pipe cannot verify before executing):

- Ubuntu/macOS: `curl -o` the file at the pinned tag → `sha256sum -c -`
  (macOS: `shasum -a 256 -c -`) → execute the local file.
- Windows (PS5.1-safe): `irm … -OutFile`, compare `(Get-FileHash …
  -Algorithm SHA256).Hash` (UPPERCASE) → execute.

Keep the fast `irm\|iex` / `curl\|bash` one-liner clearly labelled
UNVERIFIED; present the verified path as recommended. Inline the expected
hashes from `install.sha256`, regenerated by the release script so they
never go stale.

**Residual risk.** The hash travels the **same channel** as the installer,
so a full-path MITM rewrites both. The hash defends cache-poisoning,
partial content, accidental corruption, a stale mirror, and `main`-drift —
it is integrity-against-accident and against-drift, **NOT** a cryptographic
root of trust against an active MITM. That needs a signature (D1). The
convenience one-liner stays unverified by construction.

**Effort.** Small-to-Medium. Generator + README edits ≈ 0.5–1 day.

**Implementation (Item 1 done; D1 upgraded to signature-now).** `install/install.sha256`
(SHA-256 of the three installers) is generated + signed by
`tools/Update-YurunaReleasePins.ps1` into `install/install.sha256.sig` — a
detached RSA-4096 PKCS#1 v1.5 / SHA-256 signature. The bundled public key
(`install/keys/yuruna-release-signing.pub.{pem,xml}`, fingerprint
`14fce044…c337`) verifies it on every fresh host with no extra tooling:
`openssl` on macOS/Linux and .NET `RSACryptoServiceProvider.FromXmlString` on
Windows PowerShell 5.1 (the `irm|iex` target). The verified two-step path lives
in `install/README.md`; the release private key is held out-of-repo by the
release owner (the script reads it via `-PrivateKeyPath` at release time) and the
script runs the ASCII gate as a hard precondition (closes Item 6's release-gate
half). Tag scheme is bare CalVer from `VERSION`. **Item 2 (complete):** the
clone pinning + release-time pin-rewriting is implemented in
`tools/Update-YurunaReleasePins.ps1`.

### Item 2 — Pin clones to release tags, not `main`

**Threat.** All three installers `git clone --branch main` (windows
L600/605, ubuntu L511/516, macos L475/480), a second moving-target fetch of
the WHOLE repo. The cloned working tree (every host/guest/automation script
later executed) can differ from the audited installer. A force-push or a
mid-window malicious commit on `main` lands on the host. **Highest blast
radius**: one push compromises every install, every re-pull, and every
guest.

**Current (file:line).** windows.hyper-v.ps1 L600/L605 (`$YurunaBranch`
default `main`, L33); ubuntu.kvm.sh L511/L516 (`YURUNA_BRANCH:-main`);
macos.utm.sh L475/L480 (default `main`). Tags are inconsistent:
`2026.05.29` (e849b65) and `v2026.05.22` (921f6a7) — both confirmed via
`git for-each-ref`.

**Proposed fix.** Adopt ONE tag scheme (D2: recommend bare CalVer) and pin:
change the three README one-liners to `refs/tags/<TAG>/…` and the three
installer defaults from `main` to the release tag, cloning
`--branch <TAG> --depth 1`. Fall back to `main` **only on explicit operator
opt-in with a loud warning** (D4) — never silently. Because pinning means
the README and installer defaults must be bumped every release, add a
single release script (`Update-YurunaReleasePins.ps1`) that rewrites the
tag token in `README.md` + the three installer defaults + regenerates
`install.sha256` in one commit, so the three never drift. This pinning is
also the precondition that makes Item 1's hashes meaningful (an immutable
target).

**Residual risk.** A tag name is mutable (force-moveable by anyone with
push), so pin-to-tag-name still allows a moved-tag attack — record the
resolved commit SHA for true immutability and recommend signed annotated
tags (D1/D5). A freshly-tagged-and-signed **malicious** release still flows
through; defense is code review + tag protection, outside these tracked items.

**Effort.** Medium. Code edits are small; the release-process plumbing
(rewrite + regenerate + gate + cut tag in one commit) is the bulk, ≈ 1–2
days incl. per-host clone-from-tag verification, plus a one-time
tag-scheme reconciliation.

**Implementation.** No installer clone/pull change was needed: the existing
`clone --branch <ref>` + `checkout <ref>` + `pull --ff-only origin <ref>`
handles either a branch or a CalVer tag transparently. The clone DEFAULT stays
on the moving `main` branch, so a normal install **auto-updates the framework
every cycle** (the runner's per-cycle `pull --ff-only` fast-forwards the
tracking branch). Pinning to a release is OPT-IN via `-PinVersion` (Windows) /
`PIN_VERSION=1` or `--pin-version` (bash): after cloning, the installer reads
the repo's own `VERSION` file (top of the repository) and checks that tag out as
a detached HEAD, which has no upstream, so the per-cycle pull is a no-op and the
host freezes. `tools/Update-YurunaReleasePins.ps1` regenerates + signs
`install.sha256` and bumps the README verified-download tag (ASCII gate as a
hard gate); the installers carry no baked version and their `main` clone default
is untouched, so a release never re-pins a fresh install. The convenience
one-liners deliberately stay on `refs/heads/main` (unverified latest). An
explicit `YURUNA_BRANCH=<tag>` / `-YurunaBranch <tag>` pins to any specific
release. Per-release work is just "bump VERSION, run the script, cut the tag."

### Item 3 — Collapse the Windows-installer multi-fetch

**Threat.** Under `irm\|iex` on PS5.1 there is no `$PSCommandPath`, so the
installer URL is fetched **up to three times** in one invocation:
(1) the operator's `irm`; (2) the elevation relaunch re-`irm`s in the
spawned admin shell; (3) the PS7 relaunch re-`irm`s again in elevated pwsh.
Fetches 2 and 3 re-pull a moving ref with no cross-fetch integrity binding,
so an attacker who loses the race on fetch 1 gets two more swings — in the
elevated/SYSTEM context. The benign analogue is just as real: `main`
advancing between fetches means the elevated child can run a different
installer version than the operator launched (silent version-skew).

**Current (file:line).** Confirmed against the file this session.
Elevation no-`$PSCommandPath` branch L225–235 builds a here-string that
hardcodes the `refs/heads/main` URL and runs `Invoke-RestMethod` +
`[scriptblock]::Create` + `& $sb` in the elevated child (re-fetch #2). PS7
no-`$PSCommandPath` branch L284–297 re-fetches (L290), writes BOM-lessly
via `[IO.File]::WriteAllText(…, UTF8Encoding $false)` (L291), and runs via
`-File` (L293) — **this temp-file pattern is already the correct shape**.

**Proposed fix (doc-corrected).** **Do NOT use `-EncodedCommand`** — the
~44 KB installer base64-encodes to ~118,000 chars, ~3.6× over the 32,767
CreateProcess cap (feedback_createprocess_cmdline_limit). Instead
**materialize the source ONCE to a single BOM-less temp file and relaunch
every child via `-File`**:

- At the top of the script body (before the elevation block), gate on the
  `irm\|iex` case (`-not $PSCommandPath`). Capture the source with
  `$MyInvocation.MyCommand.ScriptBlock.ToString()` (zero extra fetch,
  byte-true to what the operator launched), falling back to one
  `Invoke-RestMethod` only if that is empty (D: option c). Write it
  BOM-less via `[Text.UTF8Encoding]::new($false)` to a GUID-named temp,
  then re-dispatch `& $shell -File $tmp <forwarded params>; return`.
- The relaunched child now has a real `$PSCommandPath = $tmp`, so BOTH the
  elevation branch (L219) and the PS7 branch (L277) take their already-clean
  `-File` paths with zero further fetches. Net: exactly ONE fetch.
- Delete the elevation re-fetch + its hardcoded URL (L226–234). Optionally
  keep the PS7 temp-file branch as a defensive fallback that reuses the
  already-materialized file rather than re-fetching.
- Temp hygiene: GUID-random name (defeats predictable-path symlink/pre-
  creation hijack); child self-deletes in `finally` (the parent cannot
  clean across the UAC boundary without `-Wait`, which would pin the
  non-elevated console); best-effort sweep stale `yuruna-installer-*.ps1`.

**Residual risk.** CLOSED: the 2nd and 3rd fetches and their inter-fetch
version-skew/TOCTOU window — with ScriptBlock capture there is exactly one
fetch and every child runs byte-identical text. IRREDUCIBLE: the FIRST
fetch is unverified-at-transport and is the trust root (you only have bytes
after fetching them); closing it is Item 1's job. The `git clone` target
(Item 2) is separate.

**Effort.** Small-to-Medium, ≈ 25–40 net lines. The only non-trivial risk
is validating `ScriptBlock.ToString()` round-trips the full source on a
real PS5.1 host; if it does not, the design degrades to the IRM-fallback
(2 fetches max). Must re-run `test/Test-AsciiNoBom.ps1`, a real `irm\|iex`
on a fresh PS5.1 non-elevated host, and PSScriptAnalyzer before merge.

**Implementation.** Built with the adversarial-review **primary (IRM-to-temp,
not `ScriptBlock.ToString()`)**, so there is no PS5.1 round-trip-fidelity
assumption. A single materialization gate (after preflight) handles the
`irm|iex` case: when `-not $PSCommandPath`, fetch the source ONCE to a BOM-less
GUID temp and relaunch `& <shell> -File <tmp> -SkipPreflight`; every child then
has a real `$PSCommandPath`, so the elevation and PS7 relaunches take their
`-File` paths. The two elevated re-fetches — the elevation here-string +
`[scriptblock]::Create`, and the PS7 IRM-to-temp — are deleted. Net: one
materialization fetch (non-elevated) + the operator's `irm`; **zero elevated
re-fetches** (confirmed: exactly one `Invoke-RestMethod`, zero
`scriptblock::Create` remain). Temp hygiene: GUID name, the final stage deletes
it at end-of-script, a >1h sweep at the top recovers crash-leaks.
**Residual (MITIGATED, not closed):** the temp lives in user-writable `%TEMP%`
that the elevated child later opens, so a same-user local attacker can still
TOCTOU-race the GUID path; a full fix needs an ACL'd per-user dir or
handle/stdin passing. Statically verified (parse + PSSA + ASCII/no-BOM clean);
**still needs a real `irm|iex` run on a fresh PS5.1 host before relying on it.**

### Item 4 — Transparency message before the in-guest download (verification declined)

**Operator decision.** Guest-side integrity verification (the `?sha=` /
`.sha256` sidecar machinery) is **NOT** implemented.
The guest is a disposable test VM that fetches project code from the **same
trust domain** that already provisioned it — the operator's own host status
server on the LAN, or the pinned project repo (Items 1–2). A per-fetch sha
gate would add a new OCR failure-marker (every marker is a fuzzy-match
liability — `feedback_ocr_failure_pattern_command_echo_false_match`), a
host-side hash producer, and rename-race false-aborts, all for negligible
security gain inside an already-trusted, disposable boundary. The value here
is **transparency, not an integrity gate**: one human-readable line so anyone
watching the console (or the OCR log) sees that remote project code is about
to run.

**Current (file:line).** `automation/fetch-and-execute.sh` L46 is the only
pre-download human line — `echo "fetch-and-execute: $FILE_PATH"` — and it
itself contains the words "fetch"/"execute". The fetch is L64
(`wget … -qO- "$FULL_URL"`); there is no content verification (L71 checks
only wget rc and byte count). The success/failure markers are the end-tags
`FETCHED AND EXECUTED:` (L224) and `NONZERO SCRIPT EXIT:` (L92/L226).

**Proposed fix (the entire change).** Replace the L46 echo with the
awareness message, deliberately worded to avoid the tokens "fetch" and
"execute":

```bash
echo "About to download and run project code: $FILE_PATH"
```

That is the whole change — one line, no new processing. The wording avoids
"fetch"/"execute" for the same reason the failure marker does: the host-side
OCR `FailurePattern` matcher is fuzzy, and those words already appear on
screen via the typed `fetch-and-execute.sh …` command, so a new message
carrying them would widen the false-match surface
(`feedback_ocr_failure_pattern_command_echo_false_match`).

**Confirmed safe.** No sequence keys a `waitPattern`/`failPattern` on the
literal `fetch-and-execute:` echo — the only success `waitPattern` is
`FETCHED AND EXECUTED:` (the L224 end-tag) and the derived `failPattern` is
`NONZERO SCRIPT EXIT:` (`Test.SequenceHandler.psm1` L787/L795). So rewording
the L46 text changes only what a human/OCR-log reads, not step detection
(re-confirm with a `waitPattern`/`failPattern` grep at implementation time).

**The working-tree-rename race is handled elsewhere — not here.** The
non-adversarial race (a mid-cycle edit/rename serving partial/404 content —
`feedback_status_server_working_tree_rename_race`) is mitigated operationally
by the capture self-heal (`Wait-ForText` frame-hashing + `Restart-VMConsole`
on a feed unchanged ≥45s — `feedback_frozen_capture_feed_idle_tail`), not by
a guest integrity check. Eliminating it at the source (per-cycle snapshot
serving) is a separate serving-model robustness item, deliberately out of #1.

**Residual risk (stated plainly).** This message is disclosure, not
integrity. A compromised/spoofed host on the LAN, the unauthenticated
`http://HOST:PORT` "trust whoever answers first" responder, or a mid-cycle
rename can still feed the guest wrong bytes — all **accepted** for the
disposable-guest, same-trust-domain model. The real install-integrity value
lives at the bootstrap (Items 1–3) and the host tool/image downloads
(Item 7).

**Effort.** Trivial — one line in `fetch-and-execute.sh`, plus a shellcheck
run and the confirming `waitPattern`/`failPattern` grep.

### Item 5 — Pin GPG fingerprints (MS / GitHub CLI) in `ubuntu.kvm.sh`

**Threat.** Three TOFU hops where a network/CDN/MITM attacker substitutes a
key or binary the installer then trusts permanently. (1) Microsoft apt key
(L332–334): the fetched key becomes the `signed-by` anchor for the MS repo,
so a swapped key yields root-level package execution. (2) GitHub CLI key
(L578–581): same shape for the `gh` repo. (3) PowerShell tarball (L355): no
checksum/signature — a substituted tarball is unpacked as root and becomes
the interpreter (`pwsh`) that runs ALL downstream Yuruna automation
(highest-value hop). The apt-key hops are partially backstopped by apt
re-verifying packages against the pinned key — but that is exactly what the
TOFU key fetch undermines: trust the wrong key once and apt validates the
attacker's packages forever. The tarball has no such backstop.

**Current (file:line).** Confirmed this session. L332–334
`curl …/microsoft.asc \| sudo gpg --dearmor` — no fingerprint check. L355
`curl …/v${ver}/${pkg}` tarball — no checksum. L578–581 `curl
…/githubcli-archive-keyring.gpg \| sudo dd` — no fingerprint check.
**Latent correctness bug:** the documented target is Ubuntu 26.04+, but the
script fetches the LEGACY `microsoft.asc` while the repo line (L337) targets
a prod repo signed by the NEW 2025 key — likely NO_PUBKEY at `apt-get
update`, masked on x86_64 by the `install_pwsh_apt \|\| install_pwsh_tarball`
fallback (L364). The fix must select the right key per repo generation, not
just pin a fingerprint (D7).

**Proposed fix.** For all three hops: download to a temp file, verify,
install only on match — never pipe an unverified key into the keyring.
- MS key: fetch `microsoft-2025.asc`, compare
  `gpg --show-keys --with-colons` field 10 against the pinned fingerprint
  (space-stripped), `die` on mismatch, then dearmor into the keyring.
- GitHub CLI key: the keyring now contains BOTH old and new keys (multiple
  `fpr:` records), so verify the **set** — require the NEW fingerprint
  present (D6; old expires 2026-09-05).
- PowerShell tarball: **research result — the release publishes a
  `hashes.sha256` asset** covering every artifact. Fetch it from the same
  release tag and `sha256sum -c` the named asset. Do NOT pin a per-version
  hash in-script (`PWSH_VERSION` is operator-overridable). The apt `pwsh`
  path is unchanged (apt already enforces the GPG signature).

Decide hard-fail vs warn (D5: recommend hard-fail — a mismatch is the exact
event the control exists to catch). Run shellcheck after editing.

**Residual risk.** (1) Installer trust is unchanged and dominant — an
attacker who controls the installer delivery edits the pinned fingerprints
themselves; pinning only protects the key fetch GIVEN a trusted installer
(Items 1/2 territory). (2) `hashes.sha256` travels the same channel and is
not a signature — defends asset-swap/corruption, not a release-pipeline or
github.com origin compromise (residual concentrates on aarch64 + the
x86_64 fallback). (3) Pinning trusts the vendor's key infra; a compromise
there defeats it — the correct, expected ceiling. (4) Hard-fail introduces
an availability cost: the next MS/gh rotation aborts installs until the pin
is bumped (gh rotation is already mid-flight) — the operator owns a
"bump the pin on rotation" task.

**Effort.** Small-to-Moderate, contained to `ubuntu.kvm.sh`. Dev ≈ 2 h
(MS block ~12 lines, gh block ~12 lines, tarball ~6 lines, repo-line
correctness fix). Validation ≈ 2–4 h, gated on confirming the fingerprints
and including a live Ubuntu 26.04 KVM smoke test of `apt-get update` with
the 2025 key. **No code lands until fingerprints are confirmed against the
live keys.**

**Implementation (confirmed values).** A shared `verify_key_fingerprints`
helper fetches each apt key to a temp file and pins it BEFORE it becomes a
trust anchor: it dies on any fingerprint outside the allow-set (an injected
key would otherwise become a trusted apt source) or if the required key is
missing — D5 hard-fail, never warn. Pinned fingerprints (each confirmed via a
live `gpg --show-keys`):
- `AA86F75E427A19DD33346403EE4D7792F748182B` — Microsoft 2025 General GPG
  Signer. The MS block now fetches `microsoft-2025.asc` unconditionally
  (preflight requires Ubuntu 26.04+), which also fixes the latent NO_PUBKEY
  mismatch against the 2025-signed prod repo.
- `7F38BBB59D064DBCB3D84D725612B36462313325` (required) + allow
  `2C6106201985B60E6C7AC87323F3D4EA75716059` (legacy, expires 2026-09-05) —
  GitHub CLI keyring (D6 allow-set: require current, reject foreign).

The PowerShell tarball is verified against the release's `hashes.sha256`
(awk-extract the single pinned-version line, then `sha256sum -c`; hard-fail on
mismatch). On a vendor key rotation, refresh the pinned fingerprint constants
at the top of `ubuntu.kvm.sh`.

### Item 6 — `Test-AsciiNoBom.ps1` enforcement gate

**Threat.** The no-BOM constraint on `install/windows.hyper-v.ps1` is
load-bearing: a bulk re-encode that adds a UTF-8 BOM makes PS5.1 `irm\|iex`
die at line 1, before the param block — bricking first-install on every
fresh Windows host (denial-of-bootstrap).

**Current (file:line) — doc is stale.** Item 6 is ~80% already built.
`test/Test-AsciiNoBom.ps1` **exists** (UTF-8 BOM, UTF-16 BOM, and
first-non-ASCII-byte checks; default targets `install/windows.hyper-v.ps1`
+ `guest/windows.11/*.ps1`) and is **already wired** into the per-cycle
gate (`Test-Config.ps1`, runs `-Quiet`, Write-Fail on nonzero). What is
MISSING is commit-time / pre-publish enforcement: there is no `.github/`
(confirmed), `core.hooksPath` is unset (confirmed), and `.git/hooks` holds
only `*.sample`. So the gate fires only when someone runs a full cycle — it
does NOT block a bad commit/push or a release.

**Proposed fix (finishing the missing 20%, no CI assumed).**
- Repo-tracked **pre-commit hook** (`tools/githooks/pre-commit`) that runs
  `pwsh test/Test-AsciiNoBom.ps1 -Quiet` and blocks on nonzero, activated
  per-clone via `git config core.hooksPath tools/githooks` (set in the
  installers' renormalize block / CONTRIBUTING). Must run on Linux/macOS
  too (the file is edited there) — invoke `pwsh`, skip gracefully with a
  printed warning if absent.
- The **release script** (Item 2) MUST run the ASCII gate as a hard
  precondition before cutting a tag / regenerating `install.sha256` — this
  is the real backstop, because the published artifact is exactly what
  fresh hosts fetch.
- Optionally expand the gate's default set to include `ubuntu.kvm.sh` and
  `macos.utm.sh` (not BOM-fatal the same way, but a non-ASCII byte in a
  `curl\|bash` script is a latent locale hazard) — first confirm they are
  already clean.
- Adding `.github/` CI is a **separate operator decision** (D10) — design
  it but do not assume it.

**Residual risk.** The pre-commit hook is advisory — a contributor can
`--no-verify` or never set `core.hooksPath`; only the release-script gate
is authoritative, and it protects the published artifact, not every
intermediate push. The per-cycle gate still will not catch a BOM committed
without ever running a cycle (exactly the gap the hook + release gate
close).

**Effort.** Small, ≈ 0.5 day — the script and per-cycle wiring already
exist; this is the hook + `core.hooksPath` line + release-script hard call
+ (optional) default-set expansion.

**Implementation.** Done except wiring the release-script gate into the release
run (the release script `tools/Update-YurunaReleasePins.ps1` already ships and
already runs the ASCII/no-BOM gate as a hard precondition): `tools/githooks/pre-commit` runs the
ASCII/no-BOM gate and blocks the commit; it is activated per-clone via
`core.hooksPath = tools/githooks` set in the tracked `.gitconfig.yuruna` (which
the install scripts already `include.path`) — no installer edits needed. The
gate's default set was expanded to the two `curl|bash` installers
(`ubuntu.kvm.sh`, `macos.utm.sh`, both confirmed ASCII-clean) alongside the
existing `windows.hyper-v.ps1` + `guest/windows.11/*.ps1`. The hook is advisory
(skips when `pwsh` is absent, bypassable with `--no-verify`); `CONTRIBUTING.md`
records the `git config --local core.hooksPath tools/githooks` activation for
hand-made clones. The release script `tools/Update-YurunaReleasePins.ps1` now
exists and already calls the ASCII/no-BOM gate (`test/Test-AsciiNoBom.ps1`) as a
hard precondition — the authoritative gate for the published artifact; the
remaining work is running it at release time.

### Item 7 — Verify host tool/image downloads (Get-Image checksums + Windows 11 ISO/Fido)

**Threat.** `Get-Image.ps1` downloads the base OS images/ISOs that **every
guest** is built from; a poisoned image is the highest-blast-radius host-side
hop after the clone. The integrity primitive already exists but is run in its
weakest mode, and the Windows path has none at all.

**Current (file:line).** `host/modules/Yuruna.Image.psm1`
`Save-ImageWithChecksum` is the single download chokepoint (L105); its
`-OnMismatch` already supports `WarnAndContinue` (default), `WarnAndDelete`,
and `Throw` (L146-147). Every caller passes the **warn-only** default
(`-OnMismatch 'WarnAndContinue'`, e.g.
`host/macos.utm/guest.amazon.linux.2023/Get-Image.ps1` L66), so a checksum
**mismatch keeps the file** (L199) and a **missing** upstream checksum entry
is accepted without verification (L174). For Ubuntu only the `SHA256SUMS`
hash is checked — its `SHA256SUMS.gpg`/`Release.gpg` signature is **not**
verified, so the hash itself is unauthenticated. The Windows 11 ISO is
fetched via `Fido.ps1` pulled from
`raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1` (moving ref,
unverified) and the resulting ISO gets only a size sanity check (≥ 1 GB) —
**no checksum** (`guest.windows.11/Get-Image.ps1`).

**Proposed fix.**
- **Flip the policy to hard-fail on mismatch (D12).** Pass
  `-OnMismatch 'Throw'` (or `WarnAndDelete`) from the Get-Image callers for
  the images where upstream publishes a checksum (AL2023 `.qcow2.sha256`,
  Ubuntu `SHA256SUMS`). A mismatch is corruption or tamper — never benign.
  Keep **warn-and-continue only for a genuinely *missing* upstream checksum**
  (daily images sometimes lag), and warn that case loudly.
- **Authenticate the Ubuntu hash (D13).** Verify `SHA256SUMS` against
  `SHA256SUMS.gpg` (or `Release.gpg`) using a **pinned Ubuntu archive
  signing-key fingerprint** before trusting any line in it — upgrading
  warn-only-hash into authenticated integrity, mirroring Item 5's
  verify-before-trust discipline.
- **Pin the Windows 11 downloader (D13).** Pin `Fido.ps1` to a **commit SHA**
  instead of `master`, and verify the on-disk script hash before running it.
  Microsoft publishes no stable consumer-ISO hash, so the ISO itself stays
  size-checked + operator-verifiable — flagged as a named residual rather
  than pretended-closed.

**Residual risk.** HTTPS/CA trust still gates the first image pull; the
Ubuntu key pin trusts Canonical's key infra (rotation = a bump task, same
shape as Item 5); the Windows 11 ISO has no authenticated upstream hash, so
that hop stays at "size sanity + the operator's own verification"; pinning
`Fido.ps1` to a commit still trusts the `pbatard/Fido` repo.

**Effort.** Small-to-Medium. The checksum primitive and its `Throw` mode
already exist — the bulk is the per-caller policy flip + the new GPG-verify
step for `SHA256SUMS` + the `Fido.ps1` commit-pin. **No fingerprints/commit
SHAs are hardcoded from this document** — confirm against the live keys/repo
at implementation time.

**Implementation (confirmed values).** D12: all 9 `Save-ImageWithChecksum`
callers use `-OnMismatch 'WarnAndDelete'`; the Ubuntu ISO path throws on a
genuine mismatch (missing/transient stays a soft pass). D13: best-effort
**bundled-keyring** GPG verification — `Test-PublishedChecksumSignature`
(`Yuruna.Image`) imports the repo-bundled keyring
(`host/modules/keys/ubuntu-image-signing-keys.asc`) into an ephemeral homedir
and `gpg --verify`s the detached `SHA256SUMS.gpg` **offline** (no
dirmngr/keyserver — that path fails under a custom `--homedir` on Windows).
gpg-absent / no `.gpg` / key-unavailable → `unverified` (hash-only + warn); a
bad or foreign-key signature → `bad` (hard-fail). Pinned PRIMARY fingerprints,
each verified against the live mirrors via `gpg --verify` → Good signature:
- `843938DF228D22F7B3742BC0D94AA3F0EFE21092` — Ubuntu CD Image Automatic
  Signing Key (2012): `releases.ubuntu.com` + `cdimage` (ISO path).
- `D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81` — UEC Image Automatic Signing
  Key: `cloud-images.ubuntu.com` (cloud path; dual-signed by both keys).

Fido pinned to tag `v1.70` (== commit `3d47260b8915385c58e20c73e24b36e9a9536f3f`),
script SHA-256 `24c86067fa399d2fd75ef0693a2ec79ca8db162827f808caac03541cbf640c13`
verified before execution (mismatch → manual-download fallback). AL2023
(`cdn.amazonlinux.com`) stays hash-only — AWS publishes no detached signature.

## 5. Missed supply-chain hops — P1 follow-on (now closed)

The tracked items left four hops of the **same `curl\|bash` / unchecked-
download shape**. All four are now addressed:

- **macOS Homebrew `install.sh` pipe** (`macos.utm.sh`): **DONE.** Pinned to a
  specific `Homebrew/install` commit and the `install.sh` SHA-256 verified
  before running (hard-fail on mismatch). Homebrew/install publishes no tags
  or signatures, so a pinned commit + content hash is the available control;
  the pin carries a refresh note for Homebrew installer updates.
- **PowerShell `.deb`/tarball** (`ubuntu.kvm.sh`): addressed by Item 5's
  `hashes.sha256` verification on the tarball path; the apt `.deb` path is
  backstopped by apt's signature check.
- **libosinfo tarball** (`ubuntu.kvm.sh`): **DONE.** The dynamically-selected
  latest osinfo-db tarball is GPG-verified against its `.asc` and the pinned
  libosinfo release key (`4252D86A…7062A701`, Pavel Hrdina) before import;
  FAIL CLOSED to the apt-shipped osinfo-db on any verification gap (no gpg,
  no `.asc`, key-unavailable, or a bad signature).
- **All three clones target `main`** — covered by Item 2; listed here for
  completeness.

## 6. Recommended phasing

The order follows the threat ranking and respects dependencies (pinning is
the precondition that makes hashing meaningful).

1. **Phase 0 — reconcile the tag scheme (D2) and cut a pinned release
   tag.** Unblocks Items 1, 2, and 4 (an immutable target is the
   precondition for every hash). Cheap, decision-gated.
2. **Phase 1 — Item 2 (pin clones to the tag) + Item 1 (publish + verify
   `install.sha256`), delivered together via the single release script.**
   Closes Rank 1 (moving-target clone) and Rank 2 (first-fetch
   drift/cache-poisoning) and establishes the release-pin plumbing that
   Item 6's release gate hooks into. Highest leverage.
3. **Phase 2 — Item 5 (key fingerprint pins + PowerShell tarball checksum)
   + Item 7 (host tool/image download verification) + Item 6 (commit/release
   no-BOM enforcement).** Items 5 and 7 share one discipline — verify a vendor
   artifact (apt key, OS image/ISO) before trusting it: Item 5 closes the
   apt-key hole and the latent NO_PUBKEY bug, Item 7 flips image checksums to
   hard-fail and authenticates the Ubuntu hash. Item 6 finishes the ~20% gap
   and adds the release-time gate that Phase 1's script already runs.
4. **Phase 3 — Item 3 (Windows multi-fetch collapse) + Item 4 (transparency
   message).** Item 3 collapses the elevated-context re-fetch TOCTOU to a
   single fetch (then covered by Item 1). Item 4 is a one-line awareness
   message in `fetch-and-execute.sh` (guest-side verification declined).
5. **Phase 4 (follow-up, operator-gated).** D1 detached signature: **DONE**
   (folded into Item 1 — RSA-4096 detached sig on `install.sha256`). The missed
   hops (Section 5): **DONE** (Homebrew + libosinfo). The two remaining optional
   hardenings were **assessed and deliberately skipped** by the operator:
   - **Item 3 `%TEMP%` TOCTOU**: kept as MITIGATED. Per-user `%TEMP%` already
     blocks other users; the same-user residual can only be closed by piping the
     source to the elevated child via stdin (abandons the `-File`/`$PSCommandPath`
     model, UAC-fragile) for a threat that already requires same-user code
     execution — net-negative, not worth it.
   - **Per-cycle snapshot serving** (the working-tree-rename-race *cure*): the
     race is already operationally mitigated by the capture self-heal, and a
     snapshot conflicts with the interceptor workflow (`/yuruna-repo/` serves the
     live working tree so local changes are testable without pushing). Deferred
     unless the workflow trade-off changes.

**What each fix does NOT close (stated plainly):** none of the tracked items
removes TLS/CA trust as the root assumption for the first fetch, the clone,
and the image pulls; `install.sha256` over the same channel is
integrity-against-accident and against-drift, not against an active MITM
(needs a signature); tag-pinning shrinks but does not eliminate the
moving-target window unless the tag is signed and its SHA recorded; Item 4 is
a transparency message, **not** an integrity gate — the guest still trusts
whatever the provisioning host (or a faster LAN responder) returns, and the
rename race is mitigated operationally rather than verified away; Item 7
trusts the OS vendors' CDNs/keys and cannot authenticate the Windows 11 ISO
(no stable upstream hash); and the missed hops remain unverified until the P1
follow-on.

## 7. Adversarial-review refinements (fold in during implementation)

Three independent reviews (security, feasibility, completeness) approved this
design. The corrections below were surfaced against the live files and upstream
sources; apply them when each item is implemented. Two are scope additions
inside existing items; the rest are correctness/accuracy fixes. None changes the
architecture.

### Item 1
- Hash comparison MUST be case-insensitive: Windows `Get-FileHash`.Hash is
  UPPERCASE, `sha256sum`-generated `install.sha256` is lowercase — normalize
  before compare or the Windows verify step false-fails every time.
- The documented recovery path (`install/README.md` L20-26) is the convenience
  one-liner, which stays UNVERIFIED by construction. State plainly that the
  recovery path specifically remains unverified until a signature (D1) lands.

### Item 2
- The re-pull path `git pull --ff-only origin $YurunaBranch` (windows L554-555,
  ubuntu L499-500, macos L463-464) is in scope and the plan missed it: flipping
  the default from `main` to a tag changes/breaks it (`pull --ff-only origin
  <tag>` is not a branch pull). Specify the update-path behavior under a pin —
  re-checkout the pinned tag (detached HEAD) or skip-pull — so pinning does not
  silently leave the update path on `main` or fail ff-only against a tag.

### Item 3
- Downgrade the temp-file residual from "CLOSED" to **MITIGATED**: the
  non-elevated parent writes the temp `.ps1` in user-writable `%TEMP%` that the
  ELEVATED child later opens, so a same-user local attacker can still TOCTOU-race
  the GUID path between write and open. GUID-random name + `finally`-delete
  defeats predictable-path hijack but not the same-user race. Full fix: an ACL'd
  per-user dir the child re-validates, or pass the bytes via handle/stdin.
- Prefer the single `Invoke-RestMethod`-to-temp materialization as the PRIMARY
  path over `ScriptBlock.ToString()` capture. IRM-to-temp is byte-true to the
  canonical installer (which matters if Item 1's sha-verify is ever applied to
  the materialized file); `ScriptBlock.ToString()` round-trip fidelity under
  PS5.1 is the plan's one unverified assumption and may not reproduce the on-disk
  bytes even when it "works". Use ScriptBlock capture only as an optimization,
  never when the materialized file will be sha-verified.

### Item 4
- **Superseded by the operator decision** (verification declined; Item 4 is
  now a one-line transparency message). The sha-sidecar refinements that were
  here — `sshFetchAndExecute` parity, the `?sha=` query-string `&`-merge, the
  GitHub-`main` fallback sidecar, and the retry-library self-heal hop — no
  longer apply because no sha is computed or verified. The only remaining
  implementation note: confirm with a `waitPattern`/`failPattern` grep that
  nothing keys on the `fetch-and-execute:` echo before rewording L46 (already
  checked once: only `FETCHED AND EXECUTED:` / `NONZERO SCRIPT EXIT:` match).

### Item 7
- The `Save-ImageWithChecksum` `Throw` mode already exists, so the policy flip
  is per-caller (`-OnMismatch 'Throw'`) — audit ALL Get-Image callers, not just
  the AL2023 one, so the policy is uniform across distros/hosts.
- Keep the **missing-checksum** path warn-and-continue (D12) so a daily image
  whose `SHA256SUMS` has not yet published does not hard-block a dev cycle; only
  a present-and-mismatched hash aborts.
- The Ubuntu `SHA256SUMS` GPG verify and the `Fido.ps1` commit-pin both
  introduce a pinned upstream value — re-verify the Ubuntu archive key
  fingerprint and the Fido commit SHA against the live sources at implementation
  time (same standing rule as the Item 5 fingerprints; never hardcode from this
  document).

### Item 5
- Tighten the Microsoft key version boundary (the fingerprint VALUES are
  correct): `microsoft-2025.asc` (AA86...) covers repos created AFTER April 2025
  = Ubuntu **25.10+** (not "26.04+"); legacy `microsoft.asc` (BC52...) covers
  before May 2025 = Ubuntu 24.04 and earlier.
- The proposed `VERSION_ID` dual-key guard is DEAD CODE for this installer:
  `ubuntu.kvm.sh` preflight (L60) hard-requires Ubuntu 26.04+, so the legacy
  branch can never run. Switch UNCONDITIONALLY to `microsoft-2025.asc` + the
  AA86... pin and drop the dual-key branching. (The NO_PUBKEY latent bug is real:
  L337 builds the 26.04 prod repo signed by the 2025 key while L332 fetches the
  legacy `microsoft.asc`.)
- PowerShell `hashes.sha256` verify: `sha256sum -c hashes.sha256` over the full
  file FAILS on the absent sibling artifacts (musl/osx/arm/.deb) — grep the
  single pinned-version x64 filename line out first, then `-c`, so the control
  does not always-fail.
- The GPG fingerprint match must target the PRIMARY-key fpr (the `fpr:`
  colon-record following a `pub:` record, NOT a `sub:` record), compared as full
  40-hex exact equality (space-stripped), not `grep`-contains — a naive grep can
  match a subkey fingerprint and pass on the wrong anchor. For the GitHub
  allow-set (D6), require the NEW primary fpr present among the pub-anchored fprs.

### Add to "values to confirm"
- Re-verify all four GPG fingerprints against the LIVE upstream keys at
  implementation time. They were confirmed during this review against MS Learn
  (`/linux/packages`) and cli/cli #13118, but the standing rule is to re-verify
  and never hardcode from this document or the review.
- Confirm a `<file>.sha256` sidecar under `/yuruna-repo/` passes the status
  server's unified deny-list (`Start-StatusService.ps1` L2068+) before relying on
  the sidecar-default design (Item 4, D-option-b).

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.03

Back to [Yuruna](../README.md)
