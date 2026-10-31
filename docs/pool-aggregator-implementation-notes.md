<a id="42c29d04-0001"></a>

# Pool aggregator implementation notes

These notes hold the longer rationale behind the pool aggregator
(`test/extension/pool-aggregator-service/`). The Go source keeps each
function's contract in its doc comment and points here for the why. The
service's behavior, flags and endpoints are in its
[README](../test/extension/pool-aggregator-service/README.md).

<a id="42c29d04-0002"></a>

## Distinct client addresses

Applies to: `distinctClientIPs` in `main.go`, whose set `RecordAddressScan` in
`internal/poolstate/addresses.go` joins with the host addresses

`distinctClientIPs` returns the different addresses seen in the squid log over
a window, and whether the whole window was covered. It is a count of addresses
observed, and deliberately nothing more: reading it as a statement about the
pool would need the DHCP lease period and scope size, which this service is not
given. The same count is unremarkable under a short lease and alarming under a
long one, so the reading is left to whoever can see those numbers.

It returns the set rather than its size so callers can union it with addresses
learned elsewhere (host records) without double-counting: a host that also talks
to the proxy appears in both, and adding two counts would invent addresses.

It is separate from `recentClientIPs` because the two want opposite tradeoffs.
Discovery wants the cheap fixed tail of a 35-minute window; this wants a day,
which does not fit in that tail, and reusing it would silently answer for
whatever fraction of the day fit in 512 KB -- a number that looks like a
measurement and is not one.

The second return is that honesty: false means the scan cannot vouch for the
whole window, so the count is a floor. There are two ways to be complete.
Reaching a line older than the cutoff proves the scan spans the window. Reading
the file from byte 0 without seeking proves there is nothing older to miss --
the ordinary case for a young lab or a freshly rotated log, which a stricter rule
would disclaim permanently. The residual caveat is rotation: entries rotated out
of `yuruna_access.log` are not consulted either way.

<a id="42c29d04-0003"></a>

## Host presence announces

Applies to: `handleHostAnnounce` in `main.go`

`POST /api/v1/host-announce` is the host-presence write surface: a host posts its
own `hostId` when its address changes, on service start, and on a periodic
beacon, so the pool view follows it across a DHCP renumber. It exists because
squid-log discovery is pull-only and lags exactly when it matters: a host enters
the log only when it or its guests pull through the proxy, so between cycles the
view ages out and the recorded address is the one the host has just left, and
guests resolving through the view get an answer that is confidently wrong.

It is distinct from `/announce`, which is area-scoped extension presence; this
route moves a host's address inside the host view that pool-status, `/go/*` and
the guest resolver all read. Its containment mirrors `/announce`, with one gate
stronger:

1. Self-identity bound: the address comes from the connection, never the body,
   so an announcer can only advertise itself.
2. Confirmed, not believed: `/announce` probes `/healthz`; this route probes
   `/runtime/status.json` and requires the `hostId` there to equal the claimed
   one. The claim is an identity, so identity is what gets checked, and a machine
   that cannot serve a host's `status.json` cannot rename itself into that host's
   place.
3. Bounded: the same body cap and `hostId` character set as `/announce`.
4. No bearer, for the reason `/announce` has none: requiring the internal
   authentication key would kill the beacon in exactly the labs that need it.
   The route only relocates an existing identity and confers no control.

<a id="42c29d04-0004"></a>

## Pool health gate

Applies to: `EvaluateGate` in `internal/incident/incident.go`, called with the
hosts' health by `evaluatePoolGate` in `main.go`

The gate is read-side only: no runner consumes it (consensus-gated control is
deferred). It drives alerting -- the host-side notifier reads
`yuruna_pool_alert_active` -- and dashboard de-noise, never a cycle, pause or
break.

A member is healthy when it is reachable, not in an open incident, and its
status is running, pass, idle or stopped, or either pending pause. An armed pause
flag does not stop a host until its boundary, so the host is still executing
normally and must not drag the pool's fraction down; a stopped runner is not
running cycles at all and is not counted against the pool either, the reading
idle has always had. The healthy fraction is healthy over known members.
Degraded latches when the fraction stays below the threshold for
`DegradedAfter` (wall clock) and clears at once on recovery. The alert fires
after `FailuresBeforeAlert` consecutive degraded polls and re-arms after
`SuccessesBeforeRearm` non-degraded polls: poll-count hysteresis is
deterministic and unit-testable.

The gauges (`_healthy_fraction`, `_degraded`, `_members_*`) are computed for
every pool with a member; `_alert_active` and the fired and re-armed events come
only from pools that authored a gating block, so an unconfigured pool is observed
but never paged. A firing latch is restored from the incident feed after a
restart, so a still-degraded pool does not page again.

<a id="42c29d04-0005"></a>

## Host status label

