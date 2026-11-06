<a id="42c29d04-0001"></a>

# Pool aggregator implementation notes

These notes hold the longer rationale behind the pool aggregator
(`test/extension/pool-aggregator-service/`). The Go source keeps each
function's contract in its doc comment and points here for the why. The
service's behavior, flags and endpoints are in its
[README](../test/extension/pool-aggregator-service/README.md).

<a id="42c29d04-0002"></a>

## Distinct client addresses

Applies to: `DistinctClientIPs` in `internal/poll/poll.go`, whose set
`RecordAddressScan` in `internal/poolstate/addresses.go` joins with the host
addresses

`DistinctClientIPs` returns the different addresses seen in the squid log over
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

Applies to: `HandleHostAnnounce` in `internal/routes/ingest.go`

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
hosts' health by `Poller.EvaluatePoolGate` in `internal/poll/poll.go`

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

Applies to: `Candidates`, `Better`, `SourceRank` and `ResolveHosts` in
`internal/extensions/extensions.go`, and `HandleExtensionHosts` in
`internal/routes/routes.go`

`Candidates` is the one place the registration and announce
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

`Better` is deterministic all the way down -- usable, then
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

`SourceRank` orders the evidence behind an address, not its sender:

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

`ResolveHosts` is the read side of the presence data: the pool's best address
per area. A host that needs the stash service or the pool-control service but
does not run it has no other way to find it -- the address is not in its
configuration, and the service may live on another host entirely, on another
subnet -- so the alternative is a hard-coded literal that goes stale the first
time the service moves. Knowing the caching proxy's address, which every host
already needs, becomes enough to find every other service the pool offers. An
area is an address question, so a candidate whose target yields no host is
dropped there: presence without an address answers nothing.

`/api/v1/extension-hosts` serves that answer. With `?area=<slug>` it returns one
area, and 404 when the pool knows no live host for it: a consumer must be able
to tell "not there" from "here it is", because falling back to a guess is what
the hard-coded literal already did. Without `?area` it returns every area the
pool knows, so an operator sees the whole coordinate set in one call, beside the
`services` list of every `(hostId, area)` the pool holds, suppressed entries
included. The route is unauthenticated and read-only, like
`/api/v1/pool-status`: it discloses service addresses to a caller that is
already on the LAN those services listen on.

<a id="42c29d04-0007"></a>

## Extension hosts in the metrics

Applies to: the `extRow` export in `Render`, `internal/metrics/metrics.go`

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

The rows come from `extensions.Candidates`, the one merge every consumer
reads. When the two sources cover the same `(hostId, area)` and disagree, a
live announce wins: its target came off the source address of a request this
process received, while the registration is a value the owning host wrote into
a file a cycle ago. An announce-only row still resolves `baseUrl` from the view
when the host is at least known (a stub or an unreachable entry), and carries
none otherwise: a host can run an extension service without running cycles,
and such a host has no status page at all, so `/go/host` would answer "host not
known to the pool". That is why the Extension hosts table's Host ID cell never
offers that hop -- its menu names the row's id and opens the extension UI --
and the Pool hosts table, whose rows all have a status page, is where a host is
opened with the control token. `baseUrl` stays exported as the answer to "does
this extension host have a status page".

<a id="42c29d04-0008"></a>

## Resolving a clicked cycle

Applies to: `resolveClickedCycle`, `cycleFolderAt`, `ResolveFolderByListing`,
`PickFolderFromListing` and `HandleGoCycleShare` in
`internal/routes/deeplinks.go`

Every cycle deep link asks the same question: which host, and which cycle
folder, is under that point on the timeline? `resolveClickedCycle` answers it
for all of them. The state-timeline series carries no address -- it is keyed on
`hostId`, so a host's row does not split when its address changes -- so a link
cannot carry one either, and the host's current address is resolved when the
link is followed: from the live view, or from the last address the transition
feed recorded for a host the view no longer holds. That is what lets a link
survive an address change. When the clicked time falls inside the host's
current cycle, the folder comes from memory with no fetch.

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

A host's `/log/` index does not inline every retained cycle. A cycle older than
the retention window moves into a `history.<YYYY-MM-DD>/` bucket that the index
links but does not inline. Without following those links a click would fall
through to the oldest-retained fallback and silently land on a cycle nobody
asked for, and the failure under investigation would read as "the evidence was
pruned" while it is still on disk one directory away. A bucket is named for the
host-local day rotation ran, not for the day its cycles did, so the clicked time
cannot pick one. Rotation always moves the oldest cycles, so the buckets hold
consecutive stretches of history in date order, and read newest first, the
first one holding a cycle that started at or before the clicked time holds the
cycle active then. One click reads at most `maxHistoryBucketsScanned` buckets;
older clicks are answered from the backfill's cycle index, which has read every
bucket. When the clicked time predates every folder the listing holds, the
earliest one is returned, so the link still lands on a real cycle.

