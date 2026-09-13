<a id="42c8b468-0001"></a>

# Accessibility

Yuruna targets **WCAG 2.2 Level A and AA** on every web surface it serves, and
applies the same intent -- do not make the reader depend on sight, on a mouse,
or on holding still -- to the surfaces WCAG does not reach, such as the
terminal.

This document states the target, names what is deliberately outside it, gives
operators a keyboard reference, and tells contributors which gates to run.

<a id="42c8b468-0002"></a>

## Surfaces in scope

| Surface | Where it lives |
|---|---|
| pool-control service UI (7 pages) | [`test/extension/pool-control-service/.../web/`](../test/extension/pool-control-service/server/internal/httpsrv/web/) |
| download-agent service UI (2 pages) | [`test/extension/download-agent-service/.../web/`](../test/extension/download-agent-service/server/internal/httpsrv/web/) |
| stash service UI | [`test/extension/stash-service/.../web/`](../test/extension/stash-service/server/internal/httpsrv/web/) |
| caching-proxy-service UI | [`test/extension/caching-proxy-service/ui.go`](../test/extension/caching-proxy-service/ui.go) |
| caching-proxy-parser service UI | [`test/extension/caching-proxy-parser-service/parse.go`](../test/extension/caching-proxy-parser-service/parse.go) |
| status pages (5) | [`test/status/`](../test/status/) |
| Provisioned Grafana dashboards (3) | [`host/vmconfig/caching-proxy-service.base.user-data`](../host/vmconfig/caching-proxy-service.base.user-data) |
| Per-cycle HTML transcript | [`test/modules/Test.Log.psm1`](../test/modules/Test.Log.psm1), [`automation/Yuruna.Log.psm1`](../automation/Yuruna.Log.psm1) |
| Log directory listings | [`test/service/Start-StatusService.ps1`](../test/service/Start-StatusService.ps1) |
| Cycle-failure notification email | [`test/extension/notification/default.psm1`](../test/extension/notification/default.psm1) |
| CLI output | every entry point |