Applies to: `HostView.StatusLabel` and `HostView.StatusCode` in
`internal/poolstate/views.go`

`StatusLabel` folds reachability, whether the host's runner is alive,
`overallStatus` and the two pause flags into one value for the per-host table;
`StatusCode` is its numeric twin for the state-timeline panel, derived from the
same source so they never disagree: unreachable 0, running 1, pass 2, fail 3,
idle 4 (reachable with no or another cycle status), paused 5, pausing-cycle 6,
pausing-step 7, stopped 8, preflight-failed 9.

The ladder mirrors the host status page's banner state for state, so a host reads
the same on both surfaces. Two readings exist because `status.json` cannot supply
them, and a host that looks fine without them is the one an operator most needs
to see:

- Armed but not yet stopped. The host is still executing, but an operator has
  told it to stop; a plain "running" would hide a pending stop. Step pause
  resolves before cycle pause because the step boundary comes first.
- Runner stopped. `status.json` is a record of what ran, so it reads the same an
  hour after the runner went away -- a green "pass" for a host testing nothing,
  the false green the runner-status route exists to remove. It resolves above
  everything: the last result and any pause flag still armed describe a runner no
  longer there to honor them.

<a id="42c29d04-0006"></a>

## Extension host resolution

Applies to: `extensionCandidatesLocked`, `betterExtensionCandidate` and
`extensionSourceRank` in `main.go`

`extensionCandidatesLocked` is the one place the registration and announce
sources are merged. Every consumer -- the `/metrics` rows behind the dashboard's
Extension hosts table, `/api/v1/extension-hosts`, pool-status's `stashBaseUrl`
and the `/go/stash` redirect -- reads it, because four hand-written copies of a
precedence rule are how a correction lands in one and not the others. Entries
with no target are kept: a host that advertises an area with no address still
runs it, and the table shows an unlinked cell; callers that need an address
filter on the target. Entries whose address the pool cannot reach are kept but
suppressed -- target blanked, the refused address and reason carried -- so they
answer nothing and link nowhere while an operator can still see the claim a
silent drop would hide. A TTL-expired announce is skipped rather than trusted
until the next poll reaps it.

`betterExtensionCandidate` is deterministic all the way down -- usable, then
source, then recency, then `hostId` -- so two aggregators holding the same facts
answer identically and a consumer that asks again gets a stable address.
Usability comes first: an address this aggregator has reached beats one it has
not, whoever named it, since the source ranking chooses between addresses that
could both work and is no reason to prefer one that demonstrably does not.
Having an address at all is part of usability. A host that runs an area but
publishes no address for it is a normal, permanent state -- a service VM on a
hypervisor-private network is withheld from the pool on purpose -- and the
service's own announce, confirmed by this aggregator's probe, is meant to carry
it. Since the merge keeps one candidate per `(hostId, area)`, ranking a
presence-only entry above an address-bearing one would destroy that address.

`extensionSourceRank` orders the evidence behind an address, not its sender:

- 0, a live announce: the service posted to the aggregator and the target came
  from that request's source address, first-hand evidence that it answers there.
- 1, a registration: the owning host resolved an address and wrote it into a
  file the aggregator reads. Correct whenever nobody announces, but hearsay, and
  it lags: the runner writes `host.registration.json` before it refreshes the
  stash marker (the refresh needs `Get-VMIp`, wired later in startup), so
  `extensionTargets` carries the previous refresh's value, and a service VM
  rebuilt onto a new DHCP address is advertised at its predecessor's address for
  a whole cycle.
- 2, a rehydrated announce: restored from the Loki feed after a collector
  restart, a real but historical observation, worth less than the owning host's
  current word until a live beacon binds it again.

A live announce is bounded by its beacon period (minutes) and reaped at its TTL;
a lagging registration is bounded by the cycle, which can be hours.

<a id="42c29d04-0007"></a>

## Extension hosts in the metrics

Applies to: the `extRow` export in `handleMetricsWithArchiveProbe`, `main.go`

The Extension hosts rows list hosts actively running an extension function
(such as a stash service VM), learned from two sources in the pool table's
`hostId` namespace: each host's registration record (`activeExtensions`, read
through its status service) and the service's own presence announce, so a row
survives the owning host's status service being down. One row per
`(hostId, area)`; the dashboard maps the area to a friendly label.