The resolver writes its own refusals -- 400 without a host id, 404 for a host
the pool does not know -- and treats a resolved host whose folder cannot be
found as an answer with no folder. That is still an answer for `/go/cycle`,
which then opens the host's status root. `/go/cycle-share` opens the host's own
share page for the cycle, which packs the folder into one archive and hands it
to the operator's mail client. It resolves through the same body, so "share
this" can never archive a different cycle than "open this" would show. The page
lives on the host rather than on the aggregator because the artifacts do: it is
same-origin with the files it archives, needs no CORS, and builds the archive
from local disk instead of crawling a directory listing over HTTP. With no
folder it answers 404 rather than falling back to the status root: a share page
that does not know which cycle it is sharing would only move the failure to a
button.

A host-state click on a failure older than the 20-attempt window uses the same
order: a cycle that began after the failure ended is the evidence that a later
attempt passed, so such a click does not open the failure's record.

<a id="42c29d04-0009"></a>

## Prometheus host discovery

Applies to: `HandlePrometheusTargets` in `internal/routes/routes.go`

`/api/v1/prometheus-targets` serves the pool's supported hosts as a Prometheus
HTTP service-discovery document, so the collector scrapes machine metrics at the
addresses the pool is on now. Discovery belongs here rather than in a targets
file: this process already resolves `hostId` to the current address every poll
on a DHCP-served lab, and a second copy of that mapping goes stale while still
looking right. The labels are the ones the pool exposition carries (`pool`,
`hostId`, `hostIdDashed`, `hostType`), so a machine series joins a pool series on
`hostId` with no translation table and no hostname. Only reachable hosts are
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

Applies to: `FetchControlStatus` (result type `ControlStatus`) in
`internal/hostpoll/hostpoll.go`, and the poll's reading of it in `Poller.Once`,
`ClassifyControl` and `mergeRefresh`, `internal/poll/poll.go`

A host's answer to `GET /control/control-status` says whether it can be driven
remotely at all, and by which internal authentication key. `TokenTag` is
`base64(HMAC-SHA256(token, "yuruna-control|tag|v1"))` -- a non-secret name for
the token, never the token itself. `Present` is false when the route did not
answer usably, which is not the same as "no token": an older framework build has
no such route, and reporting that host as uncontrollable would be a guess.
`UtcNow` is the host's clock, so the caller can catch the skew that expires a
freshly minted proof. `Refresh` is the host's refresh capability summary,
normalized; nil when the answer did not carry one.

The poll asks every host this question and keeps the two halves of the answer
on opposite rules. The control verdict survives a missed read: a transport
failure leaves the host's prior verdict in place, while a host that answers --
including an older build with no such route -- replaces it, so the column
reports `unknown` rather than inheriting a stale `ready` forever. The verdict is
classified in the probe goroutine against the poll's own clock, so the skew
reading is not skewed by how long the poll took. The refresh capability rides
the same answer with the opposite stickiness: a host that answered replaces it,
and a failed or oversize read demotes it to unavailable rather than keeping it,
because a last-known value must not stand in for a capability that authorizes a
disruptive action.

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
`RecordExtensionProbe` in `internal/poolstate/announces.go`, `TargetProblem`,
`Refresh`, `applyHealth` and the health constants in
`internal/extensions/extensions.go`, and `defaultAnnounceTtl` in `main.go`

The pool hands out an extension's address only after this aggregator has
reached it, and the verdict behind that rule belongs to an address, not to a
service: when the advertised address changes, the record starts over and the new
address has to earn its own confirmation. `Confirmed` separates two opposite
situations. An address never reached is refused outright, which is what keeps a
host-private address (a service VM on a hypervisor-private network) out of the
pool. An address reached and then lost is carried through `HealthGrace`
of failures before it is refused, so a service restart or a dropped packet does
not empty the dashboard panel and stall every cycle that needs the service.

The rule is the same for both sources and has no exceptions. `TargetProblem` is
its cheap half: it refuses on sight the values that are wrong on their face --
anything that is not an http(s) URL, and any address no other machine could
route to. A host that resolved 127.0.0.1 for its service is advertising, to
every consumer, that consumer's own machine. A name is not judged there, since
only the probe can say whether it resolves to something the pool can reach.
Every other address waits for its first successful probe, which lands within
one poll of the address being learned, or at once for an announce, because the
announce handler confirms a newly announced address before it answers.

`Refresh` re-confirms every advertised address once per poll. It snapshots the
address list under the lock, runs the probes unlocked and concurrently (at most
`MaxProbe` at a time), because a black-holed address costs a whole probe
timeout, and applies the verdicts under the lock again. It removes neither
source. Suppression is what stops an unreachable address being handed out, and
it applies to both: a registration-sourced address is re-asserted by its owning
host on every poll, so removing it would achieve nothing, and an
announce-sourced one belongs to a service that is most likely still up at an
address it has yet to re-announce. Removal is left to the announce TTL, a
goodbye, or the owning host retracting its marker, which `Stop-StashServiceVM`
does.

A refused entry survives the refusal, suppressed rather than removed. A service
whose address died is nearly always a service that renumbered, and it
re-announces from its new address within a beacon period; deleting the entry in
the meantime would leave the area with no record at all, so an operator asking
why a cycle cannot find the stash would see "this pool has no stash" instead of
"the stash is advertised at X and X does not answer". Suppressed, the entry
answers nothing and links nowhere, while `yuruna_pool_extension_unreachable`
and the services list keep naming the refused address for as long as the
announce TTL carries it. That is why a beacon period must stay shorter than the
grace: recovery slower than refusal opens a window in which the pool holds
neither the old address nor the new one (see the presence-interval constant
each extension service defines).