The last four are **generated** -- there is no `.html` file anywhere in the tree
to open. That is not a footnote: it is why they went unaudited for so long, and
why the browser gate materializes them rather than walking the tree for files.
See [Contributor rules](#contributor-rules).

<a id="42c8b468-0003"></a>

## Known exclusions, and why

An exclusion is a decision, not an oversight. Each of these is one.

<a id="42c8b468-0004"></a>

### Grafana's own application chrome

The project provisions dashboards; it does not ship Grafana. Panel content,
titles, descriptions, color choices and value mappings are ours and are in
scope. The navigation, time picker, settings drawers and login page are
upstream's.

<a id="42c8b468-0005"></a>

### The community Zot dashboard

A third-party dashboard is downloaded from grafana.com at provision time and
installed beside the project's own. It is unmodified upstream content, it has
had no accessibility assessment, and pinning a copy into this repository would
create a standing obligation to audit content the project does not author.

It is therefore **labeled rather than pinned**. The step that installs it tags
it `community`, and the brand-stamping timer reads that tag and marks the board
as unmodified community content, so an operator can tell at a glance that it is
not one of ours and is not covered by this document. The tag is the only
reliable signal: the installer rewrites the board's uid into this project's
namespace to give it a stable identity, and Grafana names the file.

<a id="42c8b468-0006"></a>

### Canvas-rendered dashboard panels

Grafana renders timeseries panels to a `<canvas>`. There is no configuration
that makes canvas pixels readable by a screen reader -- `showValue` paints text
*into* the bitmap, which helps a sighted reader distinguish series without
relying on hue and does nothing for assistive technology.

The text equivalent is the MCP surface, not the panel. Every number a dashboard
plots is also reachable as a tool call with declared units:

| Instead of reading | Ask |
|---|---|
| the pool board | `pool_status`, `pool_stats`, `pool_extension_hosts` |
| the incident and health tiles | `pool_incidents`, `pool_health` |
| the state timeline's click destinations | `pool_cycle_links` |
| the caching-proxy panels | `caching_proxy_status`, `caching_proxy_switches` |
| the "Recent 100 requests" log panel | `caching_proxy_recent_requests` |
| the stash and image tables | `stash_list`, `download_agent_images` |

**The canvas panels have a text equivalent for the present moment and none for
history.** That is a decision, not an omission. Two further tools -- a cycle
history and a proxy traffic series -- would complete the mapping, and neither
was built: no daemon here keeps a series. The aggregator holds pass/fail
counters and the current host view; the proxy daemon reads Squid's counters as
of the call. The timelines are drawn by Prometheus scraping over time, so either
tool would mean a daemon querying Prometheus -- a new dependency, and a new
failure mode for a read that today cannot fail. The trade was taken knowingly:
an agent can answer "what is happening" and "where do I open it", but not "what
happened at 3am" without going to Prometheus or Grafana directly.

One keyboard defect belongs here too. The pool state-timeline's plot wrapper
takes no focus, while the equivalent wrapper on a timeseries panel renders with
`tabindex="0"`. Same Grafana, different panel type: that element is Grafana's
own DOM and no dashboard JSON can set an attribute on it, so it falls under the
application-chrome exclusion above rather than being fixable here.

<a id="42c8b468-0007"></a>

### Operator-uploaded media in the stash viewer

The stash viewer renders files the operator uploads. Alternative text for
someone else's screenshot cannot be synthesized, and the viewer does not invent
one. The viewer chrome around the media -- controls, names, sizes, states -- is
in scope and is covered.

<a id="42c8b468-0008"></a>

### `project/poc/**` -- demonstration material

Two demo consoles, two slide decks and a React SPA. None is deployed; all of it
exists to demonstrate a workload end to end. It produced sixteen accessibility
findings, which are recorded rather than fixed. The four worth naming, because
an exclusion can be reversed and these are what a reversal would cost:

- `--amisad-terracotta` (`#e2725b`) is 3.09:1 on white and 2.84:1 on the paper
  background, used as link text, as accent text, and as a fill behind white
  button labels, across sixteen consuming sites in five files.
- Both slide decks size every piece of type in `vh` under
  `body { overflow: hidden }`. `vh` does not respond to text-only zoom, and page
  zoom shrinks the CSS viewport proportionally so the rendered size never
  changes; anything that did grow would be clipped with no scroll path.
- The swimlane chart emits roughly 690 empty `<button>` elements that are
  `aria-hidden="true"` and still in the tab order, ahead of every real control.
  This one is an outright ARIA violation rather than a judgment call, and it
  would be worth fixing even in demo material if a deck is ever driven from a
  keyboard on stage.
- Running a step rebuilds the panel with `innerHTML`, destroying the button just
  pressed, and nothing anywhere in the demo tree restores focus.

**What the exclusion costs.** The React SPA is the only place in the repository
where a standard accessibility linter installs cleanly -- it already carries a
`package.json` and a real toolchain, so `eslint-plugin-jsx-a11y` would be a
small addition. Excluding it means no off-the-shelf linter runs anywhere, and
the project's automated coverage is entirely the two gates named below. That is
defensible where `node` is absent on the lab hosts; it is not free.

<a id="42c8b468-0009"></a>

### Two findings assessed and dropped

- **Single-key shortcuts in the slide decks.** Bare `n`, `p` and `s` are bound
  on `window` with no off switch, no remap and no focus scoping -- a 2.1.4
  failure. Both decks are `project/poc/**`, excluded above.
- **A lab-token MCP tool.** Proposed so an agent could read the rotating code,
  then declined: the code tile is already plain DOM text that a screen reader
  announces, so the tool would have added a credential to an enumerable surface
  for no accessibility gain.

<a id="42c8b468-000a"></a>

## Keyboard reference for operators

Every control in the service UIs and status pages is reachable with `Tab` and
operable with `Enter` or `Space`. The specifics worth knowing:

| Action | Keys |
|---|---|
| Open the page menu | `Tab` to the menu button, then `Enter` or `Space` |
| Close the menu, a dialog, or the unlock prompt | `Escape` |
| Sort a table | `Tab` to the column header's button, then `Enter` or `Space` |
| Pause or resume auto-refresh | `Tab` to **Pause** in the footer, then `Enter` |
| Leave the config editor with unsaved edits | `Escape`, then confirm |

**Auto-refresh and the pause control.** Every page that refreshes itself carries
a **Pause** button in its footer, next to the countdown. The choice is stored in
`localStorage` and persists across pages and reloads, because a reader who needs
the page to hold still needs it to hold still on the next page too. While
paused, the countdown reads `paused` rather than continuing to tick.

The two Go-served proxy pages carry their own **Pause auto-refresh** button
above the content, with the same behavior scoped to that page.

**Focus is never stolen by a refresh.** When a background refresh would repaint
a region containing the focused element, the repaint is deferred until focus
leaves. A refresh cannot move the caret out from under a keyboard user.

**The Lab token.** Control actions require a six-character code read from the
Yuruna hosts dashboard. The code is minted every 60 seconds, but the gate
accepts the current code **and its two predecessors**, so a code you have just
read stays valid for roughly three minutes. The unlock prompt says so. This
matters most for anyone transcribing a code with a magnifier or a screen
reader, who is slower than the sighted operator a 60-second window was sized
for. The code's alphabet deliberately omits `i`, `l`, `o`, `0` and `1`.

**Results appear where you acted.** At 400% zoom, a control and the top of the
page are not on screen together. Every asynchronous action writes its outcome
into the row that was acted on, as well as into the page-level status region,
so the feedback is within one viewport-height of the control that caused it.

**Live regions.** Status messages are announced without moving focus. Errors
that need interrupting use `role="alert"`; routine progress uses
`role="status"`. A refresh timestamp is deliberately *not* a live region --
announcing a clock every few seconds is noise, not information.

<a id="42c8b468-000b"></a>

## The terminal

WCAG does not reach the terminal, and the terminal is this project's primary
interface.

**Rule banners.** Section rules in command output are eight characters, not
seventy. A screen reader reads a rule character by character before reaching the
text it frames.

**Progress regions.** Roughly seventy `Write-Progress` calls paint repainting
progress regions that a screen reader cannot follow. Suppress them with:

```powershell
$ProgressPreference = 'SilentlyContinue'
```

The harness is fully usable without them -- progress regions carry no
information that is not also written to the transcript. Set it in your profile,
or per-invocation. This is independent of the log level; see
[loglevels.md](loglevels.md) for what the level itself gates.

**The transcript is the accessible record.** Every cycle writes an HTML
transcript whose step boundaries are exposed as headings, so it can be navigated
by heading rather than scrolled. Severity is carried by a word (`ERROR`,
`WARNING`) before it is carried by a color.

<a id="42c8b468-000c"></a>

## Contributor rules

Two gates cover the shipped surfaces. Both run without network access and
neither needs `node`.

**[`tools/Invoke-A11yCheck.ps1`](../tools/Invoke-A11yCheck.ps1)** drives the
installed Chrome over the DevTools Protocol and measures what a browser actually
paints: composited text contrast, non-text contrast, reflow at 320 CSS px,
target size, focusable `aria-hidden`, dangling ARIA references, duplicate ids
and empty accessible names. Four of those have no answer in the source -- a
token table is a hypothesis about a color that inheritance, overlays and
ancestor opacity can still change.

```
pwsh tools/Invoke-A11yCheck.ps1
```

It exits `2` when it cannot run at all, which is never a pass. Headless Chrome
clamps its viewport to a 500 CSS px floor, so the 320 px measurement is taken
through `Emulation.setDeviceMetricsOverride` rather than `--window-size`.

**[`tools/Export-GeneratedPages.ps1`](../tools/Export-GeneratedPages.ps1)**
materializes the surfaces that have no file: the two Go raw-string pages, a
transcript written by the real log tee, a directory listing produced by the
status service's own builder, and the html part of the failure email. The gate
runs it automatically; run it directly when you want the pages on disk to open.

**[`test/modules/Test.ExtensionUiChrome.Tests.ps1`](../test/modules/Test.ExtensionUiChrome.Tests.ps1)**
holds the static assertions that run everywhere, with no browser: a document
language on every page, exactly one `<h1>`, no duplicate ids, no dangling ARIA
reference, no focusable `aria-hidden`, an accessible name on every control,
visible text contained in its accessible name, and a visible focus style.

When you add a page, add it to the gate's roots. When you add a surface that
generates HTML, add it to the exporter -- a gate that only walks the tree
inherits the blind spot that left five surfaces unaudited.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.09.13

Back to [Yuruna](../README.md)
