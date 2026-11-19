# Additional demo scenarios

Two scenarios beyond the Toxiproxy database slowdown, for Dave to run. **Both
are written but neither has been deployed or rehearsed.**

Everything here is **inert by default**: `make start` does not activate either
scenario, and with no environment set the rendered config is byte-identical to
today's.

---

## Scenario A — a bad deployment of `payment` (2.0.3)

**Story.** Someone ships a payment release that prices each basket item with its
own query instead of one write per charge. Latency climbs, the database works
much harder, and the Service Catalogue shows a new version appearing right when
it started. Rolling back fixes it.

Deliberately **not a feature flag** — it has to look like a deployment.

### Controls

```bash
./demo.sh deploy-bad    # payment 2.0.3, N+1 on
./demo.sh rollback      # payment 2.0.2, N+1 off
```

Both redeploy `payment` only, with `--no-deps --force-recreate`, through the
same env-file and trim-overlay chain the Makefile uses.

### How it works

`PAYMENT_ITEM_LOOKUPS` (default `0`) switches on a per-item lookup loop in
`charge()` before the INSERT. At the default `BAD_ITEM_LOOKUPS=5`:

- 8–15 items per basket × 5 lookups each, plus 6 fixed lookups
- = **46–81 queries per charge**, against 1 today

Every query is a **primary-key hit on a 50-row table** (`services`,
`customers`), so each is sub-millisecond and the database is never at risk. The
damage comes from doing them sequentially.

`service.version` moves to `2.0.3` via a payment-specific
`OTEL_RESOURCE_ATTRIBUTES`. **`service.name` stays `payment`** — one service,
two versions, which is what makes the deployment visible in the Catalogue rather
than creating a second service.

### Revised sizing — baseline link latency plus a bigger N+1

**PLANNED, NOT APPLIED.** The code is written; nothing has been run, no toxic
has been touched and the collector is unchanged.

The original sizing added only ~50–90 ms per charge, which was too small to be
interesting. Two changes fix that.

**1. A permanent 4 ms baseline latency on the payment → MySQL link.**

A database at the other end of a real network is never 0 ms away. `demo.sh
baseline` and `reset` now **apply** a 4 ms ± 1 ms latency toxic
(`payment-mysql-baseline`) rather than removing all toxics. It is the normal
state, not a fault — and it is what makes the N+1 land in a believable range,
because an N+1 only hurts when each round trip costs something.

The injected slowdown (`payment-mysql-latency`) is a **separate** toxic layered
on top, so `slow-db` becomes 4 + 800 ms and `reset` returns to 4 ms rather than
to zero.

**2. `BAD_ITEM_LOOKUPS` 5 → 10**, and the per-item cap in `charge.js` raised
from 8 to 20 — at a cap of 8 the new value would have silently clamped and the
scenario would have been quietly wrong.

### Expected numbers

Per charge: `itemCount × perItem + 6 fixed + 1 INSERT`, with 8–15 items.

| | Queries/charge | At ~4.8 ms each |
|---|---:|---:|
| Minimum (8 items) | 87 | ~418 ms |
| Typical (11.5 items) | 122 | **~586 ms** |
| Maximum (15 items) | 157 | ~754 ms |

4.8 ms is the 4 ms toxic plus ~0.8 ms of real round trip, derived from the
measured 800 ms toxic producing an 878 ms charge — about one toxic application
per query.

That puts payment in the **500–800 ms** range asked for, with p50 near 590 ms.
Unlike the original sizing, this **does** cross the 500 ms payment latency rule,
so the bad deploy now trips an existing alert as well as the new
DB-calls-per-charge rule.

### Effect of the 4 ms baseline on everything else

| | Now | With 4 ms baseline |
|---|---:|---:|
| payment p50 / p95 | 6 / 10 ms | ~10 / ~14 ms |
| checkout p95 | 615 ms | ~619 ms |
| `slow-db` payment | ~888 ms | ~892 ms |

All well inside existing thresholds — payment's rule is 500 ms, checkout's
1000 ms. `quote` is unaffected: it connects to MySQL directly, not through the
proxy. `stock-reconciler` is likewise unaffected.