The advertised service URL (`target`) rides as a label so the dashboard can
link the Extension cell directly; `baseUrl` (the host's status page) rides
beside it unlinked. A Grafana table built from an instant query turns labels into
string columns with no field labels, so a `${__field.labels.hostId}` redirect
resolves to an empty host; the working pattern, the same one the Pool hosts
table uses for `yuruna_pool_host_info`'s `baseUrl`, is a hidden URL column linked
through `${__data.fields.<col>}`. As with `host_info`, a changed address exports
a fresh label set and the stale one drops. `/go/stash` stays for consumers that
know only a `hostId`; `target` is empty until the host resolves the service VM's
address.

<a id="42c29d04-0008"></a>

## Resolving a clicked cycle

Applies to: `resolveClickedCycle` in `main.go`

A timeline click names a time, and the cycle active then is resolved from
sources in order of cost and of how much they survive:

1. The history backfill's cycle index: local disk, listing every cycle folder the
   host holds, rotated ones included, so it names the right cycle where the
   archive may hold only an older one. A folder it names is still served from the
   archive when committed there.
2. The archive on the pool share: local disk, no network hop, and still answering
   for a host that is off or reimaged -- the reason the durable tier exists. On a
   move-mode host it is the only place the folder still is.
3. The host's own `/log/` listing: authoritative for a cycle not yet archived
   (the running one, or a copy-mode backlog).
4. Loki's recorded `cycleFolderUrl`: the last resort when neither the share nor
   the host can be read.

A folder name encodes its start time and `hostId`, so the first three work for
any retained cycle and supply the cycle-number prefix a transition line cannot.

<a id="42c29d04-0009"></a>

## Prometheus host discovery

Applies to: `handlePrometheusTargets` in `main.go`

`/api/v1/prometheus-targets` serves the pool's supported hosts as a Prometheus
HTTP service-discovery document, so the collector scrapes machine metrics at the
addresses the pool is on now. Discovery belongs here rather than in a targets
file: this process already resolves `hostId` to the current address every poll
on a DHCP-served lab, and a second copy of that mapping goes stale while still
looking right. The labels are the ones the pool exposition carries (`pool`,
`hostId`, `hostIdDashed`, `hostType`), so a machine series joins a pool series on
`hostId` with no translation table and no host name. Only reachable hosts are
published: a host switched off leaves the document within one refresh instead of
failing in the scrape pool forever. The route is open, like
`/api/v1/pool-status`, whose addresses it reshapes; `/metrics` is the exposition
that carries a secret.

<a id="42c29d04-000a"></a>

## Defensive gitCommits decoding

Applies to: `GitCommitRefs` in `internal/hostpoll/hostpoll.go`

status.json's `gitCommits` is expected flat -- `[{sha,repoUrl},...]` -- but a
host whose writer hits the PowerShell array-double-wrap trap emits it nested one
level too deep (`[[{sha,repoUrl},...]]`). A strict decode of that nested shape
fails the entire status.json parse, which would silently drop the host from the
pool view over one optional display field. So the decoder tries the flat shape,
then the double-wrapped shape (unwrapped and flattened), and on any other shape
yields an empty list rather than an error: the Commit column blanks but the host
stays reachable. The host-side writer fix is the real correction.

<a id="42c29d04-000b"></a>

## The bounded host read

Applies to: `Get` in `internal/hostpoll/hostpoll.go`

Every host probe shares one bounded GET: one `ProbeTimeout`, one request, and a
size-capped read, so a host serving an unbounded body cannot exhaust the
collector.

It returns the HTTP status beside the body rather than deciding on it, because
the callers genuinely disagree and must keep disagreeing: runner-status,
current-action and control-status treat 404 as "this host's build predates the
route and has nothing to say", while status.json, VERSION and the registration
treat the same code as a real failure. Folding that choice into the shared read
would silently flip three of them.

The body is read only on 200: an error response's body is never inspected, so
reading it would be work done for nothing.

<a id="42c29d04-000c"></a>

## Runner stopped only on an explicit false

Applies to: `FetchRunnerStopped` in `internal/hostpoll/hostpoll.go`

`/control/runner-status` is open and read-only like control-status, so reading
it needs no credential. Only an explicit `running: false` counts as stopped,
matching the host status page's own banner test (`yuruna.common.js` `applyBanner`
reads `runnerStatus.running === false`). A route that is absent (404 on an older
framework build) or that answers without the field has nothing to say, and
inventing "stopped" out of silence would blank every host's real status the
moment the route moved or was renamed. A transport failure returns the error so
the caller can keep what it last knew.

<a id="42c29d04-000d"></a>

## Host framework version

Applies to: `FetchVersion` in `internal/hostpoll/hostpoll.go`

The version comes from `VERSION` at the repository root, served by the status
service at `/yuruna-repo/VERSION` -- the same source the host's own status pages
read for their header (their `getHostInfo()` fetches it in the browser, so the
version is not embedded in the HTML). It is one CalVer line, lighter than any
status page and readable without a JavaScript engine. Any failure returns an
error and the caller keeps the version it had, since the version is stable
across polls. The value is cut to its first line and 64 characters so a garbage
or oversized file cannot bloat the metric label.

<a id="42c29d04-000e"></a>

## Control status

Applies to: `FetchControlStatus` (result type `ControlStatus`) in `internal/hostpoll/hostpoll.go`