The same reasoning sizes the announce TTL (`-announce-ttl`, 45 minutes by
default) as a reaping horizon many beacon periods long rather than a tight
multiple of one. Refusal, not reaping, stops an unreachable address being
handed out; the row that outlives the failure is what still names the address
that stopped answering, and reaping it promptly would replace "advertised at X,
which does not answer" with silence.

The health path, the grace and the probe bound are code-only knobs by design:
where a lab's services answer is not an operator preference, and a per-pool
override would let one host's misconfiguration be configured away instead of
fixed.

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
as a parameter (`handoverHostLocked`, the extension merge, `poolFor`, the
incident evaluation), so the lock requirement is in the signature rather than in
a comment. The lock is not reentrant: a function that takes it must not be
called from inside `Do`.

Nothing waits on the network inside `Do`. The poll captures what it will send to
Loki -- cycle transitions, presence beacons, incident events, event-tail targets
-- while it holds the lock and sends it after the lock is released; pool status
and the metrics are serialized to bytes inside `Do`, because the host records
they hold are mutated by the next poll, and written to the client after it. The
one disk write inside `Do` is the handover ledger, synced before the handover is
applied, so an acknowledged handover is always the persisted one.

The extracted state methods keep the invariants of their operations. The
cycle ledger (`ObserveCycle`, `CountTerminal`, `RevertCycle`, `ReapCycles`,
`ForgetCycles`), the address scan (`RecordAddressScan`, which takes the union with
the host addresses under the same lock) and the per-host address footprints, the
lab connection codes (`RotateLabCode`, `RedeemLabCode`, which compares every kept
code in constant time and bounds the throttle map), the identity aliases
(`CanonicalHostID`, `ReplacedBy`, `RetiredIDs`, `SetAliases`) and the time of the
last completed poll are reached only that way. The host records, the incident
records and the health gate's latch, the announces with their health verdicts
and the canary ring's facts are read through the view's exported fields.
Methods own host-map membership and the incident, announce and ring operations:
a retired identity never regains a row
(`EnsureHost`, `SeedHostStub`, `RelocateHost`), a host leaves with the state that
belongs to it (`DropHost`, `ForgetHost`, `RetireHost`), a fail window stays in
time order (`RecordFail`), a window is never pruned without its incident
re-judged (`EvaluateIncidents`, `EvaluateGate`, `SetGating`, `RestoreIncident`,
`RestorePoolIncident`, `RestoreAlert`), an announce is removed only by its own
source and a verdict belongs to one address (`RecordAnnounce`, `Goodbye`,
`RestoreAnnounce`, `ReapAnnounces`, `RecordExtensionProbe`,
`PruneExtensionVerdicts`), and the ring facts stay within their bounds
(`RecordRingCycles`, `SetRingFacts`). The poll in `internal/poll` still writes
individual host fields directly under `Do`, and the extension health check in
`internal/extensions` sets the refusal-log latch the same way; neither goes
through a `View` method. The Prometheus exposition reads the view
from `internal/metrics`, inside the same `Do`.

<a id="42c29d04-0012"></a>

## Dashed host ids

Applies to: `DashedHostID` and `NormalizeHostID` in `internal/poolstate/hosts.go`,
the `hostIdDashed` label in `internal/metrics/metrics.go`

A hostId has two spellings: the undashed 32-hex form the view keys hosts on,
and the GUID-formatted rendering (8-4-4-4-12) every operator-facing surface
shows a full id in, because 32 undifferentiated hex characters cannot be
checked by eye against another screen or pasted into a command. `DashedHostID`
renders one and `NormalizeHostID` folds the other back, so a `/go/*` link built
from a rendered value resolves either way.

The dashed form rides as a separate `hostIdDashed` label beside `hostId` rather
than replacing it: `hostId` is the join key the dashboard's Loki frames and
every deep link are keyed on, and re-spelling it would fork those series and
break the join. It is the same kind of precomputed display value as `goPath`,
`commitUrl` and `cycleFolderUrl`: a Grafana data link interpolates a field's
displayed value, so a panel that shows the short id cannot recover the full one
from the cell it is showing. An id that is not 32 hex passes through untouched,
since an announce may carry any opaque identifier and hostIds are opaque by
contract.

<a id="42c29d04-0013"></a>

## Seeding a host from Loki

Applies to: `SeedHostStub` and `RelocateHost` in `internal/poolstate/hosts.go`,
`SeedHostStub` and the `Cycles`, `Presence` and `ApplyPresenceLines` readers in
`internal/rehydrate/rehydrate.go`, `Sender.PushPresence` in
`internal/feed/feed.go`, and `HandleHostAnnounce` in
`internal/routes/ingest.go`