### What still needs checking when it is safe to run

- **The 4.8 ms per-query figure is inferred, not measured.** It comes from one
  data point at 800 ms. If the real per-query cost is 3 ms the typical charge is
  ~370 ms, below target; at 6 ms it is ~730 ms. Measure one `deploy-bad` and
  adjust `BAD_ITEM_LOOKUPS` — it is a single number.
- **`demo.sh` has only been syntax-checked**, not run, because a live test was
  in progress. `baseline`, `reset`, `status` and `deploy-bad` all need one pass.
- **`status` infers state from the toxic count** (0 = baseline missing, 1 =
  normal, 2+ = slowed) because `toxiproxy-cli` has no `toxic list` and the image
  has no shell to reach the HTTP API. It cannot tell you *which* toxics are
  present, only how many.
- **The baseline latency changes what "reset" means.** The Definition of Done
  says reset returns to baseline within 60 s; baseline is now 4 ms, not 0.

### Original sizing — what it would and would not trip



At ~4.4 orders/min this adds about **4.6 queries/sec**. Per charge, 63 sequential
round trips at roughly 0.8–1.2 ms each (PK lookup plus Docker network, plus the
Toxiproxy hop) works out at **roughly 50–90 ms added per charge**.

So payment goes from ~10 ms to **~60–100 ms**. That is a 6–10× regression and
unmissable in a trace — but it is **well under the 500 ms payment latency rule**,
and under the 1000 ms checkout rule too.

**This scenario will not fire the existing latency rules.** It is detected by
the new *"Payment is making far more database calls per charge"* rule, by the
query-count rule, and by eye in the Service Catalogue. If you want it to trip
latency as well, raise `BAD_ITEM_LOOKUPS` — but note you would need roughly 400+
queries per charge to cross 500 ms, which stops being a plausible N+1 and starts
being obviously absurd.

My recommendation is to leave it as is and let it be the scenario that shows
Coworker correlating a *deployment* with a *behaviour change*, rather than
another latency alert.

---

## Scenario B — stock reconciliation batch job

**Story.** A scheduled job reconciles stock against quotes. It is legitimate,
recurring, and heavy enough to be noticed — the kind of thing that makes an
on-call engineer ask "is this normal?".

### Controls

Behind the `scenarios` compose profile, so it never starts with `make start`:

```bash
docker compose --env-file .env --env-file .env.arm64 --env-file .env.override \
  -f docker-compose.yml -f docker-compose.trim.yml \
  --profile scenarios up -d stock-reconciler
```

| Variable | Default | Meaning |
|---|---|---|
| `RECONCILE_INTERVAL_SECONDS` | `5400` (90 min) | Gap between runs. Use `300` for rehearsal. |
| `RECONCILE_BATCHES` | `1500` | Query batches per run. |
| `RECONCILE_MAX_SECONDS` | `120` | Hard ceiling — the run aborts past this. |

### Log lines

```
2026-11-11T12:00:00Z [stock-reconciler] START run=20261111T120000Z batches=1500 max_seconds=120
2026-11-11T12:01:02Z [stock-reconciler] END run=20261111T120000Z queries=6000 elapsed=62s next_in=5400s
```

An aborted run logs `ABORT ... reason=time_ceiling` instead.

### Why it is safe

This is the opposite of `removeoldquotes.cfm`, deliberately:

- every statement is a **bounded aggregate over small tables** — no `CROSS
  JOIN`, no correlated subqueries, no `UUID()`/`RAND()` per row
- **read-only** — no INSERT, UPDATE or DELETE
- `SET SESSION max_execution_time=50` per statement, so no single query can hang
- a **hard wall-clock ceiling** aborts the run regardless
- nothing scales with the `quotes` table, so it cannot degrade as data grows

### Sizing

1500 batches × 4 queries = **6000 queries and ~345,000 rows read per run**, in
about 60 seconds.

The 1500 default matters. At the 120 I first wrote, a run finished in ~5 seconds
and **averaged away to nothing across a 5-minute rate window** — it would never
have tripped an alert. Sustaining the load for ~60s is what makes it detectable.

---

## Alert rules