A host's answer to `GET /control/control-status` says whether it can be driven
remotely at all, and by which internal authentication key. `TokenTag` is
`base64(HMAC-SHA256(token, "yuruna-control|tag|v1"))` -- a non-secret name for
the token, never the token itself. `Present` is false when the route did not
answer usably, which is not the same as "no token": an older framework build has
no such route, and reporting that host as uncontrollable would be a guess.
`UtcNow` is the host's clock, so the caller can catch the skew that expires a
freshly minted proof. `Refresh` is the host's refresh capability summary,
normalized; nil when the answer did not carry one.

<a id="42c29d04-000f"></a>

## Cross-host incidents

Applies to: `EvaluateHosts` in `internal/incident/incident.go`

A pool-wide incident opens when at least `CrossN` distinct hosts each failed
within the (shorter) cross window with the same failure class: a systemic shared
cause (the proxy, the network, a bad commit hitting one class everywhere), not
unrelated single-host churn that merely coincides in time. For each class the
rule counts the distinct hosts with an in-window failure of that class; the
class with the most hosts (lexical tiebreak) is the candidate. The triggering
class is pinned at open, and resolve checks only that class's distinct-host
count against the floor `max(1, CrossN-1)` -- never re-pinning -- so the incident
cannot hop between classes and inflate its duration. A different class reaching
`CrossN` resolves the old incident and opens a new one (with a new id) in the
same pass.

<a id="42c29d04-0010"></a>

## Extension address health

Applies to: `ExtHealthView` in `internal/poolstate/views.go`,
`applyExtensionProbeLocked`, `refreshExtensionHealth` and
`applyExtensionHealthLocked` in `main.go`

The pool hands out an extension's address only after this aggregator has
reached it, and the verdict behind that rule belongs to an address, not to a
service: when the advertised address changes, the record starts over and the new
address has to earn its own confirmation. `Confirmed` separates two opposite
situations. An address never reached is refused outright, which is what keeps a
host-private address (a service VM on a hypervisor-private network) out of the
pool. An address reached and then lost is carried through `extensionHealthGrace`
of failures before it is refused, so a service restart or a dropped packet does
not empty the dashboard panel and stall every cycle that needs the service.

The verdict is re-derived on every poll, so the crossing of the grace would be
logged once per `-interval` for as long as the announce TTL holds the entry.
`RefusedLogged` keeps it to one line, and is reset with the rest of the record
when the address changes, so a failure of a later address is reported
again.

<a id="42c29d04-0011"></a>

## The pool view and its lock

Applies to: `State` and `View` in `internal/poolstate/poolstate.go`, and every
`st.Do` call in the service

The aggregator's view of the pool -- the hosts, the cycle counters and their
dedup set, the incident records and the health gate's latch, the self-announced
extensions and this aggregator's verdicts on their addresses, the lab connection
codes, the address counts, the identity aliases and the canary ring's facts --
sits behind one mutex, which `internal/poolstate` owns. Several steps change more
than one of those at once: a poll's merge updates hosts, cycle records, fail
windows and incidents together, a handover moves a host's records under its new
identity, and a forget clears one host from every map. One lock keeps each step
whole for every reader, which separate locks per map would not without an
ordering that every caller would have to follow.

The view is reached only inside `State.Do`, which holds the lock for the call;
code that needs the view while it already holds the lock takes the `*View`
as a parameter (the `...Locked` helpers, `poolFor`, the incident evaluation),
so the lock requirement is in the signature rather than in a comment. The lock
is not reentrant: a function that takes it must not be called from inside `Do`.

Nothing waits on the network inside `Do`. The poll captures what it will send to
Loki -- cycle transitions, presence beacons, incident events, event-tail targets
-- while it holds the lock and sends it after the lock is released; pool status
and the metrics are serialized to bytes inside `Do`, because the host records
they hold are mutated by the next poll, and written to the client after it. The
one disk write inside `Do` is the handover ledger, synced before the handover is
applied, so an acknowledged handover is always the persisted one.

Some groups are reached only through methods that keep their own invariants: the
cycle ledger (`ObserveCycle`, `CountTerminal`, `RevertCycle`, `ReapCycles`,
`ForgetCycles`), the address scan (`RecordAddressScan`, which takes the union with
the host addresses under the same lock) and the per-host address footprints, the
lab connection codes (`RotateLabCode`, `RedeemLabCode`, which compares every kept
code in constant time and bounds the throttle map), the identity aliases
(`CanonicalHostID`, `ReplacedBy`, `RetiredIDs`, `SetAliases`) and the time of the
last completed poll. The host records, the incident records and the health
gate's latch, the announces with their health verdicts and the canary ring's
facts are still fields of the view that the service's own code reads and changes
inside `Do`.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Back to [Yuruna](../README.md)