A collector restart wipes the volatile host view, and squid-log discovery only
finds a host that is generating fresh proxy traffic. A host that is up and
reachable but quiet -- a paused runner, or a stash-only host that runs no test
cycles -- would drop off the dashboard until it next pulled through the proxy.
The startup reads therefore seed an unreachable stub for every hostId whose
last-known address Loki recorded (the transition feed carries `baseUrl`, and the
presence feed exists for hosts that push no transition), so the first poll's
candidate set -- the squid-log addresses plus every in-view host's current
address -- probes it. The seed only makes the probe happen: the stub carries no
status or extensions, so the exposition emits no extension row or pass/fail for
it until a real probe confirms it.

The poll and the host-presence announce write the presence feed. In the poll,
`Sender.PushPresence` records a host's address under
`{pool,hostId,src=presence}` when the host is first discovered or its address
changes -- an on-change beacon, not a per-poll one, so a steady pool writes
nothing there; the announce writes the address it confirmed to the same stream.
The feed is what keeps a host that runs no test cycles, and so pushes no
`src=cycle` transition, discoverable across a restart, while it is up,
reachable and advertising its extension. A line carries only the `hostId`
and the base URL, so the feed stays hostname-free like the rest of the pool
view.

A stub never replaces an existing, possibly live, record; it refuses a retired
identity, which must never regain a row after a handover; and it is stamped as
seen at the time of the seed, so a transient first-probe miss does not evict it
before a full host TTL of retries. A malformed recorded address seeds nothing,
so a garbage line cannot become a probe candidate. The host-presence announce
uses the same path for a host the view does not hold, and moves a held record's
address in place.

<a id="42c29d04-0014"></a>

## The host_info series

Applies to: the `yuruna_pool_host_info` export in `internal/metrics/metrics.go`

`host_info` carries the pool table's label cells: name, type, framework version,
the commit and its deep-link URLs, the other deep-link URLs, the current cycle
and the derived status. The series churns whenever `cycleStartUtc`, the status
or the address changes, which is why status and cycle are not labels on the
timeline series.

The churn is also why the value is the host's last-seen time rather than a
constant. A replaced label set does not leave the instant query at once: it
keeps its final sample and stays inside the staleness window a table reads, so
for about five minutes both the old and the new series answer and the host
occupies two rows. Exporting last-seen makes the two comparable, so a reader can
take the newest with `topk(1, ...) by (hostId)`, which is what the Pool hosts
panel does. A constant cannot be ranked, ties resolve arbitrarily, and the panel
would be as likely to show the stale row as the current one.

The labels stay hostname-free, since the pool view is. `cycleFolderUrl` stays
because the table's cycle-folder deep link needs it, and the folder name is the
opaque hostId, so the value is hostname-free too (a legacy folder named before
the host adopted hostId naming still embeds the hostname until that host's next
cycle renames it). `commit`, `commitUrl` and `projectCommitUrl` are a commit id
and repository URLs. `control` is the state name only (ready, none, mismatch,
skew or unknown): the token tag it was derived from is compared inside the
process and never exported, because `/metrics` is served without a credential,
to loopback only. `hostIdDashed` is the same id rendered 8-4-4-4-12 (see
*Dashed host ids*).

<a id="42c29d04-0015"></a>

## Address footprint gauges

Applies to: the `yuruna_pool_host_address_*` and `yuruna_pool_address_*`
exports in `internal/metrics/metrics.go`

The address footprint says how fast the lab is spending the LAN's DHCP pool and
whether each host's identity is pinned. It is exported as numbers rather than
left to the log because exhaustion is a threshold event -- everything works
until nothing does -- so the only useful time to read it is while the pool still
has room, which means it has to be graphable.

The value -1 is preserved rather than folded to 0 on both the changes and the
distinct-addresses gauges. Zero changes is a meaningful answer (this host is
bounded), so a host nothing is watching must not be able to report it. The
verdict rides as a label rather than an encoded number: its four values name
four different faults, and an operator reading a panel should not have to hold
a code table to tell `renewal-churn` from `stable`. The lab-wide total is summed
over the hosts that have a reading, since a host with none is unmeasured and a
zero for it would understate the total in the one direction that matters; the
proxy's own client count (`yuruna_pool_lab_addresses_in_use`) is the figure that
predicts exhaustion, because every guest reaches the internet through the proxy.

<a id="42c29d04-0016"></a>

## The collector's HTTP client

Applies to: `NewInternalHTTPClient` and `NewPollHTTPClient` in
`internal/hostpoll/hostpoll.go`

Every request the aggregator makes goes to a machine on the LAN or to loopback:
a host's status service at `http://<lan-ip>:8080`, and Loki's push and query
endpoints on 127.0.0.1. Its client therefore never uses a proxy. The process
runs on the caching-proxy host itself, whose environment may export a
system-wide `http_proxy`; `http.DefaultTransport` reads that through
`ProxyFromEnvironment` and would route these LAN and loopback requests through
squid, and a host squid is not actively serving at that moment would then read
back as unreachable even though its port 8080 answers a direct request.
`Proxy: nil` pins direct connections.

The client also keeps no connection between requests. A pooled connection can
go stale between polls without anything noticing, and the next request on it
fails a live host's probe; `DisableKeepAlives` makes each request a fresh
connection. A poll asks each host several questions in a row, so it runs on
`NewPollHTTPClient` instead, which keeps a host's connection for the length of
one poll and closes it when the poll ends: no pooled connection lives on into
the next poll.