In [`../alerts/scenario-rules.yaml`](../alerts/scenario-rules.yaml). Measured
baseline at 20 users, 45-second sample:

| | Baseline | With N+1 | With batch (5m avg) |
|---|---:|---:|---:|
| Queries/sec | 1.6 | ~6.2 | ~22 |
| Rows read/sec | 340 | ~345 | ~1,490 |

**The key design point:** a rows-read rule catches the batch job and is nearly
blind to the N+1, which adds ~5 rows/sec against a 340/sec baseline. **Query
count catches both.** If only one rule is wanted, make it query count.

That needs a one-line collector change, because `mysql.query.count` is opt-in:

Written as an applyable patch rather than edited into the live file:

```bash
git apply docs/patches/enable-mysql-query-count.diff
```

Verified with `git apply --check`. **Not applied** — it touches the live
collector config and needs a collector restart to take effect, and a slow-db
test was running.

As with the live rules, the exact metric names must be confirmed in OpsPilot's
metric browser before the rules are typed in. The last time I assumed a metric
name it was wrong.

---

## Estimated cost

Measured now: stack **22.1% of 1000%** (10 cores), MySQL 1.6 queries/sec.

| | Extra CPU | Extra MySQL |
|---|---|---|
| **Scenario A (N+1)** | negligible — ~4.6 queries/sec of PK lookups is well under 1% of one core on MySQL; payment itself mostly waits on I/O | +4.6 queries/sec (~4× baseline), ~+5 rows/sec |
| **Scenario B (batch)** | ~60s of one core per run, dominated by spawning the `mysql` client 1500 times, not by the database | +6000 queries and ~345,000 rows per run; +20 queries/sec and +1,150 rows/sec averaged over 5 minutes |
| **Container overhead** | `stock-reconciler` idles at essentially zero between runs | 64 MiB limit |

Neither scenario comes close to the ~400% CPU the runaway `removeoldquotes`
query produced. The batch is the heavier of the two and is bounded at 120
seconds by construction.

---

## Before running either

- [ ] Rebuild payment — Scenario A needs the new `charge.js`: `make redeploy service=payment`
- [ ] Confirm the rendered config is unchanged with no scenario env set
- [ ] Decide on the `mysql.query.count` collector change, and restart the collector if yes
- [ ] Add the rules to EmmettDev and confirm the metric names first
- [ ] Rehearse Scenario B with `RECONCILE_INTERVAL_SECONDS=300` before using the 90-minute default
- [ ] Check that Scenario A's version change appears in the Service Catalogue as a second version of `payment`, not a new service

---

## Scenario C — `fail-db`: real checkout failures

Coworker needs **real failures** to raise a Situation. Slow-but-successful is
not enough, which is why `slow-db` and `deploy-bad` alone are not sufficient to
trigger an investigation.

```bash
./demo.sh fail-db          # default 30% of charges fail
./demo.sh fail-db 20%      # or pick a variant
./demo.sh reset            # clears it
```

### Timeouts on the checkout path — what actually exists

This was the starting question, and the answer shaped everything:

