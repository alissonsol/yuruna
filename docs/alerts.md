<a id="42ec79c4-0001"></a>

# Email for each failed test cycle

> **Who this is for.** An operator watching the [Yuruna hosts Grafana
> dashboard](pool-dashboard.md) who wants an email when a pool host finishes a
> test cycle with status `fail`. This guide uses Grafana's own alerting UI. It
> does not require editing the dashboard or a Yuruna sequence.

The dashboard is public to **anonymous Viewers**. Viewing it is not enough to
create an alert: an administrator must first configure Grafana's outgoing
email (SMTP), and you must sign in with permission to create alert rules,
contact points, and notification policies. If you only see the dashboard and
cannot edit anything under **Alerting**, ask the Grafana administrator for
those prerequisites. The current Yuruna proxy provisions no email contact
point or SMTP settings; a new rule alone cannot send mail.

The steps below use the **Yuruna hosts** dashboard on the caching-proxy VM.
For example, the current lab serves it at
`http://192.168.7.42:3000/d/yuruna-pool/yuruna-hosts`; use your lab's Grafana
address if it differs. Grafana 13.2.2 was checked when this guide was written;
menu names may move in later versions.

<a id="42ec79c4-0002"></a>

## 1. Get email delivery ready

Ask the Grafana server administrator to enable SMTP with a reachable mail
server, a sender address, and any required credentials or TLS settings. SMTP
is a **server setting**, not something a dashboard Viewer can turn on. The
administrator can follow [Grafana's SMTP settings](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/#smtp)
and [email alert guide](https://grafana.com/docs/grafana/latest/alerting/configure-notifications/manage-contact-points/integrations/configure-email/).
Do not put the mail password in an alert rule or dashboard.

Once SMTP is ready, sign in to Grafana with alert-editing access:

1. Open **Alerting** (in some versions, **Alerts & IRM > Alerting**) >
   **Notification configuration** > **Contact points**.
2. Select **New contact point**. Name it `Yuruna failed cycles`, choose the
   **Email** integration, and enter the recipient's address. Turn on
   **Disable resolved message** so a later resolution does not send a second
   email for the same failed cycle. Save.
3. Open that contact point and use **Test** > **Send test notification**.
   Confirm that the message arrives before creating the rule. A successful
   save without a received test message does not establish that SMTP works.

See [Grafana's contact-point guide](https://grafana.com/docs/grafana/latest/alerting/configure-notifications/manage-contact-points/)
for the current UI. Keep this contact point dedicated to failed cycles so
its resolved-message choice does not change other alerts.

<a id="42ec79c4-0003"></a>

## 2. Check the cycle data

The dashboard's **Failed cycles** tile reads Loki, but adds all failures in
the selected dashboard time range. Alerting on that total would merge hosts
and cycles. The query below instead preserves the labels `pool`, `hostId`,
and `cycleStartUtc`. Grafana makes a separate alert instance for each label
set, even when one host fails two cycles in quick succession.

Open **Explore**, choose the `yuruna-loki` data source, switch to a LogQL
code editor if necessary, and run this query as an **instant** query:

```logql
sum by (pool, hostId, cycleStartUtc) (
  count_over_time({src="cycle", pool=~".+"} | json | overallStatus="fail" [15m])
)
```

If no host failed in the last 15 minutes, an empty result is expected. To
inspect known older failures, temporarily change `[15m]` to `[2h]` in
Explore; restore `[15m]` when creating the alert. A result should have one
row per failed cycle, with value `1` in the usual case. `src="cycle"` selects
cycle-status changes rather than individual failed steps, and `pool=~".+"`
matches the dashboard's enrolled pool-host scope. A host that never reports
its result to the aggregator cannot appear in this query.

<a id="42ec79c4-0004"></a>

## 3. Route each cycle to its own email

Under **Alerting > Notification configuration > Notification policies**,
create a **child policy** rather than changing the default policy. Set both
matchers:

```text
alertname = Yuruna failed test cycle
alert_kind = yuruna_failed_cycle
```

Choose the **Yuruna failed cycles** email contact point. Override grouping
for this policy and include all four labels:

```text
alertname, pool, hostId, cycleStartUtc
```

Set **Group wait** to about `10s`, **Group interval** to `1m`, and
**Repeat interval** to `4h`, then save the policy. The repeat interval is
longer than the 15-minute query window, so it should not send reminders for
an ordinary failed cycle. Grouping by `cycleStartUtc` prevents a second
failed cycle on the same host from being folded into the first email. The
`alertname` matcher keeps Grafana's separate `DatasourceError` alerts out of
this failed-cycle route. The default policy currently has an empty receiver;
changing it instead would also affect unrelated rules, including the
existing Docker Hub pull-budget alert.

Grafana's [notification-grouping guide](https://grafana.com/docs/grafana/latest/alerting/fundamentals/notifications/group-alert-notifications/)
explains how group wait, group interval, and repeat interval affect when an
email is sent.

<a id="42ec79c4-0005"></a>

## 4. Create the alert rule

1. Go to **Alerting > Alert rules > New alert rule**. Name it
   `Yuruna failed test cycle` and choose a folder you can edit, such as
   **Yuruna**.
2. For query **A**, choose `yuruna-loki`, paste the **15-minute** LogQL
   query above, and set its query type to **Instant**. Do not paste the
   dashboard tile's `$__range` query: an alert has its own evaluation window,
   independent of the dashboard time picker.
3. Add a **Threshold** expression with condition **A is above 0**. Make it
   the alert condition. If your Grafana editor requires a Reduce expression,
   use **Last** on each series from A, then threshold that expression above
   zero. Do not use **Classic condition**: it discards the host and cycle
   labels needed for separate emails.
4. Create or select an evaluation group that runs **every 1 minute**. Set
   **Pending period** to **0** and **Keep firing for** to **0**. A completed
   failed cycle is already a final result, so waiting for several evaluations
   adds delay without filtering a transient condition.
5. Set **No Data** to **Normal**. No matching failure in the 15-minute window
   is the ordinary healthy case, not an outage alert. Leave query errors
   visible as **Error** and handle data-source health separately.
6. Add a rule label `alert_kind=yuruna_failed_cycle`. A useful **Summary**
   annotation is:

   ```text
   Yuruna host {{ $labels.hostId }} failed the cycle started {{ $labels.cycleStartUtc }}
   ```

7. Under notifications, choose **Use notification policy**. Preview the
   rule: each returned label set should be a separate firing instance.
   Save the rule.

The 15-minute lookback gives the aggregator's roughly 30-second poll and
Grafana's 1-minute evaluation time to see a completed cycle. It also keeps
an observed failure in the query long enough for notification delivery.
Grafana's [Loki alerting guide](https://grafana.com/docs/grafana/latest/datasources/loki/alerting/)
explains why an alert needs a numeric LogQL query and an instant value.

<a id="42ec79c4-0006"></a>

## 5. Verify and understand the limits

Check **Alerting > Alert rules** for an evaluation error. When a new failed
cycle is observed, its firing instance should show that cycle's `hostId` and
`cycleStartUtc`. Check **Alerting > History > Notifications** for a delivery
attempt and check the recipient's inbox. Grafana's [notification history](https://grafana.com/docs/grafana/latest/alerting/monitor-status/view-notification-history/)
distinguishes sent and failed deliveries. The earlier contact-point test
checks email transport without waiting for a real failed cycle.

This is an email for each **observed terminal `fail` cycle**, not for every
failed step inside a cycle. It covers pool hosts visible in the Yuruna hosts
dashboard. It cannot promise exactly-once delivery: if the aggregator, Loki,
Grafana, or SMTP is unavailable long enough for a failure to miss the
15-minute window, that email may never be sent. If Grafana's database is
discarded when its VM is rebuilt, a rule and contact point created only in
the UI must be recreated; durable rebuilds require an administrator to
provision them. None of these settings changes the Yuruna dashboard itself.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.09.26

Back to [Yuruna](../README.md)