<a id="42c29d04-0017"></a>

## Host registration reads

Applies to: `FetchRegistration` in `internal/poll/poll.go`, over
`FetchRegistration` in `internal/hostpoll/hostpoll.go`

A host's pool, the pool's gating policy and the extension services the host
runs come from its registration record, `/runtime/host.registration.json`,
which the poll reads beside every status probe. The runner derives the pool and
its gating from `pools.yml`, the single source of truth, and the host
advertises `extensionTargets` for the service it runs, such as the stash
service VM's UI base URL.

A failed read is not a change of membership. On a transient miss the poll keeps
the host's prior pool and gating, and it falls back to the `-pool` flag only
for a host whose pool it has never learned. An empty `poolId` is different: it
is a successful read of an unpooled host, not an error. A pool that authored no
gating block gets none, so it is observed through the gauges but never paged; a
partial block is completed field by field with the schema defaults, and a value
outside its range keeps the default.

<a id="42c29d04-0018"></a>

## The event tail

Applies to: `Poller.TailEvents` in `internal/poll/events.go`, and
`Sender.PushEvents` and `RedactEventLine` in `internal/feed/feed.go`

The poll forwards each host's current-cycle event file -- `cycle.events.ndjson`
in the cycle's results folder -- to Loki under `{pool,hostId,src=event}`. It is
the incident drill-down feed: `step_failure`, `step_end` and the typed
sub-events become queryable across hosts.

Each Loki entry is stamped with the event's own `timestamp`, not the time it was
forwarded, so forwarding the same line twice is harmless: Loki drops an exact
duplicate of a timestamp and line. That makes a collector restart that sends
the in-flight cycle again idempotent, and it lets the copy a runner pushes to
`/ingest` overlap the copy the poll pulls later (*Pushed events*). Within a
running collector, a per-host byte cursor keeps what was shipped from being
sent again. It resets when the cycle changes, because a new cycle is a new
file, and it moves past a batch only once the batch's lines are held for Loki,
so a batch that could not be held is read and sent again by the next poll. Only
complete lines are shipped; a trailing partial line waits for the next poll.
Each line is scrubbed of its hostname-bearing fields before it leaves
(`RedactEventLine`).

The tail is best-effort and bounded. One read takes at most `MaxEventFetch`
bytes and `MaxEventPush` lines; a host that ignores the range request has the
part already shipped discarded rather than held, so a bounded read still
reaches the events past it; and a failed read or push is left for the next
poll. It never blocks the poll.

<a id="42c29d04-0019"></a>

## Best-effort and durable Loki lines

Applies to: `Post`, `Sender.Queue`, `PushStream` and `PushAnnounce` in
`internal/feed/feed.go`, and the announce push in `HandleAnnounce`,
`internal/routes/ingest.go`