| Hop | Timeout |
|---|---|
| Locust → Envoy | **none** — the checkout task sets no `timeout` |
| Envoy → frontend | **15 s** (Envoy's default; the catch-all route sets none) |
| frontend → checkout | none found |
| checkout → payment (gRPC) | **none** — `context.Background()`, no deadline |
| payment → MySQL (mysql2) | **none** — no `connectTimeout`, no `acquireTimeout`; `waitForConnections: true`, `connectionLimit: 10`, `enableKeepAlive: true` |

So the **only** timeout on the whole path is Envoy's 15 s. Reaching it needs
checkout to exceed 15 s, which means ~15 s of database latency — and with
`waitForConnections: true` that ties up pool connections and queues every other
charge behind it. It is an all-or-nothing, cascade-prone lever.

### Why Toxiproxy cannot produce a partial failure rate — measured

Toxiproxy's `toxicity` is evaluated **per connection**, not per request, and
mysql2's pool keeps a connection alive across charges arriving every ~17 s. The
dice are rolled once and the result sticks:

| Toxic | Result |
|---|---|
| `reset_peer`, toxicity **1.0** | **7 of 7 checkouts failed (100%)** |
| `reset_peer`, toxicity **0.35** | **0 of 28 checkouts failed (0%)** |
| `limit_data`, 4000 bytes | **0 of 27 (0%)** — connections are closed while idle, so mysql2 just reconnects |

There is nothing in between. A per-request failure share needs a per-request
mechanism, so `fail-db` uses the `paymentDatabaseError` flagd flag instead.

### What it does

The flag throws a realistic database error — `ECONNREFUSED`, `ETIMEDOUT`,
`ER_LOCK_WAIT_TIMEOUT` or `ER_LOCK_DEADLOCK` — on a set fraction of charges,
before the database call.

**Measured at the 30% variant:**

| | |
|---|---|
| Checkout failure rate | **23.1%** (6 of 26 orders lost) |
| payment charge failures | 6, each with `trace_id` and a DB error message |
| Error spans in traces | **31, across 9 service/operation pairs** |

Error propagation, confirmed from the collector's own output:

```
payment         grpc.oteldemo.PaymentService/Charge        Error x2
checkout        oteldemo.PaymentService/Charge             Error x5
checkout        oteldemo.CheckoutService/PlaceOrder        Error x5
frontend        grpc.oteldemo.CheckoutService/PlaceOrder   Error x2
frontend        executing api route (pages) /api/checkout  Error x2
frontend-proxy  ingress                                    Error x5
load-generator  POST                                       Error x4
```

with the exception message carrying through:
`could not charge the card: rpc error: code = Unknown desc = Database ...`

### Limitations, stated plainly

1. **The error is raised just before the database call**, so there is no failed
   MySQL span and MySQL's own metrics do not move. The failure is real and the
   trace is real; the *database evidence* is not. Pair with `./demo.sh slow-db`
   if the story needs database-side corroboration.
2. **`payment`'s internal `charge` span is not marked Error.** `charge.js` calls
   `span.recordException()` without `setStatus(ERROR)`, so only the gRPC handler
   span above it carries Error status. Detection works, but a one-line fix in
   `charge.js` would make the innermost span honest too.
3. 23.1% against a 30% setting is expected sampling variation at n=26.

---

## Measured results for Scenario A (`deploy-bad`)

Run on 2026-11-11 with the 4 ms baseline latency in place.

| | Baseline (2.0.2) | deploy-bad (2.0.3) |
|---|---:|---:|
| Queries per charge | 1 | **86–156, avg 124** |
| payment p50 / p95 | 11 / 14 ms | **663 / 833 ms** |
| checkout p50 / p95 | ~430 / ~615 ms | **1090 / 1373 ms** |

Rollback restored **p50 9 ms, p95 13 ms** with zero N+1 log lines and
`service.version=2.0.2`.

### Which alerts fire

| Rule | Threshold | Under deploy-bad | Fires |
|---|---|---|---|
| Payment service is slow | p95 > 500 ms | 833 ms | **yes** |
| Checkout is slow for customers | p95 > 1000 ms | 1373 ms | **yes** |
| Payment making far more DB calls per charge | ratio > 5 | ~124 | **yes** (after the fix below) |
| Database handling far more queries | > 10 q/s | see below | **no** |

Two corrections came out of this run:

- **The DB-calls rule was wrong.** It counted `span_name="INSERT"`, but the N+1
  issues `SELECT`s — the INSERT count stays at 1 per charge. Changed to
  `span_name=~"SELECT|INSERT"`.
- **The query-count rule does not fire for the N+1.** MySQL's `Questions`
  measured **1.4/sec under deploy-bad against a 1.6/sec baseline** — no rise at
  all. At ~3.6 charges/min, 124 extra queries each is only ~7 queries/sec
  spread thinly, and the sample is dominated by variance. The query-count rule
  remains useful for the batch job; it is not a detector for this scenario.

---

## Scenario C2 — flagd-free `fail-db` (PLANNED, NOT DEPLOYED)

Mikey wants faults without flagd. The current `fail-db` uses the
`paymentDatabaseError` flag, which works but throws *before* the database call,
so there is no failed MySQL span. This replaces it with a failure that happens
**inside the database client**, producing real database-side error spans.

**Status: code written and inert, nothing deployed.** `PAYMENT_QUERY_TIMEOUT_MS`
defaults to `0`, which makes `executeWithTimeout()` exactly the previous
`pool.execute()`. It needs a payment rebuild to become live.

### How it works

Two halves, each useless alone:

1. **A per-query deadline in payment.** `PAYMENT_QUERY_TIMEOUT_MS` gives every
   charge's INSERT a timeout. Crucially this is evaluated **per query**, which
   is exactly what Toxiproxy's per-connection `toxicity` could not do.
2. **A jittery latency toxic** on the payment → MySQL link. Toxiproxy draws each
   delay uniformly from `[latency - jitter, latency + jitter]`, so a fixed
   deadline cuts that distribution at a chosen point.

The share that fails is then simple arithmetic:

```
P(timeout) = (latency + jitter - timeout) / (2 x jitter)
```

### Proposed numbers

Keep the deadline fixed at **2000 ms** and move only the latency:

| Latency | Jitter | Delay range | Timeout | Expected failures |
|---:|---:|---|---:|---:|
| 1700 | 600 | 1100–2300 ms | 2000 | **25%** |
| **1760** | **600** | **1160–2360 ms** | **2000** | **30%** |
| 1850 | 600 | 1250–2450 ms | 2000 | **37.5%** |

One number — the latency — tunes the whole range of 20–40%.

**2000 ms is chosen so `slow-db` is unaffected.** `slow-db` tops out at
800 + 100 jitter + 4 baseline = 904 ms, comfortably below the deadline, so the
existing slowdown scenario stays slow-but-successful exactly as measured.

That also means `PAYMENT_QUERY_TIMEOUT_MS` can be set **permanently** in
`docker-compose.yml` rather than requiring a payment redeploy when the scenario
is used — no query legitimately approaches 2 s, including `deploy-bad`'s 124
queries of ~5 ms each. The code default stays `0` so the service is unchanged
for anyone running it elsewhere.

### Why the connection has to be destroyed by hand

`mysql2` raises `PROTOCOL_SEQUENCE_TIMEOUT` **without setting `err.fatal`**
(verified in 3.11.5, `lib/commands/query.js _handleTimeoutError`). The pool
therefore keeps the connection — but its protocol is now desynchronised, because
the server's reply arrives after the client gave up. The next query on that
connection can pick up the previous response.

So `executeWithTimeout()` takes a connection explicitly and calls
`conn.destroy()` on timeout instead of releasing it. Using a bare
`pool.execute({ sql, timeout })` would appear to work and then produce
intermittent wrong-response bugs, which would be very unpleasant to debug
during a webinar.

### Proposed `demo.sh` change — written here, not applied

```diff
+FAIL_TOXIC_NAME="payment-mysql-failslow"
+FAIL_LATENCY_MS="${FAIL_LATENCY_MS:-1760}"
+FAIL_JITTER_MS="${FAIL_JITTER_MS:-600}"

 cmd_fail_db() {
-  flag_set paymentDatabaseError "$variant"
+  need_container toxiproxy
+  tp toxic remove -n "$FAIL_TOXIC_NAME" "$PROXY_NAME" >/dev/null 2>&1 || true
+  tp toxic add -n "$FAIL_TOXIC_NAME" -t latency \
+      -a "latency=${FAIL_LATENCY_MS}" -a "jitter=${FAIL_JITTER_MS}" \
+      "$PROXY_NAME" >/dev/null || die "failed to add the fail-db toxic"
 }
```

and `toxic_clear()` gains a third removal so `reset` clears it.

The existing flagd `fail-db` was **left in place** rather than swapped out,
because swapping it before the payment rebuild would leave a `fail-db` that
slows the database without failing anything — and a Coworker test was imminent.

### Expected effects, and what to watch

| | Expected |
|---|---|
| Failed charges | ~30%, with a **DB client span ending in error** |
| Successful charges | 1.16–2.0 s each (the latency applies to them too) |
| payment p95 | ~2 s — **also fires the 500 ms payment rule** |
| checkout p95 | ~2.6 s — **also fires the 1000 ms checkout rule** |
| MySQL itself | untouched; the delay is in the link, not the server |

So this is not a pure error scenario: it is a struggling-database scenario that
both slows and fails, which is arguably more realistic than either alone.

### Unknowns to settle when it is safe to test

1. **Does the mysql2 instrumentation mark the DB span as `Error` on a
   client-side timeout?** This is the entire point of the design and it is
   *unverified*. The promise rejects, so it should — but "should" is what the
   `span_name="INSERT"` rule and the `traces_span_metrics_duration_milliseconds`
   metric name both were. Confirm with one detailed-verbosity capture before
   relying on it.
2. **Reconnect cost.** Every timeout destroys a connection, and a new one must
   re-handshake across a ~1.76 s link — roughly 3–4 round trips, so **5–7 s**
   before the next charge can proceed. At ~3.6 orders/min that should absorb,
   but `waitForConnections: true` with `queueLimit: 0` means charges queue
   rather than fail fast if it does not.
3. **Whether the arithmetic holds.** `P = (L + J - T) / 2J` assumes the delay
   dominates the query. Measure once and adjust `FAIL_LATENCY_MS`.
4. **Whether to keep both.** The flagd version fails fast and cleanly with no
   database evidence; this one produces database evidence but also large
   latency. They are different stories and both may be worth keeping.


---

## Scenario C2 — flagd-free `fail-db`: DEPLOYED AND MEASURED

Built and tested 2026-11-12. The flagd `paymentDatabaseError` version is gone;
`./demo.sh fail-db` now uses a per-query deadline plus a jittery latency toxic.

| | |
|---|---|
| `PAYMENT_QUERY_TIMEOUT_MS` | **2000** (set permanently in `docker-compose.yml`) |
| `fail-db` defaults | **1500 ms ± 1000 ms** |
| Measured failure rate | **25.9%** (7 of 27 orders) |
| Measured timeouts | 9, all `PROTOCOL_SEQUENCE_TIMEOUT` |

### The model is wrong, and badly

`P = (latency + jitter - timeout) / (2 x jitter)` **understates the real rate**,
because timeouts feed back: each one destroys its connection, the replacement
must re-handshake across the slow link, and other charges queue behind it and
time out too. Measured:

| Setting | Model | **Actual** |
|---|---:|---:|
| 1760 ± 600 | 30% | **45.5%** |
| 1600 ± 600 | 17% | **4.3%** |
| **1500 ± 1000** | 25% | **25.9%** |

**160 ms of latency took it from 4% to 45%.** The response is near-bistable:
below a threshold almost nothing times out, above it cascades. The wider jitter
is what tames it — a lower mean makes reconnects cheaper and the wider spread
makes the rate less sensitive to the latency.

**Re-measure if you change either number. Do not trust the formula.**

### Database-side error spans — confirmed

This was the whole point, and it works:

```
payment  INSERT                               Error  x5
         db.system=mysql  net.peer.name=payment-db
         Status message: Query inactivity timeout
payment  charge                               Error  x5
payment  grpc.oteldemo.PaymentService/Charge  Error  x5
checkout oteldemo.PaymentService/Charge       Error  x5
checkout oteldemo.CheckoutService/PlaceOrder  Error  x5
frontend-proxy ingress / router egress        Error  x5 each
load-generator POST                           Error  x6
```

The failure is now **on the database span itself**, not thrown before it — the
gap the flagd version had. `dns.lookup` and `tcp.connect` spans also appear,
which is the reconnect churn made visible.

Note `charge` carries `Error` too, which only works because of the
`setStatus(ERROR)` fix applied on 2026-11-11.

### Cost: it both slows and fails

Non-timing-out queries still take 500–2000 ms, and the reconnect queuing
amplifies that: measured **payment p50 1723 ms, p95 8705 ms, max 10139 ms**.

So this fires the payment and checkout latency rules as well as the error rule.
That is realistic for a struggling database, but it is **not** a clean
errors-only scenario, and the p95 gets close enough to Envoy's 15 s route
timeout to be worth watching if traffic ever increases.