Most of what the collector writes to Loki states something that will be stated
again: the cycle transitions, the forwarded events, the incident and alert
lifecycle lines, the presence beacons and the lab-token audit. Those lines are
sent best-effort. `Sender.Queue` hands each one to the outbox when the
collector has one (*Loki delivery* in the service's README) and posts it
directly otherwise, and a caller that keeps its own record of what it sent -- a
transition's seen state, an event file's cursor -- advances that record only
once the line is held. `Post`, the shared tail of every push, still reports
whether Loki accepted a line, for the callers whose own reply has to say
whether the line will survive a restart.

The extension announce is the line that cannot be lost. It is the only record
of the announce that outlives the process: the entry itself lives in memory,
and nothing but the announcer ever sends it again, so a dropped push is a
silently lost registration, recoverable only by the announcer's next beacon a
whole re-announce period later. Every accepted hello is pushed, not only a
change, so the freshest line's age is the entry's age and a restart restores
exactly the entries still inside the announce TTL; goodbyes are pushed too, so
the latest line decides the state after a restart. The line is streamed under
the collector's own pool label, the one the startup restore queries -- the same
coupling the presence feed has.

`HandleAnnounce` makes the push outcome its reply, because a 2xx is what stops
the announcer: its beacon retries a non-2xx on its catch-up cadence and sleeps
a full re-announce period after a 2xx. Answering 2xx for a line that never
reached Loki would trade a retry the announcer would have made within seconds
for an entry that exists only in this process's memory, and the window where
that matters is precisely a restart, which is also when an aggregator is most
likely to be restarted by whatever brought it up. The entry is kept either way:
it is live and serving now, and the retry is what makes it durable. The push
runs after the view's lock is released, so a slow Loki never stalls the state.
Where no Loki is configured there is nothing to lose: `PushStream` reports
success, and those pools still get a 2xx. The host-presence announce keeps the
same contract for the same reason.

<a id="42c29d04-001a"></a>

## Restoring state at startup

Applies to: `Reader.Cycles`, `Reader.Incidents` and `Reader.ApplyIncidentLines`
in `internal/rehydrate/rehydrate.go`

The pool view lives in memory, and Loki holds the durable record of what it
saw: one line per terminal cycle transition, and the incident lifecycle feed.
At startup the collector reads both back over the last `-rehydrate-window`
(seven days by default), so a restart resumes rather than starts over.

The cycle counters become a projection of Loki. `Cycles` replays the terminal
transition lines into the pass and fail counters, so from Prometheus's view a
counter resumes at its prior value with no reset, and both the table's raw
counts and the 24-hour `increase()` tile stay correct across a restart with no
dashboard change. The same lines restore the dedup set for cycles already
terminal, so a host still reporting a finished cycle is not pushed or counted
twice, and they seed the fail windows and each host's last-known address
(*Seeding a host from Loki*). On any Loki error the collector starts with empty
counts and rebuilds them as cycles complete.

Open incidents are not rebuilt from the fail windows. `Incidents` restores them
from the incident feed, the authoritative record, so each keeps its original id
and start time, and the eventual resolve line pairs with its open line and
reports the true duration. The latest lifecycle line per host decides, whatever
the current fail count: a latest open line restores the incident, so one still
open below the open threshold survives the restart, and a latest resolve leaves
the host out of incident. "Latest" is decided across streams by timestamp, not by
the order Loki lists the streams in: one host can own several incident streams
-- the history backfill writes each replayed incident to a stream of its own,
and a host that changed pools has one per pool -- and an old resolved incident
listed first must not hide a newer open one. The decision is separate from the
fetch, so it is tested without a live Loki.

<a id="42c29d04-001b"></a>

## Pool statistics

Applies to: `HandlePoolStats`, `countCyclesByHost` and `PoolStatsRanges` in
`internal/routes/stats.go`

`/api/v1/pool-stats` serves per-host terminal-cycle counts over a preset
window, and only what Loki can answer. Pool membership lives in the intent
store, which this service has never read and deliberately does not: its only
notion of a pool is the `poolId` a host advertises for itself. The pool-control
service owns the join -- it already reads `members[]` -- so the board can
render a card for a pool whose hosts are all silent ("0 reporting") instead of
that pool vanishing because no Loki stream mentioned it.

The count is lab-wide (`{pool=~".+"}`) and grouped by host, not by pool. The
`pool` stream label is stamped at push time and falls back to the literal
`default` for a host the aggregator has not yet identified, so summing by that
label would silently fold unpooled hosts into the target pool's numbers.
Per-host rows joined onto `pools.yml`'s `members[]`, the only authoritative
statement of who is in which pool, cannot do that. The counts are folded
through the identity alias ledger first, so a host that changed identity
reports all its cycles under its current id.

The window is one of a closed set, because the value is interpolated into
LogQL, and each must stay inside Loki's retention period: a longer one would
silently return a partial answer that reads as a real number. A Loki failure is
an error, not a zero, since the board would show zeros as "0 cycles" and an
operator would read "nothing ran" instead of "we could not tell". An answer is
cached for `poolStatsCacheTTL`, sized against the board's auto-refresh, so
several boards refreshing together cost one query. The route is read-only and
open, the same posture as `/api/v1/pool-status`.

<a id="42c29d04-001c"></a>

## Control proofs for extension services

Applies to: `HandleControlProof` in `internal/routes/labtoken.go` and
`HandleGoStash` in `internal/routes/deeplinks.go`

A host's status page gets a control proof in the fragment of the `/go/host`
redirect and checks it against the internal authentication key it holds. An
extension service's UI gets the same handoff from `/go/stash`: the redirect
carries a short-lived proof bound to the audience `svc-<area>`, so a service UI
reached from the dashboard can act on its gated routes without the operator
going back to read the rotating lab code. A fragment never reaches a server or
an access log, and with no key configured there is no fragment, so the UI
prompts for the Lab token. The redirect goes to the pool's answer for
that host's area -- the lookup behind pool-status's `stashBaseUrl` (*Extension
host resolution*), which hands out only an address this aggregator has reached
(*Extension address health*) -- and a host or target the pool does not know is
a 404.

An extension service VM is not given the internal authentication key -- nothing
writes that file into its seed -- so it holds nothing to check an arriving
proof against, and a service that cannot check one has no way to honor the
dashboard's "open this UI with actions unlocked" hop. It asks the aggregator
instead, at `POST /api/v1/control-proof`, exactly as it already asks
`/api/v1/lab-token` to judge a 6-character code: validation stays with the
daemon that owns the key, and no service keeps a copy to go stale.

The route is open, like the exchange beside it, and for a stronger reason: it
verifies and never mints. It discloses one bit about a string the caller
already holds, and a caller who could produce a proof that verifies there could
have used the proof directly. It answers 503 when this aggregator holds no key,
because "no token" is not "not valid".

<a id="42c29d04-001d"></a>

## The lab connection token

Applies to: `HandleLabToken`, `NewLabCode`, `RotateLabToken`, `sealLabToken`
and the lab constants in `internal/routes/labtoken.go`

Enrolling a host means giving it the pool's internal authentication key. The
lab connection token turns that into "read the 6-character code off the Yuruna
hosts dashboard and run `test/lab/Set-LabToken.ps1`" instead of opening an SSH
session into the proxy for the secret: `POST /api/v1/lab-token` exchanges a
current code for the key.

The route is open, because the code is the credential: whoever can view the
dashboard may enroll a host. The rest of its posture follows from that. A code
is checked in constant time against the retained codes -- the current one and
its recent predecessors, so a code read off a panel about to refresh still
redeems. Failed attempts are throttled per address (per /64 for IPv6). Every
attempt is audited to the log and to Loki with the caller's address, except a
repeat from an address already throttled, and never with the code. The route
answers 503 when rotation is off or no key is configured, mirroring `/ingest`.

The answer is sealed under the redeemed code, so the key never crosses the wire
in clear and only the redeemer can open it; the listener is plain HTTP whenever
the proxy has no TLS leaf. The seal is AES-256-GCM under a key derived with
PBKDF2 from the code and a fresh salt, in the envelope shape
`Protect-ConfigSyncCredential` uses (`v`, `salt`, `nonce`, `ciphertext`, `tag`,
all base64), and `Unprotect-LabTokenEnvelope` in the `Test.ConfigServiceSync`
module is the twin that opens it. Sealing is what authenticates the answer, not
only what hides it. The enrolling host cannot verify the aggregator's TLS leaf,
so without the binding anything on the path could answer the exchange and hand
the host a key of its own choosing -- which the host would then honor for
control proofs, handing that party the host. Sealed under the code, the answer
can come only from a party that knows the displayed code.

The code is read off a tile and typed by hand, so its alphabet leaves out i, l,
o, 0 and 1, the characters most often read wrong -- which costs everyone, and
costs most whoever reads them through a magnifier or hears them spelled out.
That leaves 31 characters and 31^6 = 887,503,681 codes, against a per-address
throttle of 10 attempts per 10 minutes: the guessing math is untouched and the
reading is materially easier. The draw is unbiased: the rejection threshold is
derived from the alphabet's length, because a constant multiple is right for
one alphabet size only and silently skews the distribution for any other.

<a id="42c29d04-001e"></a>

## The archive route

Applies to: `HandleArchive`, `HostIDRe`, `ArchiveCycleRe` and
`ArchiveCommitted` in `internal/routes/deeplinks.go`

`GET /archive/<hostId>/test-cycles/<cycle>/...` serves archived cycle results
straight off the pool share, so a cycle committed there keeps answering when
its host is switched off or reimaged -- the durable tier's whole promise. The
route is read-only and answers only GET and HEAD.

The shape check is the authorization. `HostIDRe` and `ArchiveCycleRe` validate
a request before any filesystem call, exactly as the host's own
`/archive/<cycle>.zip` route does: nothing that is not a 32-hex host id
followed by the literal `test-cycles` and a well-formed cycle leaf reaches the
disk. The cycle grammar is deliberately stricter than the host-side ones. A
leaf on the share is always the stable stripped identity, because the archiver
keys its map, its destination and its ledger on `Get-PoolStorageCycleIdentity`,
so an `.incomplete` or `.aborted.<UTC>` suffix in a URL cannot name anything
that exists there; it can only be a probe, and refusing it costs nothing.
Behind the check, `os.Root` contains every open, so no `..`, symlink or case
trick can escape the archive root: the kernel enforces it rather than a string
comparison.

The root is opened again for every request rather than once at startup. The
proxy's share mount arrives asynchronously after boot -- the
configuration-service fetch owns it, and the unit is ordered on nothing that
waits for it -- so a root captured at startup would pin the route to whatever
the mount looked like before it existed, and the route would answer 404 until
someone restarted the service. A mount that is away is reported as such rather
than as a 500 that reads like a bug in the service. A dashboard click is sent
to the archive only once the folder carries the archiver's `.yuruna-complete`
sentinel (`ArchiveCommitted`), so it never lands inside a copy that is still
running.

<a id="42c29d04-001f"></a>

## Metrics stay on this machine

Applies to: `HandleMetrics` in `internal/routes/routes.go`

The Prometheus exposition includes `yuruna_pool_lab_token{token="..."}`, the
current enrollment credential in plain text, so serving it to the LAN would
hand the credential to anyone who asked. Prometheus scrapes this daemon at
`localhost:9400` (the scrape configuration in the proxy VM's seed), so a
loopback-only route is the whole of what the collector needs and none of what a
LAN client would get. A remote caller is refused with 403 rather than served a
redacted body: a partial exposition would look like a working scrape and hide
the refusal from whoever set it up.

<a id="42c29d04-0020"></a>

## Incidents, health and cycle links as JSON

Applies to: `HandlePoolIncidents` and `HandlePoolHealth` in
`internal/routes/routes.go`, and `HandleCycleLinks` in
`internal/routes/deeplinks.go`

The incident state and the pool health gate are also Prometheus exposition: a
dashboard can show them and an operator can read them off a panel, but a caller
cannot ask for them there. `/api/v1/pool-incidents` and `/api/v1/pool-health`
answer them as JSON for the MCP surface, and they do it as routes rather than
as tools reading state directly, so the tool and the metric are one body
produced once -- the rule every `mcp.go` in this tree states. Both are
read-only and ungated, matching `/api/v1/pool-status`: they are the same view
the dashboard already renders to anyone who can load it.

`/api/v1/cycle-links` is the text equivalent of the state-timeline panel. The
timeline is a canvas: its blocks, its colors and its context menu reach a
screen reader as nothing at all, and two of its actions -- open the cycle
results, share them -- exist nowhere else in the UI. The route returns the
three destinations a click offers, resolved through the same body the
redirects use (*Resolving a clicked cycle*), so a link handed out there cannot
point somewhere a click would not go.

Its `hostStatusUrl` deliberately carries no control proof, unlike `/go/host`.
That fragment is a short-lived credential minted for a browser navigation;
putting one in a JSON body would move a credential onto an enumerable read
surface to no benefit, since a caller reading the answer cannot act on the
host's UI anyway.

<a id="42c29d04-0021"></a>

## Pushed events

Applies to: `HandleIngest` in `internal/routes/ingest.go`

`POST /ingest` is the push surface: a runner-side forwarder posts its cycle's
NDJSON event lines so they reach Loki without waiting for the next poll, which
closes the gap between a cycle's last events and the poll that would pull them.
It supplements the pull and never replaces it. A pushed line and the copy
pulled later carry the event's own timestamp, so Loki drops the exact duplicate
and the overlap is harmless (*The event tail*).

The route is an inbound write, contained five ways:

1. It is gated on a configured internal authentication key. With none, the
   route is disabled (503), never exposed unauthenticated.
2. The bearer is checked in constant time before the body is read.
3. Identity binding: the `{pool,hostId}` labels come from resolving the
   sender's source address against the pull-discovered view, not from the
   body. A key holder can push only as the host currently at its own address,
   so a compromised member cannot forge another host's telemetry, and an
   undiscovered address is refused: a push never bypasses discovery. A body
   `hostId` must be one of the hosts at that address, a batch may not mix
   `hostId`s, and a batch with none binds only when exactly one host sits at
   the address.
4. Each line goes through the same hostname scrub as the pull path.
5. The body size and the line count mirror the pull side's caps, and the body
   is scanned incrementally, so the line cap fires before work is spent past
   it.

The route is telemetry only: it ships to Loki and reaches no control plane. A
202 means the lines are held, not merely received, because the forwarder
advances its own cursor on it; a full outbox and a line the outbox could not
write are both 503, under different codes, so the forwarder and its log can
tell backpressure from a fault on the aggregator.

<a id="42c29d04-0022"></a>

## The guest address route

Applies to: `HandleHostAddress` in `internal/routes/ingest.go`

`GET /api/v1/host-address?hostId=<id>` is the guest resolver's route: where one
host is now. It is a narrow alternative to pool-status because a guest parses
it during bootstrap, before anything is installed -- no `jq`, no JSON library,
only `sed` over the body -- and a single flat object is something a
line-oriented parser can read with certainty where a whole pool view is not.
The answer is never cached: an address lookup is the one answer that must not
be, because the whole point is that it changes.

It is deliberately not `/go/host`, which answers the same question for a
browser. That route mints a short-lived control proof into its redirect, and a
guest holding a control proof for its own host is the capability the status
service's control-route authentication exists to deny. This route mints nothing
and redirects nowhere.

An unknown host is a 404 rather than an empty 200, so the guest can tell "the
pool does not know this host" from "the pool says it is nowhere"; only the
first is worth falling back to the older pool-status route for.

<a id="42c29d04-0023"></a>

## Reading the internal authentication key

Applies to: `readAuthTokenFile` in `main.go`, over `servicecfg.ReadAuthToken`
in the extension SDK

The internal authentication key is what this proxy mints control proofs with,
what gates `/ingest`, and what the lab-token exchange hands out. An empty read
leaves every one of those disabled rather than open.

Surrounding whitespace is trimmed, because the key reaches its file through
cloud-init, which is free to end it with a newline. The PowerShell side that
computes the matching control tag trims at its own read, and a key that
differed by one byte between the two would report the whole pool as
onsite-only.

The provisioned unit names the default path, and only that path licenses the
fallback to the file a proxy built under the older layout still carries, so
such a VM keeps minting proofs, serving `/ingest` and displaying a Lab token
until it is rebuilt; an operator who named another path meant that path. The
default and legacy paths are parameters rather than reads of the constants, so
a test can exercise the fallback without writing under `/etc`.

<a id="42c29d04-0024"></a>

## One port for TLS and plain HTTP

Applies to: the listener setup in `main` (`main.go`), and
`NewDualProtocolListener` in `internal/httpserve/httpserve.go`

With the TLS leaf present, port 9400 answers both protocols on the one port:
TLS for the clients that carry a credential -- the ingest forwarder's bearer,
`Set-LabToken`'s exchange and the Prometheus scrape -- and plain HTTP for the
browser-facing `/go/*` deep links. The deep-link hop only redirects the
operator's browser to a host's plain-HTTP status page, so TLS there would add a
proxy-CA interstitial -- operator browsers do not trust the proxy's CA -- while
protecting nothing the very next hop does not already carry in clear: the
minted control proof travels on to the host in a cleartext header either way.
TLS starts only when both the certificate and the key name readable, non-empty
files; otherwise the service serves plain HTTP alone, so a proxy provisioned
without the leaf still runs.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Back to [Yuruna](../README.md)
